import Foundation

enum OMPAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable {
        case providerManaged
        case plan

        var displayName: String {
            switch self {
            case .providerManaged: "Default"
            case .plan: "Plan"
            }
        }

        var detailText: String {
            switch self {
            case .providerManaged:
                "Uses OMP's default ACP session mode. OMP controls its internal tools; RepoPrompt policy applies only to RepoPrompt MCP tools."
            case .plan:
                "Requests OMP's read-only Plan session mode. OMP still controls its internal tools; RepoPrompt policy applies only to RepoPrompt MCP tools."
            }
        }

        var iconName: String {
            switch self {
            case .providerManaged: "shield"
            case .plan: "doc.text.magnifyingglass"
            }
        }

        var sessionModeID: String {
            switch self {
            case .providerManaged: "default"
            case .plan: "plan"
            }
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let rawValue else { return .providerManaged }
            return PermissionLevel(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .providerManaged
        }
    }

    private static let permissionLevelKey = "ompACPSessionMode"

    static func permissionLevel(defaults: UserDefaults = .standard) -> PermissionLevel {
        PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }
}
