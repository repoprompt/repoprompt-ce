import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class FileSystemScanningPersistTests: XCTestCase {
    func testMissingScanFieldsMatchDesktopDefaults() throws {
        XCTAssertTrue(AdvancedServerSettings.default.respectRepoIgnore)
        XCTAssertTrue(AdvancedServerSettings.default.respectCursorIgnore)
        XCTAssertTrue(AdvancedServerSettings.default.respectNestedIgnoreFiles)
        XCTAssertFalse(AdvancedServerSettings.default.followSymbolicLinks)
        XCTAssertFalse(AdvancedServerSettings.default.showEmptyFolders)
        XCTAssertEqual(
            AdvancedServerSettings.default.globalIgnoreDefaults,
            AdvancedServerSettings.canonicalGlobalIgnoreDefaults
        )

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertTrue(legacy.respectRepoIgnore)
        XCTAssertFalse(legacy.showEmptyFolders)
        XCTAssertEqual(legacy.globalIgnoreDefaults, AdvancedServerSettings.canonicalGlobalIgnoreDefaults)

        let emptyGlobals = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"globalIgnoreDefaults":""}"#.utf8)
        )
        XCTAssertEqual(emptyGlobals.globalIgnoreDefaults, "")
    }

    func testRepoIgnoreGateDoesNotControlGitignoreAndEmptyFoldersDefaultOff() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "git-ignored.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "repo-ignored.swift\n".write(to: root.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("git-ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("repo-ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try "stash".write(to: root.appendingPathComponent("stash.tmp"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyScanCatalog(),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "scan", username: "scan", displayName: "Scan")
        let project = try await authority.createProject(
            input: .init(name: "Scan", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "scan-project",
            requestDigest: "scan-project"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let initialHits = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "needle")
        )
        XCTAssertEqual(initialHits.map(\.logicalPath), ["visible.swift"])
        let tmpHits = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "stash")
        )
        XCTAssertTrue(tmpHits.isEmpty, "canonical globalIgnoreDefaults should hide *.tmp")
        let initialTree = try await authority.projectTree(
            projectID: project.projectID,
            request: .init(rootID: rootID)
        )
        XCTAssertFalse(initialTree.contains(where: { $0.logicalPath == "empty" }))

        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        _ = try await service.replaceAdvanced(
            .init(
                expectedRevision: 0,
                settings: .init(respectRepoIgnore: false, globalIgnoreDefaults: "")
            ),
            attribution: attribution
        )
        let ungated = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "needle")
        )
        XCTAssertEqual(Set(ungated.map(\.logicalPath)), Set(["repo-ignored.swift", "visible.swift"]))
        let recoveredTmp = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "stash")
        )
        XCTAssertEqual(recoveredTmp.map(\.logicalPath), ["stash.tmp"])

        let recovered = try await service.advanced()
        XCTAssertFalse(recovered.settings.respectRepoIgnore)
        XCTAssertEqual(recovered.settings.globalIgnoreDefaults, "")
        XCTAssertFalse(recovered.settings.showEmptyFolders)
    }
}

private struct EmptyScanCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
