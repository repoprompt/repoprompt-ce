import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class AppSettingsEngineKeysPersistTests: XCTestCase {
    func testMissingUIAndScanMCPKeysMatchDesktopDefaults() throws {
        XCTAssertEqual(AdvancedServerSettings.default.resolvedAppearanceMode(), .system)
        XCTAssertTrue(AdvancedServerSettings.default.showTooltips)
        XCTAssertTrue(AdvancedServerSettings.default.enableKeyboardShortcuts)
        XCTAssertEqual(AdvancedServerSettings.default.resolvedFontScale(), .normal)
        XCTAssertEqual(AdvancedServerSettings.default.fontScaleBodySize, 14)
        XCTAssertTrue(AdvancedServerSettings.default.skipSymlinks)
        XCTAssertFalse(AdvancedServerSettings.default.showEmptyFolders)
        XCTAssertFalse(AdvancedServerSettings.default.codeMapsGloballyDisabled)

        let missing = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(missing.resolvedAppearanceMode(), .system)
        XCTAssertEqual(missing.resolvedFontScale(), .normal)
        XCTAssertTrue(missing.skipSymlinks)

        let invalid = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"appearanceMode":"Neon","fontScaleBodySize":13}"#.utf8)
        )
        XCTAssertEqual(invalid.resolvedAppearanceMode(), .system)
        XCTAssertEqual(invalid.resolvedFontScale(), .normal)
    }

    func testAppSettingsUIFileSystemAndCodeMapKeysWriteTheAdvancedStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "repo-ignored.swift\n".write(to: root.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("repo-ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func hello() {}\n}\n".write(
            to: root.appendingPathComponent("Greeter.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-engine-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyEngineKeysCatalog(),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            artifactService: try ArtifactRuntimeService(baseDirectory: artifacts.path),
            serverSettings: service
        )
        let actor = ExternalActor(userID: "engine-keys", username: "engine-keys", displayName: "Engine Keys")
        let project = try await authority.createProject(
            input: .init(name: "EngineKeys", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "engine-keys-project",
            requestDigest: "engine-keys-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "engine-keys-session",
            requestDigest: "engine-keys-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        let rootID = try XCTUnwrap(project.roots.first?.rootID)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let appearance = try await invoke(["op": "get", "key": "ui.appearance_mode"])
        XCTAssertEqual(appearance["value"] as? String, "System")
        let font = try await invoke(["op": "get", "key": "ui.font_scale"])
        XCTAssertEqual((font["value"] as? NSNumber)?.doubleValue, 14)
        let skip = try await invoke(["op": "get", "key": "file_system.skip_symlinks"])
        XCTAssertEqual(skip["value"] as? Bool, true)
        let emptyFolders = try await invoke(["op": "get", "key": "file_system.show_empty_folders"])
        XCTAssertEqual(emptyFolders["value"] as? Bool, false)
        let maps = try await invoke(["op": "get", "key": "code_maps.globally_disabled"])
        XCTAssertEqual(maps["value"] as? Bool, false)

        let writtenAppearance = try await invoke(["op": "set", "key": "ui.appearance_mode", "value": "Dark"])
        XCTAssertEqual(writtenAppearance["value"] as? String, "Dark")
        _ = try await invoke(["op": "set", "key": "ui.show_tooltips", "value": false])
        _ = try await invoke(["op": "set", "key": "ui.enable_keyboard_shortcuts", "value": false])
        _ = try await invoke(["op": "set", "key": "ui.font_scale", "value": 16])
        let stored = try await authority.advancedSettings()
        let storedUI = stored.settings
        XCTAssertEqual(storedUI.resolvedAppearanceMode(), AdvancedServerSettings.AppearanceMode.dark)
        XCTAssertFalse(storedUI.showTooltips)
        XCTAssertFalse(storedUI.enableKeyboardShortcuts)
        XCTAssertEqual(storedUI.resolvedFontScale(), AdvancedServerSettings.FontScale.large)

        do {
            _ = try await invoke(["op": "set", "key": "ui.appearance_mode", "value": "Neon"])
            XCTFail("invalid appearance should fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await invoke(["op": "set", "key": "ui.font_scale", "value": 13])
            XCTFail("invalid font scale should fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let gatedHits = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "needle")
        )
        XCTAssertEqual(gatedHits.map(\.logicalPath), ["visible.swift"])
        _ = try await invoke(["op": "set", "key": "file_system.respect_repo_ignore", "value": false])
        let ungatedHits = try await authority.projectSearch(
            projectID: project.projectID,
            request: .init(rootID: rootID, query: "needle")
        )
        XCTAssertEqual(Set(ungatedHits.map(\.logicalPath)), Set(["repo-ignored.swift", "visible.swift"]))

        _ = try await invoke(["op": "set", "key": "file_system.skip_symlinks", "value": false])
        let followed = try await authority.advancedSettings()
        XCTAssertTrue(followed.settings.followSymbolicLinks)

        _ = try await invoke(["op": "set", "key": "code_maps.globally_disabled", "value": true])
        do {
            _ = try await authority.projectCodeMap(
                projectID: project.projectID,
                request: .init(rootID: rootID, logicalPath: "Greeter.swift")
            )
            XCTFail("generate should fail closed after MCP disable")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
            XCTAssertEqual(error.message, AdvancedServerSettings.codeMapsGloballyDisabledMCPMessage)
        }
    }
}

private struct EmptyEngineKeysCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
