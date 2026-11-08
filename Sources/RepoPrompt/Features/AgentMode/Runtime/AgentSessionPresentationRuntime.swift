import Foundation

/// In-memory projection scope; no persisted or reflected type identity is changed.
enum AgentSessionPresentationRefreshScope: String, Equatable, Hashable {
    case full
    case transcriptRuntime
    case runtimeMetrics
}

/// Optional exact-object presentation attachment. This is not a writer registration or a run
/// lifecycle owner: detach only stops projections. Runtime activity is updated even when no
/// presenter exists, and a late detach token cannot disconnect a newer presenter.
@MainActor
final class AgentSessionPresentationRuntime {
    struct Sink {
        let activityChanged: (AgentTabSession, Bool) -> Void
        let refresh: (AgentTabSession, Bool, AgentSessionPresentationRefreshScope) -> Void
        let turnComplete: (AgentTabSession) -> Void
        let turnFailed: (AgentTabSession, String?) -> Void
        var assistantDelta: ((AgentTabSession, Int, UInt64) -> Void)?
        var derivedTranscript: ((AgentTabSession) -> Void)?
        var binding: ((AgentTabSession) -> Void)?
        var elapsedTime: ((AgentTabSession) -> Void)?
        var runState: ((AgentTabSession) -> Void)?
        var oversightBinding: ((AgentTabSession) -> Void)?
        var permissions: ((AgentTabSession) -> Void)?
        var worktreeOperations: ((AgentTabSession) -> Void)?
        var draftChanged: ((AgentTabSession, String) -> Void)?
        var draftRestored: ((AgentTabSession, AgentComposerDraftRestorationEvent) -> Void)?
        var modelConfiguration: ((AgentTabSession, AgentModelCatalogRuntime.Selection) -> Void)?
        var reasoningEffort: ((AgentTabSession) -> Void)?
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

    func permissionsChanged(_ session: AgentTabSession) {
        sink(for: session)?.permissions?(session)
    }

    func worktreeOperationsChanged(_ session: AgentTabSession) {
        sink(for: session)?.worktreeOperations?(session)
    }

    func draftChanged(_ session: AgentTabSession, previousText: String) {
        sink(for: session)?.draftChanged?(session, previousText)
    }

    func draftRestored(_ session: AgentTabSession, event: AgentComposerDraftRestorationEvent) {
        sink(for: session)?.draftRestored?(session, event)
    }

    func modelConfigurationChanged(_ session: AgentTabSession, selection: AgentModelCatalogRuntime.Selection) {
        sink(for: session)?.modelConfiguration?(session, selection)
    }

    func reasoningEffortChanged(_ session: AgentTabSession) {
        sink(for: session)?.reasoningEffort?(session)
    }

    func oversightBindingChanged(_ session: AgentTabSession) {
        sink(for: session)?.oversightBinding?(session)
    }

    func runStateChanged(_ session: AgentTabSession) {
        sink(for: session)?.runState?(session)
    }

    func elapsedTimeChanged(_ session: AgentTabSession) {
        sink(for: session)?.elapsedTime?(session)
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

    func setAgentRunActive(_ session: AgentTabSession, isActive: Bool) {
        Self.applyRunActivity(to: session, isActive: isActive)
        sink(for: session)?.activityChanged(session, isActive)
    }

    func requestUIRefresh(for session: AgentTabSession, urgent: Bool = false, scope: AgentSessionPresentationRefreshScope = .full) {
        sink(for: session)?.refresh(session, urgent, scope)
    }

    func makeRunHooks() -> AgentModeRunService.RunPresentationHooks {
        .init(
            setAgentRunActive: { [self] session, isActive in
                setAgentRunActive(session, isActive: isActive)
            },
            requestUIRefresh: { [self] session, urgent in requestUIRefresh(for: session, urgent: urgent) },
            notifyAgentTurnComplete: { [self] session in sink(for: session)?.turnComplete(session) },
            notifyAgentTurnFailed: { [self] session, error in sink(for: session)?.turnFailed(session, error) }
        )
    }
}
