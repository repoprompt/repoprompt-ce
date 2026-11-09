import Foundation
import RepoPromptAIContracts
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptProcess

extension CodexExecAgentConfig {
    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.codex,
        modelString: String? = nil,
        enableDebugLogging: Bool = false,
        fullAccess: Bool = false
    ) {
        self.init(
            commandName: commandName ?? CLILaunchProfiles.codex.commandName,
            additionalPathHints: additionalPathHints,
            modelString: modelString,
            enableDebugLogging: enableDebugLogging,
            fullAccess: fullAccess
        )
    }
}

extension CodexExecAgentProvider {
    convenience init(
        config: CodexExecAgentConfig,
        launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot = CodexRuntimeAuthority.currentLaunchSnapshot(),
        runtimeStatePreparer: @escaping @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void = {
            try $0.prepareState()
        }
    ) {
        self.init(config: config, host: CodexExecAppHost(launchSnapshot: launchSnapshot, runtimeStatePreparer: runtimeStatePreparer))
    }
}

private final class CodexExecAppHost: CodexExecAgentHost {
    private let launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot
    private let runtimeStatePreparer: @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void
    let toolTracking: any CodexExecToolTracking = CodexExecAppToolTracking()

    init(launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot, runtimeStatePreparer: @escaping @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void) {
        self.launchSnapshot = launchSnapshot
        self.runtimeStatePreparer = runtimeStatePreparer
    }

    func preflight(commandName: String, additionalPathHints: [String], enableDebugLogging: Bool) async -> CodexProviderExecutableResolution {
        await CodexProviderHelpers.preflightCodexExecutable(
            commandName: commandName,
            additionalPathHints: additionalPathHints,
            enableDebugLogging: enableDebugLogging,
            launchSnapshot: launchSnapshot
        )
    }

    func prepareState(_ runtime: CodexProviderRuntime.Runtime) throws {
        try runtimeStatePreparer(runtime)
    }

    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter {
        ProviderEnvironmentFiltering.cliFilter(for: .codexExec, explicitOverrides: explicitOverrides)
    }

    func isMCPServerRunning() async -> Bool {
        await ServerNetworkManager.shared.isRunning()
    }

    func ensureServer(runtime: CodexProviderRuntime.Runtime) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        CodexIntegrationConfiguration.ensureServerForDiscovery(runtime: runtime)
    }

    func modelSpecifier(raw: String?) -> CodexModelSpecifier {
        CodexModelSpecifier(raw: raw)
    }

    func serverEntries() -> [CodexExecServerEntry] {
        MCPIntegrationHelper.codexMCPServerEntries()
    }

    func brokenServers() async -> Set<String> {
        await CodexBrokenServersCache.shared.getAll()
    }

    func addBrokenServer(_ name: String) async {
        await CodexBrokenServersCache.shared.add(name)
    }

    func contextWindowOverrideArguments() -> [String] {
        CodexContextWindowPreferences.cliArguments(CodexContextWindowPreferences.selection())
    }

    func toolOverrideArguments() -> [String] {
        let toolPolicy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
            shellToolEnabled: false,
            webSearchRequestEnabled: nil,
            multiAgentEnabled: false,
            modelReasoningSummary: nil
        )
        return CodexOverrides.cliConfigArgs(toolPolicy: toolPolicy)
    }

    func serverOverrideArguments(entries: [CodexExecServerEntry], brokenServers: Set<String>) -> [String] {
        CodexOverrides.cliMCPServerArgs(
            entries: entries,
            policy: .enableOnlyRepoPrompt(
                repoPromptNormalizedName: MCPIntegrationHelper.repoPromptMCPServerName,
                exceptBroken: brokenServers
            )
        )
    }

    func fallbackModel(attemptedModel: String?, errorDetail: String) -> String? {
        CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: attemptedModel, errorDetail: errorDetail)
    }

    func brokenServerName(stderr: String) -> String? {
        CodexProviderHelpers.extractBrokenServerName(from: stderr)
    }

    func isRepoPromptToolName(_ name: String) -> Bool {
        MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(name)
    }

    func isRepoPromptServerIdentifier(_ name: String) -> Bool {
        MCPIntegrationHelper.isRepoPromptServerIdentifier(name)
    }

    var manualLoginGuidanceMessage: String {
        CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage
    }

    func registerExpectedPID(_ pid: Int32, runID: UUID) async {
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: AgentProviderKind.codexMCPClientID, runID: runID)
    }

    func clearExpectedPID(_ pid: Int32, runID: UUID) async {
        await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: AgentProviderKind.codexMCPClientID, runID: runID)
    }
}

private final class CodexExecAppToolTracking: CodexExecToolTracking {
    private let controller = AgentToolTrackingController()

    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) {
        controller.startTracking(runID: runID, clientNameHint: clientNameHint, continuation: continuation)
    }

    func stopTracking() async {
        await controller.stopTracking()
    }
}
