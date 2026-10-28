import OSLog

/// Low-volume, always-on route-refusal diagnostics, called by the auto-wake evaluator.
/// Accepts only a closed gate predicate and the existing attempt phase, never identifiers or content.
enum AgentSessionLinkAutoWakeDiagnostics {
    enum GatePredicate: String {
        case hasLoadedPersistedState, bindingTransitionInProgress, terminalCommitInProgress
        case mcpFollowUpRunPending, selfCompactBlocksNotificationWake, isComposerSubmissionInFlight
        case isPreparingInitialWorktree, isChangingExecutionLocation, pendingInstructions
        case pendingACPSteeringInstructions, pendingClaudeSteeringInstructions, isSettlingACPBackgroundCompaction
        case pendingAskUser, pendingUserInputRequest, pendingApproval, pendingPermissionsRequest
        case pendingMCPElicitationRequest, pendingApplyEditsReview, pendingWorktreeMergeReview
        case runStateIsActive, waitingForUserWithoutContinuation
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "AutoWake")

    static func routeRefused(predicate: GatePredicate, phase: AgentSessionLinkAutoWakeAttempt.Phase) {
        logger.notice("route_refused predicate=\(predicate.rawValue, privacy: .public) phase=\(String(describing: phase), privacy: .public)")
    }
}
