import Foundation
import RepoPromptSettingsCore

struct AgentComposerDraftRestorationOperation: Equatable {
    struct Fragment: Equatable {
        let sequence: UInt64
        let text: String
    }

    let rejectedDraftText: String
    let draftTextBeforeRestoration: String
    let composedDraftText: String
    let fragments: [Fragment]
}

struct AgentComposerDraftSnapshot {
    let text: String
    let restorationSequence: UInt64
}

/// The producer retains only fragments not yet acknowledged by this tab's composer.
/// A stored snapshot carries the highest sequence already included in its text.
struct AgentComposerDraftRestorationLedger {
    struct TabState {
        var nextSequence: UInt64 = 0
        var acknowledgedSequence: UInt64 = 0
        var storedDraftSequence: UInt64 = 0
        var pendingFragments: [AgentComposerDraftRestorationOperation.Fragment] = []
    }

    private(set) var tabs: [UUID: TabState] = [:]

    mutating func append(tabID: UUID, text: String) -> [AgentComposerDraftRestorationOperation.Fragment] {
        var state = tabs[tabID] ?? TabState()
        state.nextSequence += 1
        state.pendingFragments.append(.init(sequence: state.nextSequence, text: text))
        state.storedDraftSequence = state.nextSequence
        tabs[tabID] = state
        return state.pendingFragments
    }

    mutating func acknowledge(tabID: UUID, through sequence: UInt64) {
        guard var state = tabs[tabID] else { return }
        state.acknowledgedSequence = max(state.acknowledgedSequence, min(sequence, state.nextSequence))
        state.pendingFragments.removeAll { $0.sequence <= state.acknowledgedSequence }
        tabs[tabID] = state
    }

    mutating func markStoredDraft(tabID: UUID, through sequence: UInt64) {
        guard var state = tabs[tabID] else { return }
        state.storedDraftSequence = min(sequence, state.nextSequence)
        tabs[tabID] = state
    }

    mutating func remove(tabID: UUID) {
        tabs.removeValue(forKey: tabID)
    }

    mutating func removeAll() {
        tabs.removeAll()
    }
}

enum AgentComposerDraftRestorationReducer {
    static func compose(restoredText: String, above existingText: String) -> String {
        let restoredIsEmpty = restoredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !restoredIsEmpty else { return existingText }
        let existingIsEmpty = existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !existingIsEmpty else { return restoredText }
        return restoredText + "\n" + existingText
    }

    static func apply(
        _ operation: AgentComposerDraftRestorationOperation,
        to currentLocalText: String,
        acknowledgedSequence: UInt64
    ) -> String {
        let missingFragments = operation.fragments.filter { $0.sequence > acknowledgedSequence }
        guard !missingFragments.isEmpty else { return currentLocalText }
        if currentLocalText == operation.composedDraftText
            || currentLocalText == operation.draftTextBeforeRestoration
        {
            return operation.composedDraftText
        }
        return missingFragments.reduce(currentLocalText) { text, fragment in
            compose(restoredText: fragment.text, above: text)
        }
    }
}

struct AgentDraftRestorationProps: Equatable {
    let id: UUID
    let tabID: UUID
    let text: String
    let message: String
    let strategy: AgentModeRunService.DraftRestorationStrategy
    let operation: AgentComposerDraftRestorationOperation?

    init(_ event: AgentModeViewModel.DraftRestorationEvent) {
        id = event.id
        tabID = event.tabID
        text = event.text
        message = event.message
        strategy = event.strategy
        operation = event.operation
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

struct AgentComposerModelParameterControlProps: Equatable, Identifiable {
    let providerID: ACPProviderID
    let kind: ACPModelParameterKind
    let baseModelRaw: String
    let configID: String
    let displayName: String
    let selectedValueRaw: String
    var savedValueRaw: String?
    let selectedDisplayName: String
    let choices: [ACPModelParameterChoice]
    /// OpenCode only: the demand-scoped discovery key this control's metadata came from. The
    /// setter rejects a click whose key is missing or no longer matches the current target, so a
    /// stale menu can never retarget a selection to a different workspace/model. Cursor leaves
    /// this nil (its catalogue is static and needs no demand-scoped authority).
    let openCodeDiscoveryKey: OpenCodeACPModelParameterKey?

    var id: String {
        "\(kind.rawValue):\(configID)"
    }

    var accessibilityLabel: String {
        displayName
    }

    var isSavedValueUnavailable: Bool {
        (providerID == .openCode || providerID == .cursor) && !choices.contains { $0.rawValue == selectedValueRaw }
    }

    var tooltip: String {
        isSavedValueUnavailable
            ? "Saved \(displayName) value ‘\(selectedValueRaw)’ is not currently advertised. Choose a supported value before running."
            : displayName
    }

    var accessibilityValue: String {
        isSavedValueUnavailable ? "\(selectedDisplayName), unavailable" : selectedDisplayName
    }
}

struct AgentComputerUseComposerProps: Equatable {
    let isVisible: Bool
    let isOn: Bool
    let isBusy: Bool
    static let hidden = Self(isVisible: false, isOn: false, isBusy: false)
}

struct AgentComposerProps: Equatable {
    var computerUse: AgentComputerUseComposerProps = .hidden
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
    let isRoutingFreshTask: Bool
    let isGlobalModelRouterControllingFreshTask: Bool
    let unavailableSelectedAgentMessage: String?
    let selectedAgent: AgentProviderKind
    var selectedModelRaw: String
    var selectedModelDisplayName: String
    var selectedReasoningEffortRaw: String?
    var selectedReasoningEffortDisplayName: String
    var acpModelParameterControls: [AgentComposerModelParameterControlProps]
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
        isRoutingFreshTask: false,
        isGlobalModelRouterControllingFreshTask: false,
        unavailableSelectedAgentMessage: nil,
        selectedAgent: .claudeCode,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedModelDisplayName: AgentModel.defaultModel.displayName,
        selectedReasoningEffortRaw: nil,
        selectedReasoningEffortDisplayName: "",
        acpModelParameterControls: [],
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
