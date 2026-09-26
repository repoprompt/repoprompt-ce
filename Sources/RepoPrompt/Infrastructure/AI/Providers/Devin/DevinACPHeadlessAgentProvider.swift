import Foundation

final class DevinACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: DevinAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DevinAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    init(
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        // Test-only override. `nil` keeps the production behaviour of resolving the stored
        // level inside `makeRequest` -- once per run, not once per provider -- so a level
        // change still takes effect on the next run of a reused provider.
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel? = nil,
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
            DevinACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Devin",
            makeProvider: { resolvedProviderFactory(config) },
            makeRequest: { message, _ in
                Self.makeRunRequest(
                    config: config,
                    workspacePath: workspacePath,
                    message: message,
                    // Resolved per request, not captured at init.
                    configuredPermissionLevel: configuredPermissionLevel
                        ?? DevinAgentToolPreferences.permissionLevel()
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                // The bridge has no session-mode step of its own, so apply it here.
                //
                // Model first, mode last -- the same order the interactive runner uses. The
                // model mutation validates with `requiredModeValue: nil`, so it does not
                // re-check the mode; setting the mode last means no later configuration call
                // can accept a response that carries a different one. This ordering is what
                // the boundary suite pins.
                if let model = request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty,
                   model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
                {
                    try await controller.setSessionModel(model)
                }
                guard let mode = request.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !mode.isEmpty
                else { return }
                try await controller.setSessionMode(mode)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    /// Headless runs are unattended: the bridge declines any permission request the
    /// controller does not auto-approve, so a mid-run prompt fails the whole run. The level
    /// comes from `unattendedCLIPermissionMode`/`unattendedSessionModeID` — an explicitly
    /// configured Full Approval escalates to `bypass`, and every other level sends no mode
    /// at all. Sending nothing is NOT a floor: on a fresh session it leaves Devin's own
    /// default, and on a resumed session it leaves whatever mode that session already had,
    /// which can be a `bypass` set by an earlier run. Both carriers are sent only when the
    /// RepoPrompt MCP server is injected; model discovery keeps the provider default.
    ///
    /// The launch flag alone is not enough: `devin acp` does not consume `--permission-mode`,
    /// so the mode is also applied over ACP before the prompt.
    static func makeRunRequest(
        config: DevinAgentConfig,
        workspacePath: String?,
        message: AgentMessage,
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel =
            DevinAgentToolPreferences.permissionLevel()
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: config.includeRepoPromptMCPServer
                ? configuredPermissionLevel.unattendedSessionModeID
                : nil,
            launchPermissionMode: config.includeRepoPromptMCPServer
                ? configuredPermissionLevel.unattendedCLIPermissionMode
                : nil
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
