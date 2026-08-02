import Foundation

enum CodexMemories {
    static let defaultsKey = "enableCodexMemories"

    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexMemoriesEnabled()
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
