import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

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

    /// The visible card, when it is a question. Only questions take focus: an approval's action
    /// is bound to Return, so focusing it could approve by accident.
    var pendingQuestionFocusKey: String? {
        pendingInteractionFocusKeys.first.flatMap { Self.isQuestionFocusKey($0) ? $0 : nil }
    }

    static func isQuestionFocusKey(_ key: String) -> Bool {
        key.hasPrefix("input:") || key.hasPrefix("askUser:")
    }

    /// Every pending question or approval, most urgent first, following the card order in
    /// `messageRowsContent`. A merge conflict is excluded: it can stay open for a long time, and
    /// the composer is how the user asks the agent to help resolve it.
    var pendingInteractionFocusKeys: [String] {
        [
            pendingCodexHookReview.map { "hook:\($0.id)" },
            pendingApplyEditsReview.map { "applyEdits:\($0.id)" },
            pendingWorktreeMergeReview.map { "merge:\($0.id)" },
            pendingApproval.map { "approval:\($0.id)" },
            pendingPermissionsRequest.map { "permissions:\($0.id)" },
            pendingMCPElicitationRequest.map { "elicitation:\($0.id)" },
            // Legacy MCP tool approvals are approvals shown as question cards.
            pendingUserInputRequest.map { request in
                request.questions.contains(where: \.isLegacyMCPToolApproval) ? "approvalInput:\(request.id)" : "input:\(request.id)"
            },
            pendingAskUser.map { "askUser:\($0.id)" }
        ].compactMap(\.self)
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

/// What should happen to focus when a session's pending questions and approvals change.
enum AgentPendingInteractionFocusHandoff: Equatable {
    case none
    case returnToComposer
    case focusNextCard

    /// Focus moves on when the visible card was answered, or when an approval replaced a question
    /// that may have held focus. Focus goes to the next card only if it is a question, so that
    /// Return can never reach an approval because focus was abandoned.
    static func evaluate(previousKeys: [String], keys: [String]) -> Self {
        typealias Snapshot = AgentRunInteractionUISnapshot
        guard let previousTop = previousKeys.first, keys.first != previousTop,
              !keys.contains(previousTop) || Snapshot.isQuestionFocusKey(previousTop) else { return .none }
        if let top = keys.first, Snapshot.isQuestionFocusKey(top) { return .focusNextCard }
        return .returnToComposer
    }
}

@MainActor
final class AgentRunInteractionUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var snapshot: AgentRunInteractionUISnapshot = .empty

    /// One-shot request for a tab's pending question to take focus. A card that merely appears
    /// does not take focus, so it cannot interrupt typing.
    struct PendingCardFocusRequest: Equatable {
        let id = UUID()
        let tabID: UUID
        /// Rechecked at delivery, because the user may have moved on since the request.
        let mayDeliver: @MainActor () -> Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var pendingCardFocusRequest: PendingCardFocusRequest?
    /// Changes when a request is issued or withdrawn, which fences any delivery in flight.
    private(set) var pendingCardFocusGeneration = 0

    func requestPendingCardFocus(tabID: UUID, mayDeliver: @escaping @MainActor () -> Bool = { true }) {
        pendingCardFocusGeneration += 1
        pendingCardFocusRequest = .init(tabID: tabID, mayDeliver: mayDeliver)
    }

    func clearPendingCardFocus() {
        pendingCardFocusGeneration += 1
        if pendingCardFocusRequest != nil { pendingCardFocusRequest = nil }
    }

    /// Returns a request targeting `tabID` once, so only one card takes focus.
    func takePendingCardFocus(tabID: UUID?) -> PendingCardFocusRequest? {
        guard let tabID, let request = pendingCardFocusRequest, request.tabID == tabID else { return nil }
        pendingCardFocusRequest = nil
        return request
    }

    func update(_ snapshot: AgentRunInteractionUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                perfRecorder.recordStoreUpdate("runInteraction", published: false)
            #endif
            return
        }
        #if DEBUG
            perfRecorder.recordStoreUpdate(
                "runInteraction",
                published: true,
                details: [
                    "tabID": perfRecorder.shortID(snapshot.currentTabID),
                    "runState": String(describing: snapshot.runState),
                    "hasPendingAskUser": String(snapshot.pendingAskUser != nil),
                    "askUserTimeoutStartedAt": snapshot.pendingAskUser?.timeoutStartedAt?.description ?? "nil",
                    "hasPendingInput": String(snapshot.pendingUserInputRequest != nil),
                    "hasPendingApproval": String(snapshot.pendingApproval != nil),
                    "hasPendingCodexHookReview": String(snapshot.pendingCodexHookReview != nil),
                    "codexHookReviewPhase": snapshot.pendingCodexHookReview?.phase.rawValue ?? "nil",
                    "codexHookReviewID": perfRecorder.shortID(snapshot.pendingCodexHookReview?.id),
                    "hasPendingPermissions": String(snapshot.pendingPermissionsRequest != nil),
                    "hasPendingMCPElicitation": String(snapshot.pendingMCPElicitationRequest != nil),
                    "hasApplyReview": String(snapshot.pendingApplyEditsReview != nil),
                    "hasWorktreeMergeReview": String(snapshot.pendingWorktreeMergeReview != nil),
                    "hasWorktreeMergeConflict": String(snapshot.activeWorktreeMergeConflict != nil),
                    "activeRunID": perfRecorder.shortID(snapshot.activeRunID)
                ]
            )
        #endif
        self.snapshot = snapshot
    }
}
