import Foundation
import RepoPromptDomainRuntime

/// Proof is not release: callers must complete their existing stop/route fences after the await,
/// then synchronously obtain this typed handoff and invoke the provider without an app-owned hop.
@MainActor
enum AgentSessionLinkProviderInputRelease {
    struct Proof {
        let claim: AgentSessionLinkOutboundPromptClaim?
        fileprivate let authorized: Bool
        fileprivate let managedAuthorizations: [DomainAgentSessionManagedObservationRequirement: DomainAgentSessionLinkCommitAuthorization]?

        func replacingClaim(_ replacement: AgentSessionLinkOutboundPromptClaim?) -> Proof {
            Proof(
                claim: replacement, authorized: authorized && replacement?.localInput == claim?.localInput,
                managedAuthorizations: managedAuthorizations
            )
        }

        fileprivate func permitsManagedMetadata(_ candidate: AgentSessionLinkOutboundPromptClaim) -> Bool {
            guard !candidate.managedMetadataRequirements.isEmpty else { return true }
            guard !Task.isCancelled, let managedAuthorizations else { return false }
            // Reordering or removing rows does not require new authority. A newly added exact
            // requirement still fails closed until a later dispatch proves it.
            return candidate.managedMetadataRequirements.allSatisfy { requirement in
                guard let authorization = managedAuthorizations[requirement] else { return false }
                let lease = authorization.lease
                return lease.observer == candidate.observerEndpoint && lease.target == requirement.target
                    && lease.linkID == requirement.reference.linkID && lease.linkGeneration == requirement.reference.generation
                    && lease.capability == .manage && (try? authorization.withAuthorization { true }) == true
            }
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
        managedProof: (DomainAgentSessionLinkEndpointIdentity, [DomainAgentSessionManagedObservationRequirement]) async -> [DomainAgentSessionLinkCommitAuthorization]? = { _, _ in nil },
        readProof: (AgentSessionLinkLocalInputDecoration) async -> Bool
    ) async -> Proof {
        var managedAuthorizations: [DomainAgentSessionManagedObservationRequirement: DomainAgentSessionLinkCommitAuthorization]?
        if let claim, !claim.managedMetadataRequirements.isEmpty, let observer = claim.observerEndpoint,
           let issued = await managedProof(observer, claim.managedMetadataRequirements)
        {
            managedAuthorizations = Dictionary(issued.map {
                (.init(reference: .init(linkID: $0.lease.linkID, generation: $0.lease.linkGeneration), target: $0.lease.target), $0)
            }, uniquingKeysWith: { first, _ in first })
        }
        let authorized: Bool = if let decoration = claim?.localInput {
            await readProof(decoration)
        } else {
            false
        }
        return Proof(claim: claim, authorized: authorized && !Task.isCancelled, managedAuthorizations: managedAuthorizations)
    }

    /// Recovery reuses already accepted bytes, not whatever content remains owed. Callers pass
    /// the existing epoch/inventory reuse decision after their final suspension; live Manage
    /// fences are checked here even when no passive row or pending claim remains.
    static func handoffAcceptedReplay(
        _ claim: AgentSessionLinkOutboundPromptClaim?, proof: Proof?, isCurrent: Bool,
        requiresLaneBatch: Bool
    ) -> ReleasedDispatchContext {
        guard let claim, isCurrent, claim.localInput == nil,
              claim.managedMetadataRequirements.isEmpty || proof?.permitsManagedMetadata(claim) == true
        else {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: requiresLaneBatch, disclosedLocalInputs: false)
        }
        return ReleasedDispatchContext(claim: claim, fragment: claim.fragment, mustAbortDispatch: false, disclosedLocalInputs: false)
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
        guard proof.permitsManagedMetadata(original) else {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: original.dispatchID.isAutoWakeFamily, disclosedLocalInputs: false)
        }
        // Manage proof suspends and covers only managed rows. Reclaim the entire pending batch
        // afterwards so watch rows and observer eligibility cannot ride another row's proof.
        // Already accepted recovery uses handoffAcceptedReplay instead of this pending path.
        if original.managedMetadataRequirements.isEmpty,
           original.localInput == nil, !original.routineQuietCheckIn,
           !original.dispatchID.isAutoWakeFamily || isPending(original)
        {
            return ReleasedDispatchContext(claim: original, fragment: original.fragment, mustAbortDispatch: false, disclosedLocalInputs: false)
        }
        let outcome = current()
        guard !outcome.mustAbortDispatch else {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: true, disclosedLocalInputs: false)
        }
        let chosen = outcome.claim
        if let chosen, !proof.permitsManagedMetadata(chosen) {
            return ReleasedDispatchContext(claim: nil, fragment: nil, mustAbortDispatch: original.dispatchID.isAutoWakeFamily, disclosedLocalInputs: false)
        }
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
