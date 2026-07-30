import Foundation

/// Centralizes Codex Agent Mode boolean preferences that use GlobalSettingsStore in
/// app-standard contexts and legacy UserDefaults shims in injected-defaults tests.
enum CodexAgentModeBooleanPreference {
    case goalSupport
    case reasoningSummaries

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
        }
    }

    @MainActor
    private func isEnabledInGlobalSettingsStore() -> Bool {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.codexGoalSupportEnabled()
        case .reasoningSummaries:
            GlobalSettingsStore.shared.codexReasoningSummariesEnabled()
        }
    }

    @MainActor
    private func setEnabledInGlobalSettingsStore(_ enabled: Bool) {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.setCodexGoalSupportEnabled(enabled)
        case .reasoningSummaries:
            GlobalSettingsStore.shared.setCodexReasoningSummariesEnabled(enabled)
        }
    }
}
