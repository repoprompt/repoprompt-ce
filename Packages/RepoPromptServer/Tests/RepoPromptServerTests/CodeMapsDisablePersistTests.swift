import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServerOperations
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class CodeMapsDisablePersistTests: XCTestCase {
    func testMissingDisableFlagMeansMapsOnAndRemapsUsageToNone() throws {
        XCTAssertFalse(AdvancedServerSettings.default.codeMapsGloballyDisabled)
        XCTAssertTrue(AdvancedServerSettings.default.codeMapsEnabled)
        XCTAssertEqual(AdvancedServerSettings.default.resolvedCodeMapUsage(.auto), .auto)
        XCTAssertEqual(AdvancedServerSettings.default.resolvedCodeMapUsage(.complete), .complete)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"codeMapsEnabled":false}"#.utf8)
        )
        XCTAssertTrue(legacy.codeMapsGloballyDisabled)
        XCTAssertFalse(legacy.codeMapsEnabled)
        XCTAssertEqual(legacy.resolvedCodeMapUsage(.auto), .none)
        XCTAssertEqual(legacy.resolvedCodeMapUsage(.selected), .none)

        let explicit = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"codeMapsGloballyDisabled":true,"codeMapsEnabled":true}"#.utf8)
        )
        XCTAssertTrue(explicit.codeMapsGloballyDisabled)
        XCTAssertEqual(explicit.resolvedCodeMapUsage(.complete), .none)

        let missing = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertFalse(missing.codeMapsGloballyDisabled)
        XCTAssertTrue(missing.codeMapsEnabled)
    }

    func testDisabledMapsFailClosedOnGenerateAndRemapSelectionToFullFile() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codemap-disable-\(UUID().uuidString)")
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("codemap-disable-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        try "struct Greeter {\n    func hello() {}\n}\n".write(
            to: root.appendingPathComponent("Greeter.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyCodeMapCatalog(),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            codeMapBuilder: ServerWorkspaceCodeMapBuilder(),
            artifactService: try ArtifactRuntimeService(baseDirectory: artifacts.path),
            serverSettings: service
        )
        let actor = ExternalActor(userID: "maps", username: "maps", displayName: "Maps")
        let project = try await authority.createProject(
            input: .init(name: "Maps", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "maps-project",
            requestDigest: "maps-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "maps-session",
            requestDigest: "maps-session"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let ready = try await authority.projectCodeMap(
            projectID: project.projectID,
            request: .init(rootID: rootID, logicalPath: "Greeter.swift")
        )
        XCTAssertEqual(ready.status, "ready")
        XCTAssertTrue(ready.content.contains("Greeter"))

        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(codeMapsGloballyDisabled: true)),
            attribution: attribution
        )
        XCTAssertTrue(written.settings.codeMapsGloballyDisabled)
        XCTAssertFalse(written.settings.codeMapsEnabled)
        XCTAssertEqual(written.settings.resolvedCodeMapUsage(.auto), .none)

        do {
            _ = try await authority.projectCodeMap(
                projectID: project.projectID,
                request: .init(rootID: rootID, logicalPath: "Greeter.swift")
            )
            XCTFail("generate should fail closed while globally disabled")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
            XCTAssertEqual(error.message, AdvancedServerSettings.codeMapsGloballyDisabledMCPMessage)
        }

        let selected = try await authority.replaceSelection(
            sessionID: session.sessionID,
            entries: [.init(rootID: rootID, logicalPath: "Greeter.swift", mode: .codeMap)],
            expectedRevision: 1,
            actor: actor
        )
        let artifact = try await authority.buildContext(
            sessionID: session.sessionID,
            expectedSelectionRevision: selected.revision,
            include: ["files"],
            actor: actor
        )
        let content = String(
            decoding: try await authority.artifactContent(artifactID: artifact.artifactID, maximumBytes: 1_048_576),
            as: UTF8.self
        )
        XCTAssertFalse(content.contains("[codemap:"))
        XCTAssertTrue(content.contains("struct Greeter"))
        XCTAssertTrue(content.contains("func hello"))
    }
}

private struct EmptyCodeMapCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
