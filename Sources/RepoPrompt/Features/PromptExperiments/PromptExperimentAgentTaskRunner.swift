#if DEBUG
    import Foundation
    import RepoPromptProcess
    import RepoPromptShared

    struct PromptExperimentAgentTaskResult {
        let output: String
        let transcript: String
        let toolCalls: Int
        let promptTokens: Int?
        let completionTokens: Int?
        var cachedInputTokens: Int?
        var cacheCreationInputTokens: Int?
        var reportedCost: Double?
    }

    @MainActor
    protocol PromptExperimentAgentTaskRunning {
        func preflight(target: PromptExperimentResolvedTarget) throws
        func run(
            target: PromptExperimentResolvedTarget, systemPrompt: String, task: String,
            workspace: URL, profile: URL, maximumTurns: Int, timeout: TimeInterval
        ) async throws -> PromptExperimentAgentTaskResult
    }

    /// Runs the connected Claude-compatible provider against a private direct MCP runtime.
    /// Authentication/model/effort come from the existing provider configuration. Normal
    /// provider permission checks remain enabled; only the approved fixture tools are allowed.
    @MainActor
    final class PromptExperimentConnectedAgentTaskRunner: PromptExperimentAgentTaskRunning {
        private let mcpExecutable: String

        init(mcpExecutable: String = CLISymlinkManagerUserSpace.stableCLIPath) {
            self.mcpExecutable = mcpExecutable
        }

        static func supports(_ target: PromptExperimentResolvedTarget) -> Bool {
            guard let agent = AgentProviderKind(rawValue: target.agentRaw) else { return false }
            return [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible].contains(agent)
        }

        func preflight(target: PromptExperimentResolvedTarget) throws {
            guard Self.supports(target) else {
                throw PromptExperimentAuthorityError.targetUnavailable("The Engineer task runner requires a connected Claude-compatible provider with enforced MCP-only tools.")
            }
            guard FileManager.default.isExecutableFile(atPath: mcpExecutable) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("Install or refresh the RepoPrompt CE CLI before running Engineer tasks.")
            }
        }

        static func serverConfiguration(executable: String, workspace: URL, profile: URL) -> RepoPromptMCPServerConfiguration {
            RepoPromptMCPServerConfiguration(
                command: executable, args: ["--backend", "headless"],
                env: [
                    .init(name: "REPOPROMPT_MCP_HEADLESS_PROFILE", value: "engineer-experiment"),
                    .init(name: "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR", value: profile.path),
                    .init(name: "REPOPROMPT_MCP_WORKING_DIRS", value: workspace.path),
                    .init(name: PromptExperimentAgentProfile.environmentKey, value: PromptExperimentAgentProfile.identifier)
                ]
            )
        }

        func run(
            target: PromptExperimentResolvedTarget, systemPrompt: String, task: String,
            workspace: URL, profile: URL, maximumTurns: Int, timeout: TimeInterval
        ) async throws -> PromptExperimentAgentTaskResult {
            try preflight(target: target)
            guard let agent = AgentProviderKind(rawValue: target.agentRaw),
                  let variant = agent.claudeRuntimeVariant,
                  (1 ... 64).contains(maximumTurns), timeout > 0, timeout <= 900
            else { throw PromptExperimentAuthorityError.invalidRequest("Invalid Engineer provider or task bounds.") }
            let config = ClaudeCodeAgentConfig.agentMode(
                modelString: target.modelRaw, runtimeVariant: variant,
                permissionMode: "default", allowNativeBashTool: false,
                disallowedBuiltInTools: [], mcpStrictMode: true, toolSearchEnabled: false
            )
            let server = Self.serverConfiguration(executable: mcpExecutable, workspace: workspace, profile: profile)
            let configService = MCPConfigExportService(
                configDirectoryURL: profile.deletingLastPathComponent().appendingPathComponent("launch-config"),
                renderServerConfig: { try server.prettyPrintedWrappedSettingsJSON() }
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName, workingDirectory: workspace.path,
                environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: agent),
                captureStdoutTailBytes: 131_072, captureStderrTailBytes: 8192, logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let provider = ClaudeCodeAgentProvider(
                runner: CLIProcessRunner(config: processConfig), config: config,
                configService: configService, serverReadiness: { true },
                isolatedExperiment: .init(maximumTurns: maximumTurns, timeoutSeconds: timeout)
            )
            return try await withTaskCancellationHandler {
                do {
                    let stream = try await provider.streamAgentMessage(
                        AgentMessage(systemPrompt: systemPrompt, userMessage: task), runID: UUID()
                    )
                    var answer = PromptExperimentCompletionAccumulator()
                    var transcript = ""
                    var calls = 0
                    var terminal = false
                    for try await event in stream {
                        try Task.checkCancellation()
                        answer.consume(event)
                        switch event.type {
                        case "tool_call":
                            calls += 1
                            guard calls <= maximumTurns * 16 else { throw PromptExperimentProviderFailure(code: .timedOut) }
                            transcript += "\nTool: \(event.toolName ?? "unknown")\n\(String((event.toolArgsJSON ?? event.toolArgs ?? "").prefix(2000)))\n"
                        case "tool_result":
                            transcript += "\nResult: \(String((event.toolOutput ?? "").prefix(2000)))\n"
                        case "error":
                            throw PromptExperimentConnectedModelRunner.classifyStreamError(event)
                        case "message_stop":
                            terminal = true
                        default:
                            break
                        }
                        // Keep useful bounded evidence even when a task reads large fixtures.
                        if transcript.count > 100_000 { transcript = String(transcript.suffix(100_000)) }
                    }
                    try Task.checkCancellation()
                    guard terminal else { throw PromptExperimentProviderFailure(code: .incompleteResponse) }
                    await provider.dispose()
                    return .init(
                        output: answer.output, transcript: transcript, toolCalls: calls,
                        promptTokens: answer.totalInputTokens, completionTokens: answer.completionTokens,
                        cachedInputTokens: answer.cachedInputTokens, cacheCreationInputTokens: answer.cacheCreationInputTokens,
                        reportedCost: answer.cost
                    )
                } catch {
                    await provider.dispose()
                    if error is CancellationError { throw CancellationError() }
                    throw error
                }
            } onCancel: {
                Task { await provider.dispose() }
            }
        }
    }
#endif
