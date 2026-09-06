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
    }

    private static let key = "antigravityACPAgentMode"

    static func permissionLevel(defaults: UserDefaults = .standard) -> PermissionLevel {
        guard let raw = defaults.string(forKey: key) else { return .autoEdit }
        return PermissionLevel(rawValue: raw) ?? .autoEdit
    }

    static func setPermissionLevel(_ level: PermissionLevel, defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: key)
    }
}
