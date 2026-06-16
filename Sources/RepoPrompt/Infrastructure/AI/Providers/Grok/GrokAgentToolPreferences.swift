import Foundation

enum GrokAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable {
        case alwaysApprove
        case managedDefault

        var displayName: String {
            switch self {
            case .alwaysApprove:
                "Always Approve"
            case .managedDefault:
                "Default"
            }
        }

        var detailText: String {
            switch self {
            case .alwaysApprove:
                "Grok Build launches with `--always-approve` and RepoPrompt auto-approves ACP tool permissions."
            case .managedDefault:
                "Grok may prompt before running tools that need approval. RepoPrompt MCP is injected through the ACP session."
            }
        }

        var iconName: String {
            switch self {
            case .alwaysApprove:
                "checkmark.shield.fill"
            case .managedDefault:
                "shield"
            }
        }

        var isWarning: Bool {
            self == .alwaysApprove
        }

        var autoApprovesACPToolPermissions: Bool {
            self == .alwaysApprove
        }

        var launchesWithAlwaysApproveCLIArg: Bool {
            self == .alwaysApprove
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .alwaysApprove
            }
            switch raw.lowercased() {
            case PermissionLevel.alwaysApprove.rawValue.lowercased():
                return .alwaysApprove
            case PermissionLevel.managedDefault.rawValue.lowercased():
                return .managedDefault
            default:
                return .alwaysApprove
            }
        }
    }

    private static let permissionLevelKey = "grokACPToolPermissionLevel"

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