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
        publishesPresentation: Bool = true
    ) -> AgentSessionComposerSubmitClaimResult {
        let target = attempt.target
        guard let scope, let session = scope.sessions[target.tabID] else { return .rejected(.missingSession) }
        guard ObjectIdentifier(session) == attempt.sourceTabSessionIdentity else { return .rejected(.sourceSessionIdentityMismatch) }
        if let routing = freshTaskRoutingByTabID[target.tabID] {
            return .rejected(.activeAttemptExists(activeAttemptID: routing.requestID))
        }
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
        session.activeComposerSubmitAttempt = attempt
        session.composerSubmissionToken = UUID()
        let claim = AgentSessionComposerSubmitClaim(
            attempt: attempt, sourceSession: session, draftMutationGeneration: session.draftMutationGeneration,
            scope: scope, command: command
        )
        if publishesPresentation { scope.presentation.composerClaimChanged(session) }
        return .claimed(claim)
    }

    func isCurrent(_ claim: AgentSessionComposerSubmitClaim) -> Bool {
        guard let scope, claim.scope === scope, !scope.isRetiring, !scope.hasReleasedWriterClaims,
              ObjectIdentifier(claim.sourceSession) == claim.attempt.sourceTabSessionIdentity,
              scope.sessions[claim.attempt.sourceTabID] === claim.sourceSession,
              claim.sourceSession.activeComposerSubmitAttempt?.id == claim.attempt.id else { return false }
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
              claim.sourceSession.activeComposerSubmitAttempt?.id == claim.attempt.id else { return false }
        claim.sourceSession.activeComposerSubmitAttempt = nil
        scope.presentation.composerClaimChanged(claim.sourceSession)
        return true
    }

    /// Reconstruct only the cleanup receipt used by the existing pending-composer UI. A bound
    /// cleanup receipt has no command and cannot be submitted as an existing-session claim.
    func cleanupClaim(attempt: AgentComposerSubmitAttempt, session: AgentTabSession) -> AgentSessionComposerSubmitClaim? {
        guard let scope, scope.sessions[attempt.sourceTabID] === session,
              ObjectIdentifier(session) == attempt.sourceTabSessionIdentity,
              session.activeComposerSubmitAttempt?.id == attempt.id else { return nil }
        return .init(attempt: attempt, sourceSession: session, draftMutationGeneration: session.draftMutationGeneration, scope: scope, command: nil)
    }
}
