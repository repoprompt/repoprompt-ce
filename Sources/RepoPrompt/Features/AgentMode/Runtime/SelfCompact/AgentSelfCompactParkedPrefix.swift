import Foundation

/// Ordinary sends may carry a parked continuation. Reading the frame does not consume it;
/// only the provider-acceptance helpers below do.
enum AgentSelfCompactParkedPrefix {
    struct Carry: Equatable {
        var text: String
        var dispatchID: AgentSelfCompactionDispatchID?
        /// The whole provider input is the framed note. Do not decorate or prefix it again.
        var exactNote = false
    }

    @MainActor
    static func prepare(
        _ text: String,
        session: AgentTabSession,
        scheduleSave: @MainActor () -> Void
    ) -> Carry {
        if let dedicated = dedicatedNoteID(text: text, session: session) {
            return Carry(text: text, dispatchID: dedicated, exactNote: true)
        }
        var state = session.selfCompactState
        if state.cancelStaleParkedNote(for: session) {
            session.selfCompactState = state
            scheduleSave()
        }
        guard let parked = session.selfCompactState.parkedNote else {
            return Carry(text: text, dispatchID: nil)
        }
        return Carry(text: parked.frame + "\n\n" + text, dispatchID: parked.dispatchID)
    }

    @MainActor
    static func markAttempted(_ dispatchID: AgentSelfCompactionDispatchID, session: AgentTabSession) -> Bool {
        var state = session.selfCompactState
        guard state.noteWillAttempt(dispatchID) else { return false }
        session.selfCompactState = state
        return true
    }

    @MainActor
    @discardableResult
    static func markAccepted(_ dispatchID: AgentSelfCompactionDispatchID, session: AgentTabSession) -> Bool {
        var state = session.selfCompactState
        guard state.noteAccepted(dispatchID) else { return false }
        session.selfCompactState = state
        session.appendItem(
            AgentChatItem.selfCompactionNoteRestored(sequenceIndex: session.nextSequenceIndex)
        )
        return true
    }

    @MainActor
    static func markTransportFailed(_ dispatchID: AgentSelfCompactionDispatchID, session: AgentTabSession) {
        var state = session.selfCompactState
        _ = state.noteTransportFailed(dispatchID)
        session.selfCompactState = state
    }

    @MainActor
    static func markNotAttempted(_ dispatchID: AgentSelfCompactionDispatchID, session: AgentTabSession) {
        var state = session.selfCompactState
        // ACP invokes this only before its own transport attempt. A suspended dedicated sender
        // must not clear the marker after an ordinary sender has claimed the same note.
        guard state.active?.noteDispatchStarted == false,
              state.noteDefinitivelyNotAttempted(dispatchID)
        else { return }
        session.selfCompactState = state
    }

    /// A dedicated note that never reached `session/prompt` can safely be carried by the next
    /// ordinary input. This is not used after transport was attempted.
    @MainActor
    @discardableResult
    static func reparkUnattemptedDedicatedNote(
        _ dispatchID: AgentSelfCompactionDispatchID,
        session: AgentTabSession,
        scheduleSave: @MainActor () -> Void
    ) -> Bool {
        var state = session.selfCompactState
        guard state.active?.noteDispatchStarted == false,
              state.noteDefinitivelyNotAttempted(dispatchID)
        else { return false }
        session.selfCompactState = state
        scheduleSave()
        return true
    }

    @MainActor
    static func preparedDedicatedNoteID(
        _ text: String,
        session: AgentTabSession
    ) -> AgentSelfCompactionDispatchID? {
        dedicatedNoteID(text: text, session: session)
    }

    @MainActor
    private static func dedicatedNoteID(
        text: String,
        session: AgentTabSession
    ) -> AgentSelfCompactionDispatchID? {
        guard let active = session.selfCompactState.active,
              active.phase == .dispatchingNote || active.phase == .noteDispatchPending,
              active.noteDispatchStarted == false,
              text == AgentSelfCompactNoteEnvelope.frame(active.note)
        else { return nil }
        return AgentSelfCompactionDispatchID(requestID: active.id, stage: .note)
    }
}
