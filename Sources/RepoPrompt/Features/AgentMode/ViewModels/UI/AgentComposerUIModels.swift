import Foundation

struct AgentDraftRestorationProps: Equatable {
    let id: UUID
    let tabID: UUID
    let text: String
    let message: String
    let strategy: AgentModeRunService.DraftRestorationStrategy

    init(_ event: AgentModeViewModel.DraftRestorationEvent) {
        id = event.id
        tabID = event.tabID
        text = event.text
        message = event.message
        strategy = event.strategy
    }
}

struct AgentStagedSlashCommandProps: Equatable {
    enum Kind: Equatable {
        case codexGoal
    }

    enum GoalAction: String, Equatable {
        case setObjective
        case show
        case pause
        case resume
        case clear
    }

    let kind: Kind
    let displayText: String
    let action: GoalAction
    let selectedWorkflowName: String?
    let appliesSelectedWorkflowContext: Bool
}

struct AgentRunCancelTarget: Equatable {
    let tabID: UUID
    let expectedRunID: UUID?
    let expectedActiveAgentSessionID: UUID?
    let expectedRunAttemptID: UUID?
    let expectedPendingUserInputRequestID: CodexAppServerRequestID?
}

struct AgentComposerSubmitTarget: Equatable {
    enum Route: String, Equatable {
        case existingAgentSession
        case createAgentSessionFromSourceTab
    }

    let tabID: UUID
    let route: Route
    let expectedSourceTabSessionIdentity: ObjectIdentifier
    let expectedSourceAgentSessionID: UUID?
    let expectedPersistentBindingIdentity: AgentPersistentSessionBindingIdentity?
    let expectedBindingTransitionGeneration: UInt64
    // Exact freshness guards for unlinked first-send targets. For an existing
    // persistent session, these remain render-time diagnostics while live routing
    // selects the current run and attempt at send time.
    let expectedRunState: AgentSessionRunState
    let expectedRunID: UUID?
    let expectedRunAttemptID: UUID?
    /// One-shot render identity claimed before submission performs any async work.
    let expectedSubmissionToken: UUID
    let expectedInitialStartLocation: AgentModeViewModel.InitialStartLocation?
}

struct AgentComposerSubmitAttempt: Equatable {
    let id: UUID
    let target: AgentComposerSubmitTarget
    let inputRevision: UInt64
    let noticeRevision: UInt64
    let rawDraftSnapshot: String

    var sourceTabID: UUID {
        target.tabID
    }

    var sourceTabSessionIdentity: ObjectIdentifier {
        target.expectedSourceTabSessionIdentity
    }

    var capturedSubmissionToken: UUID {
        target.expectedSubmissionToken
    }
}

struct AgentComposerSubmissionLatch {
    struct CompletionEffects: Equatable {
        let matchedAttempt: Bool
        let shouldClearInput: Bool
        let blockedMessage: String?

        static let stale = CompletionEffects(
            matchedAttempt: false,
            shouldClearInput: false,
            blockedMessage: nil
        )
    }

    private(set) var activeAttemptsByTabID: [UUID: AgentComposerSubmitAttempt] = [:]
    private(set) var inputRevision: UInt64 = 0
    private(set) var noticeRevision: UInt64 = 0

    func isLatched(for tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return activeAttemptsByTabID[tabID] != nil
    }

    func activeAttemptID(for tabID: UUID?) -> UUID? {
        guard let tabID else { return nil }
        return activeAttemptsByTabID[tabID]?.id
    }

    mutating func advanceInputRevision() {
        inputRevision &+= 1
    }

    mutating func advanceNoticeRevision() {
        noticeRevision &+= 1
    }

    mutating func begin(
        target: AgentComposerSubmitTarget,
        rawDraftSnapshot: String,
        attemptID: UUID = UUID()
    ) -> AgentComposerSubmitAttempt? {
        guard activeAttemptsByTabID[target.tabID] == nil else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: attemptID,
            target: target,
            inputRevision: inputRevision,
            noticeRevision: noticeRevision,
            rawDraftSnapshot: rawDraftSnapshot
        )
        activeAttemptsByTabID[target.tabID] = attempt
        return attempt
    }

    @discardableResult
    mutating func cancel(_ attempt: AgentComposerSubmitAttempt) -> Bool {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else { return false }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)
        return true
    }

    mutating func complete(
        _ attempt: AgentComposerSubmitAttempt,
        result: AgentModeViewModel.UserTurnSubmissionResult,
        currentTabID: UUID?,
        currentRawDraft: String
    ) -> CompletionEffects {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else {
            return .stale
        }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)

        let inputStillMatches = currentTabID == attempt.sourceTabID
            && inputRevision == attempt.inputRevision
            && currentRawDraft == attempt.rawDraftSnapshot
        switch result {
        case .submitted:
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: inputStillMatches,
                blockedMessage: nil
            )
        case let .blocked(message):
            let mayPublishNotice = inputStillMatches && noticeRevision == attempt.noticeRevision
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: false,
                blockedMessage: mayPublishNotice ? message : nil
            )
        }
    }
}

struct AgentComposerProps: Equatable {
    let currentTabID: UUID?
    let submitTarget: AgentComposerSubmitTarget?
    let attachments: AgentAttachmentStripSnapshot
    let runState: AgentSessionRunState
    let cancelTarget: AgentRunCancelTarget?
    let isAgentBusy: Bool
    let isWaitingForInstruction: Bool
    let canUseLinkedAgentSession: Bool
    let isCurrentTabMCPControlled: Bool
    let areModelControlsDisabled: Bool
    let providerControls: AgentProviderControlsBinding?
    let isCodexRunActive: Bool
    let hasAvailableAgentProviders: Bool
    let canSendWithCurrentProvider: Bool
    let unavailableSelectedAgentMessage: String?
    let selectedAgent: AgentProviderKind
    let selectedModelRaw: String
    let selectedModelDisplayName: String
    let selectedReasoningEffortRaw: String?
    let selectedReasoningEffortDisplayName: String
    let availableAgents: [AgentProviderKind]
    let isProviderPickerLockedForCurrentTab: Bool
    let lockedAgentSelectionMessage: String?
    let autoEditEnabled: Bool
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let draftRestorationEvent: AgentDraftRestorationProps?
    let fileTagLookupContextIdentity: AgentWorkspaceLookupContextIdentity

    static let empty = AgentComposerProps(
        currentTabID: nil,
        submitTarget: nil,
        attachments: AgentAttachmentStripSnapshot(
            imageAttachments: [],
            taggedFileAttachments: []
        ),
        runState: .idle,
        cancelTarget: nil,
        isAgentBusy: false,
        isWaitingForInstruction: false,
        canUseLinkedAgentSession: false,
        isCurrentTabMCPControlled: false,
        areModelControlsDisabled: false,
        providerControls: nil,
        isCodexRunActive: false,
        hasAvailableAgentProviders: false,
        canSendWithCurrentProvider: false,
        unavailableSelectedAgentMessage: nil,
        selectedAgent: .claudeCode,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedModelDisplayName: AgentModel.defaultModel.displayName,
        selectedReasoningEffortRaw: nil,
        selectedReasoningEffortDisplayName: "",
        availableAgents: [],
        isProviderPickerLockedForCurrentTab: false,
        lockedAgentSelectionMessage: nil,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        stagedSlashCommand: nil,
        draftRestorationEvent: nil,
        fileTagLookupContextIdentity: AgentWorkspaceLookupContextSource(
            activeAgentSessionID: nil,
            worktreeBindings: []
        ).identity
    )
}
