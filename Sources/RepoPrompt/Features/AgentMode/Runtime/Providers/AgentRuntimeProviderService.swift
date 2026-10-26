import Foundation
import Logging
import RepoPromptProcess
import RepoPromptSettingsCore

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
    /// - Important: ACP-backed providers use their shared one-shot bridge for
    ///   headless discovery while keeping broader chat-provider wiring separate.
    func makeProvider(
        for agent: AgentProviderKind,
        modelString: String? = nil,
        runType: AgentRunType = .discover,
        workspacePath: String? = nil,
        modelParameterSelections: [ACPModelParameterSelection] = []
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
                environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: config.runtimeVariant.agentKind),
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
                enableDebugLogging: Self.enableDebugLogging,
                fullAccess: CodexAgentToolPreferences.permissionLevel() == .fullAccess
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CodexExecAgentProvider")
            }
            return CodexExecAgentProvider(config: config)
        case .openCode:
            let config = OpenCodeAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                toolProfile: .headless,
                modelParameterSelections: modelParameterSelections
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created OpenCodeACPHeadlessAgentProvider")
            }
            return OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .cursor:
            let config = CursorAgentConfig(
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                includeRepoPromptMCPServer: true,
                cleanupProjectMCPApproval: true,
                modelOverrides: modelParameterSelections.map { .init(configID: $0.configID, valueRaw: $0.valueRaw) }
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CursorACPHeadlessAgentProvider")
            }
            return CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .grokBuild:
            let config = GrokBuildAgentConfig(
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                alwaysApproveTools: false,
                discoveryMode: true,
                backgroundFeatureEnvironment: GrokBuildAgentConfig.managedBackgroundFeatureEnvironment
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created GrokBuildACPHeadlessAgentProvider")
            }
            return GrokBuildACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .antigravity:
            return UnsupportedHeadlessAgentProvider(reason: "Headless execution is not supported for this provider.")
        case .devin:
            return DevinACPHeadlessAgentProvider(
                config: DevinAgentConfig(
                    enableDebugLogging: Self.enableDebugLogging,
                    includeRepoPromptMCPServer: true,
                    modelString: modelString
                ),
                workspacePath: workspacePath
            )
        }
    }
}
