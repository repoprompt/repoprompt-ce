import Foundation

/// Optional exact-object presentation attachment. This is not a writer registration or a run
/// lifecycle owner: detach only stops projections. Runtime activity is updated even when no
/// presenter exists, and a late detach token cannot disconnect a newer presenter.
@MainActor
final class AgentSessionPresentationRuntime {
    struct Sink {
        let activityChanged: (AgentTabSession, Bool) -> Void
        let refresh: (AgentTabSession, Bool) -> Void
        let turnComplete: (AgentTabSession) -> Void
        let turnFailed: (AgentTabSession, String?) -> Void
        var assistantDelta: ((AgentTabSession, Int, UInt64) -> Void)?
        var derivedTranscript: ((AgentTabSession) -> Void)?
        var binding: ((AgentTabSession) -> Void)?
    }

    struct Attachment: Equatable {
        fileprivate let sessionIdentity: ObjectIdentifier
        fileprivate let generation: UUID
    }

    private struct Entry {
        weak var session: AgentTabSession?
        let attachment: Attachment
        let sink: Sink
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func attach(_ session: AgentTabSession, sink: Sink) -> Attachment {
        entries = entries.filter { $0.value.session != nil }
        let attachment = Attachment(sessionIdentity: ObjectIdentifier(session), generation: UUID())
        entries[attachment.sessionIdentity] = Entry(session: session, attachment: attachment, sink: sink)
        return attachment
    }

    func detach(_ attachment: Attachment) {
        guard entries[attachment.sessionIdentity]?.attachment == attachment else { return }
        entries.removeValue(forKey: attachment.sessionIdentity)
    }

    private func sink(for session: AgentTabSession) -> Sink? {
        guard let entry = entries[ObjectIdentifier(session)], entry.session === session else { return nil }
        return entry.sink
    }

    func assistantDeltaApplied(_ session: AgentTabSession, sourceItemsRevision: Int, flushGeneration: UInt64) {
        sink(for: session)?.assistantDelta?(session, sourceItemsRevision, flushGeneration)
    }

    func bindingChanged(_ session: AgentTabSession) {
        sink(for: session)?.binding?(session)
    }

    func derivedTranscriptChanged(_ session: AgentTabSession) {
        sink(for: session)?.derivedTranscript?(session)
    }

    static func applyRunActivity(to session: AgentTabSession, isActive: Bool) {
        if isActive {
            if session.activeAgentRunStartedAt == nil { session.activeAgentRunStartedAt = Date() }
        } else {
            session.activeAgentRunStartedAt = nil
            session.deferredActiveAgentRunTimerRollback = nil
        }
    }

    func makeRunHooks() -> AgentModeRunService.RunPresentationHooks {
        .init(
            setAgentRunActive: { [self] session, isActive in
                Self.applyRunActivity(to: session, isActive: isActive)
                sink(for: session)?.activityChanged(session, isActive)
            },
            requestUIRefresh: { [self] session, urgent in sink(for: session)?.refresh(session, urgent) },
            notifyAgentTurnComplete: { [self] session in sink(for: session)?.turnComplete(session) },
            notifyAgentTurnFailed: { [self] session, error in sink(for: session)?.turnFailed(session, error) }
        )
    }
}
