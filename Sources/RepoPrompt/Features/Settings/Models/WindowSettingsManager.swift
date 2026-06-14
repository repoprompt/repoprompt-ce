import Foundation
import SwiftUI

// MARK: - Settings Managing Protocol

/// Protocol defining the interface for settings management.
/// This allows for dependency injection and testing.
@MainActor
protocol SettingsManaging {
    func copySettings(for workspaceID: UUID) -> CopyGlobalSettings
    func chatSettings(for workspaceID: UUID) -> ChatGlobalSettings
    func updateCopySettings(_ settings: CopyGlobalSettings, commit: Bool?)
    func updateChatSettings(_ settings: ChatGlobalSettings, commit: Bool?)
    func globalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?)
    func persistedGlobalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?)
    func setGlobalContextBuilderAgentSelection(agentRaw: String, modelRaw: String, markUserDefined: Bool)
    func globalRecommendationProviderFilter() -> Set<RecommendationProviderKind>
    func promptSectionsOrderRaw() -> String
    func setPromptSectionsOrderRaw(_ raw: String, commit: Bool)
    func duplicateUserInstructionsAtTop() -> Bool
    func setDuplicateUserInstructionsAtTop(_ enabled: Bool, commit: Bool)
    func filePathDisplayOptionRaw() -> String
    func setFilePathDisplayOptionRaw(_ raw: String, commit: Bool)
    func selectedFilesSortMethodRaw() -> String
    func setSelectedFilesSortMethodRaw(_ raw: String, commit: Bool)
    func fileEditFormatRaw() -> String
    func setFileEditFormatRaw(_ raw: String, commit: Bool)
    func includeDatetimeInUserInstructions() -> Bool
    func setIncludeDatetimeInUserInstructions(_ enabled: Bool, commit: Bool)
    func customPlanningPrompt() -> String
    func setCustomPlanningPrompt(_ prompt: String, commit: Bool)
    func modelTemperature() -> Double
    func setModelTemperature(_ temperature: Double, commit: Bool)
    func shouldSetModelTemperature() -> Bool
    func setShouldSetModelTemperature(_ enabled: Bool, commit: Bool)
    func complexEditStrategyRaw() -> String
    func setComplexEditStrategyRaw(_ raw: String, commit: Bool)
    func preferredComposeModelRaw() -> String?
    func setPreferredComposeModelRaw(_ raw: String?, commit: Bool, reason: String?, honorSync: Bool)
    func planningModelRaw() -> String?
    func setPlanningModelRaw(_ raw: String?, commit: Bool, reason: String?, honorSync: Bool)
    func syncChatModelWithOracle() -> Bool
    func maxBackgroundAgentComposeTabs() -> Int
    func commitWorkspace(_ workspaceID: UUID)
    func discardWindowOverrides(for workspaceID: UUID)
    func commitAllVisitedWorkspaces()
}

// MARK: - Window Settings Manager

/// Per-window settings manager that maintains an in-memory overlay of settings.
/// Each window gets its own instance, providing isolation between windows.
/// Changes are stored in the overlay by default and can be explicitly committed
/// to the global store to become workspace defaults.
@MainActor
final class WindowSettingsManager: ObservableObject, SettingsManaging {
    let windowID: Int
    private let store: GlobalSettingsStore

    // Overlay per workspace for THIS WINDOW ONLY
    @Published private var copyOverlays: [UUID: CopyGlobalSettings] = [:]
    @Published private var chatOverlays: [UUID: ChatGlobalSettings] = [:]

    // Policy: off by default to ensure isolation. Can be surfaced in Settings UI.
    @AppStorage("autoPersistWindowSettings") private var autoPersistWindowSettings: Bool = false

    init(windowID: Int, store: GlobalSettingsStore? = nil) {
        self.windowID = windowID
        self.store = store ?? .shared
    }

    // MARK: - Read (clone from persistent store on first access)

    func copySettings(for workspaceID: UUID) -> CopyGlobalSettings {
        if let s = copyOverlays[workspaceID] { return s }
        let base = store.copySettings(for: workspaceID)
        copyOverlays[workspaceID] = base
        return base
    }

    func chatSettings(for workspaceID: UUID) -> ChatGlobalSettings {
        if let s = chatOverlays[workspaceID] { return s }
        let base = store.chatSettings(for: workspaceID)
        chatOverlays[workspaceID] = base
        return base
    }

    // MARK: - Write (update overlay; optionally persist)

    /// Updates copy settings for a workspace.
    /// - Parameters:
    ///   - settings: The new settings to store
    ///   - commit: If true, persist to store immediately. If nil, use autoPersistWindowSettings policy.
    func updateCopySettings(_ settings: CopyGlobalSettings, commit: Bool? = nil) {
        copyOverlays[settings.workspaceID] = settings
        if commit ?? autoPersistWindowSettings {
            store.updateCopySettings(settings)
        }
    }

    /// Updates chat settings for a workspace.
    /// - Parameters:
    ///   - settings: The new settings to store
    ///   - commit: If true, persist to store immediately. If nil, use autoPersistWindowSettings policy.
    func updateChatSettings(_ settings: ChatGlobalSettings, commit: Bool? = nil) {
        chatOverlays[settings.workspaceID] = settings
        if commit ?? autoPersistWindowSettings {
            store.updateChatSettings(settings)
        }
    }

    func globalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
        store.globalContextBuilderAgentSelection()
    }

    func persistedGlobalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
        store.persistedGlobalContextBuilderAgentSelection()
    }

    func setGlobalContextBuilderAgentSelection(agentRaw: String, modelRaw: String, markUserDefined: Bool = true) {
        store.setGlobalContextBuilderAgentSelection(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            markUserDefined: markUserDefined
        )
    }

    func globalRecommendationProviderFilter() -> Set<RecommendationProviderKind> {
        store.globalRecommendationProviderFilter()
    }

    // MARK: - Scalar global settings

    func promptSectionsOrderRaw() -> String {
        store.promptSectionsOrderRaw()
    }

    func setPromptSectionsOrderRaw(_ raw: String, commit: Bool = true) {
        store.setPromptSectionsOrderRaw(raw, commit: commit)
    }

    func duplicateUserInstructionsAtTop() -> Bool {
        store.duplicateUserInstructionsAtTop()
    }

    func setDuplicateUserInstructionsAtTop(_ enabled: Bool, commit: Bool = true) {
        store.setDuplicateUserInstructionsAtTop(enabled, commit: commit)
    }

    func filePathDisplayOptionRaw() -> String {
        store.filePathDisplayOptionRaw()
    }

    func setFilePathDisplayOptionRaw(_ raw: String, commit: Bool = true) {
        store.setFilePathDisplayOptionRaw(raw, commit: commit)
    }

    func selectedFilesSortMethodRaw() -> String {
        store.selectedFilesSortMethodRaw()
    }

    func setSelectedFilesSortMethodRaw(_ raw: String, commit: Bool = true) {
        store.setSelectedFilesSortMethodRaw(raw, commit: commit)
    }

    func fileEditFormatRaw() -> String {
        store.fileEditFormatRaw()
    }

    func setFileEditFormatRaw(_ raw: String, commit: Bool = true) {
        store.setFileEditFormatRaw(raw, commit: commit)
    }

    func includeDatetimeInUserInstructions() -> Bool {
        store.includeDatetimeInUserInstructions()
    }

    func setIncludeDatetimeInUserInstructions(_ enabled: Bool, commit: Bool = true) {
        store.setIncludeDatetimeInUserInstructions(enabled, commit: commit)
    }

    func customPlanningPrompt() -> String {
        store.customPlanningPrompt()
    }

    func setCustomPlanningPrompt(_ prompt: String, commit: Bool = true) {
        store.setCustomPlanningPrompt(prompt, commit: commit)
    }

    func modelTemperature() -> Double {
        store.modelTemperature()
    }

    func setModelTemperature(_ temperature: Double, commit: Bool = true) {
        store.setModelTemperature(temperature, commit: commit)
    }

    func shouldSetModelTemperature() -> Bool {
        store.shouldSetModelTemperature()
    }

    func setShouldSetModelTemperature(_ enabled: Bool, commit: Bool = true) {
        store.setShouldSetModelTemperature(enabled, commit: commit)
    }

    func complexEditStrategyRaw() -> String {
        store.complexEditStrategyRaw()
    }

    func setComplexEditStrategyRaw(_ raw: String, commit: Bool = true) {
        store.setComplexEditStrategyRaw(raw, commit: commit)
    }

    func preferredComposeModelRaw() -> String? {
        store.preferredComposeModelRaw()
    }

    func setPreferredComposeModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false
    ) {
        store.setPreferredComposeModelRaw(raw, commit: commit, reason: reason, honorSync: honorSync)
    }

    func planningModelRaw() -> String? {
        store.planningModelRaw()
    }

    func setPlanningModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false
    ) {
        store.setPlanningModelRaw(raw, commit: commit, reason: reason, honorSync: honorSync)
    }

    func syncChatModelWithOracle() -> Bool {
        store.syncChatModelWithOracle()
    }

    func maxBackgroundAgentComposeTabs() -> Int {
        store.maxBackgroundAgentComposeTabs()
    }

    // MARK: - Lifecycle helpers

    /// Commits all settings for a specific workspace to the global store,
    /// making them the default for that workspace across all windows.
    func commitWorkspace(_ workspaceID: UUID) {
        if let s = copyOverlays[workspaceID] { store.updateCopySettings(s) }
        if let s = chatOverlays[workspaceID] { store.updateChatSettings(s) }
    }

    /// Commits all workspace settings that have been modified in this window
    /// to the global store.
    func commitAllVisitedWorkspaces() {
        for (_, s) in copyOverlays {
            store.updateCopySettings(s)
        }
        for (_, s) in chatOverlays {
            store.updateChatSettings(s)
        }
    }

    /// Discards window-specific overrides for a workspace and reloads from
    /// the global store defaults.
    func discardWindowOverrides(for workspaceID: UUID) {
        copyOverlays[workspaceID] = store.copySettings(for: workspaceID)
        chatOverlays[workspaceID] = store.chatSettings(for: workspaceID)
    }
}
