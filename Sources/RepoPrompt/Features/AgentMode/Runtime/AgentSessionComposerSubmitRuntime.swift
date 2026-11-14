import Foundation

/// A transient claim retains its originating scope, not a presentation. Existing-session claims
/// also pin command admission; unbound local creation keeps the same object through its first bind.
@MainActor
struct AgentSessionComposerSubmitClaim {
    let attempt: AgentComposerSubmitAttempt
    let sourceSession: AgentTabSession
    let draftMutationGeneration: UInt64
    let scope: AgentSessionRuntimeStore.Scope
    let command: AgentSessionRuntimeStore.Command?
    let cancellation: AgentComposerStartCancellation
}

enum AgentSessionComposerSubmitClaimRejection: Equatable {
    case missingSession
    case sourceSessionIdentityMismatch
    case activeAttemptExists(activeAttemptID: UUID)
    case targetRejected(reason: String)
    case initialWorktreePreparationInProgress
    case executionLocationChangeInProgress

    var diagnosticReason: String {
        switch self {
        case .missingSession: "missing_session"
        case .sourceSessionIdentityMismatch: "source_session_identity_mismatch"
        case .activeAttemptExists: "existing_claim"
        case let .targetRejected(reason): reason
        case .initialWorktreePreparationInProgress: "initial_worktree_preparation_in_progress"
        case .executionLocationChangeInProgress: "execution_location_change_in_progress"
        }
    }
}

enum AgentSessionComposerSubmitClaimResult {
    case claimed(AgentSessionComposerSubmitClaim)
    case rejected(AgentSessionComposerSubmitClaimRejection)
}

/// The sole check-and-mutate body for the session's existing submission claim. Local focus,
/// draft and creation-target checks remain presentation inputs; programmatic targets use only
/// an admitted writer. This is not a second submission ledger or a run-lifecycle owner.
@MainActor
final class AgentSessionComposerSubmitRuntime {
    private weak var scope: AgentSessionRuntimeStore.Scope?
    var freshTaskRoutingByTabID: [UUID: AgentModeViewModel.FreshTaskRoutingOwnership] = [:]

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func programmaticTarget(_ command: AgentSessionRuntimeStore.Command) -> AgentComposerSubmitTarget? {
        guard let scope, command.writer.scope === scope, command.isCurrent else { return nil }
        let session = command.writer.session
        guard !session.isComposerSubmissionInFlight, !session.isPreparingInitialWorktree,
              !session.isChangingExecutionLocation,
              !session.runState.isActive || session.runID != nil else { return nil }
        return AgentComposerSubmitTarget(
            tabID: session.tabID, route: .existingAgentSession,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: command.identity.sessionID,
            expectedPersistentBindingIdentity: command.writer.binding,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: session.runState, expectedRunID: session.runID,
            expectedRunAttemptID: session.activeRunAttemptID,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: nil, expectedWriterIdentity: command.identity
        )
    }

    func claim(
        _ attempt: AgentComposerSubmitAttempt,
        command suppliedCommand: AgentSessionRuntimeStore.Command? = nil,
        presentationRejection: String? = nil,
        publishesPresentation: Bool = true,
        awaitsExecutor: Bool = false,
        allowsPendingStartWithdrawal: Bool = true
    ) -> AgentSessionComposerSubmitClaimResult {
        let target = attempt.target
        guard let scope, let session = scope.sessions[target.tabID] else { return .rejected(.missingSession) }
        guard ObjectIdentifier(session) == attempt.sourceTabSessionIdentity else { return .rejected(.sourceSessionIdentityMismatch) }
        if let routing = freshTaskRoutingByTabID[target.tabID] {
            return .rejected(.activeAttemptExists(activeAttemptID: routing.requestID))
        }
        if let pending = session.composerStartCancellation { return .rejected(.activeAttemptExists(activeAttemptID: pending.attemptID)) }
        if let active = session.activeComposerSubmitAttempt { return .rejected(.activeAttemptExists(activeAttemptID: active.id)) }
        guard !scope.isRetiring, !scope.hasReleasedWriterClaims else { return .rejected(.targetRejected(reason: "writer_retiring")) }
        if session.restorationAdmissionFailureMessage != nil { return .rejected(.targetRejected(reason: "restoration_unavailable")) }
        guard session.composerSubmissionToken == target.expectedSubmissionToken else { return .rejected(.targetRejected(reason: "submission_token_mismatch")) }
        if let presentationRejection { return .rejected(.targetRejected(reason: presentationRejection)) }

        let command: AgentSessionRuntimeStore.Command?
        switch target.route {
        case .existingAgentSession:
            guard let id = target.expectedSourceAgentSessionID, session.activeAgentSessionID == id,
                  session.persistentSessionBindingIdentity == target.expectedPersistentBindingIdentity,
                  session.bindingTransitionGeneration == target.expectedBindingTransitionGeneration,
                  case let .unique(writer) = scope.resolveWriter(sessionID: id),
                  writer.scope === scope, writer.session === session,
                  target.expectedWriterIdentity == writer.identity,
                  let admitted = suppliedCommand ?? (try? writer.admitCommand().get()),
                  admitted.writer.scope === scope, admitted.writer.session === session,
                  admitted.identity == writer.identity, admitted.isCurrent
            else { return .rejected(.targetRejected(reason: "writer_unavailable")) }
            command = admitted
        case .createAgentSessionFromSourceTab:
            guard suppliedCommand == nil, session.activeAgentSessionID == nil,
                  target.expectedSourceAgentSessionID == nil, session.persistentSessionBindingIdentity == nil,
                  !session.bindingTransitionInProgress,
                  session.bindingTransitionGeneration == target.expectedBindingTransitionGeneration,
                  session.runState == target.expectedRunState, !session.runState.isActive,
                  session.runID == nil, target.expectedRunID == nil,
                  session.activeRunAttemptID == nil, target.expectedRunAttemptID == nil
            else { return .rejected(.targetRejected(reason: "unlinked_source_has_run_identity")) }
            command = nil
        }
        if session.isPreparingInitialWorktree { return .rejected(.initialWorktreePreparationInProgress) }
        if session.isChangingExecutionLocation { return .rejected(.executionLocationChangeInProgress) }
        // Install the exact cancellation capability before either observer-visible publication.
        let cancellation = AgentComposerStartCancellation(attempt: attempt, source: session, runtime: self, awaitsExecutor: awaitsExecutor, allowsPendingStartWithdrawal: allowsPendingStartWithdrawal)
        session.composerStartCancellation = cancellation
        session.activeComposerSubmitAttempt = attempt
        session.composerSubmissionToken = UUID()
        let claim = AgentSessionComposerSubmitClaim(
            attempt: attempt, sourceSession: session, draftMutationGeneration: session.draftMutationGeneration,
            scope: scope, command: command, cancellation: cancellation
        )
        if publishesPresentation { scope.presentation.composerClaimChanged(session) }
        return .claimed(claim)
    }

    func isCurrent(_ claim: AgentSessionComposerSubmitClaim) -> Bool {
        guard let scope, claim.scope === scope, !scope.isRetiring, !scope.hasReleasedWriterClaims,
              ObjectIdentifier(claim.sourceSession) == claim.attempt.sourceTabSessionIdentity,
              scope.sessions[claim.attempt.sourceTabID] === claim.sourceSession,
              claim.sourceSession.activeComposerSubmitAttempt?.id == claim.attempt.id,
              claim.sourceSession.composerStartCancellation === claim.cancellation,
              !claim.cancellation.isWithdrawn else { return false }
        if let command = claim.command { return command.isCurrent }
        // Local creation deliberately acquires its first persistent binding after claiming input.
        // Its creation owner and run-start admission remain responsible for that binding's effects.
        guard claim.attempt.target.route == .createAgentSessionFromSourceTab,
              !claim.sourceSession.bindingTransitionInProgress else { return false }
        guard let sessionID = claim.sourceSession.activeAgentSessionID else { return true }
        guard case let .unique(writer) = scope.resolveWriter(sessionID: sessionID),
              writer.scope === scope, writer.session === claim.sourceSession else { return false }
        return writer.isCurrent
    }

    /// Cleanup never requires new-command admission. It may release a retired or replaced
    /// originating object, but cannot clear a different object's or newer attempt's claim.
    @discardableResult
    func release(_ claim: AgentSessionComposerSubmitClaim) -> Bool {
        guard let scope, claim.scope === scope,
              ObjectIdentifier(claim.sourceSession) == claim.attempt.sourceTabSessionIdentity,
              claim.sourceSession.composerStartCancellation === claim.cancellation else { return false }
        claim.cancellation.release()
        return true
    }

    func alias(_ claim: AgentSessionComposerSubmitClaim, to destination: AgentTabSession) -> Bool {
        guard isCurrent(claim), let scope, scope.sessions[destination.tabID] === destination,
              destination.composerStartCancellation == nil,
              let id = destination.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: id),
              writer.session === destination, writer.isCurrent,
              !destination.runState.isActive, destination.activeRunOwnership == nil else { return false }
        claim.cancellation.alias(to: destination, identity: writer.identity)
        destination.composerStartCancellation = claim.cancellation
        destination.noteMonitorObservationInputsChanged()
        scope.presentation.composerClaimChanged(destination)
        return true
    }

    fileprivate func isCurrent(_ cancellation: AgentComposerStartCancellation, on session: AgentTabSession) -> Bool {
        guard let scope, !scope.isRetiring, !scope.hasReleasedWriterClaims,
              scope.sessions[session.tabID] === session,
              session.composerStartCancellation === cancellation else { return false }
        if let source = cancellation.source, scope.sessions[source.tabID] === source {
            guard source.composerStartCancellation === cancellation,
                  source.activeComposerSubmitAttempt?.id == cancellation.attemptID else { return false }
            if let identity = cancellation.sourceWriterIdentity {
                guard let id = source.activeAgentSessionID,
                      case let .unique(writer) = scope.resolveWriter(sessionID: id),
                      writer.session === source, writer.identity == identity, writer.isCurrent else { return false }
            } else if source.bindingTransitionInProgress { return false }
        } else {
            // After L2, the admitted destination owns its exact start even if the old compose
            // source closes first. This receipt never authorizes commands on a replacement source.
            guard cancellation.hasReleasedClaim, session === cancellation.destination else { return false }
        }
        if let destination = cancellation.destination {
            guard let id = destination.activeAgentSessionID,
                  scope.sessions[destination.tabID] === destination,
                  case let .unique(writer) = scope.resolveWriter(sessionID: id),
                  writer.session === destination, writer.identity == cancellation.destinationWriterIdentity,
                  writer.isCurrent else { return false }
        }
        return session === cancellation.source || session === cancellation.destination
    }

    fileprivate func restoreDraft(_ cancellation: AgentComposerStartCancellation, message: String = "Send cancelled. Your draft was restored.") {
        guard let scope else { return }
        // Draft recovery is cleanup, not command admission. Preserve it after a rebind/retirement
        // on the originating object (or in pending-tab storage), never in a recycled tab object.
        if let current = scope.sessions[cancellation.sourceTabID], ObjectIdentifier(current) != cancellation.sourceObjectIdentity { return }
        guard let draft = cancellation.takeOwedDraft() else { return }
        scope.drafts.restore(tabID: cancellation.sourceTabID, text: draft, message: message, strategy: .prependAlways)
    }

    fileprivate func withdrawOptimisticInput(_ cancellation: AgentComposerStartCancellation) {
        guard let scope, let session = cancellation.runTarget,
              scope.sessions[session.tabID] === session,
              let itemID = cancellation.optimisticUserItemID else { return }
        if let index = session.items.firstIndex(where: { $0.id == itemID }) { _ = session.removeItem(at: index) }
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == itemID }
        session.isDirty = true
        scope.persistence.scheduleSave(for: session)
    }

    fileprivate func unpublish(_ cancellation: AgentComposerStartCancellation) {
        guard let scope, let source = cancellation.source,
              source.composerStartCancellation === cancellation else { return }
        if source.activeComposerSubmitAttempt?.id == cancellation.attemptID { source.activeComposerSubmitAttempt = nil }
        scope.presentation.composerStartWithdrawn(source, attemptID: cancellation.attemptID)
        scope.presentation.composerClaimChanged(source)
    }

    fileprivate func finalize(_ cancellation: AgentComposerStartCancellation) {
        guard let scope else { return }
        // Remove the capability before unpublishing; exact-object cleanup cannot erase a successor.
        if let source = cancellation.source, source.composerStartCancellation === cancellation {
            source.composerStartCancellation = nil
            if source.activeComposerSubmitAttempt?.id == cancellation.attemptID { source.activeComposerSubmitAttempt = nil }
            source.noteMonitorObservationInputsChanged()
            scope.presentation.composerClaimChanged(source)
        }
        if let destination = cancellation.destination, destination.composerStartCancellation === cancellation {
            destination.composerStartCancellation = nil
            destination.noteMonitorObservationInputsChanged()
            scope.presentation.composerClaimChanged(destination)
        }
    }

    /// Reconstruct only the cleanup receipt used by the existing pending-composer UI. A bound
    /// cleanup receipt has no command and cannot be submitted as an existing-session claim.
    func cleanupClaim(attempt: AgentComposerSubmitAttempt, session: AgentTabSession) -> AgentSessionComposerSubmitClaim? {
        guard let scope, scope.sessions[attempt.sourceTabID] === session,
              ObjectIdentifier(session) == attempt.sourceTabSessionIdentity,
              session.activeComposerSubmitAttempt?.id == attempt.id,
              let cancellation = session.composerStartCancellation, cancellation.attemptID == attempt.id else { return nil }
        return .init(attempt: attempt, sourceSession: session, draftMutationGeneration: session.draftMutationGeneration, scope: scope, command: nil, cancellation: cancellation)
    }
}

/// One claim's pre-prologue cancellation receipt, not a second run-lifecycle owner. Sessions and
/// producers share this identity; all back references are weak. Only the real producer's release
/// acknowledges drain, even when Stop has already withdrawn its visible claim.
@MainActor
final class AgentComposerStartCancellation {
    let attemptID: UUID
    let sourceTabID: UUID
    let sourceObjectIdentity: ObjectIdentifier
    let sourceWriterIdentity: AgentSessionRuntimeStore.WriterIdentity?
    private(set) weak var source: AgentTabSession?
    private(set) weak var destination: AgentTabSession?
    private(set) var destinationWriterIdentity: AgentSessionRuntimeStore.WriterIdentity?
    private weak var runtime: AgentSessionComposerSubmitRuntime?
    private let allowsPendingStartWithdrawal: Bool
    private var preparationOwners: Set<ObjectIdentifier> = []
    private var owedDraft: String?
    private var stopFence: AgentRunStartStopFence
    private(set) var optimisticUserItemID: UUID?
    private var executorEntered: Bool
    private var executionClaimed = false
    private var releaseRequested = false
    private var producerCount = 0
    private(set) var isWithdrawn = false
    private(set) var didLaunch: Bool
    private(set) var didRestoreDraft = false
    private(set) var isFinalized = false
    let finalized = AgentSessionLinkStopSignal<Void>()

    init(attempt: AgentComposerSubmitAttempt, source: AgentTabSession, runtime: AgentSessionComposerSubmitRuntime, awaitsExecutor: Bool, allowsPendingStartWithdrawal: Bool) {
        attemptID = attempt.id
        sourceTabID = source.tabID
        sourceObjectIdentity = ObjectIdentifier(source)
        sourceWriterIdentity = attempt.target.expectedWriterIdentity
        self.source = source
        self.runtime = runtime
        self.allowsPendingStartWithdrawal = allowsPendingStartWithdrawal
        executorEntered = !awaitsExecutor
        stopFence = AgentRunStartStopFence(session: source)
        didLaunch = source.runState.isActive || source.activeRunOwnership != nil
    }

    var runTarget: AgentTabSession? {
        destination ?? source
    }

    fileprivate var hasReleasedClaim: Bool {
        releaseRequested
    }

    func awaitFinalization(timeout: TimeInterval = AgentRunStopState.managedStopDeadlineSeconds) async -> Bool {
        if isFinalized { return true }
        let result = AgentSessionLinkStopSignal<Bool>()
        Task { [finalized] in await finalized.value()
            result.finish(true)
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            result.finish(false)
        }
        defer { deadline.cancel() }
        return await result.value()
    }

    /// Cancel only an uncommitted presentation input, including a prospective steer. This is
    /// not Stop on the existing run and must not invalidate its continuation generations.
    @discardableResult
    func cancelPresentedInput(on session: AgentTabSession) -> Bool {
        guard session === source, session.composerStartCancellation === self,
              optimisticUserItemID == nil, !isWithdrawn, !isFinalized else { return false }
        isWithdrawn = true
        runtime?.restoreDraft(self)
        runtime?.unpublish(self)
        if !executorEntered { releaseRequested = true }
        finalizeIfReleased()
        return true
    }

    func beginExecution() -> Bool {
        guard !executionClaimed, !isWithdrawn, !isFinalized else { return false }
        executionClaimed = true
        executorEntered = true
        return true
    }

    func oweDraftRestoration(_ text: String) {
        guard !didRestoreDraft, !isWithdrawn, !isFinalized else { return }
        owedDraft = text
    }

    func restoreOwedDraftIfNeeded(message: String = "Send cancelled. Your draft was restored.") {
        runtime?.restoreDraft(self, message: message)
    }

    fileprivate func takeOwedDraft() -> String? {
        guard let text = owedDraft else { return nil }
        owedDraft = nil
        didRestoreDraft = true
        return text
    }

    fileprivate func alias(to session: AgentTabSession, identity: AgentSessionRuntimeStore.WriterIdentity) {
        destination = session
        destinationWriterIdentity = identity
        stopFence = AgentRunStartStopFence(session: session)
    }

    func pendingStartFence(for session: AgentTabSession) -> AgentRunStartStopFence? {
        guard session === runTarget, !isWithdrawn, !isFinalized,
              runtime?.isCurrent(self, on: session) == true else { return nil }
        // L2 handoff: the caller has just rechecked its claim in this same actor turn. Refresh
        // here, never inside the deferred producer; internal preparation cancels are not Stop.
        stopFence = AgentRunStartStopFence(session: session)
        return stopFence
    }

    func recordOptimisticInput(_ itemID: UUID, on session: AgentTabSession) {
        guard session === runTarget, !isWithdrawn else { return }
        optimisticUserItemID = itemID
    }

    func ownsInitialPreparation(on session: AgentTabSession) {
        preparationOwners.insert(ObjectIdentifier(session))
    }

    func canWithdraw(on session: AgentTabSession) -> Bool {
        guard allowsPendingStartWithdrawal, !isWithdrawn, !didLaunch, !isFinalized, let target = runTarget,
              !target.runState.isActive, target.activeRunOwnership == nil,
              !session.isChangingExecutionLocation, !session.selfCompactState.blocksManagedStop,
              !session.isPreparingInitialWorktree || preparationOwners.contains(ObjectIdentifier(session)),
              runtime?.isCurrent(self, on: session) == true else { return false }
        return true
    }

    /// Called only after exact local/managed Stop admission, without a suspension.
    @discardableResult
    func withdraw(on session: AgentTabSession) -> Bool {
        guard canWithdraw(on: session) else { return false }
        isWithdrawn = true
        source?.stopState.invalidateScheduledStarts()
        if let destination, destination !== source { destination.stopState.invalidateScheduledStarts() }
        runtime?.withdrawOptimisticInput(self)
        runtime?.restoreDraft(self)
        runtime?.unpublish(self)
        // A queued executor which never entered has no effects to join. It will fail its first
        // guard if it arrives late. An entered executor must release its own suspended effects.
        if !executorEntered { releaseRequested = true }
        finalizeIfReleased()
        return true
    }

    /// The runner installs ownership synchronously before publishing running. Never restore an
    /// input after that handoff, even if its composer executor has not returned yet.
    func runAttemptBegan(on session: AgentTabSession) {
        guard !isWithdrawn, !isFinalized, session === runTarget else { return }
        didLaunch = true
        finalizeIfReleased()
    }

    /// Register before creating a child task, not on its first scheduled actor turn.
    func retainProducer() {
        producerCount += 1
    }

    func releaseProducer() {
        precondition(producerCount > 0)
        producerCount -= 1
        finalizeIfReleased()
    }

    fileprivate func release() {
        releaseRequested = true
        finalizeIfReleased()
    }

    private func finalizeIfReleased() {
        guard releaseRequested, producerCount == 0 || (didLaunch && !isWithdrawn), !isFinalized else { return }
        isFinalized = true
        runtime?.finalize(self)
        finalized.finish(())
    }
}
