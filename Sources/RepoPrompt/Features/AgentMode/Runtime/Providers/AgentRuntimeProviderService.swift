import Foundation
import Logging

enum ClaudeCodeRuntimeVariant: String {
    case standard
    case glm
    case kimi
    case customCompatible

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

    var agentKind: AgentProviderKind {
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
enum AgentProviderKind: String, CaseIterable, Hashable {
    case claudeCode
    case codexExec
    case openCode
    case cursor
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible

    static let claudeMCPClientID = "claude-code"
    static let codexMCPClientID = "codex-mcp-client"
    static let openCodeMCPClientID = "opencode"
    static let cursorMCPClientID = "cursor"

    var commandName: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude"
        case .codexExec:
            "codex"
        case .openCode:
            "opencode"
        case .cursor:
            "cursor-agent"
        }
    }

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
        }
    }

    var acpProviderID: ACPProviderID? {
        switch self {
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            nil
        }
    }

    var usesClaudeNativeRuntime: Bool {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        case .codexExec, .openCode, .cursor:
            false
        }
    }

    var usesClaudeTooling: Bool {
        usesClaudeNativeRuntime
    }

    var requiresExpectedPIDOwnedAgentModeMCPRouting: Bool {
        switch self {
        case .claudeCode, .codexExec, .openCode, .cursor, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        }
    }

    /// Human-readable description for MCP discovery (list_agents).
    var agentDescription: String {
        switch self {
        case .claudeCode:
            return "Anthropic's Claude Code agent. Strong at general-purpose development, code understanding, architecture, and open-ended reasoning tasks."
        case .codexExec:
            return "OpenAI's Codex CLI agent. Optimized for tool-driven engineering workflows. Supports configurable reasoning effort levels per model."
        case .openCode:
            return "OpenCode ACP agent. Interactive Agent Mode uses RepoPrompt MCP tools; headless discovery/delegate runs use RepoPrompt's managed no-native-tools mode."
        case .cursor:
            return "Cursor CLI ACP agent. Uses Cursor's ACP runtime and injects RepoPrompt MCP tools through ACP session configuration."
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

    /// Stable runtime kind identifier for MCP discovery (list_agents).
    var runtimeKind: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude_native"
        case .codexExec:
            "codex_native"
        case .openCode:
            "opencode_acp"
        case .cursor:
            "cursor_acp"
        }
    }

    var claudeRuntimeVariant: ClaudeCodeRuntimeVariant? {
        switch self {
        case .claudeCode:
            .standard
        case .claudeCodeGLM:
            .glm
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .customCompatible
        case .codexExec, .openCode, .cursor:
            nil
        }
    }
}

/// Factory/service responsible for instantiating provider runtimes.
final class AgentRuntimeProviderService {
    static let shared = AgentRuntimeProviderService()

    /// Enable debug logging for agent provider runtimes (enabled for debugging cancellation)
    static var enableDebugLogging = false
    private static let logger = Logger(label: "com.repoprompt.agent.runtime.provider")

    private init() {}

    /// Create a headless agent provider.
    /// - Parameters:
    ///   - agent: The provider kind to create
    ///   - modelString: Optional model string override
    ///   - runType: The type of run — determines CLI tool config
    /// - Note: MCP tool restrictions are handled via ServerNetworkManager connection policies,
    ///   not via CLI flags. Use installClientConnectionPolicy before starting the agent run.
    /// - Important: OpenCode and Cursor use their ACP runtimes for headless
    ///   discovery while keeping broader chat-provider wiring separate.
    func makeProvider(
        for agent: AgentProviderKind,
        modelString: String? = nil,
        runType: AgentRunType = .discover,
        workspacePath: String? = nil
    ) -> HeadlessAgentProvider {
        if Self.enableDebugLogging {
            Self.logger.debug("Creating provider for agent: \(agent.displayName), model: \(modelString ?? "default"), runType: \(String(describing: runType))")
        }
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            let runtimeVariant = agent.claudeRuntimeVariant ?? .standard
            let config: ClaudeCodeAgentConfig = .discovery(
                modelString: modelString,
                runtimeVariant: runtimeVariant,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 128 * 1024,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            let wrappedProvider = ClaudeCodeAgentProvider(runner: runner, config: config)
            let runtimeConfig = ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .discovery)
            if Self.enableDebugLogging {
                Self.logger.debug("Created ClaudeCompatibleHeadlessProviderAdapter")
            }
            return ClaudeCompatibleHeadlessProviderAdapter(
                runtimeConfig: runtimeConfig,
                wrappedProvider: wrappedProvider
            )
        case .codexExec:
            let config = CodexExecAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 128 * 1024,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            if Self.enableDebugLogging {
                Self.logger.debug("Created CodexExecAgentProvider")
            }
            return CodexExecAgentProvider(runner: runner, config: config)
        case .openCode:
            let config = OpenCodeAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                toolProfile: .headless
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created OpenCodeACPHeadlessAgentProvider")
            }
            return OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .cursor:
            let config = CursorAgentConfig(
                commandName: agent.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                includeRepoPromptMCPServer: true,
                cleanupProjectMCPApproval: true
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CursorACPHeadlessAgentProvider")
            }
            return CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        }
    }
}
