import Foundation
import RepoPromptDomainRuntime

extension AgentSessionLinkExecutionRuntime {
    /// Exact local object ownership, independently of any attached presentation. This does not
    /// prove link consent, canonical placement, provider routing or permission to start a turn.
    func ownsSession(_ session: AgentTabSession) -> Bool {
        guard let scope, !scope.hasReleasedWriterClaims else { return false }
        return scope.sessions[session.tabID] === session
    }

    /// Resume the existing instruction owner, then acknowledge only the input physically handed
    /// to that continuation. User and lane-update accounting remain separate; an automatic wake
    /// is never charged as user input or materialized as a user row.
    @discardableResult
    func resumeWaitingInstructionContinuation(
        session: AgentTabSession,
        providerText: String,
        claim: AgentSessionLinkOutboundPromptClaim?,
        origin: UserInstructionResponse.Origin,
        inputProof: AgentSessionLinkProviderInputRelease.Proof? = nil,
        undecoratedProviderText: String? = nil
    ) -> Bool {
        guard let owner = scope, !owner.isRetiring, commands.isAvailable(), ownsSession(session),
              let continuation = session.instructionContinuation else { return false }
        defer { withExtendedLifetime(owner) {} }
        session.noteAcceptedTaskInput() // User and lane-update continuations reuse, never reset, the attempt.
        let released = inputProof.flatMap { proof in
            claim.map { agentSessionLinkHandoffProviderInput(for: session, dispatchID: $0.dispatchID, claim: $0, proof: proof) }
        }
        guard released?.mustAbortDispatch != true else { return false }
        let providerText = released.flatMap { release in undecoratedProviderText.map(release.text) } ?? providerText
        let claim = released == nil ? claim : released?.claim
        switch origin {
        case .user:
            owner.usage.addUserInputTokensToActiveNonCodexTurn(
                AgentSessionUsageRuntime.estimateRuntimeTokens(for: providerText),
                for: session
            )
        case .laneUpdateAutoWake:
            owner.usage.addToolInputTokens(providerText, for: session)
        }
        session.instructionTimeoutTask?.cancel()
        session.instructionTimeoutTask = nil
        session.instructionContinuation = nil
        session.instructionWaitID = nil
        session.waitingPrompt = nil
        session.runState = .running
        continuation.resume(returning: UserInstructionResponse(
            text: providerText,
            timedOut: false,
            elapsedSeconds: 0,
            origin: origin
        ))
        // Successful resume(returning:) remains the physical acceptance boundary.
        acceptAgentSessionLinkPromptClaim(claim)
        // Optional presentation can reenter or detach its legacy command owner. Publish only
        // after the physical delivery and its receipt are settled in this actor turn.
        updateBindingsFromSession(session)
        return true
    }
}
