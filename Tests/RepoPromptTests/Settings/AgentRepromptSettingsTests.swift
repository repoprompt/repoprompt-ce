import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptSettingsTests: XCTestCase {
    func testScopedDraftSaveDefaultAndUnrelatedWritesPreserveFields() throws {
        for workspaceID in [nil, UUID()] {
            let (store, api) = try fixture()
            let global = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt61Sol.rawValue, agentRepromptGuidance: "Global wording")
            store.setGlobalAgentModelsProfile(global, contextBuilderWriteIntent: .preserveExistingOwnership)
            if let workspaceID {
                store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: .init())
            }
            let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, workspaceID: workspaceID, settingsManager: store, settingsStore: store, notificationCenter: NotificationCenter())
            vm.repromptGuidanceDraft = "  My voice\nKeep uncertainty. \n"
            vm.repromptContextPolicyDraft = .never
            XCTAssertTrue(vm.isRepromptDraftDirty)
            XCTAssertNotEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptContextPolicy, .never)
            XCTAssertTrue(vm.saveRepromptDraft())
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptGuidance, "My voice\nKeep uncertainty.")
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptContextPolicy, .never)
            vm.setOracleModel(raw: AIModel.gpt61Sol.rawValue)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptContextPolicy, .never)
            XCTAssertTrue(vm.restoreDefaultRepromptGuidance())
            XCTAssertEqual(vm.repromptGuidanceDraft, AgentRepromptGuidance.defaultText)
            XCTAssertNil(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptContextPolicy)
            if workspaceID != nil {
                XCTAssertEqual(store.globalAgentModelsProfile(), global)
            }
        }
    }

    func testStaleScopeAndExternalGuidanceCannotOverwriteWithoutReload() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store, notificationCenter: NotificationCenter())
        vm.repromptGuidanceDraft = "Unsaved draft"
        var external = store.globalAgentModelsProfile()
        external.agentRepromptGuidance = "External edit"
        store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        XCTAssertFalse(vm.saveRepromptDraft(), "Live/cache guard must refuse a stale click.")
        XCTAssertTrue(vm.repromptDraftHasConflict)
        XCTAssertEqual(vm.repromptGuidanceDraft, "Unsaved draft")
        vm.reloadRepromptDraft()
        XCTAssertEqual(vm.repromptGuidanceDraft, "External edit")
        vm.repromptGuidanceDraft = "Another draft"
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: .init())
        vm.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: "Different scope")
        XCTAssertTrue(vm.repromptDraftHasConflict)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertEqual(store.globalAgentModelsProfile().agentRepromptGuidance, "External edit")
    }

    func testOversizedGuidanceRejectedWithoutTruncationAndBlankRestoresDefault() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        vm.repromptGuidanceDraft = String(repeating: "x", count: 16 * 1024 + 1)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
        XCTAssertEqual(vm.repromptGuidanceDraft.utf8.count, 16 * 1024 + 1)
        vm.repromptGuidanceDraft = " \t\n"
        XCTAssertTrue(vm.saveRepromptDraft())
        XCTAssertEqual(vm.repromptGuidanceDraft, AgentRepromptGuidance.defaultText)
    }

    private func fixture() throws -> (GlobalSettingsStore, APISettingsViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentRepromptSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        return (store, APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false))
    }
}
