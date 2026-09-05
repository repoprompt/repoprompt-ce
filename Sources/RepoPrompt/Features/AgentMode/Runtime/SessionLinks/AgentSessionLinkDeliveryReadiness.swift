import Foundation

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
        /// The target is running, waiting, has a pending interaction, or has queued work.
        case targetNotIdle = "target_not_idle"

        var message: String {
            switch self {
            case .endpointInvalidated:
                "The overseen session is no longer available at the exact endpoint this link was granted for."
            case .targetLoading:
                "The overseen session is still loading. Poll it and try again."
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
        if !snapshot.hasLoadedPersistedState || snapshot.bindingTransitionInProgress {
            return .blocked(.targetLoading)
        }
        if isTargetBusy(snapshot) {
            return .blocked(.targetNotIdle)
        }
        return .ready
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
