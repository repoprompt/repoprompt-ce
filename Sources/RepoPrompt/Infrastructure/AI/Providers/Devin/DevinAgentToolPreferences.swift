import Foundation

enum DevinAgentToolPreferences {
    /// Top-level `devin --permission-mode` option, verified against devin 3000.10.21:
    /// "auto" auto-approves read-only tools, "accept-edits" also auto-approves workspace
    /// edits, "smart" additionally auto-runs actions a fast model judges safe, and
    /// "dangerous" auto-approves all tools. `autonomous` is intentionally excluded: it
    /// requires `--sandbox`, which this integration does not launch with.
    static let permissionModeArgumentName = "--permission-mode"

    /// Picker order is `allCases` order.
    enum PermissionLevel: String, CaseIterable {
        case providerDefault
        case normal
        case acceptEdits
        case smart
        case fullApproval

        var displayName: String {
            switch self {
            case .providerDefault:
                "Provider Default"
            case .normal:
                "Normal"
            case .acceptEdits:
                "Accept Edits"
            case .smart:
                "Smart"
            case .fullApproval:
                "Full Approval"
            }
        }

        var detailText: String {
            switch self {
            case .providerDefault:
                "No permission flag is passed; Devin uses its own configured default and decides when to ask. Applies to newly started Devin processes."
            case .normal:
                "Starts Devin with `--permission-mode auto`; Devin auto-approves read-only tools and asks before actions that need approval. Applies to newly started Devin processes."
            case .acceptEdits:
                "Starts Devin with `--permission-mode accept-edits`; workspace edits are accepted automatically, other actions still ask. Applies to newly started Devin processes."
            case .smart:
                "Starts Devin with `--permission-mode smart`; Devin additionally auto-runs actions a fast model judges safe. Applies to newly started Devin processes."
            case .fullApproval:
                "Starts Devin with `--permission-mode dangerous`; Devin runs tools without approval prompts. Applies to newly started Devin processes."
            }
        }

        var iconName: String {
            switch self {
            case .providerDefault:
                "shield"
            case .normal:
                "shield.lefthalf.filled"
            case .acceptEdits:
                "pencil"
            case .smart:
                "sparkles"
            case .fullApproval:
                "exclamationmark.shield.fill"
            }
        }

        /// Only `fullApproval` removes every approval prompt.
        var isWarning: Bool {
            self == .fullApproval
        }

        /// Value passed to `devin --permission-mode`; `nil` means "pass no flag".
        var cliPermissionMode: String? {
            switch self {
            case .providerDefault:
                nil
            case .normal:
                "auto"
            case .acceptEdits:
                "accept-edits"
            case .smart:
                "smart"
            case .fullApproval:
                "dangerous"
            }
        }

        var launchArguments: [String] {
            guard let mode = cliPermissionMode else { return [] }
            return [DevinAgentToolPreferences.permissionModeArgumentName, mode]
        }

        /// Missing/blank values mean the explicit provider default. Unknown stored values
        /// fail closed to Normal instead of delegating to a potentially broader Devin default.
        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .providerDefault
            }
            return allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) ?? .normal
        }

        /// Reverse mapping used by the provider and controller. Missing/blank means the
        /// explicit provider default; unrecognized non-empty values remain distinguishable
        /// because callers must reject them before launch/reuse.
        static func from(cliPermissionMode: String?) -> PermissionLevel {
            guard let raw = cliPermissionMode?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let level = allCases.first(where: { $0.cliPermissionMode?.lowercased() == raw.lowercased() })
            else {
                return .providerDefault
            }
            return level
        }

        static func isRecognizedCLIPermissionMode(_ mode: String?) -> Bool {
            guard let raw = mode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return true
            }
            return allCases.contains { $0.cliPermissionMode?.caseInsensitiveCompare(raw) == .orderedSame }
        }
    }

    private static let permissionLevelKey = "devinPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let document = secureStore.devinPermissions()
            if secureStore.diagnostic(for: .devin) != nil {
                return .normal
            }
            return document.permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setDevinPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
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
