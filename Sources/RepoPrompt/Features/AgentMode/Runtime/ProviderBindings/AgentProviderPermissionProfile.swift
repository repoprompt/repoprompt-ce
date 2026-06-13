import Foundation

/// Source of effective provider permissions for Agent Mode runs.
///
/// User-configured runs read the existing provider preference wrappers. MCP-originated
/// runs use the sub-agent permission policy: Safe Managed by default, optional inherited
/// provider settings, or one concrete provider-native override without mutating direct-agent
/// preferences.
enum AgentProviderPermissionProfile: Equatable {
    case userConfigured
    case mcpSafeDefaults
    case providerOverride(AgentProviderPermissionLevelID)
}

// MARK: - Compatibility helpers

extension AgentProviderPermissionProfile {
    var codexSandboxMode: CodexAgentToolPreferences.SandboxMode {
        switch self {
        case .userConfigured:
            CodexAgentToolPreferences.sandboxMode()
        case .mcpSafeDefaults:
            CodexAgentToolPreferences.PermissionLevel.autoReview.sandboxMode
        case let .providerOverride(.codex(level)):
            level.sandboxMode
        case .providerOverride:
            CodexAgentToolPreferences.PermissionLevel.defaultPermission.sandboxMode
        }
    }

    var codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy {
        switch self {
        case .userConfigured:
            CodexAgentToolPreferences.approvalPolicy()
        case .mcpSafeDefaults:
            CodexAgentToolPreferences.PermissionLevel.autoReview.approvalPolicy
        case let .providerOverride(.codex(level)):
            level.approvalPolicy
        case .providerOverride:
            CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalPolicy
        }
    }

    var codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer {
        switch self {
        case .userConfigured:
            CodexAgentToolPreferences.approvalReviewer()
        case .mcpSafeDefaults:
            CodexAgentToolPreferences.PermissionLevel.autoReview.approvalReviewer
        case let .providerOverride(.codex(level)):
            level.approvalReviewer
        case .providerOverride:
            CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalReviewer
        }
    }

    func codexBashToolEnabled(
        userConfigured: Bool = CodexAgentToolPreferences.bashToolEnabled()
    ) -> Bool {
        switch self {
        case .mcpSafeDefaults:
            true
        case .userConfigured, .providerOverride:
            userConfigured
        }
    }

    var codexSuppressesThirdPartyMCPServers: Bool {
        switch self {
        case .mcpSafeDefaults:
            true
        case .userConfigured, .providerOverride:
            false
        }
    }

    func codexPermissionLevel(
        userConfigured: CodexAgentToolPreferences.PermissionLevel = CodexAgentToolPreferences.permissionLevel()
    ) -> CodexAgentToolPreferences.PermissionLevel {
        switch self {
        case .userConfigured: userConfigured
        case .mcpSafeDefaults: .autoReview
        case let .providerOverride(.codex(level)): level
        case .providerOverride: .defaultPermission
        }
    }

    var claudePermissionMode: String {
        switch self {
        case .userConfigured:
            ClaudeAgentToolPreferences.permissionMode()
        case .mcpSafeDefaults:
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        case let .providerOverride(.claude(level)):
            level.permissionMode
        case .providerOverride:
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        }
    }

    func claudePermissionLevel(
        userConfigured: ClaudeAgentToolPreferences.PermissionLevel = ClaudeAgentToolPreferences.permissionLevel()
    ) -> ClaudeAgentToolPreferences.PermissionLevel {
        switch self {
        case .userConfigured: userConfigured
        case .mcpSafeDefaults: .requireApproval
        case let .providerOverride(.claude(level)): level
        case .providerOverride: .requireApproval
        }
    }

    var openCodeSessionModeID: String {
        switch self {
        case .userConfigured:
            OpenCodeAgentToolPreferences.sessionModeID()
        case .mcpSafeDefaults:
            OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID
        case let .providerOverride(.openCode(level)):
            level.sessionModeID
        case .providerOverride:
            OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID
        }
    }

    func openCodePermissionLevel(
        userConfigured: OpenCodeAgentToolPreferences.PermissionLevel = OpenCodeAgentToolPreferences.permissionLevel()
    ) -> OpenCodeAgentToolPreferences.PermissionLevel {
        switch self {
        case .userConfigured: userConfigured
        case .mcpSafeDefaults: .managedDefault
        case let .providerOverride(.openCode(level)): level
        case .providerOverride: .managedDefault
        }
    }

    func cursorPermissionLevel(
        userConfigured: CursorAgentToolPreferences.PermissionLevel = CursorAgentToolPreferences.permissionLevel()
    ) -> CursorAgentToolPreferences.PermissionLevel {
        switch self {
        case .userConfigured: userConfigured
        case .mcpSafeDefaults: .managedDefault
        case let .providerOverride(.cursor(level)): level
        case .providerOverride: .managedDefault
        }
    }

    func acpSessionModeID(for agent: AgentProviderKind) -> String? {
        switch agent {
        case .openCode:
            openCodeSessionModeID
        case .cursor:
            nil
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
            nil
        }
    }
}
