import Foundation

extension Notification.Name {
    static let codexReasoningSummariesDidChange = Notification.Name("RepoPrompt.codexReasoningSummariesDidChange")
}

enum CodexReasoningSummaries {
    static let defaultsKey = "enableCodexReasoningSummaries"

    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexReasoningSummariesEnabled()
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        isEnabled(persistedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }

    static func isEnabled(persistedValue: Bool) -> Bool {
        isEnabled(persistedValue: Optional(persistedValue))
    }

    static func isEnabled(persistedValue: Bool?) -> Bool {
        persistedValue ?? false
    }

    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        let oldValue = isEnabled(defaults: defaults)
        defaults.set(value, forKey: defaultsKey)
        postDidChangeIfNeeded(previousValue: oldValue, currentValue: isEnabled(defaults: defaults))
    }

    static func postDidChangeIfNeeded(previousValue: Bool, currentValue: Bool) {
        guard currentValue != previousValue else { return }
        NotificationCenter.default.post(name: .codexReasoningSummariesDidChange, object: nil)
    }
}
