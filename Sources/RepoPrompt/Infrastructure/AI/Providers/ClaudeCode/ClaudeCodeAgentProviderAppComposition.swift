import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime
import RepoPromptProcess

/// Same typed launch value for Codex and both App bridges; its reflected nominal
/// name is now HeadlessLaunchContext<ClaudeCompatibleLaunchEnvironment>.
typealias HeadlessAgentContext = ClaudeHeadlessAgentContext

extension MCPConfigExportService: ClaudeHeadlessConfigPreparing {
    package func prepareClaudeHeadlessLaunchConfig() throws -> any LaunchConfigLease {
        try prepareLaunchConfig()
    }
}

extension ClaudeCodeAgentProvider {
    convenience init(
        runner: CLIProcessRunner,
        config: ClaudeCodeAgentConfig,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
        configService: MCPConfigExportService = .shared,
        serverReadiness: @escaping @Sendable () async -> Bool = {
            await ServerNetworkManager.shared.isRunning()
        },
        processStarted: @escaping @Sendable (pid_t) async -> Void = { _ in },
        cleanupStarted: @escaping @Sendable () async -> Void = {}
    ) {
        self.init(
            composedRunner: runner,
            config: config,
            environmentResolver: environmentResolver,
            configService: configService,
            host: ClaudeHeadlessAppHost(),
            serverReadiness: serverReadiness,
            processStarted: processStarted,
            cleanupStarted: cleanupStarted
        )
    }
}

/// Retains exactly one existing tracker; no observer or lease state is duplicated.
private struct ClaudeHeadlessAppHost: ClaudeHeadlessHosting {
    private let toolTracking = AgentToolTrackingController()

    func currentPromptDelivery() -> ClaudeHeadlessPromptDelivery {
        let mode = ClaudeAgentToolPreferences.agentModePromptDelivery()
        return ClaudeHeadlessPromptDelivery(
            userMessage: { userMessage, instructions in
                ClaudeCompatibleProviderRuntimeBridge.providerBoundUserMessage(userMessage, instructions: instructions, delivery: mode)
            },
            nativeSystemPromptOverride: { mode.nativeSystemPromptOverride(instructions: $0) }
        )
    }

    func buildArguments(config: ClaudeCodeAgentConfig, context: ClaudeHeadlessAgentContext, resumeSessionID: String?, systemPromptOverride: String?) -> [String] {
        ClaudeCompatibleProviderRuntimeBridge.buildHeadlessArguments(
            config: config, context: context, resumeSessionID: resumeSessionID, systemPromptOverride: systemPromptOverride
        )
    }

    func isReasoningExtractionEnabled() -> Bool {
        ClaudeReasoningExtractionFeature.isEnabled
    }

    func expectedClientName(for variant: ClaudeCodeRuntimeVariant) -> String? {
        variant.agentKind.mcpClientNameHint
    }

    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
    }

    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
    }

    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Continuation) {
        toolTracking.startTracking(runID: runID, clientNameHint: clientNameHint, continuation: continuation)
    }

    @MainActor func stopTracking() async {
        await toolTracking.stopTracking()
    }
}
