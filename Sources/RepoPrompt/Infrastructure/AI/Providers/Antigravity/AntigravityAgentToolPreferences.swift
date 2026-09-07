import Foundation

enum AntigravityAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable, Hashable {
        case `default`
        case autoEdit = "auto_edit"
        case yolo

        var displayName: String {
            switch self {
            case .default: "Default"
            case .autoEdit: "Auto Edit"
            case .yolo: "Yolo"
            }
        }

        var detailText: String {
            switch self {
            case .default: "Antigravity decides when tool approval is required."
            case .autoEdit: "Antigravity can edit files while retaining approval safeguards."
            case .yolo: "Antigravity runs available tools without approval prompts."
            }
        }

        var iconName: String {
            self == .yolo ? "exclamationmark.shield.fill" : "shield"
        }

        var isWarning: Bool {
            self == .yolo
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .autoEdit
            }
            return PermissionLevel(rawValue: raw.lowercased()) ?? .autoEdit
        }
    }

    private static let key = "antigravityACPAgentMode"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.antigravityPermissions().permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: key))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setAntigravityPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: key)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
