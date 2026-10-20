import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptSchemaTests: XCTestCase {
    func testOldDecodeAndFeatureFence() throws {
        let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data("{}".utf8))
        XCTAssertNil(profile.agentRepromptGuidance)
        XCTAssertNil(profile.agentRepromptModelRaw)
        for policy in [nil, "primary-oracle", "specific-model"] as [String?] {
            let document = GlobalSettingsDocument(scalarPreferences: .init(modelSelection: .init(agentRepromptModelRaw: policy)))
            XCTAssertEqual(document.requiredSchemaVersion, policy == nil ? 2 : 13)
        }
        let legacy = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data(#"{"agentRepromptContextPolicy":"unknown-future-value","agentRepromptGuidance":"keep me"}"#.utf8))
        XCTAssertNil(legacy.agentRepromptModelRaw)
        XCTAssertEqual(legacy.agentRepromptGuidance, "keep me")
        let encoded = try String(decoding: JSONEncoder().encode(legacy), as: UTF8.self)
        XCTAssertFalse(encoded.contains("agentRepromptContextPolicy"))
        let retained = GlobalSettingsDocument(agentModelsSettings: [UUID(): .init(
            inheritanceMode: .useGlobalSettings,
            profile: .init(agentRepromptGuidance: "custom")
        )])
        XCTAssertEqual(retained.requiredSchemaVersion, 13)
        XCTAssertEqual(GlobalSettingsFileStore.preservationBlockReason(
            schemaVersion: 13, schemaLineage: retained.schemaLineage, supportedVersion: 12
        ), .unsupportedFutureSchema(onDiskVersion: 13, supportedVersion: 12))
    }

    func testRealStoreRoundTripCopiesResetAndUnrelatedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentRepromptSchemaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("settings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        var profile = store.globalAgentModelsProfile()
        profile.agentRepromptGuidance = "  My voice.\n"
        profile.agentRepromptModelRaw = "specific-model"
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        let workspaceID = UUID()
        store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
        var global = store.globalAgentModelsProfile()
        global.agentRepromptGuidance = nil
        global.agentRepromptModelRaw = nil
        store.setGlobalAgentModelsProfile(global, contextBuilderWriteIntent: .preserveExistingOwnership)
        let fresh = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertNil(fresh.globalAgentModelsProfile().agentRepromptGuidance)
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptGuidance, "My voice.")
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptModelRaw, "specific-model")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 13)
        fresh.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        var override = fresh.effectiveAgentModelsProfile(workspaceID: workspaceID)
        override.planningModelRaw = "fixture-model"
        fresh.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: override)
        XCTAssertEqual(fresh.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptGuidance, "My voice.")
        override.agentRepromptGuidance = nil
        override.agentRepromptModelRaw = nil
        fresh.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: override)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertNil(reloaded.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptGuidance)
        XCTAssertNil(reloaded.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptModelRaw)
    }
}
