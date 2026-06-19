import Combine
import CryptoKit
import Foundation
import MCP
import SwiftUI

struct AgentContextUsage: Codable, Equatable {
    var modelContextWindow: Int?
    var lastTotalTokens: Int?
    var totalTotalTokens: Int?
}

// MARK: - Agent Mode View Model

/// View model for Agent mode - manages per-tab agent chat sessions with long-running agent interactions
@MainActor
final class AgentModeViewModel: ObservableObject {
    @TaskLocal private static var mcpRunEpochTransitionToken: UUID?

    nonisolated static func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableSteeringDebugLogging") else { return }
            print(message())
        #endif
    }

    nonisolated static func logCodexDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableCodexDebugLogging") else { return }
            print(message())
        #endif
    }

    private static let taggedFileTrailingTrimSet = CharacterSet(charactersIn: ").,;:!?]}")
    private static let taggedFileTerminatingScalars = CharacterSet.whitespacesAndNewlines
    private static let taggedFileContentsTokenBudget = 12000
    private static let taggedFileContentsMaxFiles = 5
    private static let slashSkillNameScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    private static let slashSkillSuggestionLimit = 6

    typealias CodexControllerFactory = (
        _ runID: UUID,
        _ tabID: UUID,
        _ windowID: Int,
        _ workspacePath: String?,
        _ permissionProfile: AgentPermissionProfile,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> any CodexSessionControlling
    typealias CodexControllerFactoryWithComputerUse = CodexAgentModeCoordinator.CodexControllerFactory
    typealias HeadlessProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) -> HeadlessAgentProvider
    typealias ACPProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
    typealias ACPControllerFactory = (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController
    typealias ConnectionPolicyInstaller = (
        _ clientName: String,
        _ windowID: Int,
        _ restrictedTools: Set<String>,
        _ oneShot: Bool,
        _ reason: String?,
        _ ttl: TimeInterval,
        _ tabID: UUID?,
        _ runID: UUID?,
        _ additionalTools: Set<String>?,
        _ purpose: MCPRunPurpose,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ allowsAgentExternalControlTools: Bool,
        _ requiresExpectedAgentPID: Bool
    ) async -> Void
    typealias MCPServerEnabler = () async -> Void
    typealias MCPRunRoutingCleaner = (_ runID: UUID, _ windowID: Int, _ reason: String) async -> Void
    typealias MCPRunToolCanceller = (_ runID: UUID, _ reason: String?) -> Int
    typealias CodexActiveToolQuery = (_ runID: UUID) -> Bool
    typealias CodexAgentRunWaitQuery = (_ runID: UUID) -> Bool
    typealias CodexAgentRunWaitDrain = @MainActor (_ runID: UUID, _ source: String) async -> Bool

    // MARK: - Published Session Proxies

    @Published private(set) var activeTranscriptPresentation: AgentTranscriptPresentationSnapshot = .empty {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncTranscriptUIState()
        }
    }

    @Published private(set) var activeTranscriptFollowBindingState: ActiveTranscriptFollowBindingState = .init() {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncTranscriptUIState()
        }
    }

    @Published private(set) var activeSessionLoadInProgressTabID: UUID? {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncTranscriptUIState()
        }
    }

    @Published private(set) var activeBashLiveExecutionByItemID: [UUID: BashLiveExecutionState] = [:] {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncTranscriptUIState()
        }
    }

    private var sessionActivationGeneration: Int = 0
    private var workspaceSwitchInFlight = false

    /// Working-thread rows for the active tab. This is the bounded equilibrium view.
    var items: [AgentChatItem] {
        activeTranscriptPresentation.workingRows
    }

    /// Currently visible rendered transcript rows for the active tab.
    var transcriptItems: [AgentChatItem] {
        activeTranscriptPresentation.visibleRows
    }

    /// Structured render blocks for the active tab.
    var visibleTranscriptBlocks: [AgentTranscriptRenderBlock] {
        activeTranscriptPresentation.visibleBlocks
    }

    var workingTranscriptBlocks: [AgentTranscriptRenderBlock] {
        activeTranscriptPresentation.workingBlocks
    }

    var activeArchivedHistoryState: AgentArchivedHistoryState {
        activeTranscriptPresentation.archivedHistoryState
    }

    var activeCompressedHistoryRevealed: Bool {
        activeTranscriptPresentation.isCompressedHistoryRevealed
    }

    var activeTranscriptRowAnchorIndex: [UUID: AgentTranscriptAnchor] {
        activeTranscriptPresentation.rowAnchorIndex
    }

    var activeTranscriptAnchorBlockIndex: [AgentTranscriptAnchor: String] {
        activeTranscriptPresentation.anchorBlockIndex
    }

    var activeTranscriptPresentationRevision: Int {
        activeTranscriptPresentation.revision
    }

    var activeTranscriptPerformanceSnapshot: AgentTranscriptPerformanceSnapshot {
        activeTranscriptPresentation.performanceSnapshot
    }

    var activeSessionBindingsAreHydrated: Bool {
        isActiveTranscriptPresentationHydrated(for: currentTabID)
    }

    /// Whether transcript rendering is currently hiding older compacted turns behind the archive reveal.
    var isTranscriptWindowCappedWhileActive: Bool {
        activeTranscriptPresentation.isWindowCappedWhileActive
    }

    /// Run state for the active tab
    @Published var runState: AgentSessionRunState = .idle {
        didSet {
            guard runState != oldValue else { return }
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
            syncSidebarUIState(refresh: true, reason: .runState)
        }
    }

    @Published var runningStatusText: String? = nil {
        didSet {
            guard runningStatusText != oldValue else { return }
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var activeAgentRunStartedAt: Date? = nil {
        didSet {
            guard activeAgentRunStartedAt != oldValue else { return }
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    /// Whether agent is actively producing output in the active tab
    var isAgentBusy: Bool {
        runState == .running
    }

    /// Whether agent is waiting for the next user instruction
    var isWaitingForInstruction: Bool {
        runState == .waitingForUser
    }

    /// Prompt shown while waiting
    @Published var waitingPrompt: String? = nil {
        didSet {
            guard waitingPrompt != oldValue else { return }
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    /// Pending structured ask_user interaction from the agent
    @Published var pendingAskUser: AgentAskUserPendingState? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var pendingApproval: AgentApprovalRequest? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var pendingPermissionsRequest: AgentPermissionsRequest? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var pendingMCPElicitationRequest: AgentMCPElicitationRequest? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var pendingApplyEditsReview: PendingApplyEditsReview? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var pendingWorktreeMergeReview: PendingWorktreeMergeReview? = nil {
        didSet {
            guard !isActiveUISyncSuppressed else { return }
            syncRunInteractionUIState()
        }
    }

    @Published var autoEditEnabled: Bool = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
    @Published private(set) var activePermissionChromeState: ActivePermissionChromeState = .userConfigured
    @Published var activeProviderControlsBinding: AgentProviderControlsBinding? = nil
    @Published var autoEditPermissionGuidance: AutoEditPermissionGuidance? = nil

    /// Context usage for the active tab
    @Published var contextUsage: AgentContextUsage? = nil {
        didSet {
            guard contextUsage != oldValue else { return }
            guard !isActiveUISyncSuppressed else { return }
            syncRuntimeMetricsUIState()
        }
    }

    @Published var contextUsageSnapshot: ContextUsageSnapshot? = nil
    @Published var pendingImageAttachments: [AgentImageAttachment] = []
    @Published var pendingTaggedFileAttachments: [AgentTaggedFileAttachment] = []
    @Published var draftRestorationEvent: DraftRestorationEvent? = nil
    @Published private(set) var codexDynamicModels: [CodexAppServerClient.RemoteModel] = []
    @Published private(set) var acpDynamicModelRevision: Int = 0
    @Published private(set) var availableAgents: [AgentProviderKind] = AgentModelCatalog.selectableAgents(availability: .none)

    /// Selected workflow for the active tab
    @Published var selectedWorkflow: AgentWorkflowDefinition? = nil

    /// When true, the first message in a new chat will ask the agent to interview
    /// the user with 2–3 clarifying questions before starting work.
    @Published var interviewFirst: Bool = false {
        didSet {
            guard interviewFirst != oldValue else { return }
            syncStatusPillsUIState()
        }
    }

    private static let lastUsedAgentKey = "agentMode.lastUsedAgent"
    private static let lastUsedModelsByAgentKey = "agentMode.lastUsedModelsByAgent"

    /// Selected agent kind
    @Published var selectedAgent: AgentProviderKind = .claudeCode {
        didSet {
            guard selectedAgent != oldValue, !isRestoringState else { return }
            if let session = activeSession,
               !canSelectAgent(selectedAgent, for: session)
            {
                isRestoringState = true
                selectedAgent = session.selectedAgent
                selectedModelRaw = session.selectedModelRaw
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                isRestoringState = false
                return
            }
            if usesProductionAgentDefaultsAndModelPolling {
                UserDefaults.standard.set(selectedAgent.rawValue, forKey: Self.lastUsedAgentKey)
            }
            if let session = activeSession {
                let previousAgent = session.selectedAgent
                if previousAgent != selectedAgent {
                    codexCoordinator.handleProviderSwitch(from: previousAgent, to: selectedAgent, session: session)
                    claudeCoordinator.handleProviderIdentityTransitionSync(
                        session: session,
                        from: previousAgent,
                        to: selectedAgent
                    )
                }
                session.selectedAgent = selectedAgent
                if !isModelRawValid(selectedModelRaw, for: selectedAgent) {
                    selectedModelRaw = defaultModelRaw(for: selectedAgent)
                }
                codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: false)
                updatePermissionBindingState(from: session)
                scheduleSave(for: session.tabID)
            }
            persistLastUsedModelIfNeeded(agent: selectedAgent, modelRaw: selectedModelRaw)
            refreshAutoEditPermissionGuidanceForActiveSession()
            updateDynamicModelPolling()
            syncAllActiveUIState()
        }
    }

    /// Selected model
    @Published var selectedModelRaw: String = AgentModel.defaultModel.rawValue {
        didSet {
            guard selectedModelRaw != oldValue, !isRestoringState else { return }
            if let session = activeSession,
               !canSelectModel(selectedModelRaw, for: session)
            {
                isRestoringState = true
                selectedModelRaw = session.selectedModelRaw
                isRestoringState = false
                syncComposerUIState()
                syncRuntimeMetricsUIState()
                syncRunInteractionUIState()
                return
            }
            if !isModelRawValid(selectedModelRaw, for: selectedAgent) {
                isRestoringState = true
                selectedModelRaw = defaultModelRaw(for: selectedAgent)
                isRestoringState = false
            }
            // Persist last-used model for this agent so it survives app reboot
            persistLastUsedModelIfNeeded(agent: selectedAgent, modelRaw: selectedModelRaw)
            if let session = activeSession {
                session.selectedModelRaw = selectedModelRaw
                codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: false)
                updatePermissionBindingState(from: session)
                scheduleSave(for: session.tabID)
                claudeCoordinator.scheduleApplyCurrentClaudeModelAndEffortIfPossible(
                    for: session,
                    reason: "selected_model_changed"
                )
            }
            syncComposerUIState()
            syncRuntimeMetricsUIState()
            syncRunInteractionUIState()
        }
    }

    @Published var selectedReasoningEffortRaw: String? = nil {
        didSet {
            guard selectedReasoningEffortRaw != oldValue, !isRestoringState else { return }
            defer {
                syncComposerUIState()
                syncRunInteractionUIState()
            }
            guard let session = activeSession else { return }
            session.selectedReasoningEffortRaw = selectedReasoningEffortRaw
            codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)
            if session.selectedAgent == .codexExec,
               let effort = CodexReasoningEffort.parse(session.selectedReasoningEffortRaw)
            {
                CodexAgentToolPreferences.setLastUsedReasoningEffort(
                    effort,
                    forModelRaw: session.selectedModelRaw
                )
                codexCoordinator.recordLastUsedReasoningEffort(effort, forModelRaw: session.selectedModelRaw)
            }
            scheduleSave(for: session.tabID)
        }
    }

    var selectedModel: AgentModel {
        get { AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel }
        set { selectedModelRaw = newValue.rawValue }
    }

    var selectedModelDisplayName: String {
        inputBarModelDisplayName(rawModel: selectedModelRaw, agentKind: selectedAgent)
    }

    var selectedReasoningEffortDisplayName: String {
        codexCoordinator.selectedReasoningEffortDisplayName(raw: selectedReasoningEffortRaw)
    }

    var isProviderPickerLockedForCurrentTab: Bool {
        isProviderPickerLocked(tabID: currentTabID)
    }

    func isProviderPickerLocked(tabID: UUID?) -> Bool {
        guard let tabID,
              let session = sessions[tabID] else { return false }
        return session.isProviderSelectionLocked
    }

    func canSelectAgentInCurrentChat(_ candidate: AgentProviderKind) -> Bool {
        guard let session = activeSession else { return true }
        return canSelectAgent(candidate, for: session)
    }

    var lockedAgentSelectionMessage: String? {
        lockedAgentSelectionMessage(for: activeSession)
    }

    func lockedAgentSelectionMessage(tabID: UUID?) -> String? {
        guard let tabID else { return nil }
        return lockedAgentSelectionMessage(for: sessions[tabID])
    }

    private func lockedAgentSelectionMessage(for session: TabSession?) -> String? {
        guard let session, session.isProviderSelectionLocked else { return nil }
        if session.selectedAgent.usesClaudeNativeRuntime {
            return "Fork (⑂) or start a new chat to switch agent kinds."
        }
        return "Fork (⑂) or start a new chat to switch from \(session.selectedAgent.displayName)."
    }

    private func canSelectModel(_ rawModel: String, for session: TabSession) -> Bool {
        true
    }

    private func canSelectAgent(_ candidate: AgentProviderKind, for session: TabSession) -> Bool {
        guard session.isProviderSelectionLocked else { return true }
        if candidate == session.selectedAgent {
            return true
        }
        if session.selectedAgent.usesClaudeNativeRuntime, candidate.usesClaudeNativeRuntime {
            return true
        }
        return false
    }

    // MARK: - Session Management

    struct SessionIndexOwner: Equatable {
        let workspaceID: UUID?
        let activationEpoch: UInt64
    }

    private struct SessionIndexRefreshToken: Equatable {
        let owner: SessionIndexOwner
        let generation: UInt64
    }

    typealias SidebarPrioritizedIndexBuilder = @Sendable (
        AgentSessionSidebarBuildRequest
    ) async throws -> AgentSessionSidebarBuildResult
    typealias SidebarIndexStreamBuilder = @Sendable (
        AgentSessionSidebarBuildRequest,
        Int
    ) async -> AsyncThrowingStream<AgentSessionSidebarBuildBatch, Error>

    @Published private(set) var sessions: [UUID: TabSession] = [:] {
        didSet {
            syncSidebarUIState(refresh: true, reason: .sessionList)
            scheduleSidebarAutoArchiveIfReady(reason: .liveSessionSetChanged)
        }
    }

    @Published private(set) var sessionIndex: [UUID: AgentSessionIndexEntry] = [:] {
        didSet {
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            scheduleSidebarAutoArchiveIfReady(reason: .sessionIndexChanged)
        }
    }

    /// Cached last-user-message timestamps for tabs (used for list ordering before sessions load)
    @Published private(set) var sessionListSortDates: [UUID: Date] = [:] {
        didSet { syncSidebarUIState(refresh: true, reason: .sortDates) }
    }

    @Published private(set) var sessionListCacheReady: Bool = false {
        didSet {
            guard sessionListCacheReady != oldValue else { return }
            syncSidebarUIState(refresh: true, reason: .sessionList)
        }
    }

    static let sessionSidebarPageSize = 15
    @Published var sessionSidebarSearchText: String = "" {
        didSet {
            guard sessionSidebarSearchText != oldValue else { return }
            guard sessionSidebarVisibleSessionCount != Self.sessionSidebarPageSize else {
                syncSidebarUIState()
                return
            }
            sessionSidebarVisibleSessionCount = Self.sessionSidebarPageSize
        }
    }

    @Published var sessionSidebarVisibleSessionCount: Int = AgentModeViewModel.sessionSidebarPageSize {
        didSet {
            guard sessionSidebarVisibleSessionCount != oldValue else { return }
            syncSidebarUIState()
        }
    }

    /// Set of tab IDs with active agent runs
    @Published private(set) var tabsWithActiveAgentRun: Set<UUID> = [] {
        didSet {
            syncSidebarUIState(refresh: true, reason: .runState)
            scheduleSidebarAutoArchiveIfReady(reason: .runProtectionChanged)
        }
    }

    /// Set of tab IDs currently under MCP control. Published so sidebar/composer
    /// views can reactively show MCP indicators without observing individual TabSession fields.
    @Published private(set) var mcpControlledTabIDs: Set<UUID> = [] {
        didSet {
            syncSidebarUIState(refresh: true, reason: .mcpControl)
            syncComposerUIState()
            scheduleSidebarAutoArchiveIfReady(reason: .mcpProtectionChanged)
        }
    }

    let ui = AgentModeUIFacades()

    // MARK: - Dependencies

    private let windowID: Int
    weak var promptManager: PromptViewModel?
    private let workspaceFileContextStore: WorkspaceFileContextStore?
    weak var workspaceManager: WorkspaceManagerViewModel?
    private weak var mcpServer: MCPServerViewModel?
    private let dataService = AgentSessionDataService.shared
    private var sidebarPrioritizedIndexBuilder: SidebarPrioritizedIndexBuilder = { request in
        try await AgentSessionDataService.shared.buildPrioritizedSidebarIndex(request)
    }

    private var sidebarIndexStreamBuilder: SidebarIndexStreamBuilder = { request, batchSize in
        await AgentSessionDataService.shared.buildSidebarIndexStream(request, batchSize: batchSize)
    }

    private let workflowStore = AgentWorkflowStore.shared
    let attachmentStore = AgentAttachmentStore()
    let attachmentWorkspaceDirectoryProvider: () -> URL?
    private let workspacePathProvider: () -> String?
    private let skillCatalog: AgentSkillCatalog
    private let headlessProviderFactory: HeadlessProviderFactory
    private let acpProviderFactory: ACPProviderFactory
    private let acpControllerFactory: ACPControllerFactory
    private let connectionPolicyInstaller: ConnectionPolicyInstaller
    private let mcpServerEnabler: MCPServerEnabler
    private let mcpRunRoutingCleaner: MCPRunRoutingCleaner
    private let mcpRunToolCanceller: MCPRunToolCanceller
    let codexCoordinator: CodexAgentModeCoordinator
    let claudeCoordinator: ClaudeAgentModeCoordinator
    let providerBindingService: AgentModeProviderBindingService
    private weak var runInteractionStateObserver: (any AgentModeRunInteractionStateObserving)?
    private let shouldManageCodexTooling: Bool
    private let usesProductionAgentDefaultsAndModelPolling: Bool
    let clearConsumedAttachmentsAfterProviderConsumption: Bool
    let applyEditsApprovalStore: ApplyEditsApprovalStore
    private lazy var runService: AgentModeRunService = makeRunService()

    private var isRestoringState = false
    private var activeUISyncSuppressionDepth = 0
    private var isActiveUISyncSuppressed: Bool {
        activeUISyncSuppressionDepth > 0
    }

    private var lastProcessedTabID: UUID?

    /// Last `AgentSessionRunState` the sidebar attention system observed for
    /// each tab. Used to detect *transitions* (not steady-state) so we only
    /// raise an unseen badge when the run state actually moves into a
    /// user-relevant terminal/waiting state in the background. Seeding on
    /// first observation prevents persisted restored sessions from showing
    /// spurious attention badges on launch. Ephemeral, per VM instance.
    var sidebarObservedRunStateByTabID: [UUID: AgentSessionRunState] = [:]
    private var pendingTabIDForLoad: UUID?
    private var pendingUIRefreshScopesByTabID: [UUID: Set<UIRefreshScope>] = [:]
    private var pendingAssistantPresentationByTabID: [UUID: AssistantPresentationRequest] = [:]
    private var uiRefreshTask: Task<Void, Never>?
    private var openCodeModelsSubscriptionTask: Task<Void, Never>?
    private var cursorModelsSubscriptionTask: Task<Void, Never>?
    private var skillCatalogDeltaObservationTask: Task<Void, Never>?
    private var skillCatalogRefreshDebounceTask: Task<Void, Never>?
    private var sessionListCacheTask: Task<Void, Never>?
    private var sessionListCacheGeneration: UInt64 = 0
    private var sessionIndexActivationEpoch: UInt64 = 0
    private var latestSessionIndexOwner: SessionIndexOwner?
    private var sessionIndexOwner: SessionIndexOwner?
    private var sessionListSortDatesOwner: SessionIndexOwner?
    private var sessionListCacheReadyOwner: SessionIndexOwner?
    private var sidebarRestoreFrozenOrderOwner: SessionIndexOwner?
    private var activeSessionIndexRefreshToken: SessionIndexRefreshToken?
    private var activeSessionIndexRefreshWorkspace: WorkspaceModel?
    private var activeSessionIndexRefreshValidTabIDs: Set<UUID> = []
    private var activeSessionIndexRefreshBoundSessionIDByTabID: [UUID: UUID] = [:]
    private var activeSessionIndexRefreshBaselineEntries: [UUID: AgentSessionIndexEntry] = [:]
    private var activeSessionIndexRefreshPrioritizedEntries: [UUID: AgentSessionIndexEntry] = [:]
    private var activeSessionIndexRefreshFullEntries: [UUID: AgentSessionIndexEntry] = [:]
    private var activeSessionIndexRefreshHasPublishedFullBatch = false
    private var sessionIndexLocalUpserts: [UUID: AgentSessionIndexEntry] = [:]
    private var sessionIndexLocalRemovals: Set<UUID> = []
    private var saveInFlightSessionIDs: Set<UUID> = []
    private var saveRequestedWhileInFlightSessionIDs: Set<UUID> = []
    private var workspaceSwitchBackgroundCleanupTasks: [UUID: Task<Void, Never>] = [:]
    var sidebarAutoArchiveTask: Task<Void, Never>?
    var isApplyingSidebarAutoArchive = false
    let sidebarAutoArchivePolicy = AgentModeSidebarAutoArchivePolicy()
    private var initialSystemWorkspaceSessionListRefreshDeferralReason: String?
    private var initialSystemWorkspaceSessionListRefreshDeferralFallbackTask: Task<Void, Never>?
    var sidebarRestoreFrozenOrderByTabID: [UUID: Int] = [:]
    /// Last-published sidebar content fingerprint. Used by
    /// `syncSidebarUIState(refresh:reason:)` to skip duplicate forced refresh
    /// revisions when sidebar-visible content has not changed. Nil before the
    /// first forced refresh so the initial request always publishes.
    var lastSidebarContentFingerprint: AgentSessionSidebarContentFingerprint?
    private var lastKnownWorkspaceSnapshot: WorkspaceModel?
    var tabDraftText: [UUID: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var tabCloseListenerToken: UUID?
    private var isAgentModeActive = false
    #if DEBUG
        private var test_currentTabIDOverride: UUID?
        private var test_activeWorkspaceIDForSessionIndexOverride: UUID?
        private var test_allowsScheduledDerivedTranscriptRefreshWithoutPromptManager = false
        private var test_afterMCPStoreEpochBegan: (@MainActor () async -> Void)?
        private var test_terminalPublicationOverride: ((
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?,
            TabSession
        ) async -> AgentRunTerminalPublicationResult)?
    #endif
    private var hasPreparedForWindowClose = false
    private static let uiRefreshCoalesceDelayNanos: UInt64 = 75_000_000
    private static let sessionSidebarRestoreBatchSize = 32
    private nonisolated static let sessionSidebarRestoreRetryLimit = 1
    nonisolated static let transcriptVisibleItemLimit = 50
    private nonisolated static let detachedTranscriptVisibleItemBuffer = 5
    private nonisolated static let detachedTranscriptEvictionChunkSize = 5
    private nonisolated static let pendingToolFinalizationNonToolBoundary = 200
    private nonisolated static let staleComposerSubmitTargetMessage = "This composer changed before the message could be sent. Please try again."
    private nonisolated static let childAgentRunWaitDrainTimeoutSeconds: TimeInterval = 2.0

    #if DEBUG
        var test_updateBindingsCallCount: Int = 0
        var test_syncComposerCallCount: Int = 0
        var test_syncRuntimeMetricsCallCount: Int = 0
        var test_syncRunInteractionCallCount: Int = 0
        var test_workspaceManager: WorkspaceManagerViewModel? {
            workspaceManager
        }

        var test_dataService: AgentSessionDataService {
            dataService
        }

        var test_codexCoordinator: CodexAgentModeCoordinator {
            codexCoordinator
        }

        func test_initializeRunService() {
            _ = runService
        }

        var test_isCursorModelPollingActive: Bool {
            cursorModelsSubscriptionTask != nil
        }

        func test_setActiveSessionBindingsAreHydrated(_ value: Bool) {
            setActiveTranscriptBindingsHydrated(value)
        }

        func test_setCurrentTabIDOverride(_ tabID: UUID?) {
            test_currentTabIDOverride = tabID
        }

        func test_setSidebarAutoArchiveDependencies(
            promptManager: PromptViewModel,
            workspaceManager: WorkspaceManagerViewModel
        ) {
            self.promptManager = promptManager
            self.workspaceManager = workspaceManager
        }

        func test_setSidebarAutoArchiveActive(_ isActive: Bool) {
            isAgentModeActive = isActive
        }

        func test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(_ value: Bool) {
            test_allowsScheduledDerivedTranscriptRefreshWithoutPromptManager = value
        }

        func test_setAfterMCPStoreEpochBegan(_ hook: (@MainActor () async -> Void)?) {
            test_afterMCPStoreEpochBegan = hook
        }

        func test_setTerminalPublicationOverride(
            _ hook: ((
                AgentRunTerminalCommitRevision,
                AgentRunEpochTransitionKind?,
                TabSession
            ) async -> AgentRunTerminalPublicationResult)?
        ) {
            test_terminalPublicationOverride = hook
        }

        func test_makeTerminalPublicationEnvelope(
            for session: TabSession,
            ownership: AgentRunOwnership,
            terminalState: AgentSessionRunState,
            providerRunID: UUID? = nil
        ) -> AgentRunTerminalPublicationEnvelope? {
            makeTerminalPublicationEnvelope(
                for: session,
                ownership: ownership,
                terminalState: terminalState,
                providerRunID: providerRunID
            )
        }

        func test_publishTerminalCommit(
            _ revision: AgentRunTerminalCommitRevision,
            successorKind: AgentRunEpochTransitionKind?,
            for session: TabSession
        ) async -> AgentRunTerminalPublicationResult {
            await publishTerminalCommit(revision, successorKind: successorKind, for: session)
        }

        var test_pendingAssistantPresentationCount: Int {
            pendingAssistantPresentationByTabID.count
        }

        func test_installPersistentSessionBinding(
            sessionID: UUID?,
            on session: TabSession,
            updateWorkspaceMetadata: Bool = false
        ) -> AgentPersistentSessionBindingIdentity? {
            installPersistentSessionBinding(
                sessionID: sessionID,
                on: session,
                updateWorkspaceMetadata: updateWorkspaceMetadata,
                invalidateAsyncWork: true
            )
        }

        func test_ensureSessionBoundToTab(_ session: TabSession) -> UUID? {
            ensureSessionBoundToTab(session)
        }

        func test_bindingResolution(sessionID: UUID) -> PersistentBindingResolution {
            persistentBindingResolution(for: sessionID)
        }

        func test_bindingTransitionToken(for session: TabSession) -> PersistentBindingTransitionToken {
            session.persistentBindingTransitionToken()
        }

        func test_isBindingTransitionCurrent(_ token: PersistentBindingTransitionToken) -> Bool {
            persistentBindingTransitionIsCurrent(token)
        }

        func test_canCommitHydration(
            payloadSessionID: UUID,
            token: PersistedHydrationCommitToken
        ) -> Bool {
            payloadSessionID == token.requestedSessionID
                && persistentBindingTransitionIsCurrent(token.transition)
        }

        func test_rebindPersistentSession(
            _ sessionID: UUID,
            to session: TabSession
        ) async throws -> AgentPersistentSessionBindingIdentity {
            try await rebindPersistentSession(sessionID, to: session)
        }

        func test_saveCommitToken(for session: TabSession, workspaceID: UUID) -> SessionSaveCommitToken? {
            makeSaveCommitToken(for: session, workspaceID: workspaceID)
        }

        func test_isSaveCommitTokenCurrent(_ token: SessionSaveCommitToken) -> Bool {
            isSaveCommitTokenCurrent(token, requireWorkspaceMatch: false)
        }

        func test_shouldAcceptSidebarIndexEntry(_ entry: AgentSessionIndexEntry) -> Bool {
            shouldAcceptSidebarIndexEntry(entry)
        }

        func test_setSidebarIndexBuilders(
            prioritized: @escaping SidebarPrioritizedIndexBuilder,
            stream: @escaping SidebarIndexStreamBuilder
        ) {
            sidebarPrioritizedIndexBuilder = prioritized
            sidebarIndexStreamBuilder = stream
        }

        func test_receiveWorkspaceSwitchNotification(_ workspace: WorkspaceModel?) -> SessionIndexOwner {
            receiveWorkspaceSwitchNotification(workspace)
        }

        func test_handleWorkspaceSwitch(
            _ workspace: WorkspaceModel?,
            owner: SessionIndexOwner
        ) async {
            await handleWorkspaceSwitch(workspace, owner: owner)
        }

        func test_refreshSessionListCache(for workspace: WorkspaceModel) {
            guard let owner = sessionIndexOwner else { return }
            refreshSessionListCache(for: workspace, owner: owner)
        }

        func test_waitForSessionListCacheRefresh() async {
            while let task = sessionListCacheTask {
                await task.value
                await Task.yield()
            }
        }

        func test_setActiveWorkspaceIDForSessionIndex(_ workspaceID: UUID?) {
            test_activeWorkspaceIDForSessionIndexOverride = workspaceID
        }

        var test_sessionIndexOwner: SessionIndexOwner? {
            sessionIndexOwner
        }

        var test_activeSessionIndexRefreshGeneration: UInt64? {
            activeSessionIndexRefreshToken?.generation
        }

        var test_ownerValidatedSessionIndex: [UUID: AgentSessionIndexEntry] {
            ownerValidatedSessionIndex
        }

        var test_ownerValidatedSessionListCacheReady: Bool {
            ownerValidatedSessionListCacheReady
        }

        var test_ownerValidatedSidebarRestoreFrozenOrderCount: Int {
            ownerValidatedSidebarRestoreFrozenOrderByTabID.count
        }

        func test_installSessionIndexSnapshot(
            _ entries: [UUID: AgentSessionIndexEntry],
            owner: SessionIndexOwner,
            latestOwner: SessionIndexOwner,
            activeWorkspace: WorkspaceModel
        ) {
            latestSessionIndexOwner = latestOwner
            sessionIndexOwner = owner
            sessionListSortDatesOwner = owner
            sessionListCacheReadyOwner = owner
            lastKnownWorkspaceSnapshot = activeWorkspace
            test_activeWorkspaceIDForSessionIndexOverride = activeWorkspace.id
            sessionIndex = entries
            rebuildSessionSortDatesFromIndex()
            sessionListCacheReady = true
        }

        func test_sessionTreeCascadePlan(
            forComposeTabIDs tabIDs: Set<UUID>,
            reason: PromptViewModel.ComposeTabRemovalReason
        ) -> PromptViewModel.AgentSessionCascadePlan {
            sessionTreeCascadePlan(forComposeTabIDs: tabIDs, reason: reason)
        }

        func test_flushPendingUIRefresh() {
            flushPendingUIRefresh(cancelScheduled: true)
        }

        func test_drainScheduledDerivedTranscriptRefresh(tabID: UUID) async {
            while let session = sessions[tabID], let task = session.derivedTranscriptRefreshTask {
                let generation = session.derivedTranscriptRefreshGeneration
                await task.value
                await Task.yield()
                if session.derivedTranscriptRefreshTask != nil,
                   session.derivedTranscriptRefreshGeneration == generation
                {
                    session.derivedTranscriptRefreshTask = nil
                }
            }
        }

        func test_setMCPControlledTabIDs(_ tabIDs: Set<UUID>) {
            mcpControlledTabIDs = tabIDs
        }

        func test_setActiveSessionLoadInProgressTabID(_ tabID: UUID?) {
            activeSessionLoadInProgressTabID = tabID
        }
    #endif

    /// Current tab ID from promptManager
    var currentTabID: UUID? {
        #if DEBUG
            if let test_currentTabIDOverride {
                return test_currentTabIDOverride
            }
        #endif
        return promptManager?.activeComposeTabID
    }

    #if DEBUG
        @discardableResult
        func debugBeginSidebarDeleteRequest(tabID: UUID, source: String, reason: String? = nil) -> UUID {
            let sessionID = boundSessionID(for: tabID)
            let wasRunning = sessions[tabID]?.runState.isActive == true
            return AgentModePerfDiagnostics.beginSidebarDelete(
                AgentModePerfDiagnostics.SidebarDeleteBeginContext(
                    tabID: tabID,
                    sessionID: sessionID,
                    source: source,
                    reason: reason,
                    wasCurrentTab: currentTabID == tabID,
                    wasRunning: wasRunning,
                    isMCPControlled: mcpControlledTabIDs.contains(tabID)
                )
            )
        }
    #endif

    var canRunSidebarAutoArchive: Bool {
        isAgentModeActive
            && !workspaceSwitchInFlight
            && workspaceManager?.isSwitchingWorkspace != true
            && !hasPreparedForWindowClose
    }

    var sidebarContentFingerprintTabs: [ComposeTabState] {
        promptManager?.currentComposeTabs ?? workspaceManager?.activeWorkspace?.composeTabs ?? []
    }

    /// Active session for the current tab
    var activeSession: TabSession? {
        guard let tabID = currentTabID else { return nil }
        return sessions[tabID]
    }

    func scopedActiveTranscriptPresentation(for tabID: UUID?) -> AgentTranscriptPresentationSnapshot {
        guard let tabID,
              activeTranscriptPresentation.tabID == tabID
        else {
            return loadingTranscriptPresentationSnapshot(tabID: tabID, revision: 0)
        }
        return activeTranscriptPresentation
    }

    @MainActor
    func rawToolResultPayloadForRendering(tabID: UUID?, itemID: UUID) -> String? {
        let resolvedTabID = tabID
            ?? activeTranscriptPresentation.tabID
            ?? currentTabID
        guard let resolvedTabID,
              let payload = sessions[resolvedTabID]?.ephemeralToolResultPayloadByItemID[itemID],
              !payload.isEmpty
        else {
            return nil
        }
        return payload
    }

    func isActiveTranscriptPresentationHydrated(for tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return activeTranscriptPresentation.tabID == tabID
            && activeTranscriptPresentation.bindingsHydrated
    }

    func activeTranscriptPresentationRevision(for tabID: UUID?) -> Int {
        guard let tabID,
              activeTranscriptPresentation.tabID == tabID
        else {
            return 0
        }
        return activeTranscriptPresentation.revision
    }

    @discardableResult
    private func withActiveUISyncSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        activeUISyncSuppressionDepth += 1
        defer { activeUISyncSuppressionDepth -= 1 }
        return try body()
    }

    var activeTranscriptAnalyticsSnapshot: AgentTranscriptAnalyticsSnapshot {
        activeSession?.transcriptAnalyticsSnapshot ?? .init(selectedAgent: selectedAgent)
    }

    func modelOptions(
        for agentKind: AgentProviderKind,
        includeClaudeEffortVariants: Bool = true
    ) -> [AgentModelOption] {
        guard AgentModelCatalog.isAgentAvailable(agentKind, availability: agentAvailabilityContext) else { return [] }
        return codexCoordinator.modelOptions(
            for: agentKind,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels,
            includeClaudeEffortVariants: includeClaudeEffortVariants
        )
    }

    func selectModel(rawModel: String) {
        selectedModelRaw = rawModel
    }

    /// Persist the last-used model for a given agent to UserDefaults.
    private static func persistModelForAgent(agentRaw: String, modelRaw: String) {
        var dict = UserDefaults.standard.dictionary(forKey: lastUsedModelsByAgentKey) as? [String: String] ?? [:]
        dict[agentRaw] = modelRaw
        UserDefaults.standard.set(dict, forKey: lastUsedModelsByAgentKey)
    }

    /// Read the last-used model for a given agent from UserDefaults.
    private static func lastUsedModelRaw(forAgentRaw agentRaw: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: lastUsedModelsByAgentKey) as? [String: String]
        return dict?[agentRaw]
    }

    private func restoreLastUsedAgentSelectionIfNeeded() {
        guard let savedAgentRaw = UserDefaults.standard.string(forKey: Self.lastUsedAgentKey) else { return }
        let savedModelRaw = Self.lastUsedModelRaw(forAgentRaw: savedAgentRaw)
        let normalized = normalizedSelection(
            agentRaw: savedAgentRaw,
            modelRaw: savedModelRaw,
            preserveUnavailableAgent: true
        )
        isRestoringState = true
        selectedAgent = normalized.agent
        selectedModelRaw = normalized.modelRaw
        isRestoringState = false
    }

    private func persistLastUsedModelIfNeeded(agent: AgentProviderKind, modelRaw: String) {
        guard usesProductionAgentDefaultsAndModelPolling else { return }
        guard shouldPersistLastUsedModel(agent: agent, modelRaw: modelRaw) else { return }
        Self.persistModelForAgent(agentRaw: agent.rawValue, modelRaw: modelRaw)
    }

    private func shouldPersistLastUsedModel(agent: AgentProviderKind, modelRaw: String) -> Bool {
        true
    }

    func selectReasoningEffort(_ effort: CodexReasoningEffort?) {
        selectedReasoningEffortRaw = effort?.rawValue
    }

    func reasoningEffortOptionsForCurrentSelection() -> [CodexReasoningEffort] {
        codexCoordinator.reasoningEffortOptions(forModelRaw: selectedModelRaw, agentKind: selectedAgent)
    }

    func updateCodexDynamicModels(_ models: [CodexAppServerClient.RemoteModel]) {
        if codexDynamicModels != models {
            codexDynamicModels = models
            syncComposerUIState()
        }
        // Note: Registry updates are owned exclusively by CodexModelPollingService.
        // Do NOT call AgentCodexModelRegistry.shared.updateLiveModels() here.
    }

    func applyCodexSelectionToBindings(modelRaw: String, reasoningEffortRaw: String?) {
        isRestoringState = true
        selectedModelRaw = modelRaw
        selectedReasoningEffortRaw = reasoningEffortRaw
        isRestoringState = false
        syncComposerUIState()
    }

    func setAgentRunActive(_ tabID: UUID, isActive: Bool) {
        let session = session(for: tabID, createIfNeeded: false)
        if isActive {
            tabsWithActiveAgentRun.insert(tabID)
            if session?.activeAgentRunStartedAt == nil {
                session?.activeAgentRunStartedAt = Date()
            }
            // A new/resumed run clears any stale "completed in background"
            // badge the user hasn't acknowledged yet. The run-state transition
            // observer also handles this on .running, but some provider paths
            // call setAgentRunActive(true) before session.runState has been
            // observed by the sidebar — clearing here keeps the two in sync.
            acknowledgeSidebarRunAttention(tabID: tabID)
        } else {
            tabsWithActiveAgentRun.remove(tabID)
            session?.activeAgentRunStartedAt = nil
            // Intentionally do NOT clear/mark attention here. Provider paths
            // sometimes call setAgentRunActive(false) before session.runState
            // has been mutated to its terminal/waiting value — detection must
            // happen from the run-state transition observer instead, which
            // runs when the new runState is actually visible on the session.
        }
        publishActiveAgentRunStartedAt(for: tabID, session: session)
        syncComposerUIState()
    }

    private func publishActiveAgentRunStartedAt(for tabID: UUID, session: TabSession?) {
        let nextStartedAt = session?.activeAgentRunStartedAt
        if tabID == currentTabID, activeAgentRunStartedAt != nextStartedAt {
            activeAgentRunStartedAt = nextStartedAt
        }
    }

    func modelDisplayName(
        rawModel: String,
        agentKind: AgentProviderKind
    ) -> String {
        codexCoordinator.selectedModelDisplayName(
            rawModel: rawModel,
            agentKind: agentKind,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    func inputBarModelDisplayName(
        rawModel: String,
        agentKind: AgentProviderKind
    ) -> String {
        AgentModelCatalog.displayName(
            for: rawModel,
            agentKind: agentKind,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels,
            includeEffortSuffix: false
        )
    }

    private var agentAvailabilityContext: AgentModelCatalog.AvailabilityContext {
        promptManager?.apiSettingsViewModel?.agentModeAvailabilityContext ?? .current
    }

    var hasAvailableAgentProviders: Bool {
        !availableAgents.isEmpty
    }

    var isSelectedAgentAvailable: Bool {
        AgentModelCatalog.isAgentAvailable(selectedAgent, availability: agentAvailabilityContext)
    }

    var canSendWithCurrentProvider: Bool {
        isSelectedAgentAvailable
    }

    var unavailableSelectedAgentMessage: String? {
        guard !isSelectedAgentAvailable else { return nil }
        return unavailableAgentMessage(for: selectedAgent)
    }

    private func unavailableAgentMessage(for agent: AgentProviderKind) -> String {
        if hasAvailableAgentProviders {
            return "\(agent.displayName) is not connected. Fork or start a new chat to switch providers, or connect it in Settings."
        }
        return "Connect a CLI provider in Settings before starting Agent Mode."
    }

    private func isModelRawValid(
        _ rawModel: String,
        for agent: AgentProviderKind
    ) -> Bool {
        AgentModelCatalog.isValid(
            rawModel: rawModel,
            for: agent,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    func defaultModelRaw(for agent: AgentProviderKind) -> String {
        AgentModelCatalog.defaultModelRaw(for: agent, availability: agentAvailabilityContext, codexDynamicModels: codexDynamicModels)
    }

    private func normalizedSelection(
        agentRaw: String?,
        modelRaw: String?,
        preserveUnavailableAgent: Bool = false
    ) -> AgentModelCatalog.NormalizedAgentSelection {
        AgentModelCatalog.normalizeSelection(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels,
            preserveUnavailableAgent: preserveUnavailableAgent
        )
    }

    private func refreshAvailableAgents() {
        availableAgents = AgentModelCatalog.selectableAgents(availability: agentAvailabilityContext)
        syncComposerUIState()
    }

    private func handleAgentProviderAvailabilityChanged() {
        refreshAvailableAgents()
        if let activeSession,
           activeSession.runState.isActive || activeSession.isProviderSelectionLocked
        {
            return
        }
        let normalized = normalizedSelection(agentRaw: selectedAgent.rawValue, modelRaw: selectedModelRaw)
        guard normalized.agent != selectedAgent || normalized.modelRaw.caseInsensitiveCompare(selectedModelRaw) != .orderedSame else {
            return
        }
        isRestoringState = true
        selectedAgent = normalized.agent
        selectedModelRaw = normalized.modelRaw
        isRestoringState = false
        if let session = activeSession {
            session.selectedAgent = normalized.agent
            session.selectedModelRaw = normalized.modelRaw
            codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: false)
            scheduleSave(for: session.tabID)
        }
        updateDynamicModelPolling()
        syncAllActiveUIState()
    }

    private func updateDynamicModelPolling(startCursorPolling: Bool = true) {
        guard usesProductionAgentDefaultsAndModelPolling else { return }
        codexCoordinator.updateCodexModelPolling()
        updateOpenCodeModelPolling()
        updateCursorModelPolling(startPolling: startCursorPolling)
    }

    private func updateOpenCodeModelPolling() {
        if selectedAgent == .openCode {
            startOpenCodeModelsSubscriptionIfNeeded()
        } else {
            stopOpenCodeModelsSubscription()
        }
    }

    private func startOpenCodeModelsSubscriptionIfNeeded() {
        guard openCodeModelsSubscriptionTask == nil else { return }
        let workspacePath = workspacePathProvider()
        openCodeModelsSubscriptionTask = Task { [weak self, workspacePath] in
            let stream = await OpenCodeACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    acpDynamicModelRevision &+= 1
                    syncSelectedACPModelFromRegistryIfNeeded(for: .openCode)
                    syncComposerUIState()
                }
            }
        }
    }

    private func stopOpenCodeModelsSubscription() {
        openCodeModelsSubscriptionTask?.cancel()
        openCodeModelsSubscriptionTask = nil
    }

    private func updateCursorModelPolling(startPolling: Bool = true) {
        guard selectedAgent == .cursor else {
            stopCursorModelsSubscription()
            return
        }
        guard startPolling,
              AgentModelCatalog.isAgentAvailable(.cursor, availability: agentAvailabilityContext)
        else {
            return
        }
        startCursorModelsSubscriptionIfNeeded()
    }

    private func startCursorModelsSubscriptionIfNeeded() {
        guard cursorModelsSubscriptionTask == nil else { return }
        let workspacePath = workspacePathProvider()
        cursorModelsSubscriptionTask = Task { [weak self, workspacePath] in
            let stream = await CursorACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    acpDynamicModelRevision &+= 1
                    syncSelectedACPModelFromRegistryIfNeeded(for: .cursor)
                    syncComposerUIState()
                }
            }
        }
    }

    private func stopCursorModelsSubscription() {
        cursorModelsSubscriptionTask?.cancel()
        cursorModelsSubscriptionTask = nil
    }

    private func syncSelectedACPModelFromRegistryIfNeeded(for agent: AgentProviderKind) {
        guard selectedAgent == agent,
              let providerID = agent.acpProviderID,
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID),
              let preferredModelRaw = snapshot.preferredModelRaw
        else {
            return
        }

        let trimmedSelection = selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIsDefault = trimmedSelection.isEmpty
            || trimmedSelection.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let selectedOption = snapshot.option(matching: selectedModelRaw)
        let selectedIsPlaceholder = selectedIsDefault || selectedOption?.isPlaceholderDefault == true
        guard selectedIsPlaceholder else { return }
        guard selectedModelRaw.caseInsensitiveCompare(preferredModelRaw) != .orderedSame else { return }

        isRestoringState = true
        selectedModelRaw = preferredModelRaw
        if let session = activeSession, session.selectedAgent == agent {
            session.selectedModelRaw = preferredModelRaw
            codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)
            scheduleSave(for: session.tabID)
        }
        isRestoringState = false
        persistLastUsedModelIfNeeded(agent: agent, modelRaw: preferredModelRaw)
    }

    private nonisolated static func defaultHeadlessProviderFactory(
        agent: AgentProviderKind,
        modelString: String?
    ) -> HeadlessAgentProvider {
        assert(agent != .codexExec, "Codex native runs must not use headless provider factory.")
        return AgentRuntimeProviderService.shared.makeProvider(for: agent, modelString: modelString)
    }

    private nonisolated static func defaultConnectionPolicyInstaller(
        clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool,
        reason: String?,
        ttl: TimeInterval,
        tabID: UUID?,
        runID: UUID?,
        additionalTools: Set<String>?,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        requiresExpectedAgentPID: Bool = false
    ) async {
        await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: clientName,
            windowID: windowID,
            restrictedTools: restrictedTools,
            oneShot: oneShot,
            reason: reason,
            ttl: ttl,
            tabID: tabID,
            runID: runID,
            additionalTools: additionalTools,
            purpose: purpose,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: requiresExpectedAgentPID
        )
    }

    private nonisolated static func defaultMCPRunRoutingCleaner(
        runID: UUID,
        windowID: Int,
        reason: String
    ) async {
        _ = reason
        await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
        await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowID)
        await AgentRunCoordinator.shared.cleanupRouting(runID: runID)
    }

    // MARK: - Initialization

    private weak var oracleViewModel: OracleViewModel?

    init(
        windowID: Int,
        promptManager: PromptViewModel,
        workspaceManager: WorkspaceManagerViewModel,
        mcpServer: MCPServerViewModel,
        oracleViewModel: OracleViewModel? = nil,
        applyEditsApprovalStore: ApplyEditsApprovalStore = .shared,
        clearConsumedAttachmentsAfterProviderConsumption: Bool = true,
        skillCatalog: AgentSkillCatalog? = nil
    ) {
        self.windowID = windowID
        self.promptManager = promptManager
        workspaceFileContextStore = promptManager.workspaceFileContextStore
        self.workspaceManager = workspaceManager
        self.mcpServer = mcpServer
        self.oracleViewModel = oracleViewModel
        self.applyEditsApprovalStore = applyEditsApprovalStore
        self.skillCatalog = skillCatalog ?? AgentSkillCatalog()
        let codexWorkspacePathProvider = { [weak workspaceManager] in
            workspaceManager?.activeWorkspace?.repoPaths.first
        }
        let sessionWorkspacePathProvider: (TabSession) throws -> String? = { session in
            try Self.effectiveWorkspacePath(
                for: session,
                fallbackWorkspacePath: codexWorkspacePathProvider()
            )
        }
        workspacePathProvider = codexWorkspacePathProvider
        attachmentWorkspaceDirectoryProvider = { [weak workspaceManager] in
            guard let workspaceManager, workspaceManager.activeWorkspace != nil else {
                return nil
            }
            return FileManager.default.temporaryDirectory
        }
        let codexControllerFactory: CodexAgentModeCoordinator.CodexControllerFactory = { runID, tabID, windowID, workspacePath, permissionProfile, _, computerUseEnabled in
            let client = CodexAppServerClient()
            let options = CodexNativeSessionController.Options.agentModeDefault(
                forceExperimentalSteering: true,
                approvalPolicyProvider: { permissionProfile.codexApprovalPolicy },
                sandboxModeProvider: { permissionProfile.codexSandboxMode },
                approvalReviewerProvider: { permissionProfile.codexApprovalReviewer },
                shellToolEnabled: permissionProfile.codexBashToolEnabled(),
                suppressThirdPartyMCPServers: permissionProfile.codexSuppressesThirdPartyMCPServers,
                goalSupportEnabledProvider: { CodexGoalSupport.isEnabled },
                computerUseEnabledProvider: { computerUseEnabled }
            )
            return CodexNativeSessionController(
                client: client,
                runID: runID,
                tabID: tabID,
                windowID: windowID,
                workspacePath: workspacePath,
                options: options,
                clientShutdownBehavior: .stopOnShutdown,
                expectedMCPClientName: AgentProviderKind.codexExec.mcpClientNameHint
            )
        }
        headlessProviderFactory = Self.defaultHeadlessProviderFactory
        acpProviderFactory = { agent, modelString in
            ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        }
        acpControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
        connectionPolicyInstaller = { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
            await Self.defaultConnectionPolicyInstaller(
                clientName: clientName,
                windowID: windowID,
                restrictedTools: restrictedTools,
                oneShot: oneShot,
                reason: reason,
                ttl: ttl,
                tabID: tabID,
                runID: runID,
                additionalTools: additionalTools,
                purpose: purpose,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: requiresExpectedAgentPID
            )
        }
        mcpServerEnabler = { [weak mcpServer] in
            guard let mcpServer else { return }
            await mcpServer.ensureServerReadyForAgentBootstrap()
        }
        mcpRunRoutingCleaner = { runID, windowID, reason in
            await Self.defaultMCPRunRoutingCleaner(
                runID: runID,
                windowID: windowID,
                reason: reason
            )
        }
        mcpRunToolCanceller = { [weak mcpServer] runID, reason in
            mcpServer?.cancelActiveToolsForRun(runID: runID, reason: reason) ?? 0
        }
        shouldManageCodexTooling = true
        usesProductionAgentDefaultsAndModelPolling = true
        codexCoordinator = CodexAgentModeCoordinator(
            windowID: windowID,
            workspacePathProvider: sessionWorkspacePathProvider,
            codexControllerFactory: codexControllerFactory,
            connectionPolicyInstaller: connectionPolicyInstaller,
            shouldManageCodexTooling: true,
            activeToolQuery: { [weak mcpServer] runID in
                mcpServer?.hasActiveToolExecutions(runID: runID) ?? false
            },
            activeAgentRunWaitQuery: { [weak mcpServer] runID in
                mcpServer?.hasActiveChildAgentRunWaits(runID: runID) ?? false
            },
            stallWatchdogProbeThreshold: 90,
            stallWatchdogRecoveryThreshold: 300,
            initialLastUsedReasoningEffort: CodexAgentToolPreferences.lastUsedReasoningEffort(),
            initialLastUsedReasoningEffortsByModelSlug: CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug()
        )
        claudeCoordinator = ClaudeAgentModeCoordinator(
            windowID: windowID,
            workspacePathProvider: sessionWorkspacePathProvider,
            awaitNoActiveMCPTools: { [weak mcpServer] runID in
                guard let mcpServer else { return }
                try await mcpServer.awaitNoActiveToolExecutions(runID: runID)
            },
            toolEndedCount: { [weak mcpServer] runID in
                mcpServer?.toolEndedCount(runID: runID) ?? 0
            },
            hasActiveMCPTools: { [weak mcpServer] runID in
                mcpServer?.hasActiveToolExecutions(runID: runID) ?? false
            },
            hasActiveChildAgentRunWaits: { [weak mcpServer] runID in
                mcpServer?.hasActiveChildAgentRunWaits(runID: runID) ?? false
            }
        )
        self.clearConsumedAttachmentsAfterProviderConsumption = clearConsumedAttachmentsAfterProviderConsumption
        providerBindingService = AgentModeProviderBindingService()
        codexCoordinator.setActiveAgentRunWaitDrain { [weak self] runID, source in
            guard let self, let mcpServer = self.mcpServer else { return true }
            return await mcpServer.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
                runID: runID,
                source: source,
                timeoutSeconds: Self.childAgentRunWaitDrainTimeoutSeconds,
                publicationForSessionID: { [weak self] childSessionID in
                    self?.mcpWaitPublication(sessionID: childSessionID)
                }
            )
        }
        codexCoordinator.attach(viewModel: self)
        claudeCoordinator.attach(viewModel: self)
        runInteractionStateObserver = codexCoordinator
        mcpServer.registerAgentWorktreeBindingsProvider { [weak self] sessionID, tabID in
            guard let self else { return .unavailable }
            return worktreeBindingState(forAgentSessionID: sessionID, tabID: tabID)
        }
        mcpServer.registerAgentWorktreeBindingsResolver { [weak self] sessionID, tabID in
            guard let self else { return .unavailable }
            return await resolveWorktreeBindingStateEnsuringOwnership(sessionID: sessionID, tabID: tabID)
        }

        refreshAvailableAgents()

        // Restore last-used agent and model so new sessions default to the user's previous choice.
        restoreLastUsedAgentSelectionIfNeeded()

        setupObservers()
        updateDynamicModelPolling(startCursorPolling: false)
        syncAllActiveUIState()
        scheduleInitialSkillCatalogRefresh()
    }

    #if DEBUG
        init(
            testWindowID: Int = 1,
            testWorkspacePath: String? = nil,
            testWorkspaceDirectory: URL? = nil,
            applyEditsApprovalStore: ApplyEditsApprovalStore = .shared,
            clearConsumedAttachmentsAfterProviderConsumption: Bool = true,
            shouldManageCodexTooling: Bool = false,
            skillCatalog: AgentSkillCatalog? = nil,
            codexControllerFactory: @escaping CodexControllerFactory,
            codexControllerFactoryWithComputerUse: CodexControllerFactoryWithComputerUse? = nil,
            claudeControllerFactory: ClaudeAgentModeCoordinator.ClaudeControllerFactory? = nil,
            headlessProviderFactory: @escaping HeadlessProviderFactory = { agent, modelString in
                AgentModeViewModel.defaultHeadlessProviderFactory(agent: agent, modelString: modelString)
            },
            acpProviderFactory: @escaping ACPProviderFactory = { agent, modelString in
                ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
            },
            acpControllerFactory: @escaping ACPControllerFactory = { provider, runRequest in
                try ACPAgentSessionController(provider: provider, runRequest: runRequest)
            },
            connectionPolicyInstaller: @escaping ConnectionPolicyInstaller = { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
                await AgentModeViewModel.defaultConnectionPolicyInstaller(
                    clientName: clientName,
                    windowID: windowID,
                    restrictedTools: restrictedTools,
                    oneShot: oneShot,
                    reason: reason,
                    ttl: ttl,
                    tabID: tabID,
                    runID: runID,
                    additionalTools: additionalTools,
                    purpose: purpose,
                    taskLabelKind: taskLabelKind,
                    allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                    requiresExpectedAgentPID: requiresExpectedAgentPID
                )
            },
            mcpRunRoutingCleaner: @escaping MCPRunRoutingCleaner = { runID, windowID, reason in
                await AgentModeViewModel.defaultMCPRunRoutingCleaner(
                    runID: runID,
                    windowID: windowID,
                    reason: reason
                )
            },
            mcpRunToolCanceller: MCPRunToolCanceller? = nil,
            mcpServerEnabler: @escaping MCPServerEnabler = {},
            testMCPServer: MCPServerViewModel? = nil,
            testWorkspaceFileContextStore: WorkspaceFileContextStore? = nil,
            testCodexActiveToolQuery: CodexActiveToolQuery? = nil,
            testCodexActiveAgentRunWaitQuery: CodexAgentRunWaitQuery? = nil,
            testCodexActiveAgentRunWaitDrain: CodexAgentRunWaitDrain? = nil,
            testCodexLeaseRoutingTimeoutMs: Int? = nil,
            testCodexIdleShutdownDelayNanos: UInt64? = nil,
            testCodexStallWatchdogPollIntervalNanos: UInt64? = nil,
            testCodexStallWatchdogProbeThreshold: TimeInterval? = nil,
            testCodexStallWatchdogRecoveryThreshold: TimeInterval? = nil,
            testCodexStallWatchdogInactivityThreshold: TimeInterval? = nil,
            testCodexTransportClosedRecoveryGraceInterval: TimeInterval? = nil,
            testUsesProductionAgentDefaultsAndModelPolling: Bool = false
        ) {
            windowID = testWindowID
            promptManager = nil
            workspaceFileContextStore = testWorkspaceFileContextStore
            workspaceManager = nil
            mcpServer = testMCPServer
            self.applyEditsApprovalStore = applyEditsApprovalStore
            self.skillCatalog = skillCatalog ?? AgentSkillCatalog()
            attachmentWorkspaceDirectoryProvider = {
                if let testWorkspaceDirectory {
                    return testWorkspaceDirectory
                }
                return FileManager.default.temporaryDirectory
            }
            let codexWorkspacePathProvider = { testWorkspacePath }
            let sessionWorkspacePathProvider: (TabSession) throws -> String? = { session in
                try Self.effectiveWorkspacePath(
                    for: session,
                    fallbackWorkspacePath: codexWorkspacePathProvider()
                )
            }
            workspacePathProvider = codexWorkspacePathProvider
            let codexControllerFactory: CodexAgentModeCoordinator.CodexControllerFactory = codexControllerFactoryWithComputerUse
                ?? { runID, tabID, windowID, workspacePath, permissionProfile, taskLabelKind, _ in
                    codexControllerFactory(runID, tabID, windowID, workspacePath, permissionProfile, taskLabelKind)
                }
            self.headlessProviderFactory = headlessProviderFactory
            self.acpProviderFactory = acpProviderFactory
            self.acpControllerFactory = acpControllerFactory
            self.connectionPolicyInstaller = connectionPolicyInstaller
            self.mcpServerEnabler = mcpServerEnabler
            self.mcpRunRoutingCleaner = mcpRunRoutingCleaner
            self.mcpRunToolCanceller = mcpRunToolCanceller
                ?? { [weak testMCPServer] runID, reason in
                    testMCPServer?.cancelActiveToolsForRun(runID: runID, reason: reason) ?? 0
                }
            self.shouldManageCodexTooling = shouldManageCodexTooling
            usesProductionAgentDefaultsAndModelPolling = testUsesProductionAgentDefaultsAndModelPolling
            let legacyWatchdogThreshold = testCodexStallWatchdogInactivityThreshold
            let testWatchdogProbeThreshold = testCodexStallWatchdogProbeThreshold ?? legacyWatchdogThreshold ?? 0
            let testWatchdogRecoveryThreshold: TimeInterval = if let explicitRecoveryThreshold = testCodexStallWatchdogRecoveryThreshold {
                explicitRecoveryThreshold
            } else if testCodexStallWatchdogProbeThreshold == nil, let legacyWatchdogThreshold {
                legacyWatchdogThreshold * 2
            } else {
                max(testWatchdogProbeThreshold, legacyWatchdogThreshold ?? 0)
            }
            codexCoordinator = CodexAgentModeCoordinator(
                windowID: testWindowID,
                workspacePathProvider: sessionWorkspacePathProvider,
                codexControllerFactory: codexControllerFactory,
                connectionPolicyInstaller: connectionPolicyInstaller,
                shouldManageCodexTooling: shouldManageCodexTooling,
                activeToolQuery: testCodexActiveToolQuery
                    ?? { [weak testMCPServer] runID in
                        testMCPServer?.hasActiveToolExecutions(runID: runID) ?? false
                    },
                activeAgentRunWaitQuery: testCodexActiveAgentRunWaitQuery
                    ?? { [weak testMCPServer] runID in
                        testMCPServer?.hasActiveChildAgentRunWaits(runID: runID) ?? false
                    },
                activeAgentRunWaitDrain: testCodexActiveAgentRunWaitDrain
                    ?? { [weak testMCPServer] runID, source in
                        guard let testMCPServer else { return true }
                        return await testMCPServer.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
                            runID: runID,
                            source: source,
                            timeoutSeconds: Self.childAgentRunWaitDrainTimeoutSeconds,
                            publicationForSessionID: { _ in nil }
                        )
                    },
                leaseRoutingTimeoutMs: testCodexLeaseRoutingTimeoutMs ?? 2000,
                idleShutdownDelayNanos: testCodexIdleShutdownDelayNanos ?? 300_000_000_000,
                stallWatchdogPollIntervalNanos: testCodexStallWatchdogPollIntervalNanos ?? 5_000_000_000,
                stallWatchdogProbeThreshold: testWatchdogProbeThreshold,
                stallWatchdogRecoveryThreshold: testWatchdogRecoveryThreshold,
                transportClosedRecoveryGraceInterval: testCodexTransportClosedRecoveryGraceInterval ?? 1.5,
                initialLastUsedReasoningEffort: CodexAgentToolPreferences.lastUsedReasoningEffort(),
                initialLastUsedReasoningEffortsByModelSlug: CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug()
            )
            claudeCoordinator = ClaudeAgentModeCoordinator(
                windowID: testWindowID,
                workspacePathProvider: sessionWorkspacePathProvider,
                claudeControllerFactory: claudeControllerFactory,
                toolEndedCount: { [weak testMCPServer] runID in
                    testMCPServer?.toolEndedCount(runID: runID) ?? 0
                },
                hasActiveMCPTools: { [weak testMCPServer] runID in
                    testMCPServer?.hasActiveToolExecutions(runID: runID) ?? false
                },
                hasActiveChildAgentRunWaits: { [weak testMCPServer] runID in
                    testMCPServer?.hasActiveChildAgentRunWaits(runID: runID) ?? false
                }
            )
            self.clearConsumedAttachmentsAfterProviderConsumption = clearConsumedAttachmentsAfterProviderConsumption
            providerBindingService = AgentModeProviderBindingService()
            codexCoordinator.attach(viewModel: self)
            claudeCoordinator.attach(viewModel: self)
            runInteractionStateObserver = codexCoordinator
            testMCPServer?.registerAgentWorktreeBindingsProvider { [weak self] sessionID, tabID in
                guard let self else { return .unavailable }
                return worktreeBindingState(forAgentSessionID: sessionID, tabID: tabID)
            }
            testMCPServer?.registerAgentWorktreeBindingsResolver { [weak self] sessionID, tabID in
                guard let self else { return .unavailable }
                return await resolveWorktreeBindingStateEnsuringOwnership(sessionID: sessionID, tabID: tabID)
            }
            refreshAvailableAgents()
            if usesProductionAgentDefaultsAndModelPolling {
                restoreLastUsedAgentSelectionIfNeeded()
                updateDynamicModelPolling(startCursorPolling: false)
            }
            syncAllActiveUIState()
            scheduleInitialSkillCatalogRefresh()
        }
    #endif

    deinit {
        uiRefreshTask?.cancel()
        openCodeModelsSubscriptionTask?.cancel()
        cursorModelsSubscriptionTask?.cancel()
        skillCatalogDeltaObservationTask?.cancel()
        skillCatalogRefreshDebounceTask?.cancel()
        initialSystemWorkspaceSessionListRefreshDeferralFallbackTask?.cancel()
        for task in workspaceSwitchBackgroundCleanupTasks.values {
            task.cancel()
        }
        workspaceSwitchBackgroundCleanupTasks.removeAll()
        sessionListCacheTask?.cancel()
        sidebarAutoArchiveTask?.cancel()
        sessionListCacheGeneration &+= 1
        let codex = codexCoordinator
        let claude = claudeCoordinator
        Task { @MainActor in
            codex.stop()
            claude.stop()
        }
    }

    lazy var claudeContextUsageEstimator = ClaudeContextUsageEstimator(
        tokenEstimator: { Self.estimateRuntimeTokens(for: $0) },
        contextUsageBuilder: { usage, modelContextWindow in
            Self.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: modelContextWindow)
        }
    )

    lazy var codexContextUsageEstimator = CodexContextUsageEstimator()

    func slashSkillSuggestions(for query: String) async -> [MentionSuggestion] {
        let slashSession: TabSession? = {
            if let activeSession {
                return activeSession
            }
            guard selectedAgent == .codexExec,
                  let tabID = currentTabID
            else {
                return nil
            }
            let ephemeralSession = TabSession(tabID: tabID)
            ephemeralSession.selectedAgent = selectedAgent
            ephemeralSession.runState = runState
            return ephemeralSession
        }()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isExplicitSkillNamespaceQuery = normalizedQuery.hasPrefix("skill:")
        let skillQuery = isExplicitSkillNamespaceQuery
            ? String(query.dropFirst("skill:".count))
            : query
        let nativeSuggestions = isExplicitSkillNamespaceQuery ? [] : (slashSession.map {
            codexCoordinator.nativeSlashCommandSuggestions(
                for: $0,
                query: query,
                limit: Self.slashSkillSuggestionLimit
            )
        } ?? [])
        let nativeNames: Set<String> = slashSession?.selectedAgent == .codexExec
            ? Set(CodexAgentModeCoordinator.NativeSlashCommand.allCases.map { $0.rawValue.lowercased() })
            : []
        await refreshSkillCatalog(force: false)
        let skillSuggestions = skillCatalog.suggestions(prefix: skillQuery, limit: Self.slashSkillSuggestionLimit)
            .prefix(max(0, Self.slashSkillSuggestionLimit - nativeSuggestions.count))
            .map { suggestion in
                let description = suggestion.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseSubtitle = (description?.isEmpty == false) ? description : nil
                let collidesWithNativeCommand = nativeNames.contains(suggestion.name.lowercased())
                let relativePath = collidesWithNativeCommand ? "skill:\(suggestion.name)" : suggestion.name
                let displayName = collidesWithNativeCommand ? "/skill:\(suggestion.name)" : "/\(suggestion.name)"
                let subtitle = collidesWithNativeCommand
                    ? ["Slash skill — use /skill:\(suggestion.name) to bypass Codex native /\(suggestion.name)", baseSubtitle]
                    .compactMap(\.self)
                    .joined(separator: " — ")
                    : baseSubtitle
                return MentionSuggestion(
                    displayName: displayName,
                    relativePath: relativePath,
                    kind: .skill,
                    subtitle: subtitle
                )
            }
        return nativeSuggestions + skillSuggestions
    }

    func effectiveWorkspacePath(for session: TabSession) throws -> String? {
        try Self.effectiveWorkspacePath(
            for: session,
            fallbackWorkspacePath: workspacePathProvider()
        )
    }

    func primaryExecutionBinding(for session: TabSession) -> AgentSessionWorktreeBinding? {
        Self.primaryExecutionBinding(in: session.worktreeBindings, fallbackWorkspacePath: workspacePathProvider())
    }

    func primaryExecutionWorktreeIndicator(forTabID tabID: UUID) -> AgentWorktreeIndicator? {
        if let session = sessions[tabID], let binding = primaryExecutionBinding(for: session) {
            return AgentWorktreeIndicatorResolver.indicator(for: binding.summary)
        }
        let indicators = worktreeIndicators(forTabID: tabID)
        let primaryWorkspacePath = Self.standardizedWorkspacePath(workspacePathProvider())
        return primaryWorkspacePath.flatMap { primaryPath in
            indicators.first { Self.standardizedWorkspacePath($0.logicalRootPath) == primaryPath }
        } ?? (primaryWorkspacePath == nil && indicators.count == 1 ? indicators[0] : nil)
    }

    private static func primaryExecutionBinding(
        in bindings: [AgentSessionWorktreeBinding],
        fallbackWorkspacePath: String?
    ) -> AgentSessionWorktreeBinding? {
        AgentWorktreeRuntimeWorkspaceResolver.primaryExecutionBinding(
            in: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )
    }

    private static func effectiveWorkspacePath(
        for session: TabSession,
        fallbackWorkspacePath: String?
    ) throws -> String? {
        try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: session.worktreeBindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )
    }

    private static func standardizedWorkspacePath(_ path: String?) -> String? {
        AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(path)
    }

    private func currentWorkspacePath() -> String? {
        Self.standardizedWorkspacePath(workspacePathProvider())
    }

    /// Returns all repo paths from the active workspace for skill discovery.
    /// Unlike `currentWorkspacePath()` which returns only the first root,
    /// this returns every loaded root so skills from all directories are discovered.
    private func currentWorkspacePaths() -> [String] {
        guard let paths = workspaceManager?.activeWorkspace?.repoPaths else {
            return currentWorkspacePath().map { [$0] } ?? []
        }
        return paths.compactMap { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
    }

    private func refreshSkillCatalog(force: Bool, agentKind: AgentProviderKind? = nil) async {
        let paths = currentWorkspacePaths()
        let agent = agentKind ?? activeSession?.selectedAgent ?? selectedAgent
        if force {
            await skillCatalog.refresh(workspacePaths: paths, agentKind: agent)
            return
        }
        await skillCatalog.refreshIfNeeded(workspacePaths: paths, agentKind: agent)
    }

    private func scheduleInitialSkillCatalogRefresh() {
        let catalog = skillCatalog
        let paths = currentWorkspacePaths()
        let agent = activeSession?.selectedAgent ?? selectedAgent
        Task {
            await catalog.refresh(workspacePaths: paths, agentKind: agent)
        }
    }

    private func scheduleSkillCatalogRefresh(agentKind: AgentProviderKind? = nil) {
        let agent = agentKind ?? activeSession?.selectedAgent ?? selectedAgent
        skillCatalog.scheduleRefresh(workspacePaths: currentWorkspacePaths(), agentKind: agent)
    }

    // MARK: - Skill catalog FS-delta filtering

    /// Returns `true` when a workspace file-system delta touches a path relevant to skill discovery.
    private func containsSkillPathDelta(_ event: WorkspaceFileSystemDeltaEvent) -> Bool {
        Self.isSkillCatalogRelevant(relativePath: FileSystemDeltaPreparation.standardizedRelativePath(for: event.delta))
    }

    /// Determines whether a relative path falls within a skill or command directory tree.
    ///
    /// Returns `true` for:
    /// - Any `SKILL.md` file (case-insensitive) under `.agents/skills/` or `.claude/skills/`
    /// - Any immediate child directory of those skill roots (covers directory add/remove
    ///   when the `SKILL.md` delta may arrive separately or be coalesced away)
    /// - Any `.md` file under `.claude/commands/` or `.agents/slash/` (legacy flat commands)
    /// - Any immediate child file/directory of those legacy roots
    private static func isSkillCatalogRelevant(relativePath: String) -> Bool {
        let lower = (
            relativePath.hasPrefix("/")
                ? String(relativePath.dropFirst())
                : relativePath
        ).lowercased()

        // Folder-based skill roots (SKILL.md per subdirectory)
        let skillPrefixes = [".agents/skills/", ".claude/skills/"]
        for prefix in skillPrefixes {
            guard lower.hasPrefix(prefix) else { continue }

            // Any SKILL.md anywhere under the skills tree
            if lower.hasSuffix("/skill.md") {
                return true
            }

            // Immediate child directory of the skills root (depth == 1).
            // e.g. ".agents/skills/my-skill" but not ".agents/skills/my-skill/sub/dir"
            let remainder = String(lower.dropFirst(prefix.count))
            let slashCount = remainder.count(where: { $0 == "/" })
            if slashCount == 0, !remainder.isEmpty {
                return true // e.g. ".agents/skills/my-skill"
            }
        }

        // Legacy flat command roots (.md files directly in the directory)
        let legacyPrefixes = [".claude/commands/", ".agents/slash/"]
        for prefix in legacyPrefixes {
            guard lower.hasPrefix(prefix) else { continue }

            let remainder = String(lower.dropFirst(prefix.count))
            // Any immediate child of the legacy root (no nested slashes).
            // Covers .md file add/edit/remove as well as directory-level deltas.
            if !remainder.contains("/"), !remainder.isEmpty {
                return true
            }
        }

        return false
    }

    private func makeRunService() -> AgentModeRunService {
        let dependencies = AgentModeRunService.Dependencies(
            windowID: windowID,
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: acpControllerFactory,
            connectionPolicyInstaller: connectionPolicyInstaller,
            expectedPIDPolicyArmer: { spec in
                guard spec.requiresExpectedAgentPID, let clientName = spec.clientName else {
                    return !spec.requiresExpectedAgentPID
                }
                return await ServerNetworkManager.shared.requireExpectedAgentPIDForPendingPolicy(
                    for: clientName,
                    runID: spec.runID,
                    windowID: spec.windowID
                )
            },
            mcpServerEnabler: mcpServerEnabler,
            workspacePathProvider: { [weak self] session in
                guard let self else { return nil }
                return try effectiveWorkspacePath(for: session)
            },
            codexCoordinator: codexCoordinator,
            claudeCoordinator: claudeCoordinator,
            shouldManageCodexTooling: shouldManageCodexTooling,
            providerRuntimePermissionResolver: { [providerBindingService] agent, profile in
                providerBindingService.runtimePermission(for: agent, profile: profile)
            },
            cancelMCPToolsForRun: { [weak self] runID, reason in
                self?.cancelActiveToolsForRun(runID: runID, reason: reason)
            },
            awaitNoActiveMCPTools: { [weak self] runID in
                guard let self, let mcp = mcpServer else { return }
                try await mcp.awaitNoActiveToolExecutions(runID: runID)
            },
            activeAgentRunWaitQuery: { [weak self] runID in
                self?.mcpServer?.hasActiveChildAgentRunWaits(runID: runID) ?? false
            },
            childAgentRunWaitDrainTimeoutSeconds: Self.childAgentRunWaitDrainTimeoutSeconds
        )
        let hooks = AgentModeRunService.Hooks(
            estimateRuntimeTokens: { text in
                Self.estimateRuntimeTokens(for: text)
            },
            addUserInputTokensToActiveNonCodexTurn: { [weak self] tokens, session in
                self?.addUserInputTokensToActiveNonCodexTurn(tokens, for: session)
            },
            startNonCodexTurnAccountingIfNeeded: { [weak self] session, initialMessage in
                self?.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: initialMessage)
            },
            reserveAttachmentsForTurn: { [weak self] attachments, session in
                self?.reserveAttachmentsForTurn(attachments, session: session)
            },
            markAttachmentsConsumed: { [weak self] session, reservationID in
                self?.markAttachmentsConsumed(for: session, reservationID: reservationID)
            },
            stageConsumedAttachmentFilesForDeferredCleanup: { [weak self] attachments, session in
                self?.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session: session)
            },
            consumeDeferredAttachmentCleanup: { [weak self] session, shouldDeleteFiles in
                self?.consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: shouldDeleteFiles)
            },
            finalizeAttachmentsForTurn: { [weak self] session, reservationID, disposition in
                self?.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: disposition)
            },
            setAgentRunActive: { [weak self] tabID, isActive in
                self?.setAgentRunActive(tabID, isActive: isActive)
            },
            updateBindings: { [weak self] session in
                guard let self else { return }
                updateBindingsFromSession(session)
                handleObservedMCPStateChange(for: session)
            },
            requestUIRefresh: { [weak self] tabID, urgent in
                self?.requestUIRefresh(tabID: tabID, urgent: urgent)
            },
            scheduleSave: { [weak self] tabID in
                self?.scheduleSave(for: tabID)
            },
            notifyAgentTurnComplete: { [weak self] session in
                self?.notifyAgentTurnComplete(for: session)
            },
            handleHeadlessStreamResult: { [weak self] result, session, runID, runAttemptID in
                await self?.handleStreamResult(result, session: session, runID: runID, runAttemptID: runAttemptID)
            },
            buildHeadlessAgentMessage: { [weak self] session, initialMessage, runID, attachments in
                self?.buildHeadlessAgentMessage(
                    session: session,
                    initialMessageForRun: initialMessage,
                    runID: runID,
                    attachments: attachments
                )
                    ?? AgentMessage(systemPrompt: "", userMessage: initialMessage)
            },
            finalizeStreamingItems: { [weak self] session in
                self?.finalizeStreamingItems(in: session)
            },
            finalizePendingToolCalls: { [weak self] session, terminalState in
                _ = self?.finalizePendingToolCalls(
                    in: session,
                    terminalState: terminalState,
                    includeExplicitRepoPromptToolCalls: AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(
                        context: .liveTerminal(agentKind: session.selectedAgent)
                    )
                )
            },
            finalizePendingToolCallsWithUpperBound: { [weak self] session, terminalState, maxSequenceIndexExclusive in
                _ = self?.finalizePendingToolCalls(
                    in: session,
                    terminalState: terminalState,
                    includeExplicitRepoPromptToolCalls: AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(
                        context: .liveTerminal(agentKind: session.selectedAgent)
                    ),
                    maxSequenceIndexExclusive: maxSequenceIndexExclusive
                )
            },
            finalizeNonCodexTurnUsage: { [weak self] session, promptTokens, completionTokens, contextUsedTokens in
                self?.finalizeNonCodexTurnUsageIfNeeded(
                    for: session,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    contextUsedTokens: contextUsedTokens
                )
            },
            cancelPendingQuestion: { [weak self] session in
                self?.cancelPendingQuestion(for: session)
            },
            cancelPendingApproval: { [weak self] session in
                self?.cancelPendingApproval(for: session)
            },
            cancelPendingApplyEditsReview: { [weak self] session, reason in
                self?.cancelPendingApplyEditsReview(for: session, reason: reason)
            },
            cancelPendingWorktreeMergeReview: { [weak self] session, reason in
                self?.cancelPendingWorktreeMergeReview(for: session, reason: reason)
            },
            flushPendingAssistantDelta: { [weak self] session in
                self?.flushPendingAssistantDelta(session)
            },
            clearPendingAssistantDelta: { [weak self] session in
                self?.clearPendingAssistantDelta(session)
            },
            prepareTerminalPublication: { [weak self] session in
                self?.prepareTerminalPublication(for: session)
            },
            makeTerminalPublicationEnvelope: { [weak self] session, ownership, terminalState, providerRunID in
                self?.makeTerminalPublicationEnvelope(
                    for: session,
                    ownership: ownership,
                    terminalState: terminalState,
                    providerRunID: providerRunID
                )
            },
            publishTerminalCommit: { [weak self] session, revision, successorKind in
                guard let self else { return .rejected(reason: "view_model_deallocated") }
                return await publishTerminalCommit(
                    revision,
                    successorKind: successorKind,
                    for: session
                )
            },
            startFollowUpRun: { [weak self] tabID, initialMessage in
                Task { [weak self] in
                    await self?.startAgentRun(tabID: tabID, initialMessage: initialMessage)
                }
            },
            restoreDraftText: { [weak self] tabID, text, message, strategy in
                self?.restoreComposerDraft(tabID: tabID, text: text, message: message, strategy: strategy)
            },
            augmentUserMessageForProviderSend: { [weak self] text, attachments, taggedFileAttachments, session in
                guard let self else { return text }
                return await augmentUserMessageForProviderSend(
                    text,
                    attachments: attachments,
                    taggedFileAttachments: taggedFileAttachments,
                    agent: session?.selectedAgent,
                    session: session
                )
            },
            stageResumeRecoveryHandoffIfNeeded: { [weak self] session in
                await self?.stageResumeRecoveryHandoffIfNeeded(for: session)
            },
            prependPendingHandoffIfNeeded: { [weak self] text, session in
                self?.prependPendingHandoffIfNeeded(text, session: session) ?? text
            },
            recordPendingHandoffSendOutcome: { [weak self] session, didSend in
                self?.recordPendingHandoffSendOutcome(for: session, didSend: didSend)
            },
            signalMCPInstructionDelivered: { [weak self] session in
                await self?.signalMCPInstructionDelivered(for: session)
            }
        )
        let toolTrackingHooks = makeToolTrackingHooks()
        // Wire hooks so per-tab Claude handlers get proper viewmodel callbacks.
        claudeCoordinator.toolTrackingHooks = toolTrackingHooks
        return AgentModeRunService(
            dependencies: dependencies,
            hooks: hooks,
            toolTrackingHooks: toolTrackingHooks
        )
    }

    /// Build the generic orchestration hooks that provider tool tracking handlers need.
    private func makeToolTrackingHooks() -> AgentToolTrackingHooks {
        AgentToolTrackingHooks(
            flushPendingAssistantDelta: { [weak self] session in
                self?.flushPendingAssistantDelta(session)
            },
            endActiveAssistantSegment: { [weak self] session in
                self?.endActiveAssistantSegment(session)
            },
            endActiveReasoningSegment: { [weak self] session in
                self?.endActiveReasoningSegment(session)
            },
            sealAssistantBoundary: { [weak self] session in
                self?.flushPendingAssistantDelta(session)
                self?.endActiveAssistantSegment(session)
            },
            requestUIRefresh: { [weak self] tabID, urgent in
                self?.requestUIRefresh(tabID: tabID, urgent: urgent)
            },
            scheduleSave: { [weak self] tabID in
                self?.scheduleSave(for: tabID)
            },
            addToolInputTokens: { [weak self] payload, session in
                self?.addToolInputTokens(payload, for: session)
            },
            addToolOutputTokens: { [weak self] payload, session in
                self?.addToolOutputTokens(payload, for: session)
            }
        )
    }

    private func setupObservers() {
        guard let promptManager else { return }
        installPromptManagerCascadeResolvers(promptManager)

        // Observe post-storage tab changes. This notification does not replay the current value;
        // setAgentModeActive(true) remains the explicit activation bootstrap.
        NotificationCenter.default.publisher(for: .activeComposeTabChanged)
            .sink { [weak self] notification in
                guard let self,
                      let notificationWindowID = notification.userInfo?["windowID"] as? Int,
                      notificationWindowID == windowID
                else {
                    return
                }
                onTabChanged(notification.userInfo?["tabID"] as? UUID)
            }
            .store(in: &cancellables)

        // Register for tab-close events
        tabCloseListenerToken = promptManager.addComposeTabsWillCloseListener { [weak self] tabIDs, reason in
            guard let self else { return }
            await handleComposeTabsWillClose(tabIDs, reason: reason)
        }

        // Observe workspace changes
        workspaceManager?.addWorkspaceDidSwitchListener(label: "agentMode") { [weak self] workspace in
            guard let self else { return }
            let owner = receiveWorkspaceSwitchNotification(workspace)
            Task { @MainActor in
                await self.handleWorkspaceSwitch(workspace, owner: owner)
            }
        }

        // Save before workspace saves
        workspaceManager?.addBeforeSaveListener { [weak self] _ in
            guard let self else { return }
            persistCurrentSession()
        }

        if let apiSettingsViewModel = promptManager.apiSettingsViewModel {
            // Level-triggered: the current availability is replayed on subscription and
            // later changes arrive deduplicated by value.
            apiSettingsViewModel.$agentAvailability
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.handleAgentProviderAvailabilityChanged()
                }
                .store(in: &cancellables)
        }

        // Observe workspace file-system deltas and invalidate the skill catalog
        // when changes touch skill directories (.agents/skills/ or .claude/skills/).
        // Mark dirty immediately (so any concurrent `refreshIfNeeded` will rescan),
        // then debounce the eager pre-fetch to coalesce bursts (e.g. multi-file installs).
        skillCatalogDeltaObservationTask?.cancel()
        let workspaceFileContextStore = promptManager.workspaceFileContextStore
        skillCatalogDeltaObservationTask = Task { @MainActor [weak self] in
            let stream = await workspaceFileContextStore.fileSystemDeltaEvents()
            for await event in stream {
                guard let self, containsSkillPathDelta(event) else { continue }
                skillCatalog.markDirty(reason: "fs_delta")
                skillCatalogRefreshDebounceTask?.cancel()
                skillCatalogRefreshDebounceTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        self?.scheduleSkillCatalogRefresh()
                    } catch {
                        // Cancellation is expected while coalescing bursts of file-system deltas.
                    }
                }
            }
        }

        workflowStore.$customWorkflows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.revalidateSelectedCustomWorkflows()
            }
            .store(in: &cancellables)
    }

    private func installPromptManagerCascadeResolvers(_ promptManager: PromptViewModel) {
        promptManager.composeTabAutoStashEligibilityProvider = { [weak self] tabID in
            guard let self else { return true }
            return isComposeTabEligibleForAutomaticStash(tabID)
        }
        promptManager.composeTabCascadeResolver = { [weak self] tabIDs, reason in
            guard let self else { return .init() }
            return await MainActor.run {
                self.sessionTreeCascadePlan(forComposeTabIDs: tabIDs, reason: reason)
            }
        }
        promptManager.stashedTabCascadeResolver = { [weak self] stashedTabIDs in
            guard let self else { return .init() }
            return await MainActor.run {
                self.sessionTreeCascadePlan(forStashedTabIDs: stashedTabIDs)
            }
        }
    }

    func isComposeTabEligibleForAutomaticStash(_ tabID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return true }
        guard !session.runState.isActive else { return false }
        guard !tabsWithActiveAgentRun.contains(tabID) else { return false }
        guard session.mcpControlContext == nil else { return false }
        guard !session.hasPendingQuestionUI else { return false }
        guard session.pendingApproval == nil else { return false }
        guard session.pendingPermissionsRequest == nil else { return false }
        guard session.pendingMCPElicitationRequest == nil else { return false }
        guard session.pendingApplyEditsReview == nil else { return false }
        guard session.pendingUserInputRequest == nil else { return false }
        guard session.waitingPrompt == nil else { return false }
        guard session.instructionContinuation == nil else { return false }
        return true
    }

    private func sessionTreeCascadePlan(
        forComposeTabIDs tabIDs: Set<UUID>,
        reason: PromptViewModel.ComposeTabRemovalReason
    ) -> PromptViewModel.AgentSessionCascadePlan {
        let rootSessionIDs = sessionTreeRootSessionIDs(composeTabIDs: tabIDs, stashedTabIDs: [])
        guard !rootSessionIDs.isEmpty else {
            return .init()
        }
        let nodes = sessionTreeNodes()
        let descendantSessionIDs = descendantSessionTreeIDs(startingWith: rootSessionIDs, nodes: nodes)
        var composeDescendantTabIDs: Set<UUID> = []
        var stashedDescendantTabIDs: Set<UUID> = []
        for sessionID in descendantSessionIDs {
            guard let node = nodes[sessionID] else { continue }
            composeDescendantTabIDs.formUnion(node.composeTabIDs)
            if reason == .close {
                stashedDescendantTabIDs.formUnion(node.stashedTabIDs)
            }
        }
        composeDescendantTabIDs.subtract(tabIDs)
        return .init(
            composeTabIDs: composeDescendantTabIDs,
            stashedTabIDs: stashedDescendantTabIDs
        )
    }

    private func sessionTreeCascadePlan(
        forStashedTabIDs stashedTabIDs: Set<UUID>
    ) -> PromptViewModel.AgentSessionCascadePlan {
        let rootSessionIDs = sessionTreeRootSessionIDs(composeTabIDs: [], stashedTabIDs: stashedTabIDs)
        guard !rootSessionIDs.isEmpty else {
            return .init()
        }
        let nodes = sessionTreeNodes()
        let descendantSessionIDs = descendantSessionTreeIDs(startingWith: rootSessionIDs, nodes: nodes)
        var composeDescendantTabIDs: Set<UUID> = []
        var stashedDescendantTabIDs: Set<UUID> = []
        for sessionID in descendantSessionIDs {
            guard let node = nodes[sessionID] else { continue }
            composeDescendantTabIDs.formUnion(node.composeTabIDs)
            stashedDescendantTabIDs.formUnion(node.stashedTabIDs)
        }
        stashedDescendantTabIDs.subtract(stashedTabIDs)
        return .init(
            composeTabIDs: composeDescendantTabIDs,
            stashedTabIDs: stashedDescendantTabIDs
        )
    }

    private func sessionTreeRootSessionIDs(
        composeTabIDs: Set<UUID>,
        stashedTabIDs: Set<UUID>
    ) -> Set<UUID> {
        let currentWorkspace = workspaceManager?.activeWorkspace ?? lastKnownWorkspaceSnapshot
        let composeTabsByID = Dictionary(
            uniqueKeysWithValues: (promptManager?.currentComposeTabs ?? currentWorkspace?.composeTabs ?? [])
                .map { ($0.id, $0) }
        )
        let stashedTabsByID = Dictionary(
            uniqueKeysWithValues: (currentWorkspace?.stashedTabs ?? [])
                .map { ($0.id, $0) }
        )
        var rootSessionIDs: Set<UUID> = []
        for tabID in composeTabIDs {
            let composeTab = composeTabsByID[tabID]
            if let sessionID = composeTab.flatMap({ authoritativeSessionID(for: $0) })
                ?? preferredSidebarEntry(for: tabID, tabName: composeTab?.name)?.id
            {
                rootSessionIDs.insert(sessionID)
            }
        }
        for stashedTabID in stashedTabIDs {
            guard let stashedTab = stashedTabsByID[stashedTabID] else { continue }
            if let sessionID = authoritativeSessionID(for: stashedTab.tab)
                ?? preferredSidebarEntry(for: stashedTab.tab.id, tabName: stashedTab.tab.name)?.id
            {
                rootSessionIDs.insert(sessionID)
            }
        }
        return rootSessionIDs
    }

    private func sessionTreeNodes() -> [UUID: SessionTreeNode] {
        let currentWorkspace = workspaceManager?.activeWorkspace ?? lastKnownWorkspaceSnapshot
        let composeTabs = promptManager?.currentComposeTabs ?? currentWorkspace?.composeTabs ?? []
        let stashedTabs = currentWorkspace?.stashedTabs ?? []
        let validComposeTabIDs = Set(composeTabs.map(\.id))
        let validStashedTabIDs = Set(stashedTabs.map(\.tab.id))
        let allTabs = composeTabs + stashedTabs.map(\.tab)
        var explicitSessionIDByTabID: [UUID: UUID] = [:]
        var explicitTabIDBySessionID: [UUID: UUID] = [:]
        for tab in allTabs {
            guard let sessionID = authoritativeSessionID(for: tab) else { continue }
            explicitSessionIDByTabID[tab.id] = sessionID
            explicitTabIDBySessionID[sessionID] = tab.id
        }
        var nodes: [UUID: SessionTreeNode] = [:]

        func merge(
            sessionID: UUID,
            parentSessionID: UUID?,
            composeTabID: UUID? = nil,
            stashedTabID: UUID? = nil
        ) {
            var node = nodes[sessionID] ?? SessionTreeNode()
            if node.parentSessionID == nil,
               let parentSessionID,
               parentSessionID != sessionID
            {
                node.parentSessionID = parentSessionID
            }
            if let composeTabID {
                node.composeTabIDs.insert(composeTabID)
            }
            if let stashedTabID {
                node.stashedTabIDs.insert(stashedTabID)
            }
            nodes[sessionID] = node
        }

        for session in sessions.values where validComposeTabIDs.contains(session.tabID) {
            guard let sessionID = session.activeAgentSessionID else { continue }
            if let explicitSessionID = explicitSessionIDByTabID[session.tabID],
               explicitSessionID != sessionID
            {
                continue
            }
            merge(
                sessionID: sessionID,
                parentSessionID: session.hasLoadedPersistedState ? session.parentSessionID : nil,
                composeTabID: session.tabID
            )
        }
        for entry in ownerValidatedSessionIndex.values {
            guard validComposeTabIDs.contains(entry.tabID) || validStashedTabIDs.contains(entry.tabID) else {
                continue
            }
            if let explicitSessionID = explicitSessionIDByTabID[entry.tabID],
               explicitSessionID != entry.id
            {
                continue
            }
            if let explicitTabID = explicitTabIDBySessionID[entry.id],
               explicitTabID != entry.tabID
            {
                continue
            }
            merge(
                sessionID: entry.id,
                parentSessionID: entry.parentSessionID,
                composeTabID: validComposeTabIDs.contains(entry.tabID) ? entry.tabID : nil
            )
        }
        for tab in composeTabs {
            if let sessionID = explicitSessionIDByTabID[tab.id]
                ?? preferredSidebarEntry(for: tab.id, tabName: tab.name)?.id
            {
                merge(sessionID: sessionID, parentSessionID: nil, composeTabID: tab.id)
            }
        }
        for stashedTab in stashedTabs {
            if let sessionID = explicitSessionIDByTabID[stashedTab.tab.id]
                ?? preferredSidebarEntry(for: stashedTab.tab.id, tabName: stashedTab.tab.name)?.id
            {
                merge(sessionID: sessionID, parentSessionID: nil, stashedTabID: stashedTab.id)
            }
        }
        return nodes
    }

    private func descendantSessionTreeIDs(
        startingWith rootSessionIDs: Set<UUID>,
        nodes: [UUID: SessionTreeNode]
    ) -> Set<UUID> {
        guard !rootSessionIDs.isEmpty else { return [] }
        var childrenByParent: [UUID: Set<UUID>] = [:]
        for (sessionID, node) in nodes {
            guard let parentSessionID = node.parentSessionID,
                  parentSessionID != sessionID
            else {
                continue
            }
            childrenByParent[parentSessionID, default: []].insert(sessionID)
        }
        var visited: Set<UUID> = []
        var stack = Array(rootSessionIDs)
        while let sessionID = stack.popLast() {
            guard visited.insert(sessionID).inserted else { continue }
            if let children = childrenByParent[sessionID] {
                stack.append(contentsOf: children)
            }
        }
        return visited
    }

    static func reconciledCustomWorkflowSelection(
        _ selectedWorkflow: AgentWorkflowDefinition?,
        against customWorkflows: [AgentWorkflowDefinition]
    ) -> AgentWorkflowDefinition? {
        guard let selectedWorkflow else { return nil }
        guard let customID = selectedWorkflow.customID else {
            return selectedWorkflow
        }
        return customWorkflows.first(where: { $0.customID == customID }) ?? selectedWorkflow
    }

    private static func pendingUserTurnState(from session: TabSession?) -> PendingUserTurnState {
        PendingUserTurnState(
            workflow: session?.selectedWorkflow,
            imageAttachments: session?.pendingImageAttachments ?? [],
            taggedFileAttachments: session?.pendingTaggedFileAttachments ?? [],
            initialStartLocation: session?.pendingInitialStartLocation ?? .local
        )
    }

    private func installPendingUserTurnState(_ pendingState: PendingUserTurnState, on destinationSession: TabSession) {
        #if DEBUG
            assert(
                destinationSession.selectedWorkflow == nil
                    && destinationSession.pendingImageAttachments.isEmpty
                    && destinationSession.pendingTaggedFileAttachments.isEmpty,
                "installPendingUserTurnState should only target a fresh destination session"
            )
        #endif
        destinationSession.selectedWorkflow = pendingState.workflow
        destinationSession.pendingImageAttachments = pendingState.imageAttachments
        destinationSession.pendingTaggedFileAttachments = pendingState.taggedFileAttachments
        destinationSession.pendingInitialStartLocation = pendingState.initialStartLocation
    }

    private func clearPendingUserTurnState(on session: TabSession?) {
        session?.selectedWorkflow = nil
        session?.pendingImageAttachments.removeAll()
        session?.pendingTaggedFileAttachments.removeAll()
        session?.pendingInitialStartLocation = .local
    }

    private func revalidateSelectedCustomWorkflows() {
        var didUpdateCurrentTab = false
        for (tabID, session) in sessions {
            guard let reconciledWorkflow = Self.reconciledCustomWorkflowSelection(
                session.selectedWorkflow,
                against: workflowStore.customWorkflows
            ) else {
                continue
            }
            guard reconciledWorkflow != session.selectedWorkflow else { continue }

            session.selectedWorkflow = reconciledWorkflow
            if tabID == currentTabID {
                selectedWorkflow = reconciledWorkflow
                didUpdateCurrentTab = true
            }
            scheduleSave(for: tabID)
        }
        if didUpdateCurrentTab {
            syncStatusPillsUIState()
        }
    }

    func deferInitialSystemWorkspaceSessionListRefresh(reason: String) {
        initialSystemWorkspaceSessionListRefreshDeferralReason = reason
        initialSystemWorkspaceSessionListRefreshDeferralFallbackTask?.cancel()
        initialSystemWorkspaceSessionListRefreshDeferralFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            self?.finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: true)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "agentSessionIndex.initialSystemRefreshDeferral armed windowID=\(windowID) reason=\(reason) fallbackMS=10000"
            )
        #endif
    }

    func finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: Bool = true) {
        guard let reason = initialSystemWorkspaceSessionListRefreshDeferralReason else { return }
        initialSystemWorkspaceSessionListRefreshDeferralFallbackTask?.cancel()
        initialSystemWorkspaceSessionListRefreshDeferralFallbackTask = nil
        initialSystemWorkspaceSessionListRefreshDeferralReason = nil
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "agentSessionIndex.initialSystemRefreshDeferral cleared windowID=\(windowID) reason=\(reason) refreshIfStillSystem=\(refreshIfStillSystem)"
            )
        #endif
        guard refreshIfStillSystem,
              isAgentModeActive,
              workspaceManager?.isSwitchingWorkspace != true,
              let workspace = workspaceManager?.activeWorkspace,
              workspace.isSystemWorkspace
        else {
            return
        }
        guard let owner = sessionIndexOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return
        }
        setSessionListCacheReady(false, for: owner)
        refreshSessionListCache(for: workspace, owner: owner)
    }

    /// Toggle whether agent mode UI is active (used to defer heavy session loads).
    func setAgentModeActive(_ isActive: Bool) {
        #if DEBUG
            let activationStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let activationCount = isActive ? WorkspaceRestorePerfLog.nextAgentActivationTrueCount() : nil
            let workspaceIDForLog = workspaceManager?.activeWorkspace?.id
        #endif
        isAgentModeActive = isActive
        guard isActive else {
            #if DEBUG
                WorkspaceRestorePerfLog.log(
                    "agentActivation.inactive windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspaceIDForLog))"
                )
            #endif
            codexCoordinator.stop()
            claudeCoordinator.stop()
            stopOpenCodeModelsSubscription()
            stopCursorModelsSubscription()
            sidebarAutoArchiveTask?.cancel()
            sidebarAutoArchiveTask = nil
            cancelSessionIndexRefresh(releaseFrozenOrder: true)
            return
        }
        lastProcessedTabID = nil
        let targetTabID = pendingTabIDForLoad ?? currentTabID
        #if DEBUG
            let targetTabIDForLog = targetTabID?.uuidString.prefix(8).description ?? "nil"
            WorkspaceRestorePerfLog.log(
                "agentActivation.begin windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspaceIDForLog)) activationTrueCount=\(activationCount ?? 0) targetTabID=\(targetTabIDForLog) sessionCount=\(sessions.count) indexedSessionCount=\(sessionIndex.count)"
            )
        #endif
        pendingTabIDForLoad = nil
        activeSessionLoadInProgressTabID = targetTabID
        if let workspace = workspaceManager?.activeWorkspace,
           let owner = sessionIndexOwner,
           isSessionIndexOwnerCurrent(owner),
           owner.workspaceID == workspace.id
        {
            setSessionListCacheReady(false, for: owner)
            refreshSessionListCache(for: workspace, owner: owner)
        }
        #if DEBUG
            let tabChangeStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        onTabChanged(targetTabID)
        #if DEBUG
            if let activationStartMS {
                let tabChangeDuration = tabChangeStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                WorkspaceRestorePerfLog.log(
                    "agentActivation.end windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspaceIDForLog)) activationTrueCount=\(activationCount ?? 0) targetTabID=\(targetTabIDForLog) onTabChanged=\(tabChangeDuration) total=\(WorkspaceRestorePerfLog.formatElapsedMS(since: activationStartMS))"
                )
            }
        #endif
    }

    func prepareForWindowClose() async {
        guard !hasPreparedForWindowClose else { return }
        hasPreparedForWindowClose = true
        codexCoordinator.stop()
        claudeCoordinator.stop()
        stopOpenCodeModelsSubscription()
        stopCursorModelsSubscription()
        sidebarAutoArchiveTask?.cancel()
        sidebarAutoArchiveTask = nil
        uiRefreshTask?.cancel()
        uiRefreshTask = nil
        pendingUIRefreshScopesByTabID.removeAll()
        pendingAssistantPresentationByTabID.removeAll()
        cancelSessionIndexRefresh(releaseFrozenOrder: true)
        let tabIDs = Array(sessions.keys)
        await withTaskGroup(of: Void.self) { group in
            for tabID in tabIDs {
                group.addTask { @MainActor [weak self] in
                    guard let self, let session = sessions[tabID] else { return }
                    await prepareSessionForWindowClose(session)
                }
            }
        }
        await applyEditsApprovalStore.cleanupWindowScopes(
            windowID: windowID,
            reason: "Cancelled because window is closing"
        )
    }

    private func prepareSessionForWindowClose(_ session: TabSession) async {
        removePendingUIRefresh(for: session.tabID)
        cancelPersistedLoad(for: session)
        session.derivedTranscriptRefreshTask?.cancel()
        session.derivedTranscriptRefreshTask = nil
        session.pendingDerivedTranscriptRefreshReason = nil
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningByKey.removeAll()
        cancelPendingQuestion(for: session)
        cancelPendingApproval(for: session)
        cancelPendingApplyEditsReview(for: session, reason: "Cancelled because window is closing")
        await teardownApplyEditsApprovalSessionSync(for: session, cleanupScope: true)
        cancelPendingInstruction(for: session)
        await teardownMCPControl(for: session, cleanupSessionStore: true)
        session.agentTask?.cancel()
        session.agentTask = nil
        let provider = session.provider
        session.provider = nil
        if let provider {
            await provider.dispose()
        }
        await codexCoordinator.shutdownCodexSession(session)
        await claudeCoordinator.shutdownClaudeSession(session)
        let sessionID = boundSessionID(for: session.tabID)
        await cleanupMCPRunRoutingIfPresent(
            boundSessionID: sessionID,
            liveSession: session,
            reason: "window_close"
        )
        await releaseSessionWorktreeOwnership(sessionID: sessionID)
    }

    // MARK: - Tab Management

    private func onTabChanged(_ tabID: UUID?, allowDuringWorkspaceSwitch: Bool = false) {
        sessionActivationGeneration &+= 1
        let activationGeneration = sessionActivationGeneration
        let shouldDeferForWorkspaceSwitch = !allowDuringWorkspaceSwitch && workspaceManager?.isSwitchingWorkspace == true
        // Opening a session is the canonical "I've seen it" interaction —
        // clear any unseen-run-state badge the sidebar had queued for it.
        // Runs for every tab activation path (click, keyboard shortcut,
        // programmatic switch, deep link), not just sidebar row selection.
        if let tabID {
            acknowledgeSidebarRunAttention(tabID: tabID)
        }

        guard let tabID else {
            if workspaceSwitchInFlight || shouldDeferForWorkspaceSwitch {
                pendingTabIDForLoad = nil
                publishLoadingTranscriptPresentation(tabID: nil)
                return
            }
            activeSessionLoadInProgressTabID = nil
            clearBindings()
            return
        }

        if shouldDeferForWorkspaceSwitch {
            pendingTabIDForLoad = tabID
            activeSessionLoadInProgressTabID = tabID
            publishLoadingTranscriptPresentation(tabID: tabID)
            return
        }

        guard isAgentModeActive else {
            pendingTabIDForLoad = tabID
            return
        }

        guard lastProcessedTabID != tabID else { return }
        lastProcessedTabID = tabID

        guard let session = session(for: tabID, createIfNeeded: false) else {
            if workspaceSwitchInFlight,
               !allowDuringWorkspaceSwitch,
               workspaceManager?.composeTab(with: tabID) == nil
            {
                activeSessionLoadInProgressTabID = tabID
                publishLoadingTranscriptPresentation(tabID: tabID)
                return
            }
            workspaceSwitchInFlight = false
            // No bound agent session for this tab yet.
            activeSessionLoadInProgressTabID = nil
            clearBindings()
            return
        }

        guard !session.hasLoadedPersistedState else {
            workspaceSwitchInFlight = false
            activeSessionLoadInProgressTabID = nil
            applySessionToBindings(session)
            return
        }

        activeSessionLoadInProgressTabID = tabID
        publishLoadingTranscriptPresentation(tabID: tabID)
        applySessionToBindings(session)
        Task { [weak self] in
            guard let self else { return }
            await loadSessionFromDisk(for: session)
            guard sessionActivationGeneration == activationGeneration else { return }
            guard currentTabID == tabID else { return }
            guard sessions[tabID] === session else { return }
            workspaceSwitchInFlight = false
            applySessionToBindings(session)
            activeSessionLoadInProgressTabID = nil
            if session.selectedAgent == .codexExec, session.runState.isActive {
                await codexCoordinator.ensureCodexNativeSession(session: session)
            }
            if session.selectedAgent.usesClaudeNativeRuntime, session.runState.isActive {
                await claudeCoordinator.ensureClaudeNativeSession(session: session)
            }
        }
    }

    func authoritativeSessionID(for tab: ComposeTabState) -> UUID? {
        sessions[tab.id]?.activeAgentSessionID ?? tab.activeAgentSessionID
    }

    func explicitActiveSessionID(for tabID: UUID) -> UUID? {
        if let sessionID = sessions[tabID]?.activeAgentSessionID {
            return sessionID
        }
        if let tabSessionID = workspaceManager?.composeTab(with: tabID)?.activeAgentSessionID {
            return tabSessionID
        }
        if let tabSessionID = workspaceManager?.activeAgentSessionID(forTabID: tabID) {
            return tabSessionID
        }
        let canUseWorkspaceSnapshot = workspaceSwitchInFlight
            || workspaceManager?.isSwitchingWorkspace == true
            || workspaceManager == nil
        guard canUseWorkspaceSnapshot else {
            return nil
        }
        if let tabSessionID = lastKnownWorkspaceSnapshot?.composeTabs.first(where: { $0.id == tabID })?.activeAgentSessionID {
            return tabSessionID
        }
        if let tabSessionID = lastKnownWorkspaceSnapshot?.stashedTabs.first(where: { $0.tab.id == tabID })?.tab.activeAgentSessionID {
            return tabSessionID
        }
        return nil
    }

    func composerSourceAgentSessionID(tabID: UUID, session: TabSession?) -> UUID? {
        session?.activeAgentSessionID ?? explicitActiveSessionID(for: tabID)
    }

    private func preferredSidebarSessionID(for tabID: UUID) -> UUID? {
        preferredSidebarEntry(for: tabID)?.id
    }

    func boundSessionID(for tabID: UUID) -> UUID? {
        explicitActiveSessionID(for: tabID) ?? preferredSidebarSessionID(for: tabID)
    }

    func agentWorkspaceLookupContextIdentity(tabID: UUID?, session: TabSession? = nil) -> AgentWorkspaceLookupContextIdentity {
        guard let tabID else {
            return AgentWorkspaceLookupContextSource(activeAgentSessionID: nil, worktreeBindings: []).identity
        }
        let resolvedSession = session ?? sessions[tabID]
        return AgentWorkspaceLookupContextSource(
            activeAgentSessionID: composerSourceAgentSessionID(tabID: tabID, session: resolvedSession),
            worktreeBindings: resolvedSession?.worktreeBindings ?? []
        ).identity
    }

    func activeAgentWorkspaceLookupContext() async -> WorkspaceLookupContext {
        guard let tabID = currentTabID else { return .visibleWorkspace }
        return await agentWorkspaceLookupContext(tabID: tabID, session: sessions[tabID])
    }

    func agentWorkspaceLookupContext(tabID: UUID, session: TabSession? = nil) async -> WorkspaceLookupContext {
        guard let store = promptManager?.workspaceFileContextStore else { return .visibleWorkspace }
        let resolvedSession = session ?? sessions[tabID]
        guard resolvedSession?.worktreeBindingTransitionInProgress != true else {
            return .visibleWorkspace
        }
        let source = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: composerSourceAgentSessionID(tabID: tabID, session: resolvedSession),
            worktreeBindings: resolvedSession?.worktreeBindings ?? []
        )
        return await AgentWorkspaceLookupContextResolver.lookupContext(source: source, store: store)
    }

    private func makeSession(for tabID: UUID) -> TabSession {
        let newSession = TabSession(tabID: tabID)
        newSession.onSourceItemsChanged = { [weak self] session, mutation in
            guard let self else { return }
            if mutation.touchesUserItem {
                invalidateSidebarRestoreOrdering()
            }
            // Source items are the canonical mutable session data. Schedule
            // persistence from the source mutation itself so inactive presentation
            // deferral cannot make durability depend on derived UI refresh work.
            scheduleSave(for: session.tabID)
            scheduleDerivedTranscriptRefresh(for: session, reason: .liveMutation, mutation: mutation)
        }
        newSession.onRunStateChanged = { [weak self] session in
            guard let self else { return }
            if !session.runState.isActive {
                completeNextAgentTurnRuntimeFooterIfNeeded(for: session, endedAt: Date())
            }
            persistRunStateTransitionIfNeeded(for: session)
            republishTranscriptPresentationForRunStateChangeIfNeeded(session)
        }
        // Initialize new session with current UI selection
        newSession.selectedAgent = selectedAgent
        newSession.selectedModelRaw = selectedModelRaw
        newSession.selectedReasoningEffortRaw = selectedReasoningEffortRaw
        newSession.autoEditEnabled = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
        if let sessionID = explicitActiveSessionID(for: tabID),
           let indexEntry = ownerValidatedSessionIndex[sessionID]
        {
            seedUnhydratedSession(newSession, from: indexEntry)
        }
        if let draft = tabDraftText.removeValue(forKey: tabID) {
            newSession.draftText = draft
        }
        configureMCPStateObservation(for: newSession)
        return newSession
    }

    private func persistRunStateTransitionIfNeeded(for session: TabSession) {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return }
        guard session.hasLoadedPersistedState else { return }
        guard !isRestoringState else { return }
        switch session.runState {
        case .idle:
            return
        case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval, .completed, .cancelled, .failed:
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
    }

    func agentMessageRuntimeFooters(for tabID: UUID?) -> [UUID: AgentMessageRuntimeFooter] {
        guard let tabID,
              let session = sessions[tabID]
        else {
            return [:]
        }
        return session.agentMessageRuntimeFootersByItemID
    }

    private func recordAgentTurnUserAnchor(for session: TabSession, userItem: AgentChatItem) {
        if session.runState == .running {
            completeNextAgentTurnRuntimeFooterIfNeeded(
                for: session,
                endedAt: userItem.timestamp,
                maxSequenceIndexExclusive: userItem.sequenceIndex
            )
        }

        if shouldRestartActiveAgentRunElapsedTimer(for: session) {
            restartActiveAgentRunElapsedTimer(for: session, startedAt: userItem.timestamp)
        }

        let anchor = TabSession.AgentTurnRuntimeAnchor(
            userItemID: userItem.id,
            userSequenceIndex: userItem.sequenceIndex,
            startedAt: userItem.timestamp
        )
        if session.runState == .waitingForUser,
           !session.pendingTurnRuntimeAnchors.isEmpty
        {
            completeNextAgentTurnRuntimeFooterIfNeeded(
                for: session,
                endedAt: userItem.timestamp,
                maxSequenceIndexExclusive: userItem.sequenceIndex
            )
        }
        session.pendingTurnRuntimeAnchors.append(anchor)
    }

    private func shouldRestartActiveAgentRunElapsedTimer(for session: TabSession) -> Bool {
        session.runState == .running
    }

    private func restartActiveAgentRunElapsedTimer(for session: TabSession, startedAt: Date) {
        guard session.activeAgentRunStartedAt != startedAt else { return }
        session.activeAgentRunStartedAt = startedAt
        publishActiveAgentRunStartedAt(for: session.tabID, session: session)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func completeNextAgentTurnRuntimeFooterIfNeeded(
        for session: TabSession,
        endedAt: Date,
        maxSequenceIndexExclusive explicitMaxSequenceIndexExclusive: Int? = nil
    ) {
        guard !session.pendingTurnRuntimeAnchors.isEmpty else { return }
        let anchor = session.pendingTurnRuntimeAnchors.removeFirst()
        let nextAnchorUpperBound = session.pendingTurnRuntimeAnchors.first?.userSequenceIndex
        let upperBound = explicitMaxSequenceIndexExclusive ?? nextAnchorUpperBound
        guard let target = session.items.last(where: { item in
            guard item.sequenceIndex > anchor.userSequenceIndex else { return false }
            if let upperBound, item.sequenceIndex >= upperBound { return false }
            return item.hasDisplayableAssistantBody
        }) else {
            return
        }
        session.agentMessageRuntimeFootersByItemID[target.id] = AgentMessageRuntimeFooter(
            itemID: target.id,
            anchorDate: anchor.startedAt,
            completedDate: max(endedAt, anchor.startedAt),
            statusText: "Worked for"
        )
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func prepareSessionForRunStart(tabID: UUID, session: TabSession) async {
        if session.activeAgentSessionID == nil,
           let explicitSessionID = explicitActiveSessionID(for: tabID)
        {
            _ = installPersistentSessionBinding(
                sessionID: explicitSessionID,
                on: session,
                updateWorkspaceMetadata: false,
                invalidateAsyncWork: false
            )
        }

        guard session.activeAgentSessionID != nil else {
            return
        }

        if !session.hasLoadedPersistedState {
            await loadSessionFromDisk(for: session)
        }
    }

    func session(for tabID: UUID, createIfNeeded: Bool) -> TabSession? {
        if let existing = sessions[tabID] {
            ensureApplyEditsApprovalSessionSync(for: existing)
            return existing
        }
        let explicitSessionID = explicitActiveSessionID(for: tabID)
        guard createIfNeeded || explicitSessionID != nil else {
            return nil
        }
        let newSession = makeSession(for: tabID)
        if let explicitSessionID {
            _ = installPersistentSessionBinding(
                sessionID: explicitSessionID,
                on: newSession,
                updateWorkspaceMetadata: false,
                invalidateAsyncWork: false
            )
        }
        newSession.hasLoadedPersistedState = newSession.activeAgentSessionID == nil
        seedSortMetadataForUnhydratedSession(newSession, tabID: tabID)
        sessions[tabID] = newSession
        ensureApplyEditsApprovalSessionSync(for: newSession)
        return newSession
    }

    private func seedSortMetadataForUnhydratedSession(_ session: TabSession, tabID: UUID) {
        guard session.activeAgentSessionID != nil, !session.hasLoadedPersistedState else { return }
        if let sessionID = session.activeAgentSessionID,
           let indexEntry = ownerValidatedSessionIndex[sessionID]
        {
            seedUnhydratedSession(session, from: indexEntry)
        }
        if let cachedLastUserMessageAt = ownerValidatedSessionListSortDates[tabID] {
            session.lastUserMessageAt = cachedLastUserMessageAt
        }
        if let tabLastModified = promptManager?.currentComposeTabs.first(where: { $0.id == tabID })?.lastModified
            ?? workspaceManager?.composeTab(with: tabID)?.lastModified
        {
            session.lastActivityAt = tabLastModified
        }
    }

    private func seedUnhydratedSession(_ session: TabSession, from indexEntry: AgentSessionIndexEntry) {
        let normalizedSelection = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: indexEntry.agentKindRaw,
            modelRaw: indexEntry.agentModelRaw
        )
        session.selectedAgent = normalizedSelection.agent
        session.selectedModelRaw = normalizedSelection.modelRaw
        session.selectedReasoningEffortRaw = indexEntry.agentReasoningEffortRaw
        session.autoEditEnabled = indexEntry.autoEditEnabled
    }

    func applyTranscriptViewportBindingState(
        to session: TabSession,
        viewportState: AgentTranscriptViewportState,
        armingState: AgentTranscriptAutoFollowArmingState? = nil
    ) {
        let nextArmingState = armingState ?? session.transcriptAutoFollowArmingState
        guard session.transcriptViewportState != viewportState
            || session.transcriptAutoFollowArmingState != nextArmingState
        else {
            return
        }
        session.transcriptViewportState = viewportState
        session.transcriptAutoFollowArmingState = nextArmingState
        guard session.tabID == currentTabID else { return }
        updateBindingsFromSession(session)
    }

    func cancelPersistedLoad(for session: TabSession) {
        session.persistedLoadTask?.cancel()
        session.persistedLoadTask = nil
    }

    func markSessionAsFreshlyCreated(_ session: TabSession) {
        cancelPersistedLoad(for: session)
        session.hasLoadedPersistedState = true
        session.lastActivityAt = Date()
        session.lastUserMessageAt = nil
        session.parentSessionID = nil
        session.worktreeBindings = []
        session.worktreeMergeOperations = []
        sessionListSortDates.removeValue(forKey: session.tabID)
        if currentTabID == session.tabID {
            activeSessionLoadInProgressTabID = nil
            workspaceSwitchInFlight = false
            setActiveTranscriptBindingsHydrated(true)
        }
    }

    func session(for tabID: UUID) -> TabSession {
        if let existing = session(for: tabID, createIfNeeded: true) {
            return existing
        }
        let fallback = makeSession(for: tabID)
        sessions[tabID] = fallback
        ensureApplyEditsApprovalSessionSync(for: fallback)
        return fallback
    }

    func applyEditsScope(for tabID: UUID) -> ApplyEditsApprovalScope {
        ApplyEditsApprovalScope(windowID: windowID, tabID: tabID)
    }

    private func ensureApplyEditsApprovalSessionSync(for session: TabSession) {
        guard session.applyEditsApprovalSubscriptionTask == nil else { return }
        let tabID = session.tabID
        let scope = applyEditsScope(for: tabID)
        let initialAutoEditEnabled = session.autoEditEnabled
        let approvalStore = applyEditsApprovalStore
        session.applyEditsApprovalSubscriptionTask = Task { [weak self] in
            await approvalStore.setAutoEditEnabled(
                initialAutoEditEnabled,
                for: scope,
                updateGlobalDefault: false
            )
            let (subscriptionID, stream) = await approvalStore.subscribe(scope: scope)
            await MainActor.run { [weak self] in
                guard let self, let liveSession = sessions[tabID] else { return }
                liveSession.applyEditsApprovalSubscriptionID = subscriptionID
            }
            for await snapshot in stream {
                await MainActor.run { [weak self] in
                    guard let self, let liveSession = sessions[tabID] else { return }
                    applyEditsApprovalSnapshot(snapshot, to: liveSession)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, let liveSession = sessions[tabID] else { return }
                liveSession.applyEditsApprovalSubscriptionID = nil
                liveSession.applyEditsApprovalSubscriptionTask = nil
            }
        }
    }

    private func applyEditsApprovalSnapshot(
        _ snapshot: ApplyEditsApprovalSnapshot,
        to session: TabSession
    ) {
        let autoEditChanged = session.autoEditEnabled != snapshot.autoEditEnabled
        session.autoEditEnabled = snapshot.autoEditEnabled
        if autoEditChanged, session.mcpControlContext == nil {
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
        if session.tabID == currentTabID {
            refreshAutoEditPermissionGuidanceForActiveSession()
        }

        session.pendingApplyEditsReview = snapshot.pendingReview
        reconcileInteractiveRunState(session)

        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    func reconcileInteractiveRunState(_ session: TabSession) {
        let nextState: AgentSessionRunState? = if session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil || session.pendingApproval != nil || session.pendingPermissionsRequest != nil || session.pendingMCPElicitationRequest != nil {
            .waitingForApproval
        } else if session.hasPendingQuestionUI {
            .waitingForQuestion
        } else if session.waitingPrompt != nil || session.instructionContinuation != nil {
            .waitingForUser
        } else if session.runState.isActive,
                  session.runState == .waitingForApproval
                  || session.runState == .waitingForQuestion
                  || session.runState == .waitingForUser
        {
            .running
        } else {
            nil
        }

        guard let nextState else { return }
        session.runState = nextState
        if nextState == .waitingForApproval || nextState == .waitingForQuestion || nextState == .waitingForUser {
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus(nil, source: nil)
        }
    }

    private func teardownApplyEditsApprovalSessionSync(
        for session: TabSession,
        cleanupScope: Bool
    ) async {
        session.applyEditsApprovalSubscriptionTask?.cancel()
        session.applyEditsApprovalSubscriptionTask = nil
        let scope = applyEditsScope(for: session.tabID)
        if let subscriptionID = session.applyEditsApprovalSubscriptionID {
            session.applyEditsApprovalSubscriptionID = nil
            await applyEditsApprovalStore.unsubscribe(scope: scope, id: subscriptionID)
        }
        if cleanupScope {
            await applyEditsApprovalStore.cleanupScope(scope)
        }
    }

    private func handleSidebarRefreshBindingMutation(
        tabID: UUID,
        sessionID: UUID?
    ) {
        guard let token = activeSessionIndexRefreshToken,
              isSessionIndexOwnerCurrent(token.owner),
              activeSessionIndexRefreshValidTabIDs.contains(tabID)
        else {
            return
        }
        let expectedSessionID = activeSessionIndexRefreshBoundSessionIDByTabID[tabID]
        guard expectedSessionID != sessionID else { return }

        let workspace = currentWorkspaceSnapshot(for: token.owner)
            ?? activeSessionIndexRefreshWorkspace
        cancelSessionIndexRefresh(releaseFrozenOrder: false, owner: token.owner)
        setSessionListCacheReady(false, for: token.owner)
        guard let workspace,
              workspace.id == token.owner.workspaceID,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            releaseSidebarRestoreFrozenOrder(for: token.owner)
            return
        }
        refreshSessionListCache(for: workspace, owner: token.owner)
    }

    /// Single mutation path for the runtime binding between a compose tab and a
    /// persistent Agent session. Workspace metadata mirrors this identity but is
    /// never used as a generation source.
    @discardableResult
    private func installPersistentSessionBinding(
        sessionID: UUID?,
        on session: TabSession,
        updateWorkspaceMetadata: Bool,
        invalidateAsyncWork: Bool
    ) -> AgentPersistentSessionBindingIdentity? {
        if session.activeAgentSessionID == sessionID {
            return session.persistentSessionBindingIdentity
        }

        let previousSessionID = session.activeAgentSessionID
        if updateWorkspaceMetadata, let workspaceManager {
            let workspaceID = workspaceManager.activeWorkspaceID
                ?? sessionIndexOwner?.workspaceID
                ?? lastKnownWorkspaceSnapshot?.id
            let currentWorkspaceSessionID = workspaceManager.activeAgentSessionID(
                forTabID: session.tabID,
                inWorkspaceID: workspaceID
            )
            guard currentWorkspaceSessionID == previousSessionID else {
                #if DEBUG
                    AgentModePerfDiagnostics.event(
                        "agentSessionBinding.workspaceConflict",
                        tabID: session.tabID,
                        fields: [
                            "expectedSessionID": previousSessionID?.uuidString ?? "nil",
                            "currentSessionID": currentWorkspaceSessionID?.uuidString ?? "nil",
                            "requestedSessionID": sessionID?.uuidString ?? "nil"
                        ]
                    )
                #endif
                return nil
            }
            guard workspaceManager.compareAndSetActiveAgentSessionID(
                expected: previousSessionID,
                replacement: sessionID,
                forTabID: session.tabID,
                inWorkspaceID: workspaceID
            ) else {
                return nil
            }
        }

        if invalidateAsyncWork {
            cancelPersistedLoad(for: session)
            removePendingUIRefresh(for: session.tabID)
        }
        _ = session.beginPersistentBindingTransition()
        let binding = sessionID.map {
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: $0)
        }
        session.installPersistentSessionBinding(binding)
        handleSidebarRefreshBindingMutation(
            tabID: session.tabID,
            sessionID: sessionID
        )

        if session.tabID == currentTabID {
            publishLoadingTranscriptPresentation(tabID: session.tabID)
        }
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "agentSessionBinding.mutated",
                tabID: session.tabID,
                fields: [
                    "sessionID": sessionID?.uuidString ?? "nil",
                    "bindingGeneration": binding?.generation.uuidString ?? "nil",
                    "transitionGeneration": String(session.bindingTransitionGeneration),
                    "workspaceMetadataUpdated": String(updateWorkspaceMetadata)
                ]
            )
        #endif
        return binding
    }

    /// Single creation point for attaching an Agent session identity to a compose tab.
    @discardableResult
    private func ensureSessionBoundToTab(_ session: TabSession) -> UUID? {
        if let existing = session.activeAgentSessionID {
            return existing
        }
        let created = UUID()
        return installPersistentSessionBinding(
            sessionID: created,
            on: session,
            updateWorkspaceMetadata: true,
            invalidateAsyncWork: true
        )?.sessionID
    }

    private func persistentBindingResolution(for sessionID: UUID) -> PersistentBindingResolution {
        var authoritativeCandidates = Set<UUID>()
        var conflictingTabIDs = Set<UUID>()
        let liveClaims = Dictionary(uniqueKeysWithValues: sessions.values.compactMap { session in
            session.activeAgentSessionID.map { (session.tabID, $0) }
        })
        var workspaceClaims: [UUID: Set<UUID>] = [:]

        let workspaces = workspaceManager?.workspaces ?? lastKnownWorkspaceSnapshot.map { [$0] } ?? []
        for workspace in workspaces {
            for tab in workspace.composeTabs {
                if let claimedSessionID = tab.activeAgentSessionID {
                    workspaceClaims[tab.id, default: []].insert(claimedSessionID)
                }
            }
            for stashed in workspace.stashedTabs {
                if let claimedSessionID = stashed.tab.activeAgentSessionID {
                    workspaceClaims[stashed.tab.id, default: []].insert(claimedSessionID)
                }
            }
        }

        for (tabID, liveSessionID) in liveClaims {
            if liveSessionID == sessionID {
                authoritativeCandidates.insert(tabID)
            }
            if let persistedClaims = workspaceClaims[tabID],
               persistedClaims.contains(where: { $0 != liveSessionID }),
               liveSessionID == sessionID || persistedClaims.contains(sessionID)
            {
                conflictingTabIDs.insert(tabID)
            }
        }
        for (tabID, persistedClaims) in workspaceClaims {
            if persistedClaims.contains(sessionID) {
                authoritativeCandidates.insert(tabID)
            }
            if persistedClaims.count > 1, persistedClaims.contains(sessionID) {
                conflictingTabIDs.insert(tabID)
            }
        }

        if !conflictingTabIDs.isEmpty || authoritativeCandidates.count > 1 {
            let candidates = authoritativeCandidates.union(conflictingTabIDs).sorted { $0.uuidString < $1.uuidString }
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "mcp.routing.ambiguousAgentSession",
                    fields: [
                        "sessionID": sessionID.uuidString,
                        "candidateTabIDs": candidates.map(\.uuidString).joined(separator: ","),
                        "conflictingTabIDs": conflictingTabIDs.map(\.uuidString).sorted().joined(separator: ",")
                    ]
                )
            #endif
            return .ambiguous(tabIDs: candidates)
        }
        if let tabID = authoritativeCandidates.first {
            return .unique(tabID: tabID)
        }
        if let indexedTabID = ownerValidatedSessionIndex[sessionID]?.tabID,
           workspaceManager?.composeTab(with: indexedTabID) != nil,
           liveClaims[indexedTabID] == nil,
           workspaceClaims[indexedTabID]?.isEmpty != false
        {
            return .unique(tabID: indexedTabID)
        }
        return .notFound
    }

    private func ambiguousAgentSessionError() -> MCPError {
        MCPError.invalidParams(
            "ambiguous_agent_session: The requested agent session is bound to multiple tabs."
        )
    }

    func authoritativeLiveSession(for sessionID: UUID) throws -> TabSession? {
        switch persistentBindingResolution(for: sessionID) {
        case let .unique(tabID):
            guard let session = sessions[tabID], session.activeAgentSessionID == sessionID else { return nil }
            return session
        case .notFound:
            return nil
        case .ambiguous:
            throw ambiguousAgentSessionError()
        }
    }

    private func persistentBindingTransitionIsCurrent(_ token: PersistentBindingTransitionToken) -> Bool {
        guard let session = sessions[token.tabID],
              ObjectIdentifier(session) == token.sessionIdentity,
              session.persistentSessionBindingIdentity == token.binding,
              session.bindingTransitionGeneration == token.transitionGeneration,
              session.sourceItemsRevision == token.sourceItemsRevision
        else {
            return false
        }
        return true
    }

    private func bindingHasSynchronousOwnership(_ session: TabSession) -> Bool {
        session.activeRunOwnership != nil
            || session.runState.isActive
            || session.mcpControlContext != nil
            || session.hasBindingBlockingInteraction
    }

    private func bindingHasOwnership(_ session: TabSession, sessionID: UUID?) async -> Bool {
        if bindingHasSynchronousOwnership(session) {
            return true
        }
        guard let sessionID else { return false }
        return await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
    }

    @discardableResult
    private func rebindPersistentSession(
        _ requestedSessionID: UUID,
        to targetSession: TabSession,
        expectedTransition: PersistentBindingTransitionToken? = nil,
        requiresHydration: Bool = false
    ) async throws -> AgentPersistentSessionBindingIdentity {
        if targetSession.activeAgentSessionID == requestedSessionID,
           let binding = targetSession.persistentSessionBindingIdentity
        {
            return binding
        }

        let existingSourceTabID: UUID? = switch persistentBindingResolution(for: requestedSessionID) {
        case let .unique(tabID): tabID
        case .notFound: nil
        case .ambiguous: throw ambiguousAgentSessionError()
        }
        let sourceSession = existingSourceTabID.flatMap { sessions[$0] }
        let targetCurrentSessionID = targetSession.activeAgentSessionID

        let targetToken: PersistentBindingTransitionToken
        if let expectedTransition {
            guard targetSession.bindingTransitionInProgress,
                  persistentBindingTransitionIsCurrent(expectedTransition)
            else {
                throw PersistentBindingMutationError.staleTransition
            }
            targetToken = expectedTransition
        } else {
            guard !targetSession.bindingTransitionInProgress else {
                throw PersistentBindingMutationError.blockedByOwnership
            }
            _ = targetSession.beginPersistentBindingTransition()
            targetToken = targetSession.persistentBindingTransitionToken()
        }
        var sourceToken: PersistentBindingTransitionToken?
        if let sourceSession, sourceSession !== targetSession {
            guard !sourceSession.bindingTransitionInProgress else {
                targetSession.finishPersistentBindingTransition(generation: targetToken.transitionGeneration)
                throw PersistentBindingMutationError.blockedByOwnership
            }
            _ = sourceSession.beginPersistentBindingTransition()
            sourceToken = sourceSession.persistentBindingTransitionToken()
        }
        defer {
            targetSession.finishPersistentBindingTransition(generation: targetToken.transitionGeneration)
            if let sourceSession, let sourceToken {
                sourceSession.finishPersistentBindingTransition(generation: sourceToken.transitionGeneration)
            }
        }

        if await bindingHasOwnership(targetSession, sessionID: targetCurrentSessionID) {
            throw PersistentBindingMutationError.blockedByOwnership
        }
        if let sourceSession, sourceSession !== targetSession,
           await bindingHasOwnership(sourceSession, sessionID: requestedSessionID)
        {
            throw PersistentBindingMutationError.blockedByOwnership
        }

        guard persistentBindingTransitionIsCurrent(targetToken) else {
            throw PersistentBindingMutationError.staleTransition
        }
        if let sourceToken, !persistentBindingTransitionIsCurrent(sourceToken) {
            throw PersistentBindingMutationError.staleTransition
        }
        let targetHasRegistration = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: targetCurrentSessionID ?? requestedSessionID
        )
        guard !bindingHasSynchronousOwnership(targetSession),
              !targetHasRegistration
        else {
            throw PersistentBindingMutationError.blockedByOwnership
        }
        if let sourceSession, sourceSession !== targetSession {
            let sourceHasRegistration = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: requestedSessionID
            )
            guard !bindingHasSynchronousOwnership(sourceSession),
                  !sourceHasRegistration
            else {
                throw PersistentBindingMutationError.blockedByOwnership
            }
        }

        if let workspaceManager {
            guard workspaceManager.activeAgentSessionID(forTabID: targetSession.tabID) == targetCurrentSessionID else {
                throw PersistentBindingMutationError.staleTransition
            }
            if let sourceSession, sourceSession !== targetSession {
                guard workspaceManager.activeAgentSessionID(forTabID: sourceSession.tabID) == requestedSessionID else {
                    throw PersistentBindingMutationError.staleTransition
                }
            }
        }

        if let sourceSession, sourceSession !== targetSession {
            _ = installPersistentSessionBinding(
                sessionID: nil,
                on: sourceSession,
                updateWorkspaceMetadata: true,
                invalidateAsyncWork: true
            )
            guard sourceSession.activeAgentSessionID == nil else {
                throw PersistentBindingMutationError.staleTransition
            }
        }

        if let targetCurrentSessionID, targetCurrentSessionID != requestedSessionID {
            await releaseSessionWorktreeOwnership(sessionID: targetCurrentSessionID)
        }
        if requiresHydration {
            targetSession.hasLoadedPersistedState = false
        }
        guard let binding = installPersistentSessionBinding(
            sessionID: requestedSessionID,
            on: targetSession,
            updateWorkspaceMetadata: true,
            invalidateAsyncWork: true
        ), binding.sessionID == requestedSessionID else {
            if let sourceSession, sourceSession !== targetSession {
                _ = installPersistentSessionBinding(
                    sessionID: requestedSessionID,
                    on: sourceSession,
                    updateWorkspaceMetadata: true,
                    invalidateAsyncWork: true
                )
            }
            throw PersistentBindingMutationError.staleTransition
        }
        return binding
    }

    private func loadSessionFromDisk(for session: TabSession) async {
        #if DEBUG
            let loadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let debugTabID = session.tabID
            let debugStartRevision = session.sourceItemsRevision
            let debugExpectedSessionID = explicitActiveSessionID(for: session.tabID)
            func logLoadTask(outcome: String) {
                WorkspaceRestorePerfLog.event(
                    "agentSessionHydration.loadTask",
                    fields: [
                        "windowID": "\(windowID)",
                        "tabID": WorkspaceRestorePerfLog.shortID(debugTabID),
                        "sessionID": WorkspaceRestorePerfLog.shortID(debugExpectedSessionID),
                        "outcome": outcome,
                        "startRevision": "\(debugStartRevision)",
                        "duration": loadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        if session.hasLoadedPersistedState {
            #if DEBUG
                logLoadTask(outcome: "alreadyLoaded")
            #endif
            return
        }
        if let persistedLoadTask = session.persistedLoadTask {
            Self.logCodexDebug("[AgentModeVM][PersistedLoad] join inflight tab=\(session.tabID)")
            await persistedLoadTask.value
            #if DEBUG
                logLoadTask(outcome: "joinedExistingTask")
            #endif
            return
        }
        let startRevision = session.sourceItemsRevision
        let expectedBinding = session.persistentSessionBindingIdentity
        let expectedSessionID = expectedBinding?.sessionID
        let hydrationToken = expectedSessionID.map {
            PersistedHydrationCommitToken(
                transition: session.persistentBindingTransitionToken(),
                requestedSessionID: $0
            )
        }
        let persistedLoadTask = Task { [weak self] in
            guard let self else { return }
            await performPersistedSessionLoad(
                for: session,
                hydrationToken: hydrationToken,
                startRevision: startRevision
            )
        }
        session.persistedLoadTask = persistedLoadTask
        defer {
            session.persistedLoadTask = nil
        }
        Self.logCodexDebug(
            "[AgentModeVM][PersistedLoad] start tab=\(session.tabID) revision=\(startRevision) sessionID=\(expectedSessionID?.uuidString ?? "nil")"
        )
        await persistedLoadTask.value
        #if DEBUG
            logLoadTask(outcome: "createdTaskComplete")
        #endif
    }

    private func isActivationTargetedPersistedHydration(for session: TabSession) -> Bool {
        if session.tabID == currentTabID {
            return true
        }
        return activeSessionLoadInProgressTabID == session.tabID
            && activeTranscriptPresentation.tabID == session.tabID
    }

    func persistedHydrationTranscriptViewportState(for session: TabSession) -> AgentTranscriptViewportState {
        guard isActivationTargetedPersistedHydration(for: session) else {
            return session.transcriptViewportState
        }
        // AgentModeView's activation restore target is always `.liveBottom`.
        // Cold hydration for an activation-targeted tab should build the initial
        // projection for that target instead of protecting a stale detached viewport
        // persisted from a prior activation. During deferred/workspace restore,
        // `currentTabID` may lag, so the active loading snapshot also declares the
        // activation target.
        return .liveBottom
    }

    private func performPersistedSessionLoad(
        for session: TabSession,
        hydrationToken: PersistedHydrationCommitToken?,
        startRevision: Int
    ) async {
        let expectedSessionID = hydrationToken?.requestedSessionID
        #if DEBUG
            let performStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var prepareDurationMS: Double?
            var applyDurationMS: Double?
            func logPerform(outcome: String, currentRevision: Int? = nil, error: Error? = nil) {
                var fields: [String: String] = [
                    "windowID": "\(windowID)",
                    "tabID": WorkspaceRestorePerfLog.shortID(session.tabID),
                    "sessionID": WorkspaceRestorePerfLog.shortID(expectedSessionID),
                    "outcome": outcome,
                    "startRevision": "\(startRevision)",
                    "currentRevision": "\(currentRevision ?? session.sourceItemsRevision)",
                    "prepareDuration": prepareDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun",
                    "applyDuration": applyDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun",
                    "total": performStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
                if let error {
                    fields["error"] = String(describing: error)
                }
                WorkspaceRestorePerfLog.event("agentSessionHydration.perform", fields: fields)
            }
        #endif
        if AppLaunchConfiguration.current.suppressesAgentSessionPersistence {
            session.hasLoadedPersistedState = true
            #if DEBUG
                logPerform(outcome: "suppressedPersistence")
            #endif
            return
        }
        guard let workspace = workspaceManager?.activeWorkspace ?? lastKnownWorkspaceSnapshot else {
            #if DEBUG
                logPerform(outcome: "noWorkspace")
            #endif
            return
        }
        guard let sessionID = expectedSessionID, let hydrationToken else {
            session.hasLoadedPersistedState = true
            #if DEBUG
                logPerform(outcome: "noExpectedSessionID")
            #endif
            return
        }

        let request = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: session.tabID,
            sessionID: sessionID,
            resolvedDisplayName: resolvedSessionDisplayName(for: session.tabID),
            hasPendingQuestionUI: session.hasPendingQuestionUI,
            transcriptViewportState: persistedHydrationTranscriptViewportState(for: session),
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            initialPerformanceSnapshot: session.transcriptPerformanceSnapshot
        )

        #if DEBUG
            var prepareStartMS: Double?
        #endif
        do {
            #if DEBUG
                prepareStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            let preparedPayload = try await dataService.preparePersistedHydration(request)
            guard persistentBindingTransitionIsCurrent(hydrationToken.transition) else {
                #if DEBUG
                    logPerform(outcome: "staleAfterPrepare")
                #endif
                return
            }
            guard let payload = preparedPayload else {
                #if DEBUG
                    if let prepareStartMS {
                        prepareDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: prepareStartMS)
                    }
                #endif
                session.hasLoadedPersistedState = true
                #if DEBUG
                    logPerform(outcome: "noPayload")
                #endif
                return
            }
            #if DEBUG
                if let prepareStartMS {
                    prepareDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: prepareStartMS)
                }
            #endif
            guard !Task.isCancelled else {
                Self.logCodexDebug("[AgentModeVM][PersistedLoad] cancelled before hydrate tab=\(session.tabID)")
                #if DEBUG
                    logPerform(outcome: "cancelledBeforeHydrate")
                #endif
                return
            }
            guard sessions[session.tabID] === session else {
                Self.logCodexDebug("[AgentModeVM][PersistedLoad] skip stale owner tab=\(session.tabID)")
                #if DEBUG
                    logPerform(outcome: "staleOwner")
                #endif
                return
            }
            guard !session.hasLoadedPersistedState else {
                Self.logCodexDebug("[AgentModeVM][PersistedLoad] skip already loaded tab=\(session.tabID)")
                #if DEBUG
                    logPerform(outcome: "alreadyLoaded")
                #endif
                return
            }
            let currentSessionID = session.activeAgentSessionID
            guard currentSessionID == expectedSessionID,
                  persistentBindingTransitionIsCurrent(hydrationToken.transition)
            else {
                Self.logCodexDebug(
                    "[AgentModeVM][PersistedLoad] skip session mismatch tab=\(session.tabID) expected=\(expectedSessionID?.uuidString ?? "nil") current=\(currentSessionID?.uuidString ?? "nil")"
                )
                #if DEBUG
                    logPerform(outcome: "sessionMismatch")
                #endif
                return
            }
            guard session.sourceItemsRevision == startRevision else {
                Self.logCodexDebug(
                    "[AgentModeVM][PersistedLoad] skip superseded hydrate tab=\(session.tabID) startRevision=\(startRevision) currentRevision=\(session.sourceItemsRevision)"
                )
                session.hasLoadedPersistedState = true
                #if DEBUG
                    logPerform(outcome: "revisionSuperseded", currentRevision: session.sourceItemsRevision)
                #endif
                return
            }

            #if DEBUG
                let applyStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            guard await applyPersistedHydration(payload, to: session, token: hydrationToken) else {
                #if DEBUG
                    logPerform(outcome: "staleBeforeApply")
                #endif
                return
            }
            #if DEBUG
                if let applyStartMS {
                    applyDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: applyStartMS)
                }
                logPerform(outcome: "applied")
            #endif
        } catch {
            print("[AgentModeVM] Failed to load session: \(error)")
            if persistentBindingTransitionIsCurrent(hydrationToken.transition) {
                session.hasLoadedPersistedState = true
            }
            #if DEBUG
                if let prepareStartMS, prepareDurationMS == nil {
                    prepareDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: prepareStartMS)
                }
                let outcome = (error is CancellationError || Task.isCancelled) ? "cancelledDuringPrepare" : "error"
                logPerform(outcome: outcome, error: error)
            #endif
        }
    }

    @discardableResult
    private func applyPersistedHydration(
        _ payload: AgentSessionHydrationPayload,
        to session: TabSession,
        token: PersistedHydrationCommitToken
    ) async -> Bool {
        guard payload.sessionID == token.requestedSessionID,
              persistentBindingTransitionIsCurrent(token.transition)
        else {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "agentSessionHydration.rejected",
                    tabID: session.tabID,
                    fields: [
                        "requestedSessionID": token.requestedSessionID.uuidString,
                        "payloadSessionID": payload.sessionID.uuidString,
                        "reason": payload.sessionID == token.requestedSessionID ? "staleBinding" : "payloadMismatch"
                    ]
                )
            #endif
            return false
        }
        let agentSession = payload.persistedSession

        hydrateSession(
            session,
            withCanonicalItems: payload.canonicalLiveItems,
            transcript: payload.transcript,
            reason: .persistedSessionHydration,
            isColdLoad: true,
            builtPresentation: payload.builtPresentation
        )
        session.hasSentFirstMessage = payload.transcript.turns.contains { $0.request != nil }
        session.parentSessionID = agentSession.parentSessionID
        session.isMCPOriginated = agentSession.isMCPOriginated
        session.worktreeBindings = agentSession.worktreeBindings
        session.worktreeMergeOperations = agentSession.worktreeMergeOperations
        session.nextSequenceIndex = payload.transcript.nextSequenceIndex
        session.lastActivityAt = agentSession.savedAt
        session.lastUserMessageAt = payload.lastUserMessageAt
        if let lastUserMessageAt = payload.lastUserMessageAt {
            sessionListSortDates[session.tabID] = lastUserMessageAt
        } else {
            sessionListSortDates.removeValue(forKey: session.tabID)
        }
        session.selectedAgent = payload.normalizedSelection.agent
        if session.transcriptAnalyticsSnapshot.selectedAgent != session.selectedAgent {
            session.transcriptAnalyticsSnapshot.selectedAgent = session.selectedAgent
        }
        if session.selectedAgent == .codexExec {
            codexCoordinator.restoreCodexSelection(from: agentSession, session: session)
        } else {
            session.selectedModelRaw = payload.normalizedSelection.modelRaw
        }
        if !AgentModelCatalog.isValid(
            rawModel: session.selectedModelRaw,
            for: session.selectedAgent,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        ) {
            session.selectedModelRaw = AgentModelCatalog.defaultModelRaw(
                for: session.selectedAgent,
                availability: agentAvailabilityContext,
                codexDynamicModels: codexDynamicModels
            )
        }
        session.autoEditEnabled = agentSession.autoEditEnabled
        codexCoordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)

        session.runState = payload.normalizedRunState
        session.providerSessionID = agentSession.providerSessionID
        session.providerTokenUsageByTurn = agentSession.providerTokenUsageByTurn
        session.pendingHandoff = PendingHandoffState(
            payload: agentSession.pendingHandoffPayload,
            createdAt: agentSession.pendingHandoffCreatedAt,
            sourceItemID: agentSession.pendingHandoffSourceItemID,
            defersProviderLockUntilSend: agentSession.pendingHandoffDefersProviderLockUntilSend,
            isStagedForSend: false
        )

        codexCoordinator.restoreCodexMetadata(from: agentSession, session: session)
        switch session.selectedAgent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            if session.codexContextUsage?.lastTotalTokens == nil {
                session.codexContextUsage = Self.contextUsageFromClaudeProviderTokens(
                    session.providerTokenUsageByTurn,
                    modelContextWindow: session.codexContextUsage?.modelContextWindow
                )
            }
        case .codexExec, .openCode, .cursor:
            break
        }
        session.contextUsageSnapshot = ContextUsageSnapshot.fromAgentContextUsage(
            session.codexContextUsage,
            source: .persistedTurns,
            confidence: session.codexContextUsage?.lastTotalTokens != nil ? .bestEffort : .inferred,
            compactedAt: session.contextCompactedAt
        )
        applyLocalSessionIndexUpsert(payload.restoredIndexEntry)

        if payload.needsReloadMigrationSave {
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
        session.hasLoadedPersistedState = true

        let autoEditEnabled = agentSession.autoEditEnabled
        let tabID = session.tabID
        Task { @MainActor [weak self] in
            guard let self,
                  persistentBindingTransitionIsCurrent(token.transition)
            else {
                return
            }
            await applyEditsApprovalStore.setAutoEditEnabled(
                autoEditEnabled,
                for: applyEditsScope(for: tabID),
                updateGlobalDefault: false
            )
            guard !persistentBindingTransitionIsCurrent(token.transition),
                  let currentSession = sessions[tabID]
            else {
                return
            }
            await applyEditsApprovalStore.setAutoEditEnabled(
                currentSession.autoEditEnabled,
                for: applyEditsScope(for: tabID),
                updateGlobalDefault: false
            )
        }
        return true
    }

    /// Ensures a session exists for the given tab ID and loads any persisted state.
    /// Used by MCP tool handlers to ensure session is ready before accessing it.
    func ensureSessionReady(tabID: UUID, reconnectActiveProviders: Bool = false) async -> TabSession {
        let session = session(for: tabID)

        // Load persisted session if we haven't already.
        if !session.hasLoadedPersistedState {
            await loadSessionFromDisk(for: session)
        }

        // Apply to bindings if this is the active tab
        if tabID == currentTabID {
            applySessionToBindings(session)
        }

        if reconnectActiveProviders, session.selectedAgent == .codexExec, session.runState.isActive {
            await codexCoordinator.ensureCodexNativeSession(session: session)
        }
        if reconnectActiveProviders, session.selectedAgent.usesClaudeNativeRuntime, session.runState.isActive {
            await claudeCoordinator.ensureClaudeNativeSession(session: session)
        }

        return session
    }

    func activateRoutedAgentSession(
        tabID: UUID,
        sessionID: UUID?,
        workspace: WorkspaceModel
    ) async -> AgentRouteSessionActivationResult {
        guard let sessionID else {
            _ = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)
            return .ready
        }

        let currentBinding = sessions[tabID]?.activeAgentSessionID
            ?? workspaceManager?.activeAgentSessionID(forTabID: tabID, inWorkspaceID: workspace.id)
        if currentBinding == sessionID {
            let session = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)
            return session.activeAgentSessionID == sessionID ? .ready : .sessionNotFound
        }

        if let existing = sessions[tabID], existing.runState.isActive {
            return .blockedByActiveDifferentSession
        }

        let session = session(for: tabID)
        let transitionGeneration = session.beginPersistentBindingTransition()
        let transitionToken = session.persistentBindingTransitionToken()
        defer { session.finishPersistentBindingTransition(generation: transitionGeneration) }
        let hydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: tabID,
            sessionID: sessionID,
            resolvedDisplayName: resolvedSessionDisplayName(for: tabID),
            hasPendingQuestionUI: session.hasPendingQuestionUI,
            transcriptViewportState: persistedHydrationTranscriptViewportState(for: session),
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            initialPerformanceSnapshot: session.transcriptPerformanceSnapshot
        )

        let payload: AgentSessionHydrationPayload
        #if DEBUG
            let routePrepareStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        do {
            guard let preparedPayload = try await dataService.preparePersistedHydration(hydrationRequest) else {
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "agentSessionHydration.routeActivationPrepare",
                        fields: [
                            "windowID": "\(windowID)",
                            "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                            "sessionID": WorkspaceRestorePerfLog.shortID(sessionID),
                            "outcome": "notFound",
                            "duration": routePrepareStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                #endif
                return .sessionNotFound
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentSessionHydration.routeActivationPrepare",
                    fields: [
                        "windowID": "\(windowID)",
                        "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                        "sessionID": WorkspaceRestorePerfLog.shortID(sessionID),
                        "outcome": "payload",
                        "duration": routePrepareStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            payload = preparedPayload
        } catch {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentSessionHydration.routeActivationPrepare",
                    fields: [
                        "windowID": "\(windowID)",
                        "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                        "sessionID": WorkspaceRestorePerfLog.shortID(sessionID),
                        "outcome": "error",
                        "duration": routePrepareStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                        "error": String(describing: error)
                    ]
                )
            #endif
            return .sessionNotFound
        }

        guard payload.sessionID == sessionID,
              persistentBindingTransitionIsCurrent(transitionToken)
        else {
            return .sessionNotFound
        }

        let persistedSession = payload.persistedSession
        if let persistedWorkspaceID = persistedSession.workspaceID,
           persistedWorkspaceID != workspace.id
        {
            return .sessionWorkspaceMismatch
        }
        if let persistedTabID = persistedSession.composeTabID,
           persistedTabID != tabID
        {
            return .sessionTabMismatch
        }

        do {
            _ = try await rebindPersistentSession(
                sessionID,
                to: session,
                expectedTransition: transitionToken,
                requiresHydration: true
            )
        } catch PersistentBindingMutationError.blockedByOwnership {
            return .blockedByActiveDifferentSession
        } catch {
            return .sessionNotFound
        }

        prepareSessionForRouteActivation(session)
        guard let binding = session.persistentSessionBindingIdentity else {
            return .sessionNotFound
        }
        let hydrationToken = PersistedHydrationCommitToken(
            transition: session.persistentBindingTransitionToken(),
            requestedSessionID: binding.sessionID
        )
        guard await applyPersistedHydration(payload, to: session, token: hydrationToken) else {
            return .sessionNotFound
        }
        let hydrated = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)
        return hydrated.activeAgentSessionID == sessionID && hydrated.hasLoadedPersistedState ? .ready : .sessionNotFound
    }

    private func prepareSessionForRouteActivation(_ session: TabSession) {
        cancelPersistedLoad(for: session)
        session.hasLoadedPersistedState = false
        session.parentSessionID = nil
        session.setItemsSilently([], reason: .routeActivation)
        session.clearDerivedTranscriptCaches()
        session.hasSentFirstMessage = false
        session.nextSequenceIndex = 0
        session.runState = .idle
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        session.activeAgentRunStartedAt = nil
        session.waitingPrompt = nil
        session.pendingAskUser = nil
        session.pendingUserInputRequest = nil
        session.pendingApproval = nil
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.pendingApplyEditsReview = nil
        cancelPendingWorktreeMergeReview(for: session, reason: "Session reset")
        session.queuedUserInputRequests.removeAll()
        session.queuedMCPElicitationRequests.removeAll()
        session.pendingInstructions.removeAll()
        session.pendingImageAttachments.removeAll()
        session.pendingTaggedFileAttachments.removeAll()
        session.pendingTurnRuntimeAnchors.removeAll()
        session.agentMessageRuntimeFootersByItemID.removeAll()
        session.providerSessionID = nil
        session.providerTokenUsageByTurn.removeAll()
        session.lastUserMessageAt = nil
        session.isDirty = false
    }

    // MARK: - MCP Control Plane

    // The methods below service the MCP agent control plane (agent_run / agent_manage tools).
    // They are grouped here to make the control-plane boundary explicit.
    //
    // Related:
    // - Tool service:  Services/MCP/Agent/AgentRunMCPToolService.swift
    // - Tool service:  Services/MCP/Agent/AgentManageMCPToolService.swift
    // - Session store: Services/MCP/Agent/AgentRunSessionStore.swift
    // - Snapshot:      Services/MCP/Agent/AgentRunMCPSnapshot.swift
    // - Shared helpers: Services/MCP/Agent/AgentMCPToolHelpers.swift

    private func configureMCPStateObservation(for session: TabSession) {
        session.mcpStateObservationCancellable?.cancel()
        let publishers: [AnyPublisher<Void, Never>] = [
            session.$runState.map { _ in () }.eraseToAnyPublisher(),
            session.$runningStatusText.map { _ in () }.eraseToAnyPublisher(),
            session.$waitingPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingAskUser.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingUserInputRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingPermissionsRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingMCPElicitationRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApplyEditsReview.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingWorktreeMergeReview.map { _ in () }.eraseToAnyPublisher(),
            session.$items.map { _ in () }.eraseToAnyPublisher()
        ]
        session.mcpStateObservationCancellable = Publishers.MergeMany(publishers)
            .sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                handleObservedMCPStateChange(for: session)
            }
    }

    private func teardownMCPControl(
        for session: TabSession,
        cleanupSessionStore: Bool,
        publishChanges: Bool = true,
        deactivateLiveControlContext: Bool = true
    ) async {
        codexCoordinator.handleMCPControlReset(
            for: session,
            reason: "Codex queued follow-up was cancelled because MCP control was torn down."
        )
        session.mcpControlActivationGeneration &+= 1
        if let context = session.mcpControlContext {
            if deactivateLiveControlContext {
                await mcpDeactivateControlContext(
                    sessionID: context.sessionID,
                    cleanupSessionStore: cleanupSessionStore
                )
            } else if cleanupSessionStore {
                await AgentRunSessionStore.cleanup(registration: context.registration)
            }
        }
        // Defensive: ensure permission profile is reset even if deactivation
        // was skipped (e.g. context was already nil during tab close).
        session.permissionProfile = .userConfigured
        if publishChanges, session.tabID == currentTabID {
            updatePermissionBindingState(from: session)
        }
        session.mcpStateObservationCancellable?.cancel()
        session.mcpStateObservationCancellable = nil
        session.mcpControlCleanupTask?.cancel()
        session.mcpControlCleanupTask = nil
        session.mcpFollowUpRunPending = false
    }

    func publishMCPStateChange(for session: TabSession) {
        handleObservedMCPStateChange(for: session)
    }

    func signalCodexInstructionDelivered(for session: TabSession) async {
        await signalMCPInstructionDelivered(for: session)
    }

    func restoreCodexFallbackDraft(tabID: UUID, text: String, message: String) {
        restoreComposerDraft(
            tabID: tabID,
            text: text,
            message: message,
            strategy: .prependAlways
        )
    }

    func publishRunInteractionStateChange(
        for session: TabSession,
        reason: RunInteractionStateChangeReason
    ) {
        runInteractionStateObserver?.agentModeViewModel(
            self,
            didChangeRunInteractionStateFor: session,
            reason: reason
        )
    }

    private func handleObservedMCPStateChange(for session: TabSession) {
        guard !session.terminalCommitInProgress else { return }
        // Terminal waiter publication is owned exclusively by AgentRunTerminalCommitBarrier.
        // Legacy/special-purpose state changes without a canonical revision must not race it.
        if session.runState.isTerminalForCommit {
            return
        }
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            return
        }
        let tabID = session.tabID

        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: context.currentEpoch
        )
        Task { [weak self] in
            guard self?.mcpControlContextMatches(
                tabID: tabID,
                sessionID: snapshot.sessionID,
                activationID: context.activationID,
                registration: context.registration
            ) == true else {
                return
            }
            await AgentRunSessionStore.signalSnapshot(snapshot, cursor: cursor)
        }

        if snapshot.status.isTerminal {
            if session.mcpControlCleanupTask == nil {
                session.mcpControlCleanupTask = Task {}
            }
        } else {
            session.mcpControlCleanupTask?.cancel()
            session.mcpControlCleanupTask = nil
        }
    }

    private func prepareTerminalPublication(for session: TabSession) {
        removePendingUIRefresh(for: session.tabID)
        guard session.tabID == currentTabID,
              canBuildOrPublishActiveTranscriptBindings(for: session)
        else {
            return
        }
        catchUpDerivedTranscriptForActiveBindingIfNeeded(for: session, reason: .liveMutation)
    }

    private func makeTerminalPublicationEnvelope(
        for session: TabSession,
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        providerRunID: UUID?
    ) -> AgentRunTerminalPublicationEnvelope? {
        guard let epoch = ownership.turnEpoch,
              let context = session.mcpControlContext,
              context.sessionID == epoch.sessionID,
              context.activationID == epoch.activationID,
              context.registration.generation == epoch.registrationGeneration,
              let snapshot = mcpSnapshot(
                  for: session,
                  canonicalTerminalState: terminalState,
                  canonicalProviderRunID: providerRunID
              )
        else {
            return nil
        }
        return AgentRunTerminalPublicationEnvelope(epoch: epoch, snapshot: snapshot)
    }

    private func publishTerminalCommit(
        _ revision: AgentRunTerminalCommitRevision,
        successorKind: AgentRunEpochTransitionKind?,
        for session: TabSession
    ) async -> AgentRunTerminalPublicationResult {
        #if DEBUG
            if let test_terminalPublicationOverride {
                return await test_terminalPublicationOverride(
                    revision,
                    successorKind,
                    session
                )
            }
        #endif
        guard let envelope = revision.mcpPublicationEnvelope else {
            return session.mcpControlContext == nil
                ? .accepted(successorEpoch: nil)
                : .rejected(reason: "missing_terminal_publication_envelope")
        }
        guard let context = session.mcpControlContext,
              context.sessionID == envelope.epoch.sessionID,
              context.activationID == envelope.epoch.activationID,
              context.registration.generation == envelope.epoch.registrationGeneration
        else {
            return .rejected(reason: "activation_replaced")
        }
        var result = await AgentRunSessionStore.publishTerminal(
            envelope,
            registration: context.registration,
            commitID: revision.commitID,
            successorKind: successorKind
        )
        if successorKind != nil,
           case .accepted(successorEpoch: nil) = result
        {
            result = .rejected(reason: "missing_successor_epoch")
        }
        if let successorEpoch = result.successorEpoch,
           var liveContext = session.mcpControlContext,
           liveContext.activationID == context.activationID,
           liveContext.registration == context.registration
        {
            liveContext.currentEpoch = successorEpoch
            liveContext.preparedEpoch = successorEpoch
            session.mcpControlContext = liveContext
        }
        if result.isResolved, session.mcpControlCleanupTask == nil {
            session.mcpControlCleanupTask = Task {}
        }
        return result
    }

    private func signalMCPInstructionDelivered(for session: TabSession) async {
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal: missing snapshot/control context tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        guard mcpControlContextMatches(
            tabID: session.tabID,
            sessionID: snapshot.sessionID,
            activationID: context.activationID,
            registration: context.registration
        ) else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal: control context mismatch sessionID=\(snapshot.sessionID) tab=\(session.tabID)")
            return
        }
        Self.steeringDebugLog("[AgentRunSteeringWake] signal delivered sessionID=\(snapshot.sessionID) tab=\(session.tabID) status=\(snapshot.status.rawValue) runState=\(session.runState.rawValue)")
        await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
            snapshot,
            cursor: .init(registration: context.registration, epoch: context.currentEpoch),
            reason: .instructionDelivered
        )
    }

    private func signalMCPInstructionDeliveredFireAndForget(for session: TabSession) {
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal fire-and-forget: missing snapshot/control context tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        let tabID = session.tabID
        Task { @MainActor [weak self] in
            guard self?.mcpControlContextMatches(
                tabID: tabID,
                sessionID: snapshot.sessionID,
                activationID: context.activationID,
                registration: context.registration
            ) == true else {
                Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal fire-and-forget: control context mismatch sessionID=\(snapshot.sessionID) tab=\(tabID)")
                return
            }
            Self.steeringDebugLog("[AgentRunSteeringWake] fire delivered signal sessionID=\(snapshot.sessionID) tab=\(tabID) status=\(snapshot.status.rawValue)")
            await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
                snapshot,
                cursor: .init(registration: context.registration, epoch: context.currentEpoch),
                reason: .instructionDelivered
            )
        }
    }

    private func wakeCurrentMCPWaitersForSteeringRequestFireAndForget(for session: TabSession, source: String) {
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip fire wake: missing snapshot/control context source=\(source) tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        let tabID = session.tabID
        Task { @MainActor [weak self] in
            guard self?.mcpControlContextMatches(
                tabID: tabID,
                sessionID: snapshot.sessionID,
                activationID: context.activationID,
                registration: context.registration
            ) == true else {
                Self.steeringDebugLog("[AgentRunSteeringWake] skip fire wake: control context mismatch source=\(source) sessionID=\(snapshot.sessionID) tab=\(tabID)")
                return
            }
            Self.steeringDebugLog("[AgentRunSteeringWake] fire wake current waiters source=\(source) sessionID=\(snapshot.sessionID) tab=\(tabID) status=\(snapshot.status.rawValue)")
            await AgentRunSessionStore.wakeCurrentWaiters(
                snapshot,
                cursor: .init(registration: context.registration, epoch: context.currentEpoch),
                reason: .steeringRequested
            )
            await Task.yield()
            Self.steeringDebugLog("[AgentRunSteeringWake] fire wake yielded source=\(source) sessionID=\(snapshot.sessionID) tab=\(tabID)")
        }
    }

    private func wakeCurrentMCPWaitersForSteeringRequest(for session: TabSession) async {
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip wake: missing snapshot/control context tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        guard mcpControlContextMatches(
            tabID: session.tabID,
            sessionID: snapshot.sessionID,
            activationID: context.activationID,
            registration: context.registration
        ) else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip wake: control context mismatch sessionID=\(snapshot.sessionID) tab=\(session.tabID)")
            return
        }
        Self.steeringDebugLog("[AgentRunSteeringWake] waking current agent_run waiters reason=steering_requested sessionID=\(snapshot.sessionID) tab=\(session.tabID) status=\(snapshot.status.rawValue) runState=\(session.runState.rawValue)")
        await AgentRunSessionStore.wakeCurrentWaiters(
            snapshot,
            cursor: .init(registration: context.registration, epoch: context.currentEpoch),
            reason: .steeringRequested
        )
    }

    private func mcpControlContextMatches(
        tabID: UUID,
        sessionID: UUID,
        activationID: UUID,
        registration: AgentRunSessionStore.Registration
    ) -> Bool {
        guard let session = sessions[tabID],
              let context = session.mcpControlContext
        else {
            return false
        }
        return context.sessionID == sessionID
            && context.activationID == activationID
            && context.registration == registration
            && session.activeAgentSessionID == sessionID
    }

    /// Whether the given tab is currently MCP-controlled (reactive via `mcpControlledTabIDs`).
    func isMCPControlled(tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return mcpControlledTabIDs.contains(tabID)
    }

    func mcpControlSessionID(for session: TabSession) -> UUID? {
        session.mcpControlContext?.sessionID
    }

    func mcpControlledSession(sessionID: UUID) -> TabSession? {
        let matches = sessions.values.filter { $0.mcpControlContext?.sessionID == sessionID }
        guard matches.count == 1 else {
            if matches.count > 1 {
                #if DEBUG
                    AgentModePerfDiagnostics.event(
                        "mcp.routing.ambiguousControlContext",
                        fields: [
                            "sessionID": sessionID.uuidString,
                            "candidateTabIDs": matches.map(\.tabID.uuidString).sorted().joined(separator: ",")
                        ]
                    )
                #endif
            }
            return nil
        }
        return matches[0]
    }

    func mcpRegistration(sessionID: UUID) -> AgentRunSessionStore.Registration? {
        mcpControlledSession(sessionID: sessionID)?.mcpControlContext?.registration
    }

    func mcpWaitCursor(sessionID: UUID) -> AgentRunSessionStore.WaitCursor? {
        guard let context = mcpControlledSession(sessionID: sessionID)?.mcpControlContext else { return nil }
        return .init(registration: context.registration, epoch: context.currentEpoch)
    }

    /// Marks a controlled session as having a follow-up run pending so that
    /// `mcpSnapshot(for:)` returns `.running` during the async gap before the
    /// new run actually starts. Cleared automatically by `startAgentRun`.
    func setMCPFollowUpRunPending(sessionID: UUID, _ pending: Bool) {
        guard let session = mcpControlledSession(sessionID: sessionID) else { return }
        guard session.mcpFollowUpRunPending != pending else { return }
        session.mcpFollowUpRunPending = pending
        handleObservedMCPStateChange(for: session)
    }

    @discardableResult
    func stageMCPRunEpochTransition(
        sessionID: UUID,
        kind: AgentRunEpochTransitionKind
    ) -> UUID? {
        guard let session = mcpControlledSession(sessionID: sessionID),
              var context = session.mcpControlContext
        else { return nil }
        let token = UUID()
        context.pendingEpochTransition = AgentRunEpochTransitionIntent(
            token: token,
            kind: kind,
            expectedCurrentEpoch: context.currentEpoch
        )
        session.mcpControlContext = context
        return token
    }

    func clearStagedMCPRunEpochTransition(sessionID: UUID, token: UUID) {
        guard let session = mcpControlledSession(sessionID: sessionID),
              var context = session.mcpControlContext,
              context.preparedEpoch == nil,
              context.pendingEpochTransition?.token == token
        else { return }
        context.pendingEpochTransition = nil
        session.mcpControlContext = context
    }

    func withMCPRunEpochTransition<T>(
        sessionID: UUID,
        kind: AgentRunEpochTransitionKind,
        operation: () async throws -> T
    ) async throws -> T {
        guard let token = stageMCPRunEpochTransition(sessionID: sessionID, kind: kind) else {
            throw MCPError.invalidParams("The requested agent run is no longer active.")
        }
        do {
            return try await Self.$mcpRunEpochTransitionToken.withValue(token) {
                try await operation()
            }
        } catch {
            clearStagedMCPRunEpochTransition(sessionID: sessionID, token: token)
            throw error
        }
    }

    func prepareMCPWaitTrackingForRunStart(session: TabSession) async {
        guard !session.runState.isActive,
              let originalContext = session.mcpControlContext
        else { return }
        if originalContext.preparedEpoch != nil {
            return
        }
        let scopedTransitionIntent = originalContext.pendingEpochTransition.flatMap { intent -> AgentRunEpochTransitionIntent? in
            guard intent.token == Self.mcpRunEpochTransitionToken,
                  intent.expectedCurrentEpoch == originalContext.currentEpoch
            else { return nil }
            return intent
        }
        let transitionKind: AgentRunEpochTransitionKind = if originalContext.currentEpoch == nil {
            .initial
        } else if let scopedTransitionIntent {
            scopedTransitionIntent.kind
        } else if originalContext.pendingEpochTransition != nil {
            .unrelated
        } else if session.mcpFollowUpRunPending {
            .relatedFollowUp
        } else {
            .unrelated
        }
        let activationGeneration = session.mcpControlActivationGeneration
        var registration = originalContext.registration
        var result = await AgentRunSessionStore.beginEpoch(
            registration: registration,
            activationID: originalContext.activationID,
            expectedCurrentEpoch: originalContext.currentEpoch,
            transitionKind: transitionKind
        )
        // A stale result means the existing record advanced to another epoch; only rejected
        // results are eligible for missing-record recovery through registerIfMissing.
        if case .rejected = result {
            guard session.mcpControlActivationGeneration == activationGeneration,
                  let context = session.mcpControlContext,
                  context.activationID == originalContext.activationID,
                  context.registration == originalContext.registration,
                  context.currentEpoch == originalContext.currentEpoch,
                  let recoveredRegistration = await AgentRunSessionStore.registerIfMissing(
                      sessionID: originalContext.sessionID
                  )
            else {
                return
            }
            guard session.mcpControlActivationGeneration == activationGeneration,
                  let context = session.mcpControlContext,
                  context.activationID == originalContext.activationID,
                  context.registration == originalContext.registration,
                  context.currentEpoch == originalContext.currentEpoch
            else {
                await AgentRunSessionStore.cleanup(registration: recoveredRegistration)
                return
            }
            registration = recoveredRegistration
            result = await AgentRunSessionStore.beginEpoch(
                registration: registration,
                activationID: originalContext.activationID,
                expectedCurrentEpoch: nil,
                transitionKind: transitionKind
            )
        }
        #if DEBUG
            await test_afterMCPStoreEpochBegan?()
        #endif
        guard case let .accepted(epoch) = result,
              session.mcpControlActivationGeneration == activationGeneration,
              var context = session.mcpControlContext,
              context.activationID == originalContext.activationID,
              context.registration == originalContext.registration,
              context.currentEpoch == originalContext.currentEpoch || context.currentEpoch == epoch
        else {
            if registration != originalContext.registration {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
            return
        }
        context = context.replacingRegistration(registration)
        context.currentEpoch = epoch
        context.preparedEpoch = epoch
        let pendingTransitionToken = context.pendingEpochTransition?.token
        let shouldClearPendingTransition = pendingTransitionToken == scopedTransitionIntent?.token
            || pendingTransitionToken == Self.mcpRunEpochTransitionToken
        if shouldClearPendingTransition {
            context.pendingEpochTransition = nil
        }
        session.mcpControlContext = context
        if !session.mcpFollowUpRunPending {
            session.mcpFollowUpRunPending = true
            handleObservedMCPStateChange(for: session)
        }
    }

    func mcpSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot? {
        guard let session = mcpControlledSession(sessionID: sessionID) else { return nil }
        return mcpSnapshot(for: session)
    }

    func mcpSnapshot(registration: AgentRunSessionStore.Registration) -> AgentRunMCPSnapshot? {
        guard let cursor = mcpWaitCursor(sessionID: registration.sessionID),
              cursor.registration == registration
        else {
            return nil
        }
        return mcpSnapshot(cursor: cursor)
    }

    func mcpSnapshot(cursor: AgentRunSessionStore.WaitCursor) -> AgentRunMCPSnapshot? {
        guard let session = mcpControlledSession(sessionID: cursor.registration.sessionID),
              let context = session.mcpControlContext,
              context.registration == cursor.registration,
              context.currentEpoch == cursor.epoch
        else {
            return nil
        }
        return mcpSnapshot(for: session)
    }

    func mcpWaitPublication(
        sessionID: UUID
    ) -> (snapshot: AgentRunMCPSnapshot, cursor: AgentRunSessionStore.WaitCursor)? {
        guard let cursor = mcpWaitCursor(sessionID: sessionID),
              let snapshot = mcpSnapshot(cursor: cursor)
        else {
            return nil
        }
        return (snapshot, cursor)
    }

    func mcpSnapshot(
        for session: TabSession,
        canonicalTerminalState: AgentSessionRunState? = nil,
        canonicalProviderRunID: UUID? = nil
    ) -> AgentRunMCPSnapshot? {
        guard let context = session.mcpControlContext else { return nil }
        let interaction = canonicalTerminalState == nil ? mcpPendingInteraction(for: session) : nil
        let status: AgentRunMCPSnapshot.Status = {
            if let canonicalTerminalState {
                switch canonicalTerminalState {
                case .completed:
                    return .completed
                case .failed:
                    return .failed
                case .cancelled:
                    return .cancelled
                case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    return .completed
                }
            }
            if interaction != nil {
                return .waitingForInput
            }
            let terminalStatus: AgentRunMCPSnapshot.Status? = {
                switch session.runState {
                case .completed:
                    return .completed
                case .failed:
                    return .failed
                case .cancelled:
                    return .cancelled
                case .idle:
                    if let terminalState = session.transcript.turns.last?.terminalState {
                        switch terminalState {
                        case .completed:
                            return .completed
                        case .failed:
                            return .failed
                        case .cancelled:
                            return .cancelled
                        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                            break
                        }
                    }
                    return .completed
                case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    return nil
                }
            }()
            let now = Date()
            let followUpMaskIsStale = session.mcpFollowUpRunPending
                && session.mcpFollowUpRunPendingUpdatedAt.map { now.timeIntervalSince($0) > 15 } == true
            let supersedingMaskIsStale = session.pendingSupersedingTurnCompletions > 0
                && session.pendingSupersedingTurnCompletionsUpdatedAt.map { now.timeIntervalSince($0) > 15 } == true
            if let terminalStatus,
               followUpMaskIsStale || supersedingMaskIsStale,
               session.agentTask == nil,
               session.pendingInstructions.isEmpty,
               session.claudeSteeringFlushTask == nil,
               session.acpSteeringFlushTask == nil
            {
                Self.steeringDebugLog("[AgentRunSteeringWake] clearing stale MCP running mask sessionID=\(context.sessionID) tab=\(session.tabID) runState=\(session.runState.rawValue) terminal=\(terminalStatus.rawValue) followUp=\(session.mcpFollowUpRunPending) superseding=\(session.pendingSupersedingTurnCompletions)")
                session.mcpFollowUpRunPending = false
                session.pendingSupersedingTurnCompletions = 0
            }
            if session.mcpFollowUpRunPending || session.pendingSupersedingTurnCompletions > 0 {
                if let terminalStatus {
                    Self.steeringDebugLog("[AgentRunSteeringWake] MCP snapshot preserving active running mask over terminal state sessionID=\(context.sessionID) terminal=\(terminalStatus.rawValue) followUp=\(session.mcpFollowUpRunPending) superseding=\(session.pendingSupersedingTurnCompletions)")
                }
                return .running
            }
            if let terminalStatus {
                return terminalStatus
            }
            switch session.runState {
            case .running:
                return .running
            case .waitingForUser, .waitingForQuestion, .waitingForApproval:
                return .waitingForInput
            case .completed, .failed, .cancelled, .idle:
                return .completed
            }
        }()
        let transcriptItemCount = max(
            session.transcriptProjectionCounts.canonicalVisibleRowCount,
            session.items.count
        )
        let resolvedStatusText: String? = {
            if canonicalTerminalState == nil,
               let existing = session.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty
            {
                return existing
            }
            if canonicalTerminalState == nil, session.mcpFollowUpRunPending {
                return "Queued to start"
            }
            switch status {
            case .failed:
                return AgentTranscriptIO.latestErrorText(from: session.transcript, latestTurnOnly: true)
                    ?? AgentTranscriptIO.latestErrorText(from: session.transcript, latestTurnOnly: false)
                    ?? "Run failed without additional error details."
            case .cancelled:
                return "Run cancelled."
            default:
                return nil
            }
        }()
        let resolvedSessionID = context.sessionID
        let resolvedSessionName: String? = {
            if let name = workspaceManager?.composeTabName(with: session.tabID) { return name }
            if let name = ownerValidatedSessionIndex[resolvedSessionID]?.name { return name }
            return "Agent Session"
        }()
        let failureReason = AgentRunMCPSnapshot.FailureReason.classify(status: status, statusText: resolvedStatusText)
        let providerRunID: UUID? = if canonicalTerminalState != nil {
            canonicalProviderRunID ?? AgentModeProcessRunIdentity.mostRecentTranscriptProcessRunID(for: session)
        } else if status.isTerminal {
            session.runID ?? AgentModeProcessRunIdentity.mostRecentTranscriptProcessRunID(for: session)
        } else {
            session.runID
        }
        return AgentRunMCPSnapshot(
            sessionID: resolvedSessionID,
            runID: providerRunID,
            tabID: session.tabID,
            sessionName: resolvedSessionName,
            agentRaw: session.selectedAgent.rawValue,
            agentDisplayName: session.selectedAgent.displayName,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            status: status,
            statusText: resolvedStatusText,
            latestAssistantPreview: mcpResolvedAssistantPreview(session: session, status: status),
            interaction: interaction,
            transcriptItemCount: transcriptItemCount,
            updatedAt: Date(),
            parentSessionID: session.parentSessionID,
            failureReason: failureReason,
            worktreeBindings: session.worktreeBindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
            activeWorktreeMerges: session.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    private func mcpApprovalDecisionOptions(for approval: AgentApprovalRequest) -> [AgentRunMCPSnapshot.Interaction.Option] {
        mcpApprovalDecisionLabels(for: approval, includeAliases: false).map { label in
            let description: String? = switch label {
            case "accept":
                "Allow this action"
            case "accept_for_session":
                "Allow this action for the rest of the session"
            case "accept_with_amendment":
                "Allow with exec policy amendment (provide amendment field)"
            case "decline":
                "Reject this action"
            case "cancel":
                "Cancel the run"
            default:
                nil
            }
            return .init(label: label, description: description)
        }
    }

    private func mcpApprovalDecisionLabels(for approval: AgentApprovalRequest, includeAliases: Bool = true) -> [String] {
        var labels = ["accept", "accept_for_session"]
        if approval.kind == .commandExecution {
            labels.append("accept_with_amendment")
        }
        labels.append("decline")
        if includeAliases {
            labels.append("reject")
        }
        labels.append("cancel")
        return labels
    }

    private func mcpPendingInteraction(for session: TabSession) -> AgentRunMCPSnapshot.Interaction? {
        if let review = session.pendingWorktreeMergeReview {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = [
                .init(label: "Operation ID", value: review.operationID, isCode: false),
                .init(label: "Source", value: "\(review.sourceLabel) @ \(review.sourcePath)", isCode: false),
                .init(label: "Target", value: "\(review.targetLabel) @ \(review.targetPath)", isCode: false),
                .init(label: "Source HEAD", value: review.sourceHead, isCode: true),
                .init(label: "Target HEAD", value: review.targetHead, isCode: true),
                .init(label: "Merge Base", value: review.mergeBase, isCode: true),
                .init(label: "Visualization", value: review.visualization, isCode: true)
            ]
            if let summary = review.summary {
                details.append(.init(label: "Summary", value: "\(summary.commits) commits, \(summary.files) files (+\(summary.insertions) -\(summary.deletions))", isCode: false))
            }
            if let artifacts = review.artifacts {
                details.append(.init(label: "Preview Artifacts", value: artifacts.snapshotDirectory, isCode: true))
            }
            return .init(
                id: review.id,
                kind: .approval,
                responseType: .decision,
                title: "Worktree Merge Review",
                prompt: "Review and approve merging \(review.sourceLabel) into \(review.targetLabel).",
                context: nil,
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Apply the merge after stale validation"),
                    .init(label: "decline", description: "Reject without mutating the target worktree"),
                    .init(label: "cancel", description: "Cancel without mutating the target worktree")
                ],
                fields: [],
                details: details
            )
        }
        // Note: pendingApplyEditsReview is not surfaced here because MCP-controlled sessions
        // always have autoEditEnabled=true, so apply_edits reviews never appear on this path.
        if let approval = session.pendingApproval {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = []
            details.append(.init(label: "Approval Type", value: approval.kind.rawValue, isCode: false))
            if let command = approval.command, !command.isEmpty {
                details.append(.init(label: "Command", value: command, isCode: true))
            }
            if let cwd = approval.cwd, !cwd.isEmpty {
                details.append(.init(label: "Working Directory", value: cwd, isCode: false))
            }
            if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                details.append(.init(label: "Requested Scope", value: grantRoot, isCode: false))
            }
            if let amendment = approval.proposedExecpolicyAmendmentJSON, !amendment.isEmpty {
                details.append(.init(label: "Suggested Amendment", value: amendment, isCode: true))
            }
            for detail in approval.details {
                details.append(.init(label: detail.label, value: detail.value, isCode: detail.isCode))
            }
            return .init(
                id: approval.id,
                kind: .approval,
                responseType: .decision,
                title: approval.title,
                prompt: approval.reason,
                context: nil,
                allowsMultiple: nil,
                options: mcpApprovalDecisionOptions(for: approval),
                fields: [],
                details: details
            )
        }
        if let request = session.pendingPermissionsRequest {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = [
                .init(label: "Approval Type", value: "permissions", isCode: false),
                .init(label: "Working Directory", value: request.cwd, isCode: true)
            ]
            if let reason = request.reason, !reason.isEmpty {
                details.append(.init(label: "Reason", value: reason, isCode: false))
            }
            details.append(.init(label: "Requested Permissions", value: request.permissionsJSON, isCode: true))
            return .init(
                id: request.id,
                kind: .approval,
                responseType: .decision,
                title: request.title,
                prompt: request.reason,
                context: nil,
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Allow these permissions for this turn"),
                    .init(label: "accept_for_session", description: "Allow these permissions for the rest of the session"),
                    .init(label: "decline", description: "Reject these permissions"),
                    .init(label: "cancel", description: "Reject these permissions and cancel the run")
                ],
                fields: [],
                details: details
            )
        }
        if let request = session.pendingMCPElicitationRequest {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = []
            if let serverName = request.serverName, !serverName.isEmpty {
                details.append(.init(label: "Server", value: serverName, isCode: false))
            }
            if let toolName = request.toolName, !toolName.isEmpty {
                details.append(.init(label: "Tool", value: toolName, isCode: false))
            }
            for detail in request.details {
                details.append(.init(label: detail.label, value: detail.value, isCode: detail.isCode))
            }
            return .init(
                id: request.id,
                kind: .mcpElicitation,
                responseType: .elicitation,
                title: request.title,
                prompt: request.prompt ?? request.message,
                context: "Codex requested input or approval from MCP server \(request.serverName ?? "unknown").",
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Accept this MCP elicitation and send content"),
                    .init(label: "decline", description: "Decline this MCP elicitation"),
                    .init(label: "cancel", description: "Cancel the run")
                ],
                fields: [],
                details: details
            )
        }
        if let request = session.pendingUserInputRequest {
            return .init(
                id: request.id,
                kind: .userInput,
                responseType: .structured,
                title: "User Input Requested",
                prompt: request.questions.count == 1
                    ? request.questions[0].question
                    : "Provide the requested structured input to continue.",
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: request.questions.map { question in
                    .init(
                        id: question.id,
                        header: question.header,
                        prompt: question.question,
                        isSecret: question.isSecret,
                        allowsOther: question.isOtherOptionEnabled,
                        options: question.options.map {
                            .init(label: $0.label, description: $0.description)
                        }
                    )
                },
                details: []
            )
        }
        if let pendingAskUser = session.pendingAskUser {
            let interaction = pendingAskUser.interaction
            return .init(
                id: interaction.id,
                kind: .question,
                responseType: .structured,
                title: interaction.title ?? "Questions",
                prompt: interaction.questions.count == 1
                    ? interaction.questions[0].question
                    : "Provide the requested answers to continue.",
                context: interaction.context,
                allowsMultiple: nil,
                options: [],
                fields: interaction.questions.map { question in
                    .init(
                        id: question.id,
                        header: question.header,
                        prompt: question.question,
                        context: question.context,
                        isSecret: false,
                        allowsOther: question.allowsCustom,
                        allowsMultiple: question.allowsMultiple,
                        allowsCustom: question.allowsCustom,
                        emitAllowsOther: false,
                        options: question.options.map { .init(label: $0.label, description: $0.description) }
                    )
                },
                details: []
            )
        }
        if session.instructionContinuation != nil || session.waitingPrompt != nil {
            return .init(
                id: session.instructionWaitID ?? session.mcpControlContext?.sessionID ?? UUID(),
                kind: .instruction,
                responseType: .text,
                title: "Awaiting Instruction",
                prompt: session.waitingPrompt ?? "What would you like me to do next?",
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: [],
                details: []
            )
        }
        return nil
    }

    /// Resolves a session reference (UUID string only) against live sessions first,
    /// then falls back to persisted lookup. Returns nil if not found.
    func mcpResolveSessionID(
        reference: String,
        workspace: WorkspaceModel
    ) async throws -> UUID? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsedUUID = UUID(uuidString: trimmed) else { return nil }

        // Check live sessions
        if sessions.values.contains(where: { $0.activeAgentSessionID == parsedUUID }) {
            return parsedUUID
        }
        // Check workspace compose tabs
        if workspace.composeTabs.contains(where: { $0.activeAgentSessionID == parsedUUID }) {
            return parsedUUID
        }
        // Check session index
        if ownerValidatedSessionIndex[parsedUUID] != nil {
            return parsedUUID
        }
        // Fall back to persisted
        return try await AgentSessionDataService.shared.resolveAgentSessionID(reference: trimmed, for: workspace)
    }

    func mcpValidateAgentRunSpawnAllowed(
        sourceTabID: UUID?,
        isExploreOnly: Bool = false
    ) throws {
        guard let sourceTabID,
              let sourceSession = sessions[sourceTabID],
              let controlContext = sourceSession.mcpControlContext
        else {
            return
        }
        if isExploreOnly, controlContext.taskLabelKind == .explore {
            throw MCPError.invalidParams("Explore agents cannot start additional explore agents.")
        }
        // Top-level MCP sessions (no parent) may spawn sub-agents.
        guard sourceSession.parentSessionID != nil else {
            return
        }
        if isExploreOnly {
            return
        }
        throw MCPError.invalidParams(
            "Sub-agents cannot start additional agent runs. Only top-level MCP-started agent sessions may spawn sub-agents; non-explore sub-agents may start read-only explore children with agent_explore."
        )
    }

    func mcpSpawnParentSessionID(sourceTabID: UUID?) -> UUID? {
        guard let sourceTabID else {
            return nil
        }

        let sourceSession: TabSession? = if let liveSession = sessions[sourceTabID] {
            liveSession
        } else if workspaceManager?.composeTab(with: sourceTabID) != nil {
            session(for: sourceTabID, createIfNeeded: true)
        } else {
            nil
        }

        guard let sourceSession else {
            return nil
        }
        return ensureSessionBoundToTab(sourceSession)
    }

    func applySpawnParentSessionID(
        _ parentSessionID: UUID?,
        to session: TabSession,
        inheritWorktreeBindings: Bool = true
    ) {
        guard let parentSessionID,
              let sessionID = ensureSessionBoundToTab(session)
        else {
            return
        }
        let assignedParent: Bool
        let effectiveParentSessionID: UUID
        if let existingParentSessionID = session.parentSessionID {
            effectiveParentSessionID = existingParentSessionID
            assignedParent = false
        } else {
            guard sessionID != parentSessionID else { return }
            session.parentSessionID = parentSessionID
            effectiveParentSessionID = parentSessionID
            assignedParent = true
        }
        guard sessionID != effectiveParentSessionID else { return }
        repairSpawnParentSessionIndex(
            for: session,
            sessionID: sessionID,
            parentSessionID: effectiveParentSessionID
        )
        let didCopyParentWorktreeBindings = assignedParent
            && inheritWorktreeBindings
            && copyParentWorktreeBindingsIfNeeded(parentSessionID: effectiveParentSessionID, to: session)
        let didRefreshMCPPermissionProfile = assignedParent
            && refreshMCPPermissionProfileIfNeeded(for: session)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.applySpawnParentSessionID", tabID: session.tabID, fields: [
                "sessionID": sessionID.uuidString,
                "parentSessionID": effectiveParentSessionID.uuidString,
                "assignedParent": String(assignedParent),
                "inheritWorktreeBindings": String(inheritWorktreeBindings),
                "copiedWorktreeBindings": String(didCopyParentWorktreeBindings),
                "refreshedPermissionProfile": String(didRefreshMCPPermissionProfile),
                "taskLabel": session.mcpControlContext?.taskLabelKind?.rawValue ?? "nil",
                "originatingConnectionID": session.mcpControlContext?.originatingConnectionID?.uuidString ?? "nil"
            ])
        #endif
        if session.tabID == currentTabID {
            updatePermissionBindingState(from: session)
        }
        if didCopyParentWorktreeBindings {
            syncComposerUIState(tabID: session.tabID)
            syncStatusPillsUIState()
        }
        syncSidebarUIState(refresh: true, reason: .parentRepair)
        if assignedParent || didCopyParentWorktreeBindings || didRefreshMCPPermissionProfile {
            scheduleSave(for: session.tabID)
        }
    }

    @discardableResult
    private func copyParentWorktreeBindingsIfNeeded(parentSessionID: UUID, to session: TabSession) -> Bool {
        guard session.worktreeBindings.isEmpty,
              let parentSession = try? authoritativeLiveSession(for: parentSessionID),
              !parentSession.worktreeBindings.isEmpty
        else {
            return false
        }
        session.worktreeBindings = parentSession.worktreeBindings
        session.isDirty = true
        updateWorktreeBindingSummariesInIndex(for: session)
        return true
    }

    func worktreeBindingState(
        forAgentSessionID sessionID: UUID,
        tabID: UUID? = nil
    ) -> AgentSessionWorktreeBindingState {
        do {
            if let live = try authoritativeLiveSession(for: sessionID) {
                return live.hasLoadedPersistedState ? .hydrated(live.worktreeBindings) : .unhydrated
            }
        } catch {
            return .unavailable
        }
        if let tabID, let live = sessions[tabID], live.activeAgentSessionID == sessionID {
            return live.hasLoadedPersistedState ? .hydrated(live.worktreeBindings) : .unhydrated
        }
        switch persistentBindingResolution(for: sessionID) {
        case .unique:
            return .unhydrated
        case .notFound, .ambiguous:
            return .unavailable
        }
    }

    func worktreeBindings(forAgentSessionID sessionID: UUID, tabID: UUID? = nil) -> [AgentSessionWorktreeBinding] {
        worktreeBindingState(forAgentSessionID: sessionID, tabID: tabID).bindings ?? []
    }

    private func releaseSessionWorktreeOwnership(sessionID: UUID?) async {
        guard let sessionID, let workspaceFileContextStore else { return }
        await WorkspaceRootBindingProjectionMaterializer(store: workspaceFileContextStore).release(sessionID: sessionID)
    }

    private func resolveWorktreeBindingStateEnsuringOwnership(
        sessionID: UUID,
        tabID: UUID?
    ) async -> AgentSessionWorktreeBindingState {
        guard let tabID else { return .unavailable }
        let session = await ensureSessionReady(tabID: tabID)
        guard session.activeAgentSessionID == sessionID,
              !session.worktreeBindingTransitionInProgress
        else { return .unavailable }
        let state = worktreeBindingState(forAgentSessionID: sessionID, tabID: tabID)
        guard case let .hydrated(bindings) = state else { return state }
        guard let store = promptManager?.workspaceFileContextStore else { return .unavailable }
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        if bindings.isEmpty {
            await materializer.release(sessionID: sessionID)
            return state
        }
        guard let projection = await materializer.materialize(sessionID: sessionID, bindings: bindings),
              projection.isFullyMaterialized
        else {
            return .unavailable
        }
        return state
    }

    func requireLiveAgentSession(_ sessionID: UUID) throws {
        guard try authoritativeLiveSession(for: sessionID) != nil else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
    }

    @discardableResult
    private func commitWorktreeBindings(
        _ bindings: [AgentSessionWorktreeBinding],
        to session: TabSession
    ) -> [AgentSessionWorktreeBinding] {
        let previous = session.worktreeBindings
        guard previous != bindings else { return previous }
        session.worktreeBindings = bindings
        session.isDirty = true
        updateWorktreeBindingSummariesInIndex(for: session)
        syncComposerUIState(tabID: session.tabID)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        syncStatusPillsUIState()
        scheduleSave(for: session.tabID)
        return previous
    }

    private enum ExecutionLocationTransitionError: LocalizedError {
        case unavailable(String)
        case stale
        case confirmationRequired(ExecutionLocationChangeConfirmation)
        case retainedWorktree(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message):
                message
            case .stale:
                "The thread changed while its execution location was being prepared. Try again."
            case .confirmationRequired(.startedThreadRestart):
                "Changing execution location restarts the agent context and requires confirmation."
            case .confirmationRequired(.activeRunStop):
                "Changing execution location stops the active run and requires confirmation."
            case let .retainedWorktree(path, underlying):
                "The new worktree was created at \(path), but the thread could not be switched. It was not removed. Error: \(underlying)"
            }
        }
    }

    private struct ExecutionLocationContext {
        let logicalRoot: WorkspaceRootRef
        let repo: GitRepoDescriptor
    }

    func availableExecutionWorktrees(for tabID: UUID) async throws -> [AgentExecutionWorktreeSelection] {
        guard executionLocationProps(tabID: tabID) != nil else {
            throw ExecutionLocationTransitionError.unavailable("Execution location is unavailable for this tab.")
        }
        let context = try await executionLocationContext()
        let localPath = CheckoutPathIdentity(context.logicalRoot.standardizedFullPath)
        let selections = try await VCSService.shared.listGitWorktrees(at: context.repo.rootURL)
            .filter { CheckoutPathIdentity($0.path) != localPath }
            .map(Self.executionWorktreeSelection(from:))
        return Self.dedupedExecutionWorktreeSelections(selections)
            .sorted { lhs, rhs in
                if lhs.isPrunable != rhs.isPrunable { return !lhs.isPrunable }
                let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                return labelOrder == .orderedSame ? lhs.path < rhs.path : labelOrder == .orderedAscending
            }
    }

    func selectExecutionLocation(
        _ choice: InitialStartLocation,
        for tabID: UUID,
        confirmedChange: ExecutionLocationChangeConfirmation? = nil
    ) async -> ExecutionLocationChangeResult {
        if isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID]) {
            selectInitialStartLocation(choice, for: tabID)
            return .applied
        }
        guard tabID == currentTabID,
              let session = sessions[tabID],
              let props = executionLocationProps(tabID: tabID),
              props.isEnabled,
              let sessionID = session.activeAgentSessionID
        else {
            return .blocked("This thread cannot change execution location right now.")
        }
        let previousPrimary = primaryExecutionBinding(for: session)
        switch choice {
        case .local where previousPrimary == nil:
            return .unchanged
        case let .existingWorktree(selection) where previousPrimary?.worktreeID == selection.worktreeID:
            return .unchanged
        default:
            break
        }
        let requiredConfirmation: ExecutionLocationChangeConfirmation = session.runState.isActive ? .activeRunStop : .startedThreadRestart
        guard confirmedChange == requiredConfirmation else {
            return .confirmationRequired(requiredConfirmation)
        }
        guard !session.isChangingExecutionLocation else {
            return .blocked("An execution-location change is already in progress.")
        }
        session.isChangingExecutionLocation = true
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
        defer {
            session.isChangingExecutionLocation = false
            if tabID == currentTabID {
                syncComposerUIState(tabID: tabID)
                syncStatusPillsUIState()
            }
        }
        do {
            let desiredBindings: [AgentSessionWorktreeBinding] = switch choice {
            case .local:
                session.worktreeBindings.filter { $0.id != previousPrimary?.id }
            case .newWorktree, .existingWorktree:
                try await prepareStartedExecutionLocationBinding(
                    choice,
                    session: session,
                    source: choice == .newWorktree ? "agent_ui.location_change_new" : "agent_ui.location_change_existing"
                )
            }
            _ = try await transitionWorktreeBindings(
                desiredBindings,
                forSessionID: sessionID,
                intent: .userExecutionLocationChange(confirmation: confirmedChange)
            )
            return .applied
        } catch let ExecutionLocationTransitionError.confirmationRequired(confirmation) {
            return .confirmationRequired(confirmation)
        } catch {
            return .blocked((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @discardableResult
    func transitionWorktreeBindings(
        _ desiredBindings: [AgentSessionWorktreeBinding],
        forSessionID sessionID: UUID,
        intent: WorktreeBindingTransitionIntent
    ) async throws -> [AgentSessionWorktreeBinding] {
        guard let session = try authoritativeLiveSession(for: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        guard !session.worktreeBindingTransitionInProgress else {
            throw ExecutionLocationTransitionError.stale
        }
        session.worktreeBindingTransitionInProgress = true
        defer { session.worktreeBindingTransitionInProgress = false }
        let previousBindings = session.worktreeBindings
        let previousDestination = executionDestinationIdentity(in: previousBindings)
        let nextDestination = executionDestinationIdentity(in: desiredBindings)
        let changedDuringActiveRun = session.runState.isActive

        if changedDuringActiveRun, previousDestination != nextDestination {
            switch intent {
            case .userExecutionLocationChange(confirmation: .activeRunStop):
                break
            case .userExecutionLocationChange:
                throw ExecutionLocationTransitionError.confirmationRequired(.activeRunStop)
            case .externalManagement:
                throw MCPError.invalidParams(
                    "Stop the active Agent run before changing its execution worktree. The in-flight prompt will not be migrated or replayed automatically."
                )
            case .initialSend:
                throw MCPError.invalidParams("A running Agent thread cannot apply an initial execution location.")
            }
        }

        let materializer = promptManager.map {
            WorkspaceRootBindingProjectionMaterializer(store: $0.workspaceFileContextStore)
        }
        let preparation: WorkspaceRootBindingProjectionPreparation?
        if let materializer {
            do {
                preparation = try await materializer.prepare(sessionID: sessionID, bindings: desiredBindings)
            } catch {
                throw ExecutionLocationTransitionError.unavailable(error.localizedDescription)
            }
        } else if desiredBindings.isEmpty {
            preparation = nil
        } else {
            throw ExecutionLocationTransitionError.unavailable("The selected worktree roots could not be prepared for this thread.")
        }

        var ownershipCommitted = preparation == nil
        do {
            guard sessions[session.tabID] === session,
                  session.activeAgentSessionID == sessionID,
                  session.worktreeBindings == previousBindings,
                  session.runState.isActive == changedDuringActiveRun
            else {
                throw ExecutionLocationTransitionError.stale
            }

            if previousDestination != nextDestination {
                if changedDuringActiveRun {
                    switch intent {
                    case .userExecutionLocationChange(confirmation: .activeRunStop):
                        cancelPendingInstruction(for: session)
                        // Terminal publication synchronously detaches the old provider/controller,
                        // so rebinding does not wait on potentially non-cooperative teardown.
                        await runService.cancelRun(
                            tabID: session.tabID,
                            session: session,
                            intent: .executionLocationChange,
                            completion: .terminalPublished
                        )
                    case .userExecutionLocationChange, .externalManagement, .initialSend:
                        throw ExecutionLocationTransitionError.stale
                    }
                }
                guard sessions[session.tabID] === session,
                      session.activeAgentSessionID == sessionID,
                      session.worktreeBindings == previousBindings,
                      !session.runState.isActive
                else {
                    throw ExecutionLocationTransitionError.stale
                }
                if !changedDuringActiveRun {
                    await stageResumeRecoveryHandoffIfNeeded(for: session)
                }
                await invalidateProviderContextForExecutionLocationChange(session)
                guard sessions[session.tabID] === session,
                      session.activeAgentSessionID == sessionID,
                      session.worktreeBindings == previousBindings,
                      !session.runState.isActive
                else {
                    throw ExecutionLocationTransitionError.stale
                }
            }

            let projection: WorkspaceRootBindingProjection?
            if let materializer, let preparation {
                projection = try await materializer.commit(preparation)
                ownershipCommitted = true
            } else {
                projection = nil
            }
            _ = commitWorktreeBindings(desiredBindings, to: session)
            if let materializer {
                await materializer.initializeCodemaps(for: projection)
            }
            return session.worktreeBindings
        } catch {
            if !ownershipCommitted, let materializer, let preparation {
                await materializer.abort(preparation)
            }
            throw error
        }
    }

    private struct ExecutionDestinationIdentity: Equatable {
        let repositoryID: String?
        let worktreeID: String?
        let path: String?
    }

    private func executionDestinationIdentity(in bindings: [AgentSessionWorktreeBinding]) -> ExecutionDestinationIdentity {
        let binding = Self.primaryExecutionBinding(in: bindings, fallbackWorkspacePath: workspacePathProvider())
        return ExecutionDestinationIdentity(
            repositoryID: binding?.repositoryID,
            worktreeID: binding?.worktreeID,
            path: Self.standardizedWorkspacePath(binding?.worktreeRootPath)
                ?? Self.standardizedWorkspacePath(workspacePathProvider())
        )
    }

    private func executionLocationContext() async throws -> ExecutionLocationContext {
        guard let workspace = workspaceManager?.activeWorkspace,
              !workspace.isSystemWorkspace,
              let primaryRoot = workspace.repoPaths.first,
              let promptManager
        else {
            throw ExecutionLocationTransitionError.unavailable("Execution location requires an active project workspace.")
        }
        let primaryPath = Self.standardizedWorkspacePath((primaryRoot as NSString).expandingTildeInPath) ?? primaryRoot
        let visibleRoots = await promptManager.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
        guard let logicalRoot = visibleRoots.first(where: {
            (Self.standardizedWorkspacePath($0.standardizedFullPath) ?? $0.standardizedFullPath) == primaryPath
        }) else {
            throw ExecutionLocationTransitionError.unavailable("Load the primary workspace root before selecting an execution location.")
        }
        guard let resolvedRepo = await VCSService.shared.resolveRepo(from: URL(fileURLWithPath: primaryPath)),
              resolvedRepo.backendKind == .git
        else {
            throw ExecutionLocationTransitionError.unavailable("Existing and new worktrees require a Git-backed primary workspace root.")
        }
        return ExecutionLocationContext(logicalRoot: logicalRoot, repo: GitRepoDescriptor(rootURL: resolvedRepo.rootURL))
    }

    private func prepareStartedExecutionLocationBinding(
        _ choice: InitialStartLocation,
        session: TabSession,
        source: String
    ) async throws -> [AgentSessionWorktreeBinding] {
        guard let sessionID = session.activeAgentSessionID else {
            throw ExecutionLocationTransitionError.unavailable("This thread is not ready to change execution location.")
        }
        let previousBindings = session.worktreeBindings
        let context = try await executionLocationContext()
        let existingWorktrees = try await VCSService.shared.listGitWorktrees(at: context.repo.rootURL)
        var createdWorktree: GitWorktreeDescriptor?
        let worktree: GitWorktreeDescriptor
        switch choice {
        case .local:
            return previousBindings
        case .newWorktree:
            let mainRootPath = existingWorktrees.first(where: \.isMain)?.path ?? context.repo.rootPath
            let plan = try GitWorktreeDefaultPathPlanner.plan(
                .init(
                    mainWorktreeRoot: URL(fileURLWithPath: mainRootPath),
                    existingWorktreeRoots: existingWorktrees.map { URL(fileURLWithPath: $0.path) },
                    purpose: .agentStart(sessionID: sessionID.uuidString)
                )
            )
            worktree = try await VCSService.shared.createGitWorktree(request: plan.createRequest, at: context.repo.rootURL)
            createdWorktree = worktree
        case let .existingWorktree(selection):
            guard let selected = existingWorktrees.first(where: {
                $0.repository.repositoryID == selection.repositoryID && $0.worktreeID == selection.worktreeID
            }), !selected.isPrunable else {
                throw ExecutionLocationTransitionError.unavailable("The selected existing worktree is no longer available.")
            }
            worktree = selected
        }
        do {
            guard sessions[session.tabID] === session, session.worktreeBindings == previousBindings else {
                throw ExecutionLocationTransitionError.stale
            }
            let fallbackLabel = worktree.name ?? worktree.branch ?? (worktree.isMain ? "main" : nil)
            let identity = try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                repositoryID: worktree.repository.repositoryID,
                worktreeID: worktree.worktreeID,
                label: fallbackLabel
            )
            let previous = previousBindings.first { binding in
                Self.standardizedWorkspacePath(binding.logicalRootPath) == Self.standardizedWorkspacePath(context.logicalRoot.standardizedFullPath)
            }
            let binding = AgentSessionWorktreeBinding(
                id: previous?.id ?? UUID().uuidString,
                repositoryID: worktree.repository.repositoryID,
                repoKey: worktree.repository.repoKey,
                logicalRootPath: context.logicalRoot.standardizedFullPath,
                logicalRootName: context.logicalRoot.name,
                worktreeID: worktree.worktreeID,
                worktreeRootPath: worktree.path,
                worktreeName: worktree.name,
                branch: worktree.branch,
                head: worktree.head,
                visualLabel: identity.label,
                visualColorHex: identity.colorHex,
                source: source
            )
            var desiredBindings = previousBindings.filter {
                Self.standardizedWorkspacePath($0.logicalRootPath) != Self.standardizedWorkspacePath(binding.logicalRootPath)
            }
            desiredBindings.append(binding)
            guard sessions[session.tabID] === session, session.worktreeBindings == previousBindings else {
                throw ExecutionLocationTransitionError.stale
            }
            return desiredBindings
        } catch {
            if let createdWorktree {
                throw ExecutionLocationTransitionError.retainedWorktree(
                    path: createdWorktree.path,
                    underlying: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            throw error
        }
    }

    private func invalidateProviderContextForExecutionLocationChange(_ session: TabSession) async {
        let provider = session.provider
        session.provider = nil
        if let provider {
            await provider.dispose()
        }
        if let controller = session.acpController {
            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await controller.cancelPrompt()
            await controller.shutdown()
        }
        if session.codexController != nil || session.codexConversationID != nil || session.codexRolloutPath != nil || session.selectedAgent == .codexExec {
            await codexCoordinator.shutdownCodexSession(session)
            codexCoordinator.clearCodexSessionState(session)
        }
        await claudeCoordinator.shutdownClaudeSessionIfNeeded(session)
        session.providerSessionID = nil
        session.contextUsageSnapshot = nil
        session.activeNonCodexTurnTokenAccumulator = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        session.isDirty = true
    }

    func updateWorktreeBindingSummariesInIndex(for session: TabSession) {
        guard let sessionID = session.activeAgentSessionID,
              var entry = ownerValidatedSessionIndex[sessionID]
        else {
            return
        }
        entry.worktreeBindingSummaries = session.worktreeBindings.worktreeBindingSummaries
        applyLocalSessionIndexUpsert(entry)
    }

    func updateWorktreeMergeSummariesInIndex(for session: TabSession) {
        guard let sessionID = session.activeAgentSessionID,
              var entry = ownerValidatedSessionIndex[sessionID]
        else {
            return
        }
        entry.activeWorktreeMergeSummaries = session.worktreeMergeOperations.activeWorktreeMergeSummaries
        applyLocalSessionIndexUpsert(entry)
    }

    private func repairSpawnParentSessionIndex(
        for session: TabSession,
        sessionID: UUID,
        parentSessionID: UUID
    ) {
        if let existingEntry = ownerValidatedSessionIndex[sessionID] {
            let repairedEntry = AgentSessionIndexEntry(
                id: existingEntry.id,
                tabID: session.tabID,
                name: existingEntry.name,
                lastUserMessageAt: existingEntry.lastUserMessageAt,
                savedAt: existingEntry.savedAt,
                lastRunStateRaw: existingEntry.lastRunStateRaw,
                itemCount: existingEntry.itemCount,
                agentKindRaw: existingEntry.agentKindRaw,
                agentModelRaw: existingEntry.agentModelRaw,
                agentReasoningEffortRaw: existingEntry.agentReasoningEffortRaw,
                autoEditEnabled: existingEntry.autoEditEnabled,
                parentSessionID: parentSessionID,
                hasUnknownConversationContent: existingEntry.hasUnknownConversationContent,
                isMCPOriginated: existingEntry.isMCPOriginated || session.isMCPOriginated,
                worktreeBindingSummaries: existingEntry.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: existingEntry.activeWorktreeMergeSummaries
            )
            guard repairedEntry != existingEntry else { return }
            applyLocalSessionIndexUpsert(repairedEntry)
            return
        }
        upsertSessionIndex(
            sessionID: sessionID,
            tabID: session.tabID,
            name: resolvedSessionDisplayName(for: session.tabID),
            lastUserMessageAt: session.lastUserMessageAt,
            savedAt: session.lastActivityAt,
            lastRunStateRaw: session.runState.rawValue,
            itemCount: max(session.transcriptCanonicalVisibleRowCount, session.items.count),
            agentKindRaw: session.selectedAgent.rawValue,
            agentModelRaw: session.selectedModelRaw,
            agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: parentSessionID,
            isMCPOriginated: session.isMCPOriginated
        )
    }

    func mcpResolveOrCreateSessionTarget(
        tabID: UUID?,
        sessionID: UUID?,
        createIfNeeded: Bool,
        sessionName: String?,
        parentSessionID: UUID? = nil,
        inheritWorktreeBindings: Bool = false
    ) async throws -> MCPSessionTarget {
        if let sessionID {
            let indexedParentSessionID = ownerValidatedSessionIndex[sessionID]?.parentSessionID
            let existingTabID: UUID? = switch persistentBindingResolution(for: sessionID) {
            case let .unique(tabID): tabID
            case .notFound: nil
            case .ambiguous: throw ambiguousAgentSessionError()
            }
            if let existingTabID {
                return try await mcpExistingSessionTarget(
                    tabID: existingTabID,
                    sessionID: sessionID,
                    parentSessionID: indexedParentSessionID ?? parentSessionID,
                    inheritWorktreeBindings: inheritWorktreeBindings
                )
            }
            guard createIfNeeded else {
                throw MCPError.invalidParams("The requested agent session is not currently available.")
            }
            let createdTabID = try await mcpCreateBackgroundSessionTab(name: sessionName)
            let createdSession = session(for: createdTabID)
            _ = try await rebindPersistentSession(
                sessionID,
                to: createdSession,
                requiresHydration: true
            )
            let hydrated = await ensureSessionReady(tabID: createdTabID)
            await loadSessionFromDisk(for: hydrated)
            applySpawnParentSessionID(
                indexedParentSessionID ?? parentSessionID,
                to: hydrated,
                inheritWorktreeBindings: inheritWorktreeBindings
            )
            return .init(tabID: hydrated.tabID, sessionID: sessionID, origin: .createdForSessionResume)
        }

        if let tabID {
            guard workspaceManager?.composeTab(with: tabID) != nil else {
                throw MCPError.invalidParams("Tab '\(tabID.uuidString)' was not found.")
            }
            let hydrated = await ensureSessionReady(tabID: tabID)
            let resolvedSessionID: UUID?
            if createIfNeeded {
                guard let installedSessionID = ensureSessionBoundToTab(hydrated) else {
                    throw MCPError.invalidParams("The target tab could not be bound to an agent session.")
                }
                resolvedSessionID = installedSessionID
            } else {
                resolvedSessionID = hydrated.activeAgentSessionID
            }
            if parentSessionID != nil {
                applySpawnParentSessionID(
                    parentSessionID,
                    to: hydrated,
                    inheritWorktreeBindings: inheritWorktreeBindings
                )
            }
            return .init(tabID: hydrated.tabID, sessionID: resolvedSessionID, origin: .existingTab)
        }

        guard createIfNeeded else {
            throw MCPError.invalidParams("No target agent session was specified.")
        }
        let createdTabID = try await mcpCreateBackgroundSessionTab(name: sessionName)
        let hydrated = await ensureSessionReady(tabID: createdTabID)
        guard let createdSessionID = ensureSessionBoundToTab(hydrated) else {
            throw MCPError.invalidParams("The new tab could not be bound to an agent session.")
        }
        applySpawnParentSessionID(
            parentSessionID,
            to: hydrated,
            inheritWorktreeBindings: inheritWorktreeBindings
        )
        return .init(tabID: hydrated.tabID, sessionID: createdSessionID, origin: .createdNewTab)
    }

    private func mcpExistingSessionTarget(
        tabID: UUID,
        sessionID: UUID,
        parentSessionID: UUID?,
        inheritWorktreeBindings: Bool
    ) async throws -> MCPSessionTarget {
        let hydrated = await ensureSessionReady(tabID: tabID)
        if hydrated.activeAgentSessionID != sessionID {
            _ = try await rebindPersistentSession(
                sessionID,
                to: hydrated,
                requiresHydration: true
            )
            await loadSessionFromDisk(for: hydrated)
        }
        guard hydrated.activeAgentSessionID == sessionID else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        let resolvedSessionID = sessionID
        let indexedParentSessionID = ownerValidatedSessionIndex[resolvedSessionID]?.parentSessionID
        applySpawnParentSessionID(
            hydrated.parentSessionID ?? indexedParentSessionID ?? parentSessionID,
            to: hydrated,
            inheritWorktreeBindings: inheritWorktreeBindings
        )
        return .init(tabID: hydrated.tabID, sessionID: resolvedSessionID, origin: .existingSession)
    }

    private func mcpCreateBackgroundSessionTab(name: String?) async throws -> UUID {
        guard let promptManager else {
            throw MCPError.internalError("Prompt manager unavailable.")
        }
        guard let createdTab = await promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: name,
            capacityPolicy: .mcpBackgroundAgent
        ) else {
            throw MCPError.invalidParams("Background agent session capacity is full. Wait for detached agents to finish, close or stash idle agent sessions, or raise agentMode.maxBackgroundAgentComposeTabs.")
        }
        return createdTab.id
    }

    func mcpConfigureSession(
        tabID: UUID,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?
    ) async throws {
        let session = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)
        let normalized = normalizedSelection(
            agentRaw: agentRaw ?? session.selectedAgent.rawValue,
            modelRaw: modelRaw ?? session.selectedModelRaw,
            preserveUnavailableAgent: true
        )
        if session.activeAgentSessionID != nil,
           normalized.agent != session.selectedAgent,
           !canSelectAgent(normalized.agent, for: session)
        {
            throw MCPError.invalidParams(
                "This session is locked to \(session.selectedAgent.displayName). Start a new session to change agents."
            )
        }

        let previousAgent = session.selectedAgent
        if previousAgent != normalized.agent {
            codexCoordinator.handleProviderSwitch(from: previousAgent, to: normalized.agent, session: session)
            await claudeCoordinator.handleProviderIdentityTransition(
                session: session,
                from: previousAgent,
                to: normalized.agent
            )
        }

        session.selectedAgent = normalized.agent
        session.selectedModelRaw = normalized.modelRaw
        if let reasoningEffortRaw {
            session.selectedReasoningEffortRaw = reasoningEffortRaw
        }
        // Recompute the MCP permission profile after a provider change so a `.custom`
        // tri-state policy's per-provider override never goes stale on an already-active
        // MCP-controlled session (sub-agent or top-level).
        _ = refreshMCPPermissionProfileIfNeeded(for: session)
        codexCoordinator.normalizeCodexSelectionForSession(
            session,
            preservingExplicitEffort: reasoningEffortRaw != nil
        )
        // Record last-used effort for the MCP path so the in-memory fallback
        // used by `normalizeCodexSelectionForSession` stays current.  The UI path
        // records this via the `@Published selectedReasoningEffortRaw` didSet, but
        // MCP calls bypass that observer.  Only record when the caller explicitly
        // provided an effort and normalization accepted it, avoiding unsupported
        // requests or fallback/default values becoming sticky global state.
        if let reasoningEffortRaw,
           session.selectedAgent == .codexExec,
           let requestedEffort = CodexReasoningEffort.parse(reasoningEffortRaw),
           let acceptedEffort = CodexReasoningEffort.parse(session.selectedReasoningEffortRaw),
           requestedEffort == acceptedEffort
        {
            CodexAgentToolPreferences.setLastUsedReasoningEffort(
                acceptedEffort,
                forModelRaw: session.selectedModelRaw
            )
            codexCoordinator.recordLastUsedReasoningEffort(acceptedEffort, forModelRaw: session.selectedModelRaw)
        }
        if tabID == currentTabID {
            applySessionToBindings(session)
        }
        if session.activeAgentSessionID != nil {
            scheduleSave(for: tabID)
        }
        handleObservedMCPStateChange(for: session)
    }

    private func usesSubagentPermissionPolicy(_ session: TabSession) -> Bool {
        session.parentSessionID != nil || session.mcpControlContext != nil || session.isMCPOriginated
    }

    private func permissionProfileForMCPActivation(session: TabSession) -> AgentPermissionProfile {
        providerBindingService.permissionProfileForMCPActivation(
            isSubagent: usesSubagentPermissionPolicy(session),
            provider: session.selectedAgent.providerBindingID
        )
    }

    @discardableResult
    private func refreshMCPPermissionProfileIfNeeded(for session: TabSession) -> Bool {
        guard session.mcpControlContext != nil else { return false }
        let nextProfile = permissionProfileForMCPActivation(session: session)
        guard session.permissionProfile != nextProfile else { return false }
        session.permissionProfile = nextProfile
        if session.tabID == currentTabID {
            updatePermissionBindingState(from: session)
        }
        return true
    }

    func mcpActivateControlContext(
        forTabID tabID: UUID,
        sessionID: UUID,
        originatingConnectionID: UUID?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        startPending: Bool = false
    ) async throws {
        let session = await ensureSessionReady(tabID: tabID)
        guard sessions[tabID] === session,
              session.activeAgentSessionID == sessionID,
              !session.bindingTransitionInProgress
        else {
            throw MCPError.invalidParams("The requested agent session binding changed before MCP control activation.")
        }
        let existingContext = session.mcpControlContext
        let activationID = UUID()
        if existingContext != nil {
            codexCoordinator.handleMCPControlReset(
                for: session,
                reason: "Codex queued follow-up was cancelled because MCP control was replaced."
            )
        }
        if let existingSessionID = existingContext?.sessionID,
           existingSessionID != sessionID
        {
            await mcpDeactivateControlContext(
                sessionID: existingSessionID,
                cleanupSessionStore: true
            )
        }
        session.mcpControlCleanupTask?.cancel()
        session.mcpControlActivationGeneration &+= 1
        let activationGeneration = session.mcpControlActivationGeneration
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        guard sessions[tabID] === session,
              session.activeAgentSessionID == sessionID,
              !session.bindingTransitionInProgress,
              session.mcpControlActivationGeneration == activationGeneration
        else {
            await AgentRunSessionStore.cleanup(registration: registration)
            throw MCPError.invalidParams("The requested agent session binding changed before MCP control activation.")
        }
        let priorAutoEditEnabled = existingContext?.sessionID == sessionID
            ? existingContext?.autoEditEnabledBeforeOverride ?? session.autoEditEnabled
            : session.autoEditEnabled
        session.mcpControlContext = AgentMCPControlContext(
            sessionID: sessionID,
            activationID: activationID,
            registration: registration,
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: originatingConnectionID,
            interactionTransport: .mcp(
                sessionID: sessionID,
                originatingConnectionID: originatingConnectionID
            ),
            suppressUserNotifications: true,
            forceAutoEditEnabled: true,
            autoEditEnabledBeforeOverride: priorAutoEditEnabled,
            taskLabelKind: taskLabelKind
        )
        session.mcpFollowUpRunPending = startPending
        mcpControlledTabIDs.insert(tabID)
        // Mark session as MCP-originated so cleanup can scope to MCP sessions only
        session.isMCPOriginated = true
        // MCP-controlled sessions use the sub-agent permission policy, even when
        // they are top-level MCP starts without a parent session.
        session.permissionProfile = permissionProfileForMCPActivation(session: session)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.activateControlContext", tabID: tabID, fields: [
                "sessionID": sessionID.uuidString,
                "parentSessionID": session.parentSessionID?.uuidString ?? "nil",
                "originatingConnectionID": originatingConnectionID?.uuidString ?? "nil",
                "taskLabel": taskLabelKind?.rawValue ?? "nil",
                "startPending": String(startPending),
                "activationID": activationID.uuidString,
                "permissionProfile": String(describing: session.permissionProfile),
                "selectedAgent": session.selectedAgent.rawValue,
                "selectedModel": session.selectedModelRaw
            ])
        #endif
        if priorAutoEditEnabled != true {
            session.autoEditEnabled = true
            await applyEditsApprovalStore.setAutoEditEnabled(
                true,
                for: applyEditsScope(for: tabID),
                updateGlobalDefault: false
            )
        }
        if tabID == currentTabID {
            updateBindingsFromSession(session)
        }
        handleObservedMCPStateChange(for: session)
    }

    /// Discard a session target created by `mcpResolveOrCreateSessionTarget` when a later step
    /// in start/create/resume fails before the target becomes a real session. Only targets with
    /// origin `.createdNewTab` or `.createdForSessionResume` are eligible for discard.
    func mcpDiscardSessionTarget(_ target: MCPSessionTarget) async {
        switch target.origin {
        case .existingSession, .existingTab:
            return
        case .createdNewTab, .createdForSessionResume:
            break
        }
        if let sessionID = target.sessionID {
            await mcpDeactivateControlContext(
                sessionID: sessionID,
                cleanupSessionStore: true
            )
            if let entry = ownerValidatedSessionIndex[sessionID], entry.tabID == target.tabID {
                removeSessionIndex(sessionID: sessionID)
            }
        }
        sessions.removeValue(forKey: target.tabID)
        tabsWithActiveAgentRun.remove(target.tabID)
        mcpControlledTabIDs.remove(target.tabID)
        await promptManager?.closeComposeTab(target.tabID)
    }

    func mcpDeactivateControlContext(
        sessionID: UUID,
        cleanupSessionStore: Bool = false
    ) async {
        guard let session = mcpControlledSession(sessionID: sessionID),
              let context = session.mcpControlContext,
              context.sessionID == sessionID
        else {
            return
        }

        codexCoordinator.handleMCPControlReset(
            for: session,
            reason: "Codex queued follow-up was cancelled because MCP control was deactivated."
        )
        session.mcpControlActivationGeneration &+= 1
        session.mcpControlCleanupTask?.cancel()
        session.mcpControlCleanupTask = nil
        session.mcpFollowUpRunPending = false
        if context.forceAutoEditEnabled {
            session.autoEditEnabled = context.autoEditEnabledBeforeOverride
            await applyEditsApprovalStore.setAutoEditEnabled(
                context.autoEditEnabledBeforeOverride,
                for: applyEditsScope(for: session.tabID),
                updateGlobalDefault: false
            )
        }
        session.mcpControlContext = nil
        mcpControlledTabIDs.remove(session.tabID)
        if cleanupSessionStore {
            await AgentRunSessionStore.cleanup(registration: context.registration)
        }
        // Restore provider permissions to user-configured values.
        session.permissionProfile = .userConfigured
        if session.tabID == currentTabID {
            updateBindingsFromSession(session)
            refreshAutoEditPermissionGuidanceForActiveSession()
        }
    }

    private func withMCPWorkflowOverride<T>(
        session: TabSession,
        workflow: AgentWorkflowDefinition?,
        operation: () throws -> T
    ) rethrows -> T {
        let previousWorkflow = session.selectedWorkflow
        let previousSelectedWorkflow = selectedWorkflow
        session.selectedWorkflow = workflow
        if session.tabID == currentTabID {
            selectedWorkflow = workflow
        }
        defer {
            session.selectedWorkflow = previousWorkflow
            if session.tabID == currentTabID {
                selectedWorkflow = previousSelectedWorkflow
            }
        }
        return try operation()
    }

    /// Awaits the Codex send acknowledgement and either returns the resolved delivery type
    /// or throws an MCP error if the send was dropped, stale, cancelled, or timed out.
    private func awaitCodexSteerAck(
        session: TabSession,
        attemptID: UUID
    ) async throws -> MCPInstructionDispatch {
        let state = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID)
        switch state {
        case .durablyQueued:
            return .queuedFollowUp
        case .steerAccepted, .startAccepted, .controlAccepted:
            return .dispatchedCodexTurn
        case let .failed(message):
            throw MCPError.internalError(
                message.isEmpty
                    ? "Codex steer failed before reaching the active run."
                    : message
            )
        case .cancelled:
            if Task.isCancelled {
                throw CancellationError()
            }
            throw MCPError.invalidParams("Codex steer was cancelled before it reached the active run.")
        case let .stale(reason):
            throw MCPError.internalError(
                reason.isEmpty
                    ? "Codex steer was dropped because the active run changed before delivery."
                    : reason
            )
        case .timedOut:
            throw MCPError.internalError(
                "Timed out waiting for Codex to acknowledge the steer message. The run may have changed state."
            )
        }
    }

    private func mcpActiveInstructionDispatchPlan(for session: TabSession) -> MCPActiveInstructionDispatchPlan {
        switch activeProviderSteeringRoute(for: session) {
        case .claudeNativeInterrupt:
            return MCPActiveInstructionDispatchPlan(
                delivery: .queuedClaudeInterrupt,
                codexAttemptID: nil,
                signalsDeliveryAfterDispatch: false
            )
        case .acpPrompt:
            return MCPActiveInstructionDispatchPlan(
                delivery: .queuedACPInterrupt,
                codexAttemptID: nil,
                signalsDeliveryAfterDispatch: false
            )
        case nil:
            break
        }
        if session.selectedAgent == .codexExec {
            return MCPActiveInstructionDispatchPlan(
                delivery: .dispatchedCodexTurn,
                codexAttemptID: session.codexSteerAckTracker.beginAttempt(),
                signalsDeliveryAfterDispatch: true
            )
        }
        return MCPActiveInstructionDispatchPlan(
            delivery: .queuedFollowUp,
            codexAttemptID: nil,
            signalsDeliveryAfterDispatch: true
        )
    }

    private func wakeMCPWaitersForActiveDispatch(
        delivery: MCPInstructionDispatch,
        session: TabSession,
        sessionID: UUID
    ) async {
        guard delivery.isActiveRunDispatch else { return }
        if let runID = session.runID,
           let mcpServer
        {
            await mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                runID: runID,
                source: "mcp-dispatch-parent-run",
                publicationForSessionID: { [weak self] childSessionID in
                    self?.mcpWaitPublication(sessionID: childSessionID)
                }
            )
        }
        await wakeCurrentMCPWaitersForSteeringRequest(for: session)
        await Task.yield()
        Self.steeringDebugLog("[AgentRunSteeringWake] mcpDispatch yielded after steering wake sessionID=\(sessionID)")
    }

    private func startQueuedProviderSteeringForMCPDispatch(
        delivery: MCPInstructionDispatch,
        session: TabSession
    ) async throws {
        switch delivery {
        case .queuedClaudeInterrupt:
            let queueStarted = await runService.submitQueuedClaudeSteeringIfSupported(session: session)
            guard queueStarted else {
                throw MCPError.internalError(
                    "Claude steer could not be queued because the run is no longer ready for interruption."
                )
            }
        case .queuedACPInterrupt:
            let queueStarted = await runService.submitQueuedACPSteeringIfSupported(session: session)
            guard queueStarted else {
                throw MCPError.internalError(
                    "ACP steer could not be queued because the run is no longer ready for interruption."
                )
            }
        default:
            break
        }
    }

    func mcpDispatchInstruction(
        sessionID: UUID,
        text: String,
        allowStartingRun: Bool,
        workflow: AgentWorkflowDefinition? = nil,
        nativePreparedTurn: NativeSlashPreparedUserTurn? = nil
    ) async throws -> MCPInstructionDispatch {
        guard let session = mcpControlledSession(sessionID: sessionID) else {
            throw MCPError.invalidParams("The requested agent run is no longer active.")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw MCPError.invalidParams("message is required.")
        }
        if let interaction = mcpPendingInteraction(for: session),
           interaction.kind != .instruction
        {
            throw MCPError.invalidParams(
                "The run is waiting on \(interaction.kind.rawValue). Use agent_run.respond instead."
            )
        }

        var delivery: MCPInstructionDispatch
        let codexAttemptID: UUID?
        let signalsDeliveryAfterDispatch: Bool
        if session.runState == .waitingForUser, session.instructionContinuation != nil {
            delivery = .deliveredIntoWaitingContinuation
            codexAttemptID = nil
            signalsDeliveryAfterDispatch = false
        } else if session.runState.isActive {
            let plan = mcpActiveInstructionDispatchPlan(for: session)
            delivery = plan.delivery
            codexAttemptID = plan.codexAttemptID
            signalsDeliveryAfterDispatch = plan.signalsDeliveryAfterDispatch
        } else {
            guard allowStartingRun else {
                throw MCPError.invalidParams("The run is not active. Use agent_run.start to begin a new run.")
            }
            delivery = .startedRun
            codexAttemptID = nil
            signalsDeliveryAfterDispatch = false
        }
        defer {
            if Task.isCancelled, let codexAttemptID {
                session.codexSteerAckTracker.cancel(attemptID: codexAttemptID)
            }
        }

        let submission: UserTurnSubmissionResult
        session.isMCPInstructionDispatchInProgress = true
        defer {
            session.isMCPInstructionDispatchInProgress = false
        }
        submission = withMCPWorkflowOverride(session: session, workflow: workflow) {
            if let nativePreparedTurn {
                return submitPreparedUserTurn(
                    tabID: session.tabID,
                    session: session,
                    trimmedText: trimmedText,
                    attachmentsToSend: [],
                    taggedFilesToSend: [],
                    activeWorkflow: nativePreparedTurn.bubbleWorkflow,
                    nativePreparedTurn: nativePreparedTurn,
                    codexAttemptID: codexAttemptID
                )
            }
            return submitUserTurn(
                text: trimmedText,
                tabID: session.tabID,
                codexAttemptID: codexAttemptID
            )
        }
        switch submission {
        case .submitted:
            Self.steeringDebugLog("[AgentRunSteeringWake] mcpDispatch submitted sessionID=\(sessionID) delivery=\(delivery.rawValue) runState=\(session.runState.rawValue) isActiveDispatch=\(delivery.isActiveRunDispatch) runID=\(String(describing: session.runID))")
            if delivery == .queuedClaudeInterrupt {
                await wakeMCPWaitersForActiveDispatch(delivery: delivery, session: session, sessionID: sessionID)
            }
            try await startQueuedProviderSteeringForMCPDispatch(delivery: delivery, session: session)
            if delivery.isActiveRunDispatch, delivery != .queuedClaudeInterrupt {
                await wakeMCPWaitersForActiveDispatch(delivery: delivery, session: session, sessionID: sessionID)
            }
            if let codexAttemptID {
                session.codexSteerAckTracker.authorizeDispatch(attemptID: codexAttemptID)
                delivery = try await awaitCodexSteerAck(session: session, attemptID: codexAttemptID)
            }
            if signalsDeliveryAfterDispatch {
                await signalMCPInstructionDelivered(for: session)
            }
            handleObservedMCPStateChange(for: session)
            return delivery
        case let .blocked(message):
            if let codexAttemptID {
                session.codexSteerAckTracker.cancel(attemptID: codexAttemptID)
            }
            throw MCPError.invalidParams(message.isEmpty ? "Unable to deliver the instruction." : message)
        }
    }

    func mcpResolvePendingInteraction(
        sessionID: UUID,
        interactionID: UUID,
        payload: MCPInteractionResponsePayload,
        workflow: AgentWorkflowDefinition? = nil
    ) async throws -> MCPInstructionDispatch? {
        guard let session = mcpControlledSession(sessionID: sessionID) else {
            throw MCPError.invalidParams("The requested agent run is no longer active.")
        }

        // Infer the interaction kind from the live pending interaction
        guard let currentInteraction = mcpPendingInteraction(for: session) else {
            throw MCPError.invalidParams("No pending interaction found for the active run.")
        }
        guard currentInteraction.id == interactionID else {
            throw MCPError.invalidParams("The pending interaction no longer matches interaction_id.")
        }
        let kind = currentInteraction.kind
        switch kind {
        case .instruction:
            let expectedID = session.instructionWaitID ?? session.mcpControlContext?.sessionID
            guard expectedID == interactionID else {
                throw MCPError.invalidParams("The pending instruction prompt no longer matches interaction_id.")
            }
            let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw MCPError.invalidParams("response is required for instruction prompts.")
            }
            return try await mcpDispatchInstruction(
                sessionID: sessionID,
                text: text,
                allowStartingRun: false,
                workflow: workflow
            )
        case .question:
            guard let pendingAskUser = session.pendingAskUser,
                  pendingAskUser.interaction.id == interactionID
            else {
                throw MCPError.invalidParams("The pending question no longer matches interaction_id.")
            }
            if payload.skip {
                skipAskUser(tabID: session.tabID, interactionID: interactionID)
            } else {
                do {
                    let drafts: [String: AgentAskUserDraft]
                    if !payload.askUserAnswersByQuestionID.isEmpty {
                        drafts = try pendingAskUser.interaction.drafts(from: payload.askUserAnswersByQuestionID)
                    } else if !payload.answersByQuestionID.isEmpty {
                        drafts = try pendingAskUser.interaction.drafts(fromFlatAnswers: payload.answersByQuestionID)
                    } else {
                        let response = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !response.isEmpty else {
                            throw MCPError.invalidParams("answers are required for ask_user question interactions.")
                        }
                        guard pendingAskUser.interaction.questions.count == 1,
                              let question = pendingAskUser.interaction.questions.first
                        else {
                            throw MCPError.invalidParams("answers are required for multi-question question interactions.")
                        }
                        drafts = try pendingAskUser.interaction.drafts(fromFlatAnswers: [question.id: [response]])
                    }
                    try submitAskUserResponse(tabID: session.tabID, interactionID: interactionID, draftsByQuestionID: drafts)
                } catch let error as MCPError {
                    throw error
                } catch {
                    throw MCPError.invalidParams(error.localizedDescription)
                }
            }
            handleObservedMCPStateChange(for: session)
            return nil
        case .mcpElicitation:
            guard let request = session.pendingMCPElicitationRequest,
                  request.id == interactionID
            else {
                throw MCPError.invalidParams("The pending MCP elicitation request no longer matches interaction_id.")
            }
            let rawAction = payload.elicitationActionRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response: AgentMCPElicitationResponse
            switch rawAction {
            case "accept", "approve", "allow":
                response = AgentMCPElicitationResponse(
                    action: .accept,
                    content: payload.elicitationContent,
                    meta: payload.elicitationMeta
                )
            case "decline", "reject", "deny":
                response = AgentMCPElicitationResponse(action: .decline, meta: payload.elicitationMeta)
            case "cancel":
                response = AgentMCPElicitationResponse(action: .cancel, meta: payload.elicitationMeta)
            case nil, "":
                if !payload.elicitationContent.isEmpty {
                    response = AgentMCPElicitationResponse(
                        action: .accept,
                        content: payload.elicitationContent,
                        meta: payload.elicitationMeta
                    )
                } else {
                    let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else {
                        throw MCPError.invalidParams("response or content is required for MCP elicitation interactions.")
                    }
                    response = AgentMCPElicitationResponse(
                        action: .accept,
                        content: ["response": .string(text)],
                        meta: payload.elicitationMeta
                    )
                }
            default:
                guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw MCPError.invalidParams("response must be one of: accept, decline, cancel, or provide content.")
                }
                response = AgentMCPElicitationResponse(
                    action: .accept,
                    content: ["response": .string(text)],
                    meta: payload.elicitationMeta
                )
            }
            codexCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
            handleObservedMCPStateChange(for: session)
            return nil
        case .userInput:
            guard let request = session.pendingUserInputRequest,
                  request.id == interactionID
            else {
                throw MCPError.invalidParams("The pending user input request no longer matches interaction_id.")
            }
            if payload.explicitSkip {
                throw MCPError.invalidParams("skip is not supported for user_input interactions.")
            }
            if payload.hasStructuredAnswerObjects {
                throw MCPError.invalidParams("user_input answers must be strings or arrays of strings.")
            }
            var answers = payload.answersByQuestionID
            if answers.isEmpty,
               let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                guard request.questions.count == 1, let question = request.questions.first else {
                    throw MCPError.invalidParams("answers are required for multi-question user_input interactions.")
                }
                answers[question.id] = [text]
            }
            let response = AgentRequestUserInputResponse(answersByQuestionID: answers)
            submitUserInputResponse(tabID: session.tabID, requestID: request.requestID, response: response)
            handleObservedMCPStateChange(for: session)
            return nil
        case .approval:
            let rawDecision = payload.decisionRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if let review = session.pendingWorktreeMergeReview,
               review.id == interactionID
            {
                let reason = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackReason = reason?.isEmpty == false ? reason! : "Worktree merge review declined."
                let decision: WorktreeMergeReviewDecision
                switch rawDecision {
                case "accept", "approve":
                    decision = .accept
                case "decline", "reject":
                    decision = .reject(reason: fallbackReason)
                case "cancel":
                    decision = .cancelled(reason: reason?.isEmpty == false ? reason! : "Worktree merge review cancelled.")
                default:
                    throw MCPError.invalidParams("decision must be one of: accept, decline, cancel.")
                }
                submitWorktreeMergeReviewDecision(tabID: session.tabID, reviewID: interactionID, decision: decision)
                handleObservedMCPStateChange(for: session)
                return nil
            }
            if let request = session.pendingPermissionsRequest,
               request.id == interactionID
            {
                let decision: AgentApprovalDecision
                switch rawDecision {
                case "accept", "approve":
                    decision = .accept
                case "accept_for_session", "always_allow", "approve_for_session":
                    decision = .acceptForSession
                case "decline":
                    decision = .decline
                case "cancel":
                    decision = .cancel
                case "accept_with_amendment", "amend":
                    throw MCPError.invalidParams("accept_with_amendment is not supported for permission approvals.")
                default:
                    throw MCPError.invalidParams(
                        "decision must be one of: accept, accept_for_session, decline, cancel."
                    )
                }
                codexCoordinator.submitPermissionsDecision(session: session, request: request, decision: decision)
                handleObservedMCPStateChange(for: session)
                return nil
            }
            guard let approval = session.pendingApproval,
                  approval.id == interactionID
            else {
                throw MCPError.invalidParams("The pending approval no longer matches interaction_id.")
            }
            let decision: AgentApprovalDecision
            switch rawDecision {
            case "accept", "approve":
                decision = .accept
            case "accept_for_session", "always_allow", "approve_for_session":
                decision = .acceptForSession
            case "accept_with_amendment", "amend":
                guard approval.kind == .commandExecution else {
                    throw MCPError.invalidParams("accept_with_amendment is only supported for command approvals.")
                }
                let amendment = payload.amendment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !amendment.isEmpty else {
                    throw MCPError.invalidParams("amendment is required for accept_with_amendment.")
                }
                decision = .acceptWithExecpolicyAmendment(amendment)
            case "decline", "reject":
                decision = .decline
            case "cancel":
                decision = .cancel
            default:
                throw MCPError.invalidParams(
                    "decision must be one of: \(mcpApprovalDecisionLabels(for: approval).joined(separator: ", "))."
                )
            }
            submitApprovalDecision(tabID: session.tabID, decision: decision)
            handleObservedMCPStateChange(for: session)
            return nil
        }
    }

    // MARK: - End MCP Control Plane

    private nonisolated static func transcriptPresentationMetadata(
        from visibleRows: [AgentChatItem],
        workingBlocks: [AgentTranscriptRenderBlock],
        transcript: AgentTranscript,
        runState: AgentSessionRunState
    ) -> AgentTranscriptPresentationMetadata {
        let latestContextBuilderCall = visibleRows.last(where: { item in
            item.kind == .toolCall && normalizedToolCardName(item.toolName) == "context_builder"
        })
        let latestContextBuilderResult = visibleRows.last(where: { item in
            item.kind == .toolResult && normalizedToolCardName(item.toolName) == "context_builder"
        })
        let activeContextBuilderCallID: UUID? = {
            guard let call = latestContextBuilderCall else { return nil }
            if let result = latestContextBuilderResult,
               result.sequenceIndex > call.sequenceIndex
            {
                return nil
            }
            return call.id
        }()
        let activeContextBuilderResultID: UUID? = {
            guard let result = latestContextBuilderResult else { return nil }
            if let call = latestContextBuilderCall,
               call.sequenceIndex > result.sequenceIndex
            {
                return nil
            }
            return result.id
        }()
        let mostRecentEditID = visibleRows.last(where: { item in
            guard item.kind == .toolResult,
                  let toolName = normalizedToolCardName(item.toolName)
            else {
                return false
            }
            return toolName == "apply_edits" || toolName == "apply_patch"
        })?.id
        var recentAssistantItemIDs = Set(
            visibleRows
                .filter { $0.kind == .assistant || $0.kind == .assistantInline }
                .suffix(2)
                .map(\.id)
        )
        if runState.isActive,
           let previousTurn = transcript.turns.dropLast().last
        {
            let previousTurnConclusionAssistantID = previousTurn.conclusionActivityID
                ?? previousTurn.allActivities.reversed().first(where: { activity in
                    activity.itemKind == .assistant || activity.itemKind == .assistantInline
                })?.id
            if let previousTurnConclusionAssistantID {
                recentAssistantItemIDs.insert(previousTurnConclusionAssistantID)
            }
        }
        let latestUserMessageID = visibleRows.last(where: { $0.kind == .user })?.id
        let dynamicSummaryLockTargetTurnID: UUID? = {
            guard runState.isActive,
                  let latestTurn = transcript.turns.last else { return nil }
            let hasToolActivity = latestTurn.allActivities.contains {
                $0.itemKind == .toolCall || $0.itemKind == .toolResult
            }
            let hasDynamicSummaryBlock = workingBlocks.contains {
                $0.turnID == latestTurn.id && ($0.kind == .activityCluster || $0.kind == .groupedHistory)
            }
            guard hasToolActivity || hasDynamicSummaryBlock else { return nil }
            return latestTurn.id
        }()
        return .init(
            latestUserMessageID: latestUserMessageID,
            latestTurnID: transcript.turns.last?.id,
            dynamicSummaryLockTargetTurnID: dynamicSummaryLockTargetTurnID,
            recentAssistantItemIDs: recentAssistantItemIDs,
            activeContextBuilderCallItemID: activeContextBuilderCallID,
            activeContextBuilderResultItemID: activeContextBuilderResultID,
            mostRecentEditItemID: mostRecentEditID
        )
    }

    private func transcriptPresentationSnapshot(
        from session: TabSession,
        revision: Int
    ) -> AgentTranscriptPresentationSnapshot {
        let visibleProjection = session.transcriptProjection
        let workingProjection = session.workingTranscriptProjection
        let archivedHistoryState = session.archivedTranscriptSnapshot.historyState
        let nextVisibleBlocks = visibleProjection.archivedBlocks + visibleProjection.workingBlocks
        let nextVisibleRows = visibleProjection.archivedRows + visibleProjection.workingRows
        let isCapped = archivedHistoryState.hasArchivedHistory && !session.isCompressedHistoryRevealed
        return .init(
            tabID: session.tabID,
            revision: revision,
            visibleBlocks: nextVisibleBlocks,
            workingBlocks: workingProjection.workingBlocks,
            visibleRows: nextVisibleRows,
            workingRows: workingProjection.workingRows,
            rowAnchorIndex: visibleProjection.rowAnchorIndex,
            anchorBlockIndex: visibleProjection.anchorBlockIndex,
            archivedHistoryState: archivedHistoryState,
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            isWindowCappedWhileActive: isCapped,
            bindingsHydrated: session.authoritativeHydratedBindingTransitionGeneration != nil,
            hydratedPersistentBinding: session.authoritativeHydratedBinding,
            hydratedBindingTransitionGeneration: session.authoritativeHydratedBindingTransitionGeneration,
            performanceSnapshot: session.transcriptPerformanceSnapshot,
            metadata: Self.transcriptPresentationMetadata(
                from: nextVisibleRows,
                workingBlocks: workingProjection.workingBlocks,
                transcript: session.transcript,
                runState: session.runState
            ),
            rawToolResultPayloadRenderRevision: session.rawToolResultPayloadRenderRevision
        )
    }

    private func loadingTranscriptPresentationSnapshot(tabID: UUID?, revision: Int) -> AgentTranscriptPresentationSnapshot {
        AgentTranscriptPresentationSnapshot(
            tabID: tabID,
            revision: revision,
            bindingsHydrated: false
        )
    }

    private func publishLoadingTranscriptPresentation(tabID: UUID?) {
        let currentSnapshot = activeTranscriptPresentation
        let isDuplicateLoadingSnapshot = currentSnapshot.tabID == tabID
            && !currentSnapshot.bindingsHydrated
            && currentSnapshot.visibleBlocks.isEmpty
            && currentSnapshot.workingBlocks.isEmpty
            && currentSnapshot.visibleRows.isEmpty
            && currentSnapshot.workingRows.isEmpty
            && currentSnapshot.archivedHistoryState == .empty
        guard !isDuplicateLoadingSnapshot else { return }

        activeTranscriptPresentation = loadingTranscriptPresentationSnapshot(
            tabID: tabID,
            revision: currentSnapshot.revision &+ 1
        )
    }

    private var allowsHeadlessActiveTranscriptBindingPublication: Bool {
        #if DEBUG
            if test_currentTabIDOverride != nil {
                return false
            }
        #endif
        return promptManager == nil
    }

    /// Shared ownership predicate for work that may build or publish active transcript bindings.
    ///
    /// A session is active-owned when it is the current tab for this view model/window.
    /// Headless/test harness contexts without a prompt manager may also keep publishing the
    /// already-owned transcript presentation, preserving the existing publication fallback.
    func canBuildOrPublishActiveTranscriptBindings(for session: TabSession) -> Bool {
        guard sessions[session.tabID] === session,
              !session.bindingTransitionInProgress,
              session.hasLoadedPersistedState
        else {
            return false
        }
        if let binding = session.persistentSessionBindingIdentity {
            guard binding.tabID == session.tabID,
                  binding.sessionID == session.activeAgentSessionID
            else {
                return false
            }
            if let workspaceManager,
               workspaceManager.activeAgentSessionID(forTabID: session.tabID) != binding.sessionID
            {
                return false
            }
        }
        if currentTabID == session.tabID {
            return true
        }
        guard allowsHeadlessActiveTranscriptBindingPublication else {
            return false
        }
        return activeTranscriptPresentation.tabID == nil
            || activeTranscriptPresentation.tabID == session.tabID
    }

    @discardableResult
    private func publishTranscriptPresentation(from session: TabSession, forceRevision: Bool = false) -> Bool {
        let currentSnapshot = activeTranscriptPresentation
        let candidateSnapshot = transcriptPresentationSnapshot(
            from: session,
            revision: currentSnapshot.revision
        )
        let contentChanged = !candidateSnapshot.contentEqualsExcludingPerformance(currentSnapshot)
        #if DEBUG || EDIT_FLOW_PERF
            let performanceChanged = candidateSnapshot.performanceSnapshot != currentSnapshot.performanceSnapshot
        #else
            let performanceChanged = false
        #endif
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled {
                let candidateRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(candidateSnapshot.visibleRows)
                let currentRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(currentSnapshot.visibleRows)
                let candidateRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(candidateSnapshot.visibleRows)
                let currentRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(currentSnapshot.visibleRows)
                let candidateBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(candidateSnapshot.visibleBlocks)
                let currentBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(currentSnapshot.visibleBlocks)
                let candidateBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(candidateSnapshot.visibleBlocks)
                let currentBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(currentSnapshot.visibleBlocks)
                let candidateSemanticDigest = AgentTranscriptDebugInstrumentation.stableDigest([
                    candidateRowSemanticDigest,
                    candidateBlockSemanticDigest,
                    "archived=\(String(describing: candidateSnapshot.archivedHistoryState))",
                    "revealed=\(candidateSnapshot.isCompressedHistoryRevealed)",
                    "capped=\(candidateSnapshot.isWindowCappedWhileActive)",
                    "hydrated=\(candidateSnapshot.bindingsHydrated)",
                    "metadata=\(String(describing: candidateSnapshot.metadata))"
                ])
                let currentSemanticDigest = AgentTranscriptDebugInstrumentation.stableDigest([
                    currentRowSemanticDigest,
                    currentBlockSemanticDigest,
                    "archived=\(String(describing: currentSnapshot.archivedHistoryState))",
                    "revealed=\(currentSnapshot.isCompressedHistoryRevealed)",
                    "capped=\(currentSnapshot.isWindowCappedWhileActive)",
                    "hydrated=\(currentSnapshot.bindingsHydrated)",
                    "metadata=\(String(describing: currentSnapshot.metadata))"
                ])
                let candidateIdentityDigest = AgentTranscriptDebugInstrumentation.stableDigest([
                    candidateRowIdentityDigest,
                    candidateBlockIdentityDigest,
                    candidateSemanticDigest
                ])
                let currentIdentityDigest = AgentTranscriptDebugInstrumentation.stableDigest([
                    currentRowIdentityDigest,
                    currentBlockIdentityDigest,
                    currentSemanticDigest
                ])
                AgentTranscriptDebugInstrumentation.presentationPublishHandler?(.init(
                    visibleRowCount: candidateSnapshot.visibleRows.count,
                    workingRowCount: candidateSnapshot.workingRows.count,
                    visibleBlockCount: candidateSnapshot.visibleBlocks.count,
                    workingBlockCount: candidateSnapshot.workingBlocks.count,
                    contentChanged: contentChanged,
                    performanceChanged: performanceChanged,
                    forceRevision: forceRevision,
                    willAssignSnapshot: contentChanged || performanceChanged || forceRevision,
                    willIncrementRevision: contentChanged || forceRevision,
                    semanticDigest: candidateSemanticDigest,
                    previousSemanticDigest: currentSemanticDigest,
                    identityDigest: candidateIdentityDigest,
                    previousIdentityDigest: currentIdentityDigest,
                    rowSemanticDigest: candidateRowSemanticDigest,
                    previousRowSemanticDigest: currentRowSemanticDigest,
                    rowIdentityDigest: candidateRowIdentityDigest,
                    previousRowIdentityDigest: currentRowIdentityDigest,
                    blockSemanticDigest: candidateBlockSemanticDigest,
                    previousBlockSemanticDigest: currentBlockSemanticDigest,
                    blockIdentityDigest: candidateBlockIdentityDigest,
                    previousBlockIdentityDigest: currentBlockIdentityDigest,
                    semanticNoOpPublishOpportunity: !contentChanged && (performanceChanged || forceRevision),
                    rowIdentityDrift: candidateRowSemanticDigest == currentRowSemanticDigest && candidateRowIdentityDigest != currentRowIdentityDigest,
                    blockIdentityDrift: candidateBlockSemanticDigest == currentBlockSemanticDigest && candidateBlockIdentityDigest != currentBlockIdentityDigest
                ))
            }
        #endif
        guard contentChanged || performanceChanged || forceRevision else {
            return false
        }
        #if DEBUG || EDIT_FLOW_PERF
            if contentChanged {
                session.transcriptPerformanceSnapshot.projectionPublishCount += 1
            }
        #endif
        let nextRevision = (contentChanged || forceRevision)
            ? currentSnapshot.revision &+ 1
            : currentSnapshot.revision
        activeTranscriptPresentation = transcriptPresentationSnapshot(
            from: session,
            revision: nextRevision
        )
        if !isActiveUISyncSuppressed {
            syncRuntimeMetricsUIState()
            syncRunInteractionUIState()
        }
        return contentChanged
    }

    #if DEBUG
        @discardableResult
        func test_publishTranscriptPresentation(tabID: UUID, forceRevision: Bool = false) -> Bool {
            guard let session = sessions[tabID] else { return false }
            return publishTranscriptPresentation(from: session, forceRevision: forceRevision)
        }

        func test_publishLoadingTranscriptPresentation(tabID: UUID?) {
            publishLoadingTranscriptPresentation(tabID: tabID)
        }
    #endif

    private func setActiveTranscriptBindingsHydrated(_ value: Bool) {
        if !value {
            if let tabID = activeTranscriptPresentation.tabID {
                sessions[tabID]?.clearCurrentBindingHydration()
            }
            publishLoadingTranscriptPresentation(tabID: activeTranscriptPresentation.tabID)
            return
        }
        let snapshot = activeTranscriptPresentation
        guard let tabID = snapshot.tabID,
              let session = sessions[tabID],
              session.hasLoadedPersistedState,
              !session.bindingTransitionInProgress
        else {
            return
        }
        session.markCurrentBindingHydrated()
        let hydratedBinding = session.authoritativeHydratedBinding
        let hydratedTransitionGeneration = session.authoritativeHydratedBindingTransitionGeneration
        guard !snapshot.bindingsHydrated
            || snapshot.hydratedPersistentBinding != hydratedBinding
            || snapshot.hydratedBindingTransitionGeneration != hydratedTransitionGeneration
        else {
            return
        }
        activeTranscriptPresentation = .init(
            tabID: snapshot.tabID,
            revision: snapshot.revision,
            visibleBlocks: snapshot.visibleBlocks,
            workingBlocks: snapshot.workingBlocks,
            visibleRows: snapshot.visibleRows,
            workingRows: snapshot.workingRows,
            rowAnchorIndex: snapshot.rowAnchorIndex,
            anchorBlockIndex: snapshot.anchorBlockIndex,
            archivedHistoryState: snapshot.archivedHistoryState,
            isCompressedHistoryRevealed: snapshot.isCompressedHistoryRevealed,
            isWindowCappedWhileActive: snapshot.isWindowCappedWhileActive,
            bindingsHydrated: value,
            hydratedPersistentBinding: hydratedBinding,
            hydratedBindingTransitionGeneration: hydratedTransitionGeneration,
            performanceSnapshot: snapshot.performanceSnapshot,
            metadata: snapshot.metadata,
            rawToolResultPayloadRenderRevision: snapshot.rawToolResultPayloadRenderRevision
        )
    }

    func materializedTranscriptProjection(for session: TabSession) -> AgentTranscriptProjection {
        session.isCompressedHistoryRevealed ? session.fullTranscriptProjection : session.workingTranscriptProjection
    }

    func setCompressedHistoryVisibility(tabID: UUID, isRevealed: Bool) {
        guard let session = session(for: tabID, createIfNeeded: false) else { return }
        guard session.isCompressedHistoryRevealed != isRevealed else { return }
        session.isCompressedHistoryRevealed = isRevealed
        session.transcriptProjection = materializedTranscriptProjection(for: session)
        guard canBuildOrPublishActiveTranscriptBindings(for: session) else { return }
        _ = publishTranscriptPresentation(from: session)
    }

    private func makeActiveTranscriptFollowBindingState(
        from session: TabSession
    ) -> ActiveTranscriptFollowBindingState {
        ActiveTranscriptFollowBindingState(
            tabID: session.tabID,
            viewportState: session.transcriptViewportState,
            armingState: session.transcriptAutoFollowArmingState
        )
    }

    private func syncActiveTranscriptFollowBindings(from session: TabSession) {
        let nextState = makeActiveTranscriptFollowBindingState(from: session)
        guard activeTranscriptFollowBindingState != nextState else { return }
        activeTranscriptFollowBindingState = nextState
    }

    private func republishTranscriptPresentationForRunStateChangeIfNeeded(_ session: TabSession) {
        guard canBuildOrPublishActiveTranscriptBindings(for: session) else { return }
        if currentTabID == session.tabID {
            updateBindingsFromSession(session)
        } else {
            catchUpDerivedTranscriptForActiveBindingIfNeeded(for: session, reason: .liveMutation)
            _ = publishTranscriptPresentation(from: session)
        }
    }

    private func permissionControlsExternallyManagedReason(for session: TabSession) -> String? {
        providerBindingService.externallyManagedPermissionReason(
            isSubagent: usesSubagentPermissionPolicy(session),
            isMCPControlled: session.mcpControlContext != nil,
            permissionProfile: session.permissionProfile
        )
    }

    @discardableResult
    func updatePermissionBindingState(from session: TabSession, syncUI: Bool = true) -> Bool {
        let externallyManagedReason = permissionControlsExternallyManagedReason(for: session)
        let usesSubagentPolicy = usesSubagentPermissionPolicy(session)
        let nextState = ActivePermissionChromeState(
            permissionProfile: session.permissionProfile,
            isSubagent: usesSubagentPolicy,
            externallyManagedReason: externallyManagedReason
        )
        var didChange = false
        if activePermissionChromeState != nextState {
            activePermissionChromeState = nextState
            didChange = true
        }

        let nextControlsBinding = providerBindingService.controlsBinding(
            selectedAgent: session.selectedAgent,
            selectedModelRaw: session.selectedModelRaw,
            permissionProfile: session.permissionProfile,
            isSubagent: usesSubagentPolicy,
            externallyManagedReason: externallyManagedReason
        )
        if activeProviderControlsBinding != nextControlsBinding {
            activeProviderControlsBinding = nextControlsBinding
            didChange = true
        }
        if didChange, syncUI {
            syncComposerUIState(tabID: session.tabID)
            syncStatusPillsUIState()
        }
        return didChange
    }

    func applySessionToBindings(_ session: TabSession) {
        guard canBuildOrPublishActiveTranscriptBindings(for: session) else {
            if session.tabID == currentTabID {
                publishLoadingTranscriptPresentation(tabID: session.tabID)
            }
            return
        }
        session.markCurrentBindingHydrated()
        withActiveUISyncSuppressed {
            isRestoringState = true
            defer { isRestoringState = false }

            catchUpDerivedTranscriptForActiveBindingIfNeeded(
                for: session,
                reason: .liveMutation,
                validateProjectionIntegrity: true
            )
            publishTranscriptPresentation(from: session, forceRevision: false)

            let nextLiveBashExecutionByItemID = session.bashLiveExecutionByTranscriptItemID
            if activeBashLiveExecutionByItemID != nextLiveBashExecutionByItemID {
                activeBashLiveExecutionByItemID = nextLiveBashExecutionByItemID
            }
            if runState != session.runState {
                runState = session.runState
            }
            if waitingPrompt != session.uiWaitingPrompt {
                waitingPrompt = session.uiWaitingPrompt
            }
            if runningStatusText != session.runningStatusText {
                runningStatusText = session.runningStatusText
            }
            if activeAgentRunStartedAt != session.activeAgentRunStartedAt {
                activeAgentRunStartedAt = session.activeAgentRunStartedAt
            }
            if pendingAskUser != session.uiPendingAskUser {
                pendingAskUser = session.uiPendingAskUser
            }
            if pendingApproval != session.uiPendingApproval {
                pendingApproval = session.uiPendingApproval
            }
            if pendingPermissionsRequest != session.uiPendingPermissionsRequest {
                pendingPermissionsRequest = session.uiPendingPermissionsRequest
            }
            if pendingMCPElicitationRequest != session.uiPendingMCPElicitationRequest {
                pendingMCPElicitationRequest = session.uiPendingMCPElicitationRequest
            }
            if pendingApplyEditsReview != session.uiPendingApplyEditsReview {
                pendingApplyEditsReview = session.uiPendingApplyEditsReview
            }
            if pendingWorktreeMergeReview != session.uiPendingWorktreeMergeReview {
                pendingWorktreeMergeReview = session.uiPendingWorktreeMergeReview
            }
            if autoEditEnabled != session.autoEditEnabled {
                autoEditEnabled = session.autoEditEnabled
            }
            updatePermissionBindingState(from: session, syncUI: false)
            if contextUsage != session.codexContextUsage {
                contextUsage = session.codexContextUsage
            }
            if contextUsageSnapshot != session.contextUsageSnapshot {
                contextUsageSnapshot = session.contextUsageSnapshot
            }
            syncActiveTranscriptFollowBindings(from: session)
            if pendingImageAttachments != session.pendingImageAttachments {
                pendingImageAttachments = session.pendingImageAttachments
            }
            if pendingTaggedFileAttachments != session.pendingTaggedFileAttachments {
                pendingTaggedFileAttachments = session.pendingTaggedFileAttachments
            }
            if selectedAgent != session.selectedAgent {
                selectedAgent = session.selectedAgent
            }
            if selectedModelRaw != session.selectedModelRaw {
                selectedModelRaw = session.selectedModelRaw
            }
            if selectedReasoningEffortRaw != session.selectedReasoningEffortRaw {
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
            }
            if selectedWorkflow != session.selectedWorkflow {
                selectedWorkflow = session.selectedWorkflow
            }
            if autoEditPermissionGuidance != nil {
                autoEditPermissionGuidance = nil
            }
        }

        refreshAutoEditPermissionGuidanceForActiveSession(syncUI: false)
        updateDynamicModelPolling()
        syncAllActiveUIState(tabID: session.tabID)
    }

    func clearBindings() {
        withActiveUISyncSuppressed {
            activeSessionLoadInProgressTabID = nil
            isRestoringState = true
            defer { isRestoringState = false }

            activeTranscriptPresentation = .init(
                revision: activeTranscriptPresentation.revision &+ 1
            )
            activeTranscriptFollowBindingState = .init()
            activeBashLiveExecutionByItemID = [:]
            runState = .idle
            waitingPrompt = nil
            runningStatusText = nil
            activeAgentRunStartedAt = nil
            pendingAskUser = nil
            pendingApproval = nil
            pendingPermissionsRequest = nil
            pendingMCPElicitationRequest = nil
            pendingApplyEditsReview = nil
            pendingWorktreeMergeReview = nil
            autoEditEnabled = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
            activePermissionChromeState = .userConfigured
            activeProviderControlsBinding = nil
            autoEditPermissionGuidance = nil
            contextUsage = nil
            contextUsageSnapshot = nil
            pendingImageAttachments = []
            pendingTaggedFileAttachments = []
            selectedWorkflow = nil
        }
        updateDynamicModelPolling()
        syncAllActiveUIState()
    }

    #if DEBUG
        private func recordAgentPerfSessionSnapshot(_ session: TabSession, source: String) {
            guard AgentModePerfDiagnostics.isEnabled else { return }
            let projectionCacheRowCount = session.turnProjectionCaches.values.reduce(0) { partial, cache in
                partial + cache.workingRows.count + cache.archivedRows.count
            }
            let projectionCacheBlockCount = session.turnProjectionCaches.values.reduce(0) { partial, cache in
                partial + cache.workingBlocks.count + cache.archivedBlocks.count
            }
            let ephemeralPayloadBytes = session.ephemeralToolResultPayloadByItemID.values.reduce(0) { partial, payload in
                partial + payload.utf8.count
            }
            let bashLiveOutputBytes = session.bashLiveExecutionByKey.values.reduce(0) { partial, state in
                partial + (state.output?.utf8.count ?? 0)
            }
            let pendingCommandOutputBytes = session.pendingCommandRunningByKey.values.reduce(0) { partial, update in
                partial + (update.appendedOutput?.utf8.count ?? 0)
            }
            let codexReasoningBytes = session.codexReasoningSegmentsByKey.values.reduce(0) { partial, segment in
                partial + segment.summaryMarkdown.utf8.count + segment.bodyMarkdown.utf8.count
            }
            let claudeReasoningStatusBytes = session.claudeReasoningStatusBuffer.utf8.count
            let pendingClaudeReasoningStatusBytes = session.claudeReasoningStatusPendingText?.utf8.count ?? 0
            let pendingAssistantDeltaBytes = session.pendingAssistantDelta.utf8.count
            let reasoningBytes = codexReasoningBytes
                + claudeReasoningStatusBytes
                + pendingClaudeReasoningStatusBytes
                + pendingAssistantDeltaBytes
            let pendingInstructionBytes = session.pendingInstructions.reduce(0) { partial, instruction in
                partial + instruction.utf8.count
            }
            let ownership = session.activeRunOwnership
            let liveness = session.activeRunLiveness
            let nowUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let ageMilliseconds: (UInt64?) -> Any = { timestamp in
                guard let timestamp, timestamp <= nowUptimeNanoseconds else { return NSNull() }
                return Double(nowUptimeNanoseconds - timestamp) / 1_000_000
            }

            AgentModePerfDiagnostics.recordSessionSnapshot(
                tabID: session.tabID,
                fields: [
                    "source": source,
                    "agent": session.selectedAgent.rawValue,
                    "runState": String(describing: session.runState),
                    "runAttemptID": AgentModePerfDiagnostics.shortID(ownership?.attemptID),
                    "runBindingTabID": AgentModePerfDiagnostics.shortID(ownership?.binding.tabID),
                    "runBindingPersistentSessionID": AgentModePerfDiagnostics.shortID(ownership?.binding.persistentSessionID),
                    "runBindingGeneration": AgentModePerfDiagnostics.shortID(ownership?.binding.generation),
                    "runLifecycleStage": liveness?.stage.rawValue ?? "nil",
                    "runRetryIntent": liveness?.retryIntent.rawValue ?? "nil",
                    "runProgressSequence": liveness?.lastAcceptedSequence ?? 0,
                    "runLastSignalAgeMS": ageMilliseconds(liveness?.lastSignalUptimeNanoseconds),
                    "runLastRealProgressAgeMS": ageMilliseconds(liveness?.lastRealProgressUptimeNanoseconds),
                    "runLastHeartbeatAgeMS": ageMilliseconds(liveness?.lastHeartbeatUptimeNanoseconds),
                    "items": session.items.count,
                    "turns": session.transcript.turns.count,
                    "baseWorkingRows": session.baseTranscriptProjection.workingRows.count,
                    "baseArchivedRows": session.baseTranscriptProjection.archivedRows.count,
                    "fullWorkingRows": session.fullTranscriptProjection.workingRows.count,
                    "fullArchivedRows": session.fullTranscriptProjection.archivedRows.count,
                    "workingRows": session.workingTranscriptProjection.workingRows.count,
                    "visibleRows": session.transcriptProjection.workingRows.count + session.transcriptProjection.archivedRows.count,
                    "turnProjectionCaches": session.turnProjectionCaches.count,
                    "projectionCacheRows": projectionCacheRowCount,
                    "projectionCacheBlocks": projectionCacheBlockCount,
                    "ephemeralPayloads": session.ephemeralToolResultPayloadByItemID.count,
                    "ephemeralPayloadBytes": ephemeralPayloadBytes,
                    "bashLiveExecutions": session.bashLiveExecutionByKey.count,
                    "bashLiveOutputBytes": bashLiveOutputBytes,
                    "pendingCommandRunning": session.pendingCommandRunningByKey.count,
                    "pendingCommandOutputBytes": pendingCommandOutputBytes,
                    "reasoningSegments": session.codexReasoningSegmentsByKey.count,
                    "reasoningBytes": reasoningBytes,
                    "runtimeFooters": session.agentMessageRuntimeFootersByItemID.count,
                    "pendingInstructions": session.pendingInstructions.count,
                    "pendingInstructionBytes": pendingInstructionBytes,
                    "providerTokenUsageTurns": session.providerTokenUsageByTurn.count,
                    "dirty": session.isDirty
                ]
            )
        }

        /// Diagnostic-only helper: record an `AgentModePerfDiagnostics` session snapshot for
        /// every live `TabSession`, or for the subset of tabs in `tabIDs` when provided.
        ///
        /// Used by the hidden `agent_perf_metrics` diagnostics op so scripted multi-window
        /// validation can populate `latest_session_snapshots` without forcing each Agent tab
        /// foreground. Does not invoke `updateBindingsFromSession`, `syncAllActiveUIState`,
        /// or any UI publish path — it only reads `sessions.values` and hands each session to
        /// the existing snapshot recorder.
        ///
        /// - Parameters:
        ///   - source: Source label written into each snapshot's `source` field.
        ///   - tabIDs: Optional allow-list. When non-nil, only tabs whose `TabSession.tabID`
        ///     is contained in the set are snapshotted.
        /// - Returns: The tab IDs for which snapshots were recorded.
        @discardableResult
        func test_recordPerfSessionSnapshotsForAllTabs(
            source: String,
            tabIDs: Set<UUID>? = nil
        ) -> [UUID] {
            guard AgentModePerfDiagnostics.isEnabled else { return [] }
            var recorded: [UUID] = []
            recorded.reserveCapacity(sessions.count)
            for session in sessions.values {
                if let tabIDs, !tabIDs.contains(session.tabID) { continue }
                recordAgentPerfSessionSnapshot(session, source: source)
                recorded.append(session.tabID)
            }
            return recorded
        }
    #endif

    func requestUIRefresh(
        tabID: UUID,
        urgent: Bool = false,
        scope: UIRefreshScope = .full
    ) {
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment(urgent ? "ui.refresh.request.urgent" : "ui.refresh.request.coalesced", tabID: tabID)
                AgentModePerfDiagnostics.increment("ui.refresh.request.scope.\(scope.rawValue)", tabID: tabID)
                AgentModePerfDiagnostics.event(
                    "ui.refresh.request",
                    tabID: tabID,
                    fields: [
                        "urgent": String(urgent),
                        "scope": scope.rawValue,
                        "pendingBeforeInsert": String(pendingUIRefreshScopesByTabID.count),
                        "hasScheduledFlush": String(uiRefreshTask != nil)
                    ]
                )
            }
        #endif
        let existingScopes = pendingUIRefreshScopesByTabID[tabID] ?? []
        if scope == .full || existingScopes.contains(.full) {
            pendingUIRefreshScopesByTabID[tabID] = [.full]
            pendingAssistantPresentationByTabID.removeValue(forKey: tabID)
        } else {
            pendingUIRefreshScopesByTabID[tabID] = existingScopes.union([scope])
        }
        // Eagerly detect run-state transitions so background-tab sidebar rows
        // get their unseen badge even when the tab isn't the current one and
        // won't go through the active-tab-only `updateBindingsFromSession`.
        if let session = sessions[tabID] {
            observeSidebarRunStateTransition(for: session)
        }
        if urgent {
            flushPendingUIRefresh(cancelScheduled: true)
            return
        }
        scheduleUIRefreshFlushIfNeeded()
    }

    func requestAssistantPresentationRefresh(
        session: TabSession,
        sourceItemsRevision: Int,
        flushGeneration: UInt64
    ) {
        let request = AssistantPresentationRequest(
            tabID: session.tabID,
            sessionIdentity: ObjectIdentifier(session),
            persistentBinding: session.persistentSessionBindingIdentity,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            sourceItemsRevision: sourceItemsRevision,
            flushGeneration: flushGeneration
        )
        guard canAdmitAssistantPresentationRequest(request, session: session) else {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.assistantPresentation.rejectedBeforeAdmission", tabID: session.tabID)
            #endif
            return
        }
        pendingAssistantPresentationByTabID[session.tabID] = request
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.assistantPresentation.admitted", tabID: session.tabID)
        #endif
        scheduleUIRefreshFlushIfNeeded()
    }

    private func canAdmitAssistantPresentationRequest(
        _ request: AssistantPresentationRequest,
        session: TabSession
    ) -> Bool {
        guard currentTabID == request.tabID,
              sessions[request.tabID] === session,
              ObjectIdentifier(session) == request.sessionIdentity,
              activeSessionLoadInProgressTabID != request.tabID,
              !session.bindingTransitionInProgress,
              session.hasLoadedPersistedState,
              session.persistentSessionBindingIdentity == request.persistentBinding,
              session.bindingTransitionGeneration == request.bindingTransitionGeneration,
              session.sourceItemsRevision == request.sourceItemsRevision,
              session.assistantDeltaFlushGeneration == request.flushGeneration,
              activeTranscriptPresentation.tabID == request.tabID,
              activeTranscriptPresentation.bindingsHydrated,
              activeTranscriptPresentation.hydratedPersistentBinding == request.persistentBinding,
              activeTranscriptPresentation.hydratedBindingTransitionGeneration == request.bindingTransitionGeneration,
              !(pendingUIRefreshScopesByTabID[request.tabID]?.contains(.full) ?? false)
        else {
            return false
        }
        return true
    }

    private func scheduleUIRefreshFlushIfNeeded() {
        guard uiRefreshTask == nil else { return }
        uiRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.uiRefreshCoalesceDelayNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingUIRefresh()
        }
    }

    private func flushPendingUIRefresh(cancelScheduled: Bool = false) {
        #if DEBUG
            let diagnosticsStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        if cancelScheduled {
            uiRefreshTask?.cancel()
        }
        uiRefreshTask = nil
        guard !pendingUIRefreshScopesByTabID.isEmpty || !pendingAssistantPresentationByTabID.isEmpty else {
            #if DEBUG
                AgentModePerfDiagnostics.event("ui.refresh.flushSkipped", fields: ["reason": "empty", "cancelScheduled": String(cancelScheduled)])
            #endif
            return
        }
        let scopesByTabID = pendingUIRefreshScopesByTabID
        let assistantPresentationRequests = pendingAssistantPresentationByTabID
        pendingUIRefreshScopesByTabID.removeAll()
        pendingAssistantPresentationByTabID.removeAll()
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.refresh.flush")
            AgentModePerfDiagnostics.event(
                "ui.refresh.flushStart",
                fields: [
                    "tabCount": String(scopesByTabID.count),
                    "cancelScheduled": String(cancelScheduled)
                ]
            )
        #endif
        var didRequestFullRefresh = false
        for (tabID, scopes) in scopesByTabID {
            guard let session = sessions[tabID] else { continue }
            if scopes.contains(.full) {
                #if DEBUG
                    AgentModePerfDiagnostics.increment("ui.refresh.flush.scope.full", tabID: tabID)
                #endif
                didRequestFullRefresh = true
                updateBindingsFromSession(session)
            } else {
                performScopedUIRefresh(session: session, scopes: scopes)
            }
        }
        // Sidebar revision is already bumped by dedicated publishers (sessions,
        // sessionIndex, sessionListSortDates, sessionListCacheReady, runState,
        // tabsWithActiveAgentRun, mcpControlledTabIDs, sidebar search, visible
        // count, session name updates). Syncing here without `refresh: true`
        // keeps the snapshot fresh without publishing a new revision on every
        // provider event flush.
        if didRequestFullRefresh {
            syncSidebarUIState()
        }
        for (tabID, request) in assistantPresentationRequests {
            guard let session = sessions[tabID] else { continue }
            performAssistantPresentationRefresh(session: session, request: request)
        }
        #if DEBUG
            if let diagnosticsStartMS {
                AgentModePerfDiagnostics.event(
                    "ui.refresh.flushComplete",
                    fields: [
                        "tabCount": String(scopesByTabID.count),
                        "duration": AgentModePerfDiagnostics.formatElapsedMS(since: diagnosticsStartMS)
                    ]
                )
            }
        #endif
    }

    func removePendingUIRefresh(for tabID: UUID) {
        pendingUIRefreshScopesByTabID.removeValue(forKey: tabID)
        pendingAssistantPresentationByTabID.removeValue(forKey: tabID)
        guard pendingUIRefreshScopesByTabID.isEmpty, pendingAssistantPresentationByTabID.isEmpty else { return }
        uiRefreshTask?.cancel()
        uiRefreshTask = nil
    }

    private func performAssistantPresentationRefresh(
        session: TabSession,
        request: AssistantPresentationRequest
    ) {
        guard canAdmitAssistantPresentationRequest(request, session: session) else {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.assistantPresentation.rejectedAtFlush", tabID: session.tabID)
            #endif
            return
        }

        let didRefreshDerivedTranscript = withActiveUISyncSuppressed {
            catchUpDerivedTranscriptForActiveBindingIfNeeded(for: session, reason: .liveMutation)
        }
        guard canAdmitAssistantPresentationRequest(request, session: session) else {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.assistantPresentation.rejectedAfterCatchUp", tabID: session.tabID)
            #endif
            return
        }

        if !didRefreshDerivedTranscript {
            withActiveUISyncSuppressed {
                _ = publishTranscriptPresentation(from: session)
            }
        }
        syncTranscriptUIState()
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.assistantPresentation.published", tabID: session.tabID)
        #endif
    }

    private func performScopedUIRefresh(
        session: TabSession,
        scopes: Set<UIRefreshScope>
    ) {
        guard session.tabID == currentTabID else {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "ui.refresh.scopedSkipped",
                    tabID: session.tabID,
                    fields: [
                        "reason": "inactiveTab",
                        "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                        "scopes": scopes.map(\.rawValue).sorted().joined(separator: ",")
                    ]
                )
            #endif
            return
        }

        if scopes.contains(.transcriptRuntime) {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.refresh.flush.scope.transcriptRuntime", tabID: session.tabID)
            #endif
            let nextLiveBashExecutionByItemID = session.bashLiveExecutionByTranscriptItemID
            if activeBashLiveExecutionByItemID != nextLiveBashExecutionByItemID {
                activeBashLiveExecutionByItemID = nextLiveBashExecutionByItemID
            } else {
                syncTranscriptUIState()
            }
        }

        if scopes.contains(.runtimeMetrics) {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.refresh.flush.scope.runtimeMetrics", tabID: session.tabID)
            #endif
            let didChangeUsage = contextUsage != session.codexContextUsage
            let didChangeSnapshot = contextUsageSnapshot != session.contextUsageSnapshot
            if didChangeSnapshot {
                contextUsageSnapshot = session.contextUsageSnapshot
            }
            if didChangeUsage {
                contextUsage = session.codexContextUsage
            } else if didChangeSnapshot {
                syncRuntimeMetricsUIState()
            }
        }

        #if DEBUG
            AgentModePerfDiagnostics.event(
                "ui.refresh.scopedComplete",
                tabID: session.tabID,
                fields: [
                    "scopes": scopes.map(\.rawValue).sorted().joined(separator: ",")
                ]
            )
        #endif
    }

    func updateBindingsFromSession(_ session: TabSession) {
        #if DEBUG
            test_updateBindingsCallCount += 1
            let diagnosticsStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            AgentModePerfDiagnostics.increment("ui.updateBindings.called", tabID: session.tabID)
        #endif
        // Run-state transition observation runs before the inactive-tab guard
        // so background sessions still raise sidebar attention badges when
        // providers call updateBindings directly (e.g. draft attachments).
        observeSidebarRunStateTransition(for: session)
        guard session.tabID == currentTabID else {
            #if DEBUG
                AgentModePerfDiagnostics.increment("ui.updateBindings.skippedInactive", tabID: session.tabID)
                AgentModePerfDiagnostics.event(
                    "ui.updateBindings.skipped",
                    tabID: session.tabID,
                    fields: [
                        "reason": "inactiveTab",
                        "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID)
                    ]
                )
            #endif
            return
        }
        guard canBuildOrPublishActiveTranscriptBindings(for: session) else {
            publishLoadingTranscriptPresentation(tabID: session.tabID)
            return
        }

        var invalidation: ActiveUIInvalidation = []
        var shouldRefreshSidebarForRunState = false
        let previousTranscriptPresentation = activeTranscriptPresentation
        let previousTranscriptSnapshot = ui.transcript.snapshot
        let previousRunInteractionSnapshot = ui.runInteraction.snapshot

        if ui.composer.props.currentTabID != session.tabID {
            invalidation.insert(.composer)
        }
        if ui.statusPills.snapshot.currentTabID != session.tabID {
            invalidation.insert(.statusPills)
        }
        if previousTranscriptSnapshot.currentTabID != session.tabID {
            invalidation.insert(.transcript)
        }
        if previousRunInteractionSnapshot.currentTabID != session.tabID {
            invalidation.insert(.runInteraction)
        }

        withActiveUISyncSuppressed {
            isRestoringState = true
            defer { isRestoringState = false }

            catchUpDerivedTranscriptForActiveBindingIfNeeded(for: session, reason: .liveMutation)
            publishTranscriptPresentation(from: session)
            if activeTranscriptPresentation != previousTranscriptPresentation {
                invalidation.formUnion([.transcript, .runtimeMetrics, .runInteraction])
            }
            let nextLiveBashExecutionByItemID = session.bashLiveExecutionByTranscriptItemID
            if activeBashLiveExecutionByItemID != nextLiveBashExecutionByItemID {
                activeBashLiveExecutionByItemID = nextLiveBashExecutionByItemID
                invalidation.insert(.transcript)
            }
            if previousTranscriptSnapshot.runtimeFooterByItemID != session.agentMessageRuntimeFootersByItemID {
                invalidation.insert(.transcript)
            }
            if runState != session.runState {
                runState = session.runState
                invalidation.formUnion([.composer, .statusPills, .runInteraction])
                shouldRefreshSidebarForRunState = true
            }
            if waitingPrompt != session.uiWaitingPrompt {
                waitingPrompt = session.uiWaitingPrompt
                invalidation.formUnion([.composer, .runInteraction])
            }
            if runningStatusText != session.runningStatusText {
                runningStatusText = session.runningStatusText
                invalidation.insert(.runInteraction)
            }
            if activeAgentRunStartedAt != session.activeAgentRunStartedAt {
                activeAgentRunStartedAt = session.activeAgentRunStartedAt
                invalidation.insert(.runInteraction)
            }
            if pendingAskUser != session.uiPendingAskUser {
                pendingAskUser = session.uiPendingAskUser
                invalidation.insert(.runInteraction)
            }
            if previousRunInteractionSnapshot.pendingUserInputRequest != session.uiPendingUserInputRequest {
                invalidation.insert(.runInteraction)
            }
            if pendingApproval != session.uiPendingApproval {
                pendingApproval = session.uiPendingApproval
                invalidation.insert(.runInteraction)
            }
            if pendingPermissionsRequest != session.uiPendingPermissionsRequest {
                pendingPermissionsRequest = session.uiPendingPermissionsRequest
                invalidation.insert(.runInteraction)
            }
            if pendingApplyEditsReview != session.uiPendingApplyEditsReview {
                pendingApplyEditsReview = session.uiPendingApplyEditsReview
                invalidation.insert(.runInteraction)
            }
            if pendingWorktreeMergeReview != session.uiPendingWorktreeMergeReview {
                pendingWorktreeMergeReview = session.uiPendingWorktreeMergeReview
                invalidation.insert(.runInteraction)
            }
            if previousRunInteractionSnapshot.activeRunID != session.runID {
                invalidation.insert(.runInteraction)
            }
            let nextLatestUserSequenceIndex = session.items.last(where: { $0.kind == .user })?.sequenceIndex
            if previousRunInteractionSnapshot.latestUserSequenceIndex != nextLatestUserSequenceIndex {
                invalidation.insert(.runInteraction)
            }
            if previousRunInteractionSnapshot.canForkCurrentSession != canForkCurrentSession {
                invalidation.insert(.runInteraction)
            }
            if autoEditEnabled != session.autoEditEnabled {
                autoEditEnabled = session.autoEditEnabled
                invalidation.formUnion([.composer, .statusPills])
            }
            if updatePermissionBindingState(from: session, syncUI: false) {
                invalidation.formUnion([.composer, .statusPills])
            }
            if contextUsage != session.codexContextUsage {
                contextUsage = session.codexContextUsage
                invalidation.insert(.runtimeMetrics)
            }
            if contextUsageSnapshot != session.contextUsageSnapshot {
                contextUsageSnapshot = session.contextUsageSnapshot
                invalidation.insert(.runtimeMetrics)
            }
            let previousFollowBindingState = activeTranscriptFollowBindingState
            syncActiveTranscriptFollowBindings(from: session)
            if activeTranscriptFollowBindingState != previousFollowBindingState {
                invalidation.insert(.transcript)
            }
            if pendingImageAttachments != session.pendingImageAttachments {
                pendingImageAttachments = session.pendingImageAttachments
                invalidation.insert(.composer)
            }
            if pendingTaggedFileAttachments != session.pendingTaggedFileAttachments {
                pendingTaggedFileAttachments = session.pendingTaggedFileAttachments
                invalidation.insert(.composer)
            }
            if selectedAgent != session.selectedAgent {
                selectedAgent = session.selectedAgent
                invalidation.formUnion([.composer, .statusPills, .runtimeMetrics, .runInteraction])
            }
            if selectedModelRaw != session.selectedModelRaw {
                selectedModelRaw = session.selectedModelRaw
                invalidation.formUnion([.composer, .runtimeMetrics, .runInteraction])
            }
            if selectedReasoningEffortRaw != session.selectedReasoningEffortRaw {
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                invalidation.formUnion([.composer, .runInteraction])
            }
            if selectedWorkflow != session.selectedWorkflow {
                selectedWorkflow = session.selectedWorkflow
                invalidation.insert(.statusPills)
            }
        }
        if shouldRefreshSidebarForRunState {
            syncSidebarUIState(refresh: true, reason: .runState)
        }
        if refreshAutoEditPermissionGuidanceForActiveSession(syncUI: false) {
            invalidation.insert(.statusPills)
        }
        let runtimeSnapshot = ui.runtimeMetrics.runtimeVM.snapshot
        let analyticsSnapshot = session.transcriptAnalyticsSnapshot
        if runtimeSnapshot.estimatedTranscriptTokens != analyticsSnapshot.estimatedTranscriptTokens
            || runtimeSnapshot.observedReadFileCount != analyticsSnapshot.observedReadFiles.count
            || runtimeSnapshot.selectedAgent != session.selectedAgent
            || runtimeSnapshot.selectedModelRaw != session.selectedModelRaw
        {
            invalidation.insert(.runtimeMetrics)
        }
        if contextUsage == nil,
           analyticsSnapshot.latestWorkspaceContextItem != nil
           || analyticsSnapshot.latestManageSelectionItem != nil
           || analyticsSnapshot.latestContextBuilderItem != nil,
           runtimeSnapshot.usageSource == .unavailable
        {
            invalidation.insert(.runtimeMetrics)
        }
        if !invalidation.contains(.composer), ui.composer.props != makeComposerProps(tabID: session.tabID) {
            invalidation.insert(.composer)
        }
        if invalidation.isEmpty {
            #if DEBUG
                AgentModePerfDiagnostics.event("ui.updateBindings.noUISync", tabID: session.tabID)
            #endif
        } else {
            syncActiveUIState(tabID: session.tabID, invalidation: invalidation)
        }
        let visibleProjection = session.transcriptProjection
        let workingProjection = session.workingTranscriptProjection
        #if DEBUG
            if let diagnosticsStartMS {
                AgentModePerfDiagnostics.event(
                    "ui.updateBindings.complete",
                    tabID: session.tabID,
                    fields: [
                        "duration": AgentModePerfDiagnostics.formatElapsedMS(since: diagnosticsStartMS),
                        "runState": String(describing: session.runState),
                        "items": String(session.items.count),
                        "workingRows": String(workingProjection.workingRows.count),
                        "visibleRows": String(visibleProjection.archivedRows.count + visibleProjection.workingRows.count),
                        "pendingApproval": String(session.pendingApproval != nil),
                        "liveBash": String(session.bashLiveExecutionByKey.count),
                        "runtimeFooters": String(session.agentMessageRuntimeFootersByItemID.count),
                        "syncComposer": String(invalidation.contains(.composer)),
                        "syncStatus": String(invalidation.contains(.statusPills)),
                        "syncRuntime": String(invalidation.contains(.runtimeMetrics)),
                        "syncTranscript": String(invalidation.contains(.transcript)),
                        "syncRun": String(invalidation.contains(.runInteraction))
                    ]
                )
            }
            recordAgentPerfSessionSnapshot(session, source: "updateBindings")
        #endif
        Self.logCodexDebug("[AgentModeVM][Transcript] updateBindings tab=\(session.tabID) runState=\(session.runState) sourceItems=\(session.items.count) workingRows=\(workingProjection.workingRows.count) visibleRows=\(visibleProjection.archivedRows.count + visibleProjection.workingRows.count) archivedHidden=\(session.archivedTranscriptSnapshot.historyState.hasArchivedHistory && !session.isCompressedHistoryRevealed) pendingApproval=\(session.pendingApproval != nil)")
        Self.logCodexDebug(
            "[AgentModeVM][TranscriptOrder] updateBindings tab=\(session.tabID) sourceTail=\(Self.transcriptRowDebugWindow(session.items)) workingRowTail=\(Self.transcriptRowDebugWindow(workingProjection.workingRows)) workingBlockTail=\(Self.transcriptBlockDebugWindow(workingProjection.workingBlocks))"
        )
    }

    func selectWorkflow(_ workflow: AgentWorkflowDefinition?) {
        guard let tabID = currentTabID else { return }
        let session = session(for: tabID)
        session.selectedWorkflow = workflow
        selectedWorkflow = workflow
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    func normalizeTranscriptFollowStateForViewActivation(tabID: UUID?) {
        guard let tabID,
              let session = session(for: tabID, createIfNeeded: false)
        else {
            return
        }
        guard session.tabID == currentTabID || promptManager == nil else { return }
        applyTranscriptViewportBindingState(
            to: session,
            viewportState: .liveBottom,
            armingState: .armed
        )
        if session.tabID == currentTabID {
            syncActiveTranscriptFollowBindings(from: session)
        }
    }

    func setTranscriptAutoFollowArmingState(
        tabID: UUID,
        state: AgentTranscriptAutoFollowArmingState
    ) {
        let session = session(for: tabID)
        applyTranscriptViewportBindingState(
            to: session,
            viewportState: session.transcriptViewportState,
            armingState: state
        )
    }

    func setTranscriptDetachedFromLiveBottom(
        tabID: UUID,
        isDetached: Bool,
        armingState: AgentTranscriptAutoFollowArmingState? = nil
    ) {
        let session = session(for: tabID)
        if !isDetached {
            applyTranscriptViewportBindingState(
                to: session,
                viewportState: .liveBottom,
                armingState: .armed
            )
            return
        }

        applyTranscriptViewportBindingState(
            to: session,
            viewportState: AgentTranscriptViewportState(
                isDetachedFromLiveBottom: true,
                detachedAuthority: nil
            ),
            armingState: armingState
        )
    }

    /// Determine if an item should be shown in the transcript
    /// Hides ask_user / request_user_input tool calls when question UI is active to prevent duplicate UI.
    private func shouldDisplayInTranscript(_ item: AgentChatItem, session: TabSession) -> Bool {
        let include = AgentTranscriptIO.shouldIncludeLegacyItem(
            item,
            policy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI)
        )
        if !include {
            let reason = if AgentToolTrackingSupport.shouldHideToolFromTranscript(item.toolName) {
                "hidden-tool"
            } else if item.kind == .toolCall, isAskUserToolName(item.toolName), session.hasPendingQuestionUI {
                "pending-question-card"
            } else {
                "policy"
            }
            Self.logCodexDebug("[AgentModeVM][CodexUI] transcriptFilter drop kind=\(item.kind) tool=\(item.toolName ?? "nil") reason=\(reason)")
        }
        return include
    }

    private func scheduleDerivedTranscriptRefresh(
        for session: TabSession,
        reason: DerivedTranscriptRefreshReason,
        mutation: SourceItemsMutation? = nil
    ) {
        #if DEBUG
            let canScheduleAsyncRefresh = promptManager != nil || test_allowsScheduledDerivedTranscriptRefreshWithoutPromptManager
        #else
            let canScheduleAsyncRefresh = promptManager != nil
        #endif
        let scheduleSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.scheduleRefresh,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                sourceItemCount: session.items.count
            )
        )
        if reason == .liveMutation, let mutation {
            if var pendingSummary = session.pendingSourceItemsMutationSummary {
                pendingSummary.merge(mutation)
                session.pendingSourceItemsMutationSummary = pendingSummary
            } else {
                session.pendingSourceItemsMutationSummary = PendingSourceItemsMutationSummary(mutation)
            }
        } else if reason != .liveMutation {
            session.pendingSourceItemsMutationSummary = nil
        }
        #if DEBUG || EDIT_FLOW_PERF
            session.transcriptPerformanceSnapshot.refreshRequestCount += 1
        #endif

        guard reason == .liveMutation, canScheduleAsyncRefresh else {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.scheduleRefresh,
                scheduleSignpost,
                EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "immediate")
            )
            session.pendingDerivedTranscriptRefreshReason = nil
            session.derivedTranscriptRefreshGeneration &+= 1
            session.derivedTranscriptRefreshTask?.cancel()
            session.derivedTranscriptRefreshTask = nil
            #if DEBUG || EDIT_FLOW_PERF
                session.transcriptPerformanceSnapshot.refreshImmediateCount += 1
            #endif
            refreshDerivedTranscriptState(for: session, reason: reason)
            return
        }

        if session.derivedTranscriptRefreshTask != nil {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.scheduleRefresh,
                scheduleSignpost,
                EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "coalesced")
            )
            #if DEBUG || EDIT_FLOW_PERF
                session.transcriptPerformanceSnapshot.refreshCoalescedCount += 1
            #endif
            session.pendingDerivedTranscriptRefreshReason = .liveMutation
            return
        }

        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.scheduleRefresh,
            scheduleSignpost,
            EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "scheduled")
        )
        session.pendingDerivedTranscriptRefreshReason = .liveMutation
        session.derivedTranscriptRefreshGeneration &+= 1
        let scheduledGeneration = session.derivedTranscriptRefreshGeneration
        session.derivedTranscriptRefreshTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            guard !Task.isCancelled else { return }
            guard sessions[session.tabID] === session else { return }
            guard session.derivedTranscriptRefreshGeneration == scheduledGeneration else { return }
            let scheduledReason = session.pendingDerivedTranscriptRefreshReason ?? .liveMutation
            session.pendingDerivedTranscriptRefreshReason = nil
            session.derivedTranscriptRefreshTask = nil
            refreshDerivedTranscriptState(for: session, reason: scheduledReason)
        }
    }

    func refreshDerivedTranscriptState(
        for session: TabSession,
        reason: DerivedTranscriptRefreshReason = .manualRefresh
    ) {
        session.derivedTranscriptRefreshGeneration &+= 1
        session.derivedTranscriptRefreshTask?.cancel()
        session.derivedTranscriptRefreshTask = nil
        let pendingMutationSummary = reason == .liveMutation ? session.pendingSourceItemsMutationSummary : nil
        session.pendingSourceItemsMutationSummary = nil
        session.pendingDerivedTranscriptRefreshReason = nil
        #if DEBUG || EDIT_FLOW_PERF
            let refreshStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let refreshSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.refreshTotal,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                sourceItemCount: session.items.count
            )
        )
        let workingItemsSnapshot = session.items
        let existingTranscript = session.transcript
        let projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: existingTranscript
        )
        #if DEBUG
            let debugMetricsEnabled = AgentTranscriptDebugInstrumentation.isEnabled
            let debugPendingMutationSummary: String?
            var debugIncrementalPath: String?
            let debugRefreshInputSignature: String?
            if debugMetricsEnabled {
                debugPendingMutationSummary = pendingMutationSummary.map {
                    [
                        "earliest=\($0.earliestChangedIndex)",
                        "latest=\($0.latestChangedIndex)",
                        "removal=\($0.containsRemoval)",
                        "replaceAll=\($0.containsReplaceAll)",
                        "user=\($0.containsUserMutation)",
                        "structural=\($0.containsStructuralMutation)",
                        "allowsIncremental=\($0.allowsIncrementalFinalTurnRebuild)"
                    ].joined(separator: ",")
                } ?? "nil"
                debugIncrementalPath = {
                    guard reason == .liveMutation else { return "full-rebuild:reason-\(reason.rawValue)" }
                    guard session.pendingAskUser == nil else { return "full-rebuild:pending-question" }
                    guard let pendingMutationSummary else { return "full-rebuild:missing-mutation-summary" }
                    guard pendingMutationSummary.allowsIncrementalFinalTurnRebuild else {
                        return "full-rebuild:mutation-disallows-incremental"
                    }
                    return "incremental-attempt"
                }()
                debugRefreshInputSignature = AgentTranscriptDebugInstrumentation.stableDigest([
                    AgentTranscriptDebugInstrumentation.itemIdentitySignature(workingItemsSnapshot),
                    "sourceRevision=\(session.sourceItemsRevision)",
                    "nextSequence=\(session.nextSequenceIndex)",
                    "runState=\(session.runState.rawValue)",
                    "agent=\(session.selectedAgent.rawValue)",
                    "hidePendingQuestion=\(session.hasPendingQuestionUI)",
                    "projectionProtection=\(String(describing: projectionProtection))",
                    "compressedRevealed=\(session.isCompressedHistoryRevealed)"
                ])
            } else {
                debugPendingMutationSummary = nil
                debugIncrementalPath = nil
                debugRefreshInputSignature = nil
            }
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            var performanceSnapshot = session.transcriptPerformanceSnapshot
            performanceSnapshot.lastSourceItemCount = workingItemsSnapshot.count
        #endif
        let importPolicy = AgentTranscriptImportPolicy.liveSession(
            hidePendingQuestionToolCall: session.hasPendingQuestionUI
        )
        Self.logCodexDebug(
            "[AgentModeVM][TranscriptOrder] refreshDerived tab=\(session.tabID) selectedAgent=\(session.selectedAgent.rawValue) sourceTail=\(Self.transcriptRowDebugWindow(workingItemsSnapshot))"
        )
        #if DEBUG || EDIT_FLOW_PERF
            let importStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let importSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.importTranscript,
            EditFlowPerf.Dimensions(status: reason.rawValue, sourceItemCount: workingItemsSnapshot.count)
        )
        let importedTranscript: AgentTranscript
        var trustedIncrementalFinalTurnStartSequenceIndex: Int?
        if reason == .liveMutation,
           session.pendingAskUser == nil,
           let mutationSummary = pendingMutationSummary,
           mutationSummary.allowsIncrementalFinalTurnRebuild
        {
            #if DEBUG || EDIT_FLOW_PERF
                let incrementalImportStartedAt = CFAbsoluteTimeGetCurrent()
                var incrementalImportOutcome = "fallback"
            #endif
            let incrementalImportSignpost = EditFlowPerf.begin(
                EditFlowPerf.Stage.Transcript.incrementalImport,
                EditFlowPerf.Dimensions(sourceItemCount: workingItemsSnapshot.count)
            )
            let usesDurableFrontier = (existingTranscript.compactionFrontier?.frozenPrefixTurnCount ?? 0) > 0
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.incrementalImportAttemptCount += 1
                if usesDurableFrontier {
                    performanceSnapshot.frontierReuseAttemptCount += 1
                }
            #endif
            if let incrementallyUpdatedTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
                existingTranscript: existingTranscript,
                items: workingItemsSnapshot,
                earliestChangedIndex: mutationSummary.earliestChangedIndex,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            ) {
                importedTranscript = incrementallyUpdatedTranscript
                if workingItemsSnapshot.indices.contains(mutationSummary.earliestChangedIndex) {
                    trustedIncrementalFinalTurnStartSequenceIndex =
                        workingItemsSnapshot[mutationSummary.earliestChangedIndex].sequenceIndex
                }
                #if DEBUG
                    debugIncrementalPath = usesDurableFrontier ? "incremental-success:frontier" : "incremental-success:no-frontier"
                #endif
                #if DEBUG || EDIT_FLOW_PERF
                    incrementalImportOutcome = "success"
                    performanceSnapshot.incrementalImportSuccessCount += 1
                    if usesDurableFrontier {
                        performanceSnapshot.frontierReuseSuccessCount += 1
                    }
                #endif
            } else {
                importedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: existingTranscript,
                    workingItems: workingItemsSnapshot,
                    terminalState: session.runState,
                    nextSequenceIndex: session.nextSequenceIndex,
                    policy: importPolicy,
                    protection: projectionProtection
                )
                #if DEBUG
                    debugIncrementalPath = usesDurableFrontier ? "incremental-fallback:frontier-rejected" : "incremental-fallback:no-frontier-rejected"
                #endif
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.incrementalImportFallbackCount += 1
                    if usesDurableFrontier {
                        performanceSnapshot.frontierReuseFallbackCount += 1
                    }
                #endif
            }
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Transcript.incrementalImport,
                    incrementalImportSignpost,
                    EditFlowPerf.Dimensions(
                        outcome: incrementalImportOutcome,
                        sourceItemCount: workingItemsSnapshot.count
                    )
                )
                let incrementalImportDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - incrementalImportStartedAt) * 1000)
                performanceSnapshot.lastIncrementalImportDurationMS = incrementalImportDurationMS
                performanceSnapshot.maxIncrementalImportDurationMS = max(
                    performanceSnapshot.maxIncrementalImportDurationMS ?? 0,
                    incrementalImportDurationMS
                )
            #else
                EditFlowPerf.end(EditFlowPerf.Stage.Transcript.incrementalImport, incrementalImportSignpost)
            #endif
        } else {
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.lastIncrementalImportDurationMS = nil
            #endif
            importedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: existingTranscript,
                workingItems: workingItemsSnapshot,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            )
        }
        #if DEBUG
            if let debugPendingMutationSummary,
               let debugIncrementalPath,
               let debugRefreshInputSignature
            {
                AgentTranscriptDebugInstrumentation.emitRefreshAttempt(
                    tabID: session.tabID,
                    reason: reason.rawValue,
                    sourceItemsRevision: session.sourceItemsRevision,
                    itemCount: workingItemsSnapshot.count,
                    nextSequenceIndex: session.nextSequenceIndex,
                    runState: session.runState.rawValue,
                    selectedAgent: session.selectedAgent.rawValue,
                    projectionProtection: String(describing: projectionProtection),
                    pendingMutationSummary: debugPendingMutationSummary,
                    incrementalPath: debugIncrementalPath,
                    inputSignature: debugRefreshInputSignature
                )
            }
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.importTranscript,
            importSignpost,
            EditFlowPerf.Dimensions(status: reason.rawValue, sourceItemCount: workingItemsSnapshot.count)
        )
        #if DEBUG || EDIT_FLOW_PERF
            let importDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - importStartedAt) * 1000)
            performanceSnapshot.lastImportDurationMS = importDurationMS
            performanceSnapshot.maxImportDurationMS = max(
                performanceSnapshot.maxImportDurationMS ?? 0,
                importDurationMS
            )
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let previousPerformanceSnapshotForBuild = performanceSnapshot
        #else
            let previousPerformanceSnapshotForBuild = AgentTranscriptPerformanceSnapshot.empty
        #endif
        let builtPresentation = Self.buildTranscriptPresentation(
            from: importedTranscript,
            sourceItems: workingItemsSnapshot,
            precomputedEphemeralPayloadByItemID: session.ephemeralToolResultPayloadByItemID,
            precomputedEphemeralPayloadRevisionByItemID: session.ephemeralToolResultPayloadRevisionByItemID,
            selectedAgent: session.selectedAgent,
            previousPerformanceSnapshot: previousPerformanceSnapshotForBuild,
            previousSanitizedTranscript: existingTranscript,
            previousBaseProjection: session.baseTranscriptProjection,
            previousTurnProjectionCaches: session.turnProjectionCaches,
            previousProjectionProtection: session.transcriptProjectionProtection,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            isColdLoad: reason == .coldLoad,
            trustedIncrementalFinalTurnStartSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex
        )
        applyBuiltTranscriptPresentation(
            builtPresentation,
            sourceItems: workingItemsSnapshot,
            to: session
        )
        let hasCompactedTranscriptPrefix = builtPresentation.transcript.turns.contains { $0.retentionTier != .full }
        let canReconcileForStandardRetention = (!session.runState.isActive || hasCompactedTranscriptPrefix)
            && (session.runState != .completed || hasCompactedTranscriptPrefix)
        let containsExcludedLegacyItems = AgentTranscriptIO.containsExcludedLegacyItems(
            workingItemsSnapshot,
            policy: importPolicy
        )
        let fullDetailTurnEnvelopeChanged = AgentTranscriptIO.fullDetailTurnEnvelopeChanged(
            from: existingTranscript,
            to: builtPresentation.transcript
        )
        let shouldReconcileWorkingItems: Bool = {
            guard session.items == workingItemsSnapshot,
                  canReconcileForStandardRetention
            else {
                return false
            }
            return containsExcludedLegacyItems
                || fullDetailTurnEnvelopeChanged
                || builtPresentation.sanitizedActivityCount > 0
        }()
        let mayCompactActiveSummaryOnlyToolResults = !shouldReconcileWorkingItems
            && session.items == workingItemsSnapshot
            && session.runState.isActive
            && !hasCompactedTranscriptPrefix
            && builtPresentation.sanitizedActivityCount > 0
        let didApplyIncrementalSummaryOnlyCompaction: Bool = {
            guard builtPresentation.sanitizedActivityCount > 0,
                  !containsExcludedLegacyItems,
                  !fullDetailTurnEnvelopeChanged,
                  let mutationSummary = pendingMutationSummary,
                  mutationSummary.earliestChangedIndex == mutationSummary.latestChangedIndex,
                  workingItemsSnapshot.indices.contains(mutationSummary.earliestChangedIndex)
            else {
                return false
            }
            let changedIndex = mutationSummary.earliestChangedIndex
            let sourceItem = workingItemsSnapshot[changedIndex]
            guard let compactedItem = Self.transcriptItem(
                in: builtPresentation.transcript,
                matching: sourceItem
            ),
                let retainedRawPayload = session.ephemeralToolResultPayloadByItemID[sourceItem.id],
                Self.canApplyActiveSummaryOnlyToolResultCompaction(
                    from: sourceItem,
                    to: compactedItem,
                    retainedPayload: retainedRawPayload
                ),
                session.replaceItemSilentlyForRetentionCompaction(
                    at: changedIndex,
                    with: compactedItem,
                    retainedRawPayload: retainedRawPayload
                )
            else {
                return false
            }
            markDerivedTranscriptSynchronized(
                for: session,
                projectionProtection: builtPresentation.projectionProtection
            )
            return true
        }()
        if !didApplyIncrementalSummaryOnlyCompaction,
           shouldReconcileWorkingItems || mayCompactActiveSummaryOnlyToolResults
        {
            let trimmedWorkingItems = AgentTranscriptIO.workingSourceItems(from: builtPresentation.transcript)
            let canApplyWorkingItems = shouldReconcileWorkingItems
                || Self.canApplyActiveSummaryOnlyToolResultCompaction(
                    from: workingItemsSnapshot,
                    to: trimmedWorkingItems,
                    retainedPayloadByItemID: session.ephemeralToolResultPayloadByItemID
                )
            if canApplyWorkingItems, trimmedWorkingItems != session.items {
                let retainedPayloadByItemID = session.ephemeralToolResultPayloadByItemID
                let retainedPayloadRevisionByItemID = session.ephemeralToolResultPayloadRevisionByItemID
                let retainedTrimmedItemIDs = Set(trimmedWorkingItems.map(\.id))
                session.setItemsSilently(trimmedWorkingItems, reason: .retentionCompaction)
                session.replaceEphemeralToolResultPayloadMap(
                    retainedPayloadByItemID.filter { retainedTrimmedItemIDs.contains($0.key) },
                    liveItemIDs: retainedTrimmedItemIDs
                )
                session.ephemeralToolResultPayloadRevisionByItemID = retainedPayloadRevisionByItemID.filter {
                    retainedTrimmedItemIDs.contains($0.key) && session.ephemeralToolResultPayloadByItemID[$0.key] != nil
                }
                markDerivedTranscriptSynchronized(
                    for: session,
                    projectionProtection: builtPresentation.projectionProtection
                )
            }
        }
        #if DEBUG || EDIT_FLOW_PERF
            var finalPerformanceSnapshot = session.transcriptPerformanceSnapshot
            let refreshDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000)
            finalPerformanceSnapshot.lastRefreshTotalDurationMS = refreshDurationMS
            finalPerformanceSnapshot.maxRefreshTotalDurationMS = max(
                finalPerformanceSnapshot.maxRefreshTotalDurationMS ?? 0,
                refreshDurationMS
            )
            finalPerformanceSnapshot.lastSourceItemCount = session.items.count
            session.transcriptPerformanceSnapshot = finalPerformanceSnapshot
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.refreshTotal,
            refreshSignpost,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                lineCount: session.transcriptCanonicalVisibleRowCount,
                sourceItemCount: session.items.count
            )
        )
        if canBuildOrPublishActiveTranscriptBindings(for: session) {
            let publishSignpost = EditFlowPerf.begin(
                EditFlowPerf.Stage.Transcript.publish,
                EditFlowPerf.Dimensions(lineCount: session.transcriptCanonicalVisibleRowCount)
            )
            _ = publishTranscriptPresentation(from: session)
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.publish,
                publishSignpost,
                EditFlowPerf.Dimensions(lineCount: session.transcriptCanonicalVisibleRowCount)
            )
        }
    }

    nonisolated static func rebuildEphemeralToolResultPayloadMap(
        from items: [AgentChatItem],
        context: AgentToolResultProcessingContext? = nil
    ) -> [UUID: String] {
        Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                guard let retainedPayload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item, context: context) else {
                    return nil
                }
                return (item.id, retainedPayload)
            }
        )
    }

    private nonisolated static func visibleToolResultIDs(in projection: AgentTranscriptProjection) -> Set<UUID> {
        AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: projection)
    }

    private nonisolated static func degradeCollapsedTranscriptBlocksIfNeeded(
        _ projection: AgentTranscriptProjection,
        isColdLoad: Bool
    ) -> AgentTranscriptProjection {
        guard isColdLoad else { return projection }
        return AgentTranscriptProjection(
            workingBlocks: projection.workingBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            archivedBlocks: projection.archivedBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            workingRows: projection.workingRows,
            archivedRows: projection.archivedRows,
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex,
            workingUnitCount: projection.workingUnitCount
        )
    }

    private nonisolated static func degradeCollapsedTranscriptBlockIfNeeded(
        _ block: AgentTranscriptRenderBlock
    ) -> AgentTranscriptRenderBlock {
        guard block.defaultPresentation == .collapsed else { return block }
        if block.kind == .activityCluster, !block.rows.isEmpty {
            return AgentTranscriptRenderBlock(
                id: block.id,
                kind: block.kind,
                turnID: block.turnID,
                spanID: block.spanID,
                retentionTier: block.retentionTier,
                rows: [],
                isArchived: block.isArchived,
                primaryAnchor: block.primaryAnchor,
                anchorActivityID: block.anchorActivityID,
                activityIDs: block.activityIDs,
                clusterSummary: block.clusterSummary,
                groupedHistory: block.groupedHistory,
                defaultPresentation: block.defaultPresentation
            )
        }
        guard block.kind == .groupedHistory,
              let groupedHistory = block.groupedHistory,
              !groupedHistory.sections.isEmpty
        else {
            return block
        }
        return AgentTranscriptRenderBlock(
            id: block.id,
            kind: block.kind,
            turnID: block.turnID,
            spanID: block.spanID,
            retentionTier: block.retentionTier,
            rows: block.rows,
            isArchived: block.isArchived,
            primaryAnchor: block.primaryAnchor,
            anchorActivityID: block.anchorActivityID,
            activityIDs: block.activityIDs,
            clusterSummary: block.clusterSummary,
            groupedHistory: .init(summary: groupedHistory.summary, sections: []),
            defaultPresentation: block.defaultPresentation
        )
    }

    nonisolated static func transcriptProjectionProtection(
        for transcript: AgentTranscript,
        viewportState: AgentTranscriptViewportState
    ) -> AgentTranscriptProjectionProtection {
        guard !transcript.turns.isEmpty else { return .none }
        return AgentTranscriptProjectionBuilder.projectionProtection(
            for: transcript,
            viewportState: viewportState
        )
    }

    func transcriptProjectionProtection(
        for session: TabSession,
        transcript: AgentTranscript? = nil
    ) -> AgentTranscriptProjectionProtection {
        Self.transcriptProjectionProtection(
            for: transcript ?? session.transcript,
            viewportState: session.transcriptViewportState
        )
    }

    private func makeDerivedTranscriptSyncState(
        for session: TabSession,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> DerivedTranscriptSyncState {
        DerivedTranscriptSyncState(
            sourceItemsRevision: session.sourceItemsRevision,
            nextSequenceIndex: session.nextSequenceIndex,
            runState: session.runState,
            selectedAgent: session.selectedAgent,
            hidePendingQuestionToolCall: session.hasPendingQuestionUI,
            projectionProtection: projectionProtection
        )
    }

    private func markDerivedTranscriptSynchronized(
        for session: TabSession,
        projectionProtection: AgentTranscriptProjectionProtection
    ) {
        session.derivedTranscriptSyncState = makeDerivedTranscriptSyncState(
            for: session,
            projectionProtection: projectionProtection
        )
    }

    @discardableResult
    private func catchUpDerivedTranscriptForActiveBindingIfNeeded(
        for session: TabSession,
        reason: DerivedTranscriptRefreshReason,
        validateProjectionIntegrity: Bool = false
    ) -> Bool {
        guard canBuildOrPublishActiveTranscriptBindings(for: session) else { return false }
        guard !session.items.isEmpty || !session.transcript.turns.isEmpty else { return false }
        let projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: session.transcript
        )
        let canReuseDerivedTranscript = canReuseDerivedTranscriptForSave(
            for: session,
            projectionProtection: projectionProtection
        )
        let projectionLooksStale = validateProjectionIntegrity
            && canReuseDerivedTranscript
            && derivedTranscriptProjectionLooksStale(for: session)
        guard !canReuseDerivedTranscript || projectionLooksStale else { return false }
        session.derivedTranscriptRefreshGeneration &+= 1
        session.derivedTranscriptRefreshTask?.cancel()
        session.derivedTranscriptRefreshTask = nil
        let scheduledReason = session.pendingDerivedTranscriptRefreshReason ?? reason
        session.pendingDerivedTranscriptRefreshReason = nil
        refreshDerivedTranscriptState(for: session, reason: scheduledReason)
        return true
    }

    private func derivedTranscriptProjectionLooksStale(for session: TabSession) -> Bool {
        guard !session.transcript.turns.isEmpty else { return false }
        let expectedCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: session.transcript)
        if session.transcriptProjectionCounts != expectedCounts {
            return true
        }
        let visibleRowCount = session.transcriptProjection.archivedRows.count
            + session.transcriptProjection.workingRows.count
        let workingRowCount = session.workingTranscriptProjection.workingRows.count
        let presentedRowCount = max(visibleRowCount, workingRowCount)
        return presentedRowCount < expectedCounts.defaultPresentedRowCount
    }

    private nonisolated static func persistableSnapshot(
        from transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript?,
        workingItems: [AgentChatItem]
    ) -> PersistableTranscriptSnapshot {
        let sanitizeReusableTurnCount = commonEqualTurnPrefixCount(
            in: transcript,
            previousTranscript: previousSanitizedTranscript
        )
        let sanitizeMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            reusablePrefixTurnCount: sanitizeReusableTurnCount > 0 ? sanitizeReusableTurnCount : nil,
            context: AgentToolResultProcessingContext(),
            purpose: .runtimePresentation
        )
        let sanitizedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: sanitizeMetrics.transcript
        )
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: sanitizedTranscript)
        return PersistableTranscriptSnapshot(
            transcript: sanitizedTranscript,
            projectionCounts: projectionCounts,
            canonicalVisibleRowCount: projectionCounts.canonicalVisibleRowCount,
            lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: sanitizedTranscript)
                ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItems)
        )
    }

    private func persistableTranscriptSnapshot(
        for session: TabSession,
        workingItems: [AgentChatItem],
        existingTranscript: AgentTranscript,
        importPolicy: AgentTranscriptImportPolicy,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> PersistableTranscriptSnapshot {
        let transcriptSnapshot = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existingTranscript,
            workingItems: workingItems,
            terminalState: session.runState,
            nextSequenceIndex: session.nextSequenceIndex,
            policy: importPolicy,
            protection: projectionProtection
        )
        return Self.persistableSnapshot(
            from: transcriptSnapshot,
            previousSanitizedTranscript: existingTranscript,
            workingItems: workingItems
        )
    }

    func canReuseDerivedTranscriptForSave(
        for session: TabSession,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> Bool {
        session.derivedTranscriptSyncState == makeDerivedTranscriptSyncState(
            for: session,
            projectionProtection: projectionProtection
        )
    }

    private func builtTranscriptPresentationSnapshot(for session: TabSession) -> BuiltTranscriptPresentation {
        BuiltTranscriptPresentation(
            transcript: session.transcript,
            baseProjection: session.baseTranscriptProjection,
            fullProjection: session.fullTranscriptProjection,
            workingProjection: session.workingTranscriptProjection,
            projection: session.transcriptProjection,
            turnProjectionCaches: session.turnProjectionCaches,
            archivedSnapshot: session.archivedTranscriptSnapshot,
            projectionProtection: session.transcriptProjectionProtection,
            canonicalVisibleRowCount: session.transcriptCanonicalVisibleRowCount,
            projectionCounts: session.transcriptProjectionCounts,
            analyticsSnapshot: session.transcriptAnalyticsSnapshot,
            sanitizedActivityCount: 0,
            performanceSnapshot: session.transcriptPerformanceSnapshot,
            rawToolResultPayloadRenderRevision: session.rawToolResultPayloadRenderRevision
        )
    }

    nonisolated static func buildTranscriptPresentation(
        from transcript: AgentTranscript,
        sourceItems: [AgentChatItem],
        precomputedEphemeralPayloadByItemID: [UUID: String]? = nil,
        precomputedEphemeralPayloadRevisionByItemID: [UUID: Int]? = nil,
        selectedAgent: AgentProviderKind,
        previousPerformanceSnapshot: AgentTranscriptPerformanceSnapshot,
        previousSanitizedTranscript: AgentTranscript? = nil,
        previousBaseProjection: AgentTranscriptProjection? = nil,
        previousTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:],
        previousProjectionProtection: AgentTranscriptProjectionProtection = .none,
        projectionProtection: AgentTranscriptProjectionProtection = .none,
        isCompressedHistoryRevealed: Bool = false,
        isColdLoad: Bool = false,
        trustedIncrementalFinalTurnStartSequenceIndex: Int? = nil
    ) -> BuiltTranscriptPresentation {
        let processingContext = AgentToolResultProcessingContext()
        #if DEBUG || EDIT_FLOW_PERF
            let buildStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let projectionSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.projectionBuild,
            EditFlowPerf.Dimensions(sourceItemCount: sourceItems.count)
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let payloadSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.payloadMap,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: sourceItems.count
            )
        )
        let capturedPayloadByItemID: [UUID: String]
        let capturedPayloadRevisionByItemID: [UUID: Int]
        let payloadScannedItemCount: Int
        if let precomputedEphemeralPayloadByItemID {
            capturedPayloadByItemID = precomputedEphemeralPayloadByItemID
            capturedPayloadRevisionByItemID = precomputedEphemeralPayloadRevisionByItemID ?? [:]
            payloadScannedItemCount = 0
        } else {
            capturedPayloadByItemID = rebuildEphemeralToolResultPayloadMap(from: sourceItems, context: processingContext)
            capturedPayloadRevisionByItemID = Dictionary(
                uniqueKeysWithValues: capturedPayloadByItemID.keys.map { ($0, 1) }
            )
            payloadScannedItemCount = sourceItems.count
        }
        #if DEBUG || EDIT_FLOW_PERF
            let capturedPayloadBytes = capturedPayloadByItemID.values.reduce(0) {
                $0 + $1.lengthOfBytes(using: .utf8)
            }
        #else
            let capturedPayloadBytes = 0
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.payloadMap,
            payloadSignpost,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: payloadScannedItemCount,
                retainedPayloadCount: capturedPayloadByItemID.count,
                retainedPayloadBytes: capturedPayloadBytes
            )
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - payloadCaptureStartedAt) * 1000)
            var performanceSnapshot = previousPerformanceSnapshot
            let sanitizeStartedAt = CFAbsoluteTimeGetCurrent()
        #else
            var performanceSnapshot = AgentTranscriptPerformanceSnapshot.empty
        #endif
        let sanitizeSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.sanitize,
            EditFlowPerf.Dimensions(sourceItemCount: sourceItems.count)
        )
        let sanitizeReusableTurnCount = commonEqualTurnPrefixCount(
            in: transcript,
            previousTranscript: previousSanitizedTranscript
        )
        #if DEBUG || EDIT_FLOW_PERF
            if sanitizeReusableTurnCount > 0 {
                performanceSnapshot.sanitizeReuseAttemptCount += 1
            }
        #endif
        let sanitizeMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            reusablePrefixTurnCount: sanitizeReusableTurnCount > 0 ? sanitizeReusableTurnCount : nil,
            trustedIncrementalFinalTurnStartSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
            context: processingContext,
            purpose: .runtimePresentation
        )
        let sanitizedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: sanitizeMetrics.transcript,
            reusablePrefixTurnCount: sanitizeMetrics.reusedTurnCount
        )
        #if DEBUG || EDIT_FLOW_PERF
            if sanitizeReusableTurnCount > 0 {
                if sanitizeMetrics.reusedTurnCount > 0 {
                    performanceSnapshot.sanitizeReuseSuccessCount += 1
                } else {
                    performanceSnapshot.sanitizeReuseFallbackCount += 1
                }
                performanceSnapshot.lastSanitizeReusedTurnCount = sanitizeMetrics.reusedTurnCount
            } else {
                performanceSnapshot.lastSanitizeReusedTurnCount = nil
            }
            let sanitizeDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - sanitizeStartedAt) * 1000)
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.sanitize,
            sanitizeSignpost,
            EditFlowPerf.Dimensions(
                outcome: sanitizeMetrics.reusedTurnCount > 0 ? "reused_prefix" : "rebuilt",
                sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount
            )
        )
        let projectionReusableTurnCount = AgentTranscriptIO.validatedReusableFrozenPrefixTurnCount(in: sanitizedTranscript) ?? 0
        let baseProjection: AgentTranscriptProjection
        let updatedTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
        if projectionReusableTurnCount > 0,
           let previousSanitizedTranscript,
           !previousSanitizedTranscript.turns.isEmpty,
           let previousBaseProjection
        {
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.projectionReuseAttemptCount += 1
            #endif
            if let reusedProjection = AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(
                from: sanitizedTranscript,
                previousTranscript: previousSanitizedTranscript,
                previousProjection: previousBaseProjection,
                previousProtection: previousProjectionProtection,
                protection: projectionProtection,
                reusableFrozenPrefixTurnCount: projectionReusableTurnCount,
                context: processingContext
            ) {
                baseProjection = reusedProjection
                updatedTurnProjectionCaches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
                    for: sanitizedTranscript,
                    projection: reusedProjection,
                    protection: projectionProtection,
                    existingTurnCaches: previousTurnProjectionCaches
                )
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseSuccessCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = projectionReusableTurnCount
                #endif
            } else {
                let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: sanitizedTranscript,
                    protection: projectionProtection,
                    turnCaches: previousTurnProjectionCaches,
                    context: processingContext
                )
                baseProjection = buildResult.projection
                updatedTurnProjectionCaches = buildResult.updatedTurnCaches
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseFallbackCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = 0
                #endif
            }
        } else {
            let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: sanitizedTranscript,
                protection: projectionProtection,
                turnCaches: previousTurnProjectionCaches,
                context: processingContext
            )
            baseProjection = buildResult.projection
            updatedTurnProjectionCaches = buildResult.updatedTurnCaches
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.lastProjectionReusedTurnCount = nil
            #endif
        }
        let visibleRetainedIDs = visibleToolResultIDs(in: baseProjection)
        let rawToolResultPayloadRenderRevision = visibleRetainedIDs.reduce(0) { current, itemID in
            max(current, capturedPayloadRevisionByItemID[itemID] ?? 0)
        }
        let fullProjection = degradeCollapsedTranscriptBlocksIfNeeded(
            baseProjection,
            isColdLoad: isColdLoad
        )
        let workingProjection = AgentTranscriptProjectionBuilder.workingProjection(from: fullProjection)
        let archivedSnapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: fullProjection)
        let projection = isCompressedHistoryRevealed ? fullProjection : workingProjection
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: baseProjection)
        let canonicalVisibleRowCount = projectionCounts.canonicalVisibleRowCount
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled, let previousBaseProjection {
                let previousRows = previousBaseProjection.archivedRows + previousBaseProjection.workingRows
                let newRows = baseProjection.archivedRows + baseProjection.workingRows
                let previousBlocks = previousBaseProjection.archivedBlocks + previousBaseProjection.workingBlocks
                let newBlocks = baseProjection.archivedBlocks + baseProjection.workingBlocks
                let previousRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(previousRows)
                let newRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(newRows)
                let previousRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(previousRows)
                let newRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(newRows)
                let previousBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(previousBlocks)
                let newBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(newBlocks)
                let previousBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(previousBlocks)
                let newBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(newBlocks)
                AgentTranscriptDebugInstrumentation.projectionIdentityHandler?(.init(
                    previousRowCount: previousRows.count,
                    newRowCount: newRows.count,
                    previousBlockCount: previousBlocks.count,
                    newBlockCount: newBlocks.count,
                    rowSemanticDigest: newRowSemanticDigest,
                    previousRowSemanticDigest: previousRowSemanticDigest,
                    rowIdentityDigest: newRowIdentityDigest,
                    previousRowIdentityDigest: previousRowIdentityDigest,
                    blockSemanticDigest: newBlockSemanticDigest,
                    previousBlockSemanticDigest: previousBlockSemanticDigest,
                    blockIdentityDigest: newBlockIdentityDigest,
                    previousBlockIdentityDigest: previousBlockIdentityDigest,
                    rowIdentityDrift: newRowSemanticDigest == previousRowSemanticDigest && newRowIdentityDigest != previousRowIdentityDigest,
                    blockIdentityDrift: newBlockSemanticDigest == previousBlockSemanticDigest && newBlockIdentityDigest != previousBlockIdentityDigest
                ))
            }
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let buildDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - buildStartedAt) * 1000)
            performanceSnapshot.projectionBuildCount += 1
            performanceSnapshot.lastProjectionBuildDurationMS = buildDurationMS
            performanceSnapshot.lastPayloadCaptureDurationMS = payloadCaptureDurationMS
            performanceSnapshot.maxPayloadCaptureDurationMS = max(
                performanceSnapshot.maxPayloadCaptureDurationMS ?? 0,
                payloadCaptureDurationMS
            )
            performanceSnapshot.lastSanitizeDurationMS = sanitizeDurationMS
            performanceSnapshot.maxSanitizeDurationMS = max(
                performanceSnapshot.maxSanitizeDurationMS ?? 0,
                sanitizeDurationMS
            )
            performanceSnapshot.maxProjectionBuildDurationMS = max(
                performanceSnapshot.maxProjectionBuildDurationMS ?? 0,
                buildDurationMS
            )
            performanceSnapshot.lastPayloadCaptureScannedItemCount = payloadScannedItemCount
            performanceSnapshot.lastSanitizedActivityCount = sanitizeMetrics.sanitizedActivityCount
            performanceSnapshot.retainedRawPayloadEntryCount = capturedPayloadByItemID.count
            performanceSnapshot.retainedRawPayloadTotalBytes = capturedPayloadBytes
            let toolProcessingMetrics = processingContext.snapshotMetrics()
            performanceSnapshot.lastToolProcessingMetrics = toolProcessingMetrics
            performanceSnapshot.cumulativeToolProcessingMetrics.add(toolProcessingMetrics)
            EditFlowPerf.event(
                EditFlowPerf.Stage.Transcript.toolProcessing,
                EditFlowPerf.Dimensions(
                    sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes,
                    jsonParseAttemptCount: toolProcessingMetrics.jsonParseAttemptCount,
                    jsonParseCacheHitCount: toolProcessingMetrics.jsonParseCacheHitCount,
                    jsonParseCacheMissCount: toolProcessingMetrics.jsonParseCacheMissCount,
                    jsonParseSuccessCount: toolProcessingMetrics.jsonParseSuccessCount,
                    jsonParseFailureCount: toolProcessingMetrics.jsonParseFailureCount,
                    jsonParseByteCount: toolProcessingMetrics.jsonParseByteCount,
                    toolExecutionCacheHitCount: toolProcessingMetrics.toolExecutionCacheHitCount,
                    toolExecutionCacheMissCount: toolProcessingMetrics.toolExecutionCacheMissCount,
                    bashMetadataCacheHitCount: toolProcessingMetrics.bashMetadataCacheHitCount,
                    bashMetadataCacheMissCount: toolProcessingMetrics.bashMetadataCacheMissCount,
                    regexCaptureCallCount: toolProcessingMetrics.regexCaptureCallCount
                )
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.projectionBuild,
                projectionSignpost,
                EditFlowPerf.Dimensions(
                    outcome: performanceSnapshot.lastProjectionReusedTurnCount.map { $0 > 0 ? "reused_prefix" : "fallback" } ?? "built",
                    lineCount: canonicalVisibleRowCount,
                    sourceItemCount: sourceItems.count,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes
                )
            )
            if isColdLoad {
                performanceSnapshot.lastColdLoadProjectionBuildDurationMS = buildDurationMS
            }
        #endif
        return BuiltTranscriptPresentation(
            transcript: sanitizedTranscript,
            baseProjection: baseProjection,
            fullProjection: fullProjection,
            workingProjection: workingProjection,
            projection: projection,
            turnProjectionCaches: updatedTurnProjectionCaches,
            archivedSnapshot: archivedSnapshot,
            projectionProtection: projectionProtection,
            canonicalVisibleRowCount: canonicalVisibleRowCount,
            projectionCounts: projectionCounts,
            analyticsSnapshot: AgentTranscriptAnalyticsBuilder.build(
                from: sanitizedTranscript,
                selectedAgent: selectedAgent
            ),
            sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
            performanceSnapshot: performanceSnapshot,
            rawToolResultPayloadRenderRevision: rawToolResultPayloadRenderRevision
        )
    }

    private nonisolated static func commonEqualTurnPrefixCount(
        in transcript: AgentTranscript,
        previousTranscript: AgentTranscript?
    ) -> Int {
        guard let previousTranscript else { return 0 }
        let limit = min(transcript.turns.count, previousTranscript.turns.count)
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit,
              transcript.turns[count] == previousTranscript.turns[count]
        {
            count += 1
        }
        return count
    }

    private nonisolated static func canApplyActiveSummaryOnlyToolResultCompaction(
        from sourceItems: [AgentChatItem],
        to compactedItems: [AgentChatItem],
        retainedPayloadByItemID: [UUID: String]
    ) -> Bool {
        guard sourceItems.count == compactedItems.count else { return false }
        var foundSummaryOnlyToolResultCompaction = false
        for (sourceItem, compactedItem) in zip(sourceItems, compactedItems) {
            guard sourceItem != compactedItem else { continue }
            let retainedPayload = retainedPayloadByItemID[sourceItem.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard canApplyActiveSummaryOnlyToolResultCompaction(
                from: sourceItem,
                to: compactedItem,
                retainedPayload: retainedPayload
            ) else { return false }
            foundSummaryOnlyToolResultCompaction = true
        }
        return foundSummaryOnlyToolResultCompaction
    }

    private nonisolated static func canApplyActiveSummaryOnlyToolResultCompaction(
        from sourceItem: AgentChatItem,
        to compactedItem: AgentChatItem,
        retainedPayload: String
    ) -> Bool {
        guard sourceItem.id == compactedItem.id,
              sourceItem.timestamp == compactedItem.timestamp,
              sourceItem.kind == compactedItem.kind,
              sourceItem.attachments == compactedItem.attachments,
              sourceItem.taggedFileAttachments == compactedItem.taggedFileAttachments,
              sourceItem.toolName == compactedItem.toolName,
              sourceItem.toolInvocationID == compactedItem.toolInvocationID,
              sourceItem.toolArgsJSON == compactedItem.toolArgsJSON,
              sourceItem.reasoning == compactedItem.reasoning,
              sourceItem.sequenceIndex == compactedItem.sequenceIndex,
              sourceItem.isStreaming == compactedItem.isStreaming,
              sourceItem.workflow == compactedItem.workflow,
              sourceItem.codexGoalMode == compactedItem.codexGoalMode,
              sourceItem.isLocalControlPlaneEcho == compactedItem.isLocalControlPlaneEcho,
              sourceItem.kind == .toolResult,
              !sourceItem.isStreaming
        else {
            return false
        }
        let sourceResultJSON = sourceItem.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let compactedResultJSON = compactedItem.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourceResultJSON.isEmpty,
              sourceResultJSON != compactedResultJSON,
              retainedPayload.trimmingCharacters(in: .whitespacesAndNewlines) == sourceResultJSON,
              AgentTranscriptToolNormalizer.isSummaryOnly(raw: compactedResultJSON)
        else {
            return false
        }
        var expectedCompactedItem = sourceItem
        expectedCompactedItem.text = compactedItem.text
        expectedCompactedItem.toolResultJSON = compactedItem.toolResultJSON
        expectedCompactedItem.toolIsError = compactedItem.toolIsError
        return expectedCompactedItem == compactedItem
    }

    private nonisolated static func transcriptItem(
        in transcript: AgentTranscript,
        matching sourceItem: AgentChatItem
    ) -> AgentChatItem? {
        guard let finalTurn = transcript.turns.last else { return nil }
        for span in finalTurn.responseSpans.reversed() {
            guard let firstSequenceIndex = span.activities.first?.sequenceIndex,
                  let lastSequenceIndex = span.activities.last?.sequenceIndex,
                  sourceItem.sequenceIndex >= firstSequenceIndex,
                  sourceItem.sequenceIndex <= lastSequenceIndex
            else {
                continue
            }
            var lowerBound = span.activities.startIndex
            var upperBound = span.activities.endIndex
            while lowerBound < upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                if span.activities[midpoint].sequenceIndex < sourceItem.sequenceIndex {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            guard lowerBound < span.activities.endIndex,
                  span.activities[lowerBound].sequenceIndex == sourceItem.sequenceIndex,
                  span.activities[lowerBound].id == sourceItem.id
            else {
                continue
            }
            return span.activities[lowerBound].toItem()
        }
        return nil
    }

    private func applyBuiltTranscriptPresentation(
        _ presentation: BuiltTranscriptPresentation,
        sourceItems: [AgentChatItem]? = nil,
        to session: TabSession
    ) {
        if let sourceItems, sourceItems != session.items {
            Self.logCodexDebug(
                "[AgentModeVM][Transcript] skip applying stale built presentation tab=\(session.tabID) sourceItems=\(sourceItems.count) liveItems=\(session.items.count)"
            )
            session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
            return
        }
        session.transcript = presentation.transcript
        session.baseTranscriptProjection = presentation.baseProjection
        session.fullTranscriptProjection = presentation.fullProjection
        session.workingTranscriptProjection = presentation.workingProjection
        session.turnProjectionCaches = presentation.turnProjectionCaches
        session.archivedTranscriptSnapshot = presentation.archivedSnapshot
        session.transcriptProjection = materializedTranscriptProjection(for: session)
        session.transcriptProjectionProtection = presentation.projectionProtection
        session.transcriptCanonicalVisibleRowCount = presentation.canonicalVisibleRowCount
        session.transcriptProjectionCounts = presentation.projectionCounts
        session.transcriptAnalyticsSnapshot = presentation.analyticsSnapshot
        session.rawToolResultPayloadRenderRevision = presentation.rawToolResultPayloadRenderRevision
        #if DEBUG || EDIT_FLOW_PERF
            session.transcriptPerformanceSnapshot = presentation.performanceSnapshot
        #else
            session.transcriptPerformanceSnapshot = .empty
        #endif
        markDerivedTranscriptSynchronized(
            for: session,
            projectionProtection: presentation.projectionProtection
        )
        Self.logCodexDebug(
            "[AgentModeVM][TranscriptOrder] applyStructured tab=\(session.tabID) turns=\(presentation.transcript.turns.count) workingRowTail=\(Self.transcriptRowDebugWindow(presentation.workingProjection.workingRows)) workingBlockTail=\(Self.transcriptBlockDebugWindow(presentation.workingProjection.workingBlocks))"
        )
    }

    @discardableResult
    func applyTranscriptPresentation(
        _ transcript: AgentTranscript,
        sourceItems: [AgentChatItem]? = nil,
        to session: TabSession,
        isColdLoad: Bool = false
    ) -> BuiltTranscriptPresentation {
        let canonicalSourceItems = sourceItems ?? session.items
        let projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: transcript
        )
        let builtPresentation = Self.buildTranscriptPresentation(
            from: transcript,
            sourceItems: canonicalSourceItems,
            precomputedEphemeralPayloadByItemID: canonicalSourceItems == session.items ? session.ephemeralToolResultPayloadByItemID : nil,
            precomputedEphemeralPayloadRevisionByItemID: canonicalSourceItems == session.items ? session.ephemeralToolResultPayloadRevisionByItemID : nil,
            selectedAgent: session.selectedAgent,
            previousPerformanceSnapshot: session.transcriptPerformanceSnapshot,
            previousSanitizedTranscript: session.transcript,
            previousBaseProjection: session.baseTranscriptProjection,
            previousTurnProjectionCaches: session.turnProjectionCaches,
            previousProjectionProtection: session.transcriptProjectionProtection,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            isColdLoad: isColdLoad
        )
        applyBuiltTranscriptPresentation(
            builtPresentation,
            sourceItems: canonicalSourceItems,
            to: session
        )
        return builtPresentation
    }

    @discardableResult
    private func hydrateSession(
        _ session: TabSession,
        withCanonicalItems canonicalItems: [AgentChatItem],
        transcript: AgentTranscript,
        reason: TabSession.SilentItemReplacementReason,
        isColdLoad: Bool = false,
        builtPresentation: BuiltTranscriptPresentation? = nil
    ) -> BuiltTranscriptPresentation {
        session.setItemsSilently(canonicalItems, reason: reason)
        if let builtPresentation {
            applyBuiltTranscriptPresentation(
                builtPresentation,
                sourceItems: canonicalItems,
                to: session
            )
            return builtPresentation
        }
        return applyTranscriptPresentation(
            transcript,
            sourceItems: canonicalItems,
            to: session,
            isColdLoad: isColdLoad
        )
    }

    /// Check if tool name is an ask-user variant.
    private func isAskUserToolName(_ name: String?) -> Bool {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        if MCPIntegrationHelper.isRepoPromptAskUserToolName(trimmed) {
            return true
        }
        let lowered = trimmed.lowercased()
        return lowered == "request_user_input" || lowered == "requestuserinput" || lowered.hasSuffix(".requestuserinput")
    }

    private func resolvedSessionDisplayName(for tabID: UUID) -> String {
        normalizedSessionTitle(workspaceManager?.composeTabName(with: tabID))
    }

    func codexThreadDisplayName(for tabID: UUID) -> String {
        let composeName = workspaceManager?.composeTabName(with: tabID)
        if let composeName,
           !composeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return AgentSession.validatedName(composeName)
        }
        if let sessionID = boundSessionID(for: tabID),
           let entry = ownerValidatedSessionIndex[sessionID]
        {
            return AgentSession.validatedName(entry.name)
        }
        return AgentSession.validatedName(normalizedSessionTitle(composeName))
    }

    private func normalizedSessionTitle(_ raw: String?) -> String {
        AgentSessionRestoreSupport.normalizedSessionTitle(raw)
    }

    private static func transcriptRowDebugSummary(_ item: AgentChatItem) -> String {
        let label = item.toolName ?? item.kind.rawValue
        return "\(item.sequenceIndex):\(item.kind.rawValue):\(label):stream=\(item.isStreaming)"
    }

    private static func transcriptRowDebugWindow(_ items: [AgentChatItem], limit: Int = 8) -> String {
        guard !items.isEmpty else { return "[]" }
        let rows = Array(items.suffix(limit)).map(transcriptRowDebugSummary)
        return "[\(rows.joined(separator: ", "))]"
    }

    private static func transcriptBlockDebugSummary(_ block: AgentTranscriptRenderBlock) -> String {
        let rowSummary = block.rows.map { "\($0.sequenceIndex):\($0.kind.rawValue)" }.joined(separator: ",")
        return "\(block.kind.rawValue){\(rowSummary)}"
    }

    private static func transcriptBlockDebugWindow(_ blocks: [AgentTranscriptRenderBlock], limit: Int = 8) -> String {
        guard !blocks.isEmpty else { return "[]" }
        let tail = Array(blocks.suffix(limit)).map(transcriptBlockDebugSummary)
        return "[\(tail.joined(separator: " | "))]"
    }

    func upsertSessionIndex(
        sessionID: UUID,
        tabID: UUID,
        name: String,
        lastUserMessageAt: Date?,
        savedAt: Date,
        lastRunStateRaw: String?,
        itemCount: Int,
        agentKindRaw: String?,
        agentModelRaw: String?,
        agentReasoningEffortRaw: String?,
        autoEditEnabled: Bool,
        parentSessionID: UUID? = nil,
        hasUnknownConversationContent: Bool = false,
        isMCPOriginated: Bool = false,
        worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] = [],
        activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = []
    ) {
        applyLocalSessionIndexUpsert(AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: name,
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt,
            lastRunStateRaw: lastRunStateRaw,
            itemCount: itemCount,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: agentReasoningEffortRaw,
            autoEditEnabled: autoEditEnabled,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: hasUnknownConversationContent,
            isMCPOriginated: isMCPOriginated,
            worktreeBindingSummaries: worktreeBindingSummaries,
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries
        ))
    }

    private func cleanupMCPRunRoutingIfPresent(
        boundSessionID: UUID?,
        liveSession: TabSession?,
        explicitRunID: UUID? = nil,
        reason: String
    ) async {
        _ = boundSessionID
        guard let runID = explicitRunID ?? liveSession?.runID else { return }
        _ = mcpRunToolCanceller(runID, reason)
        await mcpRunRoutingCleaner(runID, windowID, reason)
    }

    func removeSessionIndex(sessionID: UUID) {
        applyLocalSessionIndexRemoval(sessionID: sessionID)
    }

    private func removeSessionIndex(forTabID tabID: UUID) {
        let ids = ownerValidatedSessionIndex.values.filter { $0.tabID == tabID }.map(\.id)
        for id in ids {
            applyLocalSessionIndexRemoval(sessionID: id)
        }
    }

    private func rebuildSessionSortDatesFromIndex() {
        #if DEBUG
            let rebuildStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            let debugSessionIndexCount = sessionIndex.count
        #endif
        var preferredEntryByTabID: [UUID: AgentSessionIndexEntry] = [:]
        for entry in sessionIndex.values where entry.lastUserMessageAt != nil {
            if let existing = preferredEntryByTabID[entry.tabID] {
                if AgentSessionRestoreSupport.shouldPreferSidebarEntry(entry, over: existing) {
                    preferredEntryByTabID[entry.tabID] = entry
                }
            } else {
                preferredEntryByTabID[entry.tabID] = entry
            }
        }
        var sortDates: [UUID: Date] = [:]
        for (tabID, entry) in preferredEntryByTabID {
            if let date = entry.lastUserMessageAt {
                sortDates[tabID] = date
            }
        }
        sessionListSortDatesOwner = sessionIndexOwner
        if sessionListSortDates != sortDates {
            sessionListSortDates = sortDates
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.vm.rebuildSessionSortDates",
                startMS: rebuildStartMS,
                fields: [
                    "sessionIndexCount": String(debugSessionIndexCount),
                    "sortDateCount": String(sortDates.count)
                ]
            )
        #endif
    }

    private var activeWorkspaceIDForSessionIndexOwnership: UUID? {
        #if DEBUG
            if let test_activeWorkspaceIDForSessionIndexOverride {
                return test_activeWorkspaceIDForSessionIndexOverride
            }
        #endif
        return workspaceManager?.activeWorkspaceID ?? lastKnownWorkspaceSnapshot?.id
    }

    private func receiveWorkspaceSwitchNotification(_ workspace: WorkspaceModel?) -> SessionIndexOwner {
        sessionIndexActivationEpoch &+= 1
        let owner = SessionIndexOwner(
            workspaceID: workspace?.id,
            activationEpoch: sessionIndexActivationEpoch
        )
        latestSessionIndexOwner = owner
        return owner
    }

    private func isWorkspaceActivationCurrent(
        _ owner: SessionIndexOwner,
        workspace: WorkspaceModel?
    ) -> Bool {
        guard latestSessionIndexOwner == owner,
              owner.workspaceID == workspace?.id
        else {
            return false
        }
        if let workspaceManager {
            return workspaceManager.activeWorkspaceID == owner.workspaceID
        }
        #if DEBUG
            if let test_activeWorkspaceIDForSessionIndexOverride {
                return test_activeWorkspaceIDForSessionIndexOverride == owner.workspaceID
            }
        #endif
        return true
    }

    private func isSessionIndexOwnerCurrent(_ owner: SessionIndexOwner) -> Bool {
        guard latestSessionIndexOwner == owner,
              sessionIndexOwner == owner
        else {
            return false
        }
        return activeWorkspaceIDForSessionIndexOwnership == owner.workspaceID
    }

    var ownerValidatedSessionIndex: [UUID: AgentSessionIndexEntry] {
        guard let owner = sessionIndexOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return [:]
        }
        return sessionIndex
    }

    var ownerValidatedSessionListSortDates: [UUID: Date] {
        guard let owner = sessionListSortDatesOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return [:]
        }
        return sessionListSortDates
    }

    var ownerValidatedSessionListCacheReady: Bool {
        guard let owner = sessionListCacheReadyOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return false
        }
        return sessionListCacheReady
    }

    func sidebarAutoArchiveOwner(workspaceID: UUID) -> SessionIndexOwner? {
        guard sessionListCacheReady,
              let owner = sessionListCacheReadyOwner,
              owner.workspaceID == workspaceID,
              isSessionIndexOwnerCurrent(owner)
        else {
            return nil
        }
        return owner
    }

    var ownerValidatedSidebarRestoreFrozenOrderByTabID: [UUID: Int] {
        guard let owner = sidebarRestoreFrozenOrderOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return [:]
        }
        return sidebarRestoreFrozenOrderByTabID
    }

    private func releaseSidebarRestoreFrozenOrder(for owner: SessionIndexOwner) {
        guard sidebarRestoreFrozenOrderOwner == owner else { return }
        sidebarRestoreFrozenOrderByTabID.removeAll()
        sidebarRestoreFrozenOrderOwner = nil
    }

    private func setSessionListCacheReady(_ ready: Bool, for owner: SessionIndexOwner) {
        guard isSessionIndexOwnerCurrent(owner) else { return }
        sessionListCacheReadyOwner = owner
        sessionListCacheReady = ready
    }

    private func cancelSessionIndexRefresh(
        releaseFrozenOrder: Bool,
        owner: SessionIndexOwner? = nil
    ) {
        let refreshOwner = owner ?? activeSessionIndexRefreshToken?.owner
        if let token = activeSessionIndexRefreshToken,
           isSessionIndexOwnerCurrent(token.owner)
        {
            publishSessionIndexReplacement(activeSessionIndexRefreshBaselineEntries, token: token)
        }
        sessionListCacheTask?.cancel()
        sessionListCacheTask = nil
        activeSessionIndexRefreshToken = nil
        activeSessionIndexRefreshWorkspace = nil
        activeSessionIndexRefreshValidTabIDs.removeAll()
        activeSessionIndexRefreshBoundSessionIDByTabID.removeAll()
        activeSessionIndexRefreshBaselineEntries.removeAll()
        activeSessionIndexRefreshPrioritizedEntries.removeAll()
        activeSessionIndexRefreshFullEntries.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        if releaseFrozenOrder, let refreshOwner {
            releaseSidebarRestoreFrozenOrder(for: refreshOwner)
        }
    }

    private func installSessionIndexOwner(
        _ owner: SessionIndexOwner,
        workspace: WorkspaceModel?
    ) {
        guard isWorkspaceActivationCurrent(owner, workspace: workspace) else { return }
        cancelSessionIndexRefresh(releaseFrozenOrder: false)
        sessionIndexOwner = owner
        sessionListSortDatesOwner = owner
        sessionListCacheReadyOwner = owner
        sessionIndexLocalUpserts.removeAll()
        sessionIndexLocalRemovals.removeAll()
        sessionIndex.removeAll()
        sessionListSortDates.removeAll()
        sessionListCacheReady = false
        if let workspace {
            sidebarRestoreFrozenOrderByTabID = makeSidebarRestoreFrozenOrder(for: workspace)
            sidebarRestoreFrozenOrderOwner = owner
        } else {
            sidebarRestoreFrozenOrderByTabID.removeAll()
            sidebarRestoreFrozenOrderOwner = nil
        }
        lastSidebarContentFingerprint = nil
    }

    private func sessionIndexEntriesApplyingLocalOverlay(
        to base: [UUID: AgentSessionIndexEntry]
    ) -> [UUID: AgentSessionIndexEntry] {
        var result = base
        for (sessionID, entry) in sessionIndexLocalUpserts {
            result[sessionID] = entry
        }
        for sessionID in sessionIndexLocalRemovals {
            result.removeValue(forKey: sessionID)
        }
        return result
    }

    private func publishSessionIndexReplacement(
        _ base: [UUID: AgentSessionIndexEntry],
        token: SessionIndexRefreshToken
    ) {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            return
        }
        let replacement = sessionIndexEntriesApplyingLocalOverlay(to: base)
        if sessionIndex != replacement {
            sessionIndex = replacement
        }
        rebuildSessionSortDatesFromIndex()
    }

    private func applyLocalSessionIndexUpsert(_ entry: AgentSessionIndexEntry) {
        guard let owner = sessionIndexOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return
        }
        sessionIndexLocalRemovals.remove(entry.id)
        sessionIndexLocalUpserts[entry.id] = entry
        var updated = sessionIndex
        updated[entry.id] = entry
        if sessionIndex != updated {
            sessionIndex = updated
        }
        rebuildSessionSortDatesFromIndex()
    }

    private func applyLocalSessionIndexRemoval(sessionID: UUID) {
        guard let owner = sessionIndexOwner,
              isSessionIndexOwnerCurrent(owner)
        else {
            return
        }
        sessionIndexLocalUpserts.removeValue(forKey: sessionID)
        sessionIndexLocalRemovals.insert(sessionID)
        if sessionIndex.removeValue(forKey: sessionID) != nil {
            rebuildSessionSortDatesFromIndex()
        }
    }

    private func currentWorkspaceSnapshot(for owner: SessionIndexOwner) -> WorkspaceModel? {
        if let workspace = workspaceManager?.activeWorkspace,
           workspace.id == owner.workspaceID
        {
            return workspace
        }
        if let workspace = lastKnownWorkspaceSnapshot,
           workspace.id == owner.workspaceID
        {
            return workspace
        }
        return nil
    }

    // MARK: - Workspace Handling

    private struct WorkspaceSwitchSessionCleanupTarget {
        let tabID: UUID
        let session: TabSession
        let boundSessionID: UUID?
        let providerSessionID: String?
        let runID: UUID?
        let selectedAgent: AgentProviderKind
    }

    private func prepareWorkspaceSwitchSessionDiscard(
        _ session: TabSession,
        reason: String
    ) -> WorkspaceSwitchSessionCleanupTarget {
        let target = WorkspaceSwitchSessionCleanupTarget(
            tabID: session.tabID,
            session: session,
            boundSessionID: boundSessionID(for: session.tabID),
            providerSessionID: session.providerSessionID,
            runID: session.runID,
            selectedAgent: session.selectedAgent
        )
        removePendingUIRefresh(for: session.tabID)
        cancelPersistedLoad(for: session)
        session.derivedTranscriptRefreshTask?.cancel()
        session.derivedTranscriptRefreshTask = nil
        session.pendingDerivedTranscriptRefreshReason = nil
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningByKey.removeAll()
        session.claudeSteeringFlushTask?.cancel()
        session.claudeSteeringFlushTask = nil
        session.acpSteeringFlushTask?.cancel()
        session.acpSteeringFlushTask = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        clearPendingAssistantDelta(session)
        cancelPendingQuestion(for: session)
        cancelPendingApproval(for: session)
        session.pendingApplyEditsReview = nil
        reconcileInteractiveRunState(session)
        cancelPendingInstruction(for: session)
        session.agentTask?.cancel()
        session.agentTask = nil
        session.codexEventTask?.cancel()
        session.codexEventTask = nil
        session.codexEventTaskRunID = nil
        if let runID = session.runID {
            _ = mcpRunToolCanceller(runID, "workspace_switch")
        }
        session.applyEditsApprovalSubscriptionTask?.cancel()
        session.applyEditsApprovalSubscriptionTask = nil
        session.applyEditsApprovalSubscriptionID = nil
        return target
    }

    private func scheduleWorkspaceSwitchBackgroundCleanup(
        targets: [WorkspaceSwitchSessionCleanupTarget],
        reason: String
    ) {
        guard !targets.isEmpty else { return }
        let cleanupID = UUID()
        let task = Task(priority: .utility) { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            for target in targets {
                await teardownMCPControl(
                    for: target.session,
                    cleanupSessionStore: true,
                    publishChanges: false,
                    deactivateLiveControlContext: false
                )
                await cleanupMCPRunRoutingIfPresent(
                    boundSessionID: target.boundSessionID,
                    liveSession: target.session,
                    explicitRunID: target.runID,
                    reason: reason
                )
                await Task.yield()
            }
            let codexCoordinator = codexCoordinator
            let claudeCoordinator = claudeCoordinator
            workspaceSwitchBackgroundCleanupTasks.removeValue(forKey: cleanupID)
            for target in targets {
                await Self.disposeDetachedWorkspaceSwitchTarget(
                    target,
                    codexCoordinator: codexCoordinator,
                    claudeCoordinator: claudeCoordinator
                )
                await Task.yield()
            }
        }
        workspaceSwitchBackgroundCleanupTasks[cleanupID] = task
    }

    private static func disposeDetachedWorkspaceSwitchTarget(
        _ target: WorkspaceSwitchSessionCleanupTarget,
        codexCoordinator: CodexAgentModeCoordinator,
        claudeCoordinator: ClaudeAgentModeCoordinator
    ) async {
        let session = target.session
        let provider = session.provider
        session.provider = nil
        if let provider {
            await provider.dispose()
        }
        session.acpSteeringFlushTask?.cancel()
        session.acpSteeringFlushTask = nil
        session.pendingACPSteeringInstructions.removeAll()
        if let controller = session.acpController {
            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await controller.cancelPrompt()
            await controller.shutdown()
        }
        await codexCoordinator.shutdownCodexSession(
            session,
            clearTabScopedCoordinatorState: false,
            detachedRunID: target.runID
        )
        await claudeCoordinator.shutdownClaudeSession(
            session,
            clearTabScopedCoordinatorState: false
        )
    }

    func handleWorkspaceSwitch(_ workspace: WorkspaceModel?) async {
        let owner = receiveWorkspaceSwitchNotification(workspace)
        await handleWorkspaceSwitch(workspace, owner: owner)
    }

    private func handleWorkspaceSwitch(
        _ workspace: WorkspaceModel?,
        owner: SessionIndexOwner
    ) async {
        guard isWorkspaceActivationCurrent(owner, workspace: workspace) else { return }
        lastKnownWorkspaceSnapshot = workspace
        installSessionIndexOwner(owner, workspace: workspace)
        guard isSessionIndexOwnerCurrent(owner) else { return }
        #if DEBUG
            let workspaceSwitchStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let workspaceSwitchInitialSessions = sessions.count
            let workspaceSwitchInitialActiveTabID = workspace?.activeComposeTabID
            WorkspaceRestorePerfLog.event(
                "agentMode.workspaceSwitch.begin",
                fields: [
                    "windowID": "\(windowID)",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace?.id),
                    "hasWorkspace": "\(workspace != nil)",
                    "sessionsBefore": "\(workspaceSwitchInitialSessions)",
                    "activeTabID": WorkspaceRestorePerfLog.shortID(workspaceSwitchInitialActiveTabID),
                    "isSystemWorkspace": "\(workspace?.isSystemWorkspace ?? false)"
                ]
            )
        #endif
        if workspace?.isSystemWorkspace == false {
            finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: false)
        }
        let initialActiveTabID = workspace?.activeComposeTabID
        workspaceSwitchInFlight = workspace != nil
        activeSessionLoadInProgressTabID = initialActiveTabID
        if workspace != nil {
            publishLoadingTranscriptPresentation(tabID: initialActiveTabID)
        }
        codexCoordinator.stop()
        claudeCoordinator.stop()
        stopOpenCodeModelsSubscription()
        stopCursorModelsSubscription()
        sidebarAutoArchiveTask?.cancel()
        sidebarAutoArchiveTask = nil
        uiRefreshTask?.cancel()
        uiRefreshTask = nil
        pendingUIRefreshScopesByTabID.removeAll()
        pendingAssistantPresentationByTabID.removeAll()

        #if DEBUG
            let teardownStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let teardownSessionCount = sessions.count
        #endif
        let cleanupTargets = sessions.values.map {
            prepareWorkspaceSwitchSessionDiscard(
                $0,
                reason: "Cancelled due to workspace switch"
            )
        }
        for sessionID in Set(cleanupTargets.compactMap(\.boundSessionID)) {
            await releaseSessionWorktreeOwnership(sessionID: sessionID)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentMode.workspaceSwitch.discardPrepared",
                fields: [
                    "windowID": "\(windowID)",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace?.id),
                    "sessionCount": "\(teardownSessionCount)",
                    "duration": teardownStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let clearStateStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        sessions.removeAll()
        lastProcessedTabID = nil
        if workspace == nil {
            workspaceSwitchInFlight = false
            clearBindings()
        }
        tabsWithActiveAgentRun.removeAll()
        mcpControlledTabIDs.removeAll()
        tabDraftText.removeAll()
        sidebarObservedRunStateByTabID.removeAll()
        await applyEditsApprovalStore.cleanupWindowScopes(
            windowID: windowID,
            reason: "Cancelled due to workspace switch"
        )
        scheduleWorkspaceSwitchBackgroundCleanup(
            targets: cleanupTargets,
            reason: "workspace_switch"
        )
        guard isWorkspaceActivationCurrent(owner, workspace: workspace),
              isSessionIndexOwnerCurrent(owner)
        else {
            return
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentMode.workspaceSwitch.clearState",
                fields: [
                    "windowID": "\(windowID)",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace?.id),
                    "duration": clearStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        scheduleSkillCatalogRefresh()

        guard let workspace else {
            activeSessionLoadInProgressTabID = nil
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentMode.workspaceSwitch.end",
                    fields: [
                        "windowID": "\(windowID)",
                        "workspaceID": WorkspaceRestorePerfLog.shortID(nil),
                        "outcome": "noWorkspace",
                        "duration": workspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        refreshSessionListCache(for: workspace, owner: owner)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentMode.workspaceSwitch.refreshScheduled",
                fields: [
                    "windowID": "\(windowID)",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "activeTabID": WorkspaceRestorePerfLog.shortID(workspace.activeComposeTabID),
                    "frozenOrderTabs": "\(sidebarRestoreFrozenOrderByTabID.count)"
                ]
            )
        #endif
        let resolvedActiveTabID = workspace.activeComposeTabID
        if let resolvedActiveTabID {
            activeSessionLoadInProgressTabID = resolvedActiveTabID
            onTabChanged(resolvedActiveTabID, allowDuringWorkspaceSwitch: true)
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentMode.workspaceSwitch.end",
                    fields: [
                        "windowID": "\(windowID)",
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "outcome": "activeTabChanged",
                        "duration": workspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        activeSessionLoadInProgressTabID = nil
        if workspace.composeTabs.isEmpty {
            workspaceSwitchInFlight = false
            clearBindings()
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentMode.workspaceSwitch.end",
                    fields: [
                        "windowID": "\(windowID)",
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "outcome": "emptyWorkspace",
                        "duration": workspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        } else {
            setActiveTranscriptBindingsHydrated(true)
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "agentMode.workspaceSwitch.end",
                    fields: [
                        "windowID": "\(windowID)",
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "outcome": "bindingsHydrated",
                        "duration": workspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        }
    }

    private func persistedSidebarTabs(for workspace: WorkspaceModel) -> [ComposeTabState] {
        let activeTabIDs = Set(workspace.composeTabs.map(\.id))
        return workspace.composeTabs + workspace.stashedTabs.map(\.tab)
            .filter { !activeTabIDs.contains($0.id) }
    }

    private func makeSidebarRestoreFrozenOrder(for workspace: WorkspaceModel) -> [UUID: Int] {
        var orderByTabID: [UUID: Int] = [:]
        for (index, tab) in persistedSidebarTabs(for: workspace).enumerated() where orderByTabID[tab.id] == nil {
            orderByTabID[tab.id] = index
        }
        return orderByTabID
    }

    private func invalidateSidebarRestoreOrdering() {
        sidebarRestoreFrozenOrderByTabID.removeAll()
        sidebarRestoreFrozenOrderOwner = nil
    }

    nonisolated static func shouldSkipSessionListCacheRefresh(
        for workspace: WorkspaceModel,
        isInitialSystemWorkspaceRefreshDeferred: Bool
    ) -> Bool {
        workspace.isSystemWorkspace && isInitialSystemWorkspaceRefreshDeferred
    }

    private func refreshSessionListCache(
        for workspace: WorkspaceModel,
        owner explicitOwner: SessionIndexOwner? = nil
    ) {
        guard let owner = explicitOwner ?? sessionIndexOwner,
              owner.workspaceID == workspace.id,
              isSessionIndexOwnerCurrent(owner)
        else {
            return
        }

        #if DEBUG
            let requestBuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let persistedTabs = persistedSidebarTabs(for: workspace)
        var tabNameByID: [UUID: String] = [:]
        tabNameByID.reserveCapacity(persistedTabs.count)
        for tab in persistedTabs {
            tabNameByID[tab.id] = tab.name
        }
        let validTabIDs = Set(tabNameByID.keys)
        var boundSessionIDByTabID: [UUID: UUID] = [:]
        boundSessionIDByTabID.reserveCapacity(persistedTabs.count)
        for tab in persistedTabs {
            if let activeAgentSessionID = tab.activeAgentSessionID {
                boundSessionIDByTabID[tab.id] = activeAgentSessionID
            }
        }
        for session in sessions.values where validTabIDs.contains(session.tabID) {
            if let sessionID = session.activeAgentSessionID {
                boundSessionIDByTabID[session.tabID] = sessionID
            } else {
                boundSessionIDByTabID.removeValue(forKey: session.tabID)
            }
        }
        let prioritizedTabID = workspace.activeComposeTabID
        let fullRequest = AgentSessionSidebarBuildRequest(
            workspace: workspace,
            tabNameByID: tabNameByID,
            validTabIDs: validTabIDs,
            boundSessionIDByTabID: boundSessionIDByTabID,
            prioritizedTabID: nil
        )
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.requestBuilt",
                fields: [
                    "windowID": "\(windowID)",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "activationEpoch": "\(owner.activationEpoch)",
                    "duration": requestBuildStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                    "persistedTabs": "\(persistedTabs.count)",
                    "validTabs": "\(validTabIDs.count)",
                    "boundSessions": "\(boundSessionIDByTabID.count)",
                    "frozenOrderTabs": "\(ownerValidatedSidebarRestoreFrozenOrderByTabID.count)",
                    "hasPrioritizedTab": "\(prioritizedTabID != nil)",
                    "prioritizedTabID": WorkspaceRestorePerfLog.shortID(prioritizedTabID),
                    "isSystemWorkspace": "\(workspace.isSystemWorkspace)",
                    "deferralArmed": "\(initialSystemWorkspaceSessionListRefreshDeferralReason != nil)"
                ]
            )
        #endif

        cancelSessionIndexRefresh(releaseFrozenOrder: false, owner: owner)
        sessionListCacheGeneration &+= 1
        let token = SessionIndexRefreshToken(owner: owner, generation: sessionListCacheGeneration)
        activeSessionIndexRefreshToken = token
        activeSessionIndexRefreshWorkspace = workspace
        activeSessionIndexRefreshValidTabIDs = validTabIDs
        activeSessionIndexRefreshBoundSessionIDByTabID = boundSessionIDByTabID
        activeSessionIndexRefreshBaselineEntries = sessionIndex
        activeSessionIndexRefreshPrioritizedEntries.removeAll()
        activeSessionIndexRefreshFullEntries.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        setSessionListCacheReady(false, for: owner)

        if Self.shouldSkipSessionListCacheRefresh(
            for: workspace,
            isInitialSystemWorkspaceRefreshDeferred: initialSystemWorkspaceSessionListRefreshDeferralReason != nil
        ) {
            completeSkippedSessionListCacheRefresh(
                for: workspace,
                token: token,
                reason: initialSystemWorkspaceSessionListRefreshDeferralReason ?? "initialSystemWorkspaceDeferred"
            )
            return
        }

        let prioritizedBuilder = sidebarPrioritizedIndexBuilder
        let streamBuilder = sidebarIndexStreamBuilder
        let restoreBatchSize = Self.sessionSidebarRestoreBatchSize
        sessionListCacheTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            #if DEBUG
                let taskStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                var prioritizedDurationMS: Double?
                var streamDurationMS: Double?
                var streamBatchCount = 0
                var streamEntryCount = 0
            #endif
            do {
                if let prioritizedTabID, let prioritizedTabName = tabNameByID[prioritizedTabID] {
                    let prioritizedBoundSessionIDByTabID = boundSessionIDByTabID[prioritizedTabID]
                        .map { [prioritizedTabID: $0] } ?? [:]
                    #if DEBUG
                        let prioritizedStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                    #endif
                    let prioritizedResult = try await prioritizedBuilder(
                        AgentSessionSidebarBuildRequest(
                            workspace: workspace,
                            tabNameByID: [prioritizedTabID: prioritizedTabName],
                            validTabIDs: [prioritizedTabID],
                            boundSessionIDByTabID: prioritizedBoundSessionIDByTabID
                        )
                    )
                    #if DEBUG
                        if let prioritizedStartMS {
                            prioritizedDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: prioritizedStartMS)
                        }
                    #endif
                    guard !Task.isCancelled else { return }
                    await applySidebarIndexBatch(
                        AgentSessionSidebarBuildBatch(
                            entriesBySessionID: prioritizedResult.entriesBySessionID,
                            preferredSessionIDByTabID: prioritizedResult.preferredSessionIDByTabID
                        ),
                        token: token,
                        isFullRefresh: false
                    )
                }
                await Task.yield()
                guard await notePrioritizedActiveSessionRestoreStatus(
                    token: token,
                    prioritizedTabID: prioritizedTabID
                ) else {
                    return
                }

                var streamRetryCount = 0
                while true {
                    do {
                        #if DEBUG
                            let streamStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                        #endif
                        let stream = await streamBuilder(fullRequest, restoreBatchSize)
                        for try await batch in stream {
                            #if DEBUG
                                streamBatchCount += 1
                                streamEntryCount += batch.entriesBySessionID.count
                            #endif
                            guard !Task.isCancelled else { return }
                            await applySidebarIndexBatch(
                                batch,
                                token: token,
                                isFullRefresh: true
                            )
                        }
                        guard !Task.isCancelled else { return }
                        #if DEBUG
                            if let streamStartMS {
                                streamDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: streamStartMS)
                            }
                        #endif
                        break
                    } catch {
                        guard !Task.isCancelled else { return }
                        guard streamRetryCount < Self.sessionSidebarRestoreRetryLimit,
                              await prepareSidebarIndexStreamRetry(token: token)
                        else {
                            throw error
                        }
                        streamRetryCount += 1
                        #if DEBUG
                            WorkspaceRestorePerfLog.log(
                                "agentSessionIndex.refreshRetry windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspace.id)) activationEpoch=\(owner.activationEpoch) generation=\(token.generation) retry=\(streamRetryCount) error=\(String(describing: error))"
                            )
                        #endif
                        await Task.yield()
                    }
                }
                #if DEBUG
                    if let taskStartMS {
                        WorkspaceRestorePerfLog.log(
                            "agentSessionIndex.refreshComplete windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspace.id)) activationEpoch=\(owner.activationEpoch) generation=\(token.generation) batches=\(streamBatchCount) streamEntries=\(streamEntryCount) retries=\(streamRetryCount) prioritized=\(prioritizedDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun") stream=\(streamDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured") total=\(WorkspaceRestorePerfLog.formatElapsedMS(since: taskStartMS))"
                        )
                    }
                #endif
                await applySidebarIndexCompletion(token: token)
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                    if let taskStartMS {
                        WorkspaceRestorePerfLog.log(
                            "agentSessionIndex.refreshFailure windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspace.id)) activationEpoch=\(owner.activationEpoch) generation=\(token.generation) batches=\(streamBatchCount) streamEntries=\(streamEntryCount) total=\(WorkspaceRestorePerfLog.formatElapsedMS(since: taskStartMS)) error=\(String(describing: error))"
                        )
                    }
                #endif
                await applySidebarIndexFailure(token: token)
            }
        }
    }

    private func completeSkippedSessionListCacheRefresh(
        for workspace: WorkspaceModel,
        token: SessionIndexRefreshToken,
        reason: String
    ) {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner),
              workspace.id == token.owner.workspaceID
        else {
            return
        }
        activeSessionIndexRefreshBaselineEntries.removeAll()
        activeSessionIndexRefreshPrioritizedEntries.removeAll()
        activeSessionIndexRefreshFullEntries.removeAll()
        publishSessionIndexReplacement([:], token: token)
        sessionListCacheTask = nil
        activeSessionIndexRefreshToken = nil
        activeSessionIndexRefreshWorkspace = nil
        activeSessionIndexRefreshValidTabIDs.removeAll()
        activeSessionIndexRefreshBoundSessionIDByTabID.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        setSessionListCacheReady(true, for: token.owner)
        releaseSidebarRestoreFrozenOrder(for: token.owner)
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "agentSessionIndex.refreshSkipped windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(workspace.id)) activationEpoch=\(token.owner.activationEpoch) generation=\(token.generation) reason=\(reason) managerInitialized=\(workspaceManager?.isInitialized == true) managerSwitching=\(workspaceManager?.isSwitchingWorkspace == true)"
            )
        #endif
    }

    private func shouldAcceptSidebarIndexEntry(_ entry: AgentSessionIndexEntry) -> Bool {
        switch persistentBindingResolution(for: entry.id) {
        case let .unique(tabID):
            return tabID == entry.tabID
        case .ambiguous:
            return false
        case .notFound:
            if let liveBinding = sessions[entry.tabID]?.activeAgentSessionID {
                return liveBinding == entry.id
            }
            if let workspaceBinding = workspaceManager?.activeAgentSessionID(forTabID: entry.tabID) {
                return workspaceBinding == entry.id
            }
            return true
        }
    }

    private func shouldAcceptSidebarIndexEntry(
        _ entry: AgentSessionIndexEntry,
        token: SessionIndexRefreshToken
    ) -> Bool {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner),
              activeSessionIndexRefreshValidTabIDs.contains(entry.tabID)
        else {
            return false
        }
        if let explicitSessionID = activeSessionIndexRefreshBoundSessionIDByTabID[entry.tabID] {
            return explicitSessionID == entry.id
        }
        if activeSessionIndexRefreshBoundSessionIDByTabID.contains(where: { tabID, sessionID in
            sessionID == entry.id && tabID != entry.tabID
        }) {
            return false
        }
        if let liveBinding = sessions[entry.tabID]?.activeAgentSessionID {
            return liveBinding == entry.id
        }
        return true
    }

    private func applySidebarIndexBatch(
        _ batch: AgentSessionSidebarBuildBatch,
        token: SessionIndexRefreshToken,
        isFullRefresh: Bool
    ) {
        #if DEBUG
            let applyStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            return
        }
        var acceptedEntries: [UUID: AgentSessionIndexEntry] = [:]
        var updatedTabIDs: Set<UUID> = []
        for (sessionID, entry) in batch.entriesBySessionID
            where shouldAcceptSidebarIndexEntry(entry, token: token)
        {
            acceptedEntries[sessionID] = entry
            updatedTabIDs.insert(entry.tabID)
        }
        for tabID in batch.preferredSessionIDByTabID.keys
            where activeSessionIndexRefreshValidTabIDs.contains(tabID)
        {
            updatedTabIDs.insert(tabID)
        }

        if isFullRefresh {
            activeSessionIndexRefreshFullEntries.merge(acceptedEntries) { _, new in new }
            activeSessionIndexRefreshHasPublishedFullBatch = true
            var provisional = activeSessionIndexRefreshBaselineEntries
            provisional.merge(activeSessionIndexRefreshPrioritizedEntries) { _, new in new }
            provisional.merge(activeSessionIndexRefreshFullEntries) { _, new in new }
            publishSessionIndexReplacement(provisional, token: token)
        } else if !activeSessionIndexRefreshHasPublishedFullBatch {
            activeSessionIndexRefreshPrioritizedEntries.merge(acceptedEntries) { _, new in new }
            var provisional = activeSessionIndexRefreshBaselineEntries
            provisional.merge(activeSessionIndexRefreshPrioritizedEntries) { _, new in new }
            publishSessionIndexReplacement(provisional, token: token)
        }
        let resumeTriggered = resumePendingActiveSessionLoadIfNeeded(updatedTabIDs: updatedTabIDs)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.applyBatch",
                fields: [
                    "windowID": "\(windowID)",
                    "activationEpoch": "\(token.owner.activationEpoch)",
                    "generation": "\(token.generation)",
                    "isFullRefresh": "\(isFullRefresh)",
                    "entries": "\(batch.entriesBySessionID.count)",
                    "acceptedEntries": "\(acceptedEntries.count)",
                    "updatedTabs": "\(updatedTabIDs.count)",
                    "sessionIndexAfter": "\(sessionIndex.count)",
                    "resumeTriggered": "\(resumeTriggered)",
                    "total": applyStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    @discardableResult
    private func resumePendingActiveSessionLoadIfNeeded(updatedTabIDs: Set<UUID>) -> Bool {
        guard let targetTabID = activeSessionLoadInProgressTabID,
              updatedTabIDs.contains(targetTabID)
        else {
            return false
        }
        guard explicitActiveSessionID(for: targetTabID) != nil else {
            return false
        }
        guard workspaceManager?.isSwitchingWorkspace != true else {
            return false
        }
        lastProcessedTabID = nil
        onTabChanged(targetTabID)
        return true
    }

    private func prepareSidebarIndexStreamRetry(token: SessionIndexRefreshToken) -> Bool {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            return false
        }

        activeSessionIndexRefreshFullEntries.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        var provisional = activeSessionIndexRefreshBaselineEntries
        provisional.merge(activeSessionIndexRefreshPrioritizedEntries) { _, new in new }
        publishSessionIndexReplacement(provisional, token: token)
        return true
    }

    private func applySidebarIndexCompletion(token: SessionIndexRefreshToken) {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            return
        }
        publishSessionIndexReplacement(activeSessionIndexRefreshFullEntries, token: token)
        sessionListCacheTask = nil
        activeSessionIndexRefreshToken = nil
        activeSessionIndexRefreshWorkspace = nil
        activeSessionIndexRefreshValidTabIDs.removeAll()
        activeSessionIndexRefreshBoundSessionIDByTabID.removeAll()
        activeSessionIndexRefreshBaselineEntries.removeAll()
        activeSessionIndexRefreshPrioritizedEntries.removeAll()
        activeSessionIndexRefreshFullEntries.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        setSessionListCacheReady(true, for: token.owner)
        releaseSidebarRestoreFrozenOrder(for: token.owner)
        scheduleSidebarAutoArchive(reason: .sessionListReady)
    }

    private func applySidebarIndexFailure(token: SessionIndexRefreshToken) {
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            return
        }
        publishSessionIndexReplacement(activeSessionIndexRefreshBaselineEntries, token: token)
        sessionListCacheTask = nil
        activeSessionIndexRefreshToken = nil
        activeSessionIndexRefreshWorkspace = nil
        activeSessionIndexRefreshValidTabIDs.removeAll()
        activeSessionIndexRefreshBoundSessionIDByTabID.removeAll()
        activeSessionIndexRefreshBaselineEntries.removeAll()
        activeSessionIndexRefreshPrioritizedEntries.removeAll()
        activeSessionIndexRefreshFullEntries.removeAll()
        activeSessionIndexRefreshHasPublishedFullBatch = false
        setSessionListCacheReady(false, for: token.owner)
        releaseSidebarRestoreFrozenOrder(for: token.owner)
    }

    private func notePrioritizedActiveSessionRestoreStatus(
        token: SessionIndexRefreshToken,
        prioritizedTabID: UUID?
    ) -> Bool {
        #if DEBUG
            let waitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            func logActiveRestoreWait(outcome: String, waited: Bool) {
                WorkspaceRestorePerfLog.event(
                    "agentSessionIndex.activeRestoreWait",
                    fields: [
                        "windowID": "\(windowID)",
                        "generation": "\(token.generation)",
                        "prioritizedTabID": WorkspaceRestorePerfLog.shortID(prioritizedTabID),
                        "outcome": outcome,
                        "waited": "\(waited)",
                        "duration": waitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        guard let prioritizedTabID else {
            let shouldContinue = activeSessionIndexRefreshToken == token
                && isSessionIndexOwnerCurrent(token.owner)
            #if DEBUG
                logActiveRestoreWait(outcome: "noPrioritizedTab", waited: false)
            #endif
            return shouldContinue
        }
        guard activeSessionIndexRefreshToken == token,
              isSessionIndexOwnerCurrent(token.owner)
        else {
            #if DEBUG
                logActiveRestoreWait(outcome: "generationChangedBeforeStatus", waited: false)
            #endif
            return false
        }
        guard activeSessionLoadInProgressTabID == prioritizedTabID else {
            #if DEBUG
                logActiveRestoreWait(outcome: "notActiveLoadingTarget", waited: false)
            #endif
            return true
        }
        guard sessions[prioritizedTabID]?.persistedLoadTask != nil else {
            let shouldContinue = activeSessionIndexRefreshToken == token
                && isSessionIndexOwnerCurrent(token.owner)
            #if DEBUG
                logActiveRestoreWait(outcome: "notWaitingNoPersistedLoadTask", waited: false)
            #endif
            return shouldContinue
        }
        #if DEBUG
            logActiveRestoreWait(outcome: "notWaitingLoadInProgress", waited: false)
        #endif
        return true
    }

    func handleComposeTabsWillClose(
        _ tabIDs: Set<UUID>,
        reason: PromptViewModel.ComposeTabRemovalReason
    ) async {
        // Drop any sidebar attention / observed run-state for tabs that are
        // going away so we don't leave dangling entries referring to dead IDs.
        cleanupSidebarRunAttention(tabIDs: tabIDs)
        for tabID in tabIDs {
            let boundID = boundSessionID(for: tabID)
            if let session = sessions[tabID] {
                removePendingUIRefresh(for: tabID)
                cancelPersistedLoad(for: session)
                session.pendingCommandRunningFlushTask?.cancel()
                session.pendingCommandRunningFlushTask = nil
                session.pendingCommandRunningByKey.removeAll()
                // Cancel pending question
                cancelPendingQuestion(for: session)
                cancelPendingApproval(for: session)
                cancelPendingApplyEditsReview(for: session, reason: "Cancelled because tab is closing")
                await teardownApplyEditsApprovalSessionSync(for: session, cleanupScope: true)
                cancelPendingInstruction(for: session)
                await teardownMCPControl(for: session, cleanupSessionStore: true)

                // Cancel agent run
                if session.runState.isActive {
                    await cancelAgentRun(tabID: tabID)
                }

                await codexCoordinator.shutdownCodexSession(session)
                await claudeCoordinator.shutdownClaudeSession(session)

                // Flush save before deleting backing file
                await flushSave(for: tabID)
            }
            await cleanupMCPRunRoutingIfPresent(
                boundSessionID: boundID,
                liveSession: sessions[tabID],
                reason: "compose_tab_close"
            )
            await releaseSessionWorktreeOwnership(sessionID: boundID)

            switch reason {
            case .stash:
                sessions.removeValue(forKey: tabID)
                tabsWithActiveAgentRun.remove(tabID)
            case .close:
                if let workspace = workspaceManager?.activeWorkspace {
                    try? await dataService.deleteAgentSessions(forComposeTabID: tabID, for: workspace)
                }
                removeSessionIndex(forTabID: tabID)
                tabDraftText.removeValue(forKey: tabID)
                sessionListSortDates.removeValue(forKey: tabID)
                sessions.removeValue(forKey: tabID)
                tabsWithActiveAgentRun.remove(tabID)
            case .deleteStashed:
                if let workspace = workspaceManager?.activeWorkspace {
                    try? await dataService.deleteAgentSessions(forComposeTabID: tabID, for: workspace)
                }
                removeSessionIndex(forTabID: tabID)
                tabDraftText.removeValue(forKey: tabID)
                sessionListSortDates.removeValue(forKey: tabID)
                sessions.removeValue(forKey: tabID)
                tabsWithActiveAgentRun.remove(tabID)
            }
            #if DEBUG
                AgentModePerfDiagnostics.markSidebarDeleteAgentCleanupComplete(
                    tabID: tabID,
                    source: "AgentModeViewModel.handleComposeTabsWillClose",
                    fields: ["reason": String(describing: reason)]
                )
            #endif
        }
    }

    // MARK: - Persistence

    private func makeSaveCommitToken(
        for session: TabSession,
        workspaceID: UUID
    ) -> SessionSaveCommitToken? {
        guard let binding = session.persistentSessionBindingIdentity,
              binding.sessionID == session.activeAgentSessionID,
              !session.bindingTransitionInProgress
        else {
            return nil
        }
        return SessionSaveCommitToken(
            tabID: session.tabID,
            sessionIdentity: ObjectIdentifier(session),
            workspaceID: workspaceID,
            binding: binding,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            sourceItemsRevision: session.sourceItemsRevision,
            persistenceMutationGeneration: session.persistenceMutationGeneration,
            saveRequestGeneration: session.saveRequestGeneration
        )
    }

    private func isSaveCommitTokenCurrent(
        _ token: SessionSaveCommitToken,
        requireWorkspaceMatch: Bool = true
    ) -> Bool {
        if requireWorkspaceMatch,
           workspaceManager?.activeWorkspace?.id != token.workspaceID
        {
            return false
        }
        guard let session = sessions[token.tabID],
              ObjectIdentifier(session) == token.sessionIdentity,
              session.persistentSessionBindingIdentity == token.binding,
              session.bindingTransitionGeneration == token.bindingTransitionGeneration,
              !session.bindingTransitionInProgress,
              session.sourceItemsRevision == token.sourceItemsRevision,
              session.persistenceMutationGeneration == token.persistenceMutationGeneration,
              session.saveRequestGeneration == token.saveRequestGeneration
        else {
            return false
        }
        return true
    }

    private func requestFreshSaveForCurrentOwner(
        sessionID: UUID,
        fallbackSession: TabSession
    ) {
        let currentOwner = try? authoritativeLiveSession(for: sessionID)
        if let currentOwner {
            currentOwner.isDirty = true
            saveRequestedWhileInFlightSessionIDs.insert(sessionID)
        } else if fallbackSession.activeAgentSessionID == sessionID {
            fallbackSession.isDirty = true
            saveRequestedWhileInFlightSessionIDs.insert(sessionID)
        }
    }

    func scheduleSave(for tabID: UUID) {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return }
        guard let session = sessions[tabID] else { return }
        session.saveRequestGeneration &+= 1
        #if DEBUG
            let replacedPendingSave = session.saveDebounceTask != nil
            AgentModePerfDiagnostics.increment("save.schedule", tabID: tabID)
            if replacedPendingSave {
                AgentModePerfDiagnostics.increment("save.schedule.replaced", tabID: tabID)
            }
            AgentModePerfDiagnostics.event("save.schedule", tabID: tabID, fields: ["replaced": String(replacedPendingSave), "dirty": String(session.isDirty)])
        #endif
        session.saveDebounceTask?.cancel()
        session.saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second debounce
            guard !Task.isCancelled else { return }
            await self?.saveSession(for: tabID)
        }
    }

    func scheduleSaveForCommandOutput(tabID: UUID, minInterval: TimeInterval = 5.0) {
        guard let session = sessions[tabID] else { return }
        let now = Date()
        if let lastSaveAt = session.lastCommandOutputSaveAt,
           now.timeIntervalSince(lastSaveAt) < minInterval
        {
            #if DEBUG
                AgentModePerfDiagnostics.increment("save.commandOutput.skipped", tabID: tabID)
                AgentModePerfDiagnostics.event(
                    "save.commandOutput.skipped",
                    tabID: tabID,
                    fields: [
                        "elapsed": String(format: "%.2fs", now.timeIntervalSince(lastSaveAt)),
                        "minInterval": String(format: "%.2fs", minInterval)
                    ]
                )
            #endif
            return
        }
        session.lastCommandOutputSaveAt = now
        #if DEBUG
            AgentModePerfDiagnostics.increment("save.commandOutput.scheduled", tabID: tabID)
            AgentModePerfDiagnostics.event("save.commandOutput.scheduled", tabID: tabID, fields: ["minInterval": String(format: "%.2fs", minInterval)])
        #endif
        scheduleSave(for: tabID)
    }

    private func saveSession(for tabID: UUID) async {
        #if DEBUG
            let diagnosticsStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            AgentModePerfDiagnostics.increment("save.session.invoked", tabID: tabID)
        #endif
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            #if DEBUG
                AgentModePerfDiagnostics.event("save.session.skipped", tabID: tabID, fields: ["reason": "suppressed"])
            #endif
            return
        }
        guard let session = sessions[tabID],
              let workspace = workspaceManager?.activeWorkspace,
              session.isDirty || session.activeAgentSessionID == nil
        else {
            #if DEBUG
                AgentModePerfDiagnostics.event("save.session.skipped", tabID: tabID, fields: ["reason": "missingOrClean"])
            #endif
            return
        }

        let hasConversationContent = !session.items.isEmpty || !session.transcript.turns.isEmpty || session.runState.isActive || session.hasPendingQuestionUI || session.pendingApproval != nil || session.pendingPermissionsRequest != nil || session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil || session.worktreeMergeOperations.contains { $0.status.isActive }
        if session.activeAgentSessionID == nil, !hasConversationContent {
            return
        }
        guard let sessionID = ensureSessionBoundToTab(session) else {
            return
        }
        session.saveRequestGeneration &+= 1
        if saveInFlightSessionIDs.contains(sessionID) {
            saveRequestedWhileInFlightSessionIDs.insert(sessionID)
            return
        }
        saveInFlightSessionIDs.insert(sessionID)
        defer {
            saveInFlightSessionIDs.remove(sessionID)
            if saveRequestedWhileInFlightSessionIDs.remove(sessionID) != nil {
                if let currentOwner = try? authoritativeLiveSession(for: sessionID) {
                    scheduleSave(for: currentOwner.tabID)
                } else if sessions[tabID] === session,
                          session.activeAgentSessionID == sessionID
                {
                    scheduleSave(for: tabID)
                }
            }
        }
        var workingItemsSnapshot = session.items
        var shouldRefreshAfterPreparation = false
        let existingTranscript = session.transcript
        let previousBaseProjection = session.baseTranscriptProjection
        let previousProjection = session.transcriptProjection
        let previousProjectionProtection = session.transcriptProjectionProtection
        let isActiveOwnedForSave = canBuildOrPublishActiveTranscriptBindings(for: session)
        if !session.runState.isActive {
            let repairedCount = AgentTranscriptIO.finalizePendingToolCalls(
                in: &workingItemsSnapshot,
                terminalState: session.runState,
                includeExplicitRepoPromptToolCalls: session.selectedAgent == .codexExec || session.selectedAgent.acpProviderID != nil,
                nonToolBoundary: Self.pendingToolFinalizationNonToolBoundary
            )
            if repairedCount > 0 {
                session.setItemsSilently(workingItemsSnapshot, reason: .pendingToolFinalizationRepair)
                session.isDirty = true
                refreshDerivedTranscriptState(for: session, reason: .saveSession)
                #if DEBUG
                    AgentModePerfDiagnostics.increment("save.session.localPendingToolRepair", tabID: tabID)
                    AgentModePerfDiagnostics.event(
                        "save.session.localPendingToolRepair",
                        tabID: tabID,
                        fields: [
                            "activeOwned": String(isActiveOwnedForSave),
                            "repairedCount": String(repairedCount)
                        ]
                    )
                #endif
            }
        }
        var projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: session.transcript
        )
        let importPolicy = AgentTranscriptImportPolicy.liveSession(
            hidePendingQuestionToolCall: session.hasPendingQuestionUI
        )
        if !isActiveOwnedForSave,
           session.derivedTranscriptRefreshTask != nil || session.pendingDerivedTranscriptRefreshReason != nil
        {
            let scheduledReason = session.pendingDerivedTranscriptRefreshReason ?? .liveMutation
            refreshDerivedTranscriptState(for: session, reason: scheduledReason)
            projectionProtection = transcriptProjectionProtection(
                for: session,
                transcript: session.transcript
            )
        }
        let canReusePresentation = !shouldRefreshAfterPreparation
            && canReuseDerivedTranscriptForSave(
                for: session,
                projectionProtection: projectionProtection
            )
        let builtPresentation: BuiltTranscriptPresentation?
        let persistableSnapshot: PersistableTranscriptSnapshot
        if canReusePresentation {
            let reusedPresentation = builtTranscriptPresentationSnapshot(for: session)
            builtPresentation = reusedPresentation
            persistableSnapshot = PersistableTranscriptSnapshot(
                transcript: reusedPresentation.transcript,
                projectionCounts: reusedPresentation.projectionCounts,
                canonicalVisibleRowCount: reusedPresentation.canonicalVisibleRowCount,
                lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: reusedPresentation.transcript)
                    ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItemsSnapshot)
            )
        } else if isActiveOwnedForSave {
            let transcriptSnapshot = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: existingTranscript,
                workingItems: workingItemsSnapshot,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            )
            let appliedPresentation = applyTranscriptPresentation(
                transcriptSnapshot,
                sourceItems: workingItemsSnapshot,
                to: session
            )
            builtPresentation = appliedPresentation
            persistableSnapshot = PersistableTranscriptSnapshot(
                transcript: appliedPresentation.transcript,
                projectionCounts: appliedPresentation.projectionCounts,
                canonicalVisibleRowCount: appliedPresentation.canonicalVisibleRowCount,
                lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: appliedPresentation.transcript)
                    ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItemsSnapshot)
            )
        } else {
            builtPresentation = nil
            persistableSnapshot = persistableTranscriptSnapshot(
                for: session,
                workingItems: workingItemsSnapshot,
                existingTranscript: existingTranscript,
                importPolicy: importPolicy,
                projectionProtection: projectionProtection
            )
            #if DEBUG
                AgentModePerfDiagnostics.increment("save.session.persistenceOnlySnapshot", tabID: tabID)
                AgentModePerfDiagnostics.event(
                    "save.session.persistenceOnlySnapshot",
                    tabID: tabID,
                    fields: [
                        "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                        "sourceItemsRevision": String(session.sourceItemsRevision)
                    ]
                )
            #endif
        }
        let presentationChanged = isActiveOwnedForSave && !canReusePresentation && builtPresentation != nil && (
            session.transcript != existingTranscript
                || session.baseTranscriptProjection != previousBaseProjection
                || session.transcriptProjection != previousProjection
                || session.transcriptProjectionProtection != previousProjectionProtection
        )
        if isActiveOwnedForSave, let builtPresentation {
            let shouldReconcileWorkingItems = session.items == workingItemsSnapshot
                && (
                    AgentTranscriptIO.containsExcludedLegacyItems(workingItemsSnapshot, policy: importPolicy)
                        || AgentTranscriptIO.fullDetailTurnEnvelopeChanged(
                            from: existingTranscript,
                            to: builtPresentation.transcript
                        )
                        || (!canReusePresentation && builtPresentation.sanitizedActivityCount > 0)
                )
            if shouldReconcileWorkingItems {
                let trimmedWorkingItems = AgentTranscriptIO.workingSourceItems(from: builtPresentation.transcript)
                if trimmedWorkingItems != session.items {
                    session.setItemsSilently(trimmedWorkingItems, reason: .retentionCompaction)
                    markDerivedTranscriptSynchronized(
                        for: session,
                        projectionProtection: builtPresentation.projectionProtection
                    )
                    workingItemsSnapshot = trimmedWorkingItems
                    shouldRefreshAfterPreparation = true
                }
            } else if session.items != workingItemsSnapshot {
                workingItemsSnapshot = session.items
            }
        } else if session.items != workingItemsSnapshot {
            workingItemsSnapshot = session.items
        }
        if presentationChanged {
            shouldRefreshAfterPreparation = true
        }
        if shouldRefreshAfterPreparation {
            // Only refresh sessions that can publish active bindings now. Inactive
            // persistence-only saves must not feed back into UI projection work.
            if isActiveOwnedForSave {
                #if DEBUG
                    AgentModePerfDiagnostics.increment("save.session.innerRefresh", tabID: tabID)
                    AgentModePerfDiagnostics.event("save.session.innerRefresh", tabID: tabID)
                #endif
                requestUIRefresh(tabID: tabID)
            } else {
                #if DEBUG
                    AgentModePerfDiagnostics.increment("save.session.innerRefreshSkippedInactive", tabID: tabID)
                    AgentModePerfDiagnostics.event(
                        "save.session.innerRefreshSkipped",
                        tabID: tabID,
                        fields: [
                            "reason": "inactiveTab",
                            "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID)
                        ]
                    )
                #endif
            }
        }

        // Build the persisted session only for the binding generation captured below.
        let lastUserMessageAt = persistableSnapshot.lastUserMessageAt
        let canonicalItemCount = persistableSnapshot.canonicalVisibleRowCount
        let sessionName = resolvedSessionDisplayName(for: tabID)
        var agentSession = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: sessionName,
            items: [],
            transcript: persistableSnapshot.transcript,
            itemCount: canonicalItemCount,
            transcriptProjectionCounts: persistableSnapshot.projectionCounts,
            lastUserMessageAt: lastUserMessageAt,
            agentKind: session.selectedAgent.rawValue,
            agentModel: session.selectedModelRaw,
            agentReasoningEffort: session.selectedReasoningEffortRaw,
            lastRunState: session.runState.rawValue,
            providerSessionID: session.providerSessionID,
            autoEditEnabled: session.autoEditEnabled,
            providerTokenUsageByTurn: session.providerTokenUsageByTurn,
            parentSessionID: session.parentSessionID,
            pendingHandoffPayload: session.pendingHandoff.payload,
            pendingHandoffCreatedAt: session.pendingHandoff.createdAt,
            pendingHandoffSourceItemID: session.pendingHandoff.sourceItemID,
            pendingHandoffDefersProviderLockUntilSend: session.pendingHandoff.defersProviderLockUntilSend,
            isMCPOriginated: session.isMCPOriginated,
            worktreeBindings: session.worktreeBindings,
            worktreeMergeOperations: session.worktreeMergeOperations
        )
        codexCoordinator.applyCodexPersistence(from: session, to: &agentSession)
        guard let saveToken = makeSaveCommitToken(for: session, workspaceID: workspace.id),
              isSaveCommitTokenCurrent(saveToken)
        else {
            requestFreshSaveForCurrentOwner(sessionID: sessionID, fallbackSession: session)
            return
        }

        do {
            let fileURL = try await dataService.saveAgentSession(
                agentSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: canonicalItemCount
            )
            agentSession.fileURL = fileURL
            guard isSaveCommitTokenCurrent(saveToken) else {
                requestFreshSaveForCurrentOwner(sessionID: sessionID, fallbackSession: session)
                return
            }
            session.isDirty = false
            session.lastUserMessageAt = lastUserMessageAt
            if let lastUserMessageAt {
                sessionListSortDates[tabID] = lastUserMessageAt
            } else {
                sessionListSortDates.removeValue(forKey: tabID)
            }
            upsertSessionIndex(
                sessionID: sessionID,
                tabID: tabID,
                name: sessionName,
                lastUserMessageAt: lastUserMessageAt,
                savedAt: agentSession.savedAt,
                lastRunStateRaw: agentSession.lastRunState,
                itemCount: canonicalItemCount,
                agentKindRaw: agentSession.agentKind,
                agentModelRaw: agentSession.agentModel,
                agentReasoningEffortRaw: agentSession.agentReasoningEffort,
                autoEditEnabled: agentSession.autoEditEnabled,
                parentSessionID: agentSession.parentSessionID,
                isMCPOriginated: agentSession.isMCPOriginated,
                worktreeBindingSummaries: agentSession.worktreeBindings.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: agentSession.worktreeMergeOperations.activeWorktreeMergeSummaries
            )
            #if DEBUG
                if let diagnosticsStartMS {
                    AgentModePerfDiagnostics.event(
                        "save.session.complete",
                        tabID: tabID,
                        fields: [
                            "duration": AgentModePerfDiagnostics.formatElapsedMS(since: diagnosticsStartMS),
                            "itemCount": String(canonicalItemCount)
                        ]
                    )
                }
            #endif
        } catch {
            #if DEBUG
                AgentModePerfDiagnostics.event("save.session.error", tabID: tabID, fields: ["error": String(describing: error)])
            #endif
            print("[AgentModeVM] Failed to save session: \(error)")
        }
    }

    func flushSave(for tabID: UUID) async {
        guard let session = sessions[tabID] else { return }
        session.saveDebounceTask?.cancel()
        await saveSession(for: tabID)
    }

    private func persistCurrentSession() {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return }
        guard let tabID = currentTabID else { return }
        Task {
            await flushSave(for: tabID)
        }
    }

    // MARK: - User Interaction

    func ensureMCPServerEnabledForThreadStart() async {
        await mcpServerEnabler()
    }

    func hasLiveRunRouteInCurrentMCPServer(_ runID: UUID) -> Bool {
        mcpServer?.hasLiveRunID(runID) == true
    }

    /// Submit a user message to the agent
    func submitUserMessage(_ text: String) {
        _ = submitUserTurn(text: text)
    }

    @discardableResult
    func submitUserTurn(text: String) -> UserTurnSubmissionResult {
        guard let tabID = currentTabID else {
            return .blocked(message: "")
        }
        return submitUserTurn(text: text, tabID: tabID)
    }

    @discardableResult
    func submitUserTurnCreatingSessionIfNeeded(text: String) async -> UserTurnSubmissionResult {
        guard let sourceTabID = currentTabID else {
            return .blocked(message: "")
        }
        guard let target = makeComposerSubmitTarget(tabID: sourceTabID, session: sessions[sourceTabID]) else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        return await submitUserTurnCreatingSessionIfNeeded(text: text, target: target)
    }

    @discardableResult
    func submitUserTurnCreatingSessionIfNeeded(
        text: String,
        target: AgentComposerSubmitTarget
    ) async -> UserTurnSubmissionResult {
        await submitUserTurnCreatingSessionIfNeeded(
            text: text,
            target: target,
            createAndActivateSessionTab: { [weak self] in
                await self?.createAndActivateSessionTab()
            }
        )
    }

    @discardableResult
    func submitUserTurnCreatingSessionIfNeeded(
        text: String,
        target: AgentComposerSubmitTarget,
        createAndActivateSessionTab: () async -> UUID?
    ) async -> UserTurnSubmissionResult {
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: text
        )
        switch claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) {
        case let .claimed(claim):
            return await executeComposerSubmitAttempt(
                text: text,
                claim: claim,
                createAndActivateSessionTab: createAndActivateSessionTab
            )
        case .rejected:
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
    }

    @discardableResult
    func executeComposerSubmitAttempt(
        text: String,
        claim: AgentComposerSubmitClaim
    ) async -> UserTurnSubmissionResult {
        await executeComposerSubmitAttempt(
            text: text,
            claim: claim,
            createAndActivateSessionTab: { [weak self] in
                await self?.createAndActivateSessionTab()
            }
        )
    }

    @discardableResult
    func executeComposerSubmitAttempt(
        text: String,
        claim: AgentComposerSubmitClaim,
        createAndActivateSessionTab: () async -> UUID?
    ) async -> UserTurnSubmissionResult {
        let target = claim.attempt.target
        let claimedSourceSession = claim.sourceSession
        guard composerSubmitClaimIsCurrent(claim) else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        defer {
            releaseComposerSubmitClaim(claim)
        }

        switch target.route {
        case .existingAgentSession:
            let preparedSession = await ensureSessionReady(tabID: target.tabID)
            guard preparedSession === claimedSourceSession,
                  composerSubmitClaimIsCurrent(claim)
            else {
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let rejectionReason = submitTargetRejectionReason(
                target,
                session: preparedSession,
                validateSubmissionToken: false
            ) {
                logRejectedSubmitTarget(target, session: preparedSession, reason: rejectionReason)
                resyncAfterRejectedSubmitTarget(target)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            let pendingState = Self.pendingUserTurnState(from: preparedSession)
            guard let initialLocation = target.expectedInitialStartLocation,
                  initialLocation != .local,
                  pendingState.initialStartLocation == initialLocation
            else {
                let result = submitUserTurn(text: text, tabID: target.tabID)
                if result == .submitted {
                    clearComposerDraftIfUnchanged(for: claim)
                }
                return result
            }
            let sourceSnapshot = FirstSendSourceSnapshot(
                session: preparedSession,
                fallbackSelectedAgent: selectedAgent,
                fallbackSelectedModelRaw: selectedModelRaw,
                fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                fallbackAutoEditEnabled: autoEditEnabled
            )
            preparedSession.isPreparingInitialWorktree = true
            syncComposerUIState(tabID: target.tabID)
            syncStatusPillsUIState()
            defer {
                preparedSession.isPreparingInitialWorktree = false
                if target.tabID == currentTabID {
                    syncComposerUIState(tabID: target.tabID)
                    syncStatusPillsUIState()
                }
            }
            if let blocked = preflightInitialUserTurn(text: text, session: preparedSession) {
                return blocked
            }
            do {
                try await prepareInitialExecutionLocation(initialLocation, for: preparedSession) {
                    !Task.isCancelled
                        && self.composerSubmitClaimIsCurrent(claim)
                        && self.sessions[target.tabID] === preparedSession
                        && self.composerSourceAgentSessionID(
                            tabID: target.tabID,
                            session: preparedSession
                        ) == target.expectedSourceAgentSessionID
                        && sourceSnapshot.matches(self.sessions[target.tabID])
                        && Self.pendingUserTurnState(from: preparedSession) == pendingState
                }
            } catch {
                return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            guard composerSourceAgentSessionID(tabID: target.tabID, session: preparedSession)
                == target.expectedSourceAgentSessionID
            else {
                logRejectedSubmitTarget(target, session: preparedSession, reason: "agent_session_id_mismatch")
                resyncAfterRejectedSubmitTarget(target)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard !Task.isCancelled,
                  composerSubmitClaimIsCurrent(claim),
                  sessions[target.tabID] === preparedSession,
                  sourceSnapshot.matches(sessions[target.tabID]),
                  Self.pendingUserTurnState(from: preparedSession) == pendingState
            else {
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let blocked = preflightInitialUserTurn(text: text, session: preparedSession) {
                return blocked
            }
            preparedSession.pendingInitialStartLocation = .local
            if target.tabID == currentTabID {
                applySessionToBindings(preparedSession)
            }
            let result = submitUserTurn(text: text, tabID: target.tabID)
            if result == .submitted {
                clearComposerDraftIfUnchanged(for: claim)
            }
            return result
        case .createAgentSessionFromSourceTab:
            let sourceSession = claimedSourceSession
            let sourceSnapshot = FirstSendSourceSnapshot(
                session: sourceSession,
                fallbackSelectedAgent: selectedAgent,
                fallbackSelectedModelRaw: selectedModelRaw,
                fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                fallbackAutoEditEnabled: autoEditEnabled
            )
            let pendingState = Self.pendingUserTurnState(from: sourceSession)
            let preparesExecutionLocation = pendingState.initialStartLocation != .local
            if preparesExecutionLocation {
                sourceSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: target.tabID)
                syncStatusPillsUIState()
            }
            defer {
                if preparesExecutionLocation {
                    sourceSession.isPreparingInitialWorktree = false
                    if target.tabID == currentTabID {
                        syncComposerUIState(tabID: target.tabID)
                        syncStatusPillsUIState()
                    }
                }
            }
            guard let destinationTabID = await createAndActivateSessionTab() else {
                return .blocked(message: "Failed to create a new agent session.")
            }
            guard !Task.isCancelled,
                  composerSubmitClaimIsCurrent(claim)
            else {
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard sessions[target.tabID] === sourceSession else {
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let rejectionReason = submitTargetRejectionReason(
                target,
                session: sourceSession,
                validateSubmissionToken: false
            ) {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: rejectionReason)
                resyncAfterRejectedSubmitTarget(target)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard composerSubmitClaimIsCurrent(claim),
                  sourceSnapshot.matches(sessions[target.tabID])
            else {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "source_pending_state_changed")
                resyncAfterRejectedSubmitTarget(target)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard destinationTabID != target.tabID else {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "invalid_first_send_destination")
                resyncAfterRejectedSubmitTarget(target)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: "Failed to create a new agent session.")
            }
            let destinationSession = session(for: destinationTabID)
            guard isFreshFirstSendDestination(destinationSession) else {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "invalid_first_send_destination")
                resyncAfterRejectedSubmitTarget(target)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: "Failed to create a new agent session.")
            }
            if preparesExecutionLocation {
                destinationSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: destinationTabID)
            }
            defer {
                if preparesExecutionLocation {
                    destinationSession.isPreparingInitialWorktree = false
                    if destinationTabID == currentTabID {
                        syncComposerUIState(tabID: destinationTabID)
                    }
                }
            }
            sourceSnapshot.applySessionSettings(to: destinationSession)
            if !pendingState.isEmpty {
                installPendingUserTurnState(pendingState, on: destinationSession)
            }
            if let blocked = preflightInitialUserTurn(text: text, session: destinationSession) {
                clearPendingUserTurnState(on: destinationSession)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return blocked
            }
            if preparesExecutionLocation {
                do {
                    try await prepareInitialExecutionLocation(pendingState.initialStartLocation, for: destinationSession) {
                        !Task.isCancelled
                            && self.composerSubmitClaimIsCurrent(claim)
                            && self.sessions[destinationTabID] === destinationSession
                            && self.sessions[target.tabID] === sourceSession
                            && sourceSnapshot.matches(self.sessions[target.tabID])
                            && Self.pendingUserTurnState(from: destinationSession) == pendingState
                    }
                } catch {
                    clearPendingUserTurnState(on: destinationSession)
                    await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                    return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            guard !Task.isCancelled,
                  composerSubmitClaimIsCurrent(claim),
                  sessions[destinationTabID] === destinationSession,
                  sessions[target.tabID] === sourceSession,
                  sourceSnapshot.matches(sessions[target.tabID]),
                  Self.pendingUserTurnState(from: destinationSession) == pendingState
            else {
                clearPendingUserTurnState(on: destinationSession)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let blocked = preflightInitialUserTurn(text: text, session: destinationSession) {
                clearPendingUserTurnState(on: destinationSession)
                return blocked
            }
            destinationSession.pendingInitialStartLocation = .local
            if destinationTabID == currentTabID {
                applySessionToBindings(destinationSession)
            }
            let result = submitUserTurn(text: text, tabID: destinationTabID)
            guard result == .submitted else {
                clearPendingUserTurnState(on: destinationSession)
                return result
            }
            clearPendingUserTurnState(on: sourceSession)
            clearComposerDraftIfUnchanged(for: claim)
            return result
        }
    }

    @discardableResult
    func submitUserTurnCreatingSessionIfNeeded(
        text: String,
        sourceTabID: UUID,
        createAndActivateSessionTab: () async -> UUID?
    ) async -> UserTurnSubmissionResult {
        guard let target = makeComposerSubmitTarget(tabID: sourceTabID, session: sessions[sourceTabID]) else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        return await submitUserTurnCreatingSessionIfNeeded(
            text: text,
            target: target,
            createAndActivateSessionTab: createAndActivateSessionTab
        )
    }

    @MainActor
    private struct FirstSendSourceSnapshot {
        let sourceSessionExisted: Bool
        let selectedAgent: AgentProviderKind
        let selectedModelRaw: String
        let selectedReasoningEffortRaw: String?
        let autoEditEnabled: Bool
        let selectedWorkflow: AgentWorkflowDefinition?
        let imageAttachments: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        let initialStartLocation: InitialStartLocation

        init(
            session: TabSession?,
            fallbackSelectedAgent: AgentProviderKind,
            fallbackSelectedModelRaw: String,
            fallbackSelectedReasoningEffortRaw: String?,
            fallbackAutoEditEnabled: Bool
        ) {
            sourceSessionExisted = session != nil
            selectedAgent = session?.selectedAgent ?? fallbackSelectedAgent
            selectedModelRaw = session?.selectedModelRaw ?? fallbackSelectedModelRaw
            selectedReasoningEffortRaw = session?.selectedReasoningEffortRaw ?? fallbackSelectedReasoningEffortRaw
            autoEditEnabled = session?.autoEditEnabled ?? fallbackAutoEditEnabled
            selectedWorkflow = session?.selectedWorkflow
            imageAttachments = session?.pendingImageAttachments ?? []
            taggedFileAttachments = session?.pendingTaggedFileAttachments ?? []
            initialStartLocation = session?.pendingInitialStartLocation ?? .local
        }

        func matches(_ session: TabSession?) -> Bool {
            guard let session else { return !sourceSessionExisted }
            guard sourceSessionExisted else { return false }
            return selectedAgent == session.selectedAgent
                && selectedModelRaw == session.selectedModelRaw
                && selectedReasoningEffortRaw == session.selectedReasoningEffortRaw
                && autoEditEnabled == session.autoEditEnabled
                && selectedWorkflow == session.selectedWorkflow
                && imageAttachments == session.pendingImageAttachments
                && taggedFileAttachments == session.pendingTaggedFileAttachments
                && initialStartLocation == session.pendingInitialStartLocation
        }

        func applySessionSettings(to session: TabSession) {
            session.selectedAgent = selectedAgent
            session.selectedModelRaw = selectedModelRaw
            session.selectedReasoningEffortRaw = selectedReasoningEffortRaw
            session.autoEditEnabled = autoEditEnabled
        }
    }

    private func isFreshFirstSendDestination(_ session: TabSession) -> Bool {
        !session.runState.isActive
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
            && session.pendingImageAttachments.isEmpty
            && session.pendingTaggedFileAttachments.isEmpty
            && session.selectedWorkflow == nil
    }

    private func preflightInitialUserTurn(text: String, session: TabSession) -> UserTurnSubmissionResult? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = session.pendingImageAttachments
        let taggedFiles = session.pendingTaggedFileAttachments
        guard !trimmedText.isEmpty || !attachments.isEmpty || !taggedFiles.isEmpty else {
            return .blocked(message: "")
        }
        guard AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: agentAvailabilityContext) else {
            return .blocked(message: unavailableAgentMessage(for: session.selectedAgent))
        }
        let workflow = session.selectedWorkflow
        if let nativeSlashCommand = resolvedNativeSlashCommand(in: trimmedText, session: session),
           let validationFailure = validateNativeSlashCommandUsage(
               nativeSlashCommand,
               session: session,
               attachments: attachments,
               taggedFiles: taggedFiles,
               activeWorkflow: workflow
           )
        {
            return validationFailure
        }
        if resolvedNativeSlashCommand(in: trimmedText, session: session) == nil,
           let validationFailure = validateSlashSkillUsage(in: trimmedText, activeWorkflow: workflow)
        {
            return validationFailure
        }
        return nil
    }

    private enum InitialNewWorktreePreparationError: LocalizedError {
        case unavailable(String)
        case failed(String)
        case retainedWorktree(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message), let .failed(message):
                message
            case let .retainedWorktree(path, underlying):
                "The new worktree was created at \(path), but could not be bound to this thread. It was not removed; use worktree management to inspect or remove it. Error: \(underlying)"
            }
        }
    }

    private func prepareInitialExecutionLocation(
        _ choice: InitialStartLocation,
        for session: TabSession,
        validating operationIsCurrent: () -> Bool
    ) async throws {
        guard let sessionID = session.activeAgentSessionID,
              let workspaceManager,
              let workspace = workspaceManager.activeWorkspace,
              !workspace.isSystemWorkspace,
              let primaryRoot = workspace.repoPaths.first,
              let promptManager
        else {
            throw InitialNewWorktreePreparationError.unavailable(
                "Execution location requires an active Git-backed project workspace. Select Work locally or open a Git workspace."
            )
        }
        guard !Task.isCancelled,
              isReadyForInitialNewWorktreeCommit(session),
              operationIsCurrent()
        else {
            throw InitialNewWorktreePreparationError.unavailable(Self.staleComposerSubmitTargetMessage)
        }
        let primaryPath = Self.standardizedWorkspacePath((primaryRoot as NSString).expandingTildeInPath) ?? primaryRoot
        let visibleRoots = await promptManager.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
        guard !Task.isCancelled, operationIsCurrent() else {
            throw InitialNewWorktreePreparationError.unavailable(Self.staleComposerSubmitTargetMessage)
        }
        guard let logicalRoot = visibleRoots.first(where: {
            (Self.standardizedWorkspacePath($0.standardizedFullPath) ?? $0.standardizedFullPath) == primaryPath
        }) else {
            throw InitialNewWorktreePreparationError.unavailable(
                "Execution location requires the primary workspace root to be loaded before starting this thread. Select Work locally or reload the workspace."
            )
        }
        guard let resolvedRepo = await VCSService.shared.resolveRepo(from: URL(fileURLWithPath: primaryPath)),
              resolvedRepo.backendKind == .git
        else {
            throw InitialNewWorktreePreparationError.unavailable(
                "Execution location requires a Git-backed primary workspace root. Select Work locally or open a Git workspace."
            )
        }
        guard !Task.isCancelled, operationIsCurrent() else {
            throw InitialNewWorktreePreparationError.unavailable(Self.staleComposerSubmitTargetMessage)
        }
        let repo = GitRepoDescriptor(rootURL: resolvedRepo.rootURL)
        var createdWorktree: GitWorktreeDescriptor?
        do {
            let existingWorktrees = try await VCSService.shared.listGitWorktrees(at: repo.rootURL)
            guard !Task.isCancelled,
                  isReadyForInitialNewWorktreeCommit(session),
                  operationIsCurrent()
            else {
                throw InitialNewWorktreePreparationError.unavailable(Self.staleComposerSubmitTargetMessage)
            }
            let worktree: GitWorktreeDescriptor
            let bindingSource: String
            switch choice {
            case .local:
                return
            case .newWorktree:
                let mainRootPath = existingWorktrees.first(where: \.isMain)?.path ?? repo.rootPath
                let plan = try GitWorktreeDefaultPathPlanner.plan(
                    .init(
                        mainWorktreeRoot: URL(fileURLWithPath: mainRootPath),
                        existingWorktreeRoots: existingWorktrees.map { URL(fileURLWithPath: $0.path) },
                        purpose: .agentStart(sessionID: sessionID.uuidString)
                    )
                )
                worktree = try await VCSService.shared.createGitWorktree(request: plan.createRequest, at: repo.rootURL)
                createdWorktree = worktree
                bindingSource = "agent_ui.initial_send"
            case let .existingWorktree(selection):
                guard let selected = existingWorktrees.first(where: {
                    $0.repository.repositoryID == selection.repositoryID && $0.worktreeID == selection.worktreeID
                }), !selected.isPrunable else {
                    throw InitialNewWorktreePreparationError.failed("The selected existing worktree is no longer available. Choose another execution location.")
                }
                worktree = selected
                bindingSource = "agent_ui.initial_send_existing"
            }
            func locationBindingFailure(_ message: String) -> InitialNewWorktreePreparationError {
                if let createdWorktree {
                    return .retainedWorktree(path: createdWorktree.path, underlying: message)
                }
                return .failed("Could not bind the selected existing worktree: \(message)")
            }
            guard !Task.isCancelled,
                  isReadyForInitialNewWorktreeCommit(session),
                  operationIsCurrent()
            else {
                throw locationBindingFailure(Self.staleComposerSubmitTargetMessage)
            }
            let label = worktree.name ?? worktree.branch ?? (worktree.isMain ? "main" : nil)
            let identity = try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                repositoryID: worktree.repository.repositoryID,
                worktreeID: worktree.worktreeID,
                label: label
            )
            let binding = AgentSessionWorktreeBinding(
                id: UUID().uuidString,
                repositoryID: worktree.repository.repositoryID,
                repoKey: worktree.repository.repoKey,
                logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name,
                worktreeID: worktree.worktreeID,
                worktreeRootPath: worktree.path,
                worktreeName: worktree.name,
                branch: worktree.branch,
                head: worktree.head,
                visualLabel: identity.label,
                visualColorHex: identity.colorHex,
                source: bindingSource
            )
            guard !Task.isCancelled,
                  operationIsCurrent(),
                  isReadyForInitialNewWorktreeCommit(session)
            else {
                throw locationBindingFailure(Self.staleComposerSubmitTargetMessage)
            }
            do {
                _ = try await transitionWorktreeBindings(
                    [binding],
                    forSessionID: sessionID,
                    intent: .initialSend
                )
            } catch {
                throw locationBindingFailure(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        } catch let error as InitialNewWorktreePreparationError {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let createdWorktree {
                throw InitialNewWorktreePreparationError.retainedWorktree(path: createdWorktree.path, underlying: message)
            }
            throw InitialNewWorktreePreparationError.failed("Could not prepare the selected execution location: \(message)")
        }
    }

    private func isReadyForInitialNewWorktreeCommit(_ session: TabSession) -> Bool {
        session.isPreparingInitialWorktree
            && !session.hasSentFirstMessage
            && session.runState == .idle
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.providerSessionID == nil
            && session.codexConversationID == nil
            && session.worktreeBindings.isEmpty
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
            && session.mcpControlContext == nil
            && !session.isMCPOriginated
            && session.parentSessionID == nil
            && !session.pendingHandoff.hasPayload
    }

    private func discardFreshFirstSendDestinationIfPossible(_ tabID: UUID) async {
        guard let session = sessions[tabID], isFreshFirstSendDestination(session) else { return }
        if promptManager?.currentComposeTabs.contains(where: { $0.id == tabID }) == true {
            await promptManager?.closeComposeTab(tabID)
        } else {
            sessions.removeValue(forKey: tabID)
            sessionListSortDates.removeValue(forKey: tabID)
            removePendingUIRefresh(for: tabID)
        }
    }

    @discardableResult
    func submitUserTurn(
        text: String,
        tabID: UUID,
        codexAttemptID: UUID? = nil
    ) -> UserTurnSubmissionResult {
        let session = session(for: tabID)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = session.pendingImageAttachments
        let taggedFilesToSend = session.pendingTaggedFileAttachments
        guard !trimmedText.isEmpty || !attachmentsToSend.isEmpty || !taggedFilesToSend.isEmpty else {
            return .blocked(message: "")
        }
        guard AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: agentAvailabilityContext) else {
            return .blocked(message: unavailableAgentMessage(for: session.selectedAgent))
        }

        scheduleSkillCatalogRefresh()

        let activeWorkflow = session.selectedWorkflow
        let nativePreparedTurn: NativeSlashPreparedUserTurn?
        if let nativeSlashCommand = resolvedNativeSlashCommand(in: trimmedText, session: session) {
            if let validationFailure = validateNativeSlashCommandUsage(
                nativeSlashCommand,
                session: session,
                attachments: attachmentsToSend,
                taggedFiles: taggedFilesToSend,
                activeWorkflow: activeWorkflow
            ) {
                return validationFailure
            }
            switch nativeSlashCommand.command.behavior {
            case .controlPlane:
                let goalAction: CodexAgentModeCoordinator.GoalSlashAction? = nativeSlashCommand.command == .goal
                    ? CodexAgentModeCoordinator.goalSlashAction(from: nativeSlashCommand.argumentsText)
                    : nil
                let progressRestoreState = beginNativeSlashControlProgressIfNeeded(
                    command: nativeSlashCommand.command,
                    action: goalAction,
                    session: session
                )
                appendOptimisticGoalObjectiveUserBubbleIfNeeded(
                    action: goalAction,
                    session: session,
                    workflow: activeWorkflow
                )
                Task { [weak self] in
                    guard let self else { return }
                    if let codexAttemptID {
                        guard await session.codexSteerAckTracker.awaitDispatchAuthorization(
                            attemptID: codexAttemptID
                        ) else { return }
                    }
                    let result = await submitNativeSlashCommandAfterHydration(
                        tabID: tabID,
                        invocation: nativeSlashCommand,
                        selectedWorkflowForGoal: activeWorkflow,
                        progressRestoreState: progressRestoreState
                    )
                    guard let codexAttemptID else { return }
                    let state: CodexSteerAckTracker.TerminalState = switch result {
                    case .succeeded:
                        .controlAccepted
                    case let .failed(message):
                        .failed(message: message)
                    case nil:
                        .stale(reason: "Native Codex slash command could not be delivered because the session changed before execution.")
                    }
                    session.codexSteerAckTracker.resolve(attemptID: codexAttemptID, state: state)
                }
                return .submitted
            case .userTurnWrapper:
                nativePreparedTurn = prepareNativeSlashPreparedUserTurn(nativeSlashCommand)
            }
        } else {
            nativePreparedTurn = nil
        }
        if nativePreparedTurn == nil,
           let validationFailure = validateSlashSkillUsage(in: trimmedText, activeWorkflow: activeWorkflow)
        {
            return validationFailure
        }

        // If no explicit workflow but a slash-skill is present, create a display-only
        // workflow for the chat bubble so the user sees which skill was used.
        // template is nil → wrapUserText is a no-op; actual expansion happens later
        // via expandSlashSkillInvocationIfNeeded in the augmentation path.
        let bubbleWorkflow: AgentWorkflowDefinition? = {
            if let nativePreparedTurn { return nativePreparedTurn.bubbleWorkflow }
            if activeWorkflow != nil { return activeWorkflow }
            guard let invocation = resolvedSlashSkillInvocations(in: trimmedText).first else { return nil }
            return invocation.definition.asBubbleWorkflowDefinition()
        }()

        // Capture and clear workflow before sending
        session.selectedWorkflow = nil
        selectedWorkflow = nil
        session.pendingImageAttachments.removeAll()
        session.pendingTaggedFileAttachments.removeAll()

        if session.activeAgentSessionID != nil, !session.hasLoadedPersistedState {
            Self.logCodexDebug("[AgentModeVM][RunID] deferring send until hydration completes for tab \(tabID)")
            Task { [weak self] in
                guard let self else { return }
                await submitUserTurnAfterHydration(
                    tabID: tabID,
                    trimmedText: trimmedText,
                    attachmentsToSend: attachmentsToSend,
                    taggedFilesToSend: taggedFilesToSend,
                    activeWorkflow: bubbleWorkflow,
                    nativePreparedTurn: nativePreparedTurn,
                    codexAttemptID: codexAttemptID
                )
            }
            return .submitted
        }

        return submitPreparedUserTurn(
            tabID: tabID,
            session: session,
            trimmedText: trimmedText,
            attachmentsToSend: attachmentsToSend,
            taggedFilesToSend: taggedFilesToSend,
            activeWorkflow: bubbleWorkflow,
            nativePreparedTurn: nativePreparedTurn,
            codexAttemptID: codexAttemptID
        )
    }

    private func submitUserTurnAfterHydration(
        tabID: UUID,
        trimmedText: String,
        attachmentsToSend: [AgentImageAttachment],
        taggedFilesToSend: [AgentTaggedFileAttachment],
        activeWorkflow: AgentWorkflowDefinition?,
        nativePreparedTurn: NativeSlashPreparedUserTurn? = nil,
        codexAttemptID: UUID? = nil
    ) async {
        guard let session = sessions[tabID] else { return }
        await prepareSessionForRunStart(tabID: tabID, session: session)
        guard let hydratedSession = sessions[tabID] else { return }
        _ = submitPreparedUserTurn(
            tabID: tabID,
            session: hydratedSession,
            trimmedText: trimmedText,
            attachmentsToSend: attachmentsToSend,
            taggedFilesToSend: taggedFilesToSend,
            activeWorkflow: activeWorkflow,
            nativePreparedTurn: nativePreparedTurn,
            codexAttemptID: codexAttemptID
        )
    }

    private static func shouldWakeParentAgentRunWaitersForActiveSubmit(
        selectedAgent: AgentProviderKind,
        codexCompactionInFlight: Bool
    ) -> Bool {
        selectedAgent != .codexExec || codexCompactionInFlight
    }

    #if DEBUG
        static func test_shouldWakeParentAgentRunWaitersForActiveSubmit(
            selectedAgent: AgentProviderKind,
            codexCompactionInFlight: Bool
        ) -> Bool {
            shouldWakeParentAgentRunWaitersForActiveSubmit(
                selectedAgent: selectedAgent,
                codexCompactionInFlight: codexCompactionInFlight
            )
        }
    #endif

    @discardableResult
    private func submitPreparedUserTurn(
        tabID: UUID,
        session: TabSession,
        trimmedText: String,
        attachmentsToSend: [AgentImageAttachment],
        taggedFilesToSend: [AgentTaggedFileAttachment],
        activeWorkflow: AgentWorkflowDefinition?,
        nativePreparedTurn: NativeSlashPreparedUserTurn? = nil,
        codexAttemptID: UUID? = nil
    ) -> UserTurnSubmissionResult {
        Self.logCodexDebug("[AgentModeVM] submitUserTurn: tabID=\(tabID), selectedAgent=\(session.selectedAgent), attachments=\(attachmentsToSend.count), taggedFiles=\(taggedFilesToSend.count), workflow=\(activeWorkflow?.displayName ?? "none")")

        let bubbleText: String
        if !trimmedText.isEmpty {
            // When a slash-skill is active, strip the `/skillname` prefix from the bubble
            // so the user sees only their arguments (the skill pill shows the command name).
            if let workflow = activeWorkflow, workflow.displayName.hasPrefix("/") {
                let tokens = Self.extractSlashSkillTokens(from: trimmedText)
                if let token = tokens.first {
                    let argsText = (trimmedText as NSString)
                        .substring(with: token.argumentsRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    bubbleText = argsText.isEmpty ? trimmedText : argsText
                } else {
                    bubbleText = trimmedText
                }
            } else {
                bubbleText = trimmedText
            }
        } else if !attachmentsToSend.isEmpty {
            bubbleText = "Sent \(attachmentsToSend.count) image\(attachmentsToSend.count == 1 ? "" : "s")"
        } else {
            bubbleText = "Included \(taggedFilesToSend.count) file\(taggedFilesToSend.count == 1 ? "" : "s")"
        }
        if nativePreparedTurn?.shouldEnableCodexComputerUse == true {
            session.pendingCodexComputerUseActivation = CodexComputerUseActivation(
                id: UUID(),
                createdAt: Date()
            )
        }
        let stagedCodexComputerUseActivationID = session.pendingCodexComputerUseActivation?.id

        // Prepend interview instruction to the user message if enabled (first message only)
        var effectiveUserText = nativePreparedTurn?.providerText ?? trimmedText
        if interviewFirst, session.items.isEmpty || !session.items.contains(where: { $0.kind == .assistant }) {
            effectiveUserText = """
            <interview_first>
            Before starting this task, interview me to make sure you fully understand what I need. Follow these rules exactly:

            1. Ask ONE question at a time using the `ask_user` tool. Always include an `options` array with 2–4 concrete multiple-choice answers so I can respond quickly. Add a final option like "Other (I'll explain)" when my answer might not be listed.
            2. After each answer, adapt your next question based on what I told you. Narrow in on specifics — don't repeat what you already know.
            3. Ask 1–3 questions total. Stop early if the task is already clear enough.
            4. After the interview, briefly summarize what you learned and how it shapes your approach, then proceed with the task.

            Example flow:
            - Q1: "What's the main goal?" → options: ["Add new feature", "Fix a bug", "Refactor existing code", "Other (I'll explain)"]
            - User picks "Add new feature"
            - Q2 (adapted): "Where should this feature live?" → options: ["Extend FooView", "New standalone view", "Backend service layer", "Other (I'll explain)"]
            - ...and so on, each question building on previous answers.
            </interview_first>

            \(effectiveUserText)
            """
            interviewFirst = false
        }

        // Wrap text with workflow template if selected
        let includeBuiltInCleanupGuidance = GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance()
        let wrappedText = activeWorkflow?.wrapUserText(
            effectiveUserText,
            includeBuiltInSessionCleanupGuidance: includeBuiltInCleanupGuidance
        ) ?? effectiveUserText
        let codexCompactionInFlight = session.selectedAgent == .codexExec
            && codexCoordinator.isCodexCompactionInFlight(session: session)

        autoSelectTaggedFilesForTurn(
            tabID: tabID,
            text: trimmedText,
            taggedFileAttachments: taggedFilesToSend
        )

        if session.runState.isActive,
           session.runState != .waitingForUser
        {
            flushPendingAssistantDelta(session)
        }

        let userItem = AgentChatItem.user(
            bubbleText,
            attachments: attachmentsToSend,
            taggedFileAttachments: taggedFilesToSend,
            sequenceIndex: session.nextSequenceIndex,
            workflow: activeWorkflow
        )
        recordAgentTurnUserAnchor(for: session, userItem: userItem)
        session.appendItem(userItem)
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)

        if session.runState == .running,
           !session.isMCPInstructionDispatchInProgress
        {
            Self.steeringDebugLog("[AgentRunSteeringWake] manual active submit accepted tab=\(tabID) runState=\(session.runState.rawValue) agent=\(session.selectedAgent.displayName) runID=\(String(describing: session.runID)) hasMCPContext=\(session.mcpControlContext != nil)")
            if let runID = session.runID,
               Self.shouldWakeParentAgentRunWaitersForActiveSubmit(
                   selectedAgent: session.selectedAgent,
                   codexCompactionInFlight: codexCompactionInFlight
               )
            {
                Task { @MainActor [weak self] in
                    guard let self, let mcpServer else { return }
                    await mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                        runID: runID,
                        source: "manual-active-submit-parent-run",
                        publicationForSessionID: { [weak self] childSessionID in
                            self?.mcpWaitPublication(sessionID: childSessionID)
                        }
                    )
                }
            }
            if session.mcpControlContext != nil {
                wakeCurrentMCPWaitersForSteeringRequestFireAndForget(for: session, source: "manual-active-submit-controlled-session")
            }
        }

        if shouldSignalMCPInstructionDeliveredAfterOptimisticSubmit(for: session) {
            signalMCPInstructionDeliveredFireAndForget(for: session)
        }

        if session.selectedAgent == .codexExec {
            let dispatchTicket = session.codexDispatchSerialGate.issueTicket()
            let fallbackContext = TabSession.CodexFallbackSubmissionContext(
                queueID: UUID(),
                providerText: wrappedText,
                images: attachmentsToSend,
                taggedFileAttachments: taggedFilesToSend,
                draftText: trimmedText,
                optimisticUserItemID: userItem.id,
                origin: codexAttemptID.map(TabSession.CodexFallbackOrigin.mcp) ?? .manual,
                dispatchTicket: dispatchTicket
            )
            Task {
                var handedOffToSerialDispatch = false
                defer {
                    if !handedOffToSerialDispatch {
                        session.codexDispatchSerialGate.cancel(dispatchTicket)
                    }
                }
                if let codexAttemptID {
                    guard await session.codexSteerAckTracker.awaitDispatchAuthorization(
                        attemptID: codexAttemptID
                    ) else { return }
                }
                handedOffToSerialDispatch = true
                let sendOutcome = await self.startAgentRun(
                    tabID: tabID,
                    initialMessage: wrappedText,
                    attachments: attachmentsToSend,
                    taggedFileAttachments: taggedFilesToSend,
                    codexFallbackContext: fallbackContext
                )
                if sendOutcome?.didSend != true {
                    self.clearPendingCodexComputerUseActivationIfMatched(
                        session: session,
                        activationID: stagedCodexComputerUseActivationID
                    )
                }
                guard let codexAttemptID else { return }
                let terminalState: CodexSteerAckTracker.TerminalState = switch sendOutcome {
                case .sent:
                    .steerAccepted
                case let .queuedFallback(queueID, _):
                    .durablyQueued(queueID: queueID)
                case let .stale(reason):
                    .stale(reason: reason)
                case .cancelled:
                    .cancelled
                case let .failed(message):
                    .failed(message: message)
                case nil:
                    .stale(reason: "Codex steer could not be delivered because the runtime changed before send started.")
                }
                session.codexSteerAckTracker.resolve(
                    attemptID: codexAttemptID,
                    state: terminalState
                )
            }
            return UserTurnSubmissionResult.submitted
        }

        let providerPreviewText = renderProviderMessage(
            text: wrappedText,
            attachments: attachmentsToSend,
            agent: session.selectedAgent
        )
        let userInputTokenEstimate = nonCodexContextUsageEstimator(for: session.selectedAgent)?
            .enqueueUserTurnEstimate(messageForProvider: providerPreviewText, session: session)
            ?? Self.estimateRuntimeTokens(for: providerPreviewText)

        // If agent is waiting for instruction, resume it.
        // Claude image attachments must go through a resumed turn (not wait-tool continuation),
        // otherwise attachment references are not forwarded reliably.
        if session.runState == .waitingForUser {
            if session.selectedAgent.usesClaudeNativeRuntime, !attachmentsToSend.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await cancelAgentRun(tabID: tabID)
                    await startAgentRun(
                        tabID: tabID,
                        initialMessage: wrappedText,
                        attachments: attachmentsToSend,
                        taggedFileAttachments: taggedFilesToSend
                    )
                }
                return UserTurnSubmissionResult.submitted
            }
            if session.instructionContinuation != nil {
                let textForContinuation = wrappedText
                let continuationAttachments = attachmentsToSend
                let continuationTaggedFiles = taggedFilesToSend
                _ = dequeuePendingNonCodexUserTokens(for: session) ?? userInputTokenEstimate
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session else { return }
                    let augmentedText = await augmentUserMessageForProviderSend(
                        textForContinuation,
                        attachments: continuationAttachments,
                        taggedFileAttachments: continuationTaggedFiles,
                        agent: session.selectedAgent,
                        session: session
                    )
                    guard let liveContinuation = session.instructionContinuation else { return }
                    let resumedTurnTokens = Self.estimateRuntimeTokens(for: augmentedText)
                    addUserInputTokensToActiveNonCodexTurn(resumedTurnTokens, for: session)
                    session.instructionTimeoutTask?.cancel()
                    session.instructionTimeoutTask = nil
                    session.instructionContinuation = nil
                    session.instructionWaitID = nil
                    session.waitingPrompt = nil
                    session.runState = .running
                    updateBindingsFromSession(session)
                    liveContinuation.resume(returning: UserInstructionResponse(
                        text: augmentedText,
                        timedOut: false,
                        elapsedSeconds: 0
                    ))
                }
                return UserTurnSubmissionResult.submitted
            }
        }

        // If agent is not running, start it
        if !session.runState.isActive {
            Task {
                await startAgentRun(
                    tabID: tabID,
                    initialMessage: wrappedText,
                    attachments: attachmentsToSend,
                    taggedFileAttachments: taggedFilesToSend
                )
            }
        } else if let route = activeProviderSteeringRoute(for: session, attachments: attachmentsToSend) {
            submitActiveProviderSteering(
                route,
                session: session,
                wrappedText: wrappedText,
                attachmentsToSend: attachmentsToSend,
                taggedFilesToSend: taggedFilesToSend,
                trimmedText: trimmedText,
                userItem: userItem,
                userInputTokenEstimate: userInputTokenEstimate
            )
        } else {
            // Shared follow-up queue for providers that consume queued instructions at the next turn boundary.
            session.pendingInstructions.append(wrappedText)
        }
        return UserTurnSubmissionResult.submitted
    }

    private func interruptedACPProviderText(for session: TabSession, before steeringUserItem: AgentChatItem) -> String? {
        guard let interruptedUserItem = session.items.last(where: {
            $0.kind == .user && $0.sequenceIndex < steeringUserItem.sequenceIndex
        }) else {
            return nil
        }
        let rendered = renderProviderMessage(
            text: interruptedUserItem.text,
            attachments: interruptedUserItem.attachments,
            agent: session.selectedAgent
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func activeProviderSteeringRoute(
        for session: TabSession,
        attachments: [AgentImageAttachment] = []
    ) -> ActiveProviderSteeringRoute? {
        guard session.runState == .running,
              session.pendingApproval == nil else { return nil }
        if activeACPPromptIsAvailable(for: session, attachments: attachments) {
            return .acpPrompt
        }
        if session.selectedAgent.usesClaudeNativeRuntime {
            return .claudeNativeInterrupt
        }
        return nil
    }

    private func activeACPPromptIsAvailable(
        for session: TabSession,
        attachments: [AgentImageAttachment]
    ) -> Bool {
        guard session.selectedAgent.acpProviderID != nil,
              session.runState == .running,
              session.pendingApproval == nil,
              session.pendingAskUser == nil,
              session.pendingUserInputRequest == nil,
              session.pendingPermissionsRequest == nil,
              attachments.isEmpty,
              session.runID != nil,
              session.activeRunAttemptID != nil,
              session.acpController != nil
        else {
            return false
        }
        // ACP live steering is safe only through the serialized queue. The queue
        // waits for RepoPrompt MCP tools to go idle, then the runner sends
        // session/cancel and waits for the cancelled prompt to settle before the
        // steering session/prompt. Never send prompt-only steering while a turn is
        // already running.
        return true
    }

    private func submitActiveProviderSteering(
        _ route: ActiveProviderSteeringRoute,
        session: TabSession,
        wrappedText: String,
        attachmentsToSend: [AgentImageAttachment],
        taggedFilesToSend: [AgentTaggedFileAttachment],
        trimmedText: String,
        userItem: AgentChatItem,
        userInputTokenEstimate: Int
    ) {
        switch route {
        case .acpPrompt:
            // ACP live steering uses the same serialized queued-flush shape as
            // Claude native steering. The run service waits for MCP tools to go idle,
            // sends session/cancel, waits for the active ACP prompt to settle, then
            // submits the steering session/prompt. Do not prompt directly here.
            let interruptedPromptProviderText = interruptedACPProviderText(for: session, before: userItem)
            let steering = TabSession.ACPSteeringInstruction(
                id: UUID(),
                targetRunID: session.runID,
                targetRunAttemptID: session.activeRunAttemptID,
                providerText: wrappedText,
                interruptedPromptProviderText: interruptedPromptProviderText,
                attachments: attachmentsToSend,
                taggedFileAttachments: taggedFilesToSend,
                draftText: trimmedText,
                optimisticUserItemID: userItem.id,
                createdAt: Date()
            )
            session.pendingACPSteeringInstructions.append(steering)
            Self.steeringDebugLog("[AgentRunSteeringWake] ACP steering queued tab=\(session.tabID) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID)) queue=\(session.pendingACPSteeringInstructions.count) mcpDispatch=\(session.isMCPInstructionDispatchInProgress)")
            guard !session.isMCPInstructionDispatchInProgress else {
                Self.steeringDebugLog("[AgentRunSteeringWake] ACP steering flush owned by MCP dispatch tab=\(session.tabID) queue=\(session.pendingACPSteeringInstructions.count)")
                return
            }
            Task { [weak self, weak session] in
                guard let self, let session else { return }
                let accepted = await runService.submitQueuedACPSteeringIfSupported(session: session)
                guard !accepted,
                      let queuedIndex = session.pendingACPSteeringInstructions.firstIndex(where: { $0.id == steering.id })
                else {
                    return
                }
                let queued = session.pendingACPSteeringInstructions.remove(at: queuedIndex)
                if session.runState.isActive {
                    session.pendingInstructions.insert(queued.providerText, at: 0)
                } else if session.runState == .completed, session.acpController != nil {
                    await startAgentRun(tabID: session.tabID, initialMessage: queued.providerText)
                } else {
                    // ACP steering should never bounce back into the composer. If the
                    // active-steering queue was rejected before the run service could take it,
                    // preserve it as a normal provider follow-up instead.
                    session.pendingInstructions.insert(queued.providerText, at: 0)
                    session.isDirty = true
                    updateBindingsFromSession(session)
                    scheduleSave(for: session.tabID)
                }
            }
        case .claudeNativeInterrupt:
            // Claude Code preserves draft text and wakes current MCP waiters as soon
            // as the local steering request is accepted, then sends after MCP tools idle.
            let steering = TabSession.ClaudeSteeringInstruction(
                id: UUID(),
                targetRunID: session.runID,
                targetRunAttemptID: session.activeRunAttemptID,
                providerText: wrappedText,
                attachments: attachmentsToSend,
                taggedFileAttachments: taggedFilesToSend,
                draftText: trimmedText,
                optimisticUserItemID: userItem.id,
                createdAt: Date(),
                supersedingProtectedTurnIDs: []
            )
            session.pendingClaudeSteeringInstructions.append(steering)
            runService.protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(session: session, steeringID: steering.id)
            Self.steeringDebugLog("[AgentRunSteeringWake] Claude steering queued tab=\(session.tabID) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID)) queue=\(session.pendingClaudeSteeringInstructions.count) mcpDispatch=\(session.isMCPInstructionDispatchInProgress)")
            guard !session.isMCPInstructionDispatchInProgress else {
                Self.steeringDebugLog("[AgentRunSteeringWake] Claude steering flush owned by MCP dispatch tab=\(session.tabID) queue=\(session.pendingClaudeSteeringInstructions.count)")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                _ = await runService.submitQueuedClaudeSteeringIfSupported(session: session)
            }
        }
    }

    private struct NativeControlProgressRestoreState {
        let id: UUID
        let tabID: UUID
        let previousRunState: AgentSessionRunState
        let previousRunningStatusText: String?
        let previousRunningStatusSource: TabSession.RunningStatusSource?
        let previousActiveAgentRunStartedAt: Date?
        let wasMarkedActiveInTabs: Bool
        let progressStatusText: String
    }

    private func appendOptimisticGoalObjectiveUserBubbleIfNeeded(
        action: CodexAgentModeCoordinator.GoalSlashAction?,
        session: TabSession,
        workflow: AgentWorkflowDefinition?
    ) {
        guard case let .setObjective(objective) = action else { return }
        let userItem = AgentChatItem.user(
            objective,
            sequenceIndex: session.nextSequenceIndex,
            workflow: workflow,
            codexGoalMode: AgentCodexGoalModeMetadata(action: .setObjective),
            isLocalControlPlaneEcho: true
        )
        session.appendItem(userItem)
        updateBindingsFromSession(session)
        scheduleSave(for: session.tabID)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func beginNativeSlashControlProgressIfNeeded(
        command: CodexAgentModeCoordinator.NativeSlashCommand,
        action: CodexAgentModeCoordinator.GoalSlashAction?,
        session: TabSession
    ) -> NativeControlProgressRestoreState? {
        guard command == .goal else { return nil }
        let progressText = switch action ?? .show {
        case .setObjective:
            "Setting Codex goal…"
        case .show:
            "Loading Codex goal…"
        case .pause:
            "Pausing Codex goal…"
        case .resume:
            "Resuming Codex goal…"
        case .clear:
            "Clearing Codex goal…"
        }
        let id = UUID()
        let restoreState = NativeControlProgressRestoreState(
            id: id,
            tabID: session.tabID,
            previousRunState: session.runState,
            previousRunningStatusText: session.runningStatusText,
            previousRunningStatusSource: session.runningStatusSource,
            previousActiveAgentRunStartedAt: session.activeAgentRunStartedAt,
            wasMarkedActiveInTabs: tabsWithActiveAgentRun.contains(session.tabID),
            progressStatusText: progressText
        )
        session.nativeControlProgressID = id
        session.runState = .running
        session.setRunningStatus(progressText, source: .transport)
        setAgentRunActive(session.tabID, isActive: true)
        requestUIRefresh(tabID: session.tabID, urgent: true)
        return restoreState
    }

    private func finishNativeSlashControlProgress(
        _ restoreState: NativeControlProgressRestoreState?,
        session: TabSession?
    ) {
        guard let restoreState,
              let session,
              session.nativeControlProgressID == restoreState.id
        else { return }
        let progressStillDisplayed = session.runningStatusText == restoreState.progressStatusText
            && session.runningStatusSource == .transport
        session.nativeControlProgressID = nil
        guard progressStillDisplayed else {
            requestUIRefresh(tabID: restoreState.tabID, urgent: true)
            return
        }
        session.setRunningStatus(
            restoreState.previousRunningStatusText,
            source: restoreState.previousRunningStatusSource
        )
        if session.runState == .running {
            session.runState = restoreState.previousRunState
        }
        if restoreState.wasMarkedActiveInTabs {
            session.activeAgentRunStartedAt = restoreState.previousActiveAgentRunStartedAt
            publishActiveAgentRunStartedAt(for: restoreState.tabID, session: session)
        } else {
            setAgentRunActive(restoreState.tabID, isActive: false)
        }
        requestUIRefresh(tabID: restoreState.tabID, urgent: true)
    }

    private func submitNativeSlashCommandAfterHydration(
        tabID: UUID,
        invocation: ResolvedNativeSlashCommand,
        selectedWorkflowForGoal: AgentWorkflowDefinition?,
        progressRestoreState: NativeControlProgressRestoreState?
    ) async -> CodexAgentModeCoordinator.NativeSlashCommandExecutionResult? {
        guard let session = sessions[tabID] else { return nil }
        let semanticRunState = progressRestoreState?.previousRunState ?? session.runState
        if !semanticRunState.isActive || (session.activeAgentSessionID != nil && !session.hasLoadedPersistedState) {
            await prepareSessionForRunStart(tabID: tabID, session: session)
        }
        guard let hydratedSession = sessions[tabID] else {
            finishNativeSlashControlProgress(progressRestoreState, session: sessions[tabID])
            return nil
        }
        let result = await codexCoordinator.executeNativeSlashCommand(
            invocation.command,
            argumentsText: invocation.argumentsText,
            session: hydratedSession,
            selectedWorkflowForGoal: selectedWorkflowForGoal,
            semanticRunStateForControlCommand: progressRestoreState?.previousRunState
        )
        switch result {
        case let .succeeded(message):
            let item = AgentChatItem.system(message, sequenceIndex: hydratedSession.nextSequenceIndex)
            hydratedSession.appendItem(item)
        case let .failed(message):
            let item = AgentChatItem.error(message, sequenceIndex: hydratedSession.nextSequenceIndex)
            hydratedSession.appendItem(item)
        }
        updateBindingsFromSession(hydratedSession)
        scheduleSave(for: tabID)
        finishNativeSlashControlProgress(progressRestoreState, session: hydratedSession)
        return result
    }

    private func resolvedNativeSlashCommand(
        in text: String,
        session: TabSession
    ) -> ResolvedNativeSlashCommand? {
        guard let token = Self.extractSlashSkillTokens(from: text).first,
              !token.name.lowercased().hasPrefix("skill:"),
              let command = codexCoordinator.nativeSlashCommand(named: token.name, session: session)
        else {
            return nil
        }
        let argumentsText = (text as NSString)
            .substring(with: token.argumentsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedNativeSlashCommand(command: command, token: token, argumentsText: argumentsText)
    }

    private func prepareNativeSlashPreparedUserTurn(
        _ invocation: ResolvedNativeSlashCommand
    ) -> NativeSlashPreparedUserTurn {
        switch invocation.command {
        case .computerUse:
            NativeSlashPreparedUserTurn(
                command: invocation.command,
                argumentsText: invocation.argumentsText,
                providerText: CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: invocation.argumentsText),
                bubbleWorkflow: CodexComputerUseWorkflow.bubbleWorkflowDefinition(),
                shouldEnableCodexComputerUse: true
            )
        case .compact, .goal:
            NativeSlashPreparedUserTurn(
                command: invocation.command,
                argumentsText: invocation.argumentsText,
                providerText: invocation.argumentsText,
                bubbleWorkflow: nil,
                shouldEnableCodexComputerUse: false
            )
        }
    }

    private func clearPendingCodexComputerUseActivationIfMatched(
        session: TabSession,
        activationID: UUID?
    ) {
        guard let activationID,
              session.pendingCodexComputerUseActivation?.id == activationID
        else {
            return
        }
        session.pendingCodexComputerUseActivation = nil
    }

    private func validateNativeSlashCommandUsage(
        _ invocation: ResolvedNativeSlashCommand,
        session: TabSession,
        attachments: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        activeWorkflow: AgentWorkflowDefinition?
    ) -> UserTurnSubmissionResult? {
        let argumentsText = invocation.argumentsText
        if activeWorkflow != nil,
           invocation.command.behavior == .userTurnWrapper
        {
            return .blocked(message: "/\(invocation.command.rawValue) is a Codex native workflow that starts its own provider turn. Clear the selected prompt workflow before using it.")
        }
        if !attachments.isEmpty || !taggedFiles.isEmpty {
            let suffix = invocation.command == .computerUse ? " yet" : ""
            return .blocked(message: "The /\(invocation.command.rawValue) command cannot be used with attachments or tagged files\(suffix).")
        }
        switch invocation.command {
        case .compact:
            if !argumentsText.isEmpty {
                return .blocked(message: "/compact does not take arguments.")
            }
        case .goal:
            if case let .setObjective(objective) = CodexAgentModeCoordinator.goalSlashAction(from: argumentsText) {
                if let message = CodexAgentModeCoordinator.goalObjectiveValidationMessage(objective) {
                    return .blocked(message: message)
                }
                if let activeWorkflow {
                    let includeBuiltInCleanupGuidance = GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance()
                    switch CodexAgentModeCoordinator.composeGoalObjective(
                        rawObjective: objective,
                        selectedWorkflow: activeWorkflow,
                        includeBuiltInSessionCleanupGuidance: includeBuiltInCleanupGuidance
                    ) {
                    case .success:
                        break
                    case let .failure(message):
                        return .blocked(message: message)
                    }
                }
            }
        case .computerUse:
            break
        }
        let shouldCheckAvailability = invocation.command == .computerUse
            || session.activeAgentSessionID == nil
            || session.hasLoadedPersistedState
        if shouldCheckAvailability,
           let availabilityMessage = codexCoordinator.nativeSlashCommandAvailabilityMessage(
               invocation.command,
               argumentsText: argumentsText,
               session: session
           )
        {
            return .blocked(message: availabilityMessage)
        }
        return nil
    }

    private func validateSlashSkillUsage(
        in text: String,
        activeWorkflow: AgentWorkflowDefinition?
    ) -> UserTurnSubmissionResult? {
        let invocations = resolvedSlashSkillInvocations(in: text)
        guard !invocations.isEmpty else {
            return nil
        }
        if invocations.count > 1 {
            return .blocked(message: "Only one /skill can be used per message.")
        }
        if activeWorkflow != nil {
            return .blocked(message: "Use either a selected workflow or a /skill, not both.")
        }
        return nil
    }

    func resolvedSlashSkillInvocations(in text: String) -> [ResolvedSlashSkillInvocation] {
        Self.extractSlashSkillTokens(from: text).compactMap { token in
            let resolvedName: String = {
                let normalizedName = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedName.lowercased().hasPrefix("skill:") {
                    return String(normalizedName.dropFirst("skill:".count))
                }
                return normalizedName
            }()
            guard !resolvedName.isEmpty,
                  let definition = skillCatalog.resolve(name: resolvedName)
            else {
                return nil
            }
            return ResolvedSlashSkillInvocation(definition: definition, token: token)
        }
    }

    /// Extract a slash-skill token only when `/` is the first non-whitespace character in the text.
    /// This allows literal slashes deeper in the input (e.g. file paths) without triggering skill expansion.
    static func extractSlashSkillTokens(from text: String) -> [SlashSkillToken] {
        guard !text.isEmpty else { return [] }
        let fullText = text as NSString
        let length = fullText.length
        guard length > 0 else { return [] }

        // Find the first non-whitespace character; it must be `/` for a skill token.
        var slashIndex = 0
        while slashIndex < length {
            let ch = fullText.character(at: slashIndex)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                slashIndex += 1
                continue
            }
            break
        }
        guard slashIndex < length, fullText.character(at: slashIndex) == 47 /* "/" */ else {
            return []
        }

        // Scan the skill name immediately after the `/`
        var cursor = slashIndex + 1
        var hasNameCharacter = false
        var isInvalidToken = false
        while cursor < length {
            let current = fullText.character(at: cursor)
            guard let scalar = UnicodeScalar(current) else {
                isInvalidToken = true
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                break
            }
            if Self.slashSkillNameScalars.contains(scalar) {
                hasNameCharacter = true
                cursor += 1
                continue
            }
            if scalar == ":",
               fullText.substring(with: NSRange(location: slashIndex + 1, length: cursor - slashIndex - 1)).lowercased() == "skill"
            {
                hasNameCharacter = true
                cursor += 1
                continue
            }
            isInvalidToken = true
            break
        }

        guard hasNameCharacter, !isInvalidToken else { return [] }

        let nameRange = NSRange(location: slashIndex + 1, length: cursor - slashIndex - 1)
        let name = fullText.substring(with: nameRange)
        let tokenRange = NSRange(location: slashIndex, length: cursor - slashIndex)
        let argumentsRange = NSRange(location: cursor, length: length - cursor)
        return [SlashSkillToken(name: name, tokenRange: tokenRange, argumentsRange: argumentsRange)]
    }

    private func shouldSignalMCPInstructionDeliveredAfterOptimisticSubmit(for session: TabSession) -> Bool {
        guard session.mcpControlContext != nil,
              session.runState == .running,
              !session.isMCPInstructionDispatchInProgress
        else {
            return false
        }
        return mcpActiveInstructionDeliverySignalTiming(for: session) == .afterOptimisticSubmit
    }

    private func mcpActiveInstructionDeliverySignalTiming(
        for session: TabSession
    ) -> MCPActiveInstructionDeliverySignalTiming {
        switch activeProviderSteeringRoute(for: session) {
        case .claudeNativeInterrupt, .acpPrompt:
            .afterProviderSend
        case nil:
            session.selectedAgent == .codexExec
                ? .afterProviderSend
                : .afterOptimisticSubmit
        }
    }

    #if DEBUG
        static func test_mcpActiveInstructionDeliverySignalTiming(
            selectedAgent: AgentProviderKind,
            hasNativeSteeringRoute: Bool
        ) -> MCPActiveInstructionDeliverySignalTiming {
            if hasNativeSteeringRoute {
                return .afterProviderSend
            }
            return selectedAgent == .codexExec
                ? .afterProviderSend
                : .afterOptimisticSubmit
        }
    #endif

    func renderProviderMessage(
        text: String,
        attachments: [AgentImageAttachment],
        agent: AgentProviderKind
    ) -> String {
        guard !attachments.isEmpty else { return text }
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .openCode, .cursor:
            return renderAtPathAttachmentMessage(text: text, attachments: attachments)
        case .codexExec:
            return text
        }
    }

    private func renderAtPathAttachmentMessage(text: String, attachments: [AgentImageAttachment]) -> String {
        var lines: [String] = []
        for attachment in attachments {
            switch attachment.source {
            case let .localFile(path):
                let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPath.isEmpty else { continue }
                lines.append("@\(escapePathForAtCommand(trimmedPath))")
            case let .url(url):
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty else { continue }
                lines.append(trimmedURL)
            }
        }
        guard !lines.isEmpty else { return text }
        if !text.isEmpty {
            lines.append("")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    func escapePathForAtCommand(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private static func estimateRuntimeTokens(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return TokenCalculationService.estimateTokens(for: trimmed)
    }

    static func extractTaggedPaths(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let scalars = Array(text.unicodeScalars)
        var ordered: [String] = []
        ordered.reserveCapacity(8)
        var seen = Set<String>()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "@" else {
                index += 1
                continue
            }
            if index > 0 {
                let previous = scalars[index - 1]
                if !taggedFileTerminatingScalars.contains(previous) {
                    index += 1
                    continue
                }
            }

            var cursor = index + 1
            var tokenScalars: [UnicodeScalar] = []
            var isEscaped = false

            while cursor < scalars.count {
                let current = scalars[cursor]
                if isEscaped {
                    tokenScalars.append(current)
                    isEscaped = false
                    cursor += 1
                    continue
                }
                if current == "\\" {
                    isEscaped = true
                    cursor += 1
                    continue
                }
                if taggedFileTerminatingScalars.contains(current) {
                    break
                }
                tokenScalars.append(current)
                cursor += 1
            }

            var token = String(String.UnicodeScalarView(tokenScalars))
            token = token.trimmingCharacters(in: taggedFileTrailingTrimSet)
            if !token.isEmpty {
                let lowered = token.lowercased()
                if !lowered.hasPrefix("/"),
                   !lowered.hasPrefix("~"),
                   !lowered.hasPrefix("file://"),
                   seen.insert(token).inserted
                {
                    ordered.append(token)
                }
            }

            index = cursor
        }

        return ordered
    }

    static func unescapeTaggedPath(_ value: String) -> String {
        guard value.contains("\\") else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let scalars = Array(value.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let current = scalars[index]
            if current == "\\", index + 1 < scalars.count {
                let next = scalars[index + 1]
                switch next {
                case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                    output.append(next)
                default:
                    output.append(current)
                    output.append(next)
                }
                index += 2
                continue
            }
            output.append(current)
            index += 1
        }
        return String(String.UnicodeScalarView(output)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func fileContentsXMLForTaggedPaths(
        _ taggedPaths: [String],
        tokenBudget: Int,
        maxFiles: Int,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> String? {
        guard let promptManager else { return nil }
        return await Self.taggedFileContentsXMLForTaggedPaths(
            taggedPaths,
            tokenBudget: tokenBudget,
            maxFiles: maxFiles,
            store: promptManager.workspaceFileContextStore,
            lookupContext: lookupContext
        )
    }

    static func taggedFileContentsXMLForTaggedPaths(
        _ taggedPaths: [String],
        tokenBudget: Int,
        maxFiles: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> String? {
        guard !taggedPaths.isEmpty else { return nil }

        enum TaggedReadableFile {
            case workspace(ResolvedPromptFileEntry)
            case external(WorkspaceExternalReadableFile)
        }

        let readableService = WorkspaceReadableFileService(store: store)
        var orderedFiles: [TaggedReadableFile] = []
        orderedFiles.reserveCapacity(min(taggedPaths.count, maxFiles))
        var workspaceEntries: [ResolvedPromptFileEntry] = []
        workspaceEntries.reserveCapacity(min(taggedPaths.count, maxFiles))
        var seenFileIDs = Set<UUID>()
        var seenExternalPaths = Set<String>()
        let rootsByID = await Dictionary(uniqueKeysWithValues: store.rootRefs(scope: lookupContext.rootScope).map { ($0.id, $0) })

        for taggedPath in taggedPaths {
            guard orderedFiles.count < maxFiles else { break }
            let translatedPath = lookupContext.translateInputPath(taggedPath)
            guard let readable = await readableService.resolveReadableFile(
                translatedPath,
                profile: .mcpRead,
                rootScope: lookupContext.rootScope
            ) else { continue }
            switch readable {
            case let .workspace(file):
                guard seenFileIDs.insert(file.id).inserted,
                      let content = try? await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath),
                      let root = rootsByID[file.rootID]
                else { continue }
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: false,
                    mode: .fullFile,
                    loadedContent: content,
                    rootFolderPath: root.standardizedFullPath
                )
                workspaceEntries.append(entry)
                orderedFiles.append(.workspace(entry))
            case let .external(externalFile):
                guard seenExternalPaths.insert(externalFile.absolutePath).inserted else { continue }
                orderedFiles.append(.external(externalFile))
            }
        }

        guard !orderedFiles.isEmpty else { return nil }

        let workspaceBlocks = PromptPackagingService.generateFileBlocksDetailed(
            files: workspaceEntries,
            filePathDisplay: .relative,
            codemapSnapshotBundle: .empty,
            displayPathResolver: { entry in
                lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                    forPhysicalPath: entry.file.standardizedFullPath,
                    display: .relative
                )
            }
        )
        let workspaceBlocksByID = Dictionary(uniqueKeysWithValues: workspaceBlocks.map { ($0.file.id, $0.text) })

        var blocks: [String] = []
        blocks.reserveCapacity(orderedFiles.count)
        for file in orderedFiles {
            switch file {
            case let .workspace(workspaceEntry):
                guard let block = workspaceBlocksByID[workspaceEntry.file.id], !block.isEmpty else { continue }
                blocks.append(block)
            case let .external(externalFile):
                guard let content = try? await readableService.readAlwaysReadableExternalFile(externalFile) else { continue }
                blocks.append(Self.externalTaggedFileBlock(displayPath: externalFile.displayPath, content: content))
            }
        }

        guard !blocks.isEmpty else { return nil }

        var acceptedBlocks: [String] = []
        acceptedBlocks.reserveCapacity(blocks.count)
        var runningTokens = 0
        for block in blocks {
            let blockTokens = TokenCalculationService.estimateTokens(for: block)
            if runningTokens + blockTokens > tokenBudget {
                break
            }
            acceptedBlocks.append(block)
            runningTokens += blockTokens
        }

        guard !acceptedBlocks.isEmpty else { return nil }
        return """
        <file_contents>
        \(acceptedBlocks.joined(separator: "\n\n"))
        </file_contents>
        """
    }

    private nonisolated static func externalTaggedFileBlock(displayPath: String, content: String) -> String {
        let fence = PromptPackagingService.codeFenceStart(for: displayPath)
        return """
        File: \(displayPath)
        \(fence)
        \(content)
        ```
        """
    }

    @MainActor
    private func autoSelectTaggedFilesForTurn(
        tabID: UUID,
        text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment]
    ) {
        guard Self.shouldAttemptTaggedFileAutoSelection(
            text: text,
            taggedFileAttachments: taggedFileAttachments
        ) else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.promoteSelectionPathsToFullContext(
                tabID: tabID,
                rawPaths: Self.taggedSelectionRawPaths(text: text, taggedFileAttachments: taggedFileAttachments)
            )
        }
    }

    private static func taggedSelectionRawPaths(
        text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment]
    ) -> [String] {
        var rawPaths: [String] = []
        rawPaths.reserveCapacity(extractTaggedPaths(from: text).count + taggedFileAttachments.count)
        rawPaths.append(contentsOf: extractTaggedPaths(from: text))
        rawPaths.append(contentsOf: taggedFileAttachments.map(\.relativePath))
        return rawPaths
    }

    @MainActor
    func promoteSelectionPathsToFullContext(
        tabID: UUID,
        rawPaths: [String]
    ) async {
        guard !rawPaths.isEmpty,
              let promptManager,
              let workspaceManager
        else {
            return
        }

        let store = promptManager.workspaceFileContextStore
        let lookupContext = await agentWorkspaceLookupContext(tabID: tabID, session: session(for: tabID, createIfNeeded: false))
        let resolvedPaths = await resolvedWorkspaceTaggedSelectionPaths(
            rawPaths: rawPaths,
            store: store,
            lookupContext: lookupContext
        )
        guard !resolvedPaths.isEmpty else { return }

        if promptManager.activeComposeTabID == tabID {
            workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        guard var tab = workspaceManager.composeTab(with: tabID) else { return }
        let updatedSelection = Self.selectionByPromotingPathsToFullSelection(
            tab.selection,
            paths: resolvedPaths,
            lookupContext: lookupContext
        )
        guard updatedSelection != tab.selection else { return }
        tab.selection = updatedSelection
        workspaceManager.updateComposeTabStoredOnly(tab)
    }

    static func shouldAttemptTaggedFileAutoSelection(
        text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment]
    ) -> Bool {
        !taggedFileAttachments.isEmpty || !extractTaggedPaths(from: text).isEmpty
    }

    private func resolvedWorkspaceTaggedSelectionPaths(
        rawPaths: [String],
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [String] {
        var normalizedPaths: [String] = []
        normalizedPaths.reserveCapacity(rawPaths.count)
        var seenInputs = Set<String>()
        for rawPath in rawPaths {
            let normalizedPath = Self.unescapeTaggedPath(rawPath)
            guard !normalizedPath.isEmpty, seenInputs.insert(normalizedPath).inserted else { continue }
            normalizedPaths.append(normalizedPath)
        }
        guard !normalizedPaths.isEmpty else { return [] }

        let translatedPaths = normalizedPaths.map { lookupContext.translateInputPath($0) }
        let requests = translatedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: .mcpRead, rootScope: lookupContext.rootScope)
        }
        let lookupResults = await store.lookupPaths(requests)
        var resolvedPaths: [String] = []
        resolvedPaths.reserveCapacity(normalizedPaths.count)
        var seenResolved = Set<String>()
        for translatedPath in translatedPaths {
            guard let file = lookupResults[translatedPath]?.file else { continue }
            let physicalPath = file.standardizedFullPath
            guard seenResolved.insert(physicalPath).inserted else { continue }
            resolvedPaths.append(lookupContext.displayPath(forPhysicalPath: physicalPath, display: .full))
        }
        return resolvedPaths
    }

    nonisolated static func selectionByPromotingPathsToFullSelection(
        _ selection: StoredSelection,
        paths: [String],
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) -> StoredSelection {
        let logicalSelection = lookupContext.logicalizeSelection(selection)
        let promotedPaths = StoredSelectionPathNormalization.standardizedPaths(paths)
        guard !promotedPaths.isEmpty else { return logicalSelection == selection ? selection : logicalSelection }

        let existingPaths = StoredSelectionPathNormalization.standardizedPaths(logicalSelection.selectedPaths)
        let existingAutoCodemapPaths = StoredSelectionPathNormalization.standardizedPaths(logicalSelection.autoCodemapPaths)
        let existingSlices = StoredSelectionPathNormalization.standardizedSlices(logicalSelection.slices)
        let promotedKeys = Set(promotedPaths.map { physicalizedSelectionKey($0, lookupContext: lookupContext) })

        var mergedPaths = existingPaths
        var seen = Set(existingPaths.map { physicalizedSelectionKey($0, lookupContext: lookupContext) })
        for path in promotedPaths where seen.insert(physicalizedSelectionKey(path, lookupContext: lookupContext)).inserted {
            mergedPaths.append(path)
        }

        let filteredAutoCodemapPaths = existingAutoCodemapPaths.filter {
            !promotedKeys.contains(physicalizedSelectionKey($0, lookupContext: lookupContext))
        }
        let filteredSlices = existingSlices.filter {
            !promotedKeys.contains(physicalizedSelectionKey($0.key, lookupContext: lookupContext))
        }

        let normalizedSelection = StoredSelection(
            selectedPaths: existingPaths,
            autoCodemapPaths: existingAutoCodemapPaths,
            slices: existingSlices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
        let updatedSelection = StoredSelection(
            selectedPaths: mergedPaths,
            autoCodemapPaths: filteredAutoCodemapPaths,
            slices: filteredSlices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
        return updatedSelection == normalizedSelection && logicalSelection == selection ? selection : updatedSelection
    }

    private nonisolated static func physicalizedSelectionKey(
        _ path: String,
        lookupContext: WorkspaceLookupContext
    ) -> String {
        let translated = lookupContext.translateInputPath(path)
        let expanded = (translated as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return StandardizedPath.absolute(expanded)
        }
        return StandardizedPath.relative(expanded)
    }

    @MainActor
    func augmentUserMessageForProviderSend(
        _ text: String,
        attachments: [AgentImageAttachment] = [],
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        agent: AgentProviderKind? = nil,
        session: TabSession? = nil
    ) async -> String {
        let effectiveAgent = session?.selectedAgent ?? agent ?? activeSession?.selectedAgent ?? selectedAgent
        let withSkillExpansion = await expandSlashSkillInvocationIfNeeded(text, agentKind: effectiveAgent)
        let lookupContext: WorkspaceLookupContext = if let session {
            await agentWorkspaceLookupContext(tabID: session.tabID, session: session)
        } else if let tabID = currentTabID {
            await agentWorkspaceLookupContext(tabID: tabID, session: sessions[tabID])
        } else {
            .visibleWorkspace
        }
        let withTaggedFiles = await augmentUserMessageWithTaggedFileContents(
            withSkillExpansion,
            taggedFileAttachments: taggedFileAttachments,
            lookupContext: lookupContext
        )
        let withAttachmentRendering = renderProviderMessage(
            text: withTaggedFiles,
            attachments: attachments,
            agent: effectiveAgent
        )
        guard let session else { return withAttachmentRendering }
        return prependPendingHandoffIfNeeded(withAttachmentRendering, session: session)
    }

    @MainActor
    func prependPendingHandoffIfNeeded(
        _ text: String,
        session: TabSession
    ) -> String {
        guard let handoffPayload = session.pendingHandoff.payload,
              session.pendingHandoff.isStagedForSend == false
        else {
            return text
        }
        let trimmedPayload = handoffPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else {
            return text
        }
        session.pendingHandoff.isStagedForSend = true
        return trimmedPayload + "\n\n" + text
    }

    // SEARCH-HELPER: Handoff, Resume, Recovery, Transcript, Session Transfer
    // Shared helper that stages a resume-recovery handoff so the model has
    // conversational context after a forced fresh session start.
    @MainActor
    func stageResumeRecoveryHandoffIfNeeded(for session: TabSession) async {
        // Don't overwrite an existing staged payload.
        if let existingPayload = session.pendingHandoff.payload,
           !existingPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }
        let cutoffItemID = session.items.last(where: { $0.kind != .thinking })?.id
        let sourceTabName = normalizedSessionTitle(workspaceManager?.composeTabName(with: session.tabID))
        let escapedSourceTabName = sourceTabName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let sourceAgentName = session.selectedAgent.displayName
        let transcriptXML = buildForkTranscriptXML(from: session, upToItemID: cutoffItemID)
        // delivery_id makes crash/restart retries best-effort idempotent at the prompt level.
        let deliveryID = UUID().uuidString
        let payload = await Self.composeClaudeResumeRecoveryHandoffPayload(
            sourceTabName: escapedSourceTabName,
            sourceAgentName: sourceAgentName,
            transcriptXML: transcriptXML,
            initialThreadContextBlock: buildInitialThreadContextBlock(tabID: session.tabID),
            deliveryID: deliveryID
        )
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        session.pendingHandoff = PendingHandoffState(
            payload: payload,
            createdAt: Date(),
            sourceItemID: cutoffItemID,
            defersProviderLockUntilSend: false,
            isStagedForSend: false
        )
        session.isDirty = true
    }

    @MainActor
    func stageClaudeResumeRecoveryHandoffIfNeeded(for session: TabSession) async {
        await stageResumeRecoveryHandoffIfNeeded(for: session)
    }

    @MainActor
    private func recordPendingHandoffSendOutcome(for session: TabSession, didSend: Bool) {
        guard session.pendingHandoff.isStagedForSend else { return }
        if didSend {
            session.pendingHandoff.clearAfterSend()
            session.isDirty = true
            scheduleSave(for: session.tabID)
            return
        }
        session.pendingHandoff.isStagedForSend = false
    }

    @MainActor
    private func expandSlashSkillInvocationIfNeeded(
        _ text: String,
        agentKind: AgentProviderKind? = nil
    ) async -> String {
        guard !text.isEmpty else { return text }
        await refreshSkillCatalog(force: false, agentKind: agentKind)
        var invocations = resolvedSlashSkillInvocations(in: text)

        // Defensive fallback: if slash-skill tokens were detected syntactically but none
        // resolved (e.g. a skill was just installed and we missed the dirty signal),
        // force-refresh once and retry resolution.
        if invocations.isEmpty {
            let syntacticTokens = Self.extractSlashSkillTokens(from: text)
            if !syntacticTokens.isEmpty {
                await refreshSkillCatalog(force: true, agentKind: agentKind)
                invocations = resolvedSlashSkillInvocations(in: text)
            }
        }

        guard invocations.count == 1, let invocation = invocations.first else {
            return text
        }
        guard let renderedBody = renderSlashSkillBody(for: invocation, sourceText: text) else {
            return text
        }
        return composeSlashSkillPromptBlock(
            definition: invocation.definition,
            renderedBody: renderedBody
        )
    }

    private func renderSlashSkillBody(
        for invocation: ResolvedSlashSkillInvocation,
        sourceText: String
    ) -> String? {
        let template = AgentWorkflowDefinition.stripYAMLFrontmatter(invocation.definition.template)
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else {
            return nil
        }

        let fullText = sourceText as NSString
        let argsText = fullText.substring(with: invocation.token.argumentsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedUserInstructions = renderSlashSkillUserInstructions(argsText)
        if trimmedTemplate.contains("$ARGUMENTS") {
            return trimmedTemplate.replacingOccurrences(of: "$ARGUMENTS", with: renderedUserInstructions)
        }
        guard !renderedUserInstructions.isEmpty else {
            return trimmedTemplate
        }
        return "\(trimmedTemplate)\n\n\(renderedUserInstructions)"
    }

    private func renderSlashSkillUserInstructions(_ argsText: String) -> String {
        let trimmedArgs = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArgs.isEmpty else {
            return ""
        }
        return """
        <user_instructions>
        \(trimmedArgs)
        </user_instructions>
        """
    }

    private func composeSlashSkillPromptBlock(
        definition: AgentSkillDefinition,
        renderedBody: String
    ) -> String {
        let promptContext = skillCatalog.promptContext(for: definition)
        let escapedName = Self.escapePromptXMLAttribute(definition.name)
        let escapedScope = Self.escapePromptXMLAttribute(promptContext.scopeLabel)
        let escapedSource = Self.escapePromptXMLAttribute(promptContext.sourceLabel)

        var sections = [
            """
            <selected_skill_context name="\(escapedName)" scope="\(escapedScope)" source="\(escapedSource)">
            The selected /\(definition.name) skill content is already included below.
            Treat any <user_instructions> block as the user's live instructions for this skill invocation.
            Do not re-read the skill file unless the user explicitly asks you to inspect or modify the skill itself.
            </selected_skill_context>
            """
        ]

        if let directoryTree = promptContext.directoryTree?.trimmingCharacters(in: .whitespacesAndNewlines), !directoryTree.isEmpty {
            sections.append(
                """
                <skill_directory_tree>
                \(directoryTree)
                </skill_directory_tree>
                """
            )
        }

        sections.append(renderedBody)
        return sections.joined(separator: "\n\n")
    }

    private static func escapePromptXMLAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @MainActor
    private func augmentUserMessageWithTaggedFileContents(
        _ text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> String {
        guard !text.contains("<file_contents>") else { return text }
        var orderedPaths: [String] = []
        var seen = Set<String>()
        for taggedPath in Self.extractTaggedPaths(from: text) {
            let normalized = Self.unescapeTaggedPath(taggedPath)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                orderedPaths.append(normalized)
            }
        }
        for attachment in taggedFileAttachments {
            let normalized = Self.unescapeTaggedPath(attachment.relativePath)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                orderedPaths.append(normalized)
            }
        }
        guard !orderedPaths.isEmpty else { return text }
        guard let xml = await fileContentsXMLForTaggedPaths(
            orderedPaths,
            tokenBudget: Self.taggedFileContentsTokenBudget,
            maxFiles: Self.taggedFileContentsMaxFiles,
            lookupContext: lookupContext
        ) else {
            return text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return xml }
        return "\(text)\n\n\(xml)"
    }

    // MARK: - Agent Run Lifecycle

    /// Start an agent run for the given tab.
    @discardableResult
    func startAgentRun(
        tabID: UUID,
        initialMessage: String,
        attachments: [AgentImageAttachment] = [],
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        codexFallbackContext: TabSession.CodexFallbackSubmissionContext? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        let session = session(for: tabID)
        let codexDispatchTicket = codexFallbackContext?.dispatchTicket
        if let codexDispatchTicket {
            guard await session.codexDispatchSerialGate.awaitTurn(codexDispatchTicket) else {
                return .cancelled
            }
        }
        defer {
            if let codexDispatchTicket {
                session.codexDispatchSerialGate.finish(codexDispatchTicket)
            }
        }
        guard AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: agentAvailabilityContext) else {
            if session.mcpFollowUpRunPending {
                session.mcpFollowUpRunPending = false
                handleObservedMCPStateChange(for: session)
            }
            return .failed(message: unavailableAgentMessage(for: session.selectedAgent))
        }
        defer {
            if session.mcpFollowUpRunPending {
                session.mcpFollowUpRunPending = false
                handleObservedMCPStateChange(for: session)
            }
        }
        guard ensureSessionBoundToTab(session) != nil else {
            return .failed(message: "The tab could not be bound to an agent session.")
        }
        await prepareSessionForRunStart(tabID: tabID, session: session)
        await prepareMCPWaitTrackingForRunStart(session: session)
        let augmentedInitialMessage = await augmentUserMessageForProviderSend(
            initialMessage,
            attachments: attachments,
            taggedFileAttachments: taggedFileAttachments,
            agent: session.selectedAgent,
            session: session
        )

        let initialMessageForRun = await buildInitialThreadMessageIfNeeded(
            tabID: tabID,
            session: session,
            initialMessage: augmentedInitialMessage
        )
        let preparedCodexFallbackContext = codexFallbackContext.map { context in
            TabSession.CodexFallbackSubmissionContext(
                queueID: context.queueID,
                providerText: initialMessageForRun,
                images: context.images,
                taggedFileAttachments: context.taggedFileAttachments,
                draftText: context.draftText,
                optimisticUserItemID: context.optimisticUserItemID,
                origin: context.origin,
                dispatchTicket: context.dispatchTicket
            )
        }

        return await runService.startRun(
            tabID: tabID,
            session: session,
            initialUserMessage: augmentedInitialMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            codexFallbackContext: preparedCodexFallbackContext
        )
    }

    private func buildHeadlessAgentMessage(
        session: TabSession,
        initialMessageForRun: String,
        runID: UUID,
        attachments: [AgentImageAttachment]
    ) -> AgentMessage {
        // Build initial message - for providers with resumable sessions, use --resume when available.
        let supportsSessionResume = session.selectedAgent.usesClaudeNativeRuntime || session.selectedAgent.acpProviderID != nil
        // Fresh handoff tabs already carry their continuity inside the staged
        // <forked_session> payload injected into the first user turn. Replaying
        // the migrated local transcript as <previous_conversation> would duplicate
        // that context for the model.
        let shouldBypassHistoryReplay = session.pendingHandoff.hasPayload
            || (supportsSessionResume && (session.providerSessionID != nil || !attachments.isEmpty))
        let fullMessage: String
        let resumeSessionID: String?

        if shouldBypassHistoryReplay {
            // Resumable providers handle conversation continuity natively.
            // Also keep attachment references at top-level (not wrapped) for image turns.
            fullMessage = initialMessageForRun
            resumeSessionID = session.providerSessionID
        } else {
            // Non-resumable agents: include conversation history in prompt.
            let conversationHistory = buildConversationHistory(for: session)
            fullMessage = conversationHistory.isEmpty
                ? initialMessageForRun
                : """
                <previous_conversation>
                \(conversationHistory)
                </previous_conversation>

                <current_instruction>
                \(initialMessageForRun)
                </current_instruction>
                """
            resumeSessionID = nil
        }

        // Create agent message with system prompt for interactive assistance
        let systemPrompt = SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
        return AgentMessage(systemPrompt: systemPrompt, userMessage: fullMessage, resumeSessionID: resumeSessionID)
    }

    private static let claudeReasoningStatusBufferCharacterLimit = 4000
    private static let claudeReasoningStatusPreviewCharacterLimit = 128
    private static let claudeReasoningStatusUpdateIntervalNanos: UInt64 = 120_000_000

    #if DEBUG
        private static func claudeReasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][ViewModel] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private static func claudeReasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private static func claudeReasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    private static func claudeReasoningStatusPreview(from rawBuffer: String) -> String? {
        let trimmed = rawBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = ReasoningTextFormatter.normalize(trimmed)
        let candidateLine = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
            ?? normalized
        let collapsed = candidateLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let cleaned = stripClaudeReasoningPreviewDecoration(collapsed)
        guard !cleaned.isEmpty else { return nil }
        return tailTruncatedOneLine(cleaned, limit: claudeReasoningStatusPreviewCharacterLimit)
    }

    private static func stripClaudeReasoningPreviewDecoration(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in ["- ", "* ", "• "] where value.hasPrefix(marker) {
            value.removeFirst(marker.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("**"), value.hasSuffix("**"), value.count > 4 {
            value.removeFirst(2)
            value.removeLast(2)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func tailTruncatedOneLine(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let suffixLimit = max(1, limit - 1)
        var suffix = String(text.suffix(suffixLimit))
        if let firstWhitespace = suffix.firstIndex(where: { $0.isWhitespace }),
           firstWhitespace != suffix.startIndex
        {
            suffix = String(suffix[suffix.index(after: firstWhitespace)...])
        }
        if suffix.count > suffixLimit {
            suffix = String(suffix.suffix(suffixLimit))
        }
        return "…" + suffix
    }

    private static func claudeDisplayableStatusText(_ raw: String?) -> String? {
        var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "Permission mode:", options: [.caseInsensitive]) {
            text = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix("—") || text.hasSuffix("-") {
                text.removeLast()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    private func setTransportRunningStatus(
        _ text: String?,
        session: TabSession,
        allowOverrideReasoning: Bool = false
    ) -> Bool {
        if session.runningStatusSource == .reasoning, !allowOverrideReasoning {
            return false
        }
        if allowOverrideReasoning {
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        }
        return session.setRunningStatus(text, source: .transport)
    }

    @discardableResult
    private func applyClaudeReasoningStatusDelta(_ delta: String, session: TabSession) -> Bool {
        guard ClaudeReasoningExtractionFeature.isEnabled else { return false }
        guard session.selectedAgent.usesClaudeNativeRuntime else {
            Self.claudeReasoningDebug("drop delta for non-Claude-native agent tab=\(session.tabID.uuidString) selectedAgent=\(session.selectedAgent.rawValue)")
            return false
        }
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else {
            Self.claudeReasoningDebug("drop empty reasoning delta tab=\(session.tabID.uuidString)")
            return false
        }
        Self.claudeReasoningDebug("apply delta tab=\(session.tabID.uuidString) deltaLen=\(delta.count) trimmedLen=\(trimmedDelta.count) snippet=\(Self.claudeReasoningDebugSnippet(delta)) statusBefore=\(session.runningStatusText ?? "nil") sourceBefore=\(String(describing: session.runningStatusSource))")
        session.claudeReasoningStatusBuffer = delta
        if session.claudeReasoningStatusBuffer.count > Self.claudeReasoningStatusBufferCharacterLimit {
            session.claudeReasoningStatusBuffer = String(session.claudeReasoningStatusBuffer.suffix(Self.claudeReasoningStatusBufferCharacterLimit))
            Self.claudeReasoningDebug("trimmed reasoning buffer tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count)")
        }
        guard let preview = Self.claudeReasoningStatusPreview(from: session.claudeReasoningStatusBuffer) else {
            Self.claudeReasoningDebug("no displayable preview tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count)")
            return false
        }
        Self.claudeReasoningDebug("pending preview tab=\(session.tabID.uuidString) preview=\(Self.claudeReasoningDebugSnippet(preview)) existingFlushTask=\(session.claudeReasoningStatusFlushTask != nil)")
        if session.runningStatusSource == .reasoning {
            session.claudeReasoningStatusPendingText = nil
            session.claudeReasoningStatusFlushTask?.cancel()
            session.claudeReasoningStatusFlushTask = nil
            let changed = session.setRunningStatus(preview, source: .reasoning)
            Self.claudeReasoningDebug("replace visible preview tab=\(session.tabID.uuidString) changed=\(changed) preview=\(Self.claudeReasoningDebugSnippet(preview))")
            if changed {
                requestUIRefresh(tabID: session.tabID)
            }
            return changed
        }
        session.claudeReasoningStatusPendingText = preview
        guard session.claudeReasoningStatusFlushTask == nil else { return false }
        session.claudeReasoningStatusFlushTask = Task { [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: Self.claudeReasoningStatusUpdateIntervalNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, let self, let session else { return }
                session.claudeReasoningStatusFlushTask = nil
                guard session.selectedAgent.usesClaudeNativeRuntime else {
                    Self.claudeReasoningDebug("flush dropped for non-Claude-native agent tab=\(session.tabID.uuidString) selectedAgent=\(session.selectedAgent.rawValue)")
                    return
                }
                guard let pendingText = session.claudeReasoningStatusPendingText else {
                    Self.claudeReasoningDebug("flush found no pending text tab=\(session.tabID.uuidString)")
                    return
                }
                session.claudeReasoningStatusPendingText = nil
                let changed = session.setRunningStatus(pendingText, source: .reasoning)
                Self.claudeReasoningDebug("flush preview tab=\(session.tabID.uuidString) changed=\(changed) pending=\(Self.claudeReasoningDebugSnippet(pendingText)) statusAfter=\(session.runningStatusText ?? "nil") sourceAfter=\(String(describing: session.runningStatusSource))")
                if changed {
                    self.requestUIRefresh(tabID: session.tabID)
                }
            }
        }
        return false
    }

    @discardableResult
    private func clearClaudeReasoningStatus(_ session: TabSession) -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
        let shouldLog = !session.claudeReasoningStatusBuffer.isEmpty
            || session.claudeReasoningStatusPendingText != nil
            || session.claudeReasoningStatusFlushTask != nil
            || session.runningStatusSource == .reasoning
        if shouldLog {
            Self.claudeReasoningDebug("clear status tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count) pending=\(session.claudeReasoningStatusPendingText ?? "nil") source=\(String(describing: session.runningStatusSource))")
        }
        let changed = session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        if shouldLog {
            Self.claudeReasoningDebug("clear status complete tab=\(session.tabID.uuidString) changed=\(changed) statusAfter=\(session.runningStatusText ?? "nil") sourceAfter=\(String(describing: session.runningStatusSource))")
        }
        return changed
    }

    #if DEBUG
        func test_applyClaudeReasoningStatusDelta(_ delta: String, session: TabSession) -> Bool {
            applyClaudeReasoningStatusDelta(delta, session: session)
        }

        func test_handleStreamResult(
            _ result: AIStreamResult,
            session: TabSession,
            runID: UUID,
            runAttemptID: UUID
        ) async {
            await handleStreamResult(result, session: session, runID: runID, runAttemptID: runAttemptID)
        }

        static func test_claudeReasoningStatusPreview(from rawBuffer: String) -> String? {
            claudeReasoningStatusPreview(from: rawBuffer)
        }
    #endif

    private func handleStreamResult(
        _ result: AIStreamResult,
        session: TabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async {
        if session.activeRunAttemptID != runAttemptID,
           let reroutedSession = sessions.values.first(where: {
               $0.runID == runID && $0.activeRunAttemptID == runAttemptID
           }),
           reroutedSession !== session
        {
            await handleStreamResult(
                result,
                session: reroutedSession,
                runID: runID,
                runAttemptID: runAttemptID
            )
            return
        }
        await MainActor.run {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID else { return }
            var shouldUpdateBindings = false
            switch result.type {
            case "content":
                // Normal content text
                guard let content = result.text, !content.isEmpty else { break }
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                enqueueAssistantDelta(content, session: session)

            case "final_content":
                // Final authoritative message content for the turn.
                guard let content = result.text else { break }
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                // Materialize any pending content delta first so we preserve ordering.
                flushPendingAssistantDelta(session)
                guard AgentDisplayableText.hasDisplayableBody(content) else { break }

                // Search backward for a trailing assistant bubble. It may not be the
                // very last item if system events (e.g. rate-limit telemetry) were
                // interleaved, which can prematurely finalize the streaming segment.
                // Walk past system items but stop at tool calls, user messages, etc.
                let tailAssistantIndex: Int? = {
                    if let streamingAssistantIndex = self.resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in: session) {
                        return streamingAssistantIndex
                    }
                    for i in session.items.indices.reversed() {
                        switch session.items[i].kind {
                        case .assistant:
                            return i
                        case .system:
                            continue
                        default:
                            return nil
                        }
                    }
                    return nil
                }()

                if let index = tailAssistantIndex {
                    var updated = session.items[index]
                    updated.text = content
                    updated.isStreaming = false
                    session.replaceItem(at: index, with: updated)
                } else {
                    let assistantItem = AgentChatItem.assistant(content, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(assistantItem)
                }
                shouldUpdateBindings = true

            case "reasoning":
                guard ClaudeReasoningExtractionFeature.isEnabled else { break }
                // Claude provider-internal reasoning/thinking traces update only the
                // transient running-status row. They are intentionally never added to
                // the persisted chat transcript.
                Self.claudeReasoningDebug("handleStreamResult reasoning tab=\(session.tabID.uuidString) hasReasoning=\(result.reasoning != nil) textLen=\(result.text?.count ?? 0) reasoningLen=\(result.reasoning?.count ?? 0) selectedAgent=\(session.selectedAgent.rawValue)")
                if session.selectedAgent.usesClaudeNativeRuntime,
                   let reasoning = result.reasoning ?? result.text
                {
                    shouldUpdateBindings = applyClaudeReasoningStatusDelta(reasoning, session: session) || shouldUpdateBindings
                } else {
                    Self.claudeReasoningDebug("reasoning result ignored tab=\(session.tabID.uuidString) usesClaudeNative=\(session.selectedAgent.usesClaudeNativeRuntime)")
                }

            case "tool_call":
                // Structured tool call event with args. Keep any Claude reasoning
                // status visible through tool execution; it is replaced by the next
                // reasoning update or cleared when assistant content starts.
                guard let toolName = result.toolName else { break }
                let argsJSON = result.toolArgsJSON ?? result.toolArgs
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                endActiveReasoningSegment(session)
                // Route provider-specific tool events through dedicated handlers.
                if runService.handleProviderToolStreamEvent(result, session: session) {
                    shouldUpdateBindings = true
                    break
                }
                if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    break
                }
                addToolInputTokens(argsJSON, for: session)
                guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                if AgentToolTrackingSupport.shouldAutoCompleteProviderToolCall(
                    for: session,
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    let syntheticResultJSON = AgentToolTrackingSupport.syntheticCompletedToolResultJSON(
                        note: "Provider emitted tool_call without a matching tool_result event."
                    )
                    var toolResultItem = AgentChatItem.toolResult(
                        name: toolName,
                        invocationID: result.toolInvocationID,
                        resultJSON: syntheticResultJSON,
                        isError: false,
                        sequenceIndex: session.nextSequenceIndex
                    )
                    toolResultItem.toolArgsJSON = argsJSON
                    session.appendItem(toolResultItem)
                } else {
                    let toolItem = AgentChatItem.toolCall(name: toolName, invocationID: result.toolInvocationID, argsJSON: argsJSON, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(toolItem)
                }
                shouldUpdateBindings = true

            case "tool_result":
                // Structured tool result event with output. Preserve Claude reasoning
                // status across tool results.
                guard let toolName = result.toolName else { break }
                let outputJSON = result.toolResultJSON ?? result.toolOutput ?? ""
                let argsJSON = result.toolArgsJSON ?? result.toolArgs
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                endActiveReasoningSegment(session)
                // Route provider-specific tool events through dedicated handlers.
                if runService.handleProviderToolStreamEvent(result, session: session) {
                    shouldUpdateBindings = true
                    break
                }
                if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    break
                }
                addToolOutputTokens(outputJSON, for: session)
                guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                let invocationID = result.toolInvocationID
                if let invocationID,
                   let index = session.items.lastIndex(where: { $0.toolInvocationID == invocationID })
                {
                    var updated = session.items[index]
                    updated.kind = .toolResult
                    updated.toolResultJSON = outputJSON
                    updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                    updated.toolIsError = result.toolIsError
                    updated.text = outputJSON
                    session.replaceItem(at: index, with: updated)
                } else if let index = session.items.lastIndex(where: { $0.kind == .toolCall && $0.toolName == toolName }) {
                    var updated = session.items[index]
                    updated.kind = .toolResult
                    updated.toolInvocationID = invocationID ?? updated.toolInvocationID
                    updated.toolResultJSON = outputJSON
                    updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                    updated.toolIsError = result.toolIsError
                    updated.text = outputJSON
                    session.replaceItem(at: index, with: updated)
                } else {
                    let toolResultItem = AgentChatItem.toolResult(
                        name: toolName,
                        invocationID: invocationID,
                        resultJSON: outputJSON,
                        isError: result.toolIsError,
                        sequenceIndex: session.nextSequenceIndex
                    )
                    session.appendItem(toolResultItem)
                }
                codexCoordinator.reconcileCodexCommandExecutionRunningUpdate(
                    toolName: toolName,
                    argsJSON: argsJSON,
                    resultJSON: outputJSON,
                    isError: result.toolIsError,
                    session: session
                )
                shouldUpdateBindings = true

            case "event":
                // Legacy tool usage event (e.g., "Using tool: read_file") - fallback for compatibility
                if let eventText = result.text, eventText.hasPrefix("Using tool: ") {
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    endActiveReasoningSegment(session)
                    let toolName = String(eventText.dropFirst("Using tool: ".count))
                    if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(toolName: toolName, invocationID: nil) {
                        break
                    }
                    guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                    let toolItem = AgentChatItem.toolCall(name: toolName, argsJSON: nil, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(toolItem)
                    shouldUpdateBindings = true
                }

            case "tool_progress":
                if let progress = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !progress.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(progress, session: session) || shouldUpdateBindings
                }

            case "status":
                nonCodexContextUsageEstimator(for: session.selectedAgent)?.ingestStatusSignal(result.text, session: session)
                let statusText = session.selectedAgent.usesClaudeNativeRuntime
                    ? Self.claudeDisplayableStatusText(result.text)
                    : result.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let statusText, !statusText.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(statusText, session: session) || shouldUpdateBindings
                } else if session.selectedAgent.usesClaudeNativeRuntime,
                          result.text?.range(of: "Permission mode:", options: [.caseInsensitive]) != nil,
                          session.runningStatusSource != .reasoning
                {
                    shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                }

            case "usage":
                if let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent),
                   estimator.ingestUsageSignal(
                       promptTokens: result.promptTokens,
                       completionTokens: result.completionTokens,
                       contextUsedTokens: result.contextUsedTokens,
                       modelContextWindow: result.modelContextWindow,
                       session: session
                   ) != nil
                {
                    shouldUpdateBindings = true
                }

            case "auth_status":
                if let status = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(status, session: session, allowOverrideReasoning: true) || shouldUpdateBindings
                    let systemItem = AgentChatItem.system(status, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(systemItem)
                    shouldUpdateBindings = true
                }

            case "session_state_changed":
                // Claude Code lifecycle event — update run-state UI only, no transcript rows.
                let state = result.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                switch state {
                case "idle":
                    shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                    shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                case "running":
                    // Keep active reasoning previews; otherwise show the generic fallback.
                    if session.runningStatusText == nil {
                        shouldUpdateBindings = setTransportRunningStatus("Thinking…", session: session) || shouldUpdateBindings
                    }
                default:
                    if !state.isEmpty {
                        // Humanize: replace underscores with spaces, capitalize words
                        let humanized = state.replacingOccurrences(of: "_", with: " ").capitalized
                        shouldUpdateBindings = setTransportRunningStatus(humanized, session: session) || shouldUpdateBindings
                    }
                }

            case "task_progress":
                // Claude Code task progress — update running status text, no transcript rows.
                // Do not displace a visible Claude reasoning preview.
                if let progressText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !progressText.isEmpty
                {
                    shouldUpdateBindings = setTransportRunningStatus(progressText, session: session) || shouldUpdateBindings
                }

            case "system":
                // System messages - skip lifecycle messages that don't need UI display.
                // Preserve Claude reasoning previews until the next reasoning or assistant message.
                if let text = result.text, !text.isEmpty {
                    nonCodexContextUsageEstimator(for: session.selectedAgent)?.ingestSystemSignal(text, session: session)
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    // Filter out agent lifecycle messages that shouldn't appear in chat
                    let skipMessages = ["Agent initialized", "Agent completed", "Agent cancelled"]
                    guard !skipMessages.contains(text) else { break }
                    let systemItem = AgentChatItem.system(text, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(systemItem)
                    shouldUpdateBindings = true
                }

            case "error":
                // Error messages. Preserve Claude reasoning previews until terminal
                // finalization clears run state.
                if let text = result.text, !text.isEmpty {
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    let errorItem = AgentChatItem.error(text, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(errorItem)
                    shouldUpdateBindings = true
                }

            case "message_stop":
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                // Stream completed - assistant streaming segments already finalized above.

                // Store provider session ID for resumption (native Claude or ACP runtimes).
                if let sessionID = result.providerSessionID,
                   session.selectedAgent.usesClaudeNativeRuntime || session.selectedAgent.acpProviderID != nil
                {
                    session.providerSessionID = sessionID
                    session.isDirty = true
                    self.scheduleSave(for: session.tabID)
                }

                // Track per-turn token usage for resumable non-Codex agents.
                if let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) {
                    _ = estimator.ingestTurnFinalizationSignal(
                        contextUsedTokens: result.contextUsedTokens,
                        modelContextWindow: result.modelContextWindow,
                        session: session
                    )
                    finalizeNonCodexTurnUsageIfNeeded(
                        for: session,
                        promptTokens: result.promptTokens,
                        completionTokens: result.completionTokens,
                        contextUsedTokens: result.contextUsedTokens
                    )
                }
                shouldUpdateBindings = true

            case AIStreamResult.lifecycleType:
                // Lifecycle events (init/complete/cancel) are not rendered in chat
                // They're handled via session.runState for UI state management
                break

            default:
                break
            }

            if shouldUpdateBindings {
                requestUIRefresh(tabID: session.tabID)
            }
        }
    }

    // MARK: - Tool Event Filtering

    static func isRepoPromptTool(_ name: String) -> Bool {
        MCPIntegrationHelper.isRepoPromptToolName(name)
    }

    static func isExplicitRepoPromptTool(_ name: String) -> Bool {
        MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(name)
    }

    func finalizeStreamingItems(in session: TabSession) {
        session.mutateItemsBatch(touchActivity: false) { items in
            for index in items.indices where items[index].isStreaming {
                items[index].isStreaming = false
            }
        }
    }

    @discardableResult
    private func finalizePendingToolCalls(
        in session: TabSession,
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false
    ) -> Int {
        finalizePendingToolCalls(
            in: session,
            terminalState: terminalState,
            includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
            maxSequenceIndexExclusive: nil
        )
    }

    @discardableResult
    private func finalizePendingToolCalls(
        in session: TabSession,
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false,
        maxSequenceIndexExclusive: Int?
    ) -> Int {
        var finalizedCount = 0
        session.mutateItemsBatch(touchActivity: false) { items in
            finalizedCount = Self.finalizePendingToolCallsInItems(
                &items,
                terminalState: terminalState,
                includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
                maxSequenceIndexExclusive: maxSequenceIndexExclusive
            )
        }
        if finalizedCount > 0 {
            refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
        }
        #if DEBUG
            if includeExplicitRepoPromptToolCalls || finalizedCount > 0 {
                let tail = session.items.suffix(6).map { item in
                    let tool = item.toolName ?? "-"
                    return "\(item.sequenceIndex):\(item.kind.rawValue):\(tool)"
                }.joined(separator: " | ")
                print("[ACPAgentRunToolTracking] finalizePendingToolCalls session=\(session.activeAgentSessionID?.uuidString ?? "nil") agent=\(session.selectedAgent.rawValue) state=\(terminalState.rawValue) includeExplicit=\(includeExplicitRepoPromptToolCalls) finalized=\(finalizedCount) tail=\(tail)")
            }
        #endif
        return finalizedCount
    }

    @discardableResult
    private nonisolated static func finalizePendingToolCallsInItems(
        _ items: inout [AgentChatItem],
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false,
        maxSequenceIndexExclusive: Int?
    ) -> Int {
        AgentTranscriptIO.finalizePendingToolCalls(
            in: &items,
            terminalState: terminalState,
            includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
            maxSequenceIndexExclusive: maxSequenceIndexExclusive,
            nonToolBoundary: pendingToolFinalizationNonToolBoundary
        )
    }

    func enqueueAssistantDelta(_ delta: String, session: TabSession) {
        session.pendingAssistantDelta += delta
        if session.assistantDeltaFlushTask == nil {
            session.assistantDeltaTaskGeneration &+= 1
            let taskGeneration = session.assistantDeltaTaskGeneration
            session.assistantDeltaFlushTask = Task { [weak self, weak session] in
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                await MainActor.run {
                    guard let self, let session,
                          session.assistantDeltaTaskGeneration == taskGeneration
                    else { return }
                    self.flushPendingAssistantDelta(session)
                }
            }
        }
    }

    func clearPendingAssistantDelta(_ session: TabSession) {
        session.pendingAssistantDelta = ""
        session.assistantDeltaTaskGeneration &+= 1
        session.assistantDeltaFlushTask?.cancel()
        session.assistantDeltaFlushTask = nil
    }

    func flushPendingAssistantDelta(_ session: TabSession) {
        guard !session.pendingAssistantDelta.isEmpty else { return }
        let delta = session.pendingAssistantDelta
        clearPendingAssistantDelta(session)
        if applyAssistantDelta(delta, session: session) {
            session.assistantDeltaFlushGeneration &+= 1
            requestAssistantPresentationRefresh(
                session: session,
                sourceItemsRevision: session.sourceItemsRevision,
                flushGeneration: session.assistantDeltaFlushGeneration
            )
        }
    }

    private func resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in session: TabSession) -> Int? {
        for index in session.items.indices.reversed() {
            let item = session.items[index]
            if item.kind == .assistant, item.isStreaming {
                return index
            }
            guard item.kind == .user else {
                return nil
            }
        }
        return nil
    }

    @discardableResult
    func applyAssistantDelta(_ delta: String, session: TabSession) -> Bool {
        if let streamingAssistantIndex = resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in: session) {
            session.mutateItem(at: streamingAssistantIndex) { item in
                item.text += delta
            }
            return true
        }

        guard AgentDisplayableText.hasDisplayableBody(delta) else {
            return false
        }
        var assistantItem = AgentChatItem.assistant(delta, sequenceIndex: session.nextSequenceIndex)
        assistantItem.isStreaming = true
        session.appendItem(assistantItem)
        return true
    }

    func endActiveAssistantSegment(_ session: TabSession) {
        session.mutateItemsBatch(touchActivity: false) { items in
            for index in items.indices where items[index].kind == .assistant && items[index].isStreaming {
                items[index].isStreaming = false
            }
        }
    }

    func applyReasoningDelta(_ delta: String, groupID: String?, session: TabSession) {
        if let groupID, let localID = session.reasoningItemIDsByGroupID[groupID],
           let index = session.items.firstIndex(where: { $0.id == localID })
        {
            session.mutateItem(at: index) { item in
                item.text += delta
            }
            session.activeReasoningItemID = localID
        } else if let activeID = session.activeReasoningItemID,
                  groupID == nil,
                  let index = session.items.firstIndex(where: { $0.id == activeID })
        {
            session.mutateItem(at: index) { item in
                item.text += delta
            }
        } else {
            var thinkingItem = AgentChatItem.thinking(delta, sequenceIndex: session.nextSequenceIndex)
            thinkingItem.isStreaming = true
            session.appendItem(thinkingItem)
            session.activeReasoningItemID = thinkingItem.id
            if let groupID {
                session.reasoningItemIDsByGroupID[groupID] = thinkingItem.id
            }
        }
    }

    func endActiveReasoningSegment(_ session: TabSession) {
        let activeIDs = Set(session.reasoningItemIDsByGroupID.values)
        let allIDs = session.activeReasoningItemID.map { activeIDs.union([$0]) } ?? activeIDs
        session.mutateItemsBatch(touchActivity: false) { items in
            for itemID in allIDs {
                if let index = items.firstIndex(where: { $0.id == itemID }),
                   items[index].kind == .thinking,
                   items[index].isStreaming
                {
                    items[index].isStreaming = false
                }
            }
        }
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
    }

    func makeRunCancelTarget(
        tabID: UUID,
        session: TabSession,
        expectedPendingUserInputRequestID: CodexAppServerRequestID? = nil
    ) -> AgentRunCancelTarget {
        AgentRunCancelTarget(
            tabID: tabID,
            expectedRunID: session.runID,
            expectedActiveAgentSessionID: session.activeAgentSessionID,
            expectedRunAttemptID: session.activeRunAttemptID,
            expectedPendingUserInputRequestID: expectedPendingUserInputRequestID
        )
    }

    /// Cancel the agent run for a tab.
    ///
    /// Terminal publication and synchronous provider detachment are the default return point.
    /// Callers that destroy provider-owned infrastructure can explicitly await terminal teardown.
    func cancelAgentRun(
        tabID: UUID,
        completion: AgentModeRunService.CancellationCompletion = .terminalPublished
    ) async {
        guard let session = sessions[tabID] else { return }
        cancelPendingInstruction(for: session)
        await runService.cancelRun(tabID: tabID, session: session, completion: completion)
    }

    /// Cancel a render-time run target, refusing if the live tab no longer matches that target.
    /// - Returns: `true` when cancellation was routed to the guarded target; `false` when refused.
    @discardableResult
    func cancelAgentRun(
        target: AgentRunCancelTarget,
        completion: AgentModeRunService.CancellationCompletion = .terminalPublished
    ) async -> Bool {
        guard let session = sessions[target.tabID] else {
            logRejectedCancelTarget(target, session: nil, reason: "missing_session")
            resyncAfterRejectedCancelTarget(target)
            return false
        }
        if let rejectionReason = cancelTargetRejectionReason(target, session: session) {
            logRejectedCancelTarget(target, session: session, reason: rejectionReason)
            resyncAfterRejectedCancelTarget(target)
            return false
        }
        cancelPendingInstruction(for: session)
        await runService.cancelRun(tabID: target.tabID, session: session, completion: completion)
        return true
    }

    private func cancelTargetRejectionReason(_ target: AgentRunCancelTarget, session: TabSession) -> String? {
        guard session.runState.isActive else { return "inactive_run" }
        guard let expectedRunID = target.expectedRunID else { return "missing_expected_run_id" }
        if session.runID != expectedRunID {
            return "run_id_mismatch"
        }
        if session.activeAgentSessionID != target.expectedActiveAgentSessionID {
            return "agent_session_id_mismatch"
        }
        if session.activeRunAttemptID != target.expectedRunAttemptID {
            return "run_attempt_id_mismatch"
        }
        if let expectedPendingUserInputRequestID = target.expectedPendingUserInputRequestID,
           session.pendingUserInputRequest?.requestID != expectedPendingUserInputRequestID
        {
            return "pending_user_input_request_mismatch"
        }
        return nil
    }

    private func logRejectedCancelTarget(_ target: AgentRunCancelTarget, session: TabSession?, reason: String) {
        Self.steeringDebugLog(
            "[AgentCancelTarget] rejected reason=\(reason) targetTab=\(target.tabID) expectedRun=\(target.expectedRunID?.uuidString ?? "nil") liveRun=\(session?.runID?.uuidString ?? "nil")"
        )
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "agent.cancelTarget.rejected",
                tabID: target.tabID,
                fields: [
                    "reason": reason,
                    "expectedRunID": AgentModePerfDiagnostics.shortID(target.expectedRunID),
                    "liveRunID": AgentModePerfDiagnostics.shortID(session?.runID),
                    "expectedAgentSessionID": AgentModePerfDiagnostics.shortID(target.expectedActiveAgentSessionID),
                    "liveAgentSessionID": AgentModePerfDiagnostics.shortID(session?.activeAgentSessionID),
                    "expectedRunAttemptID": AgentModePerfDiagnostics.shortID(target.expectedRunAttemptID),
                    "liveRunAttemptID": AgentModePerfDiagnostics.shortID(session?.activeRunAttemptID),
                    "expectedPendingInputRequestID": target.expectedPendingUserInputRequestID?.displayValue ?? "nil",
                    "livePendingInputRequestID": session?.pendingUserInputRequest?.requestID.displayValue ?? "nil",
                    "liveRunState": session?.runState.rawValue ?? "missing"
                ]
            )
        #endif
    }

    private func resyncAfterRejectedCancelTarget(_ target: AgentRunCancelTarget) {
        if let currentTabID, currentTabID == target.tabID {
            syncActiveUIState(tabID: currentTabID, invalidation: [.composer, .runInteraction])
        }
        requestUIRefresh(tabID: target.tabID, urgent: true)
        if let currentTabID, currentTabID != target.tabID {
            requestUIRefresh(tabID: currentTabID, urgent: true)
        }
    }

    func claimComposerSubmitAttempt(_ attempt: AgentComposerSubmitAttempt) -> AgentComposerSubmitClaimResult {
        claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: true)
    }

    private func claimComposerSubmitAttempt(
        _ attempt: AgentComposerSubmitAttempt,
        requireActiveTabOwnership: Bool
    ) -> AgentComposerSubmitClaimResult {
        let target = attempt.target
        if requireActiveTabOwnership, currentTabID != target.tabID {
            let rejection = AgentComposerSubmitClaimRejection.targetRejected(reason: "inactive_composer_tab")
            logRejectedSubmitTarget(
                target,
                session: sessions[target.tabID],
                reason: rejection.diagnosticReason,
                attempt: attempt
            )
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        guard let session = sessions[target.tabID] else {
            let rejection = AgentComposerSubmitClaimRejection.missingSession
            logRejectedSubmitTarget(target, session: nil, reason: rejection.diagnosticReason, attempt: attempt)
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        guard ObjectIdentifier(session) == attempt.sourceTabSessionIdentity else {
            let rejection = AgentComposerSubmitClaimRejection.sourceSessionIdentityMismatch
            logRejectedSubmitTarget(target, session: session, reason: rejection.diagnosticReason, attempt: attempt)
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        if let activeAttempt = session.activeComposerSubmitAttempt {
            let rejection = AgentComposerSubmitClaimRejection.activeAttemptExists(activeAttemptID: activeAttempt.id)
            logRejectedSubmitTarget(
                target,
                session: session,
                reason: rejection.diagnosticReason,
                attempt: attempt,
                activeAttempt: activeAttempt
            )
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        if let rejectionReason = submitTargetRejectionReason(target, session: session) {
            let rejection = AgentComposerSubmitClaimRejection.targetRejected(reason: rejectionReason)
            logRejectedSubmitTarget(target, session: session, reason: rejectionReason, attempt: attempt)
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        if session.isPreparingInitialWorktree {
            let rejection = AgentComposerSubmitClaimRejection.initialWorktreePreparationInProgress
            logRejectedSubmitTarget(target, session: session, reason: rejection.diagnosticReason, attempt: attempt)
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }
        if session.isChangingExecutionLocation {
            let rejection = AgentComposerSubmitClaimRejection.executionLocationChangeInProgress
            logRejectedSubmitTarget(target, session: session, reason: rejection.diagnosticReason, attempt: attempt)
            resyncAfterRejectedSubmitTarget(target)
            return .rejected(rejection)
        }

        session.activeComposerSubmitAttempt = attempt
        session.composerSubmissionToken = UUID()
        let claim = AgentComposerSubmitClaim(
            attempt: attempt,
            sourceSession: session,
            draftMutationGeneration: session.draftMutationGeneration
        )
        if currentTabID == target.tabID {
            syncComposerUIState(tabID: target.tabID)
        }
        requestUIRefresh(tabID: target.tabID, urgent: true)
        logComposerSubmitClaimAccepted(claim)
        return .claimed(claim)
    }

    private func composerSubmitClaimIsCurrent(_ claim: AgentComposerSubmitClaim) -> Bool {
        let attempt = claim.attempt
        return ObjectIdentifier(claim.sourceSession) == attempt.sourceTabSessionIdentity
            && sessions[attempt.sourceTabID] === claim.sourceSession
            && claim.sourceSession.activeComposerSubmitAttempt?.id == attempt.id
    }

    @discardableResult
    func releaseComposerSubmitClaim(_ claim: AgentComposerSubmitClaim) -> Bool {
        let attempt = claim.attempt
        let sourceSession = claim.sourceSession
        guard ObjectIdentifier(sourceSession) == attempt.sourceTabSessionIdentity,
              sourceSession.activeComposerSubmitAttempt?.id == attempt.id
        else {
            logComposerSubmitClaimRelease(claim, accepted: false)
            return false
        }

        sourceSession.activeComposerSubmitAttempt = nil
        if sessions[attempt.sourceTabID] === sourceSession,
           currentTabID == attempt.sourceTabID
        {
            syncComposerUIState(tabID: attempt.sourceTabID)
        }
        requestUIRefresh(tabID: attempt.sourceTabID, urgent: true)
        logComposerSubmitClaimRelease(claim, accepted: true)
        return true
    }

    private func clearComposerDraftIfUnchanged(for claim: AgentComposerSubmitClaim) {
        let attempt = claim.attempt
        let session = claim.sourceSession
        guard ObjectIdentifier(session) == attempt.sourceTabSessionIdentity,
              session.draftMutationGeneration == claim.draftMutationGeneration,
              session.draftText == attempt.rawDraftSnapshot
        else { return }
        storeDraftText(for: attempt.sourceTabID, "")
    }

    private func submitTargetRejectionReason(
        _ target: AgentComposerSubmitTarget,
        session: TabSession?,
        validateSubmissionToken: Bool = true
    ) -> String? {
        let liveHasLinkedSession = hasLinkedAgentSession(for: target.tabID)
        let liveSourceAgentSessionID = composerSourceAgentSessionID(tabID: target.tabID, session: session)
        let liveRunState = session?.runState ?? .idle
        let liveRunID = session?.runID
        let liveRunAttemptID = session?.activeRunAttemptID
        let liveInitialStartLocation = initialStartLocationProps(tabID: target.tabID)?.selection

        if let session,
           ObjectIdentifier(session) != target.expectedSourceTabSessionIdentity
        {
            return "source_session_identity_mismatch"
        }
        if validateSubmissionToken, session?.composerSubmissionToken != target.expectedSubmissionToken {
            return "submission_token_mismatch"
        }

        switch target.route {
        case .existingAgentSession:
            guard liveHasLinkedSession else { return "linked_state_mismatch" }
            guard let expectedSourceAgentSessionID = target.expectedSourceAgentSessionID else {
                return "missing_expected_agent_session_id"
            }
            guard liveSourceAgentSessionID == expectedSourceAgentSessionID else {
                return "agent_session_id_mismatch"
            }
            guard liveInitialStartLocation == target.expectedInitialStartLocation else {
                return "initial_start_location_mismatch"
            }
            return nil
        case .createAgentSessionFromSourceTab:
            guard !liveHasLinkedSession else { return "linked_state_mismatch" }
            guard liveSourceAgentSessionID == target.expectedSourceAgentSessionID else {
                return "agent_session_id_mismatch"
            }
            guard liveRunState == target.expectedRunState else {
                return "run_state_mismatch"
            }
            if liveRunState.isActive, target.expectedRunID == nil {
                return "missing_expected_run_id"
            }
            guard liveRunID == target.expectedRunID else {
                return "run_id_mismatch"
            }
            guard liveRunAttemptID == target.expectedRunAttemptID else {
                return "run_attempt_id_mismatch"
            }
            guard liveInitialStartLocation == target.expectedInitialStartLocation else {
                return "initial_start_location_mismatch"
            }
            if liveSourceAgentSessionID != nil || liveRunState.isActive || liveRunID != nil || liveRunAttemptID != nil {
                return "unlinked_source_has_run_identity"
            }
            return nil
        }
    }

    private func logRejectedSubmitTarget(
        _ target: AgentComposerSubmitTarget,
        session: TabSession?,
        reason: String,
        attempt: AgentComposerSubmitAttempt? = nil,
        activeAttempt: AgentComposerSubmitAttempt? = nil
    ) {
        let liveSourceAgentSessionID = composerSourceAgentSessionID(tabID: target.tabID, session: session)
        let reportedAttempt = attempt ?? session?.activeComposerSubmitAttempt
        let reportedActiveAttempt = activeAttempt ?? session?.activeComposerSubmitAttempt
        Self.steeringDebugLog(
            "[AgentSubmitTarget] rejected reason=\(reason) attempt=\(reportedAttempt?.id.uuidString ?? "nil") activeClaim=\(reportedActiveAttempt?.id.uuidString ?? "nil") route=\(target.route.rawValue) targetTab=\(target.tabID) expectedRun=\(target.expectedRunID?.uuidString ?? "nil") liveRun=\(session?.runID?.uuidString ?? "nil")"
        )
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "agent.submitTarget.rejected",
                tabID: target.tabID,
                fields: [
                    "reason": reason,
                    "attemptID": AgentModePerfDiagnostics.shortID(reportedAttempt?.id),
                    "activeClaimID": AgentModePerfDiagnostics.shortID(reportedActiveAttempt?.id),
                    "route": target.route.rawValue,
                    "targetTabID": AgentModePerfDiagnostics.shortID(target.tabID),
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "expectedSourceTabSessionIdentity": String(describing: target.expectedSourceTabSessionIdentity),
                    "liveSourceTabSessionIdentity": session.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                    "expectedSourceAgentSessionID": AgentModePerfDiagnostics.shortID(target.expectedSourceAgentSessionID),
                    "liveSourceAgentSessionID": AgentModePerfDiagnostics.shortID(liveSourceAgentSessionID),
                    "expectedPersistentBindingSessionID": AgentModePerfDiagnostics.shortID(target.expectedPersistentBindingIdentity?.sessionID),
                    "livePersistentBindingSessionID": AgentModePerfDiagnostics.shortID(session?.persistentSessionBindingIdentity?.sessionID),
                    "expectedPersistentBindingGeneration": AgentModePerfDiagnostics.shortID(target.expectedPersistentBindingIdentity?.generation),
                    "livePersistentBindingGeneration": AgentModePerfDiagnostics.shortID(session?.persistentSessionBindingIdentity?.generation),
                    "expectedBindingTransitionGeneration": String(target.expectedBindingTransitionGeneration),
                    "liveBindingTransitionGeneration": session.map { String($0.bindingTransitionGeneration) } ?? "nil",
                    "liveBindingTransitionInProgress": String(session?.bindingTransitionInProgress ?? false),
                    "expectedRunState": target.expectedRunState.rawValue,
                    "liveRunState": session?.runState.rawValue ?? "idle",
                    "expectedRunID": AgentModePerfDiagnostics.shortID(target.expectedRunID),
                    "liveRunID": AgentModePerfDiagnostics.shortID(session?.runID),
                    "expectedRunAttemptID": AgentModePerfDiagnostics.shortID(target.expectedRunAttemptID),
                    "liveRunAttemptID": AgentModePerfDiagnostics.shortID(session?.activeRunAttemptID),
                    "expectedSubmissionToken": AgentModePerfDiagnostics.shortID(target.expectedSubmissionToken),
                    "liveSubmissionToken": AgentModePerfDiagnostics.shortID(session?.composerSubmissionToken)
                ]
            )
        #endif
    }

    private func logComposerSubmitClaimAccepted(_ claim: AgentComposerSubmitClaim) {
        let attempt = claim.attempt
        Self.steeringDebugLog(
            "[AgentSubmitClaim] accepted attempt=\(attempt.id) targetTab=\(attempt.sourceTabID) token=\(attempt.capturedSubmissionToken)"
        )
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "agent.submitClaim.accepted",
                tabID: attempt.sourceTabID,
                fields: [
                    "attemptID": AgentModePerfDiagnostics.shortID(attempt.id),
                    "sourceTabSessionIdentity": String(describing: attempt.sourceTabSessionIdentity),
                    "capturedSubmissionToken": AgentModePerfDiagnostics.shortID(attempt.capturedSubmissionToken),
                    "liveSubmissionToken": AgentModePerfDiagnostics.shortID(claim.sourceSession.composerSubmissionToken),
                    "inputRevision": String(attempt.inputRevision),
                    "persistentBindingSessionID": AgentModePerfDiagnostics.shortID(claim.sourceSession.persistentSessionBindingIdentity?.sessionID),
                    "persistentBindingGeneration": AgentModePerfDiagnostics.shortID(claim.sourceSession.persistentSessionBindingIdentity?.generation),
                    "bindingTransitionGeneration": String(claim.sourceSession.bindingTransitionGeneration),
                    "composerTargetPublishedNil": String(currentTabID != attempt.sourceTabID || ui.composer.props.submitTarget == nil)
                ]
            )
        #endif
    }

    private func logComposerSubmitClaimRelease(_ claim: AgentComposerSubmitClaim, accepted: Bool) {
        let attempt = claim.attempt
        Self.steeringDebugLog(
            "[AgentSubmitClaim] release accepted=\(accepted) attempt=\(attempt.id) targetTab=\(attempt.sourceTabID) activeClaim=\(claim.sourceSession.activeComposerSubmitAttempt?.id.uuidString ?? "nil")"
        )
        #if DEBUG
            AgentModePerfDiagnostics.event(
                accepted ? "agent.submitClaim.released" : "agent.submitClaim.releaseSkipped",
                tabID: attempt.sourceTabID,
                fields: [
                    "attemptID": AgentModePerfDiagnostics.shortID(attempt.id),
                    "activeClaimID": AgentModePerfDiagnostics.shortID(claim.sourceSession.activeComposerSubmitAttempt?.id),
                    "sourceTabSessionIdentity": String(describing: attempt.sourceTabSessionIdentity),
                    "liveSourceTabSessionIdentity": String(describing: ObjectIdentifier(claim.sourceSession)),
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID)
                ]
            )
        #endif
    }

    private func resyncAfterRejectedSubmitTarget(_ target: AgentComposerSubmitTarget) {
        if let currentTabID {
            syncActiveUIState(tabID: currentTabID, invalidation: [.composer, .runInteraction])
        }
        if currentTabID != target.tabID {
            requestUIRefresh(tabID: target.tabID, urgent: true)
        }
    }

    /// Cancel all active MCP tool executions for a given runID.
    @discardableResult
    func cancelActiveToolsForRun(runID: UUID, reason: String? = nil) -> Int {
        mcpRunToolCanceller(runID, reason)
    }

    // MARK: - Share Thoughts (MCP Tool Support)

    /// Share agent thoughts/reasoning with the user (called by MCP tools)
    /// Adds a thinking-style message to the target tab's chat transcript.
    /// Falls back to the active tab when no explicit tab ID is provided.
    func shareThoughts(_ thoughts: String, title: String? = nil, tabID: UUID? = nil) {
        guard let resolvedTabID = tabID ?? currentTabID else { return }
        let session = session(for: resolvedTabID)

        let displayText = if let title, !title.isEmpty {
            "**\(title)**\n\n\(thoughts)"
        } else {
            thoughts
        }

        let thinkingItem = AgentChatItem.thinking(displayText, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(thinkingItem)
        updateBindingsFromSession(session)
        scheduleSave(for: resolvedTabID)
    }

    // MARK: - Wait for Instruction (MCP Tool Support)

    static func shouldHideAgentToolFromTranscript(_ name: String?) -> Bool {
        AgentTranscriptIO.shouldHideToolFromTranscript(name)
    }

    /// Wait for the user to provide the next instruction (called by MCP tools)
    func waitForNextUserInstruction(
        tabID: UUID,
        prompt: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> UserInstructionResponse {
        // Ensure session exists (creates if needed, loads persisted state)
        let session = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)

        if session.instructionContinuation != nil || session.instructionTimeoutTask != nil {
            cancelPendingInstruction(for: session)
        }

        // Check for queued instructions first
        if !session.pendingInstructions.isEmpty {
            let queuedText = session.pendingInstructions.removeFirst()
            let text = await augmentUserMessageForProviderSend(
                queuedText,
                agent: session.selectedAgent,
                session: session
            )
            return UserInstructionResponse(text: text, timedOut: false, elapsedSeconds: 0)
        }

        // Set waiting state
        session.waitingPrompt = prompt
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        session.runState = .waitingForUser
        let waitID = UUID()
        session.instructionWaitID = waitID
        updateBindingsFromSession(session)

        let waitMessage = (prompt?.isEmpty == false) ? prompt! : "What would you like me to do next?"
        let inlineItem = AgentChatItem.assistantInline(waitMessage, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(inlineItem)
        updateBindingsFromSession(session)
        notifyAgentWaitingForUser(for: tabID, prompt: waitMessage)

        return try await withCheckedThrowingContinuation { continuation in
            session.instructionContinuation = continuation

            // Setup timeout if specified
            if let timeout = timeoutSeconds {
                session.instructionTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard session.instructionWaitID == waitID,
                          session.runState == .waitingForUser
                    else { return }

                    session.waitingPrompt = nil
                    cancelPendingQuestion(for: session)
                    session.instructionContinuation = nil
                    session.instructionTimeoutTask = nil
                    session.instructionWaitID = nil
                    await runService.cancelRun(
                        tabID: session.tabID,
                        session: session,
                        intent: .userStop,
                        completion: .terminalPublished
                    )
                    continuation.resume(returning: UserInstructionResponse(
                        text: nil,
                        timedOut: true,
                        elapsedSeconds: Int(timeout)
                    ))
                }
            }
        }
    }

    // MARK: - Ask User Question (MCP Tool Support)

    /// Legacy single-question adapter retained until the public MCP ask_user schema migrates.
    func askUserQuestion(
        tabID: UUID,
        question: String,
        options: [String]? = nil,
        context: String? = nil,
        multiSelect: Bool = false,
        timeoutSeconds: TimeInterval = ContextBuilderDefaults.questionTimeoutSeconds
    ) async throws -> UserQuestionResponse {
        let questionID = "response"
        let interaction = AgentAskUserInteraction(
            title: "Question",
            context: context,
            timeoutSeconds: timeoutSeconds,
            questions: [
                AgentAskUserQuestion(
                    id: questionID,
                    question: question,
                    options: (options ?? []).map { AgentAskUserOption(label: $0) },
                    allowsMultiple: multiSelect,
                    allowsCustom: true
                )
            ]
        )
        let response = try await askUser(tabID: tabID, interaction: interaction)
        if response.timedOut {
            return .timeout(elapsedSeconds: response.elapsedSeconds)
        }
        if response.skipped {
            return .skipped(elapsedSeconds: response.elapsedSeconds)
        }
        let answer = response.answersByQuestionID[questionID]
        if answer?.skipped == true {
            return .skipped(elapsedSeconds: response.elapsedSeconds)
        }
        return .answered(answer?.answers.joined(separator: "\n") ?? "", elapsedSeconds: response.elapsedSeconds)
    }

    func askUserInteraction(
        tabID: UUID,
        interaction: AgentAskUserInteraction
    ) async throws -> AgentAskUserResponse {
        try await askUser(tabID: tabID, interaction: interaction)
    }

    func askUser(
        tabID: UUID,
        interaction: AgentAskUserInteraction
    ) async throws -> AgentAskUserResponse {
        let session = await ensureSessionReady(tabID: tabID, reconnectActiveProviders: true)
        try interaction.validate()
        try rejectAskUserIfBlockingInteractionExists(in: session)

        let pending = AgentAskUserPendingState(
            interaction: interaction,
            timeoutStartedAt: interaction.askedAt
        )
        session.pendingAskUser = pending
        reconcileInteractiveRunState(session)
        updateBindingsFromSession(session)

        return try await withCheckedThrowingContinuation { continuation in
            session.askUserContinuation = continuation
            schedulePendingAskUserTimeout(
                for: session,
                interactionID: interaction.id,
                timeoutSeconds: interaction.timeoutSeconds,
                startedAt: interaction.askedAt
            )
        }
    }

    private func rejectAskUserIfBlockingInteractionExists(in session: TabSession) throws {
        if session.pendingAskUser != nil {
            throw MCPError.invalidParams("ask_user is already waiting for a response in this session.")
        }
        if session.pendingApproval != nil || session.pendingPermissionsRequest != nil || session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil {
            throw MCPError.invalidParams("ask_user cannot be shown while an approval is pending.")
        }
        if session.pendingMCPElicitationRequest != nil || !session.queuedMCPElicitationRequests.isEmpty {
            throw MCPError.invalidParams("ask_user cannot be shown while an MCP elicitation is pending.")
        }
        if session.pendingUserInputRequest != nil || !session.queuedUserInputRequests.isEmpty {
            throw MCPError.invalidParams("ask_user cannot be shown while native user input is pending.")
        }
    }

    func updateAskUserDraft(tabID: UUID, interactionID: UUID, questionID: String, draft: AgentAskUserDraft) {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.contains(where: { $0.id == questionID })
        else { return }
        guard pending.draftsByQuestionID[questionID] != draft else { return }
        pending.draftsByQuestionID[questionID] = draft
        session.pendingAskUser = pending
        updateBindingsFromSession(session)
    }

    func updateAskUserQuestionIndex(tabID: UUID, interactionID: UUID, index: Int) {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.indices.contains(index)
        else { return }
        guard pending.currentQuestionIndex != index else { return }
        pending.currentQuestionIndex = index
        session.pendingAskUser = pending
        updateBindingsFromSession(session)
    }

    /// Reset the pending Agent Mode ask_user timeout after visible card activity.
    func noteAskUserCardActivity(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID],
              let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil
        else { return }

        schedulePendingAskUserTimeout(
            for: session,
            interactionID: interactionID,
            timeoutSeconds: pending.interaction.timeoutSeconds,
            startedAt: Date()
        )

        if tabID == currentTabID {
            syncRunInteractionUIState()
        }
    }

    private func schedulePendingAskUserTimeout(
        for session: TabSession,
        interactionID: UUID,
        timeoutSeconds: TimeInterval,
        startedAt: Date
    ) {
        session.askUserTimeoutTask?.cancel()
        session.pendingAskUserTimeoutGeneration &+= 1
        let generation = session.pendingAskUserTimeoutGeneration
        if var pending = session.pendingAskUser, pending.interaction.id == interactionID {
            pending.timeoutStartedAt = startedAt
            session.pendingAskUser = pending
        }
        let sleepNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)

        session.askUserTimeoutTask = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }

            guard let self,
                  let session,
                  session.pendingAskUserTimeoutGeneration == generation,
                  let pending = session.pendingAskUser,
                  pending.interaction.id == interactionID,
                  let continuation = session.askUserContinuation
            else { return }

            invalidatePendingAskUserTimeout(for: session)
            session.pendingAskUser = nil
            session.askUserContinuation = nil
            reconcileInteractiveRunState(session)
            updateBindingsFromSession(session)

            let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
            let response = pending.interaction.buildTimedOutResponse(
                drafts: pending.draftsByQuestionID,
                elapsedSeconds: elapsedSeconds
            )
            continuation.resume(returning: response)
        }
    }

    private func invalidatePendingAskUserTimeout(for session: TabSession) {
        session.pendingAskUserTimeoutGeneration &+= 1
        session.askUserTimeoutTask?.cancel()
        session.askUserTimeoutTask = nil
        if var pending = session.pendingAskUser {
            pending.timeoutStartedAt = nil
            session.pendingAskUser = pending
        }
    }

    func submitAskUserResponse(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else { return }
        do {
            try resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: false)
        } catch {
            return
        }
    }

    func submitAskUserResponse(tabID: UUID, interactionID: UUID, draftsByQuestionID: [String: AgentAskUserDraft]) throws {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID
        else { return }
        pending.draftsByQuestionID = draftsByQuestionID
        session.pendingAskUser = pending
        try resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: false)
    }

    func skipAskUser(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else { return }
        try? resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: true)
    }

    private func resolveAskUserResponse(for session: TabSession, interactionID: UUID, skipAll: Bool) throws {
        guard let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              let continuation = session.askUserContinuation
        else { return }

        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
        let response = if skipAll {
            pending.interaction.buildSkippedResponse(elapsedSeconds: elapsedSeconds)
        } else {
            try pending.interaction.buildSubmittedResponse(
                drafts: pending.draftsByQuestionID,
                elapsedSeconds: elapsedSeconds
            )
        }

        invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        reconcileInteractiveRunState(session)
        updateBindingsFromSession(session)

        // Note: We don't append a .user item here - the response will be shown
        // via the ask_user tool_result.
        continuation.resume(returning: response)
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func noteQuestionCardActivity(tabID: UUID, questionID: UUID) {
        noteAskUserCardActivity(tabID: tabID, interactionID: questionID)
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func submitQuestionResponse(tabID: UUID, interactionID: UUID, response: String) {
        guard let session = sessions[tabID],
              let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              let question = pending.interaction.questions.first
        else { return }
        var draft = AgentAskUserDraft(customResponse: response)
        if let matchedOption = question.optionLabels.first(where: { $0 == response }) {
            draft = AgentAskUserDraft(selectedOptionLabels: [matchedOption])
        }
        try? submitAskUserResponse(tabID: tabID, interactionID: interactionID, draftsByQuestionID: [question.id: draft])
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func skipQuestion(tabID: UUID, interactionID: UUID) {
        skipAskUser(tabID: tabID, interactionID: interactionID)
    }

    func submitUserInputResponse(tabID: UUID, requestID: CodexAppServerRequestID, response: AgentRequestUserInputResponse) {
        guard let session = sessions[tabID],
              let request = session.pendingUserInputRequest,
              request.requestID == requestID
        else {
            return
        }
        codexCoordinator.submitUserInputResponse(session: session, requestID: requestID, response: response)
        session.pendingUserInputRequest = nil
        if !session.queuedUserInputRequests.isEmpty {
            session.pendingUserInputRequest = session.queuedUserInputRequests.removeFirst()
        }
        reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .userInputResponseSubmitted)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: tabID, urgent: true)
    }

    private func cancelPendingQuestion(for session: TabSession) {
        invalidatePendingAskUserTimeout(for: session)
        let continuation = session.askUserContinuation
        session.askUserContinuation = nil
        session.pendingAskUser = nil
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.queuedUserInputRequests.removeAll()
        session.queuedMCPElicitationRequests.removeAll()
        reconcileInteractiveRunState(session)
        continuation?.resume(throwing: CancellationError())
        publishRunInteractionStateChange(for: session, reason: .pendingQuestionCancelled)
    }

    private func cancelPendingApproval(for session: TabSession) {
        session.pendingApproval = nil
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.queuedMCPElicitationRequests.removeAll()
        reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .pendingApprovalCancelled)
    }

    private func cancelPendingApplyEditsReview(for session: TabSession, reason: String) {
        session.pendingApplyEditsReview = nil
        let scope = applyEditsScope(for: session.tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.cancelPendingReview(scope: scope, reason: reason)
        }
    }

    private func cancelPendingInstruction(for session: TabSession) {
        session.instructionTimeoutTask?.cancel()
        session.instructionTimeoutTask = nil
        if let continuation = session.instructionContinuation {
            continuation.resume(throwing: CancellationError())
        }
        session.instructionContinuation = nil
        session.instructionWaitID = nil
        session.waitingPrompt = nil
    }

    // MARK: - Helpers

    private func buildInitialThreadMessageIfNeeded(
        tabID: UUID,
        session: TabSession,
        initialMessage: String
    ) async -> String {
        guard shouldIncludeInitialThreadContext(for: session) else {
            return initialMessage
        }
        let context = await initialThreadContext(tabID: tabID, session: session)
        return Self.composeInitialThreadMessage(
            initialMessage: initialMessage,
            fileTree: context.fileTree,
            promptText: context.promptText
        )
    }

    private func buildInitialThreadContextBlock(tabID: UUID) async -> String? {
        let context = await initialThreadContext(tabID: tabID, session: sessions[tabID])
        let block = Self.composeInitialThreadMessage(
            initialMessage: "",
            fileTree: context.fileTree,
            promptText: context.promptText
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return nil }
        return block
    }

    func shouldIncludeInitialThreadContext(for session: TabSession) -> Bool {
        guard session.providerSessionID == nil else { return false }
        guard !session.items.contains(where: Self.itemBlocksInitialThreadContext) else { return false }
        let userMessageCount = session.items.enumerated().reduce(into: 0) { partialResult, entry in
            let (index, item) = entry
            if item.kind == .user,
               !item.isLocalControlPlaneEcho,
               !Self.isGoalObjectiveControlEcho(item, at: index, in: session.items)
            {
                partialResult += 1
            }
        }
        return userMessageCount <= 1
    }

    private static func isGoalObjectiveControlEcho(_ item: AgentChatItem, at index: Int, in items: [AgentChatItem]) -> Bool {
        guard item.kind == .user else { return false }
        let objective = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return false }
        let expectedResultPrefix = "Set Codex goal: \(objective)"
        return items.dropFirst(index + 1).contains { candidate in
            candidate.kind == .system && candidate.text.contains(expectedResultPrefix)
        }
    }

    private static func itemBlocksInitialThreadContext(_ item: AgentChatItem) -> Bool {
        switch item.kind {
        case .assistant, .assistantInline, .toolCall, .toolResult, .thinking:
            true
        case .user, .system, .error:
            false
        }
    }

    private func initialThreadContext(tabID: UUID, session: TabSession?) async -> (fileTree: String, promptText: String?) {
        guard let promptManager else {
            return ("", nil)
        }
        let store = promptManager.workspaceFileContextStore
        let isActiveTab = tabID == currentTabID
        if isActiveTab {
            workspaceManager?.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        let tabState = workspaceManager?.composeTab(with: tabID)
        let promptText = isActiveTab ? promptManager.promptText : tabState?.promptText
        let selection = tabState?.selection ?? StoredSelection()
        let lookupContext = await agentWorkspaceLookupContext(tabID: tabID, session: session)
        let fileTree = await AgentProviderContextBuilder.initialFileTree(
            selection: selection,
            store: store,
            lookupContext: lookupContext
        )
        return (fileTree, promptText)
    }

    nonisolated static func composeInitialThreadMessage(
        initialMessage: String,
        fileTree: String,
        promptText: String?
    ) -> String {
        let trimmedTree = fileTree.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedInstruction = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var contextSections: [String] = []
        if !trimmedTree.isEmpty {
            contextSections.append("""
            <file_map>
            \(trimmedTree)
            </file_map>
            """)
        }
        if !trimmedPrompt.isEmpty {
            contextSections.append("""
            <current_prompt_content>
            \(trimmedPrompt)
            </current_prompt_content>
            """)
        }
        guard !contextSections.isEmpty else { return initialMessage }
        guard !trimmedInstruction.isEmpty else {
            return contextSections.joined(separator: "\n\n")
        }
        return [initialMessage, contextSections.joined(separator: "\n\n")].joined(separator: "\n\n")
    }

    nonisolated static func composeClaudeResumeRecoveryHandoffPayload(
        sourceTabName: String,
        sourceAgentName: String,
        transcriptXML: String,
        initialThreadContextBlock: String?,
        deliveryID: String
    ) -> String {
        let trimmedTranscriptXML = transcriptXML.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInitialThreadContextBlock = initialThreadContextBlock?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var payloadSections: [String] = []
        if let trimmedInitialThreadContextBlock,
           !trimmedInitialThreadContextBlock.isEmpty
        {
            payloadSections.append(
                """
                <original_thread_context>
                \(trimmedInitialThreadContextBlock)
                </original_thread_context>
                """
            )
        }
        if !trimmedTranscriptXML.isEmpty {
            payloadSections.append(trimmedTranscriptXML)
        }

        let payloadBody = payloadSections.joined(separator: "\n\n")
        return """
        <forked_session source="\(sourceTabName)" delivery_id="\(deliveryID)">
        You are continuing a session that was restarted after a native resume failed for \(sourceAgentName). Use the recovered transcript below, plus any preserved thread context, to continue seamlessly.

        \(payloadBody)
        </forked_session>
        """
    }

    nonisolated static func composeSessionHandoffPayload(
        sourceTabName: String,
        sourceAgentName: String,
        sourceModelName: String,
        fileContentsBlock: String?,
        transcriptXML: String,
        deliveryID: String
    ) -> String {
        let trimmedFileContentsBlock = fileContentsBlock?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscriptXML = transcriptXML.trimmingCharacters(in: .whitespacesAndNewlines)

        var payloadSections: [String] = []
        if let trimmedFileContentsBlock,
           !trimmedFileContentsBlock.isEmpty
        {
            payloadSections.append(trimmedFileContentsBlock)
        }
        if !trimmedTranscriptXML.isEmpty {
            payloadSections.append(trimmedTranscriptXML)
        }

        let payloadBody = payloadSections.joined(separator: "\n\n")
        return """
        <forked_session source="\(sourceTabName)" delivery_id="\(deliveryID)">
        You are continuing a session started with \(sourceAgentName) (\(sourceModelName)). Below is a snapshot of the file system state analyzed by that agent, along with the exchange made with the user up until this point.

        \(payloadBody)
        </forked_session>
        """
    }

    private func buildConversationHistory(for session: TabSession) -> String {
        AgentTranscriptIO.buildConversationHistory(from: session.transcript) { request in
            self.renderProviderMessage(
                text: request.text,
                attachments: request.attachments,
                agent: session.selectedAgent
            )
        }
    }

    func notifyAgentTurnComplete(for session: TabSession) {
        let preview = latestAssistantPreviewText(in: session)
        NotificationService.shared.notifyAgentTurnComplete(
            sessionName: resolvedSessionDisplayName(for: session.tabID),
            previewText: preview,
            route: agentNotificationRoute(for: session),
            fallbackToDockBounce: true
        )
    }

    func notifyAgentWaitingForUser(for tabID: UUID, prompt: String) {
        NotificationService.shared.notifyAgentWaitingForUser(
            sessionName: resolvedSessionDisplayName(for: tabID),
            promptText: prompt,
            route: agentNotificationRoute(forTabID: tabID),
            fallbackToDockBounce: true
        )
    }

    private func agentNotificationRoute(for session: TabSession) -> AgentSessionDeepLinkRoute? {
        agentNotificationRoute(forTabID: session.tabID, sessionID: session.activeAgentSessionID)
    }

    private func agentNotificationRoute(forTabID tabID: UUID, sessionID explicitSessionID: UUID? = nil) -> AgentSessionDeepLinkRoute? {
        guard let workspace = workspaceManager?.activeWorkspace else {
            return nil
        }
        let tabIsInWorkspace = workspace.composeTabs.contains(where: { $0.id == tabID })
            || workspace.stashedTabs.contains(where: { $0.tab.id == tabID })
        guard tabIsInWorkspace else {
            return nil
        }

        let resolvedSessionID = explicitSessionID
            ?? sessions[tabID]?.activeAgentSessionID
            ?? workspaceManager?.activeAgentSessionID(forTabID: tabID, inWorkspaceID: workspace.id)
        return AgentSessionDeepLinkRoute(
            windowID: windowID,
            workspaceID: workspace.id,
            tabID: tabID,
            sessionID: resolvedSessionID
        )
    }

    private func latestAssistantPreviewText(in session: TabSession) -> String? {
        AgentTranscriptIO.latestAssistantPreviewText(from: session.transcript)
    }

    /// Status-aware assistant preview: active runs only show text from the current turn,
    /// terminal runs show the latest text from the full transcript.
    private func mcpResolvedAssistantPreview(session: TabSession, status: AgentRunMCPSnapshot.Status) -> String? {
        switch status {
        case .expired:
            return nil
        case .running, .waitingForInput:
            if session.mcpFollowUpRunPending {
                return nil
            }
            guard let lastTurn = session.transcript.turns.last else {
                // Fallback for transcriptless sessions: only use items if latest assistant is newer than latest user
                let latestAssistant = session.items.reversed().first(where: { $0.hasDisplayableAssistantBody })
                let latestUser = session.items.reversed().first(where: { $0.kind == .user })
                guard let assistant = latestAssistant else { return nil }
                if let user = latestUser, user.timestamp >= assistant.timestamp { return nil }
                return assistant.text
            }
            if lastTurn.isCompleted, status == .running {
                return nil
            }
            return AgentTranscriptIO.latestAssistantPreviewText(in: lastTurn)
        case .completed, .failed, .cancelled:
            return latestAssistantPreviewText(in: session)
                ?? session.items.reversed().first(where: { $0.hasDisplayableAssistantBody })?.text
        }
    }

    /// Check if a tab has an active agent run
    func isTabRunning(_ tabID: UUID) -> Bool {
        tabsWithActiveAgentRun.contains(tabID)
    }

    func runState(for tabID: UUID) -> AgentSessionRunState {
        sessions[tabID]?.runState ?? .idle
    }

    func isTabWaiting(_ tabID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        return session.runState == .waitingForUser || session.runState == .waitingForQuestion || session.runState == .waitingForApproval
    }

    /// Get pending structured ask_user interaction for a tab (for UI)
    func pendingAskUser(for tabID: UUID?) -> AgentAskUserPendingState? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingAskUser
    }

    /// Legacy single-question snapshot shim retained for tests and old call sites during migration.
    func pendingQuestion(for tabID: UUID?) -> DiscoveryQuestion? {
        pendingAskUser(for: tabID)?.legacyDiscoveryQuestion
    }

    func pendingUserInputRequest(for tabID: UUID?) -> AgentRequestUserInputRequest? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingUserInputRequest
    }

    func pendingApproval(for tabID: UUID?) -> AgentApprovalRequest? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingApproval
    }

    func pendingPermissionsRequest(for tabID: UUID?) -> AgentPermissionsRequest? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingPermissionsRequest
    }

    func pendingMCPElicitationRequest(for tabID: UUID?) -> AgentMCPElicitationRequest? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingMCPElicitationRequest
    }

    func pendingApplyEditsReview(for tabID: UUID?) -> PendingApplyEditsReview? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingApplyEditsReview
    }

    /// Clear the chat transcript for the current tab
    func clearChat() {
        guard let tabID = currentTabID else { return }
        clearChat(tabID: tabID)
    }

    /// Clear the chat transcript for a specific tab
    func clearChat(tabID: UUID) {
        guard let session = sessions[tabID] else { return }

        session.setItemsSilently([], reason: .clearedChat)
        session.clearDerivedTranscriptCaches()
        session.pendingImageAttachments.removeAll()
        session.pendingTaggedFileAttachments.removeAll()
        session.attachmentsPendingProviderConsumptionCleanup.removeAll()
        session.nextSequenceIndex = 0
        session.lastActivityAt = Date()
        session.lastUserMessageAt = nil
        session.isDirty = true
        invalidateSidebarRestoreOrdering()
        sessionListSortDates.removeValue(forKey: tabID)

        // Detach before clearing the provider session ID so async cleanup cannot
        // restore the old conversation or affect a replacement controller.
        claudeCoordinator.prepareForConversationResetSync(session)
        session.providerSessionID = nil
        session.providerTokenUsageByTurn.removeAll()
        session.pendingNonCodexUserInputTokenQueue.removeAll()
        session.activeNonCodexTurnTokenAccumulator = nil
        session.contextUsageSnapshot = nil
        session.contextCompactedAt = nil
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        session.codexReasoningSegmentsByKey.removeAll()
        session.pendingTurnRuntimeAnchors.removeAll()
        session.agentMessageRuntimeFootersByItemID.removeAll()

        // Clear Codex-native identifiers and usage
        codexCoordinator.clearCodexSessionState(session)

        applyTranscriptViewportBindingState(
            to: session,
            viewportState: .liveBottom,
            armingState: .armed
        )
        if tabID == currentTabID {
            updateBindingsFromSession(session)
        }
        scheduleSave(for: tabID)
    }

    /// Rename the visible agent session for a tab.
    ///
    /// Agent-mode sidebar rows are session-first, but the user-facing title is also
    /// mirrored through the compose tab so window/tab UI and persisted workspace
    /// state stay in sync.
    func renameSession(tabID: UUID, to newName: String) {
        let validatedName = AgentSession.validatedName(newName)
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        promptManager?.renameComposeTab(tabID, to: validatedName)

        let sessionID = boundSessionID(for: tabID)
        if let sessionID,
           var entry = ownerValidatedSessionIndex[sessionID]
        {
            entry.name = validatedName
            applyLocalSessionIndexUpsert(entry)
        }

        if let session = sessions[tabID] {
            if session.activeAgentSessionID == nil, let sessionID {
                _ = installPersistentSessionBinding(
                    sessionID: sessionID,
                    on: session,
                    updateWorkspaceMetadata: true,
                    invalidateAsyncWork: true
                )
            }
            session.isDirty = true
            scheduleSave(for: tabID)
            handleObservedMCPStateChange(for: session)
            codexCoordinator.scheduleCodexThreadNameSyncIfPossible(
                for: session,
                name: validatedName,
                explicitThreadID: session.codexConversationID,
                source: "renameSession"
            )
        } else if let sessionID,
                  let workspace = workspaceManager?.activeWorkspace ?? lastKnownWorkspaceSnapshot
        {
            Task { [dataService] in
                try? await dataService.renameAgentSession(
                    id: sessionID,
                    to: validatedName,
                    for: workspace
                )
            }
        }
    }

    private func cleanupACPStateForDeletedSession(_ session: TabSession) async {
        session.acpSteeringFlushTask?.cancel()
        session.acpSteeringFlushTask = nil
        session.pendingACPSteeringInstructions.removeAll()
        if let controller = session.acpController {
            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await controller.cancelPrompt()
            await controller.shutdown()
        }
    }

    struct DeletedAgentSessionCleanupResult: Equatable {
        let affectedTabIDs: Set<UUID>
        let clearedComposeTabIDs: Set<UUID>
        let clearedStashedTabIDs: Set<UUID>
    }

    @discardableResult
    func finalizeDeletedAgentSessionReferences(
        sessionID: UUID,
        workspaceID: UUID?,
        knownTabIDs: Set<UUID> = [],
        reason: String
    ) async -> DeletedAgentSessionCleanupResult {
        #if DEBUG
            let finalizeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let cleanupRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        var affectedTabIDs = knownTabIDs
        if let indexedTabID = ownerValidatedSessionIndex[sessionID]?.tabID {
            affectedTabIDs.insert(indexedTabID)
        }

        let liveTabIDs = Set(sessions.values.compactMap { session -> UUID? in
            session.activeAgentSessionID == sessionID ? session.tabID : nil
        })
        let stateCleanupTabIDs = knownTabIDs.union(liveTabIDs)
        affectedTabIDs.formUnion(liveTabIDs)

        var clearedComposeTabIDs = Set<UUID>()
        var clearedStashedTabIDs = Set<UUID>()
        if let workspaceManager {
            for workspace in workspaceManager.workspaces where workspaceID == nil || workspace.id == workspaceID {
                for tab in workspace.composeTabs where tab.activeAgentSessionID == sessionID {
                    if workspaceManager.compareAndSetActiveAgentSessionID(
                        expected: sessionID,
                        replacement: nil,
                        forTabID: tab.id,
                        inWorkspaceID: workspace.id
                    ) {
                        clearedComposeTabIDs.insert(tab.id)
                        affectedTabIDs.insert(tab.id)
                    }
                }
                for stashed in workspace.stashedTabs where stashed.tab.activeAgentSessionID == sessionID {
                    if workspaceManager.compareAndSetActiveAgentSessionID(
                        expected: sessionID,
                        replacement: nil,
                        forTabID: stashed.tab.id,
                        inWorkspaceID: workspace.id
                    ) {
                        clearedStashedTabIDs.insert(stashed.tab.id)
                        affectedTabIDs.insert(stashed.tab.id)
                    }
                }
            }
        }
        if var snapshot = lastKnownWorkspaceSnapshot,
           workspaceID == nil || snapshot.id == workspaceID
        {
            var didChangeSnapshot = false
            for tabIndex in snapshot.composeTabs.indices where snapshot.composeTabs[tabIndex].activeAgentSessionID == sessionID {
                affectedTabIDs.insert(snapshot.composeTabs[tabIndex].id)
                snapshot.composeTabs[tabIndex].activeAgentSessionID = nil
                didChangeSnapshot = true
            }
            for stashedIndex in snapshot.stashedTabs.indices where snapshot.stashedTabs[stashedIndex].tab.activeAgentSessionID == sessionID {
                affectedTabIDs.insert(snapshot.stashedTabs[stashedIndex].tab.id)
                snapshot.stashedTabs[stashedIndex].tab.activeAgentSessionID = nil
                didChangeSnapshot = true
            }
            if didChangeSnapshot {
                lastKnownWorkspaceSnapshot = snapshot
            }
        }

        for tabID in stateCleanupTabIDs {
            removePendingUIRefresh(for: tabID)
            if activeSessionLoadInProgressTabID == tabID {
                activeSessionLoadInProgressTabID = nil
            }
            sessionListSortDates.removeValue(forKey: tabID)
            tabsWithActiveAgentRun.remove(tabID)
            mcpControlledTabIDs.remove(tabID)

            guard let session = sessions[tabID], session.activeAgentSessionID == sessionID else { continue }
            cancelPersistedLoad(for: session)
            cancelPendingQuestion(for: session)
            cancelPendingApproval(for: session)
            cancelPendingApplyEditsReview(for: session, reason: "Session deleted")
            await teardownApplyEditsApprovalSessionSync(for: session, cleanupScope: true)
            cancelPendingInstruction(for: session)
            await cleanupACPStateForDeletedSession(session)
            await teardownMCPControl(for: session, cleanupSessionStore: true)
            session.pendingCommandRunningFlushTask?.cancel()
            session.pendingCommandRunningFlushTask = nil
            session.pendingCommandRunningByKey.removeAll()
            session.agentTask?.cancel()
            if let provider = session.provider {
                await provider.dispose()
            }
            await codexCoordinator.shutdownCodexSession(session)
            await claudeCoordinator.shutdownClaudeSession(session)
            await cleanupMCPRunRoutingIfPresent(
                boundSessionID: sessionID,
                liveSession: session,
                reason: reason
            )
            sessions.removeValue(forKey: tabID)
        }

        await releaseSessionWorktreeOwnership(sessionID: sessionID)
        removeSessionIndex(sessionID: sessionID)
        if let cleanupRegistration {
            await AgentRunSessionStore.cleanup(registration: cleanupRegistration)
        }

        let activeTabID = currentTabID
        if activeTabID.map(affectedTabIDs.contains) == true {
            lastProcessedTabID = nil
            onTabChanged(activeTabID)
        } else if activeTabID == nil, !affectedTabIDs.isEmpty {
            lastProcessedTabID = nil
            onTabChanged(nil)
        }
        syncSidebarUIState(refresh: true, reason: .sessionIndex)

        let result = DeletedAgentSessionCleanupResult(
            affectedTabIDs: affectedTabIDs,
            clearedComposeTabIDs: clearedComposeTabIDs,
            clearedStashedTabIDs: clearedStashedTabIDs
        )
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.vm.finalizeDeletedReferences",
                startMS: finalizeStartMS,
                fields: [
                    "sessionID": sessionID.uuidString,
                    "affectedTabCount": String(result.affectedTabIDs.count),
                    "clearedComposeCount": String(result.clearedComposeTabIDs.count),
                    "clearedStashedCount": String(result.clearedStashedTabIDs.count)
                ]
            )
        #endif
        return result
    }

    /// Delete a session completely (clear chat and close tab)
    func deleteSession(tabID: UUID) async {
        #if DEBUG
            let deleteSessionStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let sessionID = boundSessionID(for: tabID)
        let liveSession = sessions[tabID]
        let wasCurrentTab = currentTabID == tabID
        if wasCurrentTab {
            lastProcessedTabID = nil
        }
        if let session = liveSession {
            removePendingUIRefresh(for: tabID)
            cancelPersistedLoad(for: session)
            cancelPendingQuestion(for: session)
            cancelPendingApproval(for: session)
            cancelPendingApplyEditsReview(for: session, reason: "Session deleted")
            await teardownApplyEditsApprovalSessionSync(for: session, cleanupScope: true)
            cancelPendingInstruction(for: session)
            await cleanupACPStateForDeletedSession(session)
            await teardownMCPControl(for: session, cleanupSessionStore: true)
            session.pendingCommandRunningFlushTask?.cancel()
            session.pendingCommandRunningFlushTask = nil
            session.pendingCommandRunningByKey.removeAll()
            session.agentTask?.cancel()
            if let provider = session.provider {
                await provider.dispose()
            }
            await codexCoordinator.shutdownCodexSession(session)
            await claudeCoordinator.shutdownClaudeSession(session)
        }
        await cleanupMCPRunRoutingIfPresent(
            boundSessionID: sessionID,
            liveSession: liveSession,
            reason: "session_delete"
        )
        let workspaceID = workspaceManager?.activeWorkspace?.id
        if let workspace = workspaceManager?.activeWorkspace,
           let sessionID
        {
            try? await dataService.deleteAgentSession(id: sessionID, for: workspace)
            removeSessionIndex(sessionID: sessionID)
        } else {
            removeSessionIndex(forTabID: tabID)
        }
        tabDraftText.removeValue(forKey: tabID)
        sessions.removeValue(forKey: tabID)
        tabsWithActiveAgentRun.remove(tabID)
        mcpControlledTabIDs.remove(tabID)
        sessionListSortDates.removeValue(forKey: tabID)
        removePendingUIRefresh(for: tabID)
        await promptManager?.closeComposeTab(tabID)
        if let sessionID {
            await finalizeDeletedAgentSessionReferences(
                sessionID: sessionID,
                workspaceID: workspaceID,
                knownTabIDs: [tabID],
                reason: "session_delete"
            )
        } else {
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.vm.deleteSession",
                startMS: deleteSessionStartMS,
                tabID: tabID,
                fields: [
                    "tabID": tabID.uuidString,
                    "sessionID": sessionID?.uuidString ?? "nil"
                ]
            )
        #endif
    }

    /// Last activity timestamp for sorting tabs in the UI
    func lastActivityDate(for tabID: UUID) -> Date {
        if let session = sessions[tabID] {
            return session.lastActivityAt
        }
        if let tab = promptManager?.currentComposeTabs.first(where: { $0.id == tabID }) {
            return tab.lastModified
        }
        return .distantPast
    }

    /// Last user message timestamp for sorting tabs (user messages and question responses count)
    func lastUserMessageDate(for tabID: UUID) -> Date? {
        if let session = sessions[tabID] {
            if let cached = session.lastUserMessageAt {
                return cached
            }
            if let computed = computeLastUserMessageDate(in: session.items) {
                return computed
            }
            return sessionListSortDate(for: tabID)
        }
        return sessionListSortDate(for: tabID)
    }

    /// Check if a tab has an agent session (in memory or persisted on disk)
    func hasAgentSession(for tabID: UUID) -> Bool {
        // Check in-memory sessions first (O(1) dictionary lookup)
        if sessions[tabID] != nil {
            return true
        }
        // Check cached metadata from disk (includes sessions without user messages)
        if ownerValidatedSessionIndex.values.contains(where: { $0.tabID == tabID }) {
            return true
        }
        // Check if tab has a persisted agent session ID via workspaceManager
        if let tabState = workspaceManager?.composeTab(with: tabID),
           tabState.activeAgentSessionID != nil
        {
            return true
        }
        return false
    }

    func hasLinkedAgentSession(for tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return explicitActiveSessionID(for: tabID) != nil
    }

    /// Returns true when a new-session click should be ignored because the current tab is still untouched.
    /// This prevents creating multiple consecutive empty sessions.
    func shouldSwallowNewSessionClick(for tabID: UUID?) -> Bool {
        guard let tabID,
              hasLinkedAgentSession(for: tabID),
              let session = sessions[tabID]
        else {
            return false
        }

        // If this tab points at a persisted session that has not finished loading,
        // treat it as unknown instead of empty to avoid false positives.
        if session.activeAgentSessionID != nil && !session.hasLoadedPersistedState {
            return false
        }

        let hasTranscript = !session.transcript.turns.isEmpty || !session.items.isEmpty
        let hasDraft = !session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPendingAttachments = !session.pendingImageAttachments.isEmpty || !session.pendingTaggedFileAttachments.isEmpty
        let hasPendingInteraction = session.runState == .waitingForUser
            || session.hasPendingQuestionUI
            || session.pendingApproval != nil
            || session.pendingPermissionsRequest != nil
            || session.pendingApplyEditsReview != nil
        let hasActiveRun = session.runState.isActive

        return !(hasTranscript || hasDraft || hasPendingAttachments || hasPendingInteraction || hasActiveRun)
    }

    /// Ensure a session exists for a tab (creates one if needed)
    func ensureSession(for tabID: UUID) {
        let session = session(for: tabID)
        _ = ensureSessionBoundToTab(session)
    }

    /// Create a brand new session by creating a tab that is already linked to an agent session.
    @discardableResult
    func createAndActivateSessionTab() async -> UUID? {
        guard let promptManager else { return nil }
        await promptManager.createBlankComposeTab(createAgentSession: true)
        guard let tabID = currentTabID else { return nil }
        let session = session(for: tabID)
        markSessionAsFreshlyCreated(session)
        invalidateSidebarRestoreOrdering()
        updateBindingsFromSession(session)
        return tabID
    }

    // MARK: - Session Handoff

    /// Whether the current tab has enough transcript to be worth handing off.
    var canForkCurrentSession: Bool {
        guard let tabID = currentTabID,
              let session = sessions[tabID] else { return false }
        if session.transcript.turns.contains(where: { $0.request != nil }) {
            return true
        }
        return session.items.contains(where: { $0.kind == .user || $0.kind == .assistant || $0.kind == .assistantInline })
    }

    /// Build the handoff payload string for a given item cutoff (used for clipboard copy and handoff).
    @MainActor
    func buildHandoffPayload(upToItemID: UUID?) async -> String {
        guard let sourceTabID = currentTabID,
              let sourceSession = sessions[sourceTabID],
              let sourceTranscript = resolvedHandoffSourceTranscript(
                  for: sourceSession,
                  upToItemID: upToItemID
              ) else { return "" }

        return await buildHandoffPayload(
            sourceTabID: sourceTabID,
            sourceSession: sourceSession,
            sourceTranscript: sourceTranscript,
            upToItemID: upToItemID
        )
    }

    @MainActor
    private func buildHandoffPayload(
        sourceTabID: UUID,
        sourceSession: TabSession,
        sourceTranscript: AgentTranscript,
        upToItemID: UUID?
    ) async -> String {
        guard let workspaceManager else { return "" }

        if sourceTabID == currentTabID {
            workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        let sourceSelection = workspaceManager.composeTab(with: sourceTabID)?.selection ?? StoredSelection()
        let sourceTabName = workspaceManager.composeTabName(with: sourceTabID) ?? "Session"
        let sourceAgentName = sourceSession.selectedAgent.displayName
        let sourceModelName = modelDisplayName(
            rawModel: sourceSession.selectedModelRaw,
            agentKind: sourceSession.selectedAgent
        )
        let transcriptXML = buildForkTranscriptXML(from: sourceTranscript, upToItemID: upToItemID)
        let lookupContext = await agentWorkspaceLookupContext(tabID: sourceTabID, session: sourceSession)
        let fileContentsBlock = await buildForkFileContentsBlock(
            selection: sourceSelection,
            tokenCap: 60000,
            lookupContext: lookupContext
        )
        // delivery_id makes crash/restart retries best-effort idempotent at the prompt level.
        let deliveryID = UUID().uuidString

        return Self.composeSessionHandoffPayload(
            sourceTabName: sourceTabName,
            sourceAgentName: sourceAgentName,
            sourceModelName: sourceModelName,
            fileContentsBlock: fileContentsBlock,
            transcriptXML: transcriptXML,
            deliveryID: deliveryID
        )
    }

    /// Build the file-contents block used by handoff payload export for the current active tab.
    /// This intentionally snapshots only the current tab selection, matching the in-app handoff path.
    @MainActor
    func buildCurrentTabHandoffFileContentsBlock(tokenCap: Int = 60000) async -> String {
        guard let workspaceManager,
              let sourceTabID = currentTabID else { return "" }
        workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true)
        let sourceSelection = workspaceManager.composeTab(with: sourceTabID)?.selection ?? StoredSelection()
        let lookupContext = await agentWorkspaceLookupContext(tabID: sourceTabID, session: sessions[sourceTabID])
        return await buildForkFileContentsBlock(
            selection: sourceSelection,
            tokenCap: tokenCap,
            lookupContext: lookupContext
        )
    }

    @MainActor
    private func fallbackHandoffTranscript(from items: [AgentChatItem]) -> AgentTranscript {
        AgentTranscriptIO.buildTranscript(
            from: items,
            nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1,
            policy: .canonical,
            compact: false
        )
    }

    /// Resolves the authoritative transcript used for handoff payloads and destination
    /// migration. Prefer the structured transcript because historical/compacted rows
    /// can be absent from the mutable `items` suffix.
    @MainActor
    func resolvedHandoffSourceTranscript(
        for session: TabSession,
        upToItemID: UUID?
    ) -> AgentTranscript? {
        let hasStructuredTranscript = !session.transcript.turns.isEmpty

        if let upToItemID {
            if hasStructuredTranscript {
                return AgentTranscriptIO.isValidHandoffExportCutoffRowID(upToItemID, in: session.transcript)
                    ? session.transcript
                    : nil
            }

            let itemTranscript = fallbackHandoffTranscript(from: session.items)
            if AgentTranscriptIO.isValidHandoffExportCutoffRowID(upToItemID, in: itemTranscript) {
                return itemTranscript
            }

            return nil
        }

        if !hasStructuredTranscript, !session.items.isEmpty {
            return fallbackHandoffTranscript(from: session.items)
        }

        return session.transcript
    }

    /// Build transcript items prefix for the destination session (copies items up through upToItemID,
    /// forces streaming off, drops thinking items).
    @MainActor
    func buildHandoffTranscriptItems(
        sourceTranscript: AgentTranscript,
        upToItemID: UUID
    ) -> [AgentChatItem] {
        AgentTranscriptIO.buildHandoffTranscriptItems(from: sourceTranscript, upToRowID: upToItemID)
    }

    /// Compatibility helper for legacy callers/tests that only have live items.
    @MainActor
    func buildHandoffTranscriptItems(
        sourceItems: [AgentChatItem],
        upToItemID: UUID
    ) -> [AgentChatItem] {
        buildHandoffTranscriptItems(
            sourceTranscript: fallbackHandoffTranscript(from: sourceItems),
            upToItemID: upToItemID
        )
    }

    /// Handoff the current session to a new tab with transcript migration and deferred payload injection.
    /// Creates a duplicate tab, migrates transcript items up to the cutoff, sets the pending handoff
    /// payload (delivered on the destination tab's first user send), and switches to the new tab.
    ///
    /// - Returns: The destination tab ID on success.
    @MainActor
    @discardableResult
    func prepareHandoffToNewTab(
        upToItemID: UUID,
        destinationAgent: AgentProviderKind,
        destinationModelRaw: String,
        destinationReasoningEffortRaw: String?
    ) async throws -> UUID {
        guard let promptManager,
              let workspaceManager,
              let sourceTabID = currentTabID,
              let sourceSession = sessions[sourceTabID]
        else {
            throw AgentSessionError.noActiveWorkspace
        }

        guard let sourceTranscript = resolvedHandoffSourceTranscript(
            for: sourceSession,
            upToItemID: upToItemID
        ) else {
            throw AgentSessionError.invalidHandoffCutoff
        }

        // 1) Build the handoff payload from the same transcript universe used for migration.
        let payload = await buildHandoffPayload(
            sourceTabID: sourceTabID,
            sourceSession: sourceSession,
            sourceTranscript: sourceTranscript,
            upToItemID: upToItemID
        )
        let sourceTabName = workspaceManager.composeTabName(with: sourceTabID) ?? "Session"

        // 2) Build migrated transcript items (prefix copy up to cutoff, no thinking, no streaming)
        let migratedItems = buildHandoffTranscriptItems(
            sourceTranscript: sourceTranscript,
            upToItemID: upToItemID
        )

        // 3) Create a fork-duplicate tab in the background (copies selection, prompt,
        //    expansions, overrides, discover config, etc. but clears session bindings).
        guard let destTab = await promptManager.createBackgroundForkComposeTab(
            sourceTabID: sourceTabID,
            named: "\(sourceTabName) (handoff)"
        ) else {
            throw AgentSessionError.emptySession
        }
        let destTabID = destTab.id

        // 4) Clone Oracle/chat sessions before switching tabs
        var clonedActiveChatSessionID: UUID?
        if let oracleViewModel {
            do {
                _ = try await oracleViewModel.cloneChatSessions(fromTabID: sourceTabID, toTabID: destTabID)
                clonedActiveChatSessionID = workspaceManager.activeChatSessionID(forTabID: destTabID)
            } catch {
                print("[AgentVM] Warning: failed to clone chat sessions for handoff: \(error)")
            }
        }

        // 5) Create destination agent session with migrated transcript + pending payload
        let destSession = session(for: destTabID)
        destSession.selectedAgent = destinationAgent
        destSession.selectedModelRaw = destinationModelRaw
        destSession.selectedReasoningEffortRaw = destinationReasoningEffortRaw
        destSession.autoEditEnabled = sourceSession.autoEditEnabled
        destSession.replaceItems(migratedItems)
        destSession.hasSentFirstMessage = migratedItems.contains { $0.kind == .user }
        destSession.pendingHandoff = PendingHandoffState(
            payload: payload,
            createdAt: Date(),
            sourceItemID: upToItemID,
            defersProviderLockUntilSend: true,
            isStagedForSend: false
        )
        guard ensureSessionBoundToTab(destSession) != nil else {
            throw PersistentBindingMutationError.staleTransition
        }

        // 6) Persist destination session/tab mapping
        scheduleSave(for: destTabID)

        // 7) Switch to the destination tab, focus the cloned active Oracle chat if one
        //    exists, then update active bindings for the handoff session.
        await promptManager.switchComposeTab(destTabID)
        if let oracleViewModel,
           let clonedActiveChatSessionID
        {
            await oracleViewModel.focusSession(clonedActiveChatSessionID, forTab: destTabID)
        }
        updateBindingsFromSession(destSession)

        return destTabID
    }

    /// Builds a handoff transcript XML from the resolved source transcript using the shared
    /// priority-based budgeting policy from `AgentTranscriptIO.buildForkTranscriptXML`.
    /// Tool calls are dropped first, then intermediate assistant narration, then
    /// system/error context, and finally whole oldest essential turns if needed.
    private func buildForkTranscriptXML(
        from transcript: AgentTranscript,
        upToItemID: UUID? = nil,
        maxTranscriptItems: Int = 200,
        maxToolArgsCharacters: Int = 2000
    ) -> String {
        AgentTranscriptIO.buildForkTranscriptXML(
            from: transcript,
            upToRowID: upToItemID,
            maxTranscriptItems: maxTranscriptItems,
            maxToolArgsCharacters: maxToolArgsCharacters
        )
    }

    /// Compatibility wrapper for callers with a session; resolves historical rows against
    /// the structured transcript rather than the mutable working suffix.
    private func buildForkTranscriptXML(
        from source: TabSession,
        upToItemID: UUID? = nil,
        maxTranscriptItems: Int = 200,
        maxToolArgsCharacters: Int = 2000
    ) -> String {
        guard let transcript = resolvedHandoffSourceTranscript(for: source, upToItemID: upToItemID) else {
            return AgentTranscriptIO.buildForkTranscriptXML(
                from: .empty,
                upToRowID: nil,
                maxTranscriptItems: maxTranscriptItems,
                maxToolArgsCharacters: maxToolArgsCharacters
            )
        }
        return buildForkTranscriptXML(
            from: transcript,
            upToItemID: upToItemID,
            maxTranscriptItems: maxTranscriptItems,
            maxToolArgsCharacters: maxToolArgsCharacters
        )
    }

    /// Builds the file contents block for the fork payload.
    /// If the selection token count exceeds the cap, falls back to the formatted
    /// selection reply summary (same format as the manage_selection tool response).
    @MainActor
    private func buildForkFileContentsBlock(
        selection: StoredSelection,
        tokenCap: Int,
        lookupContext: WorkspaceLookupContext
    ) async -> String {
        guard let promptManager else { return "" }

        return await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: tokenCap,
            store: promptManager.workspaceFileContextStore,
            lookupContext: lookupContext,
            overTokenCapSummaryProvider: { [weak self] selection, lookupContext, codemapSnapshotBundle in
                guard let self, let mcp = mcpServer else { return nil }
                let reply = await mcp.buildTabSelectionReply(
                    from: selection,
                    includeBlocks: false,
                    display: .relative,
                    lookupContextOverride: lookupContext,
                    codemapSnapshotBundle: codemapSnapshotBundle
                )
                let summary = ToolOutputFormatter.formatSelectionReplyToString(reply)
                return """
                <selection_summary>
                \(summary)
                </selection_summary>
                """
            }
        )
    }
}
