import Foundation

// SEARCH-HELPER: Sub-agent Permissions, Safe Managed, AgentSubagentPermissionPolicy,
// tri-state policy, provider permission levels

/// Storage shim for sub-agent permission decisions.
///
/// Production `.standard` reads and writes are persisted through
/// `AgentPermissionSecureStore.shared` as canonical plain secure documents.
/// Custom injected `UserDefaults` suites keep deterministic tests and previews isolated.
enum AgentModePermissionPreferences {
    /// Tri-state global policy key.
    static let subagentPermissionPolicyKey = "agentMode.subagents.permissionPolicy"

    /// Prefix for concrete provider-native permission levels used by Custom sub-agent policy.
    private static let providerPermissionLevelKeyPrefix = "agentMode.subagents.providerPermissionLevel."

    // MARK: - Tri-state global policy

    static func subagentPermissionPolicy(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentSubagentPermissionPolicy {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.subagentPolicy()
        }
        return defaultsSubagentPermissionPolicy(defaults: defaults)
    }

    static func setSubagentPermissionPolicy(
        _ policy: AgentSubagentPermissionPolicy,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateSubagentPermissions { document in
                document.globalPolicyRaw = policy.rawValue
            }
            return
        }
        setDefaultsSubagentPermissionPolicy(policy, defaults: defaults)
    }

    // MARK: - Per-provider overrides (consulted when global policy == `.custom`)

    static func providerSubagentPermissionLevel(
        for providerID: AgentProviderBindingID,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentProviderPermissionLevelID {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.providerSubagentPermissionLevel(for: providerID)
        }
        return defaultsProviderSubagentPermissionLevel(for: providerID, defaults: defaults)
    }

    static func setProviderSubagentPermissionLevel(
        _ level: AgentProviderPermissionLevelID,
        for providerID: AgentProviderBindingID,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        let normalizedLevel = level.providerID == providerID
            ? level
            : AgentProviderPermissionLevelID.subagentDefault(for: providerID)
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateSubagentPermissions { document in
                var levels = document.providerPermissionLevelsRawByProviderID ?? [:]
                levels[providerID.rawValue] = normalizedLevel.subagentRawValue
                document.providerPermissionLevelsRawByProviderID = levels
            }
            return
        }
        defaults.set(normalizedLevel.subagentRawValue, forKey: providerPermissionLevelKey(for: providerID))
    }

    /// Stable storage key for a given provider's concrete Custom sub-agent mode. Exposed for tests.
    static func providerPermissionLevelKey(for providerID: AgentProviderBindingID) -> String {
        "\(providerPermissionLevelKeyPrefix)\(providerID.rawValue)"
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

    private static func defaultsSubagentPermissionPolicy(defaults: UserDefaults) -> AgentSubagentPermissionPolicy {
        if let raw = defaults.string(forKey: subagentPermissionPolicyKey),
           let value = AgentSubagentPermissionPolicy(rawValue: raw)
        {
            return value
        }
        return .safeManaged
    }

    private static func setDefaultsSubagentPermissionPolicy(
        _ policy: AgentSubagentPermissionPolicy,
        defaults: UserDefaults
    ) {
        defaults.set(policy.rawValue, forKey: subagentPermissionPolicyKey)
    }

    private static func defaultsProviderSubagentPermissionLevel(
        for providerID: AgentProviderBindingID,
        defaults: UserDefaults
    ) -> AgentProviderPermissionLevelID {
        if let raw = defaults.string(forKey: providerPermissionLevelKey(for: providerID)),
           let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw)
        {
            return level
        }
        return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
    }
}

// MARK: - Policy enums

/// Global sub-agent permission policy (A3 tri-state).
enum AgentSubagentPermissionPolicy: String, CaseIterable, Hashable {
    /// Sub-agents always run with Safe Managed overrides regardless of provider prefs.
    case safeManaged
    /// Sub-agents inherit the user's provider-configured permission settings.
    case inheritProviderSettings
    /// Per-provider concrete provider-native permission levels apply.
    case custom

    var displayName: String {
        switch self {
        case .safeManaged: "Safe Managed"
        case .inheritProviderSettings: "Inherit provider settings"
        case .custom: "Custom per provider"
        }
    }
}
