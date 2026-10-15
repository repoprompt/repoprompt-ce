import Foundation
import MCP
import RepoPromptDomainRuntime

/// Bootstrap only: exact installed model route, memory-only eligibility, and no invented grant.
@MainActor
struct BecomeOverseerMCPToolService {
    static let nextTurnResult = "Oversight enabled. To oversee one saved target without another user turn, call become_overseer with session_id and optional message now: it requests one exact-target observe/control/restructure approval and the app automatically prepares, links and dispatches after approval. No go turn or target tab visit is needed. session_admin scope_status lists the operation catalog and current grants when available; activation alone grants no authority."
    static let devinResult = nextTurnResult

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
            throw MCPError.invalidParams("Tool 'become_overseer' is not available for this session.")
        }
        guard targetID != endpoint.sessionID else { throw MCPError.invalidParams("become_overseer cannot oversee itself.") }
        guard let fence = await prepareActivationCommit(invocation, endpoint) else {
            throw MCPError.invalidParams("Tool 'become_overseer' is not available for this session.")
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
        guard let provider else { throw MCPError.invalidParams("Tool 'become_overseer' is not available for this session.") }
        if let targetID {
            let key = suppliedKey
                ?? "oversee:\(targetID.uuidString):\(AgentSessionLinkMessageDigest.steerDigest(message: message ?? ""))"
            return bridge.requestTargetedOversight(observer: endpoint, targetSessionID: targetID, message: message, idempotencyKey: key)
        }
        return .string(provider == .devin ? Self.devinResult : Self.nextTurnResult)
    }
}
