import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptSchemaTests: XCTestCase {
    func testModeHistoryFeatureFenceAndUnknownSelectionsRemainExplicit() throws {
        let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data(#"{"planningModelRaw":"chosen-oracle","agentRepromptModelRaw":"future-selection","agentRepromptMode":"future-mode"}"#.utf8))
        XCTAssertEqual(profile.agentRepromptModelRaw, "future-selection")
        XCTAssertEqual(profile.agentRepromptMode, .review, "Unknown modes never authorize auto-send")
        XCTAssertEqual(GlobalSettingsDocument(scalarPreferences: .init(modelSelection: .init(agentRepromptMode: .sendAutomatically))).requiredSchemaVersion, 13)
        XCTAssertEqual(GlobalSettingsDocument(scalarPreferences: .init(modelSelection: .init(agentRepromptIncludesRecentChat: false))).requiredSchemaVersion, 13)
        let scoped = GlobalSettingsDocument(agentModelsSettings: [UUID(): .init(inheritanceMode: .useGlobalSettings, profile: .init(agentRepromptMode: .sendAutomatically, agentRepromptIncludesRecentChat: false))])
        XCTAssertEqual(scoped.requiredSchemaVersion, 13)
    }

    func testWorkspaceActivationPersistsIndependentlyOfProfileInheritance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentRepromptActivationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("settings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: url)
        let workspaceID = UUID(), otherWorkspaceID = UUID()
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertNil(store.workspaceAgentModelsSettings(for: workspaceID).agentRepromptEnabled)
        store.setWorkspaceAgentRepromptEnabled(workspaceID: workspaceID, enabled: true)
        XCTAssertEqual(store.workspaceAgentModelsSettings(for: workspaceID).inheritanceMode, .useGlobalSettings)
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: .init(planningModelRaw: "custom"))
        store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
        let fresh = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(fresh.workspaceAgentModelsSettings(for: workspaceID).agentRepromptEnabled, true)
        XCTAssertNil(fresh.workspaceAgentModelsSettings(for: otherWorkspaceID).agentRepromptEnabled)
        XCTAssertEqual(fresh.workspaceAgentModelsSettings(for: workspaceID).inheritanceMode, .useGlobalSettings)
        fresh.setWorkspaceAgentRepromptEnabled(workspaceID: workspaceID, enabled: false)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(reloaded.workspaceAgentModelsSettings(for: workspaceID).agentRepromptEnabled ?? false)
        let legacy = try JSONDecoder().decode(WorkspaceAgentModelsSettings.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.agentRepromptEnabled, "Existing workspaces remain off until explicitly enabled")
        let activated = GlobalSettingsDocument(agentModelsSettings: [workspaceID: .init(agentRepromptEnabled: true)])
        XCTAssertEqual(activated.requiredSchemaVersion, 14)
        XCTAssertEqual(GlobalSettingsFileStore.preservationBlockReason(
            schemaVersion: 14, schemaLineage: activated.schemaLineage, supportedVersion: 13
        ), .unsupportedFutureSchema(onDiskVersion: 14, supportedVersion: 13))
    }

    func testOldDecodeAndFeatureFence() throws {
        let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data("{}".utf8))
        XCTAssertNil(profile.agentRepromptGuidance)
        XCTAssertNil(profile.agentRepromptModelRaw)
        for policy in [nil, "unknown-selection", "specific-model"] as [String?] {
            let document = GlobalSettingsDocument(scalarPreferences: .init(modelSelection: .init(agentRepromptModelRaw: policy)))
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
        profile.agentRepromptModelRaw = "specific-model"
        profile.agentRepromptMode = .sendAutomatically
        profile.agentRepromptIncludesRecentChat = false
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
        XCTAssertEqual(fresh.globalAgentModelsProfile().agentRepromptMode, .sendAutomatically)
        XCTAssertEqual(fresh.globalAgentModelsProfile().agentRepromptIncludesRecentChat, false)
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptMode, .sendAutomatically)
        XCTAssertEqual(fresh.workspaceAgentModelsProfile(for: workspaceID)?.agentRepromptIncludesRecentChat, false)
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
