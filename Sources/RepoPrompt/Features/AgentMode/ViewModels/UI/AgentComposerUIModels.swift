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
    let expectedSourceAgentSessionID: UUID?
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
