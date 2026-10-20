import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptSchemaTests: XCTestCase {
    func testOldDecodeAndFeatureFence() throws {
        let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data("{}".utf8))
        XCTAssertNil(profile.agentRepromptGuidance)
        XCTAssertNil(profile.agentRepromptContextPolicy)
        for policy in [nil, .automatic, .never] as [AgentRepromptContextPolicy?] {
            let document = GlobalSettingsDocument(scalarPreferences: .init(modelSelection: .init(agentRepromptContextPolicy: policy)))
            XCTAssertEqual(document.requiredSchemaVersion, policy == nil ? 2 : 13)
        }
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
        profile.agentRepromptContextPolicy = .never
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        let workspaceID = UUID()
        store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
        var global = store.globalAgentModelsProfile()
        global.agentRepromptGuidance = nil
        global.agentRepromptContextPolicy = nil
        store.setGlobalAgentModelsProfile(global, contextBuilderWriteIntent: .preserveExistingOwnership)
        let fresh = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertNil(fresh.globalAgentModelsProfile().agentRepromptGuidance)
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptGuidance, "My voice.")
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptContextPolicy, .never)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 13)
        fresh.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        var override = fresh.effectiveAgentModelsProfile(workspaceID: workspaceID)
        override.planningModelRaw = "fixture-model"
        fresh.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: override)
        XCTAssertEqual(fresh.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptGuidance, "My voice.")
        override.agentRepromptGuidance = nil
        override.agentRepromptContextPolicy = nil
        fresh.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: override)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertNil(reloaded.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptGuidance)
        XCTAssertNil(reloaded.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptContextPolicy)
    }
}
