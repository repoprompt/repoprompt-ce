import Foundation

/// Headless/discovery adapter for the official xAI Grok Build ACP runtime.
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths (e.g. Context
/// Builder) use the shared one-shot ACP headless bridge. Grok selects its model at launch
/// (`grok agent -m <id> stdio`) and receives RepoPrompt MCP tools through ACP `session/new`
/// `mcpServers`, so the bridge needs no runtime model/mode application. Headless launches set
/// `alwaysApprove` so the launch adds `--always-approve` and autonomous tool use never stalls
/// on `session/request_permission` (there is no interactive approval UI for discovery runs).
final class GrokACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: GrokAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: GrokAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: GrokAgentConfig {
            config
        }
    #endif

    init(
        config: GrokAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            GrokACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Grok Build",
            makeProvider: {
                resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .grokBuild,
                    modelString: config.modelString,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: nil
                )
            },
            makeController: controllerFactory,
            beforePrompt: { _, _ in
                // Grok's model is fixed at launch via `-m`, it exposes no ACP session modes,
                // and it has no runtime configOptions, so no pre-prompt mutation is required.
            },
            approvalPolicy: .declineUnsupported
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }
}
