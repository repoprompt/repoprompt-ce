import Foundation

/// Proof is not release: callers must complete their existing stop/route fences after the await,
/// then synchronously obtain this typed handoff and invoke the provider without an app-owned hop.
@MainActor
enum AgentSessionLinkProviderInputRelease {
    struct Proof {
        let claim: AgentSessionLinkOutboundPromptClaim?
        fileprivate let authorized: Bool

        func replacingClaim(_ replacement: AgentSessionLinkOutboundPromptClaim?) -> Proof {
            Proof(claim: replacement, authorized: authorized && replacement?.localInput == claim?.localInput)
        }
    }

    struct ReleasedDispatchContext {
        let claim: AgentSessionLinkOutboundPromptClaim?
        let fragment: String?
        let mustAbortDispatch: Bool
        let disclosedLocalInputs: Bool
        fileprivate init(claim: AgentSessionLinkOutboundPromptClaim?, fragment: String?, mustAbortDispatch: Bool, disclosedLocalInputs: Bool) {
            self.claim = claim
            self.fragment = fragment
            self.mustAbortDispatch = mustAbortDispatch
            self.disclosedLocalInputs = disclosedLocalInputs
        }

        func text(_ undecorated: String) -> String {
            fragment.map { AgentSessionLinkPromptComposer.decorated(undecorated, fragment: $0) } ?? undecorated
        }

        func message(_ undecorated: AgentMessage) -> AgentMessage {
            var result = undecorated
            result.userMessage = text(result.userMessage)
            return result
        }
    }

    static func prove(
        _ claim: AgentSessionLinkOutboundPromptClaim?,
        readProof: (AgentSessionLinkLocalInputDecoration) async -> Bool
    ) async -> Proof {
        guard let decoration = claim?.localInput else { return Proof(claim: claim, authorized: false) }
        let authorized = await readProof(decoration)
        return Proof(claim: claim, authorized: authorized && !Task.isCancelled)
    }

    /// All synchronous checks and consumption happen in this same MainActor turn. Failed optional
    /// authorization is baseline fallback, never an exception or a new dispatch refusal.
    static func handoff(
        original: AgentSessionLinkOutboundPromptClaim?,
        proof: Proof,
        current: () -> AgentSessionLinkPromptClaimOutcome,
        isPending: (AgentSessionLinkOutboundPromptClaim) -> Bool,
        consume: (AgentSessionLinkLocalInputDecoration) -> Bool
    ) -> ReleasedDispatchContext {
        guard let original else {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: false, disclosedLocalInputs: false)
        }
        if original.localInput == nil, !original.routineQuietCheckIn,
           !original.dispatchID.isAutoWakeFamily || isPending(original)
        {
            return ReleasedDispatchContext(claim: original, fragment: original.fragment, mustAbortDispatch: false, disclosedLocalInputs: false)
        }
        let outcome = current()
        guard !outcome.mustAbortDispatch else {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: true, disclosedLocalInputs: false)
        }
        let chosen = outcome.claim
        guard let decoration = original.localInput else {
            return ReleasedDispatchContext(claim: chosen, fragment: chosen?.fragment, mustAbortDispatch: false, disclosedLocalInputs: false)
        }
        if chosen == original, proof.claim == original, proof.authorized,
           !Task.isCancelled, isPending(original), consume(decoration)
        {
            return ReleasedDispatchContext(claim: original, fragment: decoration.fragment, mustAbortDispatch: false, disclosedLocalInputs: true)
        }
        // Includes drift, concurrent consumption, accepted replay, revoked Read and edited content.
        // Reclaim once after the proof hop; the new claim's optional decoration is never upgraded.
        return ReleasedDispatchContext(claim: chosen, fragment: chosen?.fragment, mustAbortDispatch: false, disclosedLocalInputs: false)
    }
}
