import Foundation

extension CodexIntegrationConfiguration.ServerEntry: Equatable {
    static func == (
        lhs: CodexIntegrationConfiguration.ServerEntry,
        rhs: CodexIntegrationConfiguration.ServerEntry
    ) -> Bool {
        lhs.rawName == rhs.rawName
            && lhs.normalizedName == rhs.normalizedName
            && lhs.cliPathComponent == rhs.cliPathComponent
    }
}

extension CodexIntegrationConfiguration.ServerEntry: @unchecked Sendable {}

enum AgentProviderPermissionLevelID: Hashable {
    case codex(CodexAgentToolPreferences.PermissionLevel)
    case claude(ClaudeAgentToolPreferences.PermissionLevel)
    case openCode(OpenCodeAgentToolPreferences.PermissionLevel)
    case cursor(CursorAgentToolPreferences.PermissionLevel)
    case grok(GrokAgentToolPreferences.PermissionLevel)

    var providerID: AgentProviderBindingID {
        switch self {
        case .codex:
            .codex
        case .claude:
            .claude
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .grok:
            .grok
        }
    }

    static func subagentDefault(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        switch providerID {
        case .codex:
            .codex(.defaultPermission)
        case .claude:
            .claude(.requireApproval)
        case .openCode:
            .openCode(.managedDefault)
        case .cursor:
            .cursor(.managedDefault)
        case .grok:
            .grok(.managedDefault)
        }
    }

    static func options(for providerID: AgentProviderBindingID) -> [AgentProviderPermissionLevelID] {
        switch providerID {
        case .codex:
            CodexAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.codex)
        case .claude:
            ClaudeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.claude)
        case .openCode:
            OpenCodeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.openCode)
        case .cursor:
            CursorAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.cursor)
        case .grok:
            GrokAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.grok)
        }
    }

    init?(providerID: AgentProviderBindingID, subagentRawValue: String) {
        let raw = subagentRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch providerID {
        case .codex:
            guard let level = CodexAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .codex(level)
        case .claude:
            guard let level = ClaudeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .claude(level)
        case .openCode:
            guard let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .openCode(level)
        case .cursor:
            guard let level = CursorAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .cursor(level)
        case .grok:
            guard let level = GrokAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .grok(level)
        }
    }

    var subagentRawValue: String {
        switch self {
        case let .codex(level):
            level.rawValue
        case let .claude(level):
            level.rawValue
        case let .openCode(level):
            level.rawValue
        case let .cursor(level):
            level.rawValue
        case let .grok(level):
            level.rawValue
        }
    }

    var displayName: String {
        switch self {
        case let .codex(level):
            level.displayName
        case let .claude(level):
            level.displayName
        case let .openCode(level):
            level.displayName
        case let .cursor(level):
            level.displayName
        case let .grok(level):
            level.displayName
        }
    }

    var iconName: String {
        switch self {
        case let .codex(level):
            level.iconName
        case let .claude(level):
            level.iconName
        case let .openCode(level):
            level.iconName
        case let .cursor(level):
            level.iconName
        case let .grok(level):
            level.iconName
        }
    }

    var detailText: String? {
        switch self {
        case .codex:
            nil
        case let .claude(level):
            level.detailText
        case let .openCode(level):
            level.detailText
        case let .cursor(level):
            level.detailText
        case let .grok(level):
            level.detailText
        }
    }

    var isWarning: Bool {
        switch self {
        case let .codex(level):
            level.isWarning
        case let .claude(level):
            level.isWarning
        case let .openCode(level):
            level.isWarning
        case let .cursor(level):
            level.isWarning
        case let .grok(level):
            level.isWarning
        }
    }
}

struct AgentPermissionOptionBinding: Identifiable, Equatable {
    let id: AgentProviderPermissionLevelID
    let title: String
    let iconName: String
    let detailText: String?
    let isWarning: Bool
    let isSelected: Bool
    let isEnabled: Bool
}

struct AgentPermissionChromeBinding: Equatable {
    let providerID: AgentProviderBindingID
    let displayName: String
    let iconName: String
    let isWarning: Bool
    let externallyManagedReason: String?
    let options: [AgentPermissionOptionBinding]
}

struct AgentProviderRuntimePermissionBinding: Equatable {
    let codexSandboxMode: CodexAgentToolPreferences.SandboxMode?
    let codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy?
    let codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer?
    let claudePermissionMode: String?
    let acpSessionModeID: String?
    let autoApproveAllACPToolPermissions: Bool
    let acceptsPendingACPApprovalWhenActivated: Bool

    init(
        codexSandboxMode: CodexAgentToolPreferences.SandboxMode? = nil,
        codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy? = nil,
        codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer? = nil,
        claudePermissionMode: String? = nil,
        acpSessionModeID: String? = nil,
        autoApproveAllACPToolPermissions: Bool = false,
        acceptsPendingACPApprovalWhenActivated: Bool = false
    ) {
        self.codexSandboxMode = codexSandboxMode
        self.codexApprovalPolicy = codexApprovalPolicy
        self.codexApprovalReviewer = codexApprovalReviewer
        self.claudePermissionMode = claudePermissionMode
        self.acpSessionModeID = acpSessionModeID
        self.autoApproveAllACPToolPermissions = autoApproveAllACPToolPermissions
        self.acceptsPendingACPApprovalWhenActivated = acceptsPendingACPApprovalWhenActivated
    }
}

/// Persisted Codex tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`; these
/// values intentionally mirror existing UserDefaults-backed tool preferences even when a
/// caller is rendering an externally managed or MCP-safe permission profile.
struct CodexToolSettingsBinding: Equatable {
    let bashToolEnabled: Bool
    let searchToolEnabled: Bool
    let goalSupportEnabled: Bool
    let mcpServerEntries: [MCPIntegrationHelper.CodexServerEntry]
    /// Keys are lowercased/trimmed toggle keys derived from each entry's normalized name,
    /// matching the current AgentInputBar lookup convention.
    let mcpServerStatesByNormalizedName: [String: Bool]
}

/// Persisted Claude tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`; these
/// values intentionally mirror existing UserDefaults-backed tool preferences even when a
/// caller is rendering an externally managed or MCP-safe permission profile. `effortLevel`
/// is resolved for the selected model when a model context is available.
struct ClaudeToolSettingsBinding: Equatable {
    let bashToolEnabled: Bool
    let mcpStrictModeEnabled: Bool
    let toolSearchEnabled: Bool
    let effortLevel: ClaudeCodeEffortLevel
    let agentModePromptDelivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
}

/// Complete provider controls snapshot for the selected agent/provider.
///
/// `runtimePermission` is the profile-aware launch/runtime contract. Provider-specific
/// tool snapshots are Settings/editing snapshots for direct provider controls; callers
/// that are only previewing sub-agent policy should prefer capability summaries unless
/// they explicitly need a runtime binding.
struct AgentProviderControlsBinding: Equatable {
    let revision: Int
    let selectedAgent: AgentProviderKind
    let providerID: AgentProviderBindingID
    let permission: AgentPermissionChromeBinding
    let runtimePermission: AgentProviderRuntimePermissionBinding
    let codexTools: CodexToolSettingsBinding?
    let claudeTools: ClaudeToolSettingsBinding?
}
