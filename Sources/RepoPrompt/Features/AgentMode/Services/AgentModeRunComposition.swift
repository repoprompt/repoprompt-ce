import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

/// Product composition owns provider construction. Execution admits a turn and either finishes on
/// a live runtime or returns immutable resource requests; it never retains these factories.
@MainActor
final class AgentModeRunComposition {
    let execution: AgentModeRunService
    private let resources: AgentRunProviderComposition
    private let workspace: AgentRunWorkspaceInput

    init(execution: AgentModeRunService, resources: AgentRunProviderComposition, workspace: AgentRunWorkspaceInput) {
        self.execution = execution
        self.resources = resources
        self.workspace = workspace
    }

    @discardableResult
    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        startOutcome: AgentRunStartOutcomeRecorder? = nil,
        stopFence: AgentRunStartStopFence? = nil,
        localComposerCandidate: UUID? = nil,
        initialUserItemID: UUID? = nil,
        preparedClaudeEvents: ClaudeAttemptEventReservation? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        switch await execution.prepareRun(
            tabID: tabID,
            session: session,
            workspace: workspace,
            initialUserMessage: initialUserMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            codexFallbackContext: codexFallbackContext,
            autoEffortSelection: autoEffortSelection,
            providerControlCommand: providerControlCommand,
            selfCompactDispatchID: selfCompactDispatchID,
            startOutcome: startOutcome,
            stopFence: stopFence,
            localComposerCandidate: localComposerCandidate,
            initialUserItemID: initialUserItemID,
            preparedClaudeEvents: preparedClaudeEvents
        ) {
        case let .completed(outcome):
            return outcome
        case let .resources(request):
            await resources.fulfill(request)
            return nil
        }
    }
}

@MainActor
final class AgentRunProviderComposition {
    private let headless: AgentRunExecutionContracts.HeadlessProviderFactory
    private let acp: AgentRunExecutionContracts.ACPProviderFactory
    private let controller: AgentRunExecutionContracts.ACPControllerFactory

    init(
        headless: @escaping AgentRunExecutionContracts.HeadlessProviderFactory,
        acp: @escaping AgentRunExecutionContracts.ACPProviderFactory,
        controller: @escaping AgentRunExecutionContracts.ACPControllerFactory
    ) {
        self.headless = headless
        self.acp = acp
        self.controller = controller
    }

    func fulfill(_ first: AgentRunResourceRequest?) async {
        var next = first
        while let request = next {
            switch request {
            case let .headless(agent, model, preparation):
                guard preparation.claimConstruction() else {
                    await preparation.settleRefusal()
                    return
                }
                let provider = headless(agent, model)
                next = await preparation.accept(provider)
            case let .acpProvider(agent, model, preparation):
                guard preparation.claimConstruction() else {
                    await preparation.settleRefusal()
                    return
                }
                let result: Result<(any ACPAgentProvider)?, Error>
                do { result = try await .success(acp(agent, model)) }
                catch { result = .failure(error) }
                next = await preparation.accept(result)
            case let .acpController(provider, request, preparation):
                guard preparation.claimConstruction() else {
                    await preparation.settleRefusal()
                    return
                }
                let result: Result<ACPAgentSessionController, Error>
                do { result = try .success(controller(provider, request)) }
                catch { result = .failure(error) }
                next = await preparation.accept(result)
            }
        }
    }
}
