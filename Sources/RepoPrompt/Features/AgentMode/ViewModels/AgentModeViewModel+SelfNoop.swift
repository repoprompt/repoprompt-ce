import Foundation
import RepoPromptDomainRuntime

extension AgentModeViewModel {
    /// Count the body, not registration or a deduplicated transcript representation. A suspended
    /// old body never counts against a replacement attempt.
    func enterSelfNoopBody(origin: AgentSelfMCPCallOrigin, invocationID: UUID, argumentsAreEmpty: Bool) {
        guard let session = sessions[origin.endpoint.tabID], session.runID == origin.runID,
              let owner = session.activeRunOwnership, owner.attemptID == origin.runAttemptID,
              session.isCurrentRunAttemptForCurrentBinding(owner) else { return }
        session.quietLedger.enterDeclarationBody(owner: owner, hostInvocationID: invocationID)
        if !argumentsAreEmpty || session.hasOwnPendingQuietInteraction {
            session.quietLedger.noteOccurrence(owner: owner)
        }
    }

    /// Acceptance is provisional. Call acknowledgement never depends on this verdict.
    func acceptSelfNoopBody(origin: AgentSelfMCPCallOrigin, endpoint: DomainAgentSessionLinkEndpointIdentity?, invocationID: UUID) {
        guard let session = sessions[origin.endpoint.tabID], session.runID == origin.runID,
              let owner = session.activeRunOwnership, owner.attemptID == origin.runAttemptID,
              session.isCurrentRunAttemptForCurrentBinding(owner) else { return }
        guard let endpoint, agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint,
              let wakeID = session.quietLedger.routineWakeID(owner: owner),
              !session.hasOwnPendingQuietInteraction
        else {
            session.quietLedger.noteOccurrence(owner: owner)
            return
        }
        session.quietLedger.acceptDeclarationBody(
            owner: owner, hostInvocationID: invocationID, wakeID: wakeID,
            origin: origin, currentEndpoint: endpoint, currentRunID: session.runID
        )
    }
}
