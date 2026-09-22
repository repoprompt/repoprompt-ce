import Foundation

enum CodexCapabilityPreference: CaseIterable {
    case apps
    case plugins
    case mcpElicitation
    case toolSuggestions

    var defaultsKey: String {
        switch self {
        case .apps:
            "enableCodexApps"
        case .plugins:
            "enableCodexPlugins"
        case .mcpElicitation:
            "enableCodexMCPElicitation"
        case .toolSuggestions:
            "enableCodexToolSuggestions"
        }
    }

    func isEnabled(defaults: UserDefaults) -> Bool {
        Self.isEnabled(persistedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }

    static func isEnabled(persistedValue: Bool?) -> Bool {
        persistedValue ?? false
    }

    func setEnabled(_ value: Bool, defaults: UserDefaults) {
        defaults.set(value, forKey: defaultsKey)
    }
}
