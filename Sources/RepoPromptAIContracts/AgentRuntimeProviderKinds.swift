import Foundation

package enum ClaudeCodeRuntimeVariant: String {
    case standard
    case glm
    case kimi
    case customCompatible

    package var agentKind: AgentProviderKind {
        switch self {
        case .standard:
            .claudeCode
        case .glm:
            .claudeCodeGLM
        case .kimi:
            .kimiCode
        case .customCompatible:
            .customClaudeCompatible
        }
    }
}

/// Supported autonomous agent providers shared by Agent Mode and Context Builder runtimes.
package enum AgentProviderKind: String, CaseIterable, Hashable {
    case claudeCode
    case codexExec
    case openCode
    case cursor
    case grokBuild
    case antigravity
    case devin
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible

    package static let claudeMCPClientID = "claude-code"
    package static let codexMCPClientID = "codex-mcp-client"
    package static let openCodeMCPClientID = "opencode"
    /// Cursor's ACP MCP child reports this exact initialize name; pending discovery contexts use exact keys.
    package static let cursorMCPClientID = "Cursor"
    /// Devin's built-in Rust MCP client reports this exact initialize name.
    package static let devinMCPClientID = "rmcp"
    package var commandName: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude"
        case .codexExec:
            "codex"
        case .openCode:
            "opencode"
        case .cursor:
            "cursor-agent"
        case .grokBuild:
            "grok"
        case .antigravity:
            "agy_acp_server.par"
        case .devin:
            "devin"
        }
    }

    package var acpProviderID: ACPProviderID? {
        switch self {
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .grokBuild:
            .grokBuild
        case .antigravity:
            .antigravity
        case .devin:
            .devin
        case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            nil
        }
    }

    package var usesClaudeNativeRuntime: Bool {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        case .codexExec, .openCode, .cursor, .grokBuild, .antigravity, .devin:
            false
        }
    }

    package var usesClaudeTooling: Bool {
        usesClaudeNativeRuntime
    }

    package var requiresExpectedPIDOwnedAgentModeMCPRouting: Bool {
        switch self {
        case .claudeCode, .codexExec, .openCode, .cursor, .grokBuild, .antigravity, .devin, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        }
    }

    package var requiresPrePromptAgentModeMCPRouting: Bool {
        switch self {
        case .cursor, .grokBuild, .antigravity:
            false
        case .claudeCode, .codexExec, .openCode, .devin, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        }
    }

    /// Stable runtime kind identifier for MCP discovery (list_agents).
    package var runtimeKind: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude_native"
        case .codexExec:
            "codex_native"
        case .antigravity:
            "antigravity_acp"
        case .openCode:
            "opencode_acp"
        case .cursor:
            "cursor_acp"
        case .grokBuild:
            "grok_build_acp"
        case .devin:
            "devin_acp"
        }
    }

    package var claudeRuntimeVariant: ClaudeCodeRuntimeVariant? {
        switch self {
        case .claudeCode:
            .standard
        case .claudeCodeGLM:
            .glm
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .customCompatible
        case .codexExec, .openCode, .cursor, .grokBuild, .antigravity, .devin:
            nil
        }
    }
}
