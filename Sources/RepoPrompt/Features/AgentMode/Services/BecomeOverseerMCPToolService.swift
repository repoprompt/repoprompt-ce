import Foundation
import MCP
import RepoPromptDomainRuntime

/// Bootstrap only: exact installed model route, memory-only eligibility, and no invented grant.
@MainActor
struct BecomeOverseerMCPToolService {
    /// Read the setting for each call, never freeze mode-specific instructions at first access.
    static var nextTurnResult: String {
        OverseerAuthorizationEngine.current.bootstrapGuidance
    }

    static var devinResult: String {
        nextTurnResult
    }

    /// Transport-owned proof adapted to the bridge's synchronous, network-independent commit fence.
    struct ActivationCommitFence {
        let commitIfCurrent: @MainActor (_ commit: () -> Bool) -> Bool
        let invalidate: @Sendable () -> Void
    }

    let captureRequestMetadata: () async -> MCPRequestMetadata
    let resolveObserverEndpoint: (MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity?
    /// Refusal text only: the routed endpoint without the availability check. Never admits activation.
    var resolveRoutedEndpointForRefusal: (MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity? = { _ in nil }
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
        let allowed: Set = ["session_id", "message", "idempotency_key"]
        if let key = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPError.invalidParams("become_overseer does not accept '\(key)'; nothing was requested or delivered.")
        }
        let targetID: UUID?
        if let value = args["session_id"] {
            guard case let .string(raw) = value, let id = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("become_overseer session_id must be the exact target UUID.")
            }
            targetID = id
        } else { targetID = nil }
        let message: String?
        if let value = args["message"] {
            guard targetID != nil, case let .string(text) = value,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32768
            else {
                throw MCPError.invalidParams("become_overseer message requires session_id and nonempty text up to 32768 bytes.")
            }
            message = text
        } else { message = nil }
        let suppliedKey: String?
        if let value = args["idempotency_key"] {
            guard case let .string(key) = value, !key.isEmpty else {
                throw MCPError.invalidParams("become_overseer idempotency_key must be a nonempty string.")
            }
            suppliedKey = key
        } else { suppliedKey = nil }
        // Capture ingress evidence before callbacks/actor hops; do not reconstruct an invocation later.
        let invocation = MCPInvocationContextBridge.current
        let metadata = await captureRequestMetadata()
        guard let endpoint = await resolveObserverEndpoint(metadata) else {
            throw await unavailable(metadata: metadata, endpoint: nil)
        }
        guard targetID != endpoint.sessionID else { throw MCPError.invalidParams("become_overseer cannot oversee itself.") }
        guard let fence = await prepareActivationCommit(invocation, endpoint) else {
            throw await unavailable(metadata: metadata, endpoint: endpoint)
        }
        let invalidate = fence.invalidate
        defer { invalidate() }
        let provider = await withTaskCancellationHandler {
            await bridge.becomeOverseer(
                endpoint: endpoint,
                isEnabled: isEnabled,
                revalidateRoute: { await resolveObserverEndpoint(metadata) == endpoint },
                commitIfCurrent: fence.commitIfCurrent,
                continuingTargetedRequest: true
            )
        } onCancel: {
            invalidate()
        }
        guard let provider else { throw await unavailable(metadata: metadata, endpoint: endpoint) }
        if let targetID {
            let key = suppliedKey
                ?? "oversee:\(targetID.uuidString):\(AgentSessionLinkMessageDigest.steerDigest(message: message ?? ""))"
            return await bridge.requestTargetedOversight(observer: endpoint, targetSessionID: targetID, message: message, idempotencyKey: key)
        }
        return .string(provider == .devin ? Self.devinResult : Self.nextTurnResult)
    }

    /// Every refusal names its cause and the next step; a generic "not available" leaves the agent
    /// (and the user) unable to act on it.
    private func unavailable(
        metadata: MCPRequestMetadata,
        endpoint: DomainAgentSessionLinkEndpointIdentity?
    ) async -> MCPError {
        var routed = endpoint
        if routed == nil, isEnabled() { routed = await resolveRoutedEndpointForRefusal(metadata) }
        let reason: String = if !isEnabled() {
            "Session oversight is switched off: agent_session_link is disabled in this window's Tools settings. Ask the user to enable it, then retry."
        } else if let routed {
            bridge.overseerBootstrapRefusal(for: routed)?.reason
                ?? "This session's route or state changed while activating. Retry become_overseer once."
        } else {
            "This call isn't routed to an installed Agent Mode run in this window. Retry once; if it still fails, ask the user to send the request again from the Agent Mode session itself."
        }
        return MCPError.invalidParams("become_overseer can't activate this session. \(reason) Nothing was requested or delivered.")
    }
}
