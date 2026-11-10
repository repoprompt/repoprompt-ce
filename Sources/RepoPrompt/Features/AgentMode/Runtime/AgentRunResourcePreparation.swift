import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

/// A one-shot resource handoff, not a run owner. The originating runner supplies its existing
/// attempt/Stop fence; only that authority decides whether construction or installation is current.
@MainActor
final class AgentRunResourcePreparation<Resource> {
    private enum State { case pending, constructing, refused, finished }
    private var state = State.pending
    private let isCurrent: () -> Bool
    private let refused: () async -> Void
    private let receive: (Resource) async -> AgentRunResourceRequest?

    init(
        isCurrent: @escaping () -> Bool,
        refused: @escaping () async -> Void,
        receive: @escaping (Resource) async -> AgentRunResourceRequest?
    ) {
        self.isCurrent = isCurrent
        self.refused = refused
        self.receive = receive
    }

    func claimConstruction() -> Bool {
        guard state == .pending else { return false }
        guard isCurrent() else {
            state = .refused
            return false
        }
        state = .constructing
        return true
    }

    func settleRefusal() async {
        guard state == .refused else { return }
        state = .finished
        await refused()
    }

    func accept(_ resource: Resource) async -> AgentRunResourceRequest? {
        guard state == .constructing else { return nil }
        state = .finished
        return await receive(resource)
    }
}

/// Immutable construction inputs leave execution; neither factories nor a mutable session enter
/// the composition operation. Result errors return to the originating runner's terminal barrier.
@MainActor
enum AgentRunResourceRequest {
    case headless(
        agent: AgentProviderKind, model: String?,
        preparation: AgentRunResourcePreparation<HeadlessAgentProvider>
    )
    case acpProvider(
        agent: AgentProviderKind, model: String?,
        preparation: AgentRunResourcePreparation<Result<(any ACPAgentProvider)?, Error>>
    )
    case acpController(
        provider: any ACPAgentProvider, request: ACPRunRequest,
        preparation: AgentRunResourcePreparation<Result<ACPAgentSessionController, Error>>
    )
}
