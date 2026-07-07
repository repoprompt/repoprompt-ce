import Combine
import SwiftUI

/// Agent Mode view - a chat-style interface for long-running agent interactions
/// with per-tab session management, markdown message rendering, and tool call display
struct AgentModeView: View {
    @ObservedObject var windowState: WindowState
    let agentModeVM: AgentModeViewModel
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject private var workspaceManager: WorkspaceManagerViewModel

    @StateObject private var navigationController: AgentModeNavigationController
    @StateObject private var rootsSidebarStore: AgentWorkspaceRootsSidebarStore
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var currentTabID: UUID? {
        promptManager.activeComposeTabID
    }

    private var isSystemWorkspaceMode: Bool {
        workspaceManager.activeWorkspace?.isSystemWorkspace ?? true
    }

    init(
        windowState: WindowState,
        agentModeVM: AgentModeViewModel,
        promptManager: PromptViewModel
    ) {
        self.windowState = windowState
        self.agentModeVM = agentModeVM
        self.promptManager = promptManager
        _workspaceManager = ObservedObject(wrappedValue: windowState.workspaceManager)

        let isSystem = windowState.workspaceManager.activeWorkspace?.isSystemWorkspace ?? true
        _navigationController = StateObject(wrappedValue: AgentModeNavigationController(isSystemWorkspaceMode: isSystem))
        _rootsSidebarStore = StateObject(wrappedValue: AgentWorkspaceRootsSidebarStore(
            rootProjections: { windowState.workspaceFilesViewModel.visibleRootShellProjections },
            rootChanges: windowState.workspaceFilesViewModel.rootShellProjectionsChangedPublisher,
            gitContextLookup: { promptManager.gitViewModel.gitWorktreeContext(forStandardizedRootPath: $0) },
            gitContextChanges: promptManager.gitViewModel.gitWorktreeContextChanges,
            workspaceManager: windowState.workspaceManager,
            windowID: windowState.windowID
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            let fontPreset = fontScale.preset
            let sidebarMinWidth = AgentSidebarSizing.minWidth(for: fontPreset)
            let sidebarMaxWidth = AgentSidebarSizing.resolvedMaxWidth(for: proxy.size.width, preset: fontPreset)
            let sidebarIdealWidth = AgentSidebarSizing.resolvedIdealWidth(for: proxy.size.width, preset: fontPreset)

            NavigationSplitView(
                columnVisibility: $navigationController.columnVisibility,
                preferredCompactColumn: $navigationController.preferredColumn
            ) {
                // Sidebar column: Sessions list
                AgentModeSessionsSidebarView(
                    rootsStore: rootsSidebarStore,
                    agentModeVM: agentModeVM,
                    sidebarUI: agentModeVM.ui.sessionSidebar,
                    promptManager: promptManager,
                    apiSettingsVM: windowState.apiSettingsViewModel,
                    currentTabID: currentTabID,
                    onManageWorkspaces: {
                        NotificationCenter.default.post(
                            name: .showManageWorkspacesTab,
                            object: nil,
                            userInfo: ["windowID": windowState.windowID]
                        )
                    }
                )
                .navigationSplitViewColumnWidth(
                    min: sidebarMinWidth,
                    ideal: sidebarIdealWidth,
                    max: sidebarMaxWidth
                )
            } detail: {
                #if DEBUG
                    AgentModeDetailWithSidebarView(
                        agentModeVM: agentModeVM,
                        runtimeVM: agentModeVM.ui.runtimeMetrics.runtimeVM,
                        statusPillsUI: agentModeVM.ui.statusPills,
                        contextBuilderAgentVM: windowState.contextBuilderAgentViewModel,
                        oracleViewModel: windowState.oracleViewModel,
                        promptManager: promptManager,
                        workspaceSearchService: windowState.workspaceSearchService,
                        selectionCoordinator: windowState.selectionCoordinator,
                        stressHarness: windowState.agentChatStressHarness,
                        windowID: windowState.windowID,
                        currentTabID: currentTabID,
                        codexManagedLoginAction: codexManagedLoginAction
                    )
                    .environment(\.agentWindowIsFocused, windowState.isCurrentlyFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                    AgentModeDetailWithSidebarView(
                        agentModeVM: agentModeVM,
                        runtimeVM: agentModeVM.ui.runtimeMetrics.runtimeVM,
                        statusPillsUI: agentModeVM.ui.statusPills,
                        contextBuilderAgentVM: windowState.contextBuilderAgentViewModel,
                        oracleViewModel: windowState.oracleViewModel,
                        promptManager: promptManager,
                        workspaceSearchService: windowState.workspaceSearchService,
                        selectionCoordinator: windowState.selectionCoordinator,
                        windowID: windowState.windowID,
                        currentTabID: currentTabID,
                        codexManagedLoginAction: codexManagedLoginAction
                    )
                    .environment(\.agentWindowIsFocused, windowState.isCurrentlyFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            navigationController.onAppear(
                isSystem: isSystemWorkspaceMode,
                windowState: windowState,
                agentModeVM: agentModeVM
            )
        }
        .onDisappear {
            navigationController.onDisappear(windowState: windowState, agentModeVM: agentModeVM)
        }
        .onChange(of: isSystemWorkspaceMode) { _, isSystem in
            navigationController.onWorkspaceModeChanged(
                isSystem: isSystem,
                windowState: windowState,
                agentModeVM: agentModeVM
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .toggleRepoPromptNavigationSidebar)
        ) { note in
            if let id = note.userInfo?["windowID"] as? Int,
               id == windowState.windowID,
               !isSystemWorkspaceMode
            {
                toggleAgentSessionSidebar()
            }
        }
    }

    private func toggleAgentSessionSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if navigationController.columnVisibility == .detailOnly {
                navigationController.columnVisibility = .all
            } else {
                navigationController.columnVisibility = .detailOnly
            }
        }
    }

    private func codexManagedLoginAction(openURL: @MainActor @escaping (URL) -> Void) async throws -> Bool {
        try await windowState.apiSettingsViewModel.startCodexManagedChatgptLogin(openURL: openURL)
    }
}

// Sidebar views extracted to Components/AgentSessionsSidebarView.swift
// Transcript scroll types extracted to Components/AgentTranscriptScrollTypes.swift

struct AgentModeChatDetailView: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var transcriptUI: AgentTranscriptUIStore
    @ObservedObject var runInteractionUI: AgentRunInteractionUIStore
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let isContextBuilderQuestionPresented: Bool
    let oracleViewModel: OracleViewModel
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    #if DEBUG
        let stressHarness: AgentChatStressHarness?
    #endif
    let runtimeVM: AgentRuntimeSidebarViewModel
    let windowID: Int
    let currentTabID: UUID?
    let codexManagedLoginAction: CodexManagedLoginAction
    @Environment(\.agentWindowIsFocused) private var agentWindowIsFocused
    @ObservedObject private var workflowStore: AgentWorkflowStore = .shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    // MARK: - Consolidated Scroll State

    @State private var scrollViewState = AgentTranscriptScrollViewState()
    @StateObject private var scrollEngine = AgentTranscriptScrollEngine()

    // Non-grouped state
    @State private var resetTextFieldTrigger = false
    @State private var isTranscriptWindowExpanded = false
    @StateObject private var viewportRegistry = AgentTranscriptViewportRegistry()

    // MARK: - Computed Shims (bridge existing references to struct members)

    // These shims bridge existing references to struct members without renaming
    // every call site. They are removed as code migrates to coordinators.

    private var presentation: TranscriptPresentationViewState {
        get { scrollViewState.presentation }
        nonmutating set { scrollViewState.presentation = newValue }
    }

    private var attachment: FollowAttachmentState {
        get { scrollViewState.attachment }
        nonmutating set { scrollViewState.attachment = newValue }
    }

    private var bottomAffordance: AgentTranscriptBottomAffordanceState {
        get { scrollViewState.bottomAffordance }
        nonmutating set { scrollViewState.bottomAffordance = newValue }
    }

    private var pinnedMaintenance: PinnedMaintenanceState {
        get { scrollEngine.pinnedMaintenance }
        nonmutating set { scrollEngine.pinnedMaintenance = newValue }
    }

    private var smoothSend: SmoothSendEnvelopeState {
        get { scrollEngine.smoothSend }
        nonmutating set { scrollEngine.smoothSend = newValue }
    }

    private var rehydrate: RehydrateRestoreState {
        get { scrollEngine.rehydrate }
        nonmutating set { scrollEngine.rehydrate = newValue }
    }

    private var detachedSnapshot: DetachedViewportSnapshotState {
        get { scrollEngine.detachedSnapshot }
        nonmutating set { scrollEngine.detachedSnapshot = newValue }
    }

    private var detachedRebase: DetachedRebaseCaptureState {
        get { scrollEngine.detachedRebase }
        nonmutating set { scrollEngine.detachedRebase = newValue }
    }

    private var userScroll: UserScrollInteractionState {
        get { scrollEngine.userScroll }
        nonmutating set { scrollEngine.userScroll = newValue }
    }

    private var bottomScrollOutcome: BottomScrollOutcomeState {
        get { scrollEngine.bottomScrollOutcome }
        nonmutating set { scrollEngine.bottomScrollOutcome = newValue }
    }

    private var programmaticScrollGate: ProgrammaticScrollGate {
        get { scrollEngine.programmaticScrollGate }
        nonmutating set { scrollEngine.programmaticScrollGate = newValue }
    }

    private var pendingProgrammaticRestoreTargetID: AgentTranscriptViewportTargetID? {
        get { scrollEngine.pendingProgrammaticRestoreTargetID }
        nonmutating set { scrollEngine.pendingProgrammaticRestoreTargetID = newValue }
    }

    private var pendingProgrammaticRestoreAnchor: AgentTranscriptAnchor? {
        get { scrollEngine.pendingProgrammaticRestoreAnchor }
        nonmutating set { scrollEngine.pendingProgrammaticRestoreAnchor = newValue }
    }

    // 2a: TranscriptPresentationViewState shims
    private var scrollMetrics: AgentTranscriptScrollMetrics {
        scrollEngine.scrollMetrics
    }

    private var legacyIsNearBottom: Bool {
        get { presentation.legacyIsNearBottom }
        nonmutating set { presentation.legacyIsNearBottom = newValue }
    }

    private var didChatChange: Bool {
        get { presentation.didChatChange }
        nonmutating set { presentation.didChatChange = newValue }
    }

    private var transcriptScrollResetRevision: Int {
        get { presentation.transcriptScrollResetRevision }
        nonmutating set { presentation.transcriptScrollResetRevision = newValue }
    }

    private var activationRepaintRemountKey: AgentTranscriptRehydrateRetryKey? {
        get { presentation.activationRepaintRemountKey }
        nonmutating set { presentation.activationRepaintRemountKey = newValue }
    }

    private var activationRepaintRemountCount: Int {
        get { presentation.activationRepaintRemountCount }
        nonmutating set { presentation.activationRepaintRemountCount = newValue }
    }

    private var composerBottomInset: CGFloat {
        get { presentation.composerBottomInset }
        nonmutating set { presentation.composerBottomInset = newValue }
    }

    private var transcriptBottomClearance: CGFloat {
        get { presentation.transcriptBottomClearance }
        nonmutating set { presentation.transcriptBottomClearance = newValue }
    }

    private var showCompressedHistory: Bool {
        get { presentation.showCompressedHistory }
        nonmutating set { presentation.showCompressedHistory = newValue }
    }

    private var pendingCompressionRestoreStrategy: AgentTranscriptCompressionRestoreStrategy? {
        get { scrollEngine.pendingCompressionRestoreStrategy }
        nonmutating set { scrollEngine.pendingCompressionRestoreStrategy = newValue }
    }

    private var transcriptBlockExpansion: [String: Bool] {
        get { presentation.transcriptBlockExpansion }
        nonmutating set { presentation.transcriptBlockExpansion = newValue }
    }

    private var transcriptBlockDefaultExpansion: [String: Bool] {
        get { presentation.transcriptBlockDefaultExpansion }
        nonmutating set { presentation.transcriptBlockDefaultExpansion = newValue }
    }

    private var hasUserInteractedWithScroll: Bool {
        get { scrollEngine.hasUserInteractedWithScroll }
        nonmutating set { scrollEngine.hasUserInteractedWithScroll = newValue }
    }

    private var isUserInteractingWithScroll: Bool {
        get { scrollEngine.isUserInteractingWithScroll }
        nonmutating set { scrollEngine.isUserInteractingWithScroll = newValue }
    }

    // 2b: FollowAttachmentState shims
    private var isPinnedToLiveBottom: Bool {
        get { attachment.isPinnedToLiveBottom }
        nonmutating set { attachment.isPinnedToLiveBottom = newValue }
    }

    private var userDetachedAutoFollow: Bool {
        get { attachment.userDetachedAutoFollow }
        nonmutating set { attachment.userDetachedAutoFollow = newValue }
    }

    private var shouldRestorePinnedBottomAfterBlocker: Bool {
        get { attachment.shouldRestorePinnedBottomAfterBlocker }
        nonmutating set { attachment.shouldRestorePinnedBottomAfterBlocker = newValue }
    }

    private var manualDetachOverrideUntil: Date? {
        get { attachment.manualDetachOverrideUntil }
        nonmutating set { attachment.manualDetachOverrideUntil = newValue }
    }

    private var repinGraceState: RepinGraceState? {
        get { attachment.repinGraceState }
        nonmutating set { attachment.repinGraceState = newValue }
    }

    // 2c: PinnedMaintenanceState shims
    private var pinnedBottomMaintenanceGate: WorkItemGate {
        get { pinnedMaintenance.gate }
        nonmutating set { pinnedMaintenance.gate = newValue }
    }

    private var pinnedMaintenanceGeneration: UInt64 {
        pinnedMaintenance.generation
    }

    private var pendingPinnedMaintenanceRequest: AgentTranscriptPinnedMaintenanceRequest? {
        get { pinnedMaintenance.pendingRequest }
        nonmutating set { pinnedMaintenance.pendingRequest = newValue }
    }

    private var deferredPinnedMaintenanceRequestAfterSmoothSend: AgentTranscriptPinnedMaintenanceRequest? {
        get { pinnedMaintenance.deferredRequestAfterSmoothSend }
        nonmutating set { pinnedMaintenance.deferredRequestAfterSmoothSend = newValue }
    }

    private var pendingPinnedBottomSource: PinnedBottomRequestSource? {
        get { pendingPinnedMaintenanceRequest?.source }
        nonmutating set {
            guard let newValue else {
                pendingPinnedMaintenanceRequest = nil
                return
            }
            pendingPinnedMaintenanceRequest = pinnedMaintenance.makeRequest(source: newValue)
        }
    }

    private var deferredPinnedCorrectionAfterSmoothSend: PinnedBottomRequestSource? {
        get { deferredPinnedMaintenanceRequestAfterSmoothSend?.source }
        nonmutating set {
            guard let newValue else {
                deferredPinnedMaintenanceRequestAfterSmoothSend = nil
                return
            }
            deferredPinnedMaintenanceRequestAfterSmoothSend = pinnedMaintenance.makeRequest(source: newValue)
        }
    }

    private var pinnedTranscriptChangeSuppressionUntil: Date? {
        get { pinnedMaintenance.transcriptChangeSuppressionUntil }
        nonmutating set { pinnedMaintenance.transcriptChangeSuppressionUntil = newValue }
    }

    private var pinnedIdleTransitionManualDetachUntil: Date? {
        get { pinnedMaintenance.idleTransitionManualDetachUntil }
        nonmutating set { pinnedMaintenance.idleTransitionManualDetachUntil = newValue }
    }

    private var lastPinnedBottomRequestAt: Date? {
        get { pinnedMaintenance.lastRequestAt }
        nonmutating set { pinnedMaintenance.lastRequestAt = newValue }
    }

    private var lastBottomSettleAt: Date? {
        get { pinnedMaintenance.lastSettleAt }
        nonmutating set { pinnedMaintenance.lastSettleAt = newValue }
    }

    private var bottomClearanceSuppressionUntil: Date? {
        get { pinnedMaintenance.bottomClearanceSuppressionUntil }
        nonmutating set { pinnedMaintenance.bottomClearanceSuppressionUntil = newValue }
    }

    private var pinnedBottomProtectionUntil: Date? {
        get { pinnedMaintenance.protectionUntil }
        nonmutating set { pinnedMaintenance.protectionUntil = newValue }
    }

    private var lastTranscriptChangePinnedMaintenanceRevision: Int? {
        get { pinnedMaintenance.lastTranscriptChangeRevision }
        nonmutating set { pinnedMaintenance.lastTranscriptChangeRevision = newValue }
    }

    // 2d: SmoothSendEnvelopeState shims
    private var smoothPinnedSendState: SmoothPinnedSendState? {
        get { smoothSend.state }
        nonmutating set { smoothSend.state = newValue }
    }

    private var smoothPinnedSendLaunchGate: WorkItemGate {
        get { smoothSend.launchGate }
        nonmutating set { smoothSend.launchGate = newValue }
    }

    private var lastSeenUserMessageID: UUID? {
        get { smoothSend.lastSeenUserMessageID }
        nonmutating set { smoothSend.lastSeenUserMessageID = newValue }
    }

    // 2e: RehydrateRestoreState shims
    private var rehydrateRestorePhase: AgentTranscriptRehydrateRestorePhase {
        get { scrollEngine.rehydrate.phase }
        nonmutating set { scrollEngine.rehydrate.phase = newValue }
    }

    private var rehydrateLayoutPassToken: UInt64 {
        get { scrollEngine.rehydrate.layoutPassToken }
        nonmutating set { scrollEngine.rehydrate.layoutPassToken = newValue }
    }

    private var lastSettledRehydrateRetryKey: AgentTranscriptRehydrateRetryKey? {
        get { scrollEngine.rehydrate.lastSettledRetryKey }
        nonmutating set { scrollEngine.rehydrate.lastSettledRetryKey = newValue }
    }

    private var currentRehydrateLayoutSampleKey: AgentTranscriptRehydrateRetryKey? {
        get { scrollEngine.rehydrate.currentLayoutSampleKey }
        nonmutating set { scrollEngine.rehydrate.currentLayoutSampleKey = newValue }
    }

    // 2f: DetachedViewportSnapshotState shims
    private var topVisibleBlockID: String? {
        get { detachedSnapshot.topVisibleBlockID }
        nonmutating set { detachedSnapshot.topVisibleBlockID = newValue }
    }

    private var topVisibleBlockAnchor: AgentTranscriptAnchor? {
        get { detachedSnapshot.topVisibleBlockAnchor }
        nonmutating set { detachedSnapshot.topVisibleBlockAnchor = newValue }
    }

    private var topVisibleBlockMinY: CGFloat? {
        get { detachedSnapshot.topVisibleBlockMinY }
        nonmutating set { detachedSnapshot.topVisibleBlockMinY = newValue }
    }

    private var topVisibleViewportTargetID: AgentTranscriptViewportTargetID? {
        get { detachedSnapshot.topVisibleViewportTargetID }
        nonmutating set { detachedSnapshot.topVisibleViewportTargetID = newValue }
    }

    private var topVisibleViewportAnchor: AgentTranscriptAnchor? {
        get { detachedSnapshot.topVisibleViewportAnchor }
        nonmutating set { detachedSnapshot.topVisibleViewportAnchor = newValue }
    }

    private var topVisibleViewportSequenceIndex: Int? {
        get { detachedSnapshot.topVisibleViewportSequenceIndex }
        nonmutating set { detachedSnapshot.topVisibleViewportSequenceIndex = newValue }
    }

    private var topVisibleViewportFallbackBlockID: String? {
        get { detachedSnapshot.topVisibleViewportFallbackBlockID }
        nonmutating set { detachedSnapshot.topVisibleViewportFallbackBlockID = newValue }
    }

    private var topVisibleViewportMinY: CGFloat? {
        get { detachedSnapshot.topVisibleViewportMinY }
        nonmutating set { detachedSnapshot.topVisibleViewportMinY = newValue }
    }

    // 2g: DetachedRebaseCaptureState shims
    private var pendingDetachedAnchorChangeAnchor: AgentTranscriptAnchor? {
        get { detachedRebase.pendingAnchorChangeAnchor }
        nonmutating set { detachedRebase.pendingAnchorChangeAnchor = newValue }
    }

    private var pendingDetachedAnchorChangeBlockID: String? {
        get { detachedRebase.pendingAnchorChangeBlockID }
        nonmutating set { detachedRebase.pendingAnchorChangeBlockID = newValue }
    }

    private var detachedPresentationRevisionCheckToken: UInt64 {
        get { detachedRebase.presentationRevisionCheckToken }
        nonmutating set { detachedRebase.presentationRevisionCheckToken = newValue }
    }

    // 2h: UserScrollInteractionState shims
    private var currentUserScrollPhase: AgentTranscriptUserScrollPhase {
        get { userScroll.phase }
        nonmutating set { userScroll.phase = newValue }
    }

    private var activeUserScrollSession: AgentTranscriptUserScrollSession? {
        get { userScroll.session }
        nonmutating set { userScroll.session = newValue }
    }

    private var lastCompletedUserScrollSession: AgentTranscriptCompletedUserScrollSession? {
        get { userScroll.lastCompletedSession }
        nonmutating set { userScroll.lastCompletedSession = newValue }
    }

    private var lastUserScrollIntent: DetachedManualScrollDirection {
        get { userScroll.lastIntent }
        nonmutating set { userScroll.lastIntent = newValue }
    }

    private var lastUserScrollIntentAt: Date? {
        get { userScroll.lastIntentAt }
        nonmutating set { userScroll.lastIntentAt = newValue }
    }

    // 2i: BottomScrollOutcomeState shims
    private var pendingBottomScrollOutcome: PendingBottomScrollOutcome? {
        get { bottomScrollOutcome.pendingOutcome }
        nonmutating set { bottomScrollOutcome.pendingOutcome = newValue }
    }

    private var pendingBottomScrollOutcomeLastLayoutMutationAt: Date? {
        get { bottomScrollOutcome.lastLayoutMutationAt }
        nonmutating set { bottomScrollOutcome.lastLayoutMutationAt = newValue }
    }

    private var pendingBottomScrollOutcomeGenerationToken: UInt64 {
        get { bottomScrollOutcome.generationToken }
        nonmutating set { bottomScrollOutcome.generationToken = newValue }
    }

    private var deferredPendingBottomScrollOutcomeTask: Task<Void, Never>? {
        get { bottomScrollOutcome.deferredResolveTask }
        nonmutating set { bottomScrollOutcome.deferredResolveTask = newValue }
    }

    #if DEBUG
        private var stressTelemetryState: AgentChatStressTelemetryState {
            get { scrollEngine.stressTelemetryState }
            nonmutating set { scrollEngine.stressTelemetryState = newValue }
        }

        private var lastTelemetryDistanceToBottom: CGFloat? {
            get { scrollEngine.lastTelemetryDistanceToBottom }
            nonmutating set { scrollEngine.lastTelemetryDistanceToBottom = newValue }
        }

        @State private var visibleToolCardRenderStatesByID: [UUID: AgentToolCardRenderState] = [:]
    #endif
    @FocusState private var isInputFocused: Bool

    /// Reserved layout height for the running status row.
    /// Keeping this slot stable prevents scroll-jumps when status appears/disappears.
    private var runningIndicatorReservedHeight: CGFloat {
        fontPreset.scaledMetric(24)
    }

    private static let scrollButtonVisibilityThreshold: CGFloat = 24
    private static let detachDistanceThreshold: CGFloat = scrollButtonVisibilityThreshold
    private static let repinDistanceThreshold: CGFloat = 18
    private static let repinGraceDuration: TimeInterval = 0.9
    private static let smoothPinnedSendMaxDuration: TimeInterval = 8.0
    private static let stagedSmoothSendStabilizationDelay: TimeInterval = 0.12
    private static let pinnedBottomProtectionDuration: TimeInterval = 0.35
    private static let pinnedBottomProtectionNearBottomThreshold: CGFloat = 24
    private static let bottomBoundDetachedRearmInteractionMaxAge: TimeInterval = 0.8
    private static let bottomBoundDetachedRearmMeaningfulProgressThreshold: CGFloat = 12
    private static let bottomBoundDetachedRearmInvalidationThreshold: CGFloat = 8
    private static let actualBottomRepinDistanceThreshold: CGFloat = 1
    private static let stagedSmoothSendMinimumAnimationDistance: CGFloat = 64
    private static let pinnedTranscriptChangeUpwardIntentLeadWindow: TimeInterval = 0.35
    private static let pinnedIdleTransitionManualDetachLeadWindow: TimeInterval = 1.2
    private static let pinnedIdleTransitionManualDetachDistanceThreshold: CGFloat = 6
    private static let manualDetachOverrideDuration: TimeInterval = 0.75
    private static let userScrollIntentFreshnessDuration: TimeInterval = 0.4
    private static let manualScrollEffectDistanceThreshold: CGFloat = 24
    private static let manualScrollVisibleMinYEffectThreshold: CGFloat = 12
    private static let manualScrollProgressDistanceThreshold: CGFloat = 8
    private static let manualScrollProgressVisibleMinYThreshold: CGFloat = 6
    private static let scrollToBottomSuccessDistanceThreshold: CGFloat = scrollButtonVisibilityThreshold
    private static let bottomScrollOutcomeLayoutQuietPeriod: TimeInterval = 0.12
    private static let bottomScrollOutcomeMaxPendingAge: TimeInterval = 0.75
    private static let bottomScrollOutcomeContentHeightMutationThreshold: CGFloat = 2
    private static let bottomScrollOutcomeViewportHeightMutationThreshold: CGFloat = 2
    private static let restoreScrollResponsivenessSuppressionDuration: TimeInterval = 0.35
    private static let rawScrollHistoryAvailabilityEpsilon: CGFloat = 1
    private static let viewportSnapshotMinYEpsilon: CGFloat = 1.0

    private var isHigherPriorityScrollMaintenanceActive: Bool {
        smoothPinnedSendState != nil
            || pendingPinnedBottomSource != nil
            || deferredPinnedCorrectionAfterSmoothSend != nil
            || isRehydrateRestoreActive
            || pendingCompressionRestoreStrategy != nil
            || programmaticScrollGate.isInFlight
    }

    private var debugCurrentTabLabel: String {
        debugShortID(currentTabID)
    }

    private func debugShortID(_ uuid: UUID?) -> String {
        guard let uuid else { return "nil" }
        return String(uuid.uuidString.prefix(8))
    }

    private func debugDescription(for phase: AgentTranscriptRehydrateRestorePhase) -> String {
        switch phase {
        case .idle:
            "idle"
        case let .awaitingHydration(tabID, target):
            "awaiting(\(debugShortID(tabID)),target:\(target))"
        case let .awaitingLayout(tabID, presentationRevision, target):
            "awaitingLayout(\(debugShortID(tabID)),rev:\(presentationRevision),target:\(target))"
        case let .driving(tabID, presentationRevision, target):
            "driving(\(debugShortID(tabID)),rev:\(presentationRevision),target:\(target))"
        }
    }

    private func debugDescription(for intent: AgentTranscriptScrollIntent) -> String {
        switch intent {
        case let .bottom(animated, reason):
            "bottom(animated:\(animated),reason:\(reason))"
        case let .anchor(anchor, placement, animated, reason):
            "anchor(anchor:\(anchor),placement:\(placement),animated:\(animated),reason:\(reason))"
        case let .viewportTarget(targetID, placement, animated, reason):
            "viewportTarget(target:\(targetID),placement:\(placement),animated:\(animated),reason:\(reason))"
        }
    }

    #if DEBUG
        private func assertScrollStateInvariants(caller: String = #function) {
            assert(
                !(isPinnedToLiveBottom && userDetachedAutoFollow),
                "\(caller): pinned AND detached simultaneously"
            )

            if rehydrateRestorePhase == .idle {
                assert(
                    scrollEngine.rehydrate.coldRestoreStartedAt == nil,
                    "\(caller): cold restore timing set while restore is idle"
                )
            }

            if userDetachedAutoFollow, !isPinnedToLiveBottom {
                assert(
                    smoothPinnedSendState == nil,
                    "\(caller): smooth pinned send active while detached"
                )
            }

            if #available(macOS 15.0, *) {
                assert(
                    bottomAffordance.isNearBottom == (scrollMetrics.distanceToBottom <= Self.scrollButtonVisibilityThreshold),
                    "\(caller): modern near-bottom affordance out of sync with raw scroll metrics"
                )
            }

            if pendingBottomScrollOutcome == nil {
                assert(
                    deferredPendingBottomScrollOutcomeTask == nil,
                    "\(caller): deferred bottom outcome task active without a pending outcome"
                )
            }
        }
    #endif

    private func resetPinnedBottomRequestState() {
        pinnedMaintenance.reset()
    }

    private func invalidatePinnedMaintenance(
        _ reason: AgentTranscriptPinnedMaintenanceInvalidationReason
    ) {
        pinnedMaintenance.invalidate(reason: reason)
    }

    private func armPinnedTranscriptChangeSuppression(now: Date = Date()) {
        guard isPinnedToLiveBottom,
              !userDetachedAutoFollow,
              !isInteractionBlockerVisible,
              !isRehydrateRestoreActive
        else {
            return
        }
        pinnedTranscriptChangeSuppressionUntil = now.addingTimeInterval(Self.pinnedTranscriptChangeUpwardIntentLeadWindow)
    }

    private func clearPinnedTranscriptChangeSuppression() {
        pinnedTranscriptChangeSuppressionUntil = nil
    }

    private func armPinnedIdleTransitionManualDetach(now: Date = Date()) {
        guard isPinnedToLiveBottom,
              !userDetachedAutoFollow,
              !isInteractionBlockerVisible,
              !isRehydrateRestoreActive
        else {
            clearPinnedIdleTransitionManualDetach()
            return
        }
        pinnedIdleTransitionManualDetachUntil = now.addingTimeInterval(Self.pinnedIdleTransitionManualDetachLeadWindow)
    }

    private func clearPinnedIdleTransitionManualDetach() {
        pinnedIdleTransitionManualDetachUntil = nil
    }

    private func armManualDetachOverride(now: Date = Date()) {
        manualDetachOverrideUntil = now.addingTimeInterval(Self.manualDetachOverrideDuration)
    }

    private func clearManualDetachOverride() {
        manualDetachOverrideUntil = nil
    }

    private func isManualDetachOverrideActive(now: Date = Date()) -> Bool {
        let isActive = AgentTranscriptManualDetachOverridePolicy.isActive(
            until: manualDetachOverrideUntil,
            now: now
        )
        if !isActive, manualDetachOverrideUntil != nil {
            manualDetachOverrideUntil = nil
        }
        return isActive
    }

    private func isPinnedIdleTransitionManualDetachActive(now: Date = Date()) -> Bool {
        guard let pinnedIdleTransitionManualDetachUntil else { return false }
        guard now < pinnedIdleTransitionManualDetachUntil else {
            self.pinnedIdleTransitionManualDetachUntil = nil
            return false
        }
        return true
    }

    private func isPinnedTowardHistoryManualIntentFresh(now: Date = Date()) -> Bool {
        guard let lastUserScrollIntentAt,
              now.timeIntervalSince(lastUserScrollIntentAt) <= Self.userScrollIntentFreshnessDuration
        else {
            return false
        }
        return lastUserScrollIntent == .towardHistory
    }

    private func shouldSuppressPinnedMaintenanceForFreshIdleBoundaryUpwardIntent(now: Date = Date()) -> Bool {
        isPinnedIdleTransitionManualDetachActive(now: now)
            && isPinnedTowardHistoryManualIntentFresh(now: now)
    }

    private func isPinnedTranscriptChangeSuppressionActive(now: Date = Date()) -> Bool {
        guard let pinnedTranscriptChangeSuppressionUntil else { return false }
        guard now < pinnedTranscriptChangeSuppressionUntil else {
            self.pinnedTranscriptChangeSuppressionUntil = nil
            return false
        }
        return true
    }

    private func shouldSuppressPinnedTranscriptChangeMaintenance(
        source: PinnedBottomRequestSource,
        now: Date = Date()
    ) -> Bool {
        switch source {
        case .transcriptChangeWhilePinned, .waitingStateChange, .busyStateChange, .bottomClearanceChange:
            break
        default:
            return false
        }
        guard isPinnedToLiveBottom,
              !isUserInteractingWithScroll,
              !isInteractionBlockerVisible,
              !isRehydrateRestoreActive,
              isPinnedTranscriptChangeSuppressionActive(now: now)
              || shouldSuppressPinnedMaintenanceForFreshIdleBoundaryUpwardIntent(now: now)
        else {
            return false
        }
        if let lastUserScrollIntentAt,
           now.timeIntervalSince(lastUserScrollIntentAt) <= Self.userScrollIntentFreshnessDuration,
           lastUserScrollIntent == .towardLiveBottom
        {
            clearPinnedTranscriptChangeSuppression()
            return false
        }
        return true
    }

    private func isPinnedBottomProtectionActive(now: Date = Date()) -> Bool {
        guard let pinnedBottomProtectionUntil else { return false }
        guard now < pinnedBottomProtectionUntil else {
            self.pinnedBottomProtectionUntil = nil
            return false
        }
        return true
    }

    private func armPinnedBottomProtection(now: Date = Date()) {
        pinnedBottomProtectionUntil = now.addingTimeInterval(Self.pinnedBottomProtectionDuration)
    }

    private func clearPinnedBottomProtection() {
        pinnedBottomProtectionUntil = nil
    }

    private func clearPendingTranscriptChangePinnedMaintenance() {
        let hasClearablePendingRequest = switch pendingPinnedBottomSource {
        case .transcriptChangeWhilePinned?, .waitingStateChange?, .busyStateChange?, .bottomClearanceChange?:
            true
        default:
            false
        }
        let hasClearableDeferredRequest = switch deferredPinnedCorrectionAfterSmoothSend {
        case .transcriptChangeWhilePinned?, .waitingStateChange?, .busyStateChange?, .bottomClearanceChange?:
            true
        default:
            false
        }
        guard hasClearablePendingRequest || hasClearableDeferredRequest else { return }
        invalidatePinnedMaintenance(.staleSuppression)
    }

    private func noteUserScrollIntent(_ direction: DetachedManualScrollDirection, now: Date = Date()) {
        guard direction != .unknown else { return }
        lastUserScrollIntent = direction
        lastUserScrollIntentAt = now
        if isPinnedToLiveBottom,
           !userDetachedAutoFollow,
           !isInteractionBlockerVisible,
           !isRehydrateRestoreActive
        {
            switch direction {
            case .towardHistory:
                armPinnedTranscriptChangeSuppression(now: now)
                armPinnedIdleTransitionManualDetach(now: now)
                cancelPinnedProgrammaticScrollForFreshUpwardIntent()
            case .towardLiveBottom:
                clearPinnedTranscriptChangeSuppression()
                clearPinnedIdleTransitionManualDetach()
            case .unknown:
                break
            }
        }
        handleDetachedAutoFollowManualDirection(direction)
    }

    private func handleDetachedAutoFollowManualDirection(_ direction: DetachedManualScrollDirection) {
        guard userDetachedAutoFollow,
              !isPinnedToLiveBottom
        else {
            return
        }
        guard direction == .towardHistory else { return }
        setCurrentAutoFollowArmingState(.disarmedAfterManualDetach)
    }

    private func shouldForceRepinDetachedAtActualBottom(metrics: AgentTranscriptScrollMetrics) -> Bool {
        guard !isManualDetachOverrideActive() else {
            return false
        }
        return AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: makeScrollRuntimeState(distanceToBottom: metrics.distanceToBottom),
            actualBottomDistanceThreshold: Self.actualBottomRepinDistanceThreshold
        )
    }

    private func shouldRepinDetachedAfterUserScrollSession(
        _ session: AgentTranscriptUserScrollSession,
        finalMetrics: AgentTranscriptScrollMetrics
    ) -> Bool {
        guard !isManualDetachOverrideActive() else {
            return false
        }
        guard userDetachedAutoFollow,
              !isPinnedToLiveBottom,
              !isInteractionBlockerVisible,
              !isRehydrateRestoreActive,
              pendingCompressionRestoreStrategy == nil,
              finalMetrics.distanceToBottom <= Self.repinDistanceThreshold
        else {
            return false
        }
        let madeMeaningfulProgressTowardLiveBottom = AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .towardLiveBottom,
            progress: makeViewportProgress(
                baselineDistanceToBottom: session.baselineMetrics.distanceToBottom,
                baselineVisibleMinY: session.baselineMetrics.visibleMinY,
                currentDistanceToBottom: finalMetrics.distanceToBottom,
                currentVisibleMinY: finalMetrics.visibleMinY
            ),
            distanceThreshold: Self.bottomBoundDetachedRearmMeaningfulProgressThreshold,
            visibleMinYThreshold: Self.bottomBoundDetachedRearmMeaningfulProgressThreshold
        )
        if currentAutoFollowArmingState == .armed {
            return session.baselineMetrics.distanceToBottom > Self.repinDistanceThreshold
                && madeMeaningfulProgressTowardLiveBottom
        }
        guard currentAutoFollowArmingState == .disarmedAfterManualDetach else {
            return false
        }
        let startedNearBottom = session.baselineMetrics.distanceToBottom <= Self.scrollButtonVisibilityThreshold
        return startedNearBottom || madeMeaningfulProgressTowardLiveBottom
    }

    private func repinDetachedAfterUserScrollSession(proxy: ScrollViewProxy) {
        pinToLiveBottom()
        beginRepinGrace(reason: .nearBottomReengaged)
        requestScroll(proxy, intent: .bottom(animated: false, reason: .nearBottomReengaged), immediate: true)
    }

    private func forceRepinDetachedAtActualBottom(proxy: ScrollViewProxy) {
        pinToLiveBottom()
        beginRepinGrace(reason: .nearBottomReengaged)
        requestScroll(proxy, intent: .bottom(animated: false, reason: .nearBottomReengaged), immediate: true)
    }

    private var shouldBreakPinnedProgrammaticScrollForFreshUpwardIntent: Bool {
        isPinnedToLiveBottom
            && !userDetachedAutoFollow
            && !isInteractionBlockerVisible
            && !isRehydrateRestoreActive
            && isPinnedTranscriptChangeSuppressionActive()
    }

    private func cancelPinnedProgrammaticScrollForFreshUpwardIntent() {
        guard shouldBreakPinnedProgrammaticScrollForFreshUpwardIntent else { return }
        clearPendingTranscriptChangePinnedMaintenance()
        interruptSmoothPinnedSend(reason: "freshPinnedUpwardWheel")
        cancelPendingScrollWork()
    }

    @discardableResult
    private func maybeEagerlyDetachForSuppressedPinnedTranscriptChange() -> Bool {
        guard shouldBreakPinnedProgrammaticScrollForFreshUpwardIntent,
              !isUserInteractingWithScroll,
              scrollMetrics.distanceToBottom > Self.detachDistanceThreshold
        else {
            return false
        }
        clearPendingTranscriptChangePinnedMaintenance()
        cancelPendingScrollWork()
        detachFromLiveBottom(markUserDetached: true)
        clearPinnedTranscriptChangeSuppression()
        return true
    }

    private func shouldDetachFromLiveBottomAfterRunBecomesIdle(
        hasTowardHistoryManualIntent: Bool,
        progress: AgentTranscriptViewportProgress,
        now: Date = Date()
    ) -> Bool {
        AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
            runtime: makeScrollRuntimeState(distanceToBottom: progress.currentDistanceToBottom),
            idleTransitionArmed: isPinnedIdleTransitionManualDetachActive(now: now),
            hasTowardHistoryManualIntent: hasTowardHistoryManualIntent,
            progress: progress,
            minimumEscapeDistance: Self.pinnedIdleTransitionManualDetachDistanceThreshold
        )
    }

    private func shouldDetachFromLiveBottomAfterRunBecomesIdle(
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics,
        now: Date = Date()
    ) -> Bool {
        shouldDetachFromLiveBottomAfterRunBecomesIdle(
            hasTowardHistoryManualIntent: isPinnedTowardHistoryManualIntentFresh(now: now),
            progress: makeViewportProgress(
                baselineDistanceToBottom: oldMetrics.distanceToBottom,
                baselineVisibleMinY: oldMetrics.visibleMinY,
                currentDistanceToBottom: newMetrics.distanceToBottom,
                currentVisibleMinY: newMetrics.visibleMinY
            ),
            now: now
        )
    }

    private func resolveIdleBoundaryDetachIfNeeded(
        currentMetrics: AgentTranscriptScrollMetrics,
        now: Date = Date()
    ) -> Bool {
        guard isPinnedToLiveBottom,
              !userDetachedAutoFollow,
              !isInteractionBlockerVisible,
              !isRehydrateRestoreActive,
              !programmaticScrollGate.isInFlight,
              isPinnedIdleTransitionManualDetachActive(now: now),
              let resolvedProgress = AgentTranscriptIdleBoundaryProgressResolver.resolve(
                  activeSession: activeUserScrollSession,
                  lastCompletedSession: lastCompletedUserScrollSession,
                  currentMetrics: currentMetrics,
                  now: now,
                  freshnessWindow: Self.pinnedIdleTransitionManualDetachLeadWindow
              ),
              shouldDetachFromLiveBottomAfterRunBecomesIdle(
                  hasTowardHistoryManualIntent: resolvedProgress.hasTowardHistoryManualIntent,
                  progress: resolvedProgress.progress,
                  now: now
              )
        else {
            return false
        }
        invalidatePinnedMaintenance(.idleBoundaryDetachResolved)
        cancelPendingScrollWork()
        detachFromLiveBottom(markUserDetached: true)
        clearPinnedIdleTransitionManualDetach()
        return true
    }

    private func clearLiveTranscriptViewportCaptureState(shouldResetDetachedRebaseTracking: Bool) {
        clearPendingDetachedSettleCaptureState()
        topVisibleBlockID = nil
        topVisibleBlockAnchor = nil
        topVisibleBlockMinY = nil
        clearTrackedViewportCandidateState()
        viewportRegistry.clearBlockFrames()
        detachedPresentationRevisionCheckToken &+= 1
        if shouldResetDetachedRebaseTracking {
            resetDetachedRebaseTracking()
        }
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func mergedPinnedBottomSource(
        _ current: PinnedBottomRequestSource?,
        with incoming: PinnedBottomRequestSource
    ) -> PinnedBottomRequestSource {
        guard let current else { return incoming }
        if incoming.priority < current.priority {
            return incoming
        }
        if incoming.priority == current.priority {
            return incoming
        }
        return current
    }

    private func queueDeferredPinnedCorrection(_ source: PinnedBottomRequestSource) {
        deferredPinnedCorrectionAfterSmoothSend = mergedPinnedBottomSource(
            deferredPinnedCorrectionAfterSmoothSend,
            with: source == .smoothSend ? .bottomClearanceChange : source
        )
    }

    private func flushDeferredPinnedCorrectionAfterSmoothSendIfNeeded(proxy: ScrollViewProxy) {
        let deferredSource = deferredPinnedCorrectionAfterSmoothSend
        guard let source = deferredSource ?? (!isNearBottom ? .bottomClearanceChange : nil) else { return }
        deferredPinnedCorrectionAfterSmoothSend = nil
        #if DEBUG
            if isStressHarnessEnabled {
                noteStressHarness("Flushing deferred pinned correction: source=\(source) distance=\(Int(scrollMetrics.distanceToBottom)) nearBottom=\(isNearBottom)")
            }
        #endif
        noteSmoothPinnedSendCorrectiveScroll()
        if smoothPinnedSendState != nil,
           source == .transcriptChangeWhilePinned,
           isPinnedToLiveBottom,
           !isNearBottom,
           !programmaticScrollGate.isInFlight,
           !isInteractionBlockerVisible,
           !isUserInteractingWithScroll,
           !isRehydrateRestoreActive
        {
            pendingPinnedBottomSource = nil
            pinnedBottomMaintenanceGate.cancel()
            #if DEBUG
                if isStressHarnessEnabled {
                    noteStressHarness("Direct corrective catch-up: source=\(source) distance=\(Int(scrollMetrics.distanceToBottom))")
                }
            #endif
            let correctiveRequest = pinnedMaintenance.makeRequest(source: .transcriptChangeWhilePinned)
            notePinnedBottomRequest()
            requestScroll(
                proxy,
                intent: .bottom(animated: false, reason: .transcriptChangeWhilePinned),
                immediate: true,
                pinnedMaintenanceGeneration: correctiveRequest.generation
            )
            return
        }
        requestPinnedLiveBottom(proxy: proxy, source: source)
    }

    private func notePinnedBottomRequest() {
        lastPinnedBottomRequestAt = Date()
    }

    private func requestPinnedLiveBottomForTranscriptChange(proxy: ScrollViewProxy) {
        let presentationRevision = currentTranscriptPresentationRevision
        guard lastTranscriptChangePinnedMaintenanceRevision != presentationRevision else { return }
        lastTranscriptChangePinnedMaintenanceRevision = presentationRevision
        requestPinnedLiveBottom(proxy: proxy, source: .transcriptChangeWhilePinned)
    }

    private func isPinnedMaintenanceReason(_ reason: AgentTranscriptScrollReason) -> Bool {
        switch reason {
        case .transcriptChangeWhilePinned, .waitingStateChange, .busyStateChange, .bottomClearanceChange, .nearBottomReengaged, .userSendWhilePinned, .userSendWhileDetached:
            true
        default:
            false
        }
    }

    private func cancelDetachedPresentationRevisionCheck() {
        detachedPresentationRevisionCheckToken &+= 1
    }

    private func shouldSuppressGeometryDrivenPinnedDetach(now: Date = Date()) -> Bool {
        if pendingPinnedBottomSource != nil || deferredPinnedCorrectionAfterSmoothSend != nil || programmaticScrollGate.isInFlight {
            return true
        }
        if let lastPinnedBottomRequestAt, now.timeIntervalSince(lastPinnedBottomRequestAt) <= 0.25 {
            return true
        }
        if let lastBottomSettleAt, now.timeIntervalSince(lastBottomSettleAt) <= 0.25 {
            return true
        }
        return false
    }

    private func shouldCoalesceVisibleBlockChurnDuringStagedSmoothSend(now: Date = Date()) -> Bool {
        guard smoothPinnedSendState?.phase == .preservingBottomBeforeAnimation else { return false }
        if pendingPinnedBottomSource == .transcriptChangeWhilePinned {
            return true
        }
        if programmaticScrollGate.isInFlight {
            return true
        }
        if let lastBottomSettleAt,
           now.timeIntervalSince(lastBottomSettleAt) < Self.stagedSmoothSendStabilizationDelay
        {
            return true
        }
        return false
    }

    private func shouldCoalesceTranscriptChangePinnedMaintenanceDuringStagedSmoothSend(now: Date = Date()) -> Bool {
        guard smoothPinnedSendState?.phase == .preservingBottomBeforeAnimation else { return false }
        if pendingPinnedBottomSource == .transcriptChangeWhilePinned {
            return true
        }
        if programmaticScrollGate.isInFlight {
            return true
        }
        if let lastPinnedBottomRequestAt,
           now.timeIntervalSince(lastPinnedBottomRequestAt) < Self.stagedSmoothSendStabilizationDelay
        {
            return true
        }
        return false
    }

    private func requestPinnedLiveBottom(
        proxy: ScrollViewProxy,
        source: PinnedBottomRequestSource
    ) {
        guard isPinnedToLiveBottom,
              !isInteractionBlockerVisible,
              !isUserInteractingWithScroll,
              !isRehydrateRestoreActive
        else {
            return
        }
        if shouldSuppressPinnedTranscriptChangeMaintenance(source: source) {
            clearPendingTranscriptChangePinnedMaintenance()
            if maybeEagerlyDetachForSuppressedPinnedTranscriptChange() {
                return
            }
            return
        }
        if shouldSuppressPinnedMaintenanceWhileExplicitBottomOutcomePending(source: source) {
            #if DEBUG
                if isStressHarnessEnabled {
                    noteStressHarness(
                        "Suppressed pinned maintenance during explicit bottom outcome: source=\(source) distance=\(Int(scrollMetrics.distanceToBottom))"
                    )
                }
            #endif
            return
        }
        if source == .smoothSend {
            let smoothSendRequest = pinnedMaintenance.makeRequest(source: source)
            pinnedBottomMaintenanceGate.cancel()
            pendingPinnedMaintenanceRequest = nil
            notePinnedBottomRequest()
            requestScroll(
                proxy,
                intent: .bottom(animated: true, reason: source.scrollReason),
                immediate: true,
                pinnedMaintenanceGeneration: smoothSendRequest.generation
            )
            return
        }

        if let pendingBottomScrollOutcome {
            let observingPinnedFollow = isPinnedToLiveBottom
                && !userDetachedAutoFollow
                && pendingBottomScrollOutcome.tabID == currentTabID
                && pendingBottomScrollOutcome.source == .pinnedFollowMaintenance
            let pinnedFollowNeedsCorrectiveRetry = observingPinnedFollow
                && pendingBottomScrollOutcome.didExecute
                && scrollMetrics.distanceToBottom > Self.scrollToBottomSuccessDistanceThreshold
            if !pinnedFollowNeedsCorrectiveRetry {
                return
            }
        }

        if let suppressionUntil = bottomClearanceSuppressionUntil,
           source == .bottomClearanceChange,
           Date() < suppressionUntil,
           isNearBottom
        {
            return
        }

        if source == .transcriptChangeWhilePinned,
           shouldCoalesceTranscriptChangePinnedMaintenanceDuringStagedSmoothSend()
        {
            #if DEBUG
                if isStressHarnessEnabled {
                    noteStressHarness(
                        "Coalesced transcript-change pinned maintenance during staged send: pending=\(String(describing: pendingPinnedBottomSource)) inFlight=\(programmaticScrollGate.isInFlight)"
                    )
                }
            #endif
            return
        }

        let isAnimatingSmoothPinnedSend = smoothPinnedSendState?.phase == .animatingToBottom
            && isSmoothPinnedSendActive(for: currentTabID)
        if isAnimatingSmoothPinnedSend, programmaticScrollGate.isInFlight {
            queueDeferredPinnedCorrection(source)
            return
        }

        let mergedSource = mergedPinnedBottomSource(pendingPinnedBottomSource, with: source)
        let mergedRequest = pinnedMaintenance.makeRequest(source: mergedSource)
        pendingPinnedMaintenanceRequest = mergedRequest
        let shouldFlushImmediately = mergedSource != .smoothSend
            && !isAnimatingSmoothPinnedSend
            && !programmaticScrollGate.isInFlight
        if shouldFlushImmediately {
            pendingPinnedMaintenanceRequest = nil
            bottomClearanceSuppressionUntil = Date().addingTimeInterval(0.20)
            #if DEBUG
                if isStressHarnessEnabled {
                    noteStressHarness("Pinned maintenance flushed immediately: source=\(mergedSource) distance=\(Int(scrollMetrics.distanceToBottom))")
                }
            #endif
            notePinnedBottomRequest()
            requestScroll(
                proxy,
                intent: .bottom(animated: false, reason: mergedSource.scrollReason),
                immediate: true,
                pinnedMaintenanceGeneration: mergedRequest.generation
            )
            return
        }
        pinnedBottomMaintenanceGate.schedule(after: mergedSource.gateDelay) {
            let requestToFlush = pendingPinnedMaintenanceRequest ?? pinnedMaintenance.makeRequest(source: mergedSource)
            let sourceToFlush = requestToFlush.source
            guard isPinnedToLiveBottom,
                  !isInteractionBlockerVisible,
                  !isUserInteractingWithScroll,
                  !isRehydrateRestoreActive,
                  pinnedMaintenance.isCurrent(requestToFlush)
            else {
                pendingPinnedMaintenanceRequest = nil
                return
            }
            let isAnimatingSmoothPinnedSend = smoothPinnedSendState?.phase == .animatingToBottom
                && isSmoothPinnedSendActive(for: currentTabID)
            if isAnimatingSmoothPinnedSend, programmaticScrollGate.isInFlight {
                queueDeferredPinnedCorrection(sourceToFlush)
                pendingPinnedMaintenanceRequest = nil
                return
            }
            pendingPinnedMaintenanceRequest = nil
            bottomClearanceSuppressionUntil = Date().addingTimeInterval(0.20)
            notePinnedBottomRequest()
            requestScroll(
                proxy,
                intent: .bottom(animated: false, reason: sourceToFlush.scrollReason),
                immediate: true,
                pinnedMaintenanceGeneration: requestToFlush.generation
            )
        }
    }

    private func resetDetachedRebaseTracking() {
        detachedRebase.candidateKey = nil
        detachedRebase.candidateFirstSeenAt = nil
        detachedRebase.lastRestoreKey = nil
        detachedRebase.missingLiveAuthorityCount = 0
    }

    private func debugDescription(for strategy: AgentTranscriptCompressionRestoreStrategy?) -> String {
        guard let strategy else { return "nil" }
        switch strategy {
        case .preserveBottom:
            return "preserveBottom"
        case let .restoreAnchor(anchor):
            return "restoreAnchor(\(anchor))"
        }
    }

    #if DEBUG
        private func debugConsoleStateSummary() -> String {
            let topAnchor = effectiveStressTopVisibleAnchorDescription ?? "nil"
            let topTarget = topVisibleViewportTargetID.map(String.init(describing:)) ?? "nil"
            let pendingSource = pendingPinnedBottomSource.map(String.init(describing:)) ?? "nil"
            let deferredSource = deferredPinnedCorrectionAfterSmoothSend.map(String.init(describing:)) ?? "nil"
            let lastIntent = stressTelemetryState.lastScrollIntentReason ?? "nil"
            let lastSettled = stressTelemetryState.lastSettledBottomReason ?? "nil"
            return "tab=\(debugShortID(currentTabID)) pinned=\(isPinnedToLiveBottom) detached=\(userDetachedAutoFollow) nearBottom=\(isNearBottom) distance=\(Int(scrollMetrics.distanceToBottom)) canHistory=\(canScrollTowardHistory) canBottom=\(canScrollTowardLiveBottom) interacting=\(isUserInteractingWithScroll) userPhase=\(currentUserScrollPhase.rawValue) sessionActive=\(activeUserScrollSession != nil) inFlight=\(programmaticScrollGate.isInFlight) blocker=\(isInteractionBlockerVisible) topAnchor=\(topAnchor) topTarget=\(topTarget) pendingSource=\(pendingSource) deferredSource=\(deferredSource) lastIntent=\(lastIntent) lastSettled=\(lastSettled) rows=\(renderedTranscriptRows.count) blocks=\(visibleTranscriptBlocks.count)"
        }

        private func debugConsoleLog(_ event: String, details: @autoclosure () -> String = "") {
            guard false else { return } // Logs disabled
            let resolvedDetails = details().trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = debugConsoleStateSummary()
            if resolvedDetails.isEmpty {
                print("[AgentTranscriptScroll] \(event) | \(summary)")
            } else {
                print("[AgentTranscriptScroll] \(event) | \(resolvedDetails) | \(summary)")
            }
        }

        private func shouldEmitConsoleDebugLog(for event: String) -> Bool {
            switch event {
            case "onAppear",
                 "onChange currentTabID",
                 "onChange transcriptItems",
                 "onChange visibleTranscriptBlocks",
                 "onChange restoreSignal",
                 "onChange rehydrateRestorePhase",
                 "scrollGeometry",
                 "scrollPhase",
                 "requestScroll suppressed during rehydrate",
                 "requestScroll scheduled",
                 "requestScroll executing",
                 "requestScroll settled",
                 "requestScroll aborted tab mismatch",
                 "requestScroll aborted revision gate",
                 "cancelPendingScrollWork":
                true
            default:
                false
            }
        }
    #endif

    private func debugLog(_ event: String, details: @autoclosure () -> String = "") {
        #if DEBUG
            guard shouldEmitConsoleDebugLog(for: event) else { return }
            debugConsoleLog(event, details: details())
        #else
            _ = event
            _ = details()
        #endif
    }

    private var isStressHarnessEnabled: Bool {
        #if DEBUG
            stressHarness != nil
        #else
            false
        #endif
    }

    private var shouldShowStressForceDetachButton: Bool {
        #if DEBUG
            guard let stressHarness else { return false }
            return stressHarness.configuration.showOverlay && !userDetachedAutoFollow
        #else
            false
        #endif
    }

    private func noteStressHarness(_ message: String) {
        #if DEBUG
            stressHarness?.note(message)
        #endif
    }

    private var stressHarnessCatastrophicJumpThresholdPoints: CGFloat? {
        #if DEBUG
            stressHarness?.configuration.catastrophicJumpThresholdPoints
        #else
            nil
        #endif
    }

    private var stressHarnessCatastrophicHistoricalExposureBlockThreshold: Int? {
        #if DEBUG
            stressHarness?.configuration.catastrophicHistoricalExposureBlockThreshold
        #else
            nil
        #endif
    }

    private var markdownFileLinkOpener: MarkdownFileLinkOpener {
        MarkdownFileLinkOpener { target in
            await promptManager.fileManager.openFileForMarkdownLink(target)
        }
    }

    private var supportsAutoScroll: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private var baseInputBarHeight: CGFloat {
        ComposerChrome<EmptyView, EmptyView>.baseBarHeight + AgentInputBar.footerHeight
    }

    private var isNearBottom: Bool {
        if #available(macOS 15.0, *) {
            return bottomAffordance.isNearBottom
        }
        return legacyIsNearBottom
    }

    private var isRehydrateRestoreActive: Bool {
        rehydrateRestorePhase.isActive && rehydrateRestorePhase.tabID == currentTabID
    }

    private var isScrollResponsivenessSuppressed: Bool {
        guard let suppressedUntil = scrollEngine.rehydrate.scrollResponsivenessSuppressedUntil else { return false }
        return Date() < suppressedUntil
    }

    private var transcriptSnapshot: AgentTranscriptUISnapshot {
        let snapshot = transcriptUI.snapshot
        guard snapshot.currentTabID == currentTabID else { return .empty }
        return snapshot
    }

    private var runInteractionSnapshot: AgentRunInteractionUISnapshot {
        let snapshot = runInteractionUI.snapshot
        guard snapshot.currentTabID == currentTabID else { return .empty }
        return snapshot
    }

    private var statusPillsSnapshot: AgentStatusPillsSnapshot {
        let snapshot = statusPillsUI.snapshot
        guard snapshot.currentTabID == currentTabID else { return .empty }
        return snapshot
    }

    private var selectedWorkflow: AgentWorkflowDefinition? {
        statusPillsSnapshot.selectedWorkflow
    }

    private var transcriptPresentation: AgentTranscriptPresentationSnapshot {
        transcriptSnapshot.presentation
    }

    private var isCurrentTranscriptPresentationHydrated: Bool {
        transcriptSnapshot.isHydrated
    }

    private var currentTranscriptPresentationRevision: Int {
        transcriptSnapshot.presentationRevision
    }

    private var restoreSignal: AgentTranscriptRestoreSignal {
        .init(
            tabID: transcriptPresentation.tabID,
            bindingsHydrated: transcriptPresentation.bindingsHydrated,
            presentationRevision: transcriptPresentation.revision
        )
    }

    private var shouldShowStreamingHistoryIndicator: Bool {
        canRevealCompressedHistory && !usesCompressedHistory
    }

    private var canRevealCompressedHistory: Bool {
        transcriptPresentation.archivedHistoryState.hasArchivedHistory
    }

    private var usesCompressedHistory: Bool {
        transcriptPresentation.isCompressedHistoryRevealed && canRevealCompressedHistory
    }

    private var hasTranscriptContent: Bool {
        !transcriptPresentation.visibleRows.isEmpty || transcriptPresentation.archivedHistoryState.hasArchivedHistory
    }

    private var dynamicSummaryLockTargetTurnID: UUID? {
        transcriptPresentation.metadata.dynamicSummaryLockTargetTurnID
    }

    private var visibleTranscriptBlocks: [AgentTranscriptRenderBlock] {
        transcriptPresentation.visibleBlocks
    }

    private func transcriptBlockSupportsExpansion(_ block: AgentTranscriptRenderBlock) -> Bool {
        switch block.kind {
        case .activityCluster:
            !block.rows.isEmpty
        case .groupedHistory:
            !(block.groupedHistory?.sections.isEmpty ?? true)
        case .request, .collapsedHistoryRange, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
            false
        }
    }

    private func persistedTranscriptBlockExpansion(for block: AgentTranscriptRenderBlock) -> Bool {
        guard transcriptBlockSupportsExpansion(block) else { return false }
        return transcriptBlockExpansion[block.id] ?? (block.defaultPresentation == .expanded)
    }

    private func isDynamicToolSummaryBlock(_ block: AgentTranscriptRenderBlock) -> Bool {
        block.kind == .activityCluster || block.kind == .groupedHistory
    }

    private func isDynamicSummaryLockTarget(_ block: AgentTranscriptRenderBlock) -> Bool {
        block.turnID == dynamicSummaryLockTargetTurnID
            && isDynamicToolSummaryBlock(block)
    }

    private func isTranscriptBlockExpanded(
        _ block: AgentTranscriptRenderBlock,
        respectDynamicSummaryLock: Bool = true
    ) -> Bool {
        if respectDynamicSummaryLock,
           isDynamicSummaryLockTarget(block)
        {
            return false
        }
        guard transcriptBlockSupportsExpansion(block) else { return false }
        return persistedTranscriptBlockExpansion(for: block)
    }

    private func expandedDynamicToolSummaryBlockCount(assumeUnlocked: Bool = false) -> Int {
        visibleTranscriptBlocks.reduce(into: 0) { count, block in
            guard isDynamicToolSummaryBlock(block) else { return }
            if isTranscriptBlockExpanded(block, respectDynamicSummaryLock: !assumeUnlocked) {
                count += 1
            }
        }
    }

    private func renderedRows(for block: AgentTranscriptRenderBlock) -> [AgentChatItem] {
        switch block.kind {
        case .activityCluster:
            return isTranscriptBlockExpanded(block) ? block.rows : []
        case .groupedHistory:
            guard isTranscriptBlockExpanded(block), let groupedHistory = block.groupedHistory else { return [] }
            return groupedHistory.sections.flatMap { section in
                section.childBlocks.flatMap { renderedRows(for: $0) }
            }
        case .request, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
            return block.rows
        case .collapsedHistoryRange:
            return []
        }
    }

    private var renderedTranscriptRows: [AgentChatItem] {
        visibleTranscriptBlocks.flatMap(renderedRows(for:))
    }

    private func transcriptRenderMetadata(for rows: [AgentChatItem]) -> AgentTranscriptPresentationMetadata {
        let snapshotMetadata = transcriptPresentation.metadata
        let latestContextBuilderCall = rows.last(where: { item in
            item.kind == .toolCall && normalizedToolCardName(item.toolName) == "context_builder"
        })
        let latestContextBuilderResult = rows.last(where: { item in
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
        let mostRecentEditID = rows.last(where: isAutoExpandableEditToolResult)?.id
        return .init(
            latestUserMessageID: snapshotMetadata.latestUserMessageID,
            latestTurnID: snapshotMetadata.latestTurnID,
            dynamicSummaryLockTargetTurnID: snapshotMetadata.dynamicSummaryLockTargetTurnID,
            recentAssistantItemIDs: snapshotMetadata.recentAssistantItemIDs,
            activeContextBuilderCallItemID: activeContextBuilderCallID,
            activeContextBuilderResultItemID: activeContextBuilderResultID,
            mostRecentEditItemID: mostRecentEditID
        )
    }

    private func transcriptRenderMetadata(for blocks: [AgentTranscriptRenderBlock]) -> AgentTranscriptPresentationMetadata {
        transcriptRenderMetadata(for: blocks.flatMap(renderedRows(for:)))
    }

    private var renderedTranscriptRowIDs: Set<UUID> {
        Set(renderedTranscriptRows.map(\.id))
    }

    private var detachedViewportTrackingMode: AgentDetachedViewportTrackingMode {
        guard userDetachedAutoFollow || isUserInteractingWithScroll || isStressHarnessEnabled else {
            return .off
        }
        guard activeUserScrollSession != nil
            || detachedRestoreRowTrackingTargetID != nil
            || isStressHarnessEnabled
        else {
            return .blockOnly
        }
        let trackedBlockIDs = detachedViewportTrackedBlockIDs
        return trackedBlockIDs.isEmpty ? .blockOnly : .targetedRows(trackedBlockIDs)
    }

    private var shouldTrackDetachedViewportCandidates: Bool {
        detachedViewportTrackingMode.shouldTrackCandidates
    }

    private var detachedViewportTrackedBlockIDs: Set<String> {
        var blockIDs: Set<String> = []
        if let topVisibleBlockID {
            blockIDs.insert(topVisibleBlockID)
        }
        if let topVisibleViewportFallbackBlockID {
            blockIDs.insert(topVisibleViewportFallbackBlockID)
        }
        if let pendingDetachedAnchorChangeBlockID {
            blockIDs.insert(pendingDetachedAnchorChangeBlockID)
        }
        if let restoreTargetID = detachedRestoreRowTrackingTargetID,
           let blockID = resolveVisibleBlockID(containing: restoreTargetID)
        {
            blockIDs.insert(blockID)
        }
        if blockIDs.isEmpty,
           let firstVisibleBlockID = visibleTranscriptBlocks.first?.id
        {
            blockIDs.insert(firstVisibleBlockID)
        }
        return blockIDs.intersection(visibleTranscriptBlockIDs)
    }

    private var detachedRestoreRowTrackingTargetID: AgentTranscriptViewportTargetID? {
        guard userDetachedAutoFollow,
              !isPinnedToLiveBottom,
              let explicitTargetID = pendingProgrammaticRestoreTargetID,
              case .row = explicitTargetID
        else {
            return nil
        }
        return explicitTargetID
    }

    private func clearTrackedViewportCandidateState() {
        topVisibleViewportTargetID = nil
        topVisibleViewportAnchor = nil
        topVisibleViewportSequenceIndex = nil
        topVisibleViewportFallbackBlockID = nil
        topVisibleViewportMinY = nil
        viewportRegistry.clearViewportCandidates()
    }

    private var visibleTranscriptBlockIDs: Set<String> {
        Set(visibleTranscriptBlocks.map(\.id))
    }

    private func shouldUpdateViewportMinY(_ current: CGFloat?, to next: CGFloat?) -> Bool {
        switch (current, next) {
        case (nil, nil):
            false
        case let (current?, next?):
            abs(current - next) >= Self.viewportSnapshotMinYEpsilon
        default:
            true
        }
    }

    private var canScrollTowardHistory: Bool {
        let effectiveTopVisibleBlockID = userDetachedAutoFollow
            ? (topVisibleViewportFallbackBlockID ?? topVisibleBlockID)
            : topVisibleBlockID
        return AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
            firstVisibleBlockID: visibleTranscriptBlocks.first?.id,
            effectiveTopVisibleBlockID: effectiveTopVisibleBlockID,
            rawVisibleMinY: nil,
            fallbackVisibleMinY: scrollMetrics.visibleMinY,
            epsilon: Self.rawScrollHistoryAvailabilityEpsilon
        )
    }

    private var canScrollTowardLiveBottom: Bool {
        userDetachedAutoFollow
            && !isPinnedToLiveBottom
            && scrollMetrics.distanceToBottom > Self.scrollToBottomSuccessDistanceThreshold
    }

    private var currentAutoFollowArmingState: AgentModeViewModel.AgentTranscriptAutoFollowArmingState {
        guard let currentTabID else {
            return .armed
        }
        let followBindingState = transcriptSnapshot.followBindingState
        guard followBindingState.tabID == currentTabID else {
            return .armed
        }
        return followBindingState.armingState
    }

    private var isDetachedAutoFollowRepinArmed: Bool {
        currentAutoFollowArmingState == .armed
    }

    private func setCurrentAutoFollowArmingState(_ state: AgentModeViewModel.AgentTranscriptAutoFollowArmingState) {
        guard let currentTabID,
              transcriptSnapshot.followBindingState.armingState != state
        else {
            return
        }
        agentModeVM.setTranscriptAutoFollowArmingState(tabID: currentTabID, state: state)
    }

    private func makeScrollRuntimeState(distanceToBottom: CGFloat? = nil) -> AgentTranscriptScrollRuntimeState {
        AgentTranscriptScrollRuntimeState(
            armingState: currentAutoFollowArmingState,
            isPinnedToLiveBottom: isPinnedToLiveBottom,
            isDetachedFromLiveBottom: userDetachedAutoFollow,
            isUserInteractingWithScroll: isUserInteractingWithScroll,
            isInteractionBlocked: isInteractionBlockerVisible,
            isRehydrateRestoreActive: isRehydrateRestoreActive,
            isProgrammaticScrollInFlight: programmaticScrollGate.isInFlight,
            canScrollTowardHistory: canScrollTowardHistory,
            canScrollTowardLiveBottom: canScrollTowardLiveBottom,
            distanceToBottom: distanceToBottom ?? scrollMetrics.distanceToBottom
        )
    }

    private var scrollRuntimeState: AgentTranscriptScrollRuntimeState {
        makeScrollRuntimeState()
    }

    private func makeViewportProgress(
        baselineDistanceToBottom: CGFloat,
        baselineVisibleMinY: CGFloat,
        currentDistanceToBottom: CGFloat? = nil,
        currentVisibleMinY: CGFloat? = nil
    ) -> AgentTranscriptViewportProgress {
        AgentTranscriptViewportProgress(
            baselineDistanceToBottom: baselineDistanceToBottom,
            currentDistanceToBottom: currentDistanceToBottom ?? scrollMetrics.distanceToBottom,
            baselineVisibleMinY: baselineVisibleMinY,
            currentVisibleMinY: currentVisibleMinY ?? scrollMetrics.visibleMinY
        )
    }

    private var workingTranscriptBlockIDs: Set<String> {
        Set(transcriptPresentation.workingBlocks.map(\.id))
    }

    private var firstWorkingBlockAnchor: AgentTranscriptAnchor? {
        transcriptPresentation.workingBlocks.first?.primaryAnchor
    }

    private var latestTranscriptUserItem: AgentChatItem? {
        transcriptPresentation.workingRows.last(where: { $0.kind == .user })
    }

    private var latestTranscriptUserMessageID: UUID? {
        latestTranscriptUserItem?.id
    }

    private var pendingApprovalID: UUID? {
        runInteractionSnapshot.pendingApproval?.id
    }

    private var pendingMCPElicitationID: UUID? {
        runInteractionSnapshot.pendingMCPElicitationRequest?.id
    }

    private var pendingApplyEditsReviewID: UUID? {
        runInteractionSnapshot.pendingApplyEditsReview?.id
    }

    private var isInteractionBlockerVisible: Bool {
        pendingApprovalID != nil || pendingMCPElicitationID != nil || pendingApplyEditsReviewID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content area with floating input bar
            ZStack(alignment: .bottom) {
                // Background layer: scroll view + fixed spacer for the base bar
                VStack(spacing: 0) {
                    chatTranscript
                    Color.clear
                        .frame(height: baseInputBarHeight)
                }

                // Floating input bar
                AgentInputBar(
                    agentModeVM: agentModeVM,
                    composerUI: agentModeVM.ui.composer,
                    statusPillsUI: agentModeVM.ui.statusPills,
                    oracleViewModel: oracleViewModel,
                    promptManager: promptManager,
                    workspaceSearchService: workspaceSearchService,
                    selectionCoordinator: selectionCoordinator,
                    runtimeVM: runtimeVM,
                    windowID: windowID,
                    currentTabID: currentTabID,
                    resetTextFieldTrigger: $resetTextFieldTrigger,
                    composerBottomInset: Binding(
                        get: { composerBottomInset },
                        set: { composerBottomInset = $0 }
                    ),
                    transcriptBottomClearance: Binding(
                        get: { transcriptBottomClearance },
                        set: { transcriptBottomClearance = $0 }
                    ),
                    isFocused: _isInputFocused
                )
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Chat Transcript

    private var chatTranscript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    versionedScrollableContent(proxy: proxy, viewportHeight: geometry.size.height)

                    VStack(spacing: 10) {
                        #if DEBUG
                            if shouldShowStressForceDetachButton {
                                Button(action: {
                                    handleStressForceDetach(proxy: proxy)
                                }) {
                                    Image(systemName: "arrow.up.left.circle.fill")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                        .foregroundColor(.accentColor)
                                        .transition(.scale)
                                }
                                .buttonStyle(SmallRoundButtonStyle())
                                .hoverTooltip("Force detach for stress validation")
                                .accessibilityIdentifier("agentStress.forceDetach")
                            }
                        #endif

                        // Commented out: "fix scrollview" button (disabled in agent mode chat)
                        // Button(action: {
                        // 	handleScrollViewResetButtonTap(proxy: proxy)
                        // }) {
                        // 	Image(systemName: "hammer.circle.fill")
                        // 		.resizable()
                        // 		.frame(width: 24, height: 24)
                        // 		.foregroundColor(.accentColor)
                        // }
                        // .buttonStyle(SmallRoundButtonStyle(size: 24, iconSize: 12))
                        // .hoverTooltip("Reset scroll view to fix stuck scrolling", .top)
                        // .accessibilityIdentifier("agentTranscript.resetScrollView")

                        if shouldShowScrollToBottomButton {
                            Button(action: {
                                handleBottomButtonTap(proxy: proxy)
                            }) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.accentColor)
                                    .transition(.scale)
                            }
                            .buttonStyle(SmallRoundButtonStyle(size: 24, iconSize: 12))
                            .hoverTooltip("Scroll to bottom")
                            .accessibilityIdentifier("agentTranscript.scrollToBottom")
                        }
                    }
                    .padding(.trailing, 28)
                    .padding(.bottom, 32 + composerBottomInset)
                }
                .animation(.easeInOut, value: shouldShowScrollToBottomButton)
                .onAppear {
                    if let currentTabID {
                        agentModeVM.setCompressedHistoryVisibility(tabID: currentTabID, isRevealed: showCompressedHistory)
                        agentModeVM.setTranscriptWindowExpanded(tabID: currentTabID, isExpanded: isTranscriptWindowExpanded)
                    }
                    debugLog("onAppear", details: "visibleBlocks=\(visibleTranscriptBlocks.count) rows=\(renderedTranscriptRows.count)")
                    syncTranscriptBlockExpansion(for: visibleTranscriptBlocks)
                    publishGroupingSnapshot()
                    publishStressTelemetrySnapshot()
                    lastSeenUserMessageID = latestTranscriptUserMessageID
                    applyStoredTranscriptViewportState(for: currentTabID)
                    armRehydrateRestore(for: currentTabID)
                    _ = advanceRehydrateRestoreIfNeeded(proxy: proxy)
                    #if DEBUG
                        assertScrollStateInvariants()
                    #endif
                }
                .onDisappear {
                    clearPinnedTranscriptChangeSuppression()
                    clearPinnedIdleTransitionManualDetach()
                    clearManualDetachOverride()
                    cancelScrollResponsivenessObservations()
                    cancelAllScheduledScrollWork()
                    currentUserScrollPhase = .idle
                    activeUserScrollSession = nil
                    #if DEBUG
                        assertScrollStateInvariants()
                    #endif
                }
                .onChange(of: transcriptPresentation) { oldSnapshot, newSnapshot in
                    handleTranscriptPresentationChange(
                        from: oldSnapshot,
                        to: newSnapshot,
                        proxy: proxy
                    )
                }
                .onChange(of: runInteractionSnapshot.isWaitingForInstruction) { _, _ in
                    guard isPinnedToLiveBottom, !isInteractionBlockerVisible, !isUserInteractingWithScroll else { return }
                    requestPinnedLiveBottom(
                        proxy: proxy,
                        source: .waitingStateChange
                    )
                }
                .onChange(of: runInteractionSnapshot.isAgentBusy) { _, busy in
                    if busy {
                        guard isPinnedToLiveBottom,
                              !userDetachedAutoFollow,
                              !isInteractionBlockerVisible,
                              !isRehydrateRestoreActive,
                              !isUserInteractingWithScroll
                        else {
                            return
                        }
                        requestPinnedLiveBottom(
                            proxy: proxy,
                            source: .busyStateChange
                        )
                    }
                }
                .onChange(of: runInteractionSnapshot.runState.isActive) { wasActive, isActive in
                    if wasActive, !isActive {
                        clearPendingTranscriptChangePinnedMaintenance()
                        interruptSmoothPinnedSend(reason: "runStateBecameIdle")
                        let now = Date()
                        armPinnedIdleTransitionManualDetach(now: now)
                        if resolveIdleBoundaryDetachIfNeeded(currentMetrics: scrollMetrics, now: now) {
                            return
                        }
                        if activeUserScrollSession == nil {
                            clearPinnedIdleTransitionManualDetach()
                        }
                        if isPinnedToLiveBottom,
                           !userDetachedAutoFollow,
                           !isInteractionBlockerVisible,
                           !isUserInteractingWithScroll,
                           !isRehydrateRestoreActive,
                           scrollMetrics.distanceToBottom > Self.scrollToBottomSuccessDistanceThreshold
                        {
                            requestPinnedLiveBottom(
                                proxy: proxy,
                                source: .bottomClearanceChange
                            )
                        }
                        return
                    }
                    clearPinnedIdleTransitionManualDetach()
                    guard !wasActive, isActive else { return }
                    let expandedDynamicBlockCount = expandedDynamicToolSummaryBlockCount(assumeUnlocked: true)
                    guard expandedDynamicBlockCount > 0 else { return }
                    #if DEBUG
                        if isStressHarnessEnabled {
                            noteStressHarness("Run-active summary collapse: expandedDynamicBlocks=\(expandedDynamicBlockCount) smoothPhase=\(String(describing: smoothPinnedSendState?.phase)) inFlight=\(programmaticScrollGate.isInFlight)")
                        }
                    #endif
                    if smoothPinnedSendState?.phase == .preservingBottomBeforeAnimation {
                        markSmoothPinnedSendLayoutMutation("runStateBecameActive")
                    }
                    guard isPinnedToLiveBottom,
                          !userDetachedAutoFollow,
                          !isInteractionBlockerVisible,
                          !isUserInteractingWithScroll,
                          !isRehydrateRestoreActive
                    else {
                        return
                    }
                    if smoothPinnedSendState?.phase == .animatingToBottom {
                        interruptSmoothPinnedSend(reason: "runStateBecameActive")
                    }
                    requestPinnedLiveBottom(
                        proxy: proxy,
                        source: .transcriptChangeWhilePinned
                    )
                }
                .onChange(of: transcriptBottomClearance) { _, _ in
                    guard isPinnedToLiveBottom, !isInteractionBlockerVisible, !isUserInteractingWithScroll else { return }
                    requestPinnedLiveBottom(
                        proxy: proxy,
                        source: .bottomClearanceChange
                    )
                }
                .onChange(of: isInteractionBlockerVisible) { _, visible in
                    if visible {
                        handleInteractionBlockerPresented()
                    } else {
                        restorePinnedBottomAfterBlockerIfNeeded(proxy: proxy)
                    }
                }
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: AgentChatStressHarness.forceDetachRequestedNotification)) { notification in
                        guard let stressHarness,
                              notification.object as AnyObject === stressHarness else { return }
                        handleStressForceDetach(proxy: proxy)
                    }
                #endif
                    .onChange(of: currentTabID) { oldTabID, newTabID in
                        debugLog("onChange currentTabID", details: "old=\(debugShortID(oldTabID)) new=\(debugShortID(newTabID))")
                        #if DEBUG
                        #endif
                        invalidatePinnedMaintenance(.tabChanged)
                        cancelAllScheduledScrollWork()
                        cancelScrollResponsivenessObservations()
                        clearPinnedTranscriptChangeSuppression()
                        clearPinnedIdleTransitionManualDetach()
                        clearManualDetachOverride()
                        resetPinnedBottomRequestState()
                        showCompressedHistory = false
                        isTranscriptWindowExpanded = false
                        if let oldTabID {
                            agentModeVM.setCompressedHistoryVisibility(tabID: oldTabID, isRevealed: false)
                            agentModeVM.setTranscriptWindowExpanded(tabID: oldTabID, isExpanded: false)
                        }
                        if let newTabID {
                            agentModeVM.setCompressedHistoryVisibility(tabID: newTabID, isRevealed: false)
                            agentModeVM.setTranscriptWindowExpanded(tabID: newTabID, isExpanded: false)
                        }
                        pendingCompressionRestoreStrategy = nil
                        transcriptBlockExpansion.removeAll()
                        transcriptBlockDefaultExpansion.removeAll()
                        hasUserInteractedWithScroll = false
                        isUserInteractingWithScroll = false
                        repinGraceState = nil
                        lastTranscriptChangePinnedMaintenanceRevision = nil
                        _ = applyScrollMetrics(AgentTranscriptScrollMetrics())
                        legacyIsNearBottom = false
                        lastSeenUserMessageID = nil
                        interruptSmoothPinnedSend(reason: "tabChange")
                        transcriptScrollResetRevision &+= 1
                        scrollEngine.rehydrate.coldRestoreStartedAt = nil
                        clearLiveTranscriptViewportCaptureState(shouldResetDetachedRebaseTracking: true)
                        applyStoredTranscriptViewportState(for: newTabID)
                        armRehydrateRestore(for: newTabID)
                        _ = advanceRehydrateRestoreIfNeeded(proxy: proxy)
                        #if DEBUG
                            assertScrollStateInvariants()
                        #endif
                    }
                    .onChange(of: restoreSignal) { oldSignal, newSignal in
                        debugLog(
                            "onChange restoreSignal",
                            details: "oldTab=\(debugShortID(oldSignal.tabID)) newTab=\(debugShortID(newSignal.tabID)) oldHydrated=\(oldSignal.bindingsHydrated) newHydrated=\(newSignal.bindingsHydrated) oldRev=\(oldSignal.presentationRevision) newRev=\(newSignal.presentationRevision)"
                        )
                        if oldSignal.tabID == newSignal.tabID,
                           oldSignal.presentationRevision != newSignal.presentationRevision,
                           smoothPinnedSendState?.phase == .preservingBottomBeforeAnimation,
                           activeStressStreamingAssistantItem != nil
                        {
                            markSmoothPinnedSendLayoutMutation("presentationRevisionChangedWhileStreaming")
                        }
                        if let remountKey = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
                            oldSignal: oldSignal,
                            newSignal: newSignal,
                            currentTabID: currentTabID,
                            rehydratePhase: rehydrateRestorePhase,
                            lastRemountKey: activationRepaintRemountKey,
                            remountCount: activationRepaintRemountCount,
                            layoutPassToken: rehydrateLayoutPassToken
                        ) {
                            remountTranscriptForActivationRepaint(key: remountKey)
                        }
                        _ = advanceRehydrateRestoreIfNeeded(proxy: proxy)
                    }
                    .onChange(of: rehydrateRestorePhase) { oldPhase, newPhase in
                        debugLog("onChange rehydrateRestorePhase", details: "old=\(debugDescription(for: oldPhase)) new=\(debugDescription(for: newPhase))")
                        guard oldPhase.isActive, !newPhase.isActive else { return }
                        applyPendingCompressionStrategy(proxy: proxy)
                    }
                    .onChange(of: showCompressedHistory) { _, isRevealed in
                        if let currentTabID {
                            agentModeVM.setCompressedHistoryVisibility(tabID: currentTabID, isRevealed: isRevealed)
                        }
                        applyPendingCompressionStrategy(proxy: proxy)
                    }
            }
        }
    }

    private func handleTranscriptPresentationChange(
        from oldSnapshot: AgentTranscriptPresentationSnapshot,
        to newSnapshot: AgentTranscriptPresentationSnapshot,
        proxy: ScrollViewProxy
    ) {
        debugLog(
            "onChange transcriptPresentation",
            details: "oldRev=\(oldSnapshot.revision) newRev=\(newSnapshot.revision) oldBlocks=\(oldSnapshot.visibleBlocks.count) newBlocks=\(newSnapshot.visibleBlocks.count) oldRows=\(oldSnapshot.visibleRows.count) newRows=\(newSnapshot.visibleRows.count)"
        )

        let visiblePresentationChanged = newSnapshot.hasVisiblePresentationDelta(comparedTo: oldSnapshot)
        let visibleBlocksChanged = oldSnapshot.visibleBlocks != newSnapshot.visibleBlocks
        let visibleRowsChanged = oldSnapshot.visibleRows != newSnapshot.visibleRows

        guard visiblePresentationChanged else {
            return
        }

        if showCompressedHistory != newSnapshot.isCompressedHistoryRevealed {
            showCompressedHistory = newSnapshot.isCompressedHistoryRevealed
        }
        if isTranscriptWindowExpanded != newSnapshot.isTranscriptWindowExpanded {
            isTranscriptWindowExpanded = newSnapshot.isTranscriptWindowExpanded
        }

        syncTranscriptBlockExpansion(for: newSnapshot.visibleBlocks)
        publishGroupingSnapshot()
        publishStressTelemetrySnapshot()

        let latestUserMessageID = newSnapshot.metadata.latestUserMessageID
        let didReceiveNewUserMessage = latestUserMessageID != nil
            && latestUserMessageID != oldSnapshot.metadata.latestUserMessageID
            && latestUserMessageID != lastSeenUserMessageID

        if smoothPinnedSendState?.phase == .preservingBottomBeforeAnimation {
            markSmoothPinnedSendLayoutMutation("presentationChanged")
        }

        if didReceiveNewUserMessage {
            lastSeenUserMessageID = latestUserMessageID
            if let latestUserMessageID,
               let userItem = newSnapshot.workingRows.last(where: { $0.id == latestUserMessageID })
               ?? newSnapshot.visibleRows.last(where: { $0.id == latestUserMessageID }),
               isPinnedToLiveBottom,
               !userDetachedAutoFollow,
               !isInteractionBlockerVisible,
               !isUserInteractingWithScroll,
               !isRehydrateRestoreActive
            {
                if beginSmoothPinnedSend(for: userItem) {
                    requestPinnedLiveBottom(proxy: proxy, source: .smoothSend)
                    scheduleStagedSmoothPinnedSendLaunchIfNeeded(proxy: proxy)
                } else {
                    requestPinnedLiveBottomForTranscriptChange(proxy: proxy)
                }
            } else if userDetachedAutoFollow,
                      !isPinnedToLiveBottom,
                      !isInteractionBlockerVisible,
                      !isRehydrateRestoreActive
            {
                pinToLiveBottom()
                requestScroll(
                    proxy,
                    intent: .bottom(animated: false, reason: .userSendWhileDetached),
                    immediate: true
                )
            }
        }

        if visibleBlocksChanged, shouldCoalesceVisibleBlockChurnDuringStagedSmoothSend() {
            markSmoothPinnedSendLayoutMutation("visibleBlockChurn")
        }

        if isPinnedToLiveBottom,
           !userDetachedAutoFollow,
           !isInteractionBlockerVisible,
           !isUserInteractingWithScroll,
           !isRehydrateRestoreActive,
           visibleBlocksChanged || visibleRowsChanged
        {
            requestPinnedLiveBottomForTranscriptChange(proxy: proxy)
        }

        _ = advanceRehydrateRestoreIfNeeded(proxy: proxy)
    }

    @ViewBuilder
    private func versionedScrollableContent(proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        if #available(macOS 15.0, *) {
            modernScrollableContent(proxy: proxy, viewportHeight: viewportHeight)
        } else {
            legacyScrollableContent(proxy: proxy, viewportHeight: viewportHeight)
        }
    }

    @available(macOS 15.0, *)
    private func modernScrollableContent(proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        // Keep the ScrollView identity stable across pinned/detached transitions.
        modernScrollableContentBase(proxy: proxy, viewportHeight: viewportHeight)
    }

    @available(macOS 15.0, *)
    private func modernScrollableContentBase(proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        ScrollView {
            messageListContent(viewportHeight: viewportHeight, proxy: proxy)
        }
        .id(transcriptScrollResetRevision)
        .accessibilityIdentifier("agentTranscript.scrollView")
        .coordinateSpace(name: "AgentTranscriptScrollSpace")
        .transaction { txn in
            if didChatChange { txn.disablesAnimations = true }
        }
        .onScrollGeometryChange(for: AgentTranscriptScrollMetrics.self, of: { geometry in
            scrollMetrics(from: geometry)
        }, action: { _, newMetrics in
            let oldMetrics = applyScrollMetrics(newMetrics)
            recordRehydrateLayoutSampleIfNeeded(metrics: newMetrics)
            recordPendingBottomScrollOutcomeLayoutMutationIfNeeded(oldMetrics: oldMetrics, newMetrics: newMetrics)
            recordUserScrollProgressIfNeeded(oldMetrics: oldMetrics, newMetrics: newMetrics)
            recordScrollGeometryTransition(proxy: proxy, oldMetrics: oldMetrics, newMetrics: newMetrics)
            if isRehydrateRestoreActive {
                finishRehydrateRestoreIfSettled()
                return
            }
            if !runInteractionSnapshot.runState.isActive,
               resolveIdleBoundaryDetachIfNeeded(currentMetrics: newMetrics)
            {
                return
            }
            guard let session = activeUserScrollSession else { return }
            guard !programmaticScrollGate.isInFlight else { return }
            guard !isInteractionBlockerVisible else { return }
            if AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
                runtime: makeScrollRuntimeState(distanceToBottom: newMetrics.distanceToBottom),
                latestManualIntent: session.latestIntent,
                progress: makeViewportProgress(
                    baselineDistanceToBottom: session.baselineMetrics.distanceToBottom,
                    baselineVisibleMinY: session.baselineMetrics.visibleMinY,
                    currentDistanceToBottom: newMetrics.distanceToBottom,
                    currentVisibleMinY: newMetrics.visibleMinY
                ),
                minimumViewportEscapeDistance: Self.detachDistanceThreshold,
                suppressGeometryDetach: shouldSuppressGeometryDrivenPinnedDetach(),
                suppressRepinGraceDetach: shouldSuppressRepinGraceDetach(newMetrics: newMetrics)
            ) {
                detachFromLiveBottom(markUserDetached: true)
            }
        })
        .onScrollPhaseChange { oldPhase, newPhase, context in
            debugLog("scrollPhase", details: "old=\(oldPhase) new=\(newPhase)")
            currentUserScrollPhase = userScrollPhase(from: newPhase)
            switch currentUserScrollPhase {
            case .tracking, .interacting, .decelerating:
                let phaseMetrics = scrollMetrics(from: context.geometry)
                _ = applyScrollMetrics(phaseMetrics)
                beginUserScrollInteractionIfNeeded(
                    proxy: proxy,
                    phase: currentUserScrollPhase,
                    metrics: phaseMetrics
                )
            case .idle:
                let finalMetrics = scrollMetrics(from: context.geometry)
                _ = applyScrollMetrics(finalMetrics)
                finalizeUserScrollInteraction(proxy: proxy, finalMetrics: finalMetrics)
            case .animating:
                if !programmaticScrollGate.isInFlight {
                    cancelInvalidPendingBottomScrollOutcome(reason: "manualAnimation")
                }
            }
        }
    }

    private func legacyScrollableContent(proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        ScrollView {
            messageListContent(viewportHeight: viewportHeight, proxy: proxy)
        }
        .id(transcriptScrollResetRevision)
        .accessibilityIdentifier("agentTranscript.scrollView")
        .coordinateSpace(name: "AgentTranscriptScrollSpace")
        .transaction { txn in
            if didChatChange { txn.disablesAnimations = true }
        }
    }

    private func messageListContent(
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) -> some View {
        messagesStack()
            .padding()
            .frame(
                maxWidth: .infinity,
                minHeight: viewportHeight,
                alignment: hasTranscriptContent ? .topLeading : .center
            )
        #if DEBUG
            .onPreferenceChange(AgentToolCardRenderStatePreferenceKey.self) { states in
                visibleToolCardRenderStatesByID = states
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    private func messagesStack() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            messageRowsContent
        }
    }

    @ViewBuilder
    private var messageRowsContent: some View {
        topSentinel
        if shouldShowStreamingHistoryIndicator {
            streamingHistoryIndicator
        }
        if !hasTranscriptContent {
            emptyStateView
        } else {
            transcriptBlockRows(blocks: visibleTranscriptBlocks)
        }
        runningIndicatorSlot
        if let review = runInteractionSnapshot.pendingApplyEditsReview {
            AgentApplyEditsReviewCard(
                review: review,
                onAccept: {
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitApplyEditsReviewDecision(
                        tabID: tabID,
                        reviewID: review.id,
                        decision: .accept
                    )
                },
                onReject: { reason in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitApplyEditsReviewDecision(
                        tabID: tabID,
                        reviewID: review.id,
                        decision: .reject(reason: reason)
                    )
                }
            )
            .id("pendingApplyEditsReview")
            .transition(.opacity)
        } else if let mergeReview = runInteractionSnapshot.pendingWorktreeMergeReview {
            AgentWorktreeMergeReviewCard(
                review: mergeReview,
                onAccept: {
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitWorktreeMergeReviewDecision(
                        tabID: tabID,
                        reviewID: mergeReview.id,
                        decision: .accept
                    )
                },
                onCancel: { reason in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitWorktreeMergeReviewDecision(
                        tabID: tabID,
                        reviewID: mergeReview.id,
                        decision: .reject(reason: reason)
                    )
                }
            )
            .id("pendingWorktreeMergeReview")
            .transition(.opacity)
        } else if let approval = runInteractionSnapshot.pendingApproval {
            AgentApprovalCard(
                request: approval,
                onDecision: { decision in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitApprovalDecision(tabID: tabID, decision: decision)
                }
            )
            .id("pendingApproval")
            .transition(.opacity)
        } else if let request = runInteractionSnapshot.pendingMCPElicitationRequest {
            AgentMCPElicitationCard(
                request: request,
                onResponse: { response in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitMCPElicitationResponse(tabID: tabID, requestID: request.id, response: response)
                }
            )
            .id("pendingMCPElicitation")
            .transition(.opacity)
        } else if let request = runInteractionSnapshot.pendingUserInputRequest {
            let cancelTarget = runInteractionSnapshot.pendingUserInputCancelTarget
            AgentRequestUserInputCard(
                request: request,
                onSubmit: { response in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitUserInputResponse(tabID: tabID, requestID: request.requestID, response: response)
                },
                onStop: {
                    guard let cancelTarget else { return }
                    Task {
                        _ = await agentModeVM.cancelAgentRun(target: cancelTarget, completion: .terminalPublished)
                    }
                }
            )
            .id("pendingUserInputRequest")
            .transition(.opacity)
        } else if let pendingAskUser = runInteractionSnapshot.pendingAskUser {
            AgentAskUserWizardCard(
                pending: pendingAskUser,
                onDraftChange: { questionID, draft in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.updateAskUserDraft(
                        tabID: tabID,
                        interactionID: pendingAskUser.interaction.id,
                        questionID: questionID,
                        draft: draft
                    )
                },
                onQuestionIndexChange: { index in
                    guard let tabID = currentTabID else { return }
                    agentModeVM.updateAskUserQuestionIndex(
                        tabID: tabID,
                        interactionID: pendingAskUser.interaction.id,
                        index: index
                    )
                },
                onSubmit: {
                    guard let tabID = currentTabID else { return }
                    agentModeVM.submitAskUserResponse(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                },
                onSkipAll: {
                    guard let tabID = currentTabID else { return }
                    agentModeVM.skipAskUser(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                },
                onUserActivity: {
                    guard let tabID = currentTabID else { return }
                    agentModeVM.noteAskUserCardActivity(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                }
            )
            .id("pendingAskUser")
            .transition(.opacity)
        } else if let conflict = runInteractionSnapshot.activeWorktreeMergeConflict {
            AgentWorktreeMergeConflictCard(
                operation: conflict,
                onContinue: {
                    guard let agentSessionID = runInteractionSnapshot.activeAgentSessionID else { return }
                    Task { @MainActor in
                        _ = try? await agentModeVM.continueWorktreeMerge(
                            sessionID: agentSessionID,
                            operationID: conflict.id,
                            confirmed: true
                        )
                    }
                },
                onAbort: {
                    guard let agentSessionID = runInteractionSnapshot.activeAgentSessionID else { return }
                    Task { @MainActor in
                        _ = try? await agentModeVM.abortWorktreeMerge(
                            sessionID: agentSessionID,
                            operationID: conflict.id,
                            confirmed: true
                        )
                    }
                }
            )
            .id("activeWorktreeMergeConflict")
            .transition(.opacity)
        }
        bottomTarget
        versionedBottomSentinel
    }

    // MARK: - Structured Transcript Rows

    private struct TranscriptRenderContext {
        let isContextBuilderQuestionActive: Bool
        let activeContextBuilderCallID: UUID?
        let activeContextBuilderResultID: UUID?
        let mostRecentEditID: UUID?

        let recentAssistantItemIDs: Set<UUID>
        let interactionBlockerVisible: Bool
    }

    @ViewBuilder
    private func transcriptBlockRows(blocks: [AgentTranscriptRenderBlock]) -> some View {
        let isContextBuilderQuestionActive = isContextBuilderQuestionPresented
        let renderMetadata = transcriptRenderMetadata(for: blocks)
        let renderContext = TranscriptRenderContext(
            isContextBuilderQuestionActive: isContextBuilderQuestionActive,
            activeContextBuilderCallID: renderMetadata.activeContextBuilderCallItemID,
            activeContextBuilderResultID: renderMetadata.activeContextBuilderResultItemID,
            mostRecentEditID: renderMetadata.mostRecentEditItemID,

            recentAssistantItemIDs: renderMetadata.recentAssistantItemIDs,
            interactionBlockerVisible: isInteractionBlockerVisible
        )
        ForEach(blocks) { block in
            transcriptBlockView(block: block, renderContext: renderContext)
                .id(block.id)
        }
        .environment(\.agentMessageRuntimeFooterByItemID, transcriptSnapshot.runtimeFooterByItemID)
        .messageTimestampEnvironment()
    }

    @ViewBuilder
    private func transcriptBlockView(block: AgentTranscriptRenderBlock, renderContext: TranscriptRenderContext) -> some View {
        switch block.kind {
        case .activityCluster:
            let supportsExpansion = transcriptBlockSupportsExpansion(block)
            let persistedExpansion = persistedTranscriptBlockExpansion(for: block)
            let summaryLockTarget = isDynamicSummaryLockTarget(block)
            let isExpanded = supportsExpansion && !summaryLockTarget && persistedExpansion
            transcriptBlockRow {
                VStack(alignment: .leading, spacing: 8) {
                    if !supportsExpansion || summaryLockTarget {
                        clusterSummaryLabel(for: block, isExpanded: isExpanded)
                    } else {
                        Button {
                            transcriptBlockExpansion[block.id] = !persistedExpansion
                            transcriptBlockDefaultExpansion[block.id] = block.defaultPresentation == .expanded
                        } label: {
                            clusterSummaryLabel(for: block, isExpanded: isExpanded)
                        }
                        .buttonStyle(.plain)
                    }
                    if isExpanded {
                        let useScroll = block.rows.count > 5
                        Group {
                            if useScroll {
                                ScrollView {
                                    expandedClusterContent(block: block, renderContext: renderContext)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 220)
                            } else {
                                expandedClusterContent(block: block, renderContext: renderContext)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
            }
            .accessibilityIdentifier("agentTranscript.activityCluster")
        case .collapsedHistoryRange:
            transcriptBlockRow {
                collapsedHistoryRangeRow(for: block)
            }
            .accessibilityIdentifier("agentTranscript.collapsedHistoryRange")
        case .groupedHistory:
            let supportsExpansion = transcriptBlockSupportsExpansion(block)
            let persistedExpansion = persistedTranscriptBlockExpansion(for: block)
            let summaryLockTarget = isDynamicSummaryLockTarget(block)
            let isExpanded = supportsExpansion && !summaryLockTarget && persistedExpansion
            transcriptBlockRow {
                VStack(alignment: .leading, spacing: 8) {
                    if !supportsExpansion || summaryLockTarget {
                        groupedHistorySummaryLabel(for: block, isExpanded: isExpanded)
                    } else {
                        Button {
                            transcriptBlockExpansion[block.id] = !persistedExpansion
                            transcriptBlockDefaultExpansion[block.id] = block.defaultPresentation == .expanded
                        } label: {
                            groupedHistorySummaryLabel(for: block, isExpanded: isExpanded)
                        }
                        .buttonStyle(.plain)
                    }
                    if isExpanded, let groupedHistory = block.groupedHistory {
                        let totalRows = groupedHistory.sections.reduce(0) { $0 + $1.childBlocks.reduce(0) { $0 + $1.rows.count } }
                        let useScroll = totalRows > 5
                        Group {
                            if useScroll {
                                ScrollView {
                                    expandedGroupedContent(sections: groupedHistory.sections, renderContext: renderContext)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 260)
                            } else {
                                expandedGroupedContent(sections: groupedHistory.sections, renderContext: renderContext)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
            }
            .accessibilityIdentifier("agentTranscript.groupedHistory")
        default:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(block.rows) { item in
                    transcriptRowView(
                        item: item,
                        block: block,
                        renderContext: renderContext,
                        autoExpandEnabled: toolCardAutoExpandEnabled(for: block)
                    )
                }
            }
        }
    }

    // MARK: - Run-Scoped Tool Cancel Context

    /// Whether a tool-call item in the given block is eligible for a header cancel button.
    /// Only shows for current-turn items in non-archived, full-retention blocks during an active run.
    private func showRunScopedToolCancel(
        for item: AgentChatItem,
        in block: AgentTranscriptRenderBlock
    ) -> Bool {
        guard runInteractionSnapshot.runState == .running,
              runInteractionSnapshot.activeRunID != nil,
              !block.isArchived,
              block.retentionTier == .full,
              item.kind == .toolCall
        else { return false }
        // Only show cancel for items after the latest user message in this turn
        if let latestUserSeqIndex = runInteractionSnapshot.latestUserSequenceIndex,
           item.sequenceIndex > latestUserSeqIndex
        {
            return true
        }
        return false
    }

    /// Stable cancel closure for the active run, captured at render time.
    private var cancelActiveToolsAction: (() -> Void)? {
        guard let runID = runInteractionSnapshot.activeRunID else { return nil }
        return { [weak agentModeVM] in
            agentModeVM?.cancelActiveToolsForRun(runID: runID, reason: "tool_card_header_cancel")
        }
    }

    private func transcriptRowView(
        item: AgentChatItem,
        block: AgentTranscriptRenderBlock,
        renderContext: TranscriptRenderContext,
        autoExpandEnabled: Bool
    ) -> some View {
        let showCancel = showRunScopedToolCancel(for: item, in: block)
        let cancelAction = showCancel ? cancelActiveToolsAction : nil
        let ownerTabID = transcriptSnapshot.presentation.tabID ?? transcriptSnapshot.currentTabID ?? currentTabID
        let ownerWorkspaceID = oracleViewModel.workspaceManager.activeWorkspaceID
        return AgentMessageBubble(
            item: item,
            isMostRecentEditBubble: item.id == renderContext.mostRecentEditID,
            windowID: windowID,
            currentWorkspaceID: ownerWorkspaceID,
            currentTabID: ownerTabID,
            suppressAskUserTranscriptUI: renderContext.isContextBuilderQuestionActive,
            contextBuilderContext: .init(
                tabID: ownerTabID,
                contextBuilderAgentVM: contextBuilderAgentVM,
                activeContextBuilderCallItemID: renderContext.activeContextBuilderCallID,
                activeContextBuilderResultItemID: renderContext.activeContextBuilderResultID,
                oracleOpenContext: .init(
                    windowID: windowID,
                    workspaceID: ownerWorkspaceID,
                    tabID: ownerTabID
                ),
                showRunScopedToolCancel: showCancel,
                cancelActiveToolsAction: cancelAction
            ),
            promptManager: promptManager,
            handoffConfig: runInteractionSnapshot.canForkCurrentSession ? handoffConfig(for: item.id) : nil,
            rawToolResultPayload: agentModeVM.rawToolResultPayloadForRendering(tabID: ownerTabID, itemID: item.id),
            rawToolResultPayloadRenderRevision: transcriptSnapshot.presentation.rawToolResultPayloadRenderRevision,
            showRunScopedToolCancel: showCancel,
            cancelActiveToolsAction: cancelAction,
            codexManagedLoginAction: codexManagedLoginAction
        )
        .id(item.id)
        .environment(\.markdownFileLinkOpener, markdownFileLinkOpener)
        .environment(\.agentToolCardAutoExpandEnabled, autoExpandEnabled)
        .environment(\.agentLiveBashExecutionByItemID, transcriptSnapshot.activeBashLiveExecutionByItemID)
        .environment(\.agentRecentAssistantItemIDs, renderContext.recentAssistantItemIDs)
        .environment(\.agentApprovalVisible, renderContext.interactionBlockerVisible)
    }

    private func toolCardAutoExpandEnabled(for block: AgentTranscriptRenderBlock) -> Bool {
        block.turnID != dynamicSummaryLockTargetTurnID
            && !block.isArchived
            && block.retentionTier == .full
            && block.kind != .activityCluster
            && block.kind != .groupedHistory
    }

    /// Per-item auto-expand policy that allows bash to auto-expand inside grouped/cluster blocks
    /// while keeping other tools collapsed in those contexts.
    private func toolCardAutoExpandEnabled(for item: AgentChatItem, in block: AgentTranscriptRenderBlock) -> Bool {
        guard block.turnID != dynamicSummaryLockTargetTurnID, !block.isArchived, block.retentionTier == .full else {
            return false
        }
        if block.kind == .activityCluster || block.kind == .groupedHistory {
            // Only bash cards are allowed to auto-expand inside grouped/cluster blocks.
            return normalizedToolCardName(item.toolName) == "bash"
        }
        return true
    }

    private func transcriptBlockRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 0) {
            content()
                .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 40)
        }
    }

    private func clusterSummaryLabel(for block: AgentTranscriptRenderBlock, isExpanded: Bool) -> some View {
        collapsedSummaryLabelContent(
            display: collapsedSummaryDisplay(
                for: block.clusterSummary,
                fallbackCount: block.clusterSummary?.toolCount ?? block.rows.count,
                fallbackText: nil
            )
        )
    }

    private func groupedHistorySummaryLabel(for block: AgentTranscriptRenderBlock, isExpanded: Bool) -> some View {
        collapsedSummaryLabelContent(
            display: collapsedSummaryDisplay(for: block.groupedHistory?.summary)
        )
    }

    private func collapsedSummaryDisplay(
        for summary: AgentTranscriptClusterSummary?,
        fallbackCount: Int,
        fallbackText: String?
    ) -> AgentTranscriptCollapsedSummaryDisplay {
        if let display = summary?.collapsedDisplay {
            return display
        }
        return AgentTranscriptCollapsedSummaryDisplay(
            title: summaryTitle(for: summary, fallbackCount: fallbackCount),
            count: fallbackCount > 0 ? fallbackCount : nil,
            detailText: collapsedSummaryInlineDetailText(
                narration: collapsedInlineNarrationText(summary?.shortNarration),
                toolSummary: summary,
                fallbackText: fallbackText
            ),
            status: collapsedSummaryStatus(for: summary)
        )
    }

    private func collapsedSummaryDisplay(
        for summary: AgentTranscriptGroupedHistorySummary?
    ) -> AgentTranscriptCollapsedSummaryDisplay {
        if let display = summary?.collapsedDisplay {
            return display
        }
        let toolSummary = summary?.toolSummary
        let hiddenToolCardCount = summary?.hiddenToolCardCount ?? 0
        return AgentTranscriptCollapsedSummaryDisplay(
            title: groupedSummaryTitle(summary: summary),
            count: hiddenToolCardCount > 0 ? hiddenToolCardCount : nil,
            detailText: collapsedSummaryInlineDetailText(
                narration: collapsedInlineNarrationText(toolSummary?.shortNarration),
                toolSummary: toolSummary,
                fallbackText: groupedSummaryFallbackText(summary: summary)
            ),
            status: collapsedSummaryStatus(for: toolSummary)
        )
    }

    private func collapsedSummaryLabelContent(
        display: AgentTranscriptCollapsedSummaryDisplay
    ) -> some View {
        collapsedSummaryCard {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    collapsedSummaryTitleRow(title: display.title, count: display.count)
                    if display.narrationText != nil, let toolGroupText = display.toolGroupText {
                        Text(toolGroupText)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    collapsedSummaryStatusDot(status: display.status)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    if let narration = display.narrationText {
                        Text(narration)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let detailText = display.detailText {
                        Text(detailText)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func collapsedSummaryTitleRow(title: String, count: Int?) -> some View {
        Text(title)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
        if let count, count > 0 {
            collapsedSummaryCountBadge(count)
        }
    }

    private func collapsedSummaryCountBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(4)
    }

    private func collapsedSummaryStatus(for toolSummary: AgentTranscriptClusterSummary?) -> AgentTranscriptCollapsedSummaryStatus {
        guard let toolSummary else { return .neutral }
        if toolSummary.containsFailure { return .failure }
        if toolSummary.containsWarning { return .warning }
        if toolSummary.containsRunningWork { return .running }
        return .neutral
    }

    @ViewBuilder
    private func collapsedSummaryStatusDot(status: AgentTranscriptCollapsedSummaryStatus) -> some View {
        switch status {
        case .failure:
            StatusDot(status: .failure, size: 6)
        case .warning:
            StatusDot(status: .warning, size: 6)
        case .running:
            StatusDot(status: .running, size: 6)
        case .neutral:
            EmptyView()
        }
    }

    private func collapsedSummaryInlineDetailText(
        narration: String?,
        toolSummary: AgentTranscriptClusterSummary?,
        fallbackText: String?
    ) -> String? {
        let parts = [
            narration,
            collapsedSummaryToolGroupText(toolSummary: toolSummary),
            fallbackText
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return Array(parts.prefix(2)).joined(separator: " • ")
    }

    private func collapsedSummaryToolGroupText(toolSummary: AgentTranscriptClusterSummary?) -> String? {
        guard let toolSummary else { return nil }
        let labels = toolSummary.toolGroups.map(\.label).filter { !$0.isEmpty }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    private func expandedClusterContent(block: AgentTranscriptRenderBlock, renderContext: TranscriptRenderContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(block.rows) { item in
                transcriptRowView(
                    item: item,
                    block: block,
                    renderContext: renderContext,
                    autoExpandEnabled: toolCardAutoExpandEnabled(for: item, in: block)
                )
            }
        }
    }

    private func expandedGroupedContent(sections: [AgentTranscriptGroupedSection], renderContext: TranscriptRenderContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                groupedHistorySectionView(section: section, renderContext: renderContext)
            }
        }
    }

    private func groupedHistorySectionView(
        section: AgentTranscriptGroupedSection,
        renderContext: TranscriptRenderContext
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header — compact inline
            if section.title != nil || section.clusterSummary != nil {
                HStack(spacing: 5) {
                    if let icon = section.icon {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if let title = section.title {
                        Text(title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let summary = section.clusterSummary, summary.toolCount > 0 {
                        Text("\(summary.toolCount)")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.10))
                            .cornerRadius(3)
                    }
                    // Inline tool chips in section header
                    if let toolGroups = section.clusterSummary?.toolGroups, !toolGroups.isEmpty {
                        Text("·")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                        clusterToolChips(groups: toolGroups)
                    }
                    Spacer(minLength: 0)
                }
            }
            // Child blocks — compact spacing
            ForEach(section.childBlocks) { childBlock in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(childBlock.rows) { item in
                        transcriptRowView(
                            item: item,
                            block: childBlock,
                            renderContext: renderContext,
                            autoExpandEnabled: toolCardAutoExpandEnabled(for: item, in: childBlock)
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Tool type chips — renders pre-computed groups from the model, no grouping logic here.
    private func clusterToolChips(groups: [ClusterToolGroup]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 4)
                }
                HStack(spacing: 3) {
                    Image(systemName: group.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(group.label)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// File paths shown vertically with folder icons, truncated when collapsed
    @ViewBuilder
    private func clusterPathsList(paths: [String], isExpanded: Bool) -> some View {
        let visiblePaths = isExpanded ? paths : Array(paths.prefix(3))
        let remainingCount = paths.count - visiblePaths.count
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visiblePaths, id: \.self) { path in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(shortenPath(path))
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if remainingCount > 0 {
                Text("+\(remainingCount) more")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    /// File paths shown as a compact inline comma-separated list, disambiguating duplicate basenames.
    @ViewBuilder
    private func clusterPathsInline(paths: [String], isExpanded: Bool) -> some View {
        let visiblePaths = isExpanded ? paths : Array(paths.prefix(4))
        let remainingCount = paths.count - visiblePaths.count
        HStack(spacing: 3) {
            Image(systemName: "doc")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            let displayNames = disambiguatedFileNames(visiblePaths)
            let joined = displayNames.joined(separator: ", ") + (remainingCount > 0 ? " +\(remainingCount)" : "")
            Text(joined)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Returns filenames, adding parent directory for duplicates.
    private func disambiguatedFileNames(_ paths: [String]) -> [String] {
        let baseNames = paths.map { fileName(from: $0) }
        var counts: [String: Int] = [:]
        for name in baseNames {
            counts[name, default: 0] += 1
        }
        return zip(paths, baseNames).map { path, base in
            if counts[base, default: 0] > 1 {
                return shortenPath(path)
            }
            return base
        }
    }

    private func clusterSummaryTitle(for block: AgentTranscriptRenderBlock) -> String {
        summaryTitle(for: block.clusterSummary, fallbackCount: block.rows.count)
    }

    private func groupedSummaryTitle(summary: AgentTranscriptGroupedHistorySummary?) -> String {
        guard let summary else { return "Earlier activity" }
        return AgentTranscriptSummaryTextFormatter.summaryTitle(
            for: summary.toolSummary,
            fallbackCount: summary.hiddenToolCardCount
        )
    }

    private func groupedSummaryFallbackText(summary: AgentTranscriptGroupedHistorySummary?) -> String? {
        guard let summary else { return nil }
        let subtitle = AgentTranscriptSummaryTextFormatter.groupedSummarySubtitle(summary: summary)
        return subtitle.isEmpty ? nil : subtitle
    }

    private func collapsedInlineNarrationText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @ViewBuilder
    private func collapsedSummarySecondaryRow(
        toolSummary: AgentTranscriptClusterSummary?,
        fallbackText: String?
    ) -> some View {
        if let toolSummary,
           !toolSummary.toolNames.isEmpty || !toolSummary.toolNameCounts.isEmpty || !toolSummary.keyPaths.isEmpty
        {
            ToolCallChipsFlow(
                toolNames: toolSummary.toolNames,
                toolNameCounts: toolSummary.toolNameCounts,
                keyPaths: toolSummary.keyPaths,
                lineLimit: AgentTranscriptCollapsedCardMetrics.compactChipLineLimit,
                maxVisiblePaths: AgentTranscriptCollapsedCardMetrics.compactChipMaxVisiblePaths
            )
            .opacity(0.8)
        } else if let fallbackText, !fallbackText.isEmpty {
            Text(fallbackText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func collapsedSummaryCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(
            maxWidth: .infinity,
            minHeight: AgentTranscriptCollapsedCardMetrics.collapsedHeight,
            maxHeight: AgentTranscriptCollapsedCardMetrics.collapsedHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(BubbleColors.toolResultBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func summaryTitle(for summary: AgentTranscriptClusterSummary?, fallbackCount: Int) -> String {
        AgentTranscriptSummaryTextFormatter.summaryTitle(for: summary, fallbackCount: fallbackCount)
    }

    private func syncTranscriptBlockExpansion(for blocks: [AgentTranscriptRenderBlock]) {
        let validIDs = Set(blocks.map(\.id))
        var nextExpansion = transcriptBlockExpansion.filter { validIDs.contains($0.key) }
        var nextDefaults = transcriptBlockDefaultExpansion.filter { validIDs.contains($0.key) }
        for block in blocks {
            guard transcriptBlockSupportsExpansion(block) else {
                nextExpansion.removeValue(forKey: block.id)
                nextDefaults.removeValue(forKey: block.id)
                continue
            }
            let defaultExpanded = block.defaultPresentation == .expanded
            if let existingExpansion = nextExpansion[block.id],
               let previousDefault = nextDefaults[block.id]
            {
                if previousDefault != defaultExpanded,
                   existingExpansion == previousDefault
                {
                    nextExpansion[block.id] = defaultExpanded
                }
            } else {
                nextExpansion[block.id] = defaultExpanded
            }
            nextDefaults[block.id] = defaultExpanded
        }
        transcriptBlockExpansion = nextExpansion
        transcriptBlockDefaultExpansion = nextDefaults
    }

    // MARK: - Handoff

    private func handoffConfig(for itemID: UUID) -> AgentHandoffConfig {
        AgentHandoffConfig(
            itemID: itemID,
            defaultDestinationAgent: runInteractionSnapshot.selectedAgent,
            defaultModelRaw: runInteractionSnapshot.selectedModelRaw,
            defaultReasoningEffortRaw: runInteractionSnapshot.selectedReasoningEffortRaw,
            availableAgentsProvider: { [weak agentModeVM] in
                agentModeVM?.availableAgents ?? []
            },
            modelOptionsProvider: { [weak agentModeVM] agent in
                agentModeVM?.modelOptions(for: agent) ?? []
            },
            windowID: windowID,
            buildPayloadForClipboard: { [weak agentModeVM] in
                await agentModeVM?.buildHandoffPayload(upToItemID: itemID) ?? ""
            },
            performHandoff: { [weak agentModeVM] selection in
                guard let vm = agentModeVM else { return }
                try await vm.prepareHandoffToNewTab(
                    upToItemID: itemID,
                    destinationAgent: selection.agent,
                    destinationModelRaw: selection.modelRaw,
                    destinationReasoningEffortRaw: selection.reasoningEffortRaw
                )
            }
        )
    }

    private var topSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id("topSentinel")
    }

    private var bottomTarget: some View {
        Color.clear
            .frame(height: max(1, transcriptBottomClearance))
            .id("bottomTarget")
    }

    private var shouldShowRunningIndicator: Bool {
        runInteractionSnapshot.isAgentBusy && runInteractionSnapshot.runState == .running
    }

    private var runningIndicatorSlot: some View {
        runningIndicator
            .frame(height: runningIndicatorReservedHeight, alignment: .leading)
            .opacity(shouldShowRunningIndicator ? 1 : 0)
            .allowsHitTesting(shouldShowRunningIndicator)
            .accessibilityHidden(!shouldShowRunningIndicator)
    }

    private var runningIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
            Text(runInteractionSnapshot.runningStatusText ?? "Thinking…")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let runStartedAt = runInteractionSnapshot.activeAgentRunStartedAt {
                AgentRunningElapsedText(startedAt: runStartedAt, isLive: agentWindowIsFocused)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var versionedBottomSentinel: some View {
        if #unavailable(macOS 15.0) {
            Color.clear
                .frame(height: 1)
                .id("bottomSentinel")
                .onAppear {
                    legacyIsNearBottom = true
                    recordCurrentRehydrateLayoutSample()
                    finishRehydrateRestoreIfSettled()
                }
                .onDisappear {
                    legacyIsNearBottom = false
                }
        }
    }

    private var shouldShowScrollToBottomButton: Bool {
        !isPinnedToLiveBottom || !isNearBottom
    }

    private var streamingHistoryIndicator: some View {
        Button {
            revealCompressedHistoryIfNeeded(userInitiated: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Earlier history is hidden. Click to reveal it.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func collapsedHistoryRangeRow(for block: AgentTranscriptRenderBlock) -> some View {
        let range = block.collapsedHistoryRange
        let hiddenTurnCount = range?.hiddenTurnCount ?? 0
        let turnLabel = hiddenTurnCount == 1 ? "earlier turn" : "earlier turns"
        return Button {
            expandTranscriptWindowIfNeeded()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earlier transcript turns are hidden")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Show \(hiddenTurnCount) \(turnLabel).")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Expand")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func shouldAbortPinnedMaintenanceScrollExecution(_ intent: AgentTranscriptScrollIntent) -> Bool {
        guard case let .bottom(_, reason) = intent else {
            return false
        }
        switch reason {
        case .transcriptChangeWhilePinned, .waitingStateChange, .busyStateChange, .bottomClearanceChange:
            break
        default:
            return false
        }
        if shouldSuppressPinnedMaintenanceForFreshIdleBoundaryUpwardIntent()
            || isPinnedTranscriptChangeSuppressionActive()
            || isUserInteractingWithScroll
            || userDetachedAutoFollow
            || !isPinnedToLiveBottom
            || isInteractionBlockerVisible
            || isRehydrateRestoreActive
        {
            return true
        }
        if reason == .transcriptChangeWhilePinned {
            return scrollMetrics.distanceToBottom > max(Self.repinDistanceThreshold * 2, 96)
        }
        return false
    }

    private func requestScroll(
        _ proxy: ScrollViewProxy,
        intent: AgentTranscriptScrollIntent,
        immediate: Bool = false,
        pinnedMaintenanceGeneration: UInt64? = nil
    ) {
        if intent.reason == .sessionSwitchRestore {
            scrollEngine.rehydrate.pinnedJumpTelemetrySuppressedUntil = Date().addingTimeInterval(0.20)
            #if DEBUG
                if isStressHarnessEnabled {
                    noteStressHarness("Restore jump telemetry suppression refreshed")
                }
            #endif
        }
        if isRehydrateRestoreActive, intent.reason != .sessionSwitchRestore {
            cancelPendingBottomScrollOutcomeIfUnexecuted(reason: "rehydrateSuppressed")
            debugLog("requestScroll suppressed during rehydrate", details: "intent=\(debugDescription(for: intent))")
            return
        }
        if case let .bottom(_, reason) = intent {
            beginPendingBottomScrollOutcomeIfNeeded(for: reason)
        }
        cancelPendingScrollWork()
        let capturedTabID = currentTabID
        let capturedPresentationRevision = currentTranscriptPresentationRevision
        let delay = immediate ? 0 : intent.scheduleDelay
        clearPendingDetachedSettleCaptureState()
        if smoothPinnedSendState != nil,
           intent.reason != .userSendWhilePinned,
           intent.reason != .transcriptChangeWhilePinned,
           intent.reason != .waitingStateChange,
           intent.reason != .busyStateChange,
           intent.reason != .bottomClearanceChange
        {
            interruptSmoothPinnedSend(reason: "replacedBy\(String(describing: intent.reason))")
        }
        switch intent {
        case .bottom:
            pendingProgrammaticRestoreTargetID = nil
            pendingProgrammaticRestoreAnchor = nil
            topVisibleViewportTargetID = nil
        case let .anchor(semanticAnchor, _, _, _):
            pendingProgrammaticRestoreTargetID = nil
            pendingProgrammaticRestoreAnchor = semanticAnchor
            topVisibleViewportTargetID = nil
        case let .viewportTarget(targetID, _, _, _):
            pendingProgrammaticRestoreTargetID = targetID
            pendingProgrammaticRestoreAnchor = nil
            topVisibleViewportTargetID = targetID
        }
        recordScrollIntent(intent.reason)

        debugLog("requestScroll scheduled", details: "intent=\(debugDescription(for: intent)) immediate=\(immediate) delay=\(delay)")
        programmaticScrollGate.schedule(after: delay, settleAfter: intent.settleDelay, onSettled: {
            debugLog("requestScroll settled", details: "intent=\(debugDescription(for: intent))")
            if case let .bottom(_, settleReason) = intent {
                let bottomSettleAt = Date()
                lastBottomSettleAt = bottomSettleAt
                if AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
                    runtime: scrollRuntimeState,
                    nearBottomThreshold: Self.pinnedBottomProtectionNearBottomThreshold
                ) {
                    armPinnedBottomProtection(now: bottomSettleAt)
                } else {
                    clearPinnedBottomProtection()
                }
                #if DEBUG
                    stressTelemetryState.lastSettledBottomReason = String(describing: settleReason)
                    if isStressHarnessEnabled {
                        noteStressHarness("Bottom settle: reason=\(settleReason) distance=\(Int(scrollMetrics.distanceToBottom)) nearBottom=\(isNearBottom) pinned=\(isPinnedToLiveBottom) smoothActive=\(smoothPinnedSendState != nil)")
                    }
                #endif
                if let smoothPinnedSendState {
                    switch smoothPinnedSendState.phase {
                    case .preservingBottomBeforeAnimation:
                        if isNearBottom {
                            _ = finishSmoothPinnedSendWithoutAnimation(reason: "bottomPreservedAfterStabilization")
                        } else {
                            flushDeferredPinnedCorrectionAfterSmoothSendIfNeeded(proxy: proxy)
                            scheduleStagedSmoothPinnedSendLaunchIfNeeded(proxy: proxy)
                            #if DEBUG
                                if isStressHarnessEnabled, self.smoothPinnedSendState != nil {
                                    noteStressHarness("Smooth send still stabilizing after bottom settle: reason=\(settleReason) distance=\(Int(scrollMetrics.distanceToBottom)) nearBottom=\(isNearBottom)")
                                }
                            #endif
                        }
                    case .animatingToBottom:
                        let didCompleteSmoothSend = completeSmoothPinnedSendIfNeeded(settleReason: settleReason)
                        #if DEBUG
                            if isStressHarnessEnabled, !didCompleteSmoothSend, self.smoothPinnedSendState != nil {
                                noteStressHarness("Smooth send still active after bottom settle: reason=\(settleReason) distance=\(Int(scrollMetrics.distanceToBottom)) nearBottom=\(isNearBottom)")
                            }
                        #endif
                        if didCompleteSmoothSend || self.smoothPinnedSendState != nil {
                            flushDeferredPinnedCorrectionAfterSmoothSendIfNeeded(proxy: proxy)
                        }
                    }
                }
                if isPinnedToLiveBottom,
                   !userDetachedAutoFollow,
                   !isInteractionBlockerVisible,
                   !isUserInteractingWithScroll,
                   !isRehydrateRestoreActive,
                   isPinnedMaintenanceReason(settleReason),
                   scrollMetrics.distanceToBottom > Self.scrollToBottomSuccessDistanceThreshold
                {
                    if settleReason != .bottomClearanceChange {
                        requestPinnedLiveBottom(proxy: proxy, source: .bottomClearanceChange)
                    }
                }
                resolvePendingBottomScrollOutcomeOnSettled(for: settleReason)
            }
            recordRehydrateLayoutSampleAfterProgrammaticSettle()
            if #unavailable(macOS 15.0), continueRehydrateRestoreIfNeeded(proxy: proxy, source: .settled) {
                return
            }
            finishRehydrateRestoreIfSettled()
        }, action: {
            debugLog("requestScroll executing", details: "intent=\(debugDescription(for: intent)) capturedTab=\(debugShortID(capturedTabID)) capturedRev=\(capturedPresentationRevision)")
            guard capturedTabID == currentTabID else {
                cancelPendingBottomScrollOutcomeIfUnexecuted(reason: "tabMismatch")
                debugLog("requestScroll aborted tab mismatch", details: "intent=\(debugDescription(for: intent)) capturedTab=\(debugShortID(capturedTabID)) currentTab=\(debugCurrentTabLabel)")
                return
            }
            guard capturedPresentationRevision == currentTranscriptPresentationRevision
                || intent.allowsRevisionMismatch
            else {
                cancelPendingBottomScrollOutcomeIfUnexecuted(reason: "revisionGate")
                debugLog("requestScroll aborted revision gate", details: "intent=\(debugDescription(for: intent)) capturedRev=\(capturedPresentationRevision) currentRev=\(currentTranscriptPresentationRevision)")
                return
            }
            if let pinnedMaintenanceGeneration,
               pinnedMaintenanceGeneration != self.pinnedMaintenanceGeneration
            {
                cancelPendingBottomScrollOutcomeIfUnexecuted(reason: "pinnedMaintenanceGeneration")
                debugLog("requestScroll aborted pinned maintenance generation", details: "intent=\(debugDescription(for: intent)) requested=\(pinnedMaintenanceGeneration) current=\(self.pinnedMaintenanceGeneration)")
                return
            }
            if shouldAbortPinnedMaintenanceScrollExecution(intent) {
                cancelPendingBottomScrollOutcomeIfUnexecuted(reason: "stalePinnedMaintenance")
                debugLog("requestScroll aborted stale pinned maintenance", details: "intent=\(debugDescription(for: intent)) distance=\(Int(scrollMetrics.distanceToBottom)) interacting=\(isUserInteractingWithScroll) detached=\(userDetachedAutoFollow) suppression=\(isPinnedTranscriptChangeSuppressionActive())")
                return
            }
            if shouldAbortCompetingPinnedMaintenanceDuringExplicitBottomOutcome(intent.reason) {
                debugLog(
                    "requestScroll aborted competing pinned maintenance during explicit bottom outcome",
                    details: "intent=\(debugDescription(for: intent)) distance=\(Int(scrollMetrics.distanceToBottom))"
                )
                return
            }
            _ = markPendingBottomScrollOutcomeExecutedIfNeeded(for: intent.reason)

            let performScroll = {
                switch intent {
                case .bottom:
                    proxy.scrollTo("bottomTarget", anchor: .bottom)
                case let .anchor(semanticAnchor, placement, _, _):
                    guard let resolvedBlockID = resolveVisibleBlockID(for: semanticAnchor) else { return }
                    proxy.scrollTo(resolvedBlockID, anchor: placement.unitPoint)
                case let .viewportTarget(targetID, placement, _, _):
                    guard let resolvedTargetID = resolveVisibleViewportTargetID(targetID) else { return }
                    switch resolvedTargetID {
                    case let .row(rowID):
                        proxy.scrollTo(rowID, anchor: placement.unitPoint)
                    case let .block(blockID):
                        proxy.scrollTo(blockID, anchor: placement.unitPoint)
                    }
                }
            }

            if intent.isAnimated {
                withAnimation(.easeOut(duration: 0.2)) {
                    performScroll()
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    performScroll()
                }
            }
        })
    }

    private func cancelPendingScrollWork() {
        debugLog("cancelPendingScrollWork")
        programmaticScrollGate.cancel()
        pendingProgrammaticRestoreTargetID = nil
        pendingProgrammaticRestoreAnchor = nil
        #if DEBUG
            assert(
                pendingProgrammaticRestoreTargetID == nil && pendingProgrammaticRestoreAnchor == nil,
                "cancelPendingScrollWork: pending restore target/anchor should be cleared"
            )
        #endif
    }

    private func cancelAllScheduledScrollWork() {
        debugLog("cancelAllScheduledScrollWork")
        scrollEngine.cancelScheduledWork()
        #if DEBUG
            assert(
                pendingProgrammaticRestoreTargetID == nil && pendingProgrammaticRestoreAnchor == nil,
                "cancelAllScheduledScrollWork: pending restore target/anchor should be cleared"
            )
            assertScrollStateInvariants()
        #endif
    }

    private func handleBottomButtonTap(proxy: ScrollViewProxy) {
        invalidatePinnedMaintenance(.explicitBottomAction)
        cancelPendingBottomScrollOutcome(reason: "explicitBottomTapReplaced")
        pinToLiveBottom()
        beginRepinGrace(reason: .bottomButtonTap)
        requestScroll(proxy, intent: .bottom(animated: true, reason: .bottomButtonTap), immediate: true)
    }

    private func handleScrollViewResetButtonTap(proxy: ScrollViewProxy) {
        debugLog("manualScrollViewReset")
        invalidatePinnedMaintenance(.explicitBottomAction)
        cancelAllScheduledScrollWork()
        cancelScrollResponsivenessObservations()
        clearPinnedTranscriptChangeSuppression()
        clearPinnedIdleTransitionManualDetach()
        clearManualDetachOverride()
        resetPinnedBottomRequestState()
        hasUserInteractedWithScroll = false
        isUserInteractingWithScroll = false
        repinGraceState = nil
        lastTranscriptChangePinnedMaintenanceRevision = nil
        _ = applyScrollMetrics(AgentTranscriptScrollMetrics())
        legacyIsNearBottom = false
        interruptSmoothPinnedSend(reason: "manualScrollViewReset")
        transcriptScrollResetRevision &+= 1
        scrollEngine.rehydrate.coldRestoreStartedAt = nil
        clearLiveTranscriptViewportCaptureState(shouldResetDetachedRebaseTracking: true)
        applyStoredTranscriptViewportState(for: currentTabID)
        armRehydrateRestore(for: currentTabID)
        _ = advanceRehydrateRestoreIfNeeded(proxy: proxy)
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func revealCompressedHistoryIfNeeded(userInitiated: Bool = false) {
        guard userInitiated else { return }
        guard canRevealCompressedHistory else { return }
        guard !usesCompressedHistory else { return }
        prepareCompressionTransition(targetShowCompressedHistory: true)
        showCompressedHistory = true
        if let currentTabID {
            agentModeVM.setCompressedHistoryVisibility(tabID: currentTabID, isRevealed: true)
        }
    }

    private func expandTranscriptWindowIfNeeded() {
        guard !isTranscriptWindowExpanded else { return }
        prepareCompressionTransition(targetShowCompressedHistory: showCompressedHistory)
        isTranscriptWindowExpanded = true
        if let currentTabID {
            agentModeVM.setTranscriptWindowExpanded(tabID: currentTabID, isExpanded: true)
        }
    }

    private func resolveVisibleBlockID(for anchor: AgentTranscriptAnchor) -> String? {
        guard let blockID = transcriptPresentation.anchorBlockIndex[anchor] else { return nil }
        return visibleTranscriptBlockIDs.contains(blockID) ? blockID : nil
    }

    private func resolveVisibleViewportTargetID(_ targetID: AgentTranscriptViewportTargetID) -> AgentTranscriptViewportTargetID? {
        switch targetID {
        case let .row(rowID):
            if renderedTranscriptRowIDs.contains(rowID) {
                return targetID
            }
            if let semanticAnchor = transcriptPresentation.rowAnchorIndex[rowID],
               let blockID = resolveVisibleBlockID(for: semanticAnchor)
            {
                return .block(blockID)
            }
            return nil
        case let .block(blockID):
            return visibleTranscriptBlockIDs.contains(blockID) ? targetID : nil
        }
    }

    private func resolveVisibleBlockID(containing targetID: AgentTranscriptViewportTargetID) -> String? {
        switch targetID {
        case let .block(blockID):
            return visibleTranscriptBlockIDs.contains(blockID) ? blockID : nil
        case let .row(rowID):
            if let semanticAnchor = transcriptPresentation.rowAnchorIndex[rowID],
               let blockID = resolveVisibleBlockID(for: semanticAnchor)
            {
                return blockID
            }
            return visibleTranscriptBlocks.first(where: { block in
                block.rows.contains(where: { $0.id == rowID })
            })?.id
        }
    }

    private func activeTrackedViewportTargetID() -> AgentTranscriptViewportTargetID? {
        guard shouldTrackDetachedViewportCandidates,
              let targetID = topVisibleViewportTargetID,
              let resolvedTargetID = resolveVisibleViewportTargetID(targetID),
              viewportRegistry.viewportCandidate(for: resolvedTargetID) != nil
        else {
            return nil
        }
        return resolvedTargetID
    }

    private func visibleViewportCandidate(for targetID: AgentTranscriptViewportTargetID) -> AgentTranscriptViewportCandidate? {
        guard let resolvedTargetID = resolveVisibleViewportTargetID(targetID) else { return nil }
        return viewportRegistry.viewportCandidate(for: resolvedTargetID)
    }

    private func groupedHistoryDescendantViewportCandidate(
        anchor: AgentTranscriptAnchor?,
        sequenceIndex: Int?,
        viewportMinY: CGFloat?
    ) -> AgentTranscriptViewportCandidate? {
        guard case let .groupedHistory(turnID, spanID)? = anchor else { return nil }
        let descendantCandidates = viewportRegistry.viewportCandidates.filter { candidate in
            guard case .row = candidate.targetID,
                  let semanticAnchor = candidate.semanticAnchor
            else {
                return false
            }
            switch semanticAnchor {
            case let .activity(candidateTurnID, candidateSpanID, _):
                return candidateTurnID == turnID && candidateSpanID == spanID
            default:
                return false
            }
        }
        guard !descendantCandidates.isEmpty else { return nil }
        let referenceMinY = viewportMinY ?? 0
        return descendantCandidates.min { lhs, rhs in
            let lhsSequenceDistance = sequenceIndex.map { abs((lhs.sequenceIndex ?? $0) - $0) } ?? 0
            let rhsSequenceDistance = sequenceIndex.map { abs((rhs.sequenceIndex ?? $0) - $0) } ?? 0
            if lhsSequenceDistance != rhsSequenceDistance {
                return lhsSequenceDistance < rhsSequenceDistance
            }
            let lhsMinYDistance = abs(lhs.minY - referenceMinY)
            let rhsMinYDistance = abs(rhs.minY - referenceMinY)
            if lhsMinYDistance != rhsMinYDistance {
                return lhsMinYDistance < rhsMinYDistance
            }
            return lhs.minY < rhs.minY
        }
    }

    private func handleDetachedPresentationRevisionChange(
        proxy: ScrollViewProxy,
        presentationRevision: Int,
        reason: AgentTranscriptScrollReason
    ) -> Bool {
        if scrollMetrics.distanceToBottom <= Self.repinDistanceThreshold,
           !isManualDetachOverrideActive()
        {
            pinToLiveBottom()
            requestScroll(proxy, intent: .bottom(animated: false, reason: .nearBottomReengaged), immediate: true)
            return true
        }
        return false
    }

    private func prepareCompressionTransition(targetShowCompressedHistory: Bool) {
        guard isPinnedToLiveBottom else {
            pendingCompressionRestoreStrategy = nil
            return
        }
        pendingCompressionRestoreStrategy = .preserveBottom
    }

    private func applyPendingCompressionStrategy(proxy: ScrollViewProxy) {
        guard !isRehydrateRestoreActive else {
            debugLog("applyPendingCompressionStrategy deferred for rehydrate")
            return
        }
        guard !isUserInteractingWithScroll else {
            debugLog("applyPendingCompressionStrategy deferred for user interaction")
            return
        }
        guard pendingCompressionRestoreStrategy != nil else { return }
        debugLog("applyPendingCompressionStrategy", details: "strategy=preserveBottom")
        requestScroll(proxy, intent: .bottom(animated: false, reason: .historyCompressionTransition), immediate: true)
        pendingCompressionRestoreStrategy = nil
        clearTransientChatChangeMarkerSoon()
    }

    private func updateTopVisibleViewportTarget(from candidates: [AgentTranscriptViewportCandidate]) {
        guard shouldTrackDetachedViewportCandidates else {
            clearTrackedViewportCandidateState()
            return
        }
        guard pendingCompressionRestoreStrategy == nil else { return }
        guard !isRehydrateRestoreActive else { return }
        guard isCurrentTranscriptPresentationHydrated else { return }
        viewportRegistry.replaceViewportCandidates(candidates)
        let previousTargetID = topVisibleViewportTargetID
        let previousAnchor = topVisibleViewportAnchor
        #if DEBUG
            if isStressHarnessEnabled {
                stressTelemetryState.viewportCandidateUpdateCount += 1
            }
        #endif
        let previousEffectiveAnchor = topVisibleViewportAnchor ?? topVisibleBlockAnchor
        let candidate = candidates
            .filter { $0.maxY > 0 }
            .min { lhs, rhs in
                let lhsDistance = lhs.minY <= 0 ? 0 : lhs.minY
                let rhsDistance = rhs.minY <= 0 ? 0 : rhs.minY
                if lhsDistance == rhsDistance {
                    return lhs.minY < rhs.minY
                }
                return lhsDistance < rhsDistance
            }
        let candidateTargetID = candidate?.targetID
        let candidateAnchor = candidate?.semanticAnchor
        let candidateSequenceIndex = candidate?.sequenceIndex
        let candidateFallbackBlockID = candidate?.fallbackBlockID
        let candidateMinY = candidate?.minY
        if topVisibleViewportTargetID != candidateTargetID {
            topVisibleViewportTargetID = candidateTargetID
        }
        if topVisibleViewportAnchor != candidateAnchor {
            topVisibleViewportAnchor = candidateAnchor
        }
        if topVisibleViewportSequenceIndex != candidateSequenceIndex {
            topVisibleViewportSequenceIndex = candidateSequenceIndex
        }
        if topVisibleViewportFallbackBlockID != candidateFallbackBlockID {
            topVisibleViewportFallbackBlockID = candidateFallbackBlockID
        }
        if shouldUpdateViewportMinY(topVisibleViewportMinY, to: candidateMinY) {
            topVisibleViewportMinY = candidateMinY
        }
        let currentEffectiveAnchor = topVisibleViewportAnchor ?? topVisibleBlockAnchor
        let currentEffectiveBlockID = topVisibleViewportFallbackBlockID ?? topVisibleBlockID
        let detachedAnchorChanged = userDetachedAutoFollow
            && !isPinnedToLiveBottom
            && !isUserInteractingWithScroll
            && !programmaticScrollGate.isInFlight
            && !didChatChange
            && !isInteractionBlockerVisible
            && !isRehydrateRestoreActive
            && previousEffectiveAnchor != nil
            && currentEffectiveAnchor != nil
            && currentEffectiveAnchor != previousEffectiveAnchor
        if detachedAnchorChanged,
           let currentEffectiveAnchor
        {
            if pendingDetachedAnchorChangeAnchor == currentEffectiveAnchor {
                #if DEBUG
                    if isStressHarnessEnabled {
                        stressTelemetryState.detachedAnchorChangeCount += 1
                        if pendingDetachedAnchorChangeBlockID == visibleTranscriptBlocks.first?.id {
                            stressTelemetryState.detachedSnapToTopCount += 1
                        }
                    }
                #endif
                pendingDetachedAnchorChangeAnchor = nil
                pendingDetachedAnchorChangeBlockID = nil
            } else {
                pendingDetachedAnchorChangeAnchor = currentEffectiveAnchor
                pendingDetachedAnchorChangeBlockID = currentEffectiveBlockID
            }
        } else {
            pendingDetachedAnchorChangeAnchor = nil
            pendingDetachedAnchorChangeBlockID = nil
        }
        if topVisibleViewportTargetID != previousTargetID || topVisibleViewportAnchor != previousAnchor {
            debugLog(
                "updateTopVisibleViewportTarget",
                details: "target=\(String(describing: topVisibleViewportTargetID)) anchor=\(String(describing: topVisibleViewportAnchor)) candidateCount=\(candidates.count)"
            )
            publishStressTelemetrySnapshot()
        }
    }

    @available(macOS 15.0, *)
    private func scrollMetrics(from geometry: ScrollGeometry) -> AgentTranscriptScrollMetrics {
        AgentTranscriptScrollMetrics(
            distanceToBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
            visibleMinY: geometry.visibleRect.minY,
            contentHeight: geometry.contentSize.height,
            viewportHeight: geometry.visibleRect.height
        )
    }

    private func currentRehydrateLayoutKey(
        tabID: UUID? = nil,
        presentationRevision: Int? = nil,
        layoutPassToken: UInt64? = nil
    ) -> AgentTranscriptRehydrateRetryKey? {
        let resolvedTabID = tabID ?? currentTabID
        guard let resolvedTabID else { return nil }
        return AgentTranscriptRehydrateRetryKey(
            tabID: resolvedTabID,
            presentationRevision: presentationRevision ?? currentTranscriptPresentationRevision,
            layoutPassToken: layoutPassToken ?? rehydrateLayoutPassToken
        )
    }

    private func recordCurrentRehydrateLayoutSample() {
        let tabID: UUID
        let presentationRevision: Int
        switch rehydrateRestorePhase {
        case let .awaitingLayout(phaseTabID, phaseRevision, _),
             let .driving(phaseTabID, phaseRevision, _):
            tabID = phaseTabID
            presentationRevision = phaseRevision
        case .idle, .awaitingHydration:
            return
        }
        guard tabID == currentTabID,
              presentationRevision == currentTranscriptPresentationRevision,
              let key = currentRehydrateLayoutKey(
                  tabID: tabID,
                  presentationRevision: presentationRevision
              )
        else { return }
        currentRehydrateLayoutSampleKey = key
    }

    private func retainOnlyCurrentRehydrateLayoutSample(
        tabID: UUID,
        presentationRevision: Int
    ) {
        let currentKey = currentRehydrateLayoutKey(
            tabID: tabID,
            presentationRevision: presentationRevision
        )
        if currentRehydrateLayoutSampleKey != currentKey {
            currentRehydrateLayoutSampleKey = nil
        }
    }

    private func recordRehydrateLayoutSampleIfNeeded(metrics: AgentTranscriptScrollMetrics) {
        guard isRehydrateRestoreActive else { return }
        guard AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics) else {
            currentRehydrateLayoutSampleKey = nil
            return
        }
        recordCurrentRehydrateLayoutSample()
    }

    private func recordRehydrateLayoutSampleAfterProgrammaticSettle() {
        guard isRehydrateRestoreActive else { return }
        recordCurrentRehydrateLayoutSample()
    }

    private func canCompleteLiveBottomRehydrateRestore(
        tabID: UUID,
        presentationRevision: Int
    ) -> Bool {
        AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
            currentLayoutSampleKey: currentRehydrateLayoutSampleKey,
            tabID: tabID,
            presentationRevision: presentationRevision,
            layoutPassToken: rehydrateLayoutPassToken,
            isNearBottom: isNearBottom
        )
    }

    @discardableResult
    private func applyScrollMetrics(_ newMetrics: AgentTranscriptScrollMetrics) -> AgentTranscriptScrollMetrics {
        let previousMetrics = scrollEngine.scrollMetrics
        scrollEngine.scrollMetrics = newMetrics
        if #available(macOS 15.0, *) {
            // Only write to @State when the thresholded value actually changes.
            // Reading bottomAffordance is cheap (no invalidation), but calling
            // the mutating update() through the computed-property setter would
            // write back to @State on every frame even when the value is unchanged.
            let nextIsNearBottom = newMetrics.distanceToBottom <= Self.scrollButtonVisibilityThreshold
            if nextIsNearBottom != bottomAffordance.isNearBottom {
                bottomAffordance.isNearBottom = nextIsNearBottom
                #if DEBUG
                    assertScrollStateInvariants(caller: #function)
                #endif
            }
        }
        return previousMetrics
    }

    private func clearTransientChatChangeMarkerSoon() {
        DispatchQueue.main.async {
            didChatChange = false
        }
    }

    private func beginRepinGrace(reason: AgentTranscriptScrollReason) {
        repinGraceState = RepinGraceState(
            presentationRevision: currentTranscriptPresentationRevision,
            reason: reason,
            activatedAt: Date()
        )
    }

    private func isRepinGraceActive() -> Bool {
        guard let repinGraceState else { return false }
        if Date().timeIntervalSince(repinGraceState.activatedAt) > Self.repinGraceDuration {
            self.repinGraceState = nil
            return false
        }
        return true
    }

    private func shouldSuppressRepinGraceDetach(newMetrics: AgentTranscriptScrollMetrics) -> Bool {
        guard isRepinGraceActive() else { return false }
        guard isPinnedToLiveBottom else { return false }
        return newMetrics.distanceToBottom <= Self.repinDistanceThreshold
    }

    @available(macOS 15.0, *)
    private func userScrollPhase(from phase: ScrollPhase) -> AgentTranscriptUserScrollPhase {
        switch phase {
        case .idle:
            return .idle
        case .tracking:
            return .tracking
        case .interacting:
            return .interacting
        case .decelerating:
            return .decelerating
        case .animating:
            return .animating
        @unknown default:
            return .idle
        }
    }

    private func beginUserScrollInteractionIfNeeded(
        proxy: ScrollViewProxy,
        phase: AgentTranscriptUserScrollPhase,
        metrics: AgentTranscriptScrollMetrics
    ) {
        _ = proxy
        guard phase != .idle, phase != .animating else { return }
        guard supportsAutoScroll,
              !isInteractionBlockerVisible
        else {
            return
        }

        if programmaticScrollGate.isInFlight {
            cancelPendingScrollWork()
        }
        if smoothPinnedSendState != nil {
            interruptSmoothPinnedSend(reason: "userScrollInteraction")
        }
        if isRehydrateRestoreActive {
            cancelRehydrateRestore()
        }
        invalidatePinnedMaintenance(.userInteractionBegan)
        cancelPendingBottomScrollOutcome(reason: "userScrollBegan")

        let now = Date()
        isUserInteractingWithScroll = true
        hasUserInteractedWithScroll = true
        if activeUserScrollSession == nil {
            lastCompletedUserScrollSession = nil
            activeUserScrollSession = AgentTranscriptUserScrollSession(
                startedAt: now,
                baselineMetrics: metrics,
                latestMetrics: metrics,
                latestIntent: .unknown,
                lastIntentAt: nil,
                observedProgress: false
            )
            #if DEBUG
                if isStressHarnessEnabled {
                    stressTelemetryState.manualScrollGestureCount += 1
                    stressTelemetryState.lastManualScrollOutcome = "pending"
                    noteStressHarness(
                        "User scroll session began: phase=\(phase.rawValue) distance=\(Int(metrics.distanceToBottom)) pinned=\(isPinnedToLiveBottom) detached=\(userDetachedAutoFollow)"
                    )
                    publishStressTelemetrySnapshot()
                }
            #endif
        } else {
            activeUserScrollSession?.latestMetrics = metrics
        }
        cancelInvalidPendingBottomScrollOutcome(reason: "userScrollBegan")
    }

    private func recordUserScrollProgressIfNeeded(
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics
    ) {
        guard var session = activeUserScrollSession else { return }
        let distanceDelta = AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
            oldMetrics: oldMetrics,
            newMetrics: newMetrics,
            layoutMutationThreshold: 1
        )
        let visibleMinYDelta = newMetrics.visibleMinY - oldMetrics.visibleMinY
        // Viewport-origin movement is always manual scroll progress. Distance-to-bottom
        // is accepted only when content/viewport size is stable, because markdown/TextKit
        // relayout mutates contentHeight and therefore raw distanceToBottom.
        let observedMotion = abs(visibleMinYDelta) >= 1 || abs(distanceDelta) >= 1
        guard observedMotion else { return }

        session.latestMetrics = newMetrics
        session.observedProgress = true

        let frameDirection: DetachedManualScrollDirection = if isPinnedToLiveBottom, !userDetachedAutoFollow {
            AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
                distanceDelta: distanceDelta,
                visibleMinYDelta: visibleMinYDelta,
                distanceThreshold: Self.manualScrollProgressDistanceThreshold,
                visibleMinYThreshold: Self.manualScrollProgressVisibleMinYThreshold
            )
        } else {
            AgentTranscriptUserScrollIntentResolver.resolve(
                distanceDelta: distanceDelta,
                visibleMinYDelta: visibleMinYDelta,
                distanceThreshold: Self.manualScrollProgressDistanceThreshold,
                visibleMinYThreshold: Self.manualScrollProgressVisibleMinYThreshold
            )
        }
        let direction: DetachedManualScrollDirection
        if frameDirection == .unknown {
            let cumulativeVisibleMinYDelta = newMetrics.visibleMinY - session.baselineMetrics.visibleMinY
            direction = AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(
                visibleMinYDelta: cumulativeVisibleMinYDelta,
                visibleMinYThreshold: Self.manualScrollProgressVisibleMinYThreshold
            )
        } else {
            direction = frameDirection
        }
        if direction != .unknown {
            let now = Date()
            session.latestIntent = direction
            session.lastIntentAt = now
            noteUserScrollIntent(direction, now: now)
        }

        activeUserScrollSession = session
    }

    private func finalizeUserScrollInteraction(
        proxy: ScrollViewProxy,
        finalMetrics: AgentTranscriptScrollMetrics
    ) {
        isUserInteractingWithScroll = false
        guard var session = activeUserScrollSession else { return }
        activeUserScrollSession = nil
        session.latestMetrics = finalMetrics

        let madeMeaningfulProgress = AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: session.latestIntent,
            progress: makeViewportProgress(
                baselineDistanceToBottom: session.baselineMetrics.distanceToBottom,
                baselineVisibleMinY: session.baselineMetrics.visibleMinY,
                currentDistanceToBottom: finalMetrics.distanceToBottom,
                currentVisibleMinY: finalMetrics.visibleMinY
            ),
            distanceThreshold: Self.manualScrollProgressDistanceThreshold,
            visibleMinYThreshold: Self.manualScrollProgressVisibleMinYThreshold
        )
        let observedEffect = session.observedProgress || madeMeaningfulProgress
        lastCompletedUserScrollSession = AgentTranscriptCompletedUserScrollSession(
            startedAt: session.startedAt,
            endedAt: Date(),
            baselineMetrics: session.baselineMetrics,
            finalMetrics: finalMetrics,
            latestIntent: session.latestIntent,
            observedProgress: observedEffect
        )
        var outcome = observedEffect ? "effect" : "noEffect"

        if observedEffect,
           userDetachedAutoFollow,
           !isPinnedToLiveBottom,
           shouldForceRepinDetachedAtActualBottom(metrics: finalMetrics)
           || shouldRepinDetachedAfterUserScrollSession(session, finalMetrics: finalMetrics)
        {
            repinDetachedAfterUserScrollSession(proxy: proxy)
            outcome = "repinned"
        } else if observedEffect,
                  isPinnedToLiveBottom,
                  !userDetachedAutoFollow,
                  shouldDetachFromLiveBottomAfterRunBecomesIdle(
                      oldMetrics: session.baselineMetrics,
                      newMetrics: finalMetrics
                  )
        {
            detachFromLiveBottom(markUserDetached: true)
            outcome = "detached"
        } else if observedEffect,
                  isPinnedToLiveBottom,
                  !userDetachedAutoFollow,
                  !isInteractionBlockerVisible,
                  !isRehydrateRestoreActive,
                  finalMetrics.distanceToBottom > Self.scrollToBottomSuccessDistanceThreshold
        {
            requestPinnedLiveBottom(proxy: proxy, source: .bottomClearanceChange)
            outcome = "corrected"
        }

        if !runInteractionSnapshot.runState.isActive {
            clearPinnedIdleTransitionManualDetach()
        }

        #if DEBUG
            if isStressHarnessEnabled {
                if observedEffect {
                    stressTelemetryState.manualScrollEffectCount += 1
                    switch session.latestIntent {
                    case .towardHistory:
                        stressTelemetryState.manualScrollTowardHistoryGestureCount += 1
                        stressTelemetryState.manualScrollTowardHistoryEffectCount += 1
                    case .towardLiveBottom:
                        stressTelemetryState.manualScrollTowardLiveBottomGestureCount += 1
                        stressTelemetryState.manualScrollTowardLiveBottomEffectCount += 1
                    case .unknown:
                        stressTelemetryState.manualScrollUnknownDirectionCount += 1
                    }
                }
                stressTelemetryState.lastManualScrollDirection = session.latestIntent.debugLabel
                stressTelemetryState.lastManualScrollOutcome = outcome
                noteStressHarness(
                    "User scroll session finalized: outcome=\(outcome) direction=\(session.latestIntent.debugLabel) baselineDistance=\(Int(session.baselineMetrics.distanceToBottom)) finalDistance=\(Int(finalMetrics.distanceToBottom))"
                )
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    @discardableResult
    private func beginSmoothPinnedSend(for userItem: AgentChatItem) -> Bool {
        guard smoothPinnedSendState == nil else { return false }
        let startedAt = Date()
        smoothPinnedSendState = SmoothPinnedSendState(
            userMessageID: userItem.id,
            originUserSequenceIndex: userItem.sequenceIndex,
            startedAt: startedAt,
            presentationRevision: currentTranscriptPresentationRevision,
            phase: .preservingBottomBeforeAnimation,
            lastLayoutMutationAt: startedAt,
            correctiveScrollCount: 0
        )
        smoothPinnedSendLaunchGate.cancel()
        #if DEBUG
            guard isStressHarnessEnabled else { return true }
            stressTelemetryState.smoothSendStartCount += 1
            noteStressHarness("Smooth send staged: user=\(debugShortID(userItem.id)) seq=\(userItem.sequenceIndex) rev=\(currentTranscriptPresentationRevision)")
            publishStressTelemetrySnapshot()
        #endif
        return true
    }

    private func noteSmoothPinnedSendCorrectiveScroll() {
        guard smoothPinnedSendState != nil else { return }
        smoothPinnedSendState?.correctiveScrollCount += 1
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            stressTelemetryState.smoothSendCorrectiveScrollCount += 1
            publishStressTelemetrySnapshot()
        #endif
    }

    private func markSmoothPinnedSendLayoutMutation(_ reason: String) {
        guard var smoothPinnedSendState,
              smoothPinnedSendState.phase == .preservingBottomBeforeAnimation
        else {
            return
        }
        smoothPinnedSendState.lastLayoutMutationAt = Date()
        self.smoothPinnedSendState = smoothPinnedSendState
        smoothPinnedSendLaunchGate.cancel()
        #if DEBUG
            if isStressHarnessEnabled {
                noteStressHarness("Smooth send restabilized: reason=\(reason) distance=\(Int(scrollMetrics.distanceToBottom))")
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    @discardableResult
    private func finishSmoothPinnedSendWithoutAnimation(reason: String) -> Bool {
        guard let smoothPinnedSendState else { return false }
        let durationMS = max(0, Date().timeIntervalSince(smoothPinnedSendState.startedAt) * 1000)
        let completionAt = Date()
        self.smoothPinnedSendState = nil
        if AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
            runtime: scrollRuntimeState
        ) {
            armPinnedBottomProtection(now: completionAt)
        } else {
            clearPinnedBottomProtection()
        }
        smoothPinnedSendLaunchGate.cancel()
        bottomClearanceSuppressionUntil = completionAt.addingTimeInterval(0.20)
        #if DEBUG
            guard isStressHarnessEnabled else { return true }
            stressTelemetryState.smoothSendCompletionCount += 1
            stressTelemetryState.smoothSendFinishedWithoutAnimationCount += 1
            noteStressHarness("Smooth send finished without animation: reason=\(reason) durationMS=\(Int(durationMS)) distance=\(Int(scrollMetrics.distanceToBottom)) protectionActive=\(isPinnedBottomProtectionActive(now: completionAt))")
            stressTelemetryState.lastSmoothSendSettleDurationMS = durationMS
            stressTelemetryState.maxSmoothSendSettleDurationMS = max(
                stressTelemetryState.maxSmoothSendSettleDurationMS,
                durationMS
            )
            publishStressTelemetrySnapshot()
        #endif
        return true
    }

    private func scheduleStagedSmoothPinnedSendLaunchIfNeeded(proxy: ScrollViewProxy) {
        guard let smoothPinnedSendState,
              smoothPinnedSendState.phase == .preservingBottomBeforeAnimation
        else {
            return
        }
        smoothPinnedSendLaunchGate.schedule(after: Self.stagedSmoothSendStabilizationDelay) {
            launchStagedSmoothPinnedSendIfStable(proxy: proxy)
        }
    }

    private func launchStagedSmoothPinnedSendIfStable(proxy: ScrollViewProxy) {
        guard var smoothPinnedSendState,
              smoothPinnedSendState.phase == .preservingBottomBeforeAnimation
        else {
            return
        }
        if Date().timeIntervalSince(smoothPinnedSendState.startedAt) > Self.smoothPinnedSendMaxDuration {
            interruptSmoothPinnedSend(reason: "timedOut")
            return
        }
        guard currentTabID != nil,
              isPinnedToLiveBottom,
              !userDetachedAutoFollow,
              !isInteractionBlockerVisible,
              !isUserInteractingWithScroll,
              !isRehydrateRestoreActive
        else {
            return
        }
        let stillStabilizing = pendingCompressionRestoreStrategy != nil
            || programmaticScrollGate.isInFlight
            || pendingPinnedBottomSource != nil
            || deferredPinnedCorrectionAfterSmoothSend != nil
            || Date().timeIntervalSince(smoothPinnedSendState.lastLayoutMutationAt) < Self.stagedSmoothSendStabilizationDelay
        if stillStabilizing {
            scheduleStagedSmoothPinnedSendLaunchIfNeeded(proxy: proxy)
            return
        }
        if isNearBottom {
            _ = finishSmoothPinnedSendWithoutAnimation(reason: "alreadyNearBottomAfterStabilization")
            return
        }
        if scrollMetrics.distanceToBottom <= Self.stagedSmoothSendMinimumAnimationDistance {
            requestPinnedLiveBottom(proxy: proxy, source: .transcriptChangeWhilePinned)
            scheduleStagedSmoothPinnedSendLaunchIfNeeded(proxy: proxy)
            return
        }
        smoothPinnedSendState.phase = .animatingToBottom
        self.smoothPinnedSendState = smoothPinnedSendState
        notePinnedBottomRequest()
        #if DEBUG
            if isStressHarnessEnabled {
                noteStressHarness("Smooth send animation launched after stabilization: distance=\(Int(scrollMetrics.distanceToBottom))")
            }
        #endif
        requestScroll(
            proxy,
            intent: .bottom(animated: true, reason: .userSendWhilePinned),
            immediate: true
        )
    }

    @discardableResult
    private func completeSmoothPinnedSendIfNeeded(settleReason: AgentTranscriptScrollReason? = nil) -> Bool {
        guard let smoothPinnedSendState else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "noState")
            return false
        }
        guard smoothPinnedSendState.phase == .animatingToBottom else {
            return false
        }
        guard currentTabID != nil else {
            self.smoothPinnedSendState = nil
            smoothPinnedSendLaunchGate.cancel()
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "noCurrentTab")
            return false
        }
        guard Date().timeIntervalSince(smoothPinnedSendState.startedAt) <= Self.smoothPinnedSendMaxDuration else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "timedOut")
            interruptSmoothPinnedSend(reason: "timedOut")
            return false
        }
        guard !isRehydrateRestoreActive else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "rehydrateActive")
            return false
        }
        guard !isUserInteractingWithScroll else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "userInteracting")
            return false
        }
        guard isPinnedToLiveBottom else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "notPinned")
            return false
        }
        guard isNearBottom else {
            logSmoothPinnedSendCompletionFailure(reason: settleReason, outcome: "notNearBottom")
            return false
        }
        let durationMS = max(0, Date().timeIntervalSince(smoothPinnedSendState.startedAt) * 1000)
        self.smoothPinnedSendState = nil
        smoothPinnedSendLaunchGate.cancel()
        bottomClearanceSuppressionUntil = Date().addingTimeInterval(0.20)
        #if DEBUG
            guard isStressHarnessEnabled else { return true }
            stressTelemetryState.smoothSendCompletionCount += 1
            noteStressHarness("Smooth send completed: durationMS=\(Int(durationMS)) distance=\(Int(scrollMetrics.distanceToBottom))")
            stressTelemetryState.lastSmoothSendSettleDurationMS = durationMS
            stressTelemetryState.maxSmoothSendSettleDurationMS = max(
                stressTelemetryState.maxSmoothSendSettleDurationMS,
                durationMS
            )
            publishStressTelemetrySnapshot()
        #endif
        return true
    }

    private func logSmoothPinnedSendCompletionFailure(reason: AgentTranscriptScrollReason?, outcome: String) {
        #if DEBUG
            guard isStressHarnessEnabled, let reason else { return }
            noteStressHarness("Smooth send completion blocked: settleReason=\(reason) outcome=\(outcome) distance=\(Int(scrollMetrics.distanceToBottom)) nearBottom=\(isNearBottom) pinned=\(isPinnedToLiveBottom) inFlight=\(programmaticScrollGate.isInFlight)")
        #endif
    }

    private func interruptSmoothPinnedSend(reason: String) {
        guard smoothPinnedSendState != nil else { return }
        smoothPinnedSendState = nil
        clearPinnedBottomProtection()
        smoothPinnedSendLaunchGate.cancel()
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            let shouldCountInterruption = reason != "expired" && reason != "timedOut" && reason != "tabChange"
            if shouldCountInterruption {
                stressTelemetryState.smoothSendInterruptedCount += 1
            }
            noteStressHarness("Smooth send interrupted: reason=\(reason) distance=\(Int(scrollMetrics.distanceToBottom)) pinned=\(isPinnedToLiveBottom) inFlight=\(programmaticScrollGate.isInFlight)")
            stressTelemetryState.lastScrollIntentReason = "smoothInterrupted:\(reason)"
            publishStressTelemetrySnapshot()
        #endif
    }

    private func isSmoothPinnedSendActive(for tabID: UUID?) -> Bool {
        guard let smoothPinnedSendState, tabID == currentTabID else { return false }
        guard Date().timeIntervalSince(smoothPinnedSendState.startedAt) <= Self.smoothPinnedSendMaxDuration else {
            interruptSmoothPinnedSend(reason: "expired")
            return false
        }
        guard !userDetachedAutoFollow,
              isPinnedToLiveBottom,
              !isInteractionBlockerVisible,
              !isUserInteractingWithScroll,
              !isRehydrateRestoreActive
        else {
            return false
        }
        return true
    }

    private func markColdRestoreStart() {
        scrollEngine.rehydrate.coldRestoreStartedAt = Date()
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            stressTelemetryState.coldRestoreStartCount += 1
            publishStressTelemetrySnapshot()
        #endif
    }

    private func markColdRestoreBottomRequest(corrective: Bool) {
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            stressTelemetryState.coldRestoreScrollCount += 1
            if corrective {
                stressTelemetryState.coldRestoreCorrectiveScrollCount += 1
            }
            publishStressTelemetrySnapshot()
        #endif
    }

    private func markColdRestoreCompletion() {
        guard let startedAt = scrollEngine.rehydrate.coldRestoreStartedAt else { return }
        let durationMS = max(0, Date().timeIntervalSince(startedAt) * 1000)
        scrollEngine.rehydrate.coldRestoreStartedAt = nil
        scrollEngine.rehydrate.scrollResponsivenessSuppressedUntil = Date().addingTimeInterval(Self.restoreScrollResponsivenessSuppressionDuration)
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            stressTelemetryState.coldRestoreCompletionCount += 1
            stressTelemetryState.lastColdRestoreSettleDurationMS = durationMS
            stressTelemetryState.maxColdRestoreSettleDurationMS = max(
                stressTelemetryState.maxColdRestoreSettleDurationMS,
                durationMS
            )
            publishStressTelemetrySnapshot()
        #endif
    }

    private func currentFollowArmingState(for tabID: UUID) -> AgentModeViewModel.AgentTranscriptAutoFollowArmingState {
        if transcriptSnapshot.followBindingState.tabID == tabID {
            return transcriptSnapshot.followBindingState.armingState
        }
        return transcriptSnapshot.fallbackFollowArmingState
    }

    private func rehydrateRestoreTarget(for tabID: UUID) -> AgentTranscriptRehydrateRestoreTarget {
        // Always restore to the bottom of the transcript when loading/switching
        // sessions. Restoring a previously-detached scroll position is
        // disorienting — the user expects to see the latest content.
        .liveBottom
    }

    private func applyLocalAttachment(for target: AgentTranscriptRehydrateRestoreTarget, tabID: UUID) {
        switch target {
        case .liveBottom:
            applyTranscriptAttachmentTarget(.liveBottom, syncToSession: false)
        case .detached:
            let armingState = currentFollowArmingState(for: tabID)
            applyTranscriptAttachmentTarget(
                .detached(userInitiated: armingState == .disarmedAfterManualDetach),
                syncToSession: false
            )
            setCurrentAutoFollowArmingState(armingState)
        }
    }

    private func rehydrateRestoreIntent(
        for target: AgentTranscriptRehydrateRestoreTarget,
        tabID: UUID
    ) -> AgentTranscriptScrollIntent? {
        switch target {
        case .liveBottom:
            .bottom(animated: false, reason: .sessionSwitchRestore)
        case .detached:
            .bottom(animated: false, reason: .sessionSwitchRestore)
        }
    }

    private func resetActivationRepaintRemountTracking() {
        activationRepaintRemountKey = nil
        activationRepaintRemountCount = 0
    }

    private func remountTranscriptForActivationRepaint(key: AgentTranscriptRehydrateRetryKey) {
        debugLog(
            "activationRepaintRemount",
            details: "tab=\(debugShortID(key.tabID)) revision=\(key.presentationRevision) count=\(activationRepaintRemountCount + 1)"
        )
        cancelAllScheduledScrollWork()
        rehydrateLayoutPassToken &+= 1
        let remountKey = AgentTranscriptRehydrateRetryKey(
            tabID: key.tabID,
            presentationRevision: key.presentationRevision,
            layoutPassToken: rehydrateLayoutPassToken
        )
        activationRepaintRemountKey = remountKey
        activationRepaintRemountCount += 1
        lastSettledRehydrateRetryKey = nil
        currentRehydrateLayoutSampleKey = nil
        switch rehydrateRestorePhase {
        case let .awaitingLayout(tabID, _, target),
             let .driving(tabID, _, target):
            rehydrateRestorePhase = .awaitingHydration(tabID: tabID, target: target)
        case .idle, .awaitingHydration:
            break
        }
        clearLiveTranscriptViewportCaptureState(shouldResetDetachedRebaseTracking: false)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transcriptScrollResetRevision &+= 1
        }
    }

    private func remountTranscriptForAlreadyHydratedActivationIfNeeded() {
        let newSignal = restoreSignal
        let oldSignal = AgentTranscriptRestoreSignal(
            tabID: nil,
            bindingsHydrated: false,
            presentationRevision: newSignal.presentationRevision
        )
        if let remountKey = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: currentTabID,
            rehydratePhase: rehydrateRestorePhase,
            lastRemountKey: activationRepaintRemountKey,
            remountCount: activationRepaintRemountCount,
            layoutPassToken: rehydrateLayoutPassToken
        ) {
            remountTranscriptForActivationRepaint(key: remountKey)
        }
    }

    private func armRehydrateRestore(for tabID: UUID?) {
        debugLog("armRehydrateRestore", details: "target=\(debugShortID(tabID))")
        resetActivationRepaintRemountTracking()
        rehydrateLayoutPassToken &+= 1
        lastSettledRehydrateRetryKey = nil
        currentRehydrateLayoutSampleKey = nil
        scrollEngine.rehydrate.scrollResponsivenessSuppressedUntil = nil
        cancelScrollResponsivenessObservations()
        invalidatePinnedMaintenance(.activationRestoreStarted)
        cancelAllScheduledScrollWork()
        scrollEngine.rehydrate.pinnedJumpTelemetrySuppressedUntil = Date().addingTimeInterval(0.25)
        #if DEBUG
            if isStressHarnessEnabled {
                noteStressHarness("Restore jump telemetry suppression armed at restore start")
            }
        #endif
        guard let tabID else {
            endRehydrateRestore(clearDidChatChange: true)
            return
        }
        didChatChange = true
        let target = rehydrateRestoreTarget(for: tabID)
        applyLocalAttachment(for: target, tabID: tabID)
        markColdRestoreStart()
        rehydrateRestorePhase = .awaitingHydration(tabID: tabID, target: target)
        remountTranscriptForAlreadyHydratedActivationIfNeeded()
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func endRehydrateRestore(clearDidChatChange: Bool) {
        debugLog("endRehydrateRestore", details: "clearDidChatChange=\(clearDidChatChange)")
        rehydrateLayoutPassToken &+= 1
        lastSettledRehydrateRetryKey = nil
        currentRehydrateLayoutSampleKey = nil
        scrollEngine.rehydrate.coldRestoreStartedAt = nil
        scrollEngine.rehydrate.pinnedJumpTelemetrySuppressedUntil = nil
        rehydrateRestorePhase = .idle
        #if DEBUG
            if isStressHarnessEnabled {
                noteStressHarness("Restore jump telemetry suppression ended")
            }
        #endif
        if clearDidChatChange {
            clearTransientChatChangeMarkerSoon()
        }
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func cancelRehydrateRestore() {
        debugLog("cancelRehydrateRestore")
        endRehydrateRestore(clearDidChatChange: true)
        // Note: assertion is already called inside endRehydrateRestore
    }

    private func scheduleAwaitingLayoutRestore(
        for tabID: UUID,
        presentationRevision: Int,
        proxy: ScrollViewProxy
    ) {
        rehydrateLayoutPassToken &+= 1
        let token = rehydrateLayoutPassToken
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard token == rehydrateLayoutPassToken else { return }
            guard case let .awaitingLayout(phaseTabID, phaseRevision, target) = rehydrateRestorePhase else { return }
            guard phaseTabID == tabID, phaseRevision == presentationRevision else { return }
            guard currentTabID == tabID else { return }
            guard isCurrentTranscriptPresentationHydrated else {
                rehydrateRestorePhase = .awaitingHydration(tabID: tabID, target: target)
                return
            }
            rehydrateRestorePhase = .driving(tabID: tabID, presentationRevision: presentationRevision, target: target)
            if case .liveBottom = target {
                markColdRestoreBottomRequest(corrective: false)
            }
            if let restoreIntent = rehydrateRestoreIntent(for: target, tabID: tabID) {
                requestScroll(proxy, intent: restoreIntent, immediate: true)
            } else {
                finishRehydrateRestoreIfSettled()
            }
        }
    }

    @discardableResult
    private func advanceRehydrateRestoreIfNeeded(proxy: ScrollViewProxy) -> Bool {
        debugLog("advanceRehydrateRestoreIfNeeded begin")
        guard let currentTabID else {
            endRehydrateRestore(clearDidChatChange: true)
            return false
        }
        switch rehydrateRestorePhase {
        case .idle:
            debugLog("advanceRehydrateRestoreIfNeeded idle")
            return false
        case let .awaitingHydration(tabID, target):
            guard tabID == currentTabID else {
                debugLog("advanceRehydrateRestoreIfNeeded awaiting tab mismatch", details: "phaseTab=\(debugShortID(tabID)) currentTab=\(debugCurrentTabLabel)")
                endRehydrateRestore(clearDidChatChange: true)
                return false
            }
            applyLocalAttachment(for: target, tabID: currentTabID)
            guard isCurrentTranscriptPresentationHydrated else {
                debugLog("advanceRehydrateRestoreIfNeeded awaiting hydration")
                return true
            }
            let presentationRevision = currentTranscriptPresentationRevision
            debugLog("advanceRehydrateRestoreIfNeeded enter awaitingLayout", details: "presentationRevision=\(presentationRevision)")
            retainOnlyCurrentRehydrateLayoutSample(
                tabID: currentTabID,
                presentationRevision: presentationRevision
            )
            rehydrateRestorePhase = .awaitingLayout(
                tabID: currentTabID,
                presentationRevision: presentationRevision,
                target: target
            )
            scheduleAwaitingLayoutRestore(for: currentTabID, presentationRevision: presentationRevision, proxy: proxy)
            return true
        case let .awaitingLayout(tabID, presentationRevision, target):
            guard tabID == currentTabID else {
                endRehydrateRestore(clearDidChatChange: true)
                return false
            }
            guard !isUserInteractingWithScroll else {
                endRehydrateRestore(clearDidChatChange: true)
                return false
            }
            applyLocalAttachment(for: target, tabID: currentTabID)
            if !isCurrentTranscriptPresentationHydrated {
                rehydrateRestorePhase = .awaitingHydration(tabID: currentTabID, target: target)
                return true
            }
            let currentRevision = currentTranscriptPresentationRevision
            if currentRevision != presentationRevision {
                retainOnlyCurrentRehydrateLayoutSample(
                    tabID: currentTabID,
                    presentationRevision: currentRevision
                )
                rehydrateRestorePhase = .awaitingLayout(
                    tabID: currentTabID,
                    presentationRevision: currentRevision,
                    target: target
                )
                scheduleAwaitingLayoutRestore(for: currentTabID, presentationRevision: currentRevision, proxy: proxy)
            }
            return true
        case let .driving(tabID, presentationRevision, target):
            guard tabID == currentTabID else {
                debugLog("advanceRehydrateRestoreIfNeeded driving tab mismatch", details: "phaseTab=\(debugShortID(tabID)) currentTab=\(debugCurrentTabLabel)")
                endRehydrateRestore(clearDidChatChange: true)
                return false
            }
            guard !isUserInteractingWithScroll else {
                debugLog("advanceRehydrateRestoreIfNeeded canceled by user interaction")
                endRehydrateRestore(clearDidChatChange: true)
                return false
            }
            applyLocalAttachment(for: target, tabID: currentTabID)
            if !isCurrentTranscriptPresentationHydrated {
                debugLog("advanceRehydrateRestoreIfNeeded driving fell back to awaiting")
                rehydrateRestorePhase = .awaitingHydration(tabID: currentTabID, target: target)
                return true
            }
            let currentRevision = currentTranscriptPresentationRevision
            if currentRevision != presentationRevision {
                debugLog("advanceRehydrateRestoreIfNeeded reassert restore", details: "oldRevision=\(presentationRevision) currentRevision=\(currentRevision)")
                retainOnlyCurrentRehydrateLayoutSample(
                    tabID: currentTabID,
                    presentationRevision: currentRevision
                )
                rehydrateRestorePhase = .driving(
                    tabID: currentTabID,
                    presentationRevision: currentRevision,
                    target: target
                )
                if case .liveBottom = target {
                    markColdRestoreBottomRequest(corrective: false)
                }
                if let restoreIntent = rehydrateRestoreIntent(for: target, tabID: currentTabID) {
                    requestScroll(proxy, intent: restoreIntent, immediate: true)
                } else {
                    finishRehydrateRestoreIfSettled()
                }
                return true
            }
            debugLog("advanceRehydrateRestoreIfNeeded driving waiting for settle")
            finishRehydrateRestoreIfSettled()
            return true
        }
    }

    private enum RehydrateRestoreContinuationSource {
        case geometry
        case settled
    }

    private func continueRehydrateRestoreIfNeeded(proxy: ScrollViewProxy, source: RehydrateRestoreContinuationSource) -> Bool {
        guard source == .settled else { return false }
        guard case let .driving(tabID, _, target) = rehydrateRestorePhase else { return false }
        guard case .liveBottom = target else { return false }
        guard tabID == currentTabID else { return false }
        guard !programmaticScrollGate.isInFlight else { return false }
        guard isCurrentTranscriptPresentationHydrated else { return false }
        guard !isUserInteractingWithScroll else { return false }
        guard !isNearBottom else { return false }
        let currentRevision = currentTranscriptPresentationRevision
        let retryKey = AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: currentRevision,
            layoutPassToken: rehydrateLayoutPassToken
        )
        guard lastSettledRehydrateRetryKey != retryKey else {
            debugLog("continueRehydrateRestoreIfNeeded skipped duplicate settled retry", details: "presentationRevision=\(currentRevision)")
            return false
        }
        lastSettledRehydrateRetryKey = retryKey
        debugLog("continueRehydrateRestoreIfNeeded reassert bottom after settle", details: "presentationRevision=\(currentRevision)")
        rehydrateRestorePhase = .driving(tabID: tabID, presentationRevision: currentRevision, target: .liveBottom)
        markColdRestoreBottomRequest(corrective: true)
        requestScroll(proxy, intent: .bottom(animated: false, reason: .sessionSwitchRestore), immediate: true)
        publishStressTelemetrySnapshot()
        return true
    }

    private func finishRehydrateRestoreIfSettled() {
        guard case let .driving(tabID, presentationRevision, target) = rehydrateRestorePhase else { return }
        debugLog("finishRehydrateRestoreIfSettled check", details: "phaseTab=\(debugShortID(tabID)) inFlight=\(programmaticScrollGate.isInFlight)")
        guard tabID == currentTabID else {
            endRehydrateRestore(clearDidChatChange: true)
            return
        }
        guard !programmaticScrollGate.isInFlight else { return }
        guard isCurrentTranscriptPresentationHydrated else { return }
        guard !isUserInteractingWithScroll else {
            endRehydrateRestore(clearDidChatChange: true)
            return
        }
        if case .liveBottom = target {
            guard canCompleteLiveBottomRehydrateRestore(
                tabID: tabID,
                presentationRevision: presentationRevision
            ) else {
                debugLog(
                    "finishRehydrateRestoreIfSettled awaiting valid layout",
                    details: "sample=\(String(describing: currentRehydrateLayoutSampleKey)) presentationRevision=\(presentationRevision) nearBottom=\(isNearBottom)"
                )
                return
            }
        }
        debugLog("finishRehydrateRestoreIfSettled completed")
        markColdRestoreCompletion()
        endRehydrateRestore(clearDidChatChange: true)
    }

    private func clearPendingDetachedSettleCaptureState() {
        detachedRebase.clearSettleCapture()
    }

    private enum AgentTranscriptAttachmentTarget {
        case liveBottom
        case detached(userInitiated: Bool)
    }

    private func applyTranscriptAttachmentTarget(
        _ target: AgentTranscriptAttachmentTarget,
        syncToSession: Bool
    ) {
        switch target {
        case .liveBottom:
            clearPinnedTranscriptChangeSuppression()
            clearPinnedIdleTransitionManualDetach()
            clearManualDetachOverride()
            isPinnedToLiveBottom = true
            userDetachedAutoFollow = false
            userScroll.reset()
            bottomScrollOutcome.reset()
            resetPinnedBottomRequestState()
            resetDetachedRebaseTracking()
            clearPendingDetachedSettleCaptureState()
            pendingDetachedAnchorChangeAnchor = nil
            pendingDetachedAnchorChangeBlockID = nil
            topVisibleViewportTargetID = nil
            topVisibleViewportAnchor = nil
            topVisibleViewportSequenceIndex = nil
            topVisibleViewportFallbackBlockID = nil
            topVisibleViewportMinY = nil
            detachedPresentationRevisionCheckToken &+= 1
            if syncToSession,
               let currentTabID
            {
                agentModeVM.setTranscriptDetachedFromLiveBottom(tabID: currentTabID, isDetached: false)
            }
        case let .detached(userInitiated):
            clearPinnedTranscriptChangeSuppression()
            clearPinnedIdleTransitionManualDetach()
            if userInitiated {
                cancelPendingScrollWork()
                armManualDetachOverride()
            }
            clearPinnedBottomProtection()
            isPinnedToLiveBottom = false
            resetPinnedBottomRequestState()
            repinGraceState = nil
            interruptSmoothPinnedSend(reason: userInitiated ? "detached" : "unpinned")
            userDetachedAutoFollow = true
            userScroll.reset()
            cancelPendingBottomScrollOutcome(reason: userInitiated ? "manualDetach" : "detachedStateChange")
            if syncToSession,
               let currentTabID
            {
                agentModeVM.setTranscriptDetachedFromLiveBottom(
                    tabID: currentTabID,
                    isDetached: true,
                    armingState: userInitiated ? .disarmedAfterManualDetach : nil
                )
            } else if userInitiated {
                setCurrentAutoFollowArmingState(.disarmedAfterManualDetach)
            }
        }
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func applyStoredTranscriptViewportState(for tabID: UUID?) {
        agentModeVM.normalizeTranscriptFollowStateForViewActivation(tabID: tabID)
        clearManualDetachOverride()
        clearPinnedIdleTransitionManualDetach()
        clearPinnedTranscriptChangeSuppression()
        clearPinnedBottomProtection()
        userScroll.reset()
        bottomScrollOutcome.reset()
        // Always pin to the bottom when activating a session.
        applyTranscriptAttachmentTarget(.liveBottom, syncToSession: false)
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func pinToLiveBottom() {
        let wasPinned = isPinnedToLiveBottom && !userDetachedAutoFollow
        if !wasPinned {
            invalidatePinnedMaintenance(.liveBottomReattached)
        }
        applyTranscriptAttachmentTarget(.liveBottom, syncToSession: true)
        #if DEBUG
            debugConsoleLog("pinToLiveBottom", details: "wasPinned=\(wasPinned)")
        #endif
        if !wasPinned {
            #if DEBUG
                if isStressHarnessEnabled {
                    stressTelemetryState.repinCount += 1
                }
            #endif
            publishStressTelemetrySnapshot()
        }
    }

    private func handleStressForceDetach(proxy: ScrollViewProxy) {
        _ = proxy
        let wasAlreadyDetached = userDetachedAutoFollow && !isPinnedToLiveBottom
        detachFromLiveBottom(markUserDetached: true)
        #if DEBUG
            if isStressHarnessEnabled, wasAlreadyDetached {
                stressTelemetryState.detachCount += 1
                noteStressHarness("Force detach confirmed while already detached")
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    #if DEBUG
    #endif

    private func detachFromLiveBottom(markUserDetached: Bool, updateTranscriptWindowDetachment: Bool = true) {
        let wasPinned = isPinnedToLiveBottom && !userDetachedAutoFollow
        if wasPinned {
            invalidatePinnedMaintenance(.detached)
        }
        applyTranscriptAttachmentTarget(
            .detached(userInitiated: markUserDetached),
            syncToSession: updateTranscriptWindowDetachment
        )
        if wasPinned {
            #if DEBUG
                debugConsoleLog(
                    "detachFromLiveBottom",
                    details: "wasPinned=\(wasPinned) markUserDetached=\(markUserDetached) updateWindowDetachment=\(updateTranscriptWindowDetachment)"
                )
                if isStressHarnessEnabled {
                    stressTelemetryState.detachCount += 1
                }
            #endif
            publishStressTelemetrySnapshot()
        }
    }

    private func handleInteractionBlockerPresented() {
        invalidatePinnedMaintenance(.blockerPresented)
        clearManualDetachOverride()
        shouldRestorePinnedBottomAfterBlocker = isPinnedToLiveBottom || (userDetachedAutoFollow && isDetachedAutoFollowRepinArmed && isNearBottom)
        cancelAllScheduledScrollWork()
        cancelScrollResponsivenessObservations()
        repinGraceState = nil
        interruptSmoothPinnedSend(reason: "blockerPresented")
        cancelRehydrateRestore()
        applyTranscriptAttachmentTarget(.detached(userInitiated: false), syncToSession: false)
        legacyIsNearBottom = false
        isUserInteractingWithScroll = false
        didChatChange = false
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func restorePinnedBottomAfterBlockerIfNeeded(proxy: ScrollViewProxy) {
        guard shouldRestorePinnedBottomAfterBlocker else { return }
        shouldRestorePinnedBottomAfterBlocker = false
        pinToLiveBottom()
        beginRepinGrace(reason: .blockerDismissed)
        requestScroll(proxy, intent: .bottom(animated: false, reason: .blockerDismissed))
        #if DEBUG
            assertScrollStateInvariants()
        #endif
    }

    private func recordScrollIntent(_ reason: AgentTranscriptScrollReason) {
        #if DEBUG
            guard isStressHarnessEnabled else { return }
            stressTelemetryState.scrollIntentCount += 1
            if reason == .userSendWhilePinned {
                stressTelemetryState.smoothSendScrollCount += 1
            }
            stressTelemetryState.lastScrollIntentReason = String(describing: reason)
            publishStressTelemetrySnapshot()
        #endif
    }

    private var effectiveStressTopVisibleBlockID: String? {
        userDetachedAutoFollow ? (topVisibleViewportFallbackBlockID ?? topVisibleBlockID) : topVisibleBlockID
    }

    private var effectiveStressDetachedAuthorityAnchorDescription: String? {
        let effectiveTopVisibleAnchor = userDetachedAutoFollow
            ? (topVisibleViewportAnchor ?? topVisibleBlockAnchor)
            : topVisibleBlockAnchor
        guard userDetachedAutoFollow, !isUserInteractingWithScroll else { return nil }
        return effectiveTopVisibleAnchor.map(String.init(describing:))
    }

    private var effectiveStressTopVisibleAnchorDescription: String? {
        let effectiveTopVisibleAnchor = userDetachedAutoFollow
            ? (topVisibleViewportAnchor ?? topVisibleBlockAnchor)
            : topVisibleBlockAnchor
        return effectiveStressDetachedAuthorityAnchorDescription
            ?? effectiveTopVisibleAnchor.map(String.init(describing:))
    }

    private static let largeStreamingAssistantCharacterThreshold = 12000
    private static let largeStreamingAssistantLineThreshold = 220
    private static let largeStreamingTelemetryGraceDuration: TimeInterval = 1.5

    private var activeStressStreamingAssistantItem: AgentChatItem? {
        transcriptPresentation.visibleRows.reversed().first { item in
            (item.kind == .assistant || item.kind == .assistantInline) && item.isStreaming
        }
    }

    private var activeStressStreamingAssistantCharacterCount: Int {
        activeStressStreamingAssistantItem?.text.count ?? 0
    }

    private var activeStressStreamingAssistantLineCount: Int {
        Self.streamingAssistantLineCount(activeStressStreamingAssistantItem?.text ?? "")
    }

    private var isLargeStressStreamingAssistantActive: Bool {
        guard activeStressStreamingAssistantItem != nil else { return false }
        return activeStressStreamingAssistantCharacterCount >= Self.largeStreamingAssistantCharacterThreshold
            || activeStressStreamingAssistantLineCount >= Self.largeStreamingAssistantLineThreshold
    }

    private func isLargeStressStreamingContextActive(now: Date = Date()) -> Bool {
        if isLargeStressStreamingAssistantActive {
            return true
        }
        #if DEBUG
            guard let lastLargeStreamingAssistantActiveAt = stressTelemetryState.lastLargeStreamingAssistantActiveAt else {
                return false
            }
            return now.timeIntervalSince(lastLargeStreamingAssistantActiveAt) <= Self.largeStreamingTelemetryGraceDuration
        #else
            return false
        #endif
    }

    private static func streamingAssistantLineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private func cancelScrollResponsivenessObservations() {
        userScroll.reset()
        isUserInteractingWithScroll = false
        currentUserScrollPhase = .idle
        cancelPendingBottomScrollOutcome(reason: "cancelAllScrollResponsivenessObservations")
    }

    private func isBottomScrollOutcomeContextValid(_ source: AgentTranscriptBottomScrollOutcomeSource) -> Bool {
        guard supportsAutoScroll,
              let currentTabID,
              pendingBottomScrollOutcome?.tabID == currentTabID,
              !isUserInteractingWithScroll
        else {
            return false
        }
        switch source {
        case .explicitBottomAction:
            return !isInteractionBlockerVisible && !isRehydrateRestoreActive
        case .pinnedFollowMaintenance:
            return isPinnedToLiveBottom
                && !userDetachedAutoFollow
                && !isInteractionBlockerVisible
                && !isRehydrateRestoreActive
        }
    }

    private func bottomScrollOutcomeSource(for reason: AgentTranscriptScrollReason) -> AgentTranscriptBottomScrollOutcomeSource? {
        switch reason {
        case .bottomButtonTap:
            .explicitBottomAction
        case .transcriptChangeWhilePinned,
             .waitingStateChange,
             .busyStateChange,
             .bottomClearanceChange,
             .nearBottomReengaged,
             .userSendWhilePinned,
             .userSendWhileDetached:
            .pinnedFollowMaintenance
        default:
            nil
        }
    }

    private func recordPendingBottomScrollOutcomeLayoutMutationIfNeeded(
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics
    ) {
        guard let pendingBottomScrollOutcome,
              pendingBottomScrollOutcome.didExecute
        else {
            return
        }
        guard AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: oldMetrics,
            newMetrics: newMetrics,
            contentHeightThreshold: Self.bottomScrollOutcomeContentHeightMutationThreshold,
            viewportHeightThreshold: Self.bottomScrollOutcomeViewportHeightMutationThreshold
        ) else {
            return
        }
        pendingBottomScrollOutcomeLastLayoutMutationAt = Date()
    }

    private func scheduleDeferredPendingBottomScrollOutcomeResolve(
        for settleReason: AgentTranscriptScrollReason,
        after delay: TimeInterval
    ) {
        deferredPendingBottomScrollOutcomeTask?.cancel()
        let generationToken = pendingBottomScrollOutcomeGenerationToken
        deferredPendingBottomScrollOutcomeTask = Task { @MainActor in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  generationToken == pendingBottomScrollOutcomeGenerationToken
            else {
                return
            }
            deferredPendingBottomScrollOutcomeTask = nil
            resolvePendingBottomScrollOutcomeOnSettled(for: settleReason)
        }
    }

    private func cancelPendingBottomScrollOutcome(
        reason: String,
        matchingSource: AgentTranscriptBottomScrollOutcomeSource? = nil,
        onlyIfUnexecuted: Bool = false
    ) {
        guard let pendingBottomScrollOutcome else { return }
        if let matchingSource, pendingBottomScrollOutcome.source != matchingSource {
            return
        }
        if onlyIfUnexecuted, pendingBottomScrollOutcome.didExecute {
            return
        }
        bottomScrollOutcome.reset()
        #if DEBUG
            debugConsoleLog(
                "bottomScrollOutcome canceled",
                details: "reason=\(reason) source=\(pendingBottomScrollOutcome.source) executed=\(pendingBottomScrollOutcome.didExecute)"
            )
            if isStressHarnessEnabled, pendingBottomScrollOutcome.source == .explicitBottomAction {
                stressTelemetryState.lastScrollToBottomOutcome = "canceled"
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    private func cancelPendingBottomScrollOutcomeIfUnexecuted(reason: String = "cancelUnexecutedPendingBottomOutcome") {
        cancelPendingBottomScrollOutcome(reason: reason, onlyIfUnexecuted: true)
    }

    private func cancelInvalidPendingBottomScrollOutcome(reason: String) {
        guard let pendingBottomScrollOutcome else { return }
        guard !isBottomScrollOutcomeContextValid(pendingBottomScrollOutcome.source) else { return }
        cancelPendingBottomScrollOutcome(reason: reason)
    }

    private var hasPendingExplicitBottomScrollOutcome: Bool {
        guard let pendingBottomScrollOutcome,
              pendingBottomScrollOutcome.tabID == currentTabID
        else {
            return false
        }
        return pendingBottomScrollOutcome.source == .explicitBottomAction
    }

    private func shouldSuppressPinnedMaintenanceWhileExplicitBottomOutcomePending(
        source: PinnedBottomRequestSource
    ) -> Bool {
        guard hasPendingExplicitBottomScrollOutcome else { return false }
        switch source {
        case .transcriptChangeWhilePinned, .waitingStateChange, .busyStateChange, .bottomClearanceChange:
            return true
        case .smoothSend:
            return false
        }
    }

    private func shouldAbortCompetingPinnedMaintenanceDuringExplicitBottomOutcome(
        _ reason: AgentTranscriptScrollReason
    ) -> Bool {
        hasPendingExplicitBottomScrollOutcome && isPinnedMaintenanceReason(reason)
    }

    private func beginPendingBottomScrollOutcomeIfNeeded(for reason: AgentTranscriptScrollReason) {
        guard let source = bottomScrollOutcomeSource(for: reason),
              supportsAutoScroll,
              let currentTabID,
              isCurrentTranscriptPresentationHydrated
        else {
            return
        }
        if source == .pinnedFollowMaintenance, hasPendingExplicitBottomScrollOutcome {
            return
        }
        if let pendingBottomScrollOutcome,
           pendingBottomScrollOutcome.tabID == currentTabID,
           pendingBottomScrollOutcome.source == source,
           !pendingBottomScrollOutcome.didExecute
        {
            return
        }

        bottomScrollOutcome.prepareForNewPendingOutcome()
        pendingBottomScrollOutcome = PendingBottomScrollOutcome(
            tabID: currentTabID,
            startedAt: Date(),
            baselineDistanceToBottom: scrollMetrics.distanceToBottom,
            source: source
        )
        cancelDetachedPresentationRevisionCheck()
        #if DEBUG
            debugConsoleLog(
                "bottomScrollOutcome began",
                details: "source=\(source) distance=\(Int(scrollMetrics.distanceToBottom)) reason=\(reason)"
            )
            if isStressHarnessEnabled {
                if source == .explicitBottomAction {
                    stressTelemetryState.scrollToBottomTapCount += 1
                }
                stressTelemetryState.lastScrollToBottomOutcome = "pending"
                noteStressHarness(
                    "Bottom scroll outcome began: source=\(source) distance=\(Int(scrollMetrics.distanceToBottom)) reason=\(reason)"
                )
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    private func markPendingBottomScrollOutcomeExecutedIfNeeded(for reason: AgentTranscriptScrollReason) -> Bool {
        guard var pendingBottomScrollOutcome,
              pendingBottomScrollOutcome.tabID == currentTabID
        else {
            return false
        }
        switch (pendingBottomScrollOutcome.source, reason) {
        case (.explicitBottomAction, .bottomButtonTap):
            pendingBottomScrollOutcome.didExecute = true
            self.pendingBottomScrollOutcome = pendingBottomScrollOutcome
            return true
        case (.pinnedFollowMaintenance, _) where isPinnedMaintenanceReason(reason):
            pendingBottomScrollOutcome.didExecute = true
            self.pendingBottomScrollOutcome = pendingBottomScrollOutcome
            return true
        default:
            return false
        }
    }

    private func resolvePendingBottomScrollOutcomeOnSettled(for settleReason: AgentTranscriptScrollReason) {
        guard let pendingBottomScrollOutcome,
              currentTabID == pendingBottomScrollOutcome.tabID
        else {
            return
        }
        guard isBottomScrollOutcomeContextValid(pendingBottomScrollOutcome.source) else {
            cancelPendingBottomScrollOutcome(reason: "invalidSettledContext")
            return
        }
        let now = Date()
        if pendingBottomScrollOutcome.didExecute,
           now.timeIntervalSince(pendingBottomScrollOutcome.startedAt) < Self.bottomScrollOutcomeMaxPendingAge,
           let quietDelay = AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
               lastLayoutMutationAt: pendingBottomScrollOutcomeLastLayoutMutationAt,
               now: now,
               quietPeriod: Self.bottomScrollOutcomeLayoutQuietPeriod
           )
        {
            scheduleDeferredPendingBottomScrollOutcomeResolve(for: settleReason, after: quietDelay)
            return
        }
        deferredPendingBottomScrollOutcomeTask?.cancel()
        deferredPendingBottomScrollOutcomeTask = nil

        let reachedBottom = isNearBottom || scrollMetrics.distanceToBottom <= Self.scrollToBottomSuccessDistanceThreshold
        let outcome: String
        if pendingBottomScrollOutcome.didExecute, reachedBottom {
            outcome = "reachedBottom"
            bottomScrollOutcome.reset()
        } else if pendingBottomScrollOutcome.didExecute {
            outcome = "noEffect"
            bottomScrollOutcome.reset()
        } else {
            outcome = "canceled"
            bottomScrollOutcome.reset()
        }

        #if DEBUG
            debugConsoleLog(
                "bottomScrollOutcome settled",
                details: "source=\(pendingBottomScrollOutcome.source) settleReason=\(settleReason) outcome=\(outcome) baselineDistance=\(Int(pendingBottomScrollOutcome.baselineDistanceToBottom)) finalDistance=\(Int(scrollMetrics.distanceToBottom))"
            )
            if isStressHarnessEnabled {
                if pendingBottomScrollOutcome.source == .explicitBottomAction {
                    switch outcome {
                    case "reachedBottom":
                        stressTelemetryState.scrollToBottomSuccessCount += 1
                    case "noEffect":
                        stressTelemetryState.scrollToBottomNoEffectCount += 1
                    default:
                        break
                    }
                }
                stressTelemetryState.lastScrollToBottomOutcome = outcome
                noteStressHarness(
                    "Bottom scroll outcome settled: source=\(pendingBottomScrollOutcome.source) settleReason=\(settleReason) outcome=\(outcome) baselineDistance=\(Int(pendingBottomScrollOutcome.baselineDistanceToBottom)) finalDistance=\(Int(scrollMetrics.distanceToBottom))"
                )
                publishStressTelemetrySnapshot()
            }
        #endif
    }

    #if DEBUG
        private func recordPinnedHistoricalExposureIfNeeded(jumpDelta: CGFloat, newMetrics: AgentTranscriptScrollMetrics) {
            guard let threshold = stressHarnessCatastrophicHistoricalExposureBlockThreshold,
                  threshold > 0,
                  isPinnedToLiveBottom,
                  !userDetachedAutoFollow,
                  !programmaticScrollGate.isInFlight,
                  !isUserInteractingWithScroll,
                  !isInteractionBlockerVisible,
                  !isRehydrateRestoreActive,
                  newMetrics.distanceToBottom > Self.scrollButtonVisibilityThreshold || jumpDelta > Self.scrollButtonVisibilityThreshold
            else {
                stressTelemetryState.wasTrackingHistoricalExposure = false
                stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
                return
            }

            let now = Date()
            if isLargeStressStreamingAssistantActive {
                stressTelemetryState.lastLargeStreamingAssistantActiveAt = now
            }
            let catastrophicJumpThreshold = stressHarnessCatastrophicJumpThresholdPoints ?? 0
            let topVisibleBlockIndex = effectiveStressTopVisibleBlockID.flatMap { topVisibleBlockID in
                visibleTranscriptBlocks.firstIndex(where: { $0.id == topVisibleBlockID })
            }
            let tracksLargeStreamingExposure = isLargeStressStreamingContextActive(now: now)

            let triggered: Bool
            let blockID: String?
            let kind: String
            let blocksBelowTop: Int
            if let topVisibleBlockIndex {
                blocksBelowTop = max(0, visibleTranscriptBlocks.count - topVisibleBlockIndex - 1)
                guard blocksBelowTop >= threshold else {
                    stressTelemetryState.wasTrackingHistoricalExposure = false
                    stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
                    return
                }
                let block = visibleTranscriptBlocks[topVisibleBlockIndex]
                triggered = true
                blockID = block.id
                kind = block.kind.rawValue
            } else {
                let unanchoredExposureTriggered = canScrollTowardHistory
                    && catastrophicJumpThreshold > 0
                    && (jumpDelta >= catastrophicJumpThreshold || newMetrics.distanceToBottom >= catastrophicJumpThreshold)
                    && visibleTranscriptBlocks.count > threshold
                guard unanchoredExposureTriggered else {
                    stressTelemetryState.wasTrackingHistoricalExposure = false
                    stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
                    return
                }
                triggered = true
                blockID = nil
                kind = "unanchoredViewport"
                blocksBelowTop = max(threshold, visibleTranscriptBlocks.count - 1)
            }

            guard triggered else {
                stressTelemetryState.wasTrackingHistoricalExposure = false
                stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
                return
            }
            stressTelemetryState.maxUnexpectedHistoricalExposureBlocksBelowTop = max(
                stressTelemetryState.maxUnexpectedHistoricalExposureBlocksBelowTop,
                blocksBelowTop
            )
            stressTelemetryState.lastUnexpectedHistoricalExposureBlockID = blockID
            stressTelemetryState.lastUnexpectedHistoricalExposureKind = kind
            if !stressTelemetryState.wasTrackingHistoricalExposure {
                stressTelemetryState.unexpectedHistoricalExposureCount += 1
                noteStressHarness(
                    "Unexpected historical exposure while pinned: topBlock=\(blockID ?? "nil") kind=\(kind) blocksBelowTop=\(blocksBelowTop) distance=\(Int(newMetrics.distanceToBottom)) jumpDelta=\(Int(jumpDelta))"
                )
            }
            stressTelemetryState.wasTrackingHistoricalExposure = true

            if tracksLargeStreamingExposure {
                stressTelemetryState.maxLargeStreamingHistoricalExposureBlocksBelowTop = max(
                    stressTelemetryState.maxLargeStreamingHistoricalExposureBlocksBelowTop,
                    blocksBelowTop
                )
                stressTelemetryState.lastLargeStreamingHistoricalExposureBlockID = blockID
                stressTelemetryState.lastLargeStreamingHistoricalExposureKind = kind
                if !stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure {
                    stressTelemetryState.largeStreamingHistoricalExposureCount += 1
                    noteStressHarness(
                        "Large streaming markdown historical exposure recorded: topBlock=\(blockID ?? "nil") kind=\(kind) blocksBelowTop=\(blocksBelowTop) distance=\(Int(newMetrics.distanceToBottom)) jumpDelta=\(Int(jumpDelta)) chars=\(activeStressStreamingAssistantCharacterCount) lines=\(activeStressStreamingAssistantLineCount)"
                    )
                }
                stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = true
            } else {
                stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
            }
        }
    #else
        private func recordPinnedHistoricalExposureIfNeeded(jumpDelta: CGFloat, newMetrics: AgentTranscriptScrollMetrics) {}
    #endif

    private func recordScrollGeometryTransition(
        proxy: ScrollViewProxy,
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics
    ) {
        #if DEBUG
            guard isStressHarnessEnabled else {
                completeSmoothPinnedSendIfNeeded()
                return
            }
            let now = Date()
            if isLargeStressStreamingAssistantActive {
                stressTelemetryState.lastLargeStreamingAssistantActiveAt = now
            }
            let previousDistance = lastTelemetryDistanceToBottom ?? oldMetrics.distanceToBottom
            let delta = abs(newMetrics.distanceToBottom - previousDistance)
            let jumpThreshold: CGFloat = 60
            let pinnedJumpTelemetrySuppressedUntil = scrollEngine.rehydrate.pinnedJumpTelemetrySuppressedUntil
            let pinnedJumpTelemetrySuppressed = isRehydrateRestoreActive || (pinnedJumpTelemetrySuppressedUntil.map { now < $0 } ?? false)
            if !programmaticScrollGate.isInFlight,
               !isUserInteractingWithScroll,
               !isInteractionBlockerVisible,
               !pinnedJumpTelemetrySuppressed
            {
                let driftTriggered = isPinnedToLiveBottom && newMetrics.distanceToBottom > Self.scrollButtonVisibilityThreshold
                if driftTriggered {
                    stressTelemetryState.maxUnexpectedPinnedDrift = max(
                        stressTelemetryState.maxUnexpectedPinnedDrift,
                        newMetrics.distanceToBottom
                    )
                    if !stressTelemetryState.wasTrackingPinnedDrift {
                        stressTelemetryState.unexpectedPinnedDriftCount += 1
                    }
                }
                stressTelemetryState.wasTrackingPinnedDrift = driftTriggered
                let jumpTriggered = isPinnedToLiveBottom && delta > jumpThreshold
                if jumpTriggered {
                    stressTelemetryState.maxUnexpectedJumpMagnitude = max(
                        stressTelemetryState.maxUnexpectedJumpMagnitude,
                        delta
                    )
                    if !stressTelemetryState.wasTrackingJump {
                        stressTelemetryState.unexpectedJumpCount += 1
                        if isStressHarnessEnabled {
                            noteStressHarness(
                                "Unexpected pinned jump recorded: delta=\(Int(delta)) old=\(Int(previousDistance)) new=\(Int(newMetrics.distanceToBottom)) reason=\(stressTelemetryState.lastScrollIntentReason ?? "nil")"
                            )
                        }
                    }
                    let tracksLargeStreamingJump = isLargeStressStreamingContextActive(now: now)
                    if tracksLargeStreamingJump {
                        stressTelemetryState.maxLargeStreamingPinnedJumpMagnitude = max(
                            stressTelemetryState.maxLargeStreamingPinnedJumpMagnitude,
                            delta
                        )
                        if !stressTelemetryState.wasTrackingLargeStreamingJump {
                            stressTelemetryState.largeStreamingPinnedJumpCount += 1
                        }
                    }
                    if let threshold = stressHarnessCatastrophicJumpThresholdPoints,
                       delta >= threshold
                    {
                        let lastReason = stressTelemetryState.lastScrollIntentReason ?? "nil"
                        let lastSettledReason = stressTelemetryState.lastSettledBottomReason ?? "nil"
                        let pendingSource = pendingPinnedBottomSource.map(String.init(describing:)) ?? "nil"
                        let deferredSource = deferredPinnedCorrectionAfterSmoothSend.map(String.init(describing:)) ?? "nil"
                        let msSinceLastBottomSettle = lastBottomSettleAt.map { max(0, Date().timeIntervalSince($0) * 1000) } ?? -1
                        noteStressHarness(
                            "Catastrophic pinned jump recorded: delta=\(Int(delta)) old=\(Int(previousDistance)) new=\(Int(newMetrics.distanceToBottom)) reason=\(lastReason) lastSettled=\(lastSettledReason) pendingSource=\(pendingSource) deferredSource=\(deferredSource) msSinceSettle=\(Int(msSinceLastBottomSettle)) pinned=\(isPinnedToLiveBottom) inFlight=\(programmaticScrollGate.isInFlight)"
                        )
                        if tracksLargeStreamingJump, !stressTelemetryState.wasTrackingLargeStreamingJump {
                            noteStressHarness(
                                "Large streaming markdown pinned jump recorded: delta=\(Int(delta)) old=\(Int(previousDistance)) new=\(Int(newMetrics.distanceToBottom)) chars=\(activeStressStreamingAssistantCharacterCount) lines=\(activeStressStreamingAssistantLineCount) reason=\(lastReason) lastSettled=\(lastSettledReason) pendingSource=\(pendingSource) deferredSource=\(deferredSource) msSinceSettle=\(Int(msSinceLastBottomSettle))"
                            )
                        }
                    }
                    stressTelemetryState.wasTrackingLargeStreamingJump = tracksLargeStreamingJump
                } else {
                    stressTelemetryState.wasTrackingLargeStreamingJump = false
                }
                stressTelemetryState.wasTrackingJump = jumpTriggered
                recordPinnedHistoricalExposureIfNeeded(jumpDelta: delta, newMetrics: newMetrics)
            } else {
                stressTelemetryState.wasTrackingPinnedDrift = false
                stressTelemetryState.wasTrackingJump = false
                stressTelemetryState.wasTrackingHistoricalExposure = false
                stressTelemetryState.wasTrackingLargeStreamingJump = false
                stressTelemetryState.wasTrackingLargeStreamingHistoricalExposure = false
            }
            let detachedJumpTriggered = userDetachedAutoFollow
                && !isPinnedToLiveBottom
                && !isUserInteractingWithScroll
                && !isInteractionBlockerVisible
                && !isRehydrateRestoreActive
                && delta > jumpThreshold
            if detachedJumpTriggered {
                stressTelemetryState.maxDetachedJumpMagnitude = max(
                    stressTelemetryState.maxDetachedJumpMagnitude,
                    delta
                )
                if !stressTelemetryState.wasTrackingDetachedJump {
                    stressTelemetryState.detachedJumpCount += 1
                }
            }
            stressTelemetryState.wasTrackingDetachedJump = detachedJumpTriggered
            lastTelemetryDistanceToBottom = newMetrics.distanceToBottom
        #endif
        completeSmoothPinnedSendIfNeeded()
        publishStressTelemetrySnapshot()
    }

    private func publishStressTelemetrySnapshot() {
        #if DEBUG
            guard let stressHarness else { return }
            let visibleRenderStates = Array(visibleToolCardRenderStatesByID.values)
            let expandedApplyEditsCardCount = visibleRenderStates.count(where: { $0.toolName == "apply_edits" && $0.isExpanded })
            let expandedApplyEditsDiffPreviewCardCount = visibleRenderStates.count(where: {
                $0.toolName == "apply_edits" && $0.isExpanded && $0.renderMode == .diffPreview
            })
            let expandedApplyEditsMarkdownFallbackCardCount = visibleRenderStates.count(where: {
                $0.toolName == "apply_edits" && $0.isExpanded && $0.renderMode == .markdownFallback
            })
            let expandedApplyPatchCardCount = visibleRenderStates.count(where: { $0.toolName == "apply_patch" && $0.isExpanded })
            let expandedApplyPatchDiffPreviewCardCount = visibleRenderStates.count(where: {
                $0.toolName == "apply_patch" && $0.isExpanded && $0.renderMode == .diffPreview
            })
            let expandedApplyPatchMarkdownFallbackCardCount = visibleRenderStates.count(where: {
                $0.toolName == "apply_patch" && $0.isExpanded && $0.renderMode == .markdownFallback
            })
            let liveBashCardCount = visibleRenderStates.count(where: { $0.toolName == "bash" && $0.bashPhase == .live })
            let expandedLiveBashCardCount = visibleRenderStates.count(where: { $0.toolName == "bash" && $0.bashPhase == .live && $0.isExpanded })
            let completedBashCardCount = visibleRenderStates.count(where: { $0.toolName == "bash" && $0.bashPhase == .completed })
            let expandedCompletedBashCardCount = visibleRenderStates.count(where: { $0.toolName == "bash" && $0.bashPhase == .completed && $0.isExpanded })
            let latestExpandedHighSignalState = visibleRenderStates
                .filter { $0.isExpanded && ($0.toolName == "apply_edits" || $0.toolName == "apply_patch" || $0.toolName == "bash") }
                .sorted { lhs, rhs in lhs.itemID.uuidString < rhs.itemID.uuidString }
                .last
            let latestExpandedHighSignalToolDescription = latestExpandedHighSignalState.map { state in
                if state.toolName == "bash", let bashPhase = state.bashPhase {
                    return "bash-\(bashPhase.rawValue):\(debugShortID(state.itemID))"
                }
                return "\(state.toolName):\(debugShortID(state.itemID))"
            }
            let latestExpandedHighSignalRenderMode = latestExpandedHighSignalState?.renderMode?.rawValue
            let storedDetachedTargetDescription: String? = nil
            let storedDetachedAnchorDescription: String? = nil
            let detachedAuthorityAnchorDescription = effectiveStressDetachedAuthorityAnchorDescription
            let effectiveTopVisibleAnchorDescription = effectiveStressTopVisibleAnchorDescription
            let liveDetachedTargetDescription = userDetachedAutoFollow
                ? topVisibleViewportTargetID.map(String.init(describing:))
                : nil
            if isLargeStressStreamingAssistantActive {
                stressTelemetryState.lastLargeStreamingAssistantActiveAt = Date()
            }
            let activeStreamingAssistantCharacterCount = activeStressStreamingAssistantCharacterCount
            let activeStreamingAssistantLineCount = activeStressStreamingAssistantLineCount
            let isLargeStreamingAssistantActive = isLargeStressStreamingAssistantActive
            stressTelemetryState.sampleIndex += 1
            stressHarness.recordScrollSnapshot(
                .init(
                    sampleIndex: stressTelemetryState.sampleIndex,
                    timestamp: Date(),
                    tabID: currentTabID,
                    isPinnedToLiveBottom: isPinnedToLiveBottom,
                    userDetachedAutoFollow: userDetachedAutoFollow,
                    canScrollTowardHistory: canScrollTowardHistory,
                    canScrollTowardLiveBottom: canScrollTowardLiveBottom,
                    isNearBottom: isNearBottom,
                    distanceToBottom: scrollMetrics.distanceToBottom,
                    topVisibleBlockID: effectiveStressTopVisibleBlockID,
                    topVisibleAnchorDescription: effectiveTopVisibleAnchorDescription,
                    lastScrollIntentReason: stressTelemetryState.lastScrollIntentReason,
                    lastSettledBottomReason: stressTelemetryState.lastSettledBottomReason,
                    pendingPinnedBottomSourceDescription: pendingPinnedBottomSource.map(String.init(describing:)),
                    hasPendingPinnedBottomFlush: pendingPinnedBottomSource != nil,
                    deferredPinnedCorrectionSourceDescription: deferredPinnedCorrectionAfterSmoothSend.map(String.init(describing:)),
                    millisecondsSinceLastBottomSettle: lastBottomSettleAt.map { max(0, Date().timeIntervalSince($0) * 1000) },
                    scrollIntentCount: stressTelemetryState.scrollIntentCount,
                    detachCount: stressTelemetryState.detachCount,
                    repinCount: stressTelemetryState.repinCount,
                    unexpectedPinnedDriftCount: stressTelemetryState.unexpectedPinnedDriftCount,
                    maxUnexpectedPinnedDrift: stressTelemetryState.maxUnexpectedPinnedDrift,
                    unexpectedJumpCount: stressTelemetryState.unexpectedJumpCount,
                    maxUnexpectedJumpMagnitude: stressTelemetryState.maxUnexpectedJumpMagnitude,
                    unexpectedHistoricalExposureCount: stressTelemetryState.unexpectedHistoricalExposureCount,
                    maxUnexpectedHistoricalExposureBlocksBelowTop: stressTelemetryState.maxUnexpectedHistoricalExposureBlocksBelowTop,
                    lastUnexpectedHistoricalExposureBlockID: stressTelemetryState.lastUnexpectedHistoricalExposureBlockID,
                    lastUnexpectedHistoricalExposureKind: stressTelemetryState.lastUnexpectedHistoricalExposureKind,
                    activeStreamingAssistantCharacterCount: activeStreamingAssistantCharacterCount,
                    activeStreamingAssistantLineCount: activeStreamingAssistantLineCount,
                    isLargeStreamingAssistantActive: isLargeStreamingAssistantActive,
                    largeStreamingPinnedJumpCount: stressTelemetryState.largeStreamingPinnedJumpCount,
                    maxLargeStreamingPinnedJumpMagnitude: stressTelemetryState.maxLargeStreamingPinnedJumpMagnitude,
                    largeStreamingHistoricalExposureCount: stressTelemetryState.largeStreamingHistoricalExposureCount,
                    maxLargeStreamingHistoricalExposureBlocksBelowTop: stressTelemetryState.maxLargeStreamingHistoricalExposureBlocksBelowTop,
                    lastLargeStreamingHistoricalExposureBlockID: stressTelemetryState.lastLargeStreamingHistoricalExposureBlockID,
                    lastLargeStreamingHistoricalExposureKind: stressTelemetryState.lastLargeStreamingHistoricalExposureKind,
                    detachedJumpCount: stressTelemetryState.detachedJumpCount,
                    maxDetachedJumpMagnitude: stressTelemetryState.maxDetachedJumpMagnitude,
                    detachedAnchorChangeCount: stressTelemetryState.detachedAnchorChangeCount,
                    detachedSnapToTopCount: stressTelemetryState.detachedSnapToTopCount,
                    storedDetachedTargetDescription: storedDetachedTargetDescription,
                    storedDetachedAnchorDescription: storedDetachedAnchorDescription,
                    storedDetachedViewportMinY: nil,
                    liveDetachedTargetDescription: liveDetachedTargetDescription,
                    liveDetachedViewportMinY: userDetachedAutoFollow ? topVisibleViewportMinY : nil,
                    detachedAcceptedDriftCount: stressTelemetryState.detachedAcceptedDriftCount,
                    detachedRestoreIntentCount: stressTelemetryState.detachedRestoreIntentCount,
                    lastDetachedRebaseAction: stressTelemetryState.lastDetachedRebaseAction,
                    smoothSendScrollCount: stressTelemetryState.smoothSendScrollCount,
                    smoothSendStartCount: stressTelemetryState.smoothSendStartCount,
                    smoothSendCompletionCount: stressTelemetryState.smoothSendCompletionCount,
                    smoothSendFinishedWithoutAnimationCount: stressTelemetryState.smoothSendFinishedWithoutAnimationCount,
                    smoothSendInterruptedCount: stressTelemetryState.smoothSendInterruptedCount,
                    smoothSendCorrectiveScrollCount: stressTelemetryState.smoothSendCorrectiveScrollCount,
                    lastSmoothSendSettleDurationMS: stressTelemetryState.lastSmoothSendSettleDurationMS,
                    maxSmoothSendSettleDurationMS: stressTelemetryState.maxSmoothSendSettleDurationMS,
                    detachedAuthorityAnchorDescription: detachedAuthorityAnchorDescription,
                    viewportFrameUpdateCount: stressTelemetryState.viewportFrameUpdateCount,
                    viewportCandidateUpdateCount: stressTelemetryState.viewportCandidateUpdateCount,
                    projectionBuildCount: transcriptPresentation.performanceSnapshot.projectionBuildCount,
                    projectionPublishCount: transcriptPresentation.performanceSnapshot.projectionPublishCount,
                    lastProjectionBuildDurationMS: transcriptPresentation.performanceSnapshot.lastProjectionBuildDurationMS,
                    maxProjectionBuildDurationMS: transcriptPresentation.performanceSnapshot.maxProjectionBuildDurationMS,
                    lastColdLoadProjectionBuildDurationMS: transcriptPresentation.performanceSnapshot.lastColdLoadProjectionBuildDurationMS,
                    refreshRequestCount: transcriptPresentation.performanceSnapshot.refreshRequestCount,
                    refreshCoalescedCount: transcriptPresentation.performanceSnapshot.refreshCoalescedCount,
                    refreshImmediateCount: transcriptPresentation.performanceSnapshot.refreshImmediateCount,
                    lastRefreshTotalDurationMS: transcriptPresentation.performanceSnapshot.lastRefreshTotalDurationMS,
                    maxRefreshTotalDurationMS: transcriptPresentation.performanceSnapshot.maxRefreshTotalDurationMS,
                    lastImportDurationMS: transcriptPresentation.performanceSnapshot.lastImportDurationMS,
                    maxImportDurationMS: transcriptPresentation.performanceSnapshot.maxImportDurationMS,
                    incrementalImportAttemptCount: transcriptPresentation.performanceSnapshot.incrementalImportAttemptCount,
                    incrementalImportSuccessCount: transcriptPresentation.performanceSnapshot.incrementalImportSuccessCount,
                    incrementalImportFallbackCount: transcriptPresentation.performanceSnapshot.incrementalImportFallbackCount,
                    frontierReuseAttemptCount: transcriptPresentation.performanceSnapshot.frontierReuseAttemptCount,
                    frontierReuseSuccessCount: transcriptPresentation.performanceSnapshot.frontierReuseSuccessCount,
                    frontierReuseFallbackCount: transcriptPresentation.performanceSnapshot.frontierReuseFallbackCount,
                    lastIncrementalImportDurationMS: transcriptPresentation.performanceSnapshot.lastIncrementalImportDurationMS,
                    maxIncrementalImportDurationMS: transcriptPresentation.performanceSnapshot.maxIncrementalImportDurationMS,
                    lastPayloadCaptureDurationMS: transcriptPresentation.performanceSnapshot.lastPayloadCaptureDurationMS,
                    maxPayloadCaptureDurationMS: transcriptPresentation.performanceSnapshot.maxPayloadCaptureDurationMS,
                    lastSanitizeDurationMS: transcriptPresentation.performanceSnapshot.lastSanitizeDurationMS,
                    maxSanitizeDurationMS: transcriptPresentation.performanceSnapshot.maxSanitizeDurationMS,
                    sanitizeReuseAttemptCount: transcriptPresentation.performanceSnapshot.sanitizeReuseAttemptCount,
                    sanitizeReuseSuccessCount: transcriptPresentation.performanceSnapshot.sanitizeReuseSuccessCount,
                    sanitizeReuseFallbackCount: transcriptPresentation.performanceSnapshot.sanitizeReuseFallbackCount,
                    projectionReuseAttemptCount: transcriptPresentation.performanceSnapshot.projectionReuseAttemptCount,
                    projectionReuseSuccessCount: transcriptPresentation.performanceSnapshot.projectionReuseSuccessCount,
                    projectionReuseFallbackCount: transcriptPresentation.performanceSnapshot.projectionReuseFallbackCount,
                    lastSourceItemCount: transcriptPresentation.performanceSnapshot.lastSourceItemCount,
                    lastPayloadCaptureScannedItemCount: transcriptPresentation.performanceSnapshot.lastPayloadCaptureScannedItemCount,
                    lastSanitizedActivityCount: transcriptPresentation.performanceSnapshot.lastSanitizedActivityCount,
                    lastSanitizeReusedTurnCount: transcriptPresentation.performanceSnapshot.lastSanitizeReusedTurnCount,
                    lastProjectionReusedTurnCount: transcriptPresentation.performanceSnapshot.lastProjectionReusedTurnCount,
                    retainedRawPayloadEntryCount: transcriptPresentation.performanceSnapshot.retainedRawPayloadEntryCount,
                    retainedRawPayloadTotalBytes: transcriptPresentation.performanceSnapshot.retainedRawPayloadTotalBytes,
                    coldRestoreStartCount: stressTelemetryState.coldRestoreStartCount,
                    coldRestoreScrollCount: stressTelemetryState.coldRestoreScrollCount,
                    coldRestoreCorrectiveScrollCount: stressTelemetryState.coldRestoreCorrectiveScrollCount,
                    coldRestoreCompletionCount: stressTelemetryState.coldRestoreCompletionCount,
                    lastColdRestoreSettleDurationMS: stressTelemetryState.lastColdRestoreSettleDurationMS,
                    maxColdRestoreSettleDurationMS: stressTelemetryState.maxColdRestoreSettleDurationMS,
                    manualScrollGestureCount: stressTelemetryState.manualScrollGestureCount,
                    manualScrollEffectCount: stressTelemetryState.manualScrollEffectCount,
                    manualScrollTowardHistoryGestureCount: stressTelemetryState.manualScrollTowardHistoryGestureCount,
                    manualScrollTowardHistoryEffectCount: stressTelemetryState.manualScrollTowardHistoryEffectCount,
                    manualScrollTowardLiveBottomGestureCount: stressTelemetryState.manualScrollTowardLiveBottomGestureCount,
                    manualScrollTowardLiveBottomEffectCount: stressTelemetryState.manualScrollTowardLiveBottomEffectCount,
                    manualScrollUnknownDirectionCount: stressTelemetryState.manualScrollUnknownDirectionCount,
                    lastManualScrollDirection: stressTelemetryState.lastManualScrollDirection,
                    lastManualScrollOutcome: stressTelemetryState.lastManualScrollOutcome,
                    scrollToBottomTapCount: stressTelemetryState.scrollToBottomTapCount,
                    scrollToBottomSuccessCount: stressTelemetryState.scrollToBottomSuccessCount,
                    scrollToBottomNoEffectCount: stressTelemetryState.scrollToBottomNoEffectCount,
                    lastScrollToBottomOutcome: stressTelemetryState.lastScrollToBottomOutcome,
                    expandedApplyEditsCardCount: expandedApplyEditsCardCount,
                    expandedApplyEditsDiffPreviewCardCount: expandedApplyEditsDiffPreviewCardCount,
                    expandedApplyEditsMarkdownFallbackCardCount: expandedApplyEditsMarkdownFallbackCardCount,
                    expandedApplyPatchCardCount: expandedApplyPatchCardCount,
                    expandedApplyPatchDiffPreviewCardCount: expandedApplyPatchDiffPreviewCardCount,
                    expandedApplyPatchMarkdownFallbackCardCount: expandedApplyPatchMarkdownFallbackCardCount,
                    liveBashCardCount: liveBashCardCount,
                    expandedLiveBashCardCount: expandedLiveBashCardCount,
                    completedBashCardCount: completedBashCardCount,
                    expandedCompletedBashCardCount: expandedCompletedBashCardCount,
                    latestExpandedHighSignalToolDescription: latestExpandedHighSignalToolDescription,
                    latestExpandedHighSignalRenderMode: latestExpandedHighSignalRenderMode,
                    supportsGeometryMetrics: supportsAutoScroll
                )
            )
        #endif
    }

    private func visibleStandaloneToolName(for block: AgentTranscriptRenderBlock) -> String? {
        guard block.kind == .standaloneTool else { return nil }
        for row in block.rows.reversed() {
            guard let normalizedToolName = normalizedToolCardName(row.toolName) else { continue }
            return normalizedToolName
        }
        return nil
    }

    private func publishGroupingSnapshot() {
        #if DEBUG
            guard let stressHarness else { return }
            let latestCluster = visibleTranscriptBlocks.last(where: { $0.kind == .activityCluster })
            let visibleStandaloneToolNameCounts = Dictionary(
                visibleTranscriptBlocks
                    .filter { $0.kind == .standaloneTool }
                    .compactMap { block in
                        visibleStandaloneToolName(for: block).map { ($0, 1) }
                    },
                uniquingKeysWith: +
            )
            let latestVisibleTurnID = visibleTranscriptBlocks.last?.turnID
            let latestVisibleStandaloneToolNames = visibleTranscriptBlocks
                .filter { $0.kind == .standaloneTool && $0.turnID == latestVisibleTurnID }
                .compactMap(visibleStandaloneToolName(for:))
            let latestGroupedHistory = visibleTranscriptBlocks.last(where: { $0.kind == .groupedHistory })
            let toolGroups =
                latestGroupedHistory?.groupedHistory?.summary.toolSummary?.toolGroups
                    ?? latestCluster?.clusterSummary?.toolGroups
                    ?? []
            let archivedBlocks = transcriptSnapshot.archivedBlocks
            let groupingSampleIndex = max(1, stressTelemetryState.sampleIndex)
            stressHarness.recordGroupingSnapshot(
                .init(
                    sampleIndex: groupingSampleIndex,
                    visibleBlockKindCounts: Dictionary(visibleTranscriptBlocks.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +),
                    workingBlockKindCounts: Dictionary(transcriptPresentation.workingBlocks.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +),
                    archivedBlockKindCounts: Dictionary(archivedBlocks.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +),
                    visibleStandaloneToolNameCounts: visibleStandaloneToolNameCounts,
                    latestVisibleStandaloneToolNames: latestVisibleStandaloneToolNames,
                    latestClusterTitle: latestCluster.map { clusterSummaryTitle(for: $0) },
                    latestGroupedHistoryTitle: latestGroupedHistory.map { groupedSummaryTitle(summary: $0.groupedHistory?.summary) },
                    latestToolGroupLabels: toolGroups.map(\.label)
                )
            )
        #endif
    }

    private var primaryEmptyStateWorkflows: [AgentEmptyStateWorkflowItem] {
        workflowStore.featuredWorkflows.map { workflow in
            AgentEmptyStateWorkflowItem(
                definition: workflow,
                description: emptyStateDescription(for: workflow)
            )
        }
    }

    /// All available workflows for the empty state, featured first then remaining.
    private var allEmptyStateWorkflows: [AgentEmptyStateWorkflowItem] {
        let featured = workflowStore.featuredWorkflows
        let featuredIDs = Set(featured.map(\.id))
        let remaining = workflowStore.allWorkflows.filter { !featuredIDs.contains($0.id) }
        return (featured + remaining).map { workflow in
            AgentEmptyStateWorkflowItem(
                definition: workflow,
                description: emptyStateDescription(for: workflow)
            )
        }
    }

    private var emptyStateTips: [AgentTipItem] {
        [
            AgentTipItem(
                icon: "bolt.fill",
                iconColor: .blue,
                title: "Use workflows to structure the next step",
                description: "Choose one before you send your message to get a more focused, multi-step result."
            ),
            AgentTipItem(
                icon: "bubble.left.and.text.bubble.right",
                iconColor: .purple,
                title: "\"Ask the oracle\" for a second opinion",
                description: "Tell the agent to ask the oracle when you want a plan, review, or fresh perspective from a separate model."
            ),
            AgentTipItem(
                icon: "brain",
                iconColor: .green,
                title: "The oracle follows the agent's reading context",
                description: "Files the agent reads are auto-selected, so the oracle stays up to date when you ask for a review or plan."
            ),
            AgentTipItem(
                icon: "person.2.fill",
                iconColor: .orange,
                title: "Delegate work with sub-agents",
                description: "Say \"use explore agent\" to research the codebase, or \"use engineer agent\" to build out a concrete set of changes in a separate session."
            ),
            AgentTipItem(
                icon: "gearshape.fill",
                iconColor: .indigo,
                title: "Let the agent tweak app settings",
                description: "Ask for changes like \"change the oracle model\" or \"switch to dark mode\" — the agent can update RepoPrompt's settings without leaving the chat."
            )
        ]
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.55))
                Text("What are we building?")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 23, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.9))
            }

            VStack(spacing: 10) {
                AgentPaginatedWorkflowsView(
                    workflows: allEmptyStateWorkflows,
                    selectedWorkflowID: selectedWorkflow?.id,
                    onSelect: { workflow in
                        if selectedWorkflow?.id == workflow.definition.id {
                            agentModeVM.selectWorkflow(nil)
                        } else {
                            agentModeVM.selectWorkflow(workflow.definition)
                        }
                        isInputFocused = true
                    },
                    editAction: {
                        NotificationCenter.default.post(
                            name: .showAgentWorkflowPopover,
                            object: nil,
                            userInfo: ["windowID": windowID]
                        )
                    }
                )
            }
            .frame(maxWidth: 620)

            AgentRotatingTipsView(tips: emptyStateTips)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func emptyStateDescription(for workflow: AgentWorkflowDefinition) -> String {
        if let builtInWorkflow = workflow.builtInWorkflow {
            return builtInWorkflow.descriptionText
        }

        if let description = workflow.descriptionText, !description.isEmpty {
            return description
        }
        return "Use this workflow to structure your next message."
    }
}

private struct AgentRunningElapsedText: View {
    let startedAt: Date
    let isLive: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                #if DEBUG
                    let _ = AgentModePerfDiagnostics.increment("timeline.runningIndicator.tick")
                #endif
                elapsedText(now: timeline.date)
            }
        } else {
            elapsedText(now: Date())
        }
    }

    private func elapsedText(now: Date) -> some View {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return Text("· \(Self.formatElapsed(elapsedSeconds))")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary.opacity(0.75))
            .monospacedDigit()
    }

    private static func formatElapsed(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(String(format: "%02d", seconds))s"
    }
}
