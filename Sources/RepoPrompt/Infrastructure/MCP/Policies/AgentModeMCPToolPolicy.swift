import Foundation

/// MCP tool policy for agent mode runs.
/// Controls which tools are restricted and which special tools are granted.
enum AgentModeMCPToolPolicy {
    /// Agent mode is tab-scoped, so advanced routing and the live oracle helper surface stay blocked.
    static let restrictedCapabilities: Set<MCPToolCapability> = [
        .routingAdvanced,
        .conversationHelper,
        .conversationSend
    ]

    static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    /// Tools granted to legacy/generic agent mode runs (from MCPPolicyGatedTools).
    /// These enable user interaction, agent workflow control, and agent-only oracle recovery.
    static let grantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)

    /// Tools granted to Claude native-style agent runs.
    /// Claude no longer relies on share_thoughts or wait_for_next_user_instruction,
    /// but it does use set_status to rename the active session.
    static let claudeNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let claudeNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

    /// Tools granted to Codex native agent runs.
    /// Codex native still needs ask_user + set_status even though it doesn't use
    /// share_thoughts or wait_for_next_user_instruction.
    /// set_status is title-only; running status now comes from native reasoning summaries.
    static let codexNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let codexNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

    /// OpenCode ACP uses the Agent Mode app/session control surface.
    static let openCodeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let openCodeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

    /// Cursor ACP uses the same Agent Mode app/session control surface as OpenCode.
    static let cursorGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let cursorGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

    static func grantedTools(forAgent agent: AgentProviderKind) -> Set<String> {
        switch agent {
        case .codexExec:
            codexNativeGrantedTools
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeNativeGrantedTools
        case .openCode:
            openCodeGrantedTools
        case .cursor, .grokBuild:
            cursorGrantedTools
        }
    }
}
