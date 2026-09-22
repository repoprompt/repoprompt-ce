import Foundation

struct AgentRunInteractionUISnapshot: Equatable {
    var currentTabID: UUID?
    var runState: AgentSessionRunState
    var runningStatusText: String?
    var activeAgentRunStartedAt: Date?
    var waitingPrompt: String?
    var pendingAskUser: AgentAskUserPendingState?
    var pendingUserInputRequest: AgentRequestUserInputRequest?
    var pendingApproval: AgentApprovalRequest?
    var pendingCodexHookReview: AgentCodexHookReviewRequest? = .none
    var pendingPermissionsRequest: AgentPermissionsRequest?
    var pendingMCPElicitationRequest: AgentMCPElicitationRequest?
    var pendingApplyEditsReview: PendingApplyEditsReview?
    var pendingWorktreeMergeReview: PendingWorktreeMergeReview?
    /// Active worktree merge operation in `.conflicted` or `.awaitingCommit`
    /// state for the current tab, surfaced as a persistent blocker so the
    /// merge conflict card can be shown when no higher-priority blocker is
    /// active. `nil` when no such operation exists for the current tab.
    var activeWorktreeMergeConflict: AgentSessionWorktreeMergeOperation?
    var activeRunID: UUID?
    var activeAgentSessionID: UUID?
    var activeRunAttemptID: UUID?
    var latestUserSequenceIndex: Int?
    var canForkCurrentSession: Bool
    var selectedAgent: AgentProviderKind
    var selectedModelRaw: String
    var selectedReasoningEffortRaw: String?

    var isAgentBusy: Bool {
        runState == .running
    }

    var isWaitingForInstruction: Bool {
        runState == .waitingForUser
    }

    var pendingUserInputCancelTarget: AgentRunCancelTarget? {
        guard let currentTabID,
              let activeRunID,
              let pendingUserInputRequest
        else { return nil }
        return AgentRunCancelTarget(
            tabID: currentTabID,
            expectedRunID: activeRunID,
            expectedActiveAgentSessionID: activeAgentSessionID,
            expectedRunAttemptID: activeRunAttemptID,
            expectedPendingUserInputRequestID: pendingUserInputRequest.requestID
        )
    }

    static let empty = AgentRunInteractionUISnapshot(
        currentTabID: nil,
        runState: .idle,
        runningStatusText: nil,
        activeAgentRunStartedAt: nil,
        waitingPrompt: nil,
        pendingAskUser: nil,
        pendingUserInputRequest: nil,
        pendingApproval: nil,
        pendingCodexHookReview: nil,
        pendingPermissionsRequest: nil,
        pendingMCPElicitationRequest: nil,
        pendingApplyEditsReview: nil,
        pendingWorktreeMergeReview: nil,
        activeWorktreeMergeConflict: nil,
        activeRunID: nil,
        activeAgentSessionID: nil,
        activeRunAttemptID: nil,
        latestUserSequenceIndex: nil,
        canForkCurrentSession: false,
        selectedAgent: .codexExec,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedReasoningEffortRaw: nil
    )
}

@MainActor
final class AgentRunInteractionUIStore: ObservableObject {
    @Published private(set) var snapshot: AgentRunInteractionUISnapshot = .empty

    func update(_ snapshot: AgentRunInteractionUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("runInteraction", published: false)
            #endif
            return
        }
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "runInteraction",
                published: true,
                details: [
                    "tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID),
                    "runState": String(describing: snapshot.runState),
                    "hasPendingAskUser": String(snapshot.pendingAskUser != nil),
                    "askUserTimeoutStartedAt": snapshot.pendingAskUser?.timeoutStartedAt?.description ?? "nil",
                    "hasPendingInput": String(snapshot.pendingUserInputRequest != nil),
                    "hasPendingApproval": String(snapshot.pendingApproval != nil),
                    "hasPendingCodexHookReview": String(snapshot.pendingCodexHookReview != nil),
                    "codexHookReviewPhase": snapshot.pendingCodexHookReview?.phase.rawValue ?? "nil",
                    "codexHookReviewID": AgentModePerfDiagnostics.shortID(snapshot.pendingCodexHookReview?.id),
                    "hasPendingPermissions": String(snapshot.pendingPermissionsRequest != nil),
                    "hasPendingMCPElicitation": String(snapshot.pendingMCPElicitationRequest != nil),
                    "hasApplyReview": String(snapshot.pendingApplyEditsReview != nil),
                    "hasWorktreeMergeReview": String(snapshot.pendingWorktreeMergeReview != nil),
                    "hasWorktreeMergeConflict": String(snapshot.activeWorktreeMergeConflict != nil),
                    "activeRunID": AgentModePerfDiagnostics.shortID(snapshot.activeRunID)
                ]
            )
        #endif
        self.snapshot = snapshot
    }
}
