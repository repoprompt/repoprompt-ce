import Foundation

enum CodexConnectedApps {
    static let defaultsKey = "enableCodexConnectedApps"

    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexConnectedAppsEnabled()
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        isEnabled(persistedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }

    static func isEnabled(persistedValue: Bool?) -> Bool {
        persistedValue ?? false
    }

    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
