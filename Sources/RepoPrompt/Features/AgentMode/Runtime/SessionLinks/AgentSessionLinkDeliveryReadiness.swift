import Foundation
import RepoPromptDomainRuntime

// The pure, table-provable admission decision for an attributed cross-session `send`.
//
// Owns the `Snapshot` of target facts, the wire-stable `BlockReason` vocabulary the observer's
// guidance names, and `evaluate(snapshot:)`. `AgentModeViewModel+SessionLinkSend` assembles the
// snapshot from live `AgentTabSession` state (including `oversight.hasPendingAutoWake`) and the
// `AgentSessionLinkPendingSend` queue re-evaluates it when a target may have become sendable.
// Invariants: every blocker is a fact about the target and nothing about the caller; precedence is
// fixed so a permanent endpoint invalidation is never reported as a retryable state; and a waiting
// target is never ready. `AgentModeViewModel+SessionLinkAutoWake` reuses this same blocker set,
// minus the two that describe the wake itself, so no blocker can be enforced for one caller and
// forgotten for the other.

// MARK: - Readiness

/// Pure admission decision for an attributed cross-session send.
///
/// Deliberately a free function over a value snapshot: the full blocker matrix is the security
/// contract of `send`, and it must be provable by a truth table rather than by driving a live
/// `AgentModeViewModel` through every combination of run, wait, interaction, queue, and transition
/// state. The target's MainActor assembles the snapshot immediately before claiming submission, and
/// the same snapshot is re-evaluated after the authorization commit hop.
enum AgentSessionLinkDeliveryReadiness {
    /// Every verified blocker, all of them facts about the **target**.
    ///
    /// Nothing about the caller appears here. The user's exact direct oversight grant is the
    /// delegation for this surface, so admission depends on whether the target can safely accept a
    /// message — never on what started the caller's own turn.
    ///
    /// Field-for-field this mirrors live `TabSession` state; nothing is derived here so a future
    /// blocker cannot be silently dropped by an intermediate projection.
    struct Snapshot: Equatable {
        // Target identity/lifecycle
        var hasLoadedPersistedState: Bool
        var restorationReadiness: AgentSessionRestorationReadiness
        var bindingTransitionInProgress: Bool
        var isClosing: Bool
        var endpointMatchesGrant: Bool

        // Target run state
        var runStateIsActive: Bool
        var terminalCommitInProgress: Bool
        var mcpFollowUpRunPending: Bool
        var isComposerSubmissionInFlight: Bool
        var isPreparingInitialWorktree: Bool
        var isChangingExecutionLocation: Bool

        // Target queues
        var pendingInstructionCount: Int
        var pendingACPSteeringCount: Int
        var pendingClaudeSteeringCount: Int
        /// This session has already reserved its one automatic lane-update follow-up.
        ///
        /// Source-compatible default `false`. A reservation is work the session is committed to, so
        /// another observer must not `send` into it any more than into an active run — otherwise the
        /// wake and the send race for the same terminal boundary.
        var pendingOversightAutoWake: Bool = false
        /// An in-flight self-compaction owns the next provider boundary.
        var pendingSelfCompact: Bool = false
        /// Narrower than `pendingSelfCompact`: RepoPrompt itself owns an unsent self-compaction
        /// dispatch. Only this refuses managed Stop; the caller's originating turn, a parked note,
        /// and a note whose send already started remain stoppable.
        var selfCompactBlocksManagedStop: Bool = false
        /// A binding-qualified managed stop owns this target until cleanup releases its gate.
        var stopInProgress: Bool = false
        /// A fire-and-forget ACP compaction may still be running in the provider's background, where
        /// a new prompt would cancel it. Held off for its settle window like any other target work.
        var backgroundCompactionSettling: Bool = false

        // Target interactions. Waiting states are never ready: answering one would be a different
        // capability than sending a new instruction, and `send` never gains it.
        var hasWaitingPrompt: Bool
        var hasPendingAskUser: Bool
        var hasPendingUserInputRequest: Bool
        var hasPendingApproval: Bool
        var hasPendingPermissionsRequest: Bool
        var hasPendingMCPElicitationRequest: Bool
        var hasPendingApplyEditsReview: Bool
        var hasPendingWorktreeMergeReview: Bool

        init(
            hasLoadedPersistedState: Bool,
            restorationReadiness: AgentSessionRestorationReadiness,
            bindingTransitionInProgress: Bool,
            isClosing: Bool,
            endpointMatchesGrant: Bool,
            runStateIsActive: Bool,
            terminalCommitInProgress: Bool,
            mcpFollowUpRunPending: Bool,
            isComposerSubmissionInFlight: Bool,
            isPreparingInitialWorktree: Bool,
            isChangingExecutionLocation: Bool,
            pendingInstructionCount: Int,
            pendingACPSteeringCount: Int,
            pendingClaudeSteeringCount: Int,
            pendingOversightAutoWake: Bool = false,
            pendingSelfCompact: Bool = false,
            selfCompactBlocksManagedStop: Bool = false,
            stopInProgress: Bool = false,
            backgroundCompactionSettling: Bool = false,
            hasWaitingPrompt: Bool,
            hasPendingAskUser: Bool,
            hasPendingUserInputRequest: Bool,
            hasPendingApproval: Bool,
            hasPendingPermissionsRequest: Bool,
            hasPendingMCPElicitationRequest: Bool,
            hasPendingApplyEditsReview: Bool,
            hasPendingWorktreeMergeReview: Bool
        ) {
            self.hasLoadedPersistedState = hasLoadedPersistedState
            self.restorationReadiness = restorationReadiness
            self.bindingTransitionInProgress = bindingTransitionInProgress
            self.isClosing = isClosing
            self.endpointMatchesGrant = endpointMatchesGrant
            self.runStateIsActive = runStateIsActive
            self.terminalCommitInProgress = terminalCommitInProgress
            self.mcpFollowUpRunPending = mcpFollowUpRunPending
            self.isComposerSubmissionInFlight = isComposerSubmissionInFlight
            self.isPreparingInitialWorktree = isPreparingInitialWorktree
            self.isChangingExecutionLocation = isChangingExecutionLocation
            self.pendingInstructionCount = pendingInstructionCount
            self.pendingACPSteeringCount = pendingACPSteeringCount
            self.pendingClaudeSteeringCount = pendingClaudeSteeringCount
            self.pendingOversightAutoWake = pendingOversightAutoWake
            self.pendingSelfCompact = pendingSelfCompact
            self.selfCompactBlocksManagedStop = selfCompactBlocksManagedStop
            self.stopInProgress = stopInProgress
            self.backgroundCompactionSettling = backgroundCompactionSettling
            self.hasWaitingPrompt = hasWaitingPrompt
            self.hasPendingAskUser = hasPendingAskUser
            self.hasPendingUserInputRequest = hasPendingUserInputRequest
            self.hasPendingApproval = hasPendingApproval
            self.hasPendingPermissionsRequest = hasPendingPermissionsRequest
            self.hasPendingMCPElicitationRequest = hasPendingMCPElicitationRequest
            self.hasPendingApplyEditsReview = hasPendingApplyEditsReview
            self.hasPendingWorktreeMergeReview = hasPendingWorktreeMergeReview
        }

        /// A fully idle, hydrated, exactly-bound target.
        ///
        /// Only used to build test cases and as documentation of the ready shape; production always
        /// assembles from live state.
        static let ready = Snapshot(
            hasLoadedPersistedState: true,
            restorationReadiness: .authoritative(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(tabID: UUID(), sessionID: UUID()),
                    bindingTransitionGeneration: 0
                ),
                .persistedPayloadApplied
            ),
            bindingTransitionInProgress: false,
            isClosing: false,
            endpointMatchesGrant: true,
            runStateIsActive: false,
            terminalCommitInProgress: false,
            mcpFollowUpRunPending: false,
            isComposerSubmissionInFlight: false,
            isPreparingInitialWorktree: false,
            isChangingExecutionLocation: false,
            pendingInstructionCount: 0,
            pendingACPSteeringCount: 0,
            pendingClaudeSteeringCount: 0,
            pendingOversightAutoWake: false,
            hasWaitingPrompt: false,
            hasPendingAskUser: false,
            hasPendingUserInputRequest: false,
            hasPendingApproval: false,
            hasPendingPermissionsRequest: false,
            hasPendingMCPElicitationRequest: false,
            hasPendingApplyEditsReview: false,
            hasPendingWorktreeMergeReview: false
        )
    }

    /// Why a send was refused. These are wire-stable: the observer's prompt guidance names them.
    enum BlockReason: String, CaseIterable, Equatable {
        /// The exact endpoint incarnation is gone or no longer matches the grant.
        case endpointInvalidated = "endpoint_invalidated"
        /// Retryable: the target has not finished hydrating or is rebinding.
        case targetLoading = "target_loading"
        /// Loading completed without a usable payload. Polling cannot make this binding writable.
        case targetRestoreUnavailable = "target_restore_unavailable"
        /// Creation needs its owner to finish configuration and confirm the matching payload save.
        case targetCreationIncomplete = "target_creation_incomplete"
        /// The target is running, waiting, has a pending interaction, or has queued work.
        case targetNotIdle = "target_not_idle"

        var message: String {
            switch self {
            case .endpointInvalidated:
                "The overseen session is no longer available at the exact endpoint this link was granted for."
            case .targetLoading:
                "The overseen session is still loading. Poll it and try again."
            case .targetRestoreUnavailable:
                "This session could not be restored. Retry loading it or create a new session; its saved data has not been replaced."
            case .targetCreationIncomplete:
                "This session is still being created or has not been saved. Open it in the app to finish creation before sending a turn."
            case .targetNotIdle:
                "The overseen session is not ready to accept a message. Wait for it with "
                    + "until: \"sendable\" and send when a snapshot reports idle_for_send: true; "
                    + "until: \"idle\" is satisfied by targets this call still refuses."
            }
        }
    }

    enum Decision: Equatable {
        case ready
        case blocked(BlockReason)

        var isReady: Bool {
            self == .ready
        }

        var blockReason: BlockReason? {
            guard case let .blocked(reason) = self else { return nil }
            return reason
        }
    }

    /// Evaluates the full matrix in fixed precedence order.
    ///
    /// Order matters for the caller's next action, not just for the message: an invalidated endpoint
    /// is permanent for this grant and must never be reported as the retryable "still loading" or
    /// "busy" case that a caller would poll on.
    static func evaluate(snapshot: Snapshot) -> Decision {
        if !snapshot.endpointMatchesGrant || snapshot.isClosing {
            return .blocked(.endpointInvalidated)
        }
        if snapshot.bindingTransitionInProgress {
            return .blocked(.targetLoading)
        }
        if let reason = restorationBlockReason(snapshot.restorationReadiness) {
            return .blocked(reason)
        }
        if !snapshot.hasLoadedPersistedState {
            return .blocked(.targetLoading)
        }
        if isTargetBusy(snapshot) {
            return .blocked(.targetNotIdle)
        }
        return .ready
    }

    /// Ordinary callers cannot borrow the creation owner's permission to configure or save.
    static func restorationBlockReason(_ readiness: AgentSessionRestorationReadiness) -> BlockReason? {
        switch readiness {
        case .authoritative: nil
        case .unbound, .pending: .targetLoading
        case .creating: .targetCreationIncomplete
        case .terminal: .targetRestoreUnavailable
        }
    }

    static func failure(snapshot: Snapshot) -> AgentSessionLinkSendFailure? {
        switch evaluate(snapshot: snapshot) {
        case let .blocked(reason): AgentSessionLinkSendFailure(reason)
        case .ready: nil
        }
    }

    /// Every non-lifecycle blocker. Completed, cancelled, and failed prior runs are *not* blockers:
    /// a terminal run in a still-live session is idle and remains sendable.
    private static func isTargetBusy(_ snapshot: Snapshot) -> Bool {
        snapshot.runStateIsActive
            || snapshot.terminalCommitInProgress
            || snapshot.mcpFollowUpRunPending
            || snapshot.isComposerSubmissionInFlight
            || snapshot.isPreparingInitialWorktree
            || snapshot.isChangingExecutionLocation
            || snapshot.pendingInstructionCount > 0
            || snapshot.pendingACPSteeringCount > 0
            || snapshot.pendingClaudeSteeringCount > 0
            || snapshot.pendingOversightAutoWake
            || snapshot.pendingSelfCompact
            || snapshot.stopInProgress
            || snapshot.backgroundCompactionSettling
            || snapshot.hasWaitingPrompt
            || snapshot.hasPendingAskUser
            || snapshot.hasPendingUserInputRequest
            || snapshot.hasPendingApproval
            || snapshot.hasPendingPermissionsRequest
            || snapshot.hasPendingMCPElicitationRequest
            || snapshot.hasPendingApplyEditsReview
            || snapshot.hasPendingWorktreeMergeReview
    }
}
