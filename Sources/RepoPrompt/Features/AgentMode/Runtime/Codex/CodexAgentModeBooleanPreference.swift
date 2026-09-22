import Foundation

/// Centralizes Codex Agent Mode boolean preferences that use GlobalSettingsStore in
/// app-standard contexts and legacy UserDefaults shims in injected-defaults tests.
enum CodexAgentModeBooleanPreference {
    case goalSupport
    case reasoningSummaries
    case memories
    case apps
    case plugins
    case mcpElicitation
    case toolSuggestions

    @MainActor
    func isEnabled(defaults: UserDefaults) -> Bool {
        if defaults === UserDefaults.standard {
            return isEnabledInGlobalSettingsStore()
        }
        switch self {
        case .goalSupport:
            return CodexGoalSupport.isEnabled(defaults: defaults)
        case .reasoningSummaries:
            return CodexReasoningSummaries.isEnabled(defaults: defaults)
        case .memories:
            return CodexMemories.isEnabled(defaults: defaults)
        case .apps:
            return CodexCapabilityPreference.apps.isEnabled(defaults: defaults)
        case .plugins:
            return CodexCapabilityPreference.plugins.isEnabled(defaults: defaults)
        case .mcpElicitation:
            return CodexCapabilityPreference.mcpElicitation.isEnabled(defaults: defaults)
        case .toolSuggestions:
            return CodexCapabilityPreference.toolSuggestions.isEnabled(defaults: defaults)
        }
    }

    @MainActor
    func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        if defaults === UserDefaults.standard {
            setEnabledInGlobalSettingsStore(enabled)
            return
        }
        switch self {
        case .goalSupport:
            CodexGoalSupport.setEnabled(enabled, defaults: defaults)
        case .reasoningSummaries:
            CodexReasoningSummaries.setEnabled(enabled, defaults: defaults)
        case .memories:
            CodexMemories.setEnabled(enabled, defaults: defaults)
        case .apps:
            CodexCapabilityPreference.apps.setEnabled(enabled, defaults: defaults)
        case .plugins:
            CodexCapabilityPreference.plugins.setEnabled(enabled, defaults: defaults)
        case .mcpElicitation:
            CodexCapabilityPreference.mcpElicitation.setEnabled(enabled, defaults: defaults)
        case .toolSuggestions:
            CodexCapabilityPreference.toolSuggestions.setEnabled(enabled, defaults: defaults)
        }
    }

    @MainActor
    private func isEnabledInGlobalSettingsStore() -> Bool {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.codexGoalSupportEnabled()
        case .reasoningSummaries:
            GlobalSettingsStore.shared.codexReasoningSummariesEnabled()
        case .memories:
            GlobalSettingsStore.shared.codexMemoriesEnabled()
        case .apps:
            GlobalSettingsStore.shared.codexAppsEnabled()
        case .plugins:
            GlobalSettingsStore.shared.codexPluginsEnabled()
        case .mcpElicitation:
            GlobalSettingsStore.shared.codexMCPElicitationEnabled()
        case .toolSuggestions:
            GlobalSettingsStore.shared.codexToolSuggestionsEnabled()
        }
    }

    @MainActor
    private func setEnabledInGlobalSettingsStore(_ enabled: Bool) {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.setCodexGoalSupportEnabled(enabled)
        case .reasoningSummaries:
            GlobalSettingsStore.shared.setCodexReasoningSummariesEnabled(enabled)
        case .memories:
            GlobalSettingsStore.shared.setCodexMemoriesEnabled(enabled)
        case .apps:
            GlobalSettingsStore.shared.setCodexAppsEnabled(enabled)
        case .plugins:
            GlobalSettingsStore.shared.setCodexPluginsEnabled(enabled)
        case .mcpElicitation:
            GlobalSettingsStore.shared.setCodexMCPElicitationEnabled(enabled)
        case .toolSuggestions:
            GlobalSettingsStore.shared.setCodexToolSuggestionsEnabled(enabled)
        }
    }
}
