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
        var prepareTerminal: ((AgentTabSession) -> Void)?
        var composerClaim: ((AgentTabSession) -> Void)?
        var composerStartWithdrawal: ((AgentTabSession, UUID) -> Void)?
        var binding: ((AgentTabSession) -> Void)?
        var interaction: ((AgentTabSession) -> Void)?
        var elapsedTime: ((AgentTabSession) -> Void)?
        var runState: ((AgentTabSession) -> Void)?
        var oversightBinding: ((AgentTabSession) -> Void)?
        var permissions: ((AgentTabSession) -> Void)?
        var worktreeOperations: ((AgentTabSession) -> Void)?
        var draftChanged: ((AgentTabSession, String) -> Void)?
        var draftRestored: ((AgentTabSession, AgentComposerDraftRestorationEvent) -> Void)?
        var modelConfiguration: ((AgentTabSession, AgentModelCatalogRuntime.Selection) -> Void)?
        var reasoningEffort: ((AgentTabSession) -> Void)?
        var mcpControl: ((AgentTabSession, Bool) -> Void)?
        var isAvailable: (() -> Bool)?
    }

    /// App-only projection. This sink cannot mutate a view model or supply runtime commands.
    struct DetachedSink {
        let turnComplete: (AgentTabSession) -> Void
        let turnFailed: (AgentTabSession, String?) -> Void
        let stateChanged: () -> Void
    }

    var detachedSink: DetachedSink?

    func hasPresenter(for session: AgentTabSession) -> Bool {
        sink(for: session) != nil
    }

    func refreshDetachedState() {
        detachedSink?.stateChanged()
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
    private var activeUISyncSuppressionDepth = 0

    var isActiveUISyncSuppressed: Bool {
        activeUISyncSuppressionDepth > 0
    }

    @discardableResult
    func withActiveUISyncSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        activeUISyncSuppressionDepth += 1
        defer { activeUISyncSuppressionDepth -= 1 }
        return try body()
    }

    func composerStartWithdrawn(_ session: AgentTabSession, attemptID: UUID) {
        sink(for: session)?.composerStartWithdrawal?(session, attemptID)
    }

    func composerClaimChanged(_ session: AgentTabSession) {
        sink(for: session)?.composerClaim?(session)
        requestUIRefresh(for: session, urgent: true)
    }

    func prepareTerminalPublication(_ session: AgentTabSession) {
        sink(for: session)?.prepareTerminal?(session)
    }

    func attach(_ session: AgentTabSession, sink: Sink) -> Attachment {
        entries = entries.filter { $0.value.session != nil }
        let attachment = Attachment(sessionIdentity: ObjectIdentifier(session), generation: UUID())
        entries[attachment.sessionIdentity] = Entry(session: session, attachment: attachment, sink: sink)
        refreshDetachedState()
        return attachment
    }

    func detach(_ attachment: Attachment) {
        guard entries[attachment.sessionIdentity]?.attachment == attachment else { return }
        entries.removeValue(forKey: attachment.sessionIdentity)
        refreshDetachedState()
    }

    private func sink(for session: AgentTabSession) -> Sink? {
        guard let entry = entries[ObjectIdentifier(session)], entry.session === session,
              entry.sink.isAvailable?() != false else { return nil }
        return entry.sink
    }

    func assistantDeltaApplied(_ session: AgentTabSession, sourceItemsRevision: Int, flushGeneration: UInt64) {
        sink(for: session)?.assistantDelta?(session, sourceItemsRevision, flushGeneration)
    }

    func mcpControlChanged(_ session: AgentTabSession, controlled: Bool) {
        if let sink = sink(for: session) { sink.mcpControl?(session, controlled) }
        else { refreshDetachedState() }
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
        if let sink = sink(for: session) { sink.runState?(session) }
        else { refreshDetachedState() }
    }

    func elapsedTimeChanged(_ session: AgentTabSession) {
        sink(for: session)?.elapsedTime?(session)
    }

    func bindingChanged(_ session: AgentTabSession) {
        if let sink = sink(for: session) { sink.binding?(session) }
        else { refreshDetachedState() }
    }

    func interactionChanged(_ session: AgentTabSession) {
        if let sink = sink(for: session) { sink.interaction?(session) }
        else { refreshDetachedState() }
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
            notifyAgentTurnComplete: { [self] session in
                if let sink = sink(for: session) { sink.turnComplete(session) }
                else { detachedSink?.turnComplete(session) }
            },
            notifyAgentTurnFailed: { [self] session, error in
                if let sink = sink(for: session) { sink.turnFailed(session, error) }
                else { detachedSink?.turnFailed(session, error) }
            }
        )
    }
}
