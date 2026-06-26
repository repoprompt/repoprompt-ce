import Combine
import Foundation

extension AgentModeViewModel {
    // MARK: - Tab Session

    /// Per-tab session state for agent mode
    @MainActor
    final class TabSession: ObservableObject {
        let tabID: UUID
        private var suppressSourceItemsChanged = false

        /// Canonical runtime source-item suffix. Coordinators and tests mutate this list,
        /// but it only retains the mutable full-detail working turns; older compacted
        /// history lives in `transcript` and should not be rehydrated back into this array.
        @Published var items: [AgentChatItem] = [] {
            didSet {
                guard !suppressSourceItemsChanged else { return }
                rebuildSourceItemDerivedState()
                onSourceItemsChanged?(self, .structural)
            }
        }

        var transcript: AgentTranscript = .empty
        var baseTranscriptProjection: AgentTranscriptProjection = .empty
        var fullTranscriptProjection: AgentTranscriptProjection = .empty
        var workingTranscriptProjection: AgentTranscriptProjection = .empty
        var transcriptProjection: AgentTranscriptProjection = .empty
        var turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:]
        var archivedTranscriptSnapshot: AgentArchivedTranscriptSnapshot = .empty
        var isCompressedHistoryRevealed: Bool = false
        var transcriptProjectionProtection: AgentTranscriptProjectionProtection = .none
        var transcriptCanonicalVisibleRowCount: Int = 0
        var transcriptProjectionCounts: AgentTranscriptProjectionCounts = .zero
        var transcriptAnalyticsSnapshot: AgentTranscriptAnalyticsSnapshot = .init()
        var transcriptPerformanceSnapshot: AgentTranscriptPerformanceSnapshot = .empty
        var ephemeralToolResultPayloadByItemID: [UUID: String] = [:]
        var ephemeralToolResultPayloadRevisionByItemID: [UUID: Int] = [:]
        private(set) var liveItemIDs: Set<UUID> = []
        private var toolCorrelationIndexes = ToolCorrelationIndexes()
        private var nextEphemeralToolResultPayloadRevision: Int = 1
        var rawToolResultPayloadRenderRevision: Int = 0
        var onSourceItemsChanged: ((TabSession, SourceItemsMutation) -> Void)?
        var onRunStateChanged: ((TabSession) -> Void)?
        #if DEBUG
            private(set) var test_incrementalRetentionCompactionCount = 0
        #endif

        /// Run state
        @Published var runState: AgentSessionRunState = .idle {
            didSet {
                guard runState != oldValue else { return }
                onRunStateChanged?(self)
            }
        }

        @Published var runningStatusText: String? = nil
        var activeAgentRunStartedAt: Date?

        enum RunningStatusSource: Equatable {
            case transport
            case reasoning
            case reconnect
        }

        struct CodexReasoningSegmentState {
            var summaryMarkdown: String = ""
            var bodyMarkdown: String = ""
            var transcriptItemID: UUID?
            var statusTitle: String?
        }

        struct AgentTurnRuntimeAnchor: Equatable {
            let userItemID: UUID
            let userSequenceIndex: Int
            let startedAt: Date
        }

        var runningStatusSource: RunningStatusSource?
        var nativeControlProgressID: UUID?
        var claudeReasoningStatusBuffer: String = ""
        var claudeReasoningStatusPendingText: String?
        var claudeReasoningStatusFlushTask: Task<Void, Never>?
        var codexReasoningSegmentsByKey: [String: CodexReasoningSegmentState] = [:]
        var pendingTurnRuntimeAnchors: [AgentTurnRuntimeAnchor] = []
        var agentMessageRuntimeFootersByItemID: [UUID: AgentMessageRuntimeFooter] = [:]

        /// Tracks whether this session already contains a real user turn.
        /// Provider selection may still remain temporarily editable for a handoff destination
        /// until its first destination-side send succeeds.
        var hasSentFirstMessage: Bool = false

        var deservesProviderVisibleBranchSwitchNote: Bool {
            runState.isActive || providerSessionID != nil || !items.isEmpty || hasSentFirstMessage
        }

        /// Ephemeral location intent for a new manual thread. It is consumed on first send
        /// and intentionally never persisted as session state.
        var pendingInitialStartLocation: InitialStartLocation = .local
        var composerSubmissionToken = UUID()
        var activeComposerSubmitAttempt: AgentComposerSubmitAttempt?
        var isComposerSubmissionInFlight: Bool {
            activeComposerSubmitAttempt != nil
        }

        var isPreparingInitialWorktree: Bool = false
        var isChangingExecutionLocation: Bool = false
        var worktreeBindingTransitionInProgress: Bool = false

        // Wait/question state
        @Published var waitingPrompt: String? = nil
        @Published var pendingAskUser: AgentAskUserPendingState? = nil
        @Published var pendingUserInputRequest: AgentRequestUserInputRequest? = nil
        @Published var pendingApproval: AgentApprovalRequest? = nil
        @Published var pendingPermissionsRequest: AgentPermissionsRequest? = nil
        @Published var pendingMCPElicitationRequest: AgentMCPElicitationRequest? = nil
        @Published var pendingApplyEditsReview: PendingApplyEditsReview? = nil
        @Published var pendingWorktreeMergeReview: PendingWorktreeMergeReview? = nil
        var queuedUserInputRequests: [AgentRequestUserInputRequest] = []
        var queuedMCPElicitationRequests: [AgentMCPElicitationRequest] = []
        var transcriptViewportState: AgentTranscriptViewportState = .liveBottom
        var transcriptAutoFollowArmingState: AgentTranscriptAutoFollowArmingState = .armed
        var askUserContinuation: CheckedContinuation<AgentAskUserResponse, Error>?
        var askUserTimeoutTask: Task<Void, Never>?
        var pendingAskUserTimeoutGeneration: UInt64 = 0
        var hasPendingQuestionUI: Bool {
            pendingAskUser != nil || pendingUserInputRequest != nil || pendingMCPElicitationRequest != nil
        }

        var applyEditsApprovalSubscriptionID: UUID?
        var applyEditsApprovalSubscriptionTask: Task<Void, Never>?
        var worktreeMergeReviewContinuation: CheckedContinuation<WorktreeMergeReviewDecision, Never>?
        var worktreeMergeReviewTimeoutTask: Task<Void, Never>?
        var mcpControlContext: AgentMCPControlContext?
        var mcpStateObservationCancellable: AnyCancellable?
        var mcpControlCleanupTask: Task<Void, Never>?
        var mcpControlActivationGeneration: UInt64 = 0
        var mcpFollowUpRunPendingUpdatedAt: Date?
        var mcpFollowUpRunPending: Bool = false {
            didSet {
                if oldValue != mcpFollowUpRunPending {
                    mcpFollowUpRunPendingUpdatedAt = Date()
                }
            }
        }

        var isMCPInstructionDispatchInProgress: Bool = false
        /// Whether this session was originally created by an MCP client.
        var isMCPOriginated: Bool = false
        /// Persisted logical-root to worktree bindings for this Agent session.
        var worktreeBindings: [AgentSessionWorktreeBinding] = []
        /// Persisted resumable worktree-merge operations for this Agent session.
        var worktreeMergeOperations: [AgentSessionWorktreeMergeOperation] = []
        /// Permission profile for the current session. Set to `.mcpSafeDefaults`
        /// when MCP control is active, `.userConfigured` otherwise.
        var permissionProfile: AgentPermissionProfile = .userConfigured

        // Instruction queue for when user sends while agent is not waiting (shared across all runners)
        var pendingInstructions: [String] = []
        let codexSteerAckTracker = CodexSteerAckTracker()

        /// Claude-only steering queue — carries draft text for restoration on cancel/failure
        struct ClaudeSteeringInstruction: Equatable, Identifiable {
            let id: UUID
            /// The Claude run this steering message was queued against.
            let targetRunID: UUID?
            /// The Claude runner attempt this steering message was queued against.
            let targetRunAttemptID: UUID?
            /// The text we actually send to the provider (may include workflow wrapping, etc.)
            let providerText: String
            let attachments: [AgentImageAttachment]
            let taggedFileAttachments: [AgentTaggedFileAttachment]
            /// The original user-typed text to restore into the composer on failure/cancel.
            let draftText: String
            /// The optimistic user bubble we appended (for potential removal on failure).
            let optimisticUserItemID: UUID?
            let createdAt: Date
            /// Claude turn completions protected by this accepted steering instruction.
            var supersedingProtectedTurnIDs: Set<UUID> = []
        }

        var pendingClaudeSteeringInstructions: [ClaudeSteeringInstruction] = []
        /// Claude turn IDs whose terminal events should be treated as superseded by accepted steering.
        var claudeSupersedingProtectedTurnIDs: Set<UUID> = []
        /// Task that drains `pendingClaudeSteeringInstructions` one-by-one, waiting for MCP tool idle between each.
        var claudeSteeringFlushTask: Task<Void, Never>?

        /// ACP steering queue — carries text accepted for serialized live steering.
        struct ACPSteeringInstruction: Identifiable {
            let id: UUID
            /// The ACP process run this steering message was queued against.
            let targetRunID: UUID?
            /// The ACP runner attempt this steering message was queued against.
            let targetRunAttemptID: UUID?
            /// The steering text we actually send to the provider (may include workflow wrapping, etc.)
            let providerText: String
            /// The active ACP prompt's user text when this steering was queued. Some
            /// providers drop the cancelled prompt from provider history, so the flush
            /// re-bundles this with `providerText` after session/cancel.
            let interruptedPromptProviderText: String?
            let attachments: [AgentImageAttachment]
            let taggedFileAttachments: [AgentTaggedFileAttachment]
            /// The original user-typed text to restore into the composer on failure/cancel.
            let draftText: String
            /// The optimistic user bubble we appended (for potential removal on failure).
            let optimisticUserItemID: UUID?
            let createdAt: Date
        }

        var pendingACPSteeringInstructions: [ACPSteeringInstruction] = []
        /// Task that drains `pendingACPSteeringInstructions` one-by-one, waiting for MCP tool idle between each.
        var acpSteeringFlushTask: Task<Void, Never>?

        /// Number of upcoming turnCompleted events that should be treated as intermediate
        /// because we successfully queued a follow-up prompt during the same run.
        var pendingSupersedingTurnCompletionsUpdatedAt: Date?
        var pendingSupersedingTurnCompletions: Int = 0 {
            didSet {
                if oldValue != pendingSupersedingTurnCompletions {
                    pendingSupersedingTurnCompletionsUpdatedAt = Date()
                }
            }
        }

        struct CodexPendingAuthRetryTurn: Equatable {
            var text: String
            var images: [AgentImageAttachment]
            var model: String?
            var reasoningEffort: String?
            var serviceTier: String?
            var attachmentReservationID: UUID?
            var expectedTurnID: String?
            var retryAttempted: Bool = false
        }

        enum CodexTurnKind: String {
            case user
            case compact
            case review
            case unknown
        }

        struct CodexAuthoritativeTurnIdentity: Equatable {
            let threadID: String
            let turnID: String
            let turnKind: CodexTurnKind
            let controllerInstanceID: ObjectIdentifier
            let controllerGeneration: UUID
            let runID: UUID
            let runAttemptID: UUID
        }

        struct CodexAnonymousTurnLiveness: Equatable {
            let threadID: String
            let turnKind: CodexTurnKind
            let controllerInstanceID: ObjectIdentifier
            let controllerGeneration: UUID
            let runID: UUID
            let runAttemptID: UUID
        }

        enum CodexFallbackOrigin: Equatable {
            case manual
            case mcp(attemptID: UUID)
        }

        @MainActor
        final class CodexDispatchSerialGate {
            private var nextTicket: UInt64 = 0
            private var servingTicket: UInt64 = 0
            private var cancelledTickets: Set<UInt64> = []
            private var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

            func issueTicket() -> UInt64 {
                defer { nextTicket &+= 1 }
                return nextTicket
            }

            func awaitTurn(_ ticket: UInt64) async -> Bool {
                if cancelledTickets.remove(ticket) != nil {
                    advancePastCancelledTickets()
                    return false
                }
                if ticket == servingTicket {
                    return true
                }
                return await withCheckedContinuation { continuation in
                    waiters[ticket] = continuation
                }
            }

            func finish(_ ticket: UInt64) {
                guard ticket == servingTicket else { return }
                servingTicket &+= 1
                advancePastCancelledTickets()
                waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
            }

            func cancel(_ ticket: UInt64) {
                if let waiter = waiters.removeValue(forKey: ticket) {
                    waiter.resume(returning: false)
                }
                cancelledTickets.insert(ticket)
                guard ticket == servingTicket else { return }
                advancePastCancelledTickets()
                waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
            }

            private func advancePastCancelledTickets() {
                while cancelledTickets.remove(servingTicket) != nil {
                    servingTicket &+= 1
                }
            }
        }

        enum CodexFallbackReason: Equatable {
            case activeWithoutAuthoritativeIdentity
            case staleAuthoritativeIdentity
            case nonSteerableTurn(kind: CodexTurnKind)
            case noActiveTurn(failure: CodexAppServerClient.RequestFailure)
            case expectedTurnMismatch(
                expectedTurnID: String,
                actualTurnID: String?,
                failure: CodexAppServerClient.RequestFailure
            )
            case activeTurnNotSteerable(
                turnKind: String?,
                failure: CodexAppServerClient.RequestFailure
            )
        }

        struct CodexFallbackSubmissionContext: Equatable {
            let queueID: UUID
            let providerText: String
            let images: [AgentImageAttachment]
            let taggedFileAttachments: [AgentTaggedFileAttachment]
            let draftText: String
            let optimisticUserItemID: UUID?
            let origin: CodexFallbackOrigin
            let dispatchTicket: UInt64?
        }

        struct CodexFallbackBlockingTurn: Equatable {
            let threadID: String
            let turnID: String
            let controllerInstanceID: ObjectIdentifier
            let controllerGeneration: UUID
            let runID: UUID
            let runAttemptID: UUID
        }

        struct CodexPendingSteerLifecycleReconciliation: Equatable {
            let priorIdentity: CodexAuthoritativeTurnIdentity
            let acceptedDispatchTurnID: String
        }

        enum CodexFallbackQueueState: Equatable {
            case queued
            case eligibleForSuccessor(completedTurnID: String)
            case dispatching
            case awaitingLifecycleStart
            case lifecycleStarted
        }

        struct CodexFallbackQueueEntry: Equatable, Identifiable {
            let id: UUID
            let providerText: String
            let images: [AgentImageAttachment]
            let taggedFileAttachments: [AgentTaggedFileAttachment]
            let model: String?
            let reasoningEffort: String?
            let serviceTier: String?
            let attachmentReservationID: UUID?
            let optimisticUserItemID: UUID?
            let draftText: String
            let origin: CodexFallbackOrigin
            let fallbackReason: CodexFallbackReason
            let originThreadID: String
            let originControllerInstanceID: ObjectIdentifier
            let originControllerGeneration: UUID
            let originRunID: UUID
            let originRunAttemptID: UUID
            var blockingTurn: CodexFallbackBlockingTurn?
            var state: CodexFallbackQueueState
        }

        var codexPendingTurnKind: CodexTurnKind?
        var codexPendingAuthRetryTurn: CodexPendingAuthRetryTurn?
        var codexAuthoritativeActiveTurn: CodexAuthoritativeTurnIdentity?
        var codexAnonymousActiveTurn: CodexAnonymousTurnLiveness?
        var codexRoutingObservedTurnID: String?
        var codexPendingSteerLifecycleReconciliation: CodexPendingSteerLifecycleReconciliation?
        var codexFallbackQueue: [CodexFallbackQueueEntry] = []
        var codexFallbackDispatchInFlight: CodexFallbackQueueEntry?
        var codexFallbackPumpTask: Task<Void, Never>?
        var codexFallbackSuccessorRetryTask: Task<Void, Never>?
        let codexDispatchSerialGate = CodexDispatchSerialGate()

        // Instruction steering coordination state
        var instructionContinuation: CheckedContinuation<UserInstructionResponse, Error>?
        var instructionTimeoutTask: Task<Void, Never>?
        var instructionWaitID: UUID?

        // Agent run
        var runID: UUID?
        private(set) var runLifecycleTracker = AgentRunLifecycleTracker()
        var activeRunOwnership: AgentRunOwnership? {
            runLifecycleTracker.activeOwnership
        }

        var activeRunAttemptID: UUID? {
            activeRunOwnership?.attemptID
        }

        var activeRunLiveness: AgentRunLivenessSnapshot? {
            runLifecycleTracker.liveness
        }

        var provider: HeadlessAgentProvider?
        var agentTask: Task<Void, Never>?

        // Settings (per-tab)
        var selectedAgent: AgentProviderKind = .claudeCode
        var selectedModelRaw: String = AgentModel.defaultModel.rawValue
        var selectedReasoningEffortRaw: String?
        var autoEditEnabled: Bool = true
        var selectedModel: AgentModel {
            get { AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel }
            set { selectedModelRaw = newValue.rawValue }
        }

        /// Draft text for input field
        var draftText: String = "" {
            didSet {
                guard draftText != oldValue else { return }
                draftMutationGeneration &+= 1
            }
        }

        private(set) var draftMutationGeneration: UInt64 = 0

        /// Selected workflow template for next message
        var selectedWorkflow: AgentWorkflowDefinition?

        // Pending image attachments for the next user turn
        @Published var pendingImageAttachments: [AgentImageAttachment] = []
        @Published var pendingTaggedFileAttachments: [AgentTaggedFileAttachment] = []
        var attachmentsPendingProviderConsumptionCleanup: [AgentImageAttachment] = []
        var attachmentTurnState: AttachmentTurnState = .idle

        // Provider session ID for resumption (e.g., Claude CLI session_id)
        var providerSessionID: String?
        var providerTokenUsageByTurn: [AgentTokenUsagePersist] = []
        var pendingNonCodexUserInputTokenQueue: [Int] = []
        var activeNonCodexTurnTokenAccumulator: NonCodexTurnTokenAccumulator?

        // Codex native session identifiers and metadata
        var codexConversationID: String?
        var codexRolloutPath: String?
        var codexModel: String?
        var codexReasoningEffort: String?
        @Published var codexContextUsage: AgentContextUsage? = nil
        @Published var contextUsageSnapshot: ContextUsageSnapshot? = nil
        var contextCompactedAt: Date?
        var codexNeedsReconnect: Bool = false
        var codexResumeTimeoutState: CodexResumeTimeoutState = .init()
        var codexToolPreferencesGeneration: Int = 0
        var codexController: (any CodexSessionControlling)? {
            didSet {
                let oldIdentity = oldValue.map { ObjectIdentifier($0) }
                let newIdentity = codexController.map { ObjectIdentifier($0) }
                guard oldIdentity != newIdentity else { return }
                codexControllerGeneration = UUID()
                codexAuthoritativeActiveTurn = nil
                codexAnonymousActiveTurn = nil
                codexRoutingObservedTurnID = nil
            }
        }

        private(set) var codexControllerGeneration = UUID()
        /// The permission profile the current Codex controller was created with.
        /// Used to detect when MCP control changes require controller recycling.
        var codexControllerPermissionProfile: AgentPermissionProfile?
        /// The task label kind the current Codex controller was created with.
        /// Used to detect when role-specific native tool overrides require controller recycling.
        var codexControllerTaskLabelKind: AgentModelCatalog.TaskLabelKind?
        /// The effective workspace path the current Codex controller was created with.
        /// Used to recycle the provider when a session worktree binding changes cwd.
        var codexControllerWorkspacePath: String?
        var pendingCodexComputerUseActivation: CodexComputerUseActivation?
        var codexControllerComputerUseEnabled: Bool = false
        var codexControllerGoalSupportEnabled: Bool = false
        var wantsCodexComputerUseForNextTurn: Bool {
            pendingCodexComputerUseActivation != nil
        }

        var claudeController: (any NativeAgentRuntimeControlling)?
        var acpController: ACPAgentSessionController?
        var codexEventTask: Task<Void, Never>?
        var codexEventTaskRunID: UUID?
        var codexLastEventAt: Date?
        var codexWatchdogState: CodexWatchdogState = .init()
        var codexNativeToolLiveness: CodexNativeToolLivenessState = .init()
        /// Turn IDs started during the current run attempt, used to filter stale turnCompleted events.
        var claudeExpectedTurnIDs: Set<UUID> = []
        var hasReconciledPersistedCodexCommandStatus: Bool = false
        var activeReasoningItemID: UUID?
        var reasoningItemIDsByGroupID: [String: UUID] = [:]
        var pendingAssistantDelta: String = ""
        var pendingCodexAssistantScope: CodexNativeSessionController.ItemScope?
        var codexAssistantRowIDByScope: [CodexNativeSessionController.ItemScope: UUID] = [:]
        var assistantDeltaFlushTask: Task<Void, Never>?
        var assistantDeltaTaskGeneration: UInt64 = 0
        var assistantDeltaFlushGeneration: UInt64 = 0
        var providerTerminalDrainGeneration: UInt64 = 0
        var terminalCommitInProgress: Bool = false
        var lastTerminalCommitRevision: AgentRunTerminalCommitRevision?
        var lastTerminalPublicationResult: AgentRunTerminalPublicationResult?
        var runAttemptTerminalResources: AgentRunAttemptTerminalResources?
        /// Handoff payload (injected into provider-facing text on first user send).
        /// Cleared only after the provider accepts the turn.
        var pendingHandoff: PendingHandoffState = .init()

        var isProviderSelectionLocked: Bool {
            hasSentFirstMessage && !pendingHandoff.defersProviderLockUntilSend
        }

        // Persistence
        private(set) var persistentSessionBindingIdentity: AgentPersistentSessionBindingIdentity?
        var activeAgentSessionID: UUID? {
            persistentSessionBindingIdentity?.sessionID
        }

        private(set) var bindingTransitionGeneration: UInt64 = 0
        private(set) var bindingTransitionInProgress: Bool = false
        private(set) var persistenceMutationGeneration: UInt64 = 0
        var saveRequestGeneration: UInt64 = 0
        var parentSessionID: UUID?
        var hasLoadedPersistedState: Bool = false
        private(set) var authoritativeHydratedBinding: AgentPersistentSessionBindingIdentity?
        private(set) var authoritativeHydratedBindingTransitionGeneration: UInt64?
        var persistedLoadTask: Task<Void, Never>?
        var lastActivityAt: Date = .init()
        var lastUserMessageAt: Date?
        var lastCommandOutputSaveAt: Date?
        var saveDebounceTask: Task<Void, Never>?
        var isDirty: Bool = false {
            didSet {
                if isDirty {
                    persistenceMutationGeneration &+= 1
                }
            }
        }

        var sourceItemsRevision: Int = 0
        var pendingSourceItemsMutationSummary: PendingSourceItemsMutationSummary?
        var pendingDerivedTranscriptRefreshReason: DerivedTranscriptRefreshReason?
        var derivedTranscriptRefreshTask: Task<Void, Never>?
        var derivedTranscriptRefreshGeneration: UInt64 = 0
        var derivedTranscriptSyncState: DerivedTranscriptSyncState?
        var pendingCommandRunningByKey: [String: CodexNativeSessionController.CommandExecutionRunningUpdate] = [:]
        var pendingCommandRunningFlushTask: Task<Void, Never>?
        var pendingCommandRunningFlushUsesLiveOutputDelay: Bool = false
        var bashLiveExecutionByKey: [String: BashLiveExecutionState] = [:]
        var bashLiveExecutionKeyByTranscriptItemID: [UUID: String] = [:]

        /// Sequence tracking
        var nextSequenceIndex: Int = 0

        var bashLiveExecutionByTranscriptItemID: [UUID: BashLiveExecutionState] {
            var result: [UUID: BashLiveExecutionState] = [:]
            for (itemID, key) in bashLiveExecutionKeyByTranscriptItemID {
                guard let state = bashLiveExecutionByKey[key] else { continue }
                result[itemID] = state
            }
            return result
        }

        init(tabID: UUID) {
            self.tabID = tabID
        }

        deinit {
            applyEditsApprovalSubscriptionTask?.cancel()
        }

        @discardableResult
        func beginPersistentBindingTransition() -> UInt64 {
            bindingTransitionGeneration &+= 1
            bindingTransitionInProgress = true
            authoritativeHydratedBinding = nil
            authoritativeHydratedBindingTransitionGeneration = nil
            return bindingTransitionGeneration
        }

        func installPersistentSessionBinding(_ binding: AgentPersistentSessionBindingIdentity?) {
            precondition(binding == nil || binding?.tabID == tabID)
            persistentSessionBindingIdentity = binding
            bindingTransitionInProgress = false
        }

        func finishPersistentBindingTransition(generation: UInt64) {
            guard bindingTransitionGeneration == generation else { return }
            bindingTransitionInProgress = false
        }

        func markCurrentBindingHydrated() {
            guard hasLoadedPersistedState, !bindingTransitionInProgress else { return }
            authoritativeHydratedBinding = persistentSessionBindingIdentity
            authoritativeHydratedBindingTransitionGeneration = bindingTransitionGeneration
        }

        func clearCurrentBindingHydration() {
            authoritativeHydratedBinding = nil
            authoritativeHydratedBindingTransitionGeneration = nil
        }

        var hasBindingBlockingInteraction: Bool {
            waitingPrompt != nil
                || instructionContinuation != nil
                || pendingAskUser != nil
                || pendingUserInputRequest != nil
                || pendingApproval != nil
                || pendingPermissionsRequest != nil
                || pendingMCPElicitationRequest != nil
                || pendingApplyEditsReview != nil
                || pendingWorktreeMergeReview != nil
                || !queuedUserInputRequests.isEmpty
                || !queuedMCPElicitationRequests.isEmpty
        }

        func persistentBindingTransitionToken() -> PersistentBindingTransitionToken {
            PersistentBindingTransitionToken(
                tabID: tabID,
                sessionIdentity: ObjectIdentifier(self),
                binding: persistentSessionBindingIdentity,
                transitionGeneration: bindingTransitionGeneration,
                sourceItemsRevision: sourceItemsRevision
            )
        }

        #if DEBUG
            func testInstallPersistentSessionBinding(sessionID: UUID?) {
                _ = beginPersistentBindingTransition()
                installPersistentSessionBinding(
                    sessionID.map { AgentPersistentSessionBindingIdentity(tabID: tabID, sessionID: $0) }
                )
            }
        #endif

        func installRunAttemptTerminalResources(
            ownership: AgentRunOwnership,
            prepare: @escaping AgentRunAttemptTerminalResources.Prepare
        ) {
            guard isCurrentRunAttempt(ownership) else { return }
            runAttemptTerminalResources = AgentRunAttemptTerminalResources(
                ownership: ownership,
                prepare: prepare
            )
        }

        func claimRunAttemptTerminalTeardown(
            ownership: AgentRunOwnership,
            terminalState: AgentSessionRunState
        ) -> AgentRunAttemptTerminalResources.Teardown? {
            guard let resources = runAttemptTerminalResources else { return nil }
            let teardown = resources.claim(for: ownership, terminalState: terminalState)
            if resources.isClaimed {
                runAttemptTerminalResources = nil
            }
            return teardown
        }

        @discardableResult
        func beginRunAttempt(source: String, attemptID: UUID = UUID()) -> AgentRunOwnership {
            assert(runAttemptTerminalResources == nil || runAttemptTerminalResources?.isClaimed == true)
            runAttemptTerminalResources = nil
            terminalCommitInProgress = false
            lastTerminalCommitRevision = nil
            lastTerminalPublicationResult = nil
            providerTerminalDrainGeneration = 0
            codexAuthoritativeActiveTurn = nil
            codexAnonymousActiveTurn = nil
            codexRoutingObservedTurnID = nil
            codexPendingSteerLifecycleReconciliation = nil
            var turnEpoch: AgentRunTurnEpoch?
            if var context = mcpControlContext {
                turnEpoch = context.preparedEpoch ?? context.currentEpoch
                if context.preparedEpoch != nil {
                    context.preparedEpoch = nil
                    mcpControlContext = context
                }
            }
            let ownership = runLifecycleTracker.begin(
                tabID: tabID,
                persistentSessionID: activeAgentSessionID,
                persistentBindingGeneration: persistentSessionBindingIdentity?.generation,
                bindingTransitionGeneration: bindingTransitionGeneration,
                attemptID: attemptID,
                turnEpoch: turnEpoch
            )
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.lifecycle.attempt.started")
                AgentModePerfDiagnostics.increment("run.lifecycle.attempt.started.source.\(source)")
                AgentModePerfDiagnostics.event(
                    "run.lifecycle.attemptStarted",
                    tabID: tabID,
                    fields: [
                        "source": source,
                        "attemptID": AgentModePerfDiagnostics.shortID(ownership.attemptID),
                        "bindingGeneration": AgentModePerfDiagnostics.shortID(ownership.binding.generation),
                        "persistentBindingGeneration": AgentModePerfDiagnostics.shortID(ownership.binding.persistentBindingGeneration),
                        "bindingTransitionGeneration": String(ownership.binding.bindingTransitionGeneration),
                        "persistentSessionID": AgentModePerfDiagnostics.shortID(ownership.binding.persistentSessionID)
                    ]
                )
            #endif
            return ownership
        }

        func isCurrentRunAttempt(_ ownership: AgentRunOwnership, expectedRunID: UUID? = nil) -> Bool {
            guard activeRunOwnership == ownership else { return false }
            if let expectedRunID {
                return runID == expectedRunID
            }
            return true
        }

        func isCurrentRunAttemptForCurrentBinding(
            _ ownership: AgentRunOwnership,
            expectedRunID: UUID? = nil
        ) -> Bool {
            guard isCurrentRunAttempt(ownership, expectedRunID: expectedRunID) else { return false }
            return ownership.binding.tabID == tabID
                && ownership.binding.persistentSessionID == activeAgentSessionID
                && ownership.binding.persistentBindingGeneration == persistentSessionBindingIdentity?.generation
                && ownership.binding.bindingTransitionGeneration == bindingTransitionGeneration
                && !bindingTransitionInProgress
        }

        @discardableResult
        func recordRunProgress(
            ownership: AgentRunOwnership,
            kind: AgentRunLivenessSignalKind,
            stage: AgentRunLifecycleStage,
            retryIntent: AgentRunRetryIntent = .none,
            timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) -> AgentRunProgressAcceptance {
            let result = runLifecycleTracker.record(
                ownership: ownership,
                kind: kind,
                stage: stage,
                retryIntent: retryIntent,
                timestampUptimeNanoseconds: timestampUptimeNanoseconds
            )
            recordRunProgressDiagnostic(result, kind: kind, stage: stage)
            return result
        }

        @discardableResult
        func acceptRunProgress(_ signal: AgentRunProgressSignal) -> AgentRunProgressAcceptance {
            let result = runLifecycleTracker.accept(signal)
            recordRunProgressDiagnostic(result, kind: signal.kind, stage: signal.stage)
            return result
        }

        @discardableResult
        func endRunAttempt(ifCurrent ownership: AgentRunOwnership, source: String) -> Bool {
            guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
            recordRunAttemptEnded(ownership, source: source)
            return true
        }

        @discardableResult
        func endCurrentRunAttempt(source: String) -> Bool {
            guard let ownership = activeRunOwnership else { return false }
            guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
            recordRunAttemptEnded(ownership, source: source)
            return true
        }

        @discardableResult
        func endRunAttempt(ifCurrentAttemptID attemptID: UUID, source: String) -> Bool {
            guard let ownership = activeRunOwnership, ownership.attemptID == attemptID else { return false }
            return endRunAttempt(ifCurrent: ownership, source: source)
        }

        private func recordRunAttemptEnded(_ ownership: AgentRunOwnership, source: String) {
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.lifecycle.attempt.ended")
                AgentModePerfDiagnostics.increment("run.lifecycle.attempt.ended.source.\(source)")
                AgentModePerfDiagnostics.event(
                    "run.lifecycle.attemptEnded",
                    tabID: tabID,
                    fields: [
                        "source": source,
                        "attemptID": AgentModePerfDiagnostics.shortID(ownership.attemptID)
                    ]
                )
            #endif
        }

        private func recordRunProgressDiagnostic(
            _ result: AgentRunProgressAcceptance,
            kind: AgentRunLivenessSignalKind,
            stage: AgentRunLifecycleStage
        ) {
            #if DEBUG
                switch result {
                case .accepted:
                    if kind == .stageTransition {
                        AgentModePerfDiagnostics.increment("run.lifecycle.stage.\(stage.rawValue)", tabID: tabID)
                    }
                case let .rejected(reason):
                    AgentModePerfDiagnostics.increment("run.lifecycle.progress.rejected.\(reason.rawValue)", tabID: tabID)
                    AgentModePerfDiagnostics.event(
                        "run.lifecycle.progressRejected",
                        tabID: tabID,
                        fields: ["reason": reason.rawValue, "kind": kind.rawValue, "stage": stage.rawValue]
                    )
                }
            #endif
        }

        @discardableResult
        func setRunningStatus(_ text: String?, source: RunningStatusSource?) -> Bool {
            let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (normalized?.isEmpty == false) ? normalized : nil
            let normalizedSource = value == nil ? nil : source
            guard runningStatusText != value || runningStatusSource != normalizedSource else { return false }
            runningStatusText = value
            runningStatusSource = normalizedSource
            return true
        }

        @discardableResult
        func clearClaudeReasoningStatus(clearDisplayedStatus: Bool = true) -> Bool {
            claudeReasoningStatusBuffer = ""
            claudeReasoningStatusPendingText = nil
            claudeReasoningStatusFlushTask?.cancel()
            claudeReasoningStatusFlushTask = nil
            guard clearDisplayedStatus, runningStatusSource == .reasoning else { return false }
            return setRunningStatus(nil, source: nil)
        }

        var shouldSurfaceInteractionsInUI: Bool {
            true
        }

        var uiWaitingPrompt: String? {
            shouldSurfaceInteractionsInUI ? waitingPrompt : nil
        }

        var uiPendingAskUser: AgentAskUserPendingState? {
            shouldSurfaceInteractionsInUI ? pendingAskUser : nil
        }

        var uiPendingUserInputRequest: AgentRequestUserInputRequest? {
            shouldSurfaceInteractionsInUI ? pendingUserInputRequest : nil
        }

        var uiPendingApproval: AgentApprovalRequest? {
            shouldSurfaceInteractionsInUI ? pendingApproval : nil
        }

        var uiPendingPermissionsRequest: AgentPermissionsRequest? {
            shouldSurfaceInteractionsInUI ? pendingPermissionsRequest : nil
        }

        var uiPendingMCPElicitationRequest: AgentMCPElicitationRequest? {
            shouldSurfaceInteractionsInUI ? pendingMCPElicitationRequest : nil
        }

        var uiPendingApplyEditsReview: PendingApplyEditsReview? {
            shouldSurfaceInteractionsInUI ? pendingApplyEditsReview : nil
        }

        var uiPendingWorktreeMergeReview: PendingWorktreeMergeReview? {
            shouldSurfaceInteractionsInUI ? pendingWorktreeMergeReview : nil
        }

        struct ToolCorrelationScanResult {
            let indices: [Int]
            let scannedItemCount: Int

            var lastIndex: Int? {
                indices.last
            }
        }

        private enum ToolCorrelationBoundary: Equatable {
            case start
            case after(itemID: UUID, sequenceIndex: Int)
        }

        private struct ToolCorrelationIndexes: Equatable {
            var activeTurnBoundary: ToolCorrelationBoundary = .start
            var activeTurnStartIndex: Int = 0
            var itemIndicesByInvocationID: [UUID: Set<Int>] = [:]
            var itemIndicesBySignature: [String: Set<Int>] = [:]
            var pendingCallIndicesBySignature: [String: Set<Int>] = [:]
            var nilInvocationItemIndicesByName: [String: Set<Int>] = [:]
        }

        static func normalizedToolCorrelationName(_ toolName: String?) -> String {
            let normalized = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName ?? "")
            if !normalized.isEmpty {
                return normalized
            }
            return toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }

        static func canonicalToolInvocationSignature(toolName: String?, argsJSON: String?) -> String {
            let normalizedToolName = normalizedToolCorrelationName(toolName)
            let normalizedArgs: String = {
                guard let raw = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                      let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      JSONSerialization.isValidJSONObject(object),
                      let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      let canonical = String(data: canonicalData, encoding: .utf8)
                else {
                    return argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                return canonical
            }()
            return "\(normalizedToolName)|\(normalizedArgs)"
        }

        func indexedToolItemIndices(invocationID: UUID) -> [Int] {
            sortedValidToolItemIndices(toolCorrelationIndexes.itemIndicesByInvocationID[invocationID] ?? [])
        }

        func indexedToolItemIndices(signature: String, pendingCallsOnly: Bool = false) -> [Int] {
            let indices = pendingCallsOnly
                ? toolCorrelationIndexes.pendingCallIndicesBySignature[signature] ?? []
                : toolCorrelationIndexes.itemIndicesBySignature[signature] ?? []
            return sortedValidToolItemIndices(indices)
        }

        func indexedNilInvocationToolItemIndices(normalizedToolName: String) -> [Int] {
            sortedValidToolItemIndices(
                toolCorrelationIndexes.nilInvocationItemIndicesByName[normalizedToolName] ?? []
            )
        }

        func activeTurnToolItemIndices(
            where predicate: (AgentChatItem) -> Bool
        ) -> ToolCorrelationScanResult {
            var matches: [Int] = []
            var scannedItemCount = 0
            guard toolCorrelationIndexes.activeTurnStartIndex < items.endIndex else {
                return ToolCorrelationScanResult(indices: [], scannedItemCount: 0)
            }
            for index in stride(
                from: items.index(before: items.endIndex),
                through: toolCorrelationIndexes.activeTurnStartIndex,
                by: -1
            ) {
                scannedItemCount += 1
                if predicate(items[index]) {
                    matches.append(index)
                }
            }
            matches.reverse()
            return ToolCorrelationScanResult(indices: matches, scannedItemCount: scannedItemCount)
        }

        private func sortedValidToolItemIndices(_ indices: Set<Int>) -> [Int] {
            indices.lazy
                .filter { index in
                    self.items.indices.contains(index)
                        && index >= self.toolCorrelationIndexes.activeTurnStartIndex
                        && Self.isToolCorrelationItem(self.items[index])
                }
                .sorted()
        }

        private static func isToolCorrelationItem(_ item: AgentChatItem) -> Bool {
            item.kind == .toolCall || item.kind == .toolResult
        }

        private func syncNextSequenceIndexFromItems() {
            let maxSequenceIndex = items.map(\.sequenceIndex).max() ?? -1
            nextSequenceIndex = max(nextSequenceIndex, maxSequenceIndex + 1)
        }

        private enum SourceItemsDispatch {
            case silent
            case notify(AgentModeViewModel.SourceItemsMutation)
        }

        private func commitSourceItems(
            _ newItems: [AgentChatItem],
            dispatch: SourceItemsDispatch
        ) {
            suppressSourceItemsChanged = true
            items = newItems
            suppressSourceItemsChanged = false
            rebuildSourceItemDerivedState()
            sourceItemsRevision &+= 1
            derivedTranscriptSyncState = nil
            if case let .notify(mutation) = dispatch {
                onSourceItemsChanged?(self, mutation)
            }
        }

        private func rebuildSourceItemDerivedState() {
            syncNextSequenceIndexFromItems()
            liveItemIDs = Set(items.map(\.id))
            replaceEphemeralToolResultPayloadMap(
                AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(from: items),
                liveItemIDs: liveItemIDs
            )
            rebuildToolCorrelationIndexes()
            assertSourceItemDerivedStateIsConsistent()
        }

        private func rebuildToolCorrelationIndexes() {
            let activeTurnBoundaryOverride = runState.isActive ? toolCorrelationIndexes.activeTurnBoundary : nil
            toolCorrelationIndexes = Self.makeToolCorrelationIndexes(
                for: items,
                activeTurnBoundaryOverride: activeTurnBoundaryOverride
            )
        }

        private static func makeToolCorrelationIndexes(
            for items: [AgentChatItem],
            activeTurnBoundaryOverride: ToolCorrelationBoundary? = nil
        ) -> ToolCorrelationIndexes {
            var indexes = ToolCorrelationIndexes()
            let boundary: ToolCorrelationBoundary = if let activeTurnBoundaryOverride {
                activeTurnBoundaryOverride
            } else if let lastUserIndex = items.lastIndex(where: { $0.kind == .user }) {
                .after(
                    itemID: items[lastUserIndex].id,
                    sequenceIndex: items[lastUserIndex].sequenceIndex
                )
            } else {
                .start
            }
            indexes.activeTurnBoundary = boundary
            indexes.activeTurnStartIndex = resolvedToolCorrelationStartIndex(for: items, boundary: boundary)
            guard indexes.activeTurnStartIndex < items.endIndex else { return indexes }
            for index in indexes.activeTurnStartIndex ..< items.endIndex {
                addToolCorrelationItem(items[index], at: index, to: &indexes)
            }
            return indexes
        }

        private static func resolvedToolCorrelationStartIndex(
            for items: [AgentChatItem],
            boundary: ToolCorrelationBoundary
        ) -> Int {
            switch boundary {
            case .start:
                return items.startIndex
            case let .after(itemID, sequenceIndex):
                if let anchorIndex = items.firstIndex(where: { $0.id == itemID }) {
                    return items.index(after: anchorIndex)
                }
                return items.firstIndex(where: { $0.sequenceIndex > sequenceIndex }) ?? items.endIndex
            }
        }

        private static func addToolCorrelationItem(
            _ item: AgentChatItem,
            at index: Int,
            to indexes: inout ToolCorrelationIndexes
        ) {
            guard isToolCorrelationItem(item), index >= indexes.activeTurnStartIndex else { return }
            if let invocationID = item.toolInvocationID {
                indexes.itemIndicesByInvocationID[invocationID, default: []].insert(index)
            }
            let signature = canonicalToolInvocationSignature(
                toolName: item.toolName,
                argsJSON: item.toolArgsJSON
            )
            indexes.itemIndicesBySignature[signature, default: []].insert(index)
            if item.kind == .toolCall {
                indexes.pendingCallIndicesBySignature[signature, default: []].insert(index)
            }
            if item.toolInvocationID == nil {
                let normalizedName = normalizedToolCorrelationName(item.toolName)
                indexes.nilInvocationItemIndicesByName[normalizedName, default: []].insert(index)
            }
        }

        private static func removeToolCorrelationItem(
            _ item: AgentChatItem,
            at index: Int,
            from indexes: inout ToolCorrelationIndexes
        ) {
            guard isToolCorrelationItem(item), index >= indexes.activeTurnStartIndex else { return }
            if let invocationID = item.toolInvocationID {
                remove(index, from: &indexes.itemIndicesByInvocationID, key: invocationID)
            }
            let signature = canonicalToolInvocationSignature(
                toolName: item.toolName,
                argsJSON: item.toolArgsJSON
            )
            remove(index, from: &indexes.itemIndicesBySignature, key: signature)
            if item.kind == .toolCall {
                remove(index, from: &indexes.pendingCallIndicesBySignature, key: signature)
            }
            if item.toolInvocationID == nil {
                let normalizedName = normalizedToolCorrelationName(item.toolName)
                remove(index, from: &indexes.nilInvocationItemIndicesByName, key: normalizedName)
            }
        }

        private static func remove<Key: Hashable>(
            _ index: Int,
            from map: inout [Key: Set<Int>],
            key: Key
        ) {
            guard var indices = map[key] else { return }
            indices.remove(index)
            map[key] = indices.isEmpty ? nil : indices
        }

        private func updateToolCorrelationIndexes(
            previousItem: AgentChatItem,
            updatedItem: AgentChatItem,
            at index: Int
        ) {
            guard previousItem.kind != .user, updatedItem.kind != .user else {
                rebuildToolCorrelationIndexes()
                return
            }
            Self.removeToolCorrelationItem(previousItem, at: index, from: &toolCorrelationIndexes)
            Self.addToolCorrelationItem(updatedItem, at: index, to: &toolCorrelationIndexes)
        }

        private func appendToolCorrelationIndexes(for item: AgentChatItem, at index: Int) {
            if item.kind == .user {
                guard !runState.isActive else { return }
                toolCorrelationIndexes = ToolCorrelationIndexes(
                    activeTurnBoundary: .after(itemID: item.id, sequenceIndex: item.sequenceIndex),
                    activeTurnStartIndex: index + 1
                )
                return
            }
            Self.addToolCorrelationItem(item, at: index, to: &toolCorrelationIndexes)
        }

        private func reconcileIncrementalEphemeralPayload(
            previousItem: AgentChatItem?,
            updatedItem: AgentChatItem?
        ) {
            if let previousItem, previousItem.id != updatedItem?.id {
                liveItemIDs.remove(previousItem.id)
                setEphemeralToolResultPayload(nil, for: previousItem.id)
            }
            guard let updatedItem else { return }
            liveItemIDs.insert(updatedItem.id)
            refreshEphemeralPayload(for: updatedItem)
        }

        private func refreshEphemeralPayload(for item: AgentChatItem) {
            if let retainedPayload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item) {
                setEphemeralToolResultPayload(retainedPayload, for: item.id)
            } else {
                setEphemeralToolResultPayload(nil, for: item.id)
            }
        }

        func replaceEphemeralToolResultPayloadMap(_ payloadByItemID: [UUID: String], liveItemIDs: Set<UUID>) {
            let filteredPayloadByItemID = payloadByItemID.filter { itemID, payload in
                liveItemIDs.contains(itemID) && !payload.isEmpty
            }
            let previousPayloadByItemID = ephemeralToolResultPayloadByItemID
            ephemeralToolResultPayloadByItemID = filteredPayloadByItemID
            for itemID in Set(previousPayloadByItemID.keys).union(filteredPayloadByItemID.keys) {
                guard previousPayloadByItemID[itemID] != filteredPayloadByItemID[itemID] else { continue }
                if filteredPayloadByItemID[itemID] != nil {
                    ephemeralToolResultPayloadRevisionByItemID[itemID] = consumeNextEphemeralToolResultPayloadRevision()
                } else {
                    ephemeralToolResultPayloadRevisionByItemID.removeValue(forKey: itemID)
                }
            }
            pruneEphemeralToolResultPayloadRevisions(liveItemIDs: liveItemIDs)
        }

        private func setEphemeralToolResultPayload(_ payload: String?, for itemID: UUID) {
            let retainedPayload = payload.flatMap { $0.isEmpty ? nil : $0 }
            let previousPayload = ephemeralToolResultPayloadByItemID[itemID]
            guard previousPayload != retainedPayload else { return }
            if let retainedPayload {
                ephemeralToolResultPayloadByItemID[itemID] = retainedPayload
                ephemeralToolResultPayloadRevisionByItemID[itemID] = consumeNextEphemeralToolResultPayloadRevision()
            } else {
                ephemeralToolResultPayloadByItemID.removeValue(forKey: itemID)
                ephemeralToolResultPayloadRevisionByItemID.removeValue(forKey: itemID)
            }
        }

        private func consumeNextEphemeralToolResultPayloadRevision() -> Int {
            let revision = nextEphemeralToolResultPayloadRevision
            nextEphemeralToolResultPayloadRevision &+= 1
            return revision
        }

        private func pruneEphemeralToolResultPayloadRevisions(liveItemIDs: Set<UUID>) {
            ephemeralToolResultPayloadRevisionByItemID = ephemeralToolResultPayloadRevisionByItemID.filter {
                liveItemIDs.contains($0.key) && ephemeralToolResultPayloadByItemID[$0.key] != nil
            }
        }

        private func finishIncrementalSourceItemsMutation(
            _ mutation: AgentModeViewModel.SourceItemsMutation
        ) {
            sourceItemsRevision &+= 1
            derivedTranscriptSyncState = nil
            onSourceItemsChanged?(self, mutation)
        }

        #if DEBUG
            func testAssertSourceItemDerivedStateIsConsistent() {
                assertSourceItemDerivedStateIsConsistent()
            }
        #endif

        private func assertSourceItemDerivedStateIsConsistent(
            file: StaticString = #fileID,
            line: UInt = #line
        ) {
            #if DEBUG
                assert(liveItemIDs == Set(items.map(\.id)), "live item ID index desynchronized", file: file, line: line)
                assert(
                    ephemeralToolResultPayloadByItemID.keys.allSatisfy { liveItemIDs.contains($0) },
                    "ephemeral payload map contains non-live item IDs",
                    file: file,
                    line: line
                )
                assert(
                    toolCorrelationIndexes == Self.makeToolCorrelationIndexes(
                        for: items,
                        activeTurnBoundaryOverride: runState.isActive ? toolCorrelationIndexes.activeTurnBoundary : nil
                    ),
                    "tool correlation index desynchronized",
                    file: file,
                    line: line
                )
            #endif
        }

        @discardableResult
        func mutateItemsBatch(
            mutation: AgentModeViewModel.SourceItemsMutation = .structural,
            touchActivity: Bool = true,
            _ body: (inout [AgentChatItem]) -> Void
        ) -> Bool {
            let previousItems = items
            var updatedItems = previousItems
            body(&updatedItems)
            guard updatedItems != previousItems else { return false }
            commitSourceItems(updatedItems, dispatch: .notify(mutation))
            if touchActivity {
                lastActivityAt = Date()
            }
            isDirty = true
            return true
        }

        enum SilentItemReplacementReason: String {
            case persistedSessionHydration
            case pendingToolFinalizationRepair
            case retentionCompaction
            case codexCommandStatusReconciliation
            case routeActivation
            case clearedChat
            case stressHarnessReset
            case testOverride
        }

        func setItemsSilently(_ items: [AgentChatItem], reason: SilentItemReplacementReason) {
            #if DEBUG
                if AgentTranscriptDebugInstrumentation.isEnabled {
                    AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler?(.init(
                        reason: reason.rawValue,
                        previousItemCount: self.items.count,
                        newItemCount: items.count,
                        isEqual: self.items == items,
                        previousSignature: AgentTranscriptDebugInstrumentation.itemIdentitySignature(self.items),
                        newSignature: AgentTranscriptDebugInstrumentation.itemIdentitySignature(items)
                    ))
                }
            #endif
            commitSourceItems(items, dispatch: .silent)
            pendingSourceItemsMutationSummary = nil
            pendingDerivedTranscriptRefreshReason = nil
            derivedTranscriptRefreshGeneration &+= 1
            derivedTranscriptRefreshTask?.cancel()
            derivedTranscriptRefreshTask = nil
        }

        @discardableResult
        func replaceItemSilentlyForRetentionCompaction(
            at index: Int,
            with compactedItem: AgentChatItem,
            retainedRawPayload: String
        ) -> Bool {
            guard items.indices.contains(index) else { return false }
            let previousItem = items[index]
            guard previousItem.id == compactedItem.id,
                  previousItem != compactedItem,
                  ephemeralToolResultPayloadByItemID[previousItem.id] == retainedRawPayload
            else {
                return false
            }

            suppressSourceItemsChanged = true
            items[index] = compactedItem
            suppressSourceItemsChanged = false
            nextSequenceIndex = max(nextSequenceIndex, compactedItem.sequenceIndex + 1)
            updateToolCorrelationIndexes(
                previousItem: previousItem,
                updatedItem: compactedItem,
                at: index
            )
            sourceItemsRevision &+= 1
            derivedTranscriptSyncState = nil
            #if DEBUG
                test_incrementalRetentionCompactionCount += 1
            #endif
            assertSourceItemDerivedStateIsConsistent()
            return true
        }

        /// Compact any summary-only tool-result items in place and align
        /// `ephemeralToolResultPayloadByItemID` with the resulting live items.
        ///
        /// Used by captured-transcript apply paths so that when a stale captured
        /// presentation cannot be layered on top of newer live source items the
        /// live `toolResultJSON` is still reduced to its sanitized form (where
        /// policy requires it), the payload map only contains entries keyed by
        /// live item IDs, and stale payload entries for removed items are
        /// pruned. Mirrors the ephemeral-payload invariants that normal
        /// `TabSession` mutation helpers preserve via `reconcileEphemeralPayloadMap`.
        func compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap() {
            var alignedItems: [AgentChatItem] = []
            alignedItems.reserveCapacity(items.count)
            var alignedMap: [UUID: String] = [:]
            var itemsDidMutate = false
            for item in items {
                guard
                    item.kind == .toolResult,
                    let sanitized = AgentToolResultPersistencePolicy.sanitizedToolResult(for: item),
                    sanitized.shouldRetainEphemeralRawPayload
                else {
                    alignedItems.append(item)
                    continue
                }
                let freshRetainedPayload: String? = {
                    let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let persisted = sanitized.resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !raw.isEmpty,
                          raw != persisted,
                          !AgentTranscriptToolNormalizer.isSummaryOnly(raw: raw)
                    else {
                        return nil
                    }
                    return raw
                }()
                let existingRetainedPayload: String? = {
                    let payload = ephemeralToolResultPayloadByItemID[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !payload.isEmpty else { return nil }
                    return payload
                }()
                var compactedItem = item
                if compactedItem.toolResultJSON != sanitized.resultJSON {
                    compactedItem.toolResultJSON = sanitized.resultJSON
                    itemsDidMutate = true
                }
                if compactedItem.text != sanitized.text {
                    compactedItem.text = sanitized.text
                    itemsDidMutate = true
                }
                if compactedItem.toolIsError != sanitized.toolIsError {
                    compactedItem.toolIsError = sanitized.toolIsError
                    itemsDidMutate = true
                }
                alignedItems.append(compactedItem)
                if let retainedPayload = freshRetainedPayload ?? existingRetainedPayload {
                    alignedMap[compactedItem.id] = retainedPayload
                }
            }
            if itemsDidMutate {
                sourceItemsRevision &+= 1
                derivedTranscriptSyncState = nil
                suppressSourceItemsChanged = true
                items = alignedItems
                suppressSourceItemsChanged = false
                syncNextSequenceIndexFromItems()
                liveItemIDs = Set(alignedItems.map(\.id))
                rebuildToolCorrelationIndexes()
            }
            replaceEphemeralToolResultPayloadMap(alignedMap, liveItemIDs: liveItemIDs)
            assertSourceItemDerivedStateIsConsistent()
        }

        func clearDerivedTranscriptCaches() {
            transcript = .empty
            baseTranscriptProjection = .empty
            fullTranscriptProjection = .empty
            workingTranscriptProjection = .empty
            transcriptProjection = .empty
            turnProjectionCaches = [:]
            archivedTranscriptSnapshot = .empty
            isCompressedHistoryRevealed = false
            transcriptProjectionProtection = .none
            transcriptCanonicalVisibleRowCount = 0
            transcriptProjectionCounts = .zero
            transcriptAnalyticsSnapshot = .init()
            transcriptPerformanceSnapshot = .empty
            rawToolResultPayloadRenderRevision = 0
            derivedTranscriptSyncState = nil
        }

        func replaceItems(_ items: [AgentChatItem]) {
            setItemsSilently(items, reason: .testOverride)
            pendingTurnRuntimeAnchors.removeAll()
            agentMessageRuntimeFootersByItemID.removeAll()
            pendingSourceItemsMutationSummary = nil
            onSourceItemsChanged?(self, .replaceAll)
            lastActivityAt = Date()
            isDirty = true
        }

        func appendItem(_ item: AgentChatItem) {
            var newItem = item
            newItem.sequenceIndex = nextSequenceIndex
            nextSequenceIndex += 1
            let appendedIndex = items.count
            suppressSourceItemsChanged = true
            items.append(newItem)
            suppressSourceItemsChanged = false
            reconcileIncrementalEphemeralPayload(previousItem: nil, updatedItem: newItem)
            appendToolCorrelationIndexes(for: newItem, at: appendedIndex)
            finishIncrementalSourceItemsMutation(.append(index: appendedIndex, itemKind: newItem.kind))
            if newItem.kind == .user {
                hasSentFirstMessage = true
                lastUserMessageAt = newItem.timestamp
            }
            lastActivityAt = Date()
            isDirty = true
        }

        func replaceItem(at index: Int, with updatedItem: AgentChatItem) {
            guard items.indices.contains(index) else { return }
            let previousItem = items[index]
            guard updatedItem != previousItem else { return }
            suppressSourceItemsChanged = true
            items[index] = updatedItem
            suppressSourceItemsChanged = false
            nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
            reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
            updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
            finishIncrementalSourceItemsMutation(
                .replace(index: index, previousKind: previousItem.kind, currentKind: updatedItem.kind)
            )
            lastActivityAt = Date()
            isDirty = true
        }

        func mutateItem(at index: Int, _ mutate: (inout AgentChatItem) -> Void) {
            guard items.indices.contains(index) else { return }
            let previousItem = items[index]
            var updatedItem = previousItem
            mutate(&updatedItem)
            guard updatedItem != previousItem else { return }
            suppressSourceItemsChanged = true
            items[index] = updatedItem
            suppressSourceItemsChanged = false
            nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
            reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
            updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
            finishIncrementalSourceItemsMutation(.mutate(index: index, itemKind: updatedItem.kind))
            lastActivityAt = Date()
            isDirty = true
        }

        @discardableResult
        func removeItem(at index: Int) -> AgentChatItem? {
            guard items.indices.contains(index) else { return nil }
            let removed = items[index]
            suppressSourceItemsChanged = true
            items.remove(at: index)
            suppressSourceItemsChanged = false
            reconcileIncrementalEphemeralPayload(previousItem: removed, updatedItem: nil)
            rebuildToolCorrelationIndexes()
            finishIncrementalSourceItemsMutation(.remove(index: index, itemKind: removed.kind))
            lastActivityAt = Date()
            isDirty = true
            return removed
        }

        func updateLastItem(_ mutate: (inout AgentChatItem) -> Void) {
            guard !items.isEmpty else { return }
            let index = items.count - 1
            let previousItem = items[index]
            var updatedItem = previousItem
            mutate(&updatedItem)
            guard updatedItem != previousItem else { return }
            suppressSourceItemsChanged = true
            items[index] = updatedItem
            suppressSourceItemsChanged = false
            nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
            reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
            updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
            finishIncrementalSourceItemsMutation(
                .replace(index: index, previousKind: previousItem.kind, currentKind: updatedItem.kind)
            )
            lastActivityAt = Date()
            isDirty = true
        }

        func bashLiveExecution(for transcriptItemID: UUID) -> BashLiveExecutionState? {
            guard let key = bashLiveExecutionKeyByTranscriptItemID[transcriptItemID] else { return nil }
            return bashLiveExecutionByKey[key]
        }

        func setBashLiveExecution(_ state: BashLiveExecutionState) {
            bashLiveExecutionByKey[state.executionKey] = state
            bashLiveExecutionKeyByTranscriptItemID[state.transcriptItemID] = state.executionKey
            lastActivityAt = Date()
        }

        @discardableResult
        func removeBashLiveExecution(forKey key: String) -> BashLiveExecutionState? {
            guard let removed = bashLiveExecutionByKey.removeValue(forKey: key) else { return nil }
            bashLiveExecutionKeyByTranscriptItemID.removeValue(forKey: removed.transcriptItemID)
            lastActivityAt = Date()
            return removed
        }

        @discardableResult
        func removeBashLiveExecution(forTranscriptItemID transcriptItemID: UUID) -> BashLiveExecutionState? {
            guard let key = bashLiveExecutionKeyByTranscriptItemID[transcriptItemID] else { return nil }
            return removeBashLiveExecution(forKey: key)
        }

        func clearBashLiveExecutions() {
            guard !bashLiveExecutionByKey.isEmpty || !bashLiveExecutionKeyByTranscriptItemID.isEmpty else { return }
            bashLiveExecutionByKey.removeAll()
            bashLiveExecutionKeyByTranscriptItemID.removeAll()
            lastActivityAt = Date()
        }
    }
}
