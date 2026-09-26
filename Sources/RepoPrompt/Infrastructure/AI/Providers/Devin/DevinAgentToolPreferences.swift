import Foundation

enum DevinAgentToolPreferences {
    /// Top-level `devin --permission-mode` option, verified against devin 3000.10.21:
    /// "auto" auto-approves read-only tools, "accept-edits" also auto-approves workspace
    /// edits, "smart" additionally auto-runs actions a fast model judges safe, and
    /// "dangerous" auto-approves all tools. `autonomous` is intentionally excluded: it
    /// requires `--sandbox`, which this integration does not launch with.
    static let permissionModeArgumentName = "--permission-mode"

    /// The only ACP mode RepoPrompt treats as an escalation that removes every approval prompt.
    static let bypassSessionModeID = "bypass"

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
                "No ACP mode or permission flag is selected; Devin uses its configured default and decides when to ask."
            case .normal:
                "No ACP mode is selected; Devin's configured default applies. Unattended one-shot runs use `--permission-mode auto`."
            case .acceptEdits:
                "Selects Accept Edits over ACP when this Devin runtime advertises it; workspace edits are accepted automatically, other actions still ask."
            case .smart:
                "Selects Smart over ACP when this Devin runtime advertises it; Devin additionally auto-runs actions it judges safe."
            case .fullApproval:
                "Selects Bypass Permissions over ACP when this Devin runtime advertises it. Unattended one-shot runs, including Oracle, use `--permission-mode dangerous` because they cannot ask."
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

        /// The ACP session mode for an unattended run, mirroring `unattendedCLIPermissionMode`.
        ///
        /// Only an explicitly configured Full Approval escalates, to `bypass`; every other
        /// level sends nothing.
        ///
        /// Sending nothing is NOT a floor. On a fresh session it leaves whatever default the
        /// agent chooses, and on a session resumed through `session/load` it leaves whatever
        /// mode that session already had — which can be a `bypass` set by an earlier run.
        /// Treating nil as a guaranteed floor is the mistake this note exists to prevent.
        ///
        /// This carrier is needed because the launch flag it mirrors is inert for `devin acp`
        /// (see `sessionModeID`), so an unattended Full Approval run never reached the level
        /// it was configured for.
        var unattendedSessionModeID: String? {
            switch self {
            case .fullApproval:
                DevinAgentToolPreferences.bypassSessionModeID
            case .providerDefault, .normal, .acceptEdits, .smart:
                nil
            }
        }

        /// The `--permission-mode` an unattended launch may use for this configured level.
        /// Unattended runs cannot surface approval prompts — the headless bridge declines
        /// them — so only an explicit Full Approval escalates; intermediate levels like
        /// `smart` presume a person answers the residual prompts, and mapping them to `auto`
        /// keeps unattended behaviour deterministic.
        ///
        /// This value only reaches argv. `devin acp` ignores it entirely, so for headless ACP
        /// runs the effective level comes from `unattendedSessionModeID`, not from here. Whether
        /// the one-shot CLI path acts on it is not established; it is validated there, which is
        /// not the same as being honoured, so this should not be read as a guaranteed floor.
        var unattendedCLIPermissionMode: String {
            switch self {
            case .fullApproval:
                "dangerous"
            case .providerDefault, .normal, .acceptEdits, .smart:
                "auto"
            }
        }

        /// The ACP session mode for this level, or nil when Devin advertises no equivalent.
        ///
        /// `--permission-mode` is a top-level flag that the `acp` subcommand does not consume:
        /// a session started as `devin --permission-mode dangerous acp` reports
        /// `mode.currentValue == "accept-edits"`, identical to launching with no flag at all.
        /// The mode has to be set over ACP instead, which is how every other ACP provider here
        /// already does it. Mode availability is host-, account-, and policy-dependent: the
        /// controller applies a requested value only when that runtime advertises it and never
        /// substitutes another mode.
        ///
        /// `normal` and `providerDefault` stay nil deliberately: Devin's ACP mode vocabulary has
        /// no `normal`/`auto` member, so there is nothing to map them to without guessing.
        ///
        /// Sending nothing is not a downgrade. On a session resumed through `session/load` the
        /// previous mode survives, so a level that maps to nil cannot bring an earlier
        /// escalation back down. That gap is open and tracked, not resolved here.
        var sessionModeID: String? {
            switch self {
            case .providerDefault, .normal:
                nil
            case .acceptEdits:
                "accept-edits"
            case .smart:
                "smart"
            case .fullApproval:
                DevinAgentToolPreferences.bypassSessionModeID
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

    /// Resolves the `--permission-mode` for unattended launches from the configured level:
    /// explicit Full Approval → `dangerous`, everything else → `auto`. See
    /// `PermissionLevel.unattendedCLIPermissionMode` for the security posture.
    static func unattendedLaunchPermissionMode(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> String {
        permissionLevel(defaults: defaults, secureStore: secureStore).unattendedCLIPermissionMode
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
