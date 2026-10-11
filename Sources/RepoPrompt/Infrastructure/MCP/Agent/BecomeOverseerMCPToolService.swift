import Foundation
import MCP
import RepoPromptDomainRuntime

/// Bootstrap only: exact installed model route, memory-only eligibility, and no invented grant.
@MainActor
struct BecomeOverseerMCPToolService {
    static let nextTurnResult = "Oversight enabled; the tools will be available on your next turn."
    static let devinResult = "Oversight enabled; Devin may not discover the tools until a new provider session."

    /// Transport-owned proof adapted to the bridge's synchronous, network-independent commit fence.
    struct ActivationCommitFence {
        let commitIfCurrent: @MainActor (_ commit: () -> Bool) -> Bool
        let invalidate: @Sendable () -> Void
    }

    let captureRequestMetadata: () async -> MCPRequestMetadata
    let resolveObserverEndpoint: (MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity?
    var isEnabled: () -> Bool = { ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.agentSessionLink) }
    var bridge: AgentSessionLinkRuntimeBridge = .shared
    var prepareActivationCommit: (
        ToolInvocationContext?, DomainAgentSessionLinkEndpointIdentity
    ) async -> ActivationCommitFence? = { invocation, endpoint in
        // Install family observation synchronously before the first network qualification hop.
        // This same proof remains unarmed until the issuer independently verifies and registers it.
        guard let invocation,
              let observedProof = MCPBecomeOverseerActivationProof.prepareObservingFamily(
                  invocation: invocation, endpoint: endpoint
              )
        else { return nil }
        let issued = await withTaskCancellationHandler {
            await ServerNetworkManager.shared.issueBecomeOverseerActivationProof(
                invocation: invocation, endpoint: endpoint, observedProof: observedProof
            )
        } onCancel: {
            observedProof.invalidate()
        }
        guard let proof = issued else { return nil }
        return ActivationCommitFence(
            commitIfCurrent: { commit in
                proof.commitIfCurrent(invocation: invocation, endpoint: endpoint, commit)
            },
            invalidate: { proof.invalidate() }
        )
    }

    func execute(args: [String: Value]) async throws -> Value {
        guard args.isEmpty else { throw MCPError.invalidParams("become_overseer takes no parameters.") }
        // Capture ingress evidence before callbacks/actor hops; do not reconstruct an invocation later.
        let invocation = MCPInvocationContextBridge.current
        let metadata = await captureRequestMetadata()
        guard let endpoint = await resolveObserverEndpoint(metadata),
              let fence = await prepareActivationCommit(invocation, endpoint)
        else { throw MCPError.invalidParams("Tool 'become_overseer' is not available for this session.") }
        let invalidate = fence.invalidate
        defer { invalidate() }
        let provider = await withTaskCancellationHandler {
            await bridge.becomeOverseer(
                endpoint: endpoint,
                isEnabled: isEnabled,
                revalidateRoute: { await resolveObserverEndpoint(metadata) == endpoint },
                commitIfCurrent: fence.commitIfCurrent
            )
        } onCancel: {
            invalidate()
        }
        guard let provider else { throw MCPError.invalidParams("Tool 'become_overseer' is not available for this session.") }
        return .string(provider == .devin ? Self.devinResult : Self.nextTurnResult)
    }
}
