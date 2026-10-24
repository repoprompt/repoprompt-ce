import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import SwiftUI
import XCTest

@MainActor
final class AgentRepromptSettingsTests: XCTestCase {
    func testSavingOnlyModelModeOrHistoryDoesNotFreezeDefaultGuidance() throws {
        for baseline in [nil, "Custom user wording"] as [String?] {
            for field in 0 ..< 3 {
                let (store, api) = try fixture()
                store.setGlobalAgentModelsProfile(.init(agentRepromptGuidance: baseline), contextBuilderWriteIntent: .preserveExistingOwnership)
                let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
                switch field {
                case 0: vm.repromptModelDraft = AIModel.gpt61SolLow.rawValue
                case 1: vm.repromptModeDraft = .sendAutomatically
                default: vm.repromptRecentChatDraft = false
                }
                XCTAssertTrue(vm.saveRepromptDraft())
                XCTAssertEqual(store.globalAgentModelsProfile().agentRepromptGuidance, baseline)
                if baseline != nil {
                    vm.repromptGuidanceDraft = " \n" + AgentRepromptGuidance.defaultText + "\n "
                    XCTAssertTrue(vm.saveRepromptDraft())
                    XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
                }
                XCTAssertTrue(vm.restoreDefaultRepromptGuidance())
                XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
            }
        }
    }

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
            vm.repromptModelDraft = "specific-model"
            vm.repromptModeDraft = .sendAutomatically
            vm.repromptRecentChatDraft = false
            XCTAssertTrue(vm.isRepromptDraftDirty)
            XCTAssertNotEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            XCTAssertTrue(vm.saveRepromptDraft())
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptGuidance, "My voice\nKeep uncertainty.")
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            vm.setOracleModel(raw: AIModel.gpt61Sol.rawValue)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            XCTAssertTrue(vm.restoreDefaultRepromptGuidance())
            XCTAssertEqual(vm.repromptGuidanceDraft, AgentRepromptGuidance.defaultText)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model", "Restoring guidance must not reset model or mode")
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptMode, .sendAutomatically)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptIncludesRecentChat, false)
            if workspaceID != nil {
                XCTAssertEqual(store.globalAgentModelsProfile(), global)
            }
        }
    }

    func testDefaultPickerPresentsConcreteConnectedSubscriptionWithoutPersistingAChoice() async throws {
        let (store, api) = try fixture()
        api.isClaudeCodeConnected = true
        await api.updateAvailableModels()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        XCTAssertEqual(vm.resolvedRepromptDraftModel, AgentRepromptModelPolicy.preferredClaude)
        let picker = AgentRepromptModelPicker(selection: Binding(get: { vm.repromptModelDraft }, set: { vm.repromptModelDraft = $0 }), availableModels: api.availableModels, resolvedModel: vm.resolvedRepromptDraftModel)
        XCTAssertEqual(picker.concreteSelection.wrappedValue, AgentRepromptModelPolicy.preferredClaude.rawValue)
        XCTAssertTrue(vm.repromptModelDraft.isEmpty)
        XCTAssertFalse(vm.isRepromptDraftDirty)
        picker.concreteSelection.wrappedValue = AIModel.gpt61SolLow.rawValue
        XCTAssertEqual(vm.repromptModelDraft, AIModel.gpt61SolLow.rawValue)
        XCTAssertTrue(vm.isRepromptDraftDirty)
    }

    func testModeAndHistoryConflictsRefuseStaleSaves() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        XCTAssertEqual(vm.repromptModeDraft, .review)
        XCTAssertTrue(vm.repromptRecentChatDraft)
        vm.repromptModeDraft = .sendAutomatically
        var external = store.globalAgentModelsProfile()
        external.agentRepromptIncludesRecentChat = false
        store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertTrue(vm.repromptDraftHasConflict)
        vm.reloadRepromptDraft()
        XCTAssertFalse(vm.repromptRecentChatDraft)
        XCTAssertEqual(vm.repromptModeDraft, .review)
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
