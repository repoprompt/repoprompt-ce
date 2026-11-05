import Foundation
import RepoPromptACPProviders

enum OpenCodeAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable {
        case managedDefault
        case fullAccess

        var displayName: String {
            switch self {
            case .managedDefault:
                "Default"
            case .fullAccess:
                "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .managedDefault:
                "OpenCode asks before running tools that need approval."
            case .fullAccess:
                "OpenCode runs available tools without approval prompts."
            }
        }

        var iconName: String {
            switch self {
            case .managedDefault:
                "shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        var acceptsPendingApprovalWhenActivated: Bool {
            self == .fullAccess
        }

        var sessionModeID: String {
            switch self {
            case .managedDefault:
                OpenCodeAgentConfig.managedSessionModeID
            case .fullAccess:
                OpenCodeAgentConfig.managedFullAccessSessionModeID
            }
        }

        static func from(sessionModeID: String) -> PermissionLevel {
            switch sessionModeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case OpenCodeAgentConfig.managedFullAccessSessionModeID:
                .fullAccess
            default:
                .managedDefault
            }
        }
    }

    private static let sessionModeKey = "openCodeACPSessionMode"

    static func sessionModeID(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> String {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.openCodePermissions().sessionModeID()
        }
        let raw = defaults.string(forKey: sessionModeKey)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return PermissionLevel.from(sessionModeID: trimmed).sessionModeID
        }
        return PermissionLevel.managedDefault.sessionModeID
    }

    static func setSessionModeID(
        _ mode: String,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = trimmed.isEmpty ? PermissionLevel.managedDefault : PermissionLevel.from(sessionModeID: trimmed)
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateOpenCodePermissions { document in
                document.permissionLevelRaw = level.rawValue
            }
            return
        }
        defaults.set(level.sessionModeID, forKey: sessionModeKey)
    }

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.openCodePermissions().permissionLevel()
        }
        return PermissionLevel.from(sessionModeID: sessionModeID(defaults: defaults))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setOpenCodePermissionLevel(level)
            return
        }
        setSessionModeID(level.sessionModeID, defaults: defaults)
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
