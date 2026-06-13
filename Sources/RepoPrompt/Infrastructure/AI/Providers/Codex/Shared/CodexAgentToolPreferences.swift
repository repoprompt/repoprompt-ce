import Foundation

enum CodexAgentToolPreferences {
    enum AppServerRequestValueStyle: CaseIterable {
        case configStyle
        case camelCase
    }

    enum ApprovalPolicy: CaseIterable {
        case onRequest
        case onFailure
        case unlessTrusted
        case never

        var displayName: String {
            switch self {
            case .onRequest:
                "On Request"
            case .onFailure:
                "On Failure"
            case .unlessTrusted:
                "Unless Trusted"
            case .never:
                "Never"
            }
        }

        var persistedValue: String {
            switch self {
            case .onRequest:
                "on-request"
            case .onFailure:
                "on-failure"
            case .unlessTrusted:
                "unless-trusted"
            case .never:
                "never"
            }
        }

        func appServerRequestValue(style: AppServerRequestValueStyle) -> String {
            switch style {
            case .configStyle:
                switch self {
                case .onRequest:
                    "on-request"
                case .onFailure:
                    "on-failure"
                case .unlessTrusted:
                    "untrusted"
                case .never:
                    "never"
                }
            case .camelCase:
                switch self {
                case .onRequest:
                    "onRequest"
                case .onFailure:
                    "onFailure"
                case .unlessTrusted:
                    "unlessTrusted"
                case .never:
                    "never"
                }
            }
        }

        var appServerConfigOverrideValue: String {
            switch self {
            case .onRequest:
                "on-request"
            case .onFailure:
                "on-failure"
            case .unlessTrusted:
                "untrusted"
            case .never:
                "never"
            }
        }

        init?(storedValue: String) {
            switch storedValue {
            case "onRequest", "on-request":
                self = .onRequest
            case "onFailure", "on-failure":
                self = .onFailure
            case "unlessTrusted", "unless-trusted", "untrusted":
                self = .unlessTrusted
            case "never":
                self = .never
            default:
                return nil
            }
        }
    }

    enum SandboxMode: CaseIterable {
        case readOnly
        case workspaceWrite
        case dangerFullAccess

        var displayName: String {
            switch self {
            case .readOnly:
                "Read Only"
            case .workspaceWrite:
                "Workspace Write"
            case .dangerFullAccess:
                "Danger Full Access"
            }
        }

        var persistedValue: String {
            switch self {
            case .readOnly:
                "read-only"
            case .workspaceWrite:
                "workspace-write"
            case .dangerFullAccess:
                "danger-full-access"
            }
        }

        func appServerRequestValue(style: AppServerRequestValueStyle) -> String {
            switch style {
            case .configStyle:
                switch self {
                case .readOnly:
                    "read-only"
                case .workspaceWrite:
                    "workspace-write"
                case .dangerFullAccess:
                    "danger-full-access"
                }
            case .camelCase:
                switch self {
                case .readOnly:
                    "readOnly"
                case .workspaceWrite:
                    "workspaceWrite"
                case .dangerFullAccess:
                    "dangerFullAccess"
                }
            }
        }

        var appServerConfigOverrideValue: String {
            switch self {
            case .readOnly:
                "read-only"
            case .workspaceWrite:
                "workspace-write"
            case .dangerFullAccess:
                "danger-full-access"
            }
        }

        init?(storedValue: String) {
            switch storedValue {
            case "readOnly", "read-only":
                self = .readOnly
            case "workspaceWrite", "workspace-write":
                self = .workspaceWrite
            case "dangerFullAccess", "danger-full-access":
                self = .dangerFullAccess
            default:
                return nil
            }
        }
    }

    enum ApprovalReviewer: CaseIterable {
        case user
        case autoReview

        var displayName: String {
            switch self {
            case .user:
                "User"
            case .autoReview:
                "Auto Review"
            }
        }

        var persistedValue: String {
            switch self {
            case .user:
                "user"
            case .autoReview:
                "auto-review"
            }
        }

        var appServerRequestValue: String {
            switch self {
            case .user:
                "user"
            case .autoReview:
                // Codex accepts both auto_review and guardian_subagent; send the legacy value for older app-server builds.
                "guardian_subagent"
            }
        }

        var appServerConfigOverrideValue: String {
            appServerRequestValue
        }

        init?(storedValue: String) {
            switch storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "user":
                self = .user
            case "autoreview", "auto-review", "auto_review", "guardian_subagent", "guardiansubagent":
                self = .autoReview
            default:
                return nil
            }
        }
    }

    enum PermissionLevel: String, CaseIterable {
        case readOnly
        case defaultPermission
        case autoReview
        case fullAccess

        var displayName: String {
            switch self {
            case .readOnly: "Read Only"
            case .defaultPermission: "Default"
            case .autoReview: "Auto Review"
            case .fullAccess: "Full Access"
            }
        }

        var iconName: String {
            switch self {
            case .readOnly: "lock.shield"
            case .defaultPermission: "shield"
            case .autoReview: "checkmark.shield"
            case .fullAccess: "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        var approvalPolicy: ApprovalPolicy {
            switch self {
            case .readOnly, .defaultPermission, .autoReview: .onRequest
            case .fullAccess: .never
            }
        }

        var sandboxMode: SandboxMode {
            switch self {
            case .readOnly: .readOnly
            case .defaultPermission, .autoReview: .workspaceWrite
            case .fullAccess: .dangerFullAccess
            }
        }

        var approvalReviewer: ApprovalReviewer {
            switch self {
            case .autoReview: .autoReview
            case .readOnly, .defaultPermission, .fullAccess: .user
            }
        }

        static func from(sandbox: SandboxMode) -> PermissionLevel {
            from(sandbox: sandbox, approvalReviewer: .user)
        }

        static func from(sandbox: SandboxMode, approvalReviewer: ApprovalReviewer) -> PermissionLevel {
            switch sandbox {
            case .readOnly: .readOnly
            case .workspaceWrite: approvalReviewer == .autoReview ? .autoReview : .defaultPermission
            case .dangerFullAccess: .fullAccess
            }
        }
    }

    struct Snapshot {
        let bashToolEnabled: Bool
        let searchToolEnabled: Bool
        let approvalPolicy: ApprovalPolicy
        let sandboxMode: SandboxMode
        let approvalReviewer: ApprovalReviewer
        let enabledMCPServerNames: Set<String>
    }

    private static let bashToolEnabledKey = "codexAgentTools.bash.enabled"
    private static let searchToolEnabledKey = "codexAgentTools.search.enabled"
    private static let approvalPolicyKey = "codexAgentTools.bash.approvalPolicy"
    private static let sandboxModeKey = "codexAgentTools.bash.sandboxMode"
    private static let approvalReviewerKey = "codexAgentTools.approvalsReviewer"
    private static let mcpServerTogglesKey = "codexAgentTools.mcpServerToggles"
    private static let lastUsedReasoningEffortKey = "codexAgent.reasoning.lastUsedEffort"
    private static let legacyLastUsedReasoningEffortKey = "agentMode.codex.lastUsedReasoningEffort"
    private static let lastUsedReasoningEffortByModelSlugKey = "codexAgent.reasoning.lastUsedEffortByModelSlug"

    static func snapshot(
        for entries: [MCPIntegrationHelper.CodexServerEntry],
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Snapshot {
        Snapshot(
            bashToolEnabled: bashToolEnabled(defaults: defaults, secureStore: secureStore),
            searchToolEnabled: searchToolEnabled(defaults: defaults),
            approvalPolicy: approvalPolicy(defaults: defaults, secureStore: secureStore),
            sandboxMode: sandboxMode(defaults: defaults, secureStore: secureStore),
            approvalReviewer: approvalReviewer(defaults: defaults, secureStore: secureStore),
            enabledMCPServerNames: enabledMCPServerNames(for: entries, defaults: defaults, secureStore: secureStore)
        )
    }

    static func bashToolEnabled(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Bool {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().bashToolEnabled ?? false
        }
        if defaults.object(forKey: bashToolEnabledKey) == nil {
            // Keep legacy behavior for now. When enabled, upstream shell/unified-exec interception
            // can still surface patch activity even if include_apply_patch_tool is disabled.
            return true
        }
        return defaults.bool(forKey: bashToolEnabledKey)
    }

    static func setBashToolEnabled(
        _ isEnabled: Bool,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateCodexPermissions { document in
                document.bashToolEnabled = isEnabled
            }
            return
        }
        defaults.set(isEnabled, forKey: bashToolEnabledKey)
    }

    static func searchToolEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: searchToolEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: searchToolEnabledKey)
    }

    static func setSearchToolEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: searchToolEnabledKey)
    }

    static func approvalPolicy(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> ApprovalPolicy {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().approvalPolicy()
        }
        guard let raw = defaults.string(forKey: approvalPolicyKey),
              let policy = ApprovalPolicy(storedValue: raw)
        else {
            return .onRequest
        }
        return policy
    }

    static func setApprovalPolicy(
        _ policy: ApprovalPolicy,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateCodexPermissions { document in
                document.approvalPolicyRaw = policy.persistedValue
            }
            return
        }
        defaults.set(policy.persistedValue, forKey: approvalPolicyKey)
    }

    static func sandboxMode(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> SandboxMode {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().sandboxMode()
        }
        guard let raw = defaults.string(forKey: sandboxModeKey),
              let mode = SandboxMode(storedValue: raw)
        else {
            return .workspaceWrite
        }
        return mode
    }

    static func setSandboxMode(
        _ mode: SandboxMode,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateCodexPermissions { document in
                document.sandboxModeRaw = mode.persistedValue
            }
            return
        }
        defaults.set(mode.persistedValue, forKey: sandboxModeKey)
    }

    static func approvalReviewer(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> ApprovalReviewer {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().approvalReviewer()
        }
        guard let raw = defaults.string(forKey: approvalReviewerKey),
              let reviewer = ApprovalReviewer(storedValue: raw)
        else {
            return .autoReview
        }
        return reviewer
    }

    static func setApprovalReviewer(
        _ reviewer: ApprovalReviewer,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateCodexPermissions { document in
                document.approvalReviewerRaw = reviewer.persistedValue
            }
            return
        }
        defaults.set(reviewer.persistedValue, forKey: approvalReviewerKey)
    }

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().permissionLevel()
        }
        return PermissionLevel.from(
            sandbox: sandboxMode(defaults: defaults),
            approvalReviewer: approvalReviewer(defaults: defaults)
        )
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setCodexPermissionLevel(level)
            return
        }
        setApprovalPolicy(level.approvalPolicy, defaults: defaults)
        setSandboxMode(level.sandboxMode, defaults: defaults)
        setApprovalReviewer(level.approvalReviewer, defaults: defaults)
    }

    static func lastUsedReasoningEffort(defaults: UserDefaults = .standard) -> CodexReasoningEffort? {
        if let raw = defaults.string(forKey: lastUsedReasoningEffortKey) {
            return CodexReasoningEffort.parse(raw)
        }
        guard let legacyRaw = defaults.string(forKey: legacyLastUsedReasoningEffortKey),
              let legacyEffort = CodexReasoningEffort.parse(legacyRaw)
        else {
            return nil
        }
        defaults.set(legacyEffort.rawValue, forKey: lastUsedReasoningEffortKey)
        defaults.removeObject(forKey: legacyLastUsedReasoningEffortKey)
        return legacyEffort
    }

    static func setLastUsedReasoningEffort(
        _ effort: CodexReasoningEffort?,
        defaults: UserDefaults = .standard
    ) {
        guard let effort else {
            defaults.removeObject(forKey: lastUsedReasoningEffortKey)
            return
        }
        defaults.set(effort.rawValue, forKey: lastUsedReasoningEffortKey)
    }

    static func reasoningEffortPreferenceSlug(forModelRaw rawModel: String?) -> String {
        let trimmed = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else {
            return AgentModel.defaultModel.rawValue
        }
        let serviceTierAwareBaseID = CodexServiceTierVariantCatalog.serviceTierAwareBaseID(for: trimmed)
        let normalized = serviceTierAwareBaseID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? AgentModel.defaultModel.rawValue : normalized
    }

    static func lastUsedReasoningEffortsByModelSlug(
        defaults: UserDefaults = .standard
    ) -> [String: CodexReasoningEffort] {
        rawLastUsedReasoningEffortsByModelSlug(defaults: defaults).reduce(into: [:]) { result, entry in
            if let effort = CodexReasoningEffort.parse(entry.value) {
                result[entry.key] = effort
            }
        }
    }

    static func lastUsedReasoningEffort(
        forModelRaw modelRaw: String?,
        defaults: UserDefaults = .standard
    ) -> CodexReasoningEffort? {
        let slug = reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        if let rawValue = rawLastUsedReasoningEffortsByModelSlug(defaults: defaults)[slug],
           let effort = CodexReasoningEffort.parse(rawValue)
        {
            return effort
        }
        return lastUsedReasoningEffort(defaults: defaults)
    }

    static func setLastUsedReasoningEffort(
        _ effort: CodexReasoningEffort?,
        forModelRaw modelRaw: String?,
        defaults: UserDefaults = .standard
    ) {
        let slug = reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        var stored = rawLastUsedReasoningEffortsByModelSlug(defaults: defaults)
        guard let effort else {
            stored.removeValue(forKey: slug)
            defaults.set(stored, forKey: lastUsedReasoningEffortByModelSlugKey)
            return
        }
        stored[slug] = effort.rawValue
        defaults.set(stored, forKey: lastUsedReasoningEffortByModelSlugKey)
        setLastUsedReasoningEffort(effort, defaults: defaults)
    }

    private static func rawLastUsedReasoningEffortsByModelSlug(defaults: UserDefaults) -> [String: String] {
        guard let dictionary = defaults.dictionary(forKey: lastUsedReasoningEffortByModelSlugKey) else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            guard let rawValue = entry.value as? String else { return }
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            result[key] = rawValue
        }
    }

    static func mcpServerEnabled(
        normalizedName: String,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Bool {
        if isRepoPromptServer(normalizedName) {
            return true
        }
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.codexPermissions().mcpServerEnabled(normalizedName: normalizedName)
        }
        let key = normalizedKey(normalizedName)
        return storedMCPServerToggles(defaults: defaults)[key] ?? false
    }

    static func setMCPServerEnabled(
        normalizedName: String,
        isEnabled: Bool,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if isRepoPromptServer(normalizedName) {
            return
        }
        let key = normalizedKey(normalizedName)
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateCodexPermissions { document in
                var toggles = document.mcpServerTogglesByNormalizedName ?? [:]
                toggles[key] = isEnabled
                document.mcpServerTogglesByNormalizedName = toggles
            }
            return
        }
        var toggles = storedMCPServerToggles(defaults: defaults)
        toggles[key] = isEnabled
        defaults.set(toggles, forKey: mcpServerTogglesKey)
    }

    static func enabledMCPServerNames(
        for entries: [MCPIntegrationHelper.CodexServerEntry],
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Set<String> {
        var enabled: Set<String> = [MCPIntegrationHelper.repoPromptMCPServerName]
        for entry in entries {
            if mcpServerEnabled(normalizedName: entry.normalizedName, defaults: defaults, secureStore: secureStore) {
                enabled.insert(entry.normalizedName)
            }
        }
        return enabled
    }

    private static func storedMCPServerToggles(defaults: UserDefaults) -> [String: Bool] {
        guard let raw = defaults.dictionary(forKey: mcpServerTogglesKey) else {
            return [:]
        }
        var mapped: [String: Bool] = [:]
        mapped.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let boolValue = value as? Bool {
                mapped[normalizedKey(key)] = boolValue
            }
        }
        return mapped
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private static func isRepoPromptServer(_ normalizedName: String) -> Bool {
        normalizedName.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
    }
}
