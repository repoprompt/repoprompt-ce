import Foundation

struct AgentPersistentSessionBindingIdentity: Equatable, Hashable {
    let tabID: UUID
    let sessionID: UUID
    let generation: UUID

    init(tabID: UUID, sessionID: UUID, generation: UUID = UUID()) {
        self.tabID = tabID
        self.sessionID = sessionID
        self.generation = generation
    }
}

enum AgentSidebarThreadKey: Hashable, Equatable {
    case session(UUID)
    case tab(UUID)

    static func key(sessionID: UUID?, tabID: UUID) -> AgentSidebarThreadKey {
        if let sessionID {
            return .session(sessionID)
        }
        return .tab(tabID)
    }
}

@MainActor
protocol AgentModeRunInteractionStateObserving: AnyObject {
    func agentModeViewModel(
        _ viewModel: AgentModeViewModel,
        didChangeRunInteractionStateFor session: AgentModeViewModel.TabSession,
        reason: AgentModeViewModel.RunInteractionStateChangeReason
    )
}

extension AgentModeViewModel {
    enum UserTurnSubmissionResult: Equatable {
        case submitted
        case blocked(message: String)
    }

    struct AgentComposerSubmitClaim {
        let attempt: AgentComposerSubmitAttempt
        let sourceSession: TabSession
        let draftMutationGeneration: UInt64
    }

    enum AgentComposerSubmitClaimRejection: Equatable {
        case missingSession
        case sourceSessionIdentityMismatch
        case activeAttemptExists(activeAttemptID: UUID)
        case targetRejected(reason: String)
        case initialWorktreePreparationInProgress
        case executionLocationChangeInProgress

        var diagnosticReason: String {
            switch self {
            case .missingSession:
                "missing_session"
            case .sourceSessionIdentityMismatch:
                "source_session_identity_mismatch"
            case .activeAttemptExists:
                "existing_claim"
            case let .targetRejected(reason):
                reason
            case .initialWorktreePreparationInProgress:
                "initial_worktree_preparation_in_progress"
            case .executionLocationChangeInProgress:
                "execution_location_change_in_progress"
            }
        }
    }

    enum AgentComposerSubmitClaimResult {
        case claimed(AgentComposerSubmitClaim)
        case rejected(AgentComposerSubmitClaimRejection)
    }

    enum RunInteractionStateChangeReason: String, Equatable {
        case userInputResponseSubmitted
        case pendingQuestionCancelled
        case pendingApprovalCancelled
        case approvalResponseSubmitted
        case permissionsResponseSubmitted
        case mcpElicitationResponseSubmitted
    }

    enum AgentInteractionTransport: Equatable {
        case ui
        case mcp(sessionID: UUID, originatingConnectionID: UUID?)
    }

    enum UIRefreshScope: String, Equatable, Hashable {
        case full
        case transcriptRuntime
        case runtimeMetrics
    }

    struct AssistantPresentationRequest: Equatable {
        let tabID: UUID
        let sessionIdentity: ObjectIdentifier
        let persistentBinding: AgentPersistentSessionBindingIdentity?
        let bindingTransitionGeneration: UInt64
        let sourceItemsRevision: Int
        let flushGeneration: UInt64
    }

    struct PersistentBindingTransitionToken: Equatable {
        let tabID: UUID
        let sessionIdentity: ObjectIdentifier
        let binding: AgentPersistentSessionBindingIdentity?
        let transitionGeneration: UInt64
        let sourceItemsRevision: Int
    }

    struct PersistedHydrationCommitToken: Equatable {
        let transition: PersistentBindingTransitionToken
        let requestedSessionID: UUID
    }

    struct SessionSaveCommitToken: Equatable {
        let tabID: UUID
        let sessionIdentity: ObjectIdentifier
        let workspaceID: UUID
        let binding: AgentPersistentSessionBindingIdentity
        let bindingTransitionGeneration: UInt64
        let sourceItemsRevision: Int
        let persistenceMutationGeneration: UInt64
        let saveRequestGeneration: UInt64
    }

    enum PersistentBindingResolution: Equatable {
        case unique(tabID: UUID)
        case notFound
        case ambiguous(tabIDs: [UUID])
    }

    enum PersistentBindingMutationError: Error, Equatable {
        case staleTransition
        case blockedByOwnership
        case ambiguous
        case tabNotFound
    }

    /// Reason tag emitted by sidebar forced-refresh call sites. Used purely for
    /// diagnostics and fingerprint-skipped events; does not gate publication.
    enum SidebarRefreshReason: String, Equatable, Hashable {
        case sessionList
        case sessionIndex
        case sortDates
        case runState
        case mcpControl
        case sessionName
        case parentRepair
        case metadataUpdated
        case search
        case visibleCount
        case explicit
    }

    /// Signature of a compose tab's sidebar-rendered metadata. Captured separately
    /// from live `TabSession` state because sidebar rows resolve titles, pinned
    /// grouping, explicit session IDs, workspace order, and fallback activity dates
    /// from `ComposeTabState` values passed by the sidebar view.
    struct AgentSessionSidebarTabMetadataSignature: Equatable {
        let tabID: UUID
        let order: Int
        let normalizedName: String
        let activeAgentSessionID: UUID?
        let isPinned: Bool
        let lastModified: Date
    }

    /// Signature of a single `TabSession`'s sidebar-relevant state. Captured into a
    /// value type so fingerprint comparison is cheap and does not depend on the
    /// class identity of the live `TabSession` reference.
    struct AgentSessionSidebarTabSignature: Equatable {
        let tabID: UUID
        let activeAgentSessionID: UUID?
        let parentSessionID: UUID?
        let hasLoadedPersistedState: Bool
        let itemsIsEmpty: Bool
        let runState: AgentSessionRunState
        let lastActivityAt: Date
        let lastUserMessageAt: Date?
    }

    /// Fingerprint of every VM-level input that affects the rendered session sidebar.
    /// `syncSidebarUIState(refresh:reason:)` gates forced revisions on changes to
    /// this fingerprint, ensuring duplicate refresh requests during steady provider
    /// output do not bump `AgentSessionSidebarUIStore.revision`.
    struct AgentSessionSidebarContentFingerprint: Equatable {
        let currentTabID: UUID?
        let sessionListCacheReady: Bool
        let tabsWithActiveAgentRun: Set<UUID>
        let mcpControlledTabIDs: Set<UUID>
        let tabMetadataSignatures: [AgentSessionSidebarTabMetadataSignature]
        let sessionSignatures: [AgentSessionSidebarTabSignature]
        let sessionIndex: [UUID: AgentSessionIndexEntry]
        let sessionListSortDates: [UUID: Date]
        let sidebarRestoreFrozenOrderByTabID: [UUID: Int]
    }

    struct ActiveUIInvalidation: OptionSet {
        let rawValue: Int

        static let composer = ActiveUIInvalidation(rawValue: 1 << 0)
        static let statusPills = ActiveUIInvalidation(rawValue: 1 << 1)
        static let runtimeMetrics = ActiveUIInvalidation(rawValue: 1 << 2)
        static let transcript = ActiveUIInvalidation(rawValue: 1 << 3)
        static let runInteraction = ActiveUIInvalidation(rawValue: 1 << 4)

        static let all: ActiveUIInvalidation = [
            .composer,
            .statusPills,
            .runtimeMetrics,
            .transcript,
            .runInteraction
        ]
    }

    /// Compatibility alias retained while Agent Mode call sites migrate to the
    /// provider binding layer's top-level permission profile model.
    typealias AgentPermissionProfile = AgentProviderPermissionProfile

    struct AgentRunEpochTransitionIntent: Equatable {
        let token: UUID
        let kind: AgentRunEpochTransitionKind
        let expectedCurrentEpoch: AgentRunTurnEpoch?
    }

    struct AgentMCPControlContext: Equatable {
        let sessionID: UUID
        let activationID: UUID
        let registration: AgentRunSessionStore.Registration
        var currentEpoch: AgentRunTurnEpoch?
        var preparedEpoch: AgentRunTurnEpoch?
        var pendingEpochTransition: AgentRunEpochTransitionIntent?
        let originatingConnectionID: UUID?
        let interactionTransport: AgentInteractionTransport
        let suppressUserNotifications: Bool
        let forceAutoEditEnabled: Bool
        let autoEditEnabledBeforeOverride: Bool
        /// The task label kind for this MCP-controlled run (e.g. explore, engineer).
        /// Used to customize tool advertisement and system prompts for role-specific behavior.
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?

        func replacingRegistration(_ registration: AgentRunSessionStore.Registration) -> Self {
            Self(
                sessionID: sessionID,
                activationID: activationID,
                registration: registration,
                currentEpoch: currentEpoch,
                preparedEpoch: preparedEpoch,
                pendingEpochTransition: pendingEpochTransition,
                originatingConnectionID: originatingConnectionID,
                interactionTransport: interactionTransport,
                suppressUserNotifications: suppressUserNotifications,
                forceAutoEditEnabled: forceAutoEditEnabled,
                autoEditEnabledBeforeOverride: autoEditEnabledBeforeOverride,
                taskLabelKind: taskLabelKind
            )
        }
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    enum MCPActiveInstructionDeliverySignalTiming: Equatable {
        /// The instruction can wake MCP waiters as soon as the local optimistic submit is accepted.
        case afterOptimisticSubmit
        /// The runtime has a provider-specific handoff path and wakes MCP waiters after provider send.
        case afterProviderSend
    }

    enum ActiveProviderSteeringRoute: Equatable {
        case acpPrompt
        case claudeNativeInterrupt
    }

    enum MCPInstructionDispatch: String, Equatable {
        case deliveredIntoWaitingContinuation = "delivered_waiting_continuation"
        case queuedClaudeInterrupt = "queued_claude_interrupt"
        case queuedACPInterrupt = "queued_acp_interrupt"
        case queuedFollowUp = "queued_follow_up"
        case dispatchedCodexTurn = "dispatched_codex_turn"
        case startedRun = "started_run"

        /// Whether this dispatch sent an instruction into an already-running session.
        /// Used to suppress stale assistant previews in the immediate steer response.
        var isActiveRunDispatch: Bool {
            switch self {
            case .queuedClaudeInterrupt, .queuedACPInterrupt, .queuedFollowUp, .dispatchedCodexTurn:
                true
            case .deliveredIntoWaitingContinuation, .startedRun:
                false
            }
        }

        /// Whether MCP waiters should be woken as soon as `mcpDispatchInstruction` returns.
        /// Some runtimes accept the local queue before provider delivery; those signal later
        /// from their provider-specific flush path.
        var signalsMCPDeliveryAfterDispatch: Bool {
            guard isActiveRunDispatch else { return false }
            switch self {
            case .queuedClaudeInterrupt, .queuedACPInterrupt:
                return false
            case .queuedFollowUp, .dispatchedCodexTurn:
                return true
            case .deliveredIntoWaitingContinuation, .startedRun:
                return false
            }
        }
    }

    struct MCPActiveInstructionDispatchPlan {
        let delivery: MCPInstructionDispatch
        let codexAttemptID: UUID?
        let signalsDeliveryAfterDispatch: Bool
    }

    struct MCPInteractionResponsePayload: Equatable {
        let text: String?
        let skip: Bool
        let explicitSkip: Bool
        let decisionRaw: String?
        let amendment: String?
        let answersByQuestionID: [String: [String]]
        let askUserAnswersByQuestionID: [String: AgentAskUserAnswer]
        let hasStructuredAnswerObjects: Bool
        let elicitationActionRaw: String?
        let elicitationContent: [String: AgentJSONValue]
        let elicitationMeta: [String: AgentJSONValue]

        init(
            text: String?,
            skip: Bool,
            explicitSkip: Bool = false,
            decisionRaw: String?,
            amendment: String?,
            answersByQuestionID: [String: [String]],
            askUserAnswersByQuestionID: [String: AgentAskUserAnswer] = [:],
            hasStructuredAnswerObjects: Bool = false,
            elicitationActionRaw: String? = nil,
            elicitationContent: [String: AgentJSONValue] = [:],
            elicitationMeta: [String: AgentJSONValue] = [:]
        ) {
            self.text = text
            self.skip = skip
            self.explicitSkip = explicitSkip
            self.decisionRaw = decisionRaw
            self.amendment = amendment
            self.answersByQuestionID = answersByQuestionID
            self.askUserAnswersByQuestionID = askUserAnswersByQuestionID
            self.hasStructuredAnswerObjects = hasStructuredAnswerObjects
            self.elicitationActionRaw = elicitationActionRaw
            self.elicitationContent = elicitationContent
            self.elicitationMeta = elicitationMeta
        }
    }

    struct MCPSessionTarget: Equatable {
        /// How this session target was obtained.
        enum Origin: Equatable {
            case existingSession
            case existingTab
            case createdForSessionResume
            case createdNewTab
        }

        let tabID: UUID
        let sessionID: UUID?
        let origin: Origin
    }

    struct AutoEditPermissionGuidance: Equatable {
        enum Provider: Equatable {
            case codex
            case claude
        }

        enum Action: Equatable {
            case setCodexReadOnly
            case setClaudeRequireApproval
        }

        let provider: Provider
        let message: String
        let actionTitle: String
        let action: Action
    }

    struct NonCodexTurnTokenAccumulator {
        var estimatedUserInputTokens: Int = 0
        var estimatedToolInputTokens: Int = 0
        var estimatedToolOutputTokens: Int = 0
        /// Exact stream-derived context snapshot for the current turn (from usage events),
        /// tracked separately from the session-wide display value to prevent billed-turn
        /// aggregates from overwriting it.
        var observedContextUsedTokens: Int?

        var estimatedInputTokens: Int {
            estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
        }
    }

    enum AttachmentTurnDisposition: Equatable {
        case restoreToPending
        case deleteFiles
        case keepFiles
    }

    enum AttachmentTurnState: Equatable {
        case idle
        case reserved(reservationID: UUID, attachments: [AgentImageAttachment])
        case consumed(reservationID: UUID, attachments: [AgentImageAttachment])
    }

    struct CodexComputerUseActivation: Equatable {
        let id: UUID
        let createdAt: Date
    }

    struct NativeSlashPreparedUserTurn: Equatable {
        let command: CodexAgentModeCoordinator.NativeSlashCommand
        let argumentsText: String
        let providerText: String
        let bubbleWorkflow: AgentWorkflowDefinition?
        let shouldEnableCodexComputerUse: Bool
    }

    struct PendingHandoffState: Equatable {
        var payload: String?
        var createdAt: Date?
        var sourceItemID: UUID?
        /// True only for a freshly-created handoff tab. Keeps agent selection editable
        /// until the destination tab successfully sends its first real user turn.
        var defersProviderLockUntilSend: Bool = false
        var isStagedForSend: Bool = false

        var hasPayload: Bool {
            guard let payload else { return false }
            return !payload.isEmpty
        }

        mutating func clearAfterSend() {
            payload = nil
            createdAt = nil
            sourceItemID = nil
            defersProviderLockUntilSend = false
            isStagedForSend = false
        }
    }

    struct CodexWatchdogState: Equatable {
        var lastProgressAt: Date?
        var suppressUntil: Date?
        var ambiguousActiveProbeCount: Int = 0
        var isPausedAfterWarning: Bool = false
        var warnedSinceLastProgress: Bool = false
        var requiresColdTeardownOnCancel: Bool = false
    }

    struct CodexResumeTimeoutState: Equatable {
        var conversationID: String?
        var rolloutPath: String?
        var consecutiveTimeouts: Int = 0
    }

    struct CodexNativeToolLivenessState: Equatable {
        struct Key: Hashable {
            let invocationID: UUID?
            let fallbackSignature: String
        }

        struct Execution: Equatable {
            let toolName: String
            let startedAt: Date
            var lastSignalAt: Date
            var processID: String?
            var sawRunningUpdate: Bool = false
        }

        var inFlight: [Key: Execution] = [:]
    }

    struct BashLiveExecutionState: Equatable {
        private static let runningStatusWords: Set<String> = ["running", "in_progress", "inprogress", "in-progress", "pending"]

        let executionKey: String
        let transcriptItemID: UUID
        let toolName: String
        let invocationID: UUID?
        let fallbackSignature: String
        var processID: String?
        var command: String?
        var statusWord: String?
        var exitCode: Int?
        var output: String?
        var isSummaryOnly: Bool
        var lastSignalAt: Date

        var isRunning: Bool {
            guard let statusWord = statusWord?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !statusWord.isEmpty
            else {
                return exitCode == nil
            }
            return Self.runningStatusWords.contains(statusWord)
        }

        var parsedResult: BashToolResultParser.ParsedResult {
            .init(
                isRunning: isRunning,
                command: command,
                statusWord: statusWord,
                exitCode: exitCode,
                output: output,
                processID: processID,
                isSummaryOnly: isSummaryOnly
            )
        }

        var renderedResultJSON: String {
            BashToolResultParser.resultJSON(
                statusWord: statusWord ?? (isRunning ? "running" : "completed"),
                command: command,
                processID: processID,
                output: output,
                exitCode: exitCode,
                summaryOnly: isSummaryOnly
            )
        }
    }

    enum SourceItemsMutation {
        case append(index: Int, itemKind: AgentChatItemKind)
        case replace(index: Int, previousKind: AgentChatItemKind, currentKind: AgentChatItemKind)
        case mutate(index: Int, itemKind: AgentChatItemKind)
        case remove(index: Int, itemKind: AgentChatItemKind)
        case replaceAll
        case structural

        var changedIndexRange: ClosedRange<Int>? {
            switch self {
            case let .append(index, _),
                 let .replace(index, _, _),
                 let .mutate(index, _),
                 let .remove(index, _):
                index ... index
            case .replaceAll, .structural:
                nil
            }
        }

        var touchesUserItem: Bool {
            switch self {
            case let .append(_, itemKind),
                 let .mutate(_, itemKind),
                 let .remove(_, itemKind):
                itemKind == .user
            case let .replace(_, previousKind, currentKind):
                previousKind == .user || currentKind == .user
            case .replaceAll, .structural:
                true
            }
        }

        var isStructural: Bool {
            switch self {
            case .remove, .replaceAll, .structural:
                true
            case .append, .replace, .mutate:
                false
            }
        }
    }

    enum AgentTranscriptAutoFollowArmingState: String, Codable, Equatable {
        case armed
        case disarmedAfterManualDetach
    }

    struct PendingSourceItemsMutationSummary: Equatable {
        var earliestChangedIndex: Int
        var latestChangedIndex: Int
        var containsRemoval: Bool
        var containsReplaceAll: Bool
        var containsUserMutation: Bool
        var containsStructuralMutation: Bool

        init(_ mutation: SourceItemsMutation) {
            let changedRange = mutation.changedIndexRange
            earliestChangedIndex = changedRange?.lowerBound ?? 0
            latestChangedIndex = changedRange?.upperBound ?? Int.max
            containsRemoval = {
                if case .remove = mutation { return true }
                return false
            }()
            containsReplaceAll = {
                if case .replaceAll = mutation { return true }
                return false
            }()
            containsUserMutation = mutation.touchesUserItem
            containsStructuralMutation = mutation.isStructural
        }

        mutating func merge(_ mutation: SourceItemsMutation) {
            if let changedRange = mutation.changedIndexRange {
                earliestChangedIndex = min(earliestChangedIndex, changedRange.lowerBound)
                latestChangedIndex = max(latestChangedIndex, changedRange.upperBound)
            } else {
                earliestChangedIndex = 0
                latestChangedIndex = Int.max
            }
            if case .remove = mutation {
                containsRemoval = true
            }
            if case .replaceAll = mutation {
                containsReplaceAll = true
            }
            containsUserMutation = containsUserMutation || mutation.touchesUserItem
            containsStructuralMutation = containsStructuralMutation || mutation.isStructural
        }

        var allowsIncrementalFinalTurnRebuild: Bool {
            !containsRemoval
                && !containsReplaceAll
                && !containsUserMutation
                && !containsStructuralMutation
        }
    }

    struct DerivedTranscriptSyncState: Equatable {
        let sourceItemsRevision: Int
        let nextSequenceIndex: Int
        let runState: AgentSessionRunState
        let selectedAgent: AgentProviderKind
        let hidePendingQuestionToolCall: Bool
        let projectionProtection: AgentTranscriptProjectionProtection
    }

    struct PersistableTranscriptSnapshot {
        let transcript: AgentTranscript
        let projectionCounts: AgentTranscriptProjectionCounts
        let canonicalVisibleRowCount: Int
        let lastUserMessageAt: Date?
    }

    struct ActiveTranscriptFollowBindingState: Equatable {
        var tabID: UUID?
        var viewportState: AgentTranscriptViewportState = .liveBottom
        var armingState: AgentTranscriptAutoFollowArmingState = .armed
    }

    struct ActivePermissionChromeState: Equatable {
        let permissionProfile: AgentPermissionProfile
        let isSubagent: Bool
        let externallyManagedReason: String?

        static let userConfigured = ActivePermissionChromeState(
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: nil
        )
    }

    struct SidebarSession: Identifiable, Equatable {
        let id: UUID
        let tabID: UUID
        let title: String
        let lastUserMessageAt: Date?
        let activityDate: Date
        let isPinned: Bool
        let sessionID: UUID?
        let parentSessionID: UUID?
        let depth: Int
        let isMCPControlled: Bool
        /// Bound-worktree visual identity for this session (Item 10). Nil when
        /// the session has no worktree bindings. Carries the representative
        /// (first) binding when a session is bound to multiple roots.
        let worktree: AgentWorktreeIndicator?
        /// Active worktree merge attention for this session (Item 8). Set when
        /// the session has an awaiting-approval, conflicted, or
        /// awaiting-commit merge operation; nil otherwise.
        let worktreeMergeAttention: AgentWorktreeMergeAttention?
        let threadKey: AgentSidebarThreadKey?
        let hasThreadChildren: Bool
        let isThreadCollapsed: Bool
        let hiddenThreadDescendantCount: Int
        /// Number of hidden descendants (under this collapsed parent) that
        /// currently carry an unseen run-state attention badge. Used to tint
        /// the parent row's collapsed-count chip so a hidden sub-agent chat
        /// completing or needing approval still gets a visible signal.
        let hiddenThreadDescendantAttentionCount: Int
        let threadActivityDate: Date?

        init(
            id: UUID,
            tabID: UUID,
            title: String,
            lastUserMessageAt: Date?,
            activityDate: Date,
            isPinned: Bool,
            sessionID: UUID?,
            parentSessionID: UUID?,
            depth: Int,
            isMCPControlled: Bool,
            worktree: AgentWorktreeIndicator? = nil,
            worktreeMergeAttention: AgentWorktreeMergeAttention? = nil,
            threadKey: AgentSidebarThreadKey? = nil,
            hasThreadChildren: Bool = false,
            isThreadCollapsed: Bool = false,
            hiddenThreadDescendantCount: Int = 0,
            hiddenThreadDescendantAttentionCount: Int = 0,
            threadActivityDate: Date? = nil
        ) {
            self.id = id
            self.tabID = tabID
            self.title = title
            self.lastUserMessageAt = lastUserMessageAt
            self.activityDate = activityDate
            self.isPinned = isPinned
            self.sessionID = sessionID
            self.parentSessionID = parentSessionID
            self.depth = depth
            self.isMCPControlled = isMCPControlled
            self.worktree = worktree
            self.worktreeMergeAttention = worktreeMergeAttention
            self.threadKey = threadKey
            self.hasThreadChildren = hasThreadChildren
            self.isThreadCollapsed = isThreadCollapsed
            self.hiddenThreadDescendantCount = hiddenThreadDescendantCount
            self.hiddenThreadDescendantAttentionCount = hiddenThreadDescendantAttentionCount
            self.threadActivityDate = threadActivityDate
        }
    }

    struct BuiltTranscriptPresentation {
        let transcript: AgentTranscript
        let baseProjection: AgentTranscriptProjection
        let fullProjection: AgentTranscriptProjection
        let workingProjection: AgentTranscriptProjection
        let projection: AgentTranscriptProjection
        let turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
        let archivedSnapshot: AgentArchivedTranscriptSnapshot
        let projectionProtection: AgentTranscriptProjectionProtection
        let canonicalVisibleRowCount: Int
        let projectionCounts: AgentTranscriptProjectionCounts
        let analyticsSnapshot: AgentTranscriptAnalyticsSnapshot
        let sanitizedActivityCount: Int
        let performanceSnapshot: AgentTranscriptPerformanceSnapshot
        let rawToolResultPayloadRenderRevision: Int
    }

    enum DerivedTranscriptRefreshReason: String {
        case liveMutation
        case saveSession
        case coldLoad
        case manualRefresh
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct SessionTreeNode {
        var parentSessionID: UUID?
        var composeTabIDs: Set<UUID> = []
        var stashedTabIDs: Set<UUID> = []
    }

    struct AgentExecutionWorktreeSelection: Equatable, Identifiable {
        let repositoryID: String
        let repoKey: String
        let worktreeID: String
        let path: String
        let name: String?
        let branch: String?
        let head: String?
        let isDetached: Bool
        let label: String
        let colorHex: String?
        let isLocked: Bool
        let lockReason: String?
        let isPrunable: Bool
        let prunableReason: String?

        var id: String {
            presentationID
        }

        /// Stable SwiftUI identity for picker presentation. Selection semantics
        /// remain repositoryID + worktreeID; this ID also includes the normalized
        /// path so malformed duplicate Git records cannot collide in ForEach.
        var presentationID: String {
            let checkoutPath = CheckoutPathIdentity.canonicalPathOrOriginal(path)
            return "\(repositoryID)::\(worktreeID)::\(checkoutPath)"
        }
    }

    enum InitialStartLocation: Equatable {
        case local
        case newWorktree
        case existingWorktree(AgentExecutionWorktreeSelection)

        var label: String {
            switch self {
            case .local:
                "Work locally"
            case .newWorktree:
                "New worktree"
            case let .existingWorktree(selection):
                selection.label
            }
        }
    }

    enum ExecutionLocationChangeConfirmation: Equatable {
        case startedThreadRestart
        case activeRunStop
    }

    enum ExecutionLocationChangeResult: Equatable {
        case applied
        case unchanged
        case confirmationRequired(ExecutionLocationChangeConfirmation)
        case blocked(String)
    }

    enum WorktreeBindingTransitionIntent {
        case initialSend
        case userExecutionLocationChange(confirmation: ExecutionLocationChangeConfirmation?)
        case externalManagement
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct PendingUserTurnState: Equatable {
        let workflow: AgentWorkflowDefinition?
        let imageAttachments: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        let initialStartLocation: InitialStartLocation

        var isEmpty: Bool {
            workflow == nil
                && imageAttachments.isEmpty
                && taggedFileAttachments.isEmpty
                && initialStartLocation == .local
        }
    }

    /// Event emitted when queued steering text needs to be restored to the composer
    /// (e.g., steering send failed, or the user cancelled the run while messages were queued).
    struct DraftRestorationEvent: Equatable, Identifiable {
        let id: UUID
        let tabID: UUID
        let text: String
        let message: String
        let strategy: AgentModeRunService.DraftRestorationStrategy
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct ImageAttachmentFingerprint: Hashable {
        let byteCount: Int64
        let digestHex: String
    }

    struct SlashSkillToken: Equatable {
        let name: String
        let tokenRange: NSRange
        let argumentsRange: NSRange
    }

    struct ResolvedSlashSkillInvocation: Equatable {
        let definition: AgentSkillDefinition
        let token: SlashSkillToken
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct ResolvedNativeSlashCommand: Equatable {
        let command: CodexAgentModeCoordinator.NativeSlashCommand
        let token: SlashSkillToken
        let argumentsText: String
    }
}
