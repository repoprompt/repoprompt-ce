import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension ClaudeCodeRuntimeVariant {
    var compatibleBackendID: ClaudeCodeCompatibleBackendID? {
        switch self {
        case .standard:
            nil
        case .glm:
            .glmZAI
        case .kimi:
            .kimi
        case .customCompatible:
            .custom
        }
    }
}

extension AgentProviderKind {
    /// Grok Build presents `grok-shell-<injected server name>` (here `grok-shell-RepoPromptCEGrokRuntime`)
    /// to MCP servers. The hint must equal that exact registered name: the pending run-scoped
    /// tab-context store keys are raw client names (no family canonicalization), so a
    /// family-only hint would never bind the run's frozen tab context. The canonical
    /// `grok-shell` family in `MCPClientIdentity` still covers family-level matching.
    static let grokBuildMCPClientID = "grok-shell-\(RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName)"

    var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codexExec:
            "Codex CLI"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .grokBuild:
            "Grok Build"
        case .antigravity:
            "Google Antigravity"
        case .devin:
            "Devin CLI"
        case .claudeCodeGLM:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI).normalizedDisplayName
        case .kimiCode:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .kimi).normalizedDisplayName
        case .customClaudeCompatible:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .custom).normalizedDisplayName
        }
    }

    var mcpClientNameHint: String? {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            Self.claudeMCPClientID
        case .codexExec:
            Self.codexMCPClientID
        case .openCode:
            Self.openCodeMCPClientID
        case .cursor:
            Self.cursorMCPClientID
        case .grokBuild:
            Self.grokBuildMCPClientID
        case .antigravity:
            "antigravity"
        case .devin:
            Self.devinMCPClientID
        }
    }

    /// Human-readable description for MCP discovery (list_agents).
    var agentDescription: String {
        switch self {
        case .claudeCode:
            return "Anthropic's Claude Code agent. Strong at general-purpose development, code understanding, architecture, and open-ended reasoning tasks."
        case .codexExec:
            return "OpenAI's Codex CLI agent. Optimized for tool-driven engineering workflows. Supports configurable reasoning effort levels per model."
        case .antigravity:
            return "Google Antigravity ACP agent. Supports interactive Agent Mode through the managed ACP bridge."
        case .openCode:
            return "OpenCode ACP agent. Interactive Agent Mode uses RepoPrompt MCP tools; headless discovery/delegate runs use RepoPrompt's managed no-native-tools mode."
        case .cursor:
            return "Cursor CLI ACP agent. Uses Cursor's ACP runtime and injects RepoPrompt MCP tools through ACP session configuration."
        case .grokBuild:
            return "xAI Grok Build ACP agent. Uses Grok Build's ACP runtime (`grok agent stdio`) and injects RepoPrompt MCP tools through ACP session configuration."
        case .devin:
            return "Installed Devin ACP agent for Agent Mode, Context Builder, and delegated runs. RepoPrompt injects its MCP tools through an isolated configuration overlay."
        case .claudeCodeGLM:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI)
            if case let .claudeSlotMapping(mapping) = config.modelBehavior {
                let normalized = mapping.normalized
                return "Claude Code routed through the GLM integration. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
            return "Claude Code routed through the GLM integration for teams using that provider configuration."
        case .kimiCode:
            return "Claude Code routed through Kimi's Claude-compatible coding backend. Uses Kimi's no-model launch behavior."
        case .customClaudeCompatible:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
            switch config.modelBehavior {
            case .noModel:
                return "Claude Code routed through a custom Claude-compatible backend using no model flag."
            case let .claudeSlotMapping(mapping):
                let normalized = mapping.normalized
                return "Claude Code routed through a custom Claude-compatible backend. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
        }
    }
}
