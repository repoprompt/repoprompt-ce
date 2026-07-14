import SwiftUI

struct AgentModeDetailWithSidebarView: View {
    let agentModeVM: AgentModeViewModel
    let runtimeVM: AgentRuntimeSidebarViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let oracleViewModel: OracleViewModel
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    #if DEBUG
        let stressHarness: AgentChatStressHarness?
    #endif
    let windowID: Int
    let currentTabID: UUID?
    let codexManagedLoginAction: CodexManagedLoginAction

    @State private var isContextBuilderQuestionPresented = false

    #if DEBUG
        init(
            agentModeVM: AgentModeViewModel,
            runtimeVM: AgentRuntimeSidebarViewModel,
            statusPillsUI: AgentStatusPillsUIStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            stressHarness: AgentChatStressHarness?,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.agentModeVM = agentModeVM
            self.runtimeVM = runtimeVM
            _statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
            self.contextBuilderAgentVM = contextBuilderAgentVM
            self.oracleViewModel = oracleViewModel
            self.promptManager = promptManager
            self.workspaceSearchService = workspaceSearchService
            self.selectionCoordinator = selectionCoordinator
            self.stressHarness = stressHarness
            self.windowID = windowID
            self.currentTabID = currentTabID
            self.codexManagedLoginAction = codexManagedLoginAction
        }

        init(
            agentModeVM: AgentModeViewModel,
            runtimeMetricsUI: AgentRuntimeMetricsUIStore,
            statusPillsUI: AgentStatusPillsUIStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            stressHarness: AgentChatStressHarness?,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.init(
                agentModeVM: agentModeVM,
                runtimeVM: runtimeMetricsUI.runtimeVM,
                statusPillsUI: statusPillsUI,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                stressHarness: stressHarness,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        }
    #else
        init(
            agentModeVM: AgentModeViewModel,
            runtimeVM: AgentRuntimeSidebarViewModel,
            statusPillsUI: AgentStatusPillsUIStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.agentModeVM = agentModeVM
            self.runtimeVM = runtimeVM
            _statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
            self.contextBuilderAgentVM = contextBuilderAgentVM
            self.oracleViewModel = oracleViewModel
            self.promptManager = promptManager
            self.workspaceSearchService = workspaceSearchService
            self.selectionCoordinator = selectionCoordinator
            self.windowID = windowID
            self.currentTabID = currentTabID
            self.codexManagedLoginAction = codexManagedLoginAction
        }

        init(
            agentModeVM: AgentModeViewModel,
            runtimeMetricsUI: AgentRuntimeMetricsUIStore,
            statusPillsUI: AgentStatusPillsUIStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.init(
                agentModeVM: agentModeVM,
                runtimeVM: runtimeMetricsUI.runtimeVM,
                statusPillsUI: statusPillsUI,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        }
    #endif

    var body: some View {
        #if DEBUG
            AgentContextInspectorPresenter(
                drawerStore: agentModeVM.ui.contextDrawer,
                promptManager: promptManager,
                runtimeVM: runtimeVM,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                selectionCoordinator: selectionCoordinator,
                activeAgentSessionID: statusPillsUI.snapshot.activeAgentSessionID,
                agentModeVM: agentModeVM,
                windowID: windowID,
                currentTabID: currentTabID
            ) {
                AgentModeChatDetailView(
                    agentModeVM: agentModeVM,
                    transcriptUI: agentModeVM.ui.transcript,
                    runInteractionUI: agentModeVM.ui.runInteraction,
                    statusPillsUI: statusPillsUI,
                    openContextDrawerFiles: { agentModeVM.ui.contextDrawer.toggle(tab: .files) },
                    contextBuilderAgentVM: contextBuilderAgentVM,
                    isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
                    oracleViewModel: oracleViewModel,
                    promptManager: promptManager,
                    workspaceSearchService: workspaceSearchService,
                    selectionCoordinator: selectionCoordinator,
                    stressHarness: stressHarness,
                    runtimeVM: runtimeVM,
                    windowID: windowID,
                    currentTabID: currentTabID,
                    codexManagedLoginAction: codexManagedLoginAction
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let stressHarness, stressHarness.configuration.showOverlay {
                        AgentChatStressHarnessPanel(harness: stressHarness, currentTabID: currentTabID)
                            .padding(.top, 14)
                            .padding(.trailing, 14)
                    }
                }
            }
            .onAppear {
                syncContextBuilderQuestionPresentation()
                agentModeVM.syncComposerUIState(tabID: currentTabID)
                agentModeVM.syncTranscriptUIState()
                agentModeVM.syncRunInteractionUIState()
                agentModeVM.syncStatusPillsUIState()
                syncRuntimeMetricsSelectionCount()
                stressHarness?.bootstrapIfNeeded(currentTabID: currentTabID)
            }
            .onReceive(contextBuilderAgentVM.$pendingAskUser) { _ in
                syncContextBuilderQuestionPresentation()
            }
            .onReceive(promptManager.fileManager.$selectionStateRevision.removeDuplicates()) { _ in
                syncRuntimeMetricsSelectionCountFromActiveUIIfCurrent()
            }
            .onReceive(selectionCoordinator.changes) { change in
                syncRuntimeMetricsSelectionCount(from: change)
            }
            .onChange(of: currentTabID) { _, tabID in
                syncContextBuilderQuestionPresentation()
                agentModeVM.syncComposerUIState(tabID: tabID)
                agentModeVM.syncTranscriptUIState()
                agentModeVM.syncRunInteractionUIState()
                agentModeVM.syncStatusPillsUIState()
                syncRuntimeMetricsSelectionCount()
                stressHarness?.bootstrapIfNeeded(currentTabID: tabID)
            }
            .onDisappear { stressHarness?.pause() }
        #else
            AgentContextInspectorPresenter(
                drawerStore: agentModeVM.ui.contextDrawer,
                promptManager: promptManager,
                runtimeVM: runtimeVM,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                selectionCoordinator: selectionCoordinator,
                activeAgentSessionID: statusPillsUI.snapshot.activeAgentSessionID,
                agentModeVM: agentModeVM,
                windowID: windowID,
                currentTabID: currentTabID
            ) {
                AgentModeChatDetailView(
                    agentModeVM: agentModeVM,
                    transcriptUI: agentModeVM.ui.transcript,
                    runInteractionUI: agentModeVM.ui.runInteraction,
                    statusPillsUI: statusPillsUI,
                    openContextDrawerFiles: { agentModeVM.ui.contextDrawer.toggle(tab: .files) },
                    contextBuilderAgentVM: contextBuilderAgentVM,
                    isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
                    oracleViewModel: oracleViewModel,
                    promptManager: promptManager,
                    workspaceSearchService: workspaceSearchService,
                    selectionCoordinator: selectionCoordinator,
                    runtimeVM: runtimeVM,
                    windowID: windowID,
                    currentTabID: currentTabID,
                    codexManagedLoginAction: codexManagedLoginAction
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                syncContextBuilderQuestionPresentation()
                agentModeVM.syncComposerUIState(tabID: currentTabID)
                agentModeVM.syncTranscriptUIState()
                agentModeVM.syncRunInteractionUIState()
                agentModeVM.syncStatusPillsUIState()
                syncRuntimeMetricsSelectionCount()
            }
            .onReceive(contextBuilderAgentVM.$pendingAskUser) { _ in
                syncContextBuilderQuestionPresentation()
            }
            .onReceive(promptManager.fileManager.$selectionStateRevision.removeDuplicates()) { _ in
                syncRuntimeMetricsSelectionCountFromActiveUIIfCurrent()
            }
            .onReceive(selectionCoordinator.changes) { change in
                syncRuntimeMetricsSelectionCount(from: change)
            }
            .onChange(of: currentTabID) { _, tabID in
                syncContextBuilderQuestionPresentation()
                agentModeVM.syncComposerUIState(tabID: tabID)
                agentModeVM.syncTranscriptUIState()
                agentModeVM.syncRunInteractionUIState()
                agentModeVM.syncStatusPillsUIState()
                syncRuntimeMetricsSelectionCount()
            }
        #endif
    }

    private func syncContextBuilderQuestionPresentation() {
        isContextBuilderQuestionPresented = contextBuilderAgentVM.pendingAskUser(for: currentTabID) != nil
    }

    private var runtimeMetricsTargetTabID: UUID? {
        currentTabID ?? promptManager.activeComposeTabID
    }

    private func syncRuntimeMetricsSelectionCount() {
        guard let targetTabID = runtimeMetricsTargetTabID,
              let snapshot = selectionCoordinator.selectionSnapshot(for: targetTabID, flushPendingUIIfActive: true)
        else {
            agentModeVM.syncRuntimeMetricsUIState(liveSelectedFileCount: nil, liveSelectionSummary: nil)
            return
        }
        syncRuntimeMetricsSelectionCount(selection: snapshot.selection)
    }

    private func syncRuntimeMetricsSelectionCountFromActiveUIIfCurrent() {
        guard runtimeMetricsTargetTabID == selectionCoordinator.activeTabID() else { return }
        syncRuntimeMetricsSelectionCount()
    }

    private func syncRuntimeMetricsSelectionCount(from change: WorkspaceSelectionCoordinator.Change) {
        guard change.tabID == runtimeMetricsTargetTabID else { return }
        syncRuntimeMetricsSelectionCount(selection: change.selection)
    }

    private func syncRuntimeMetricsSelectionCount(selection: StoredSelection) {
        let summary = AgentContextExportResolver.selectionSummary(for: selection)
        agentModeVM.syncRuntimeMetricsUIState(
            liveSelectedFileCount: summary.totalExplicitFileCount,
            liveSelectionSummary: summary
        )
    }
}

struct AgentContextInspectorColumnMetrics: Equatable {
    let minimumWidth: CGFloat
    let idealWidth: CGFloat
    let maximumWidth: CGFloat
}

enum AgentContextInspectorColumnSizing {
    private static let shellMinimumWidth: CGFloat = 320
    private static let preferredWidthRatio: CGFloat = 2.0 / 3.0
    private static let minimumChatColumnWidth: CGFloat = 360
    private static let absoluteMaximumWidth: CGFloat = 800

    static func metrics(forDetailWidth detailWidth: CGFloat) -> AgentContextInspectorColumnMetrics {
        guard detailWidth.isFinite, detailWidth > 0 else {
            return AgentContextInspectorColumnMetrics(
                minimumWidth: shellMinimumWidth,
                idealWidth: shellMinimumWidth,
                maximumWidth: shellMinimumWidth
            )
        }

        let availableWidth = detailWidth.rounded(.down)
        let maximumPreservingChat = availableWidth - minimumChatColumnWidth
        let maximumWidth = max(shellMinimumWidth, min(absoluteMaximumWidth, maximumPreservingChat))
        let preferredWidth = availableWidth * preferredWidthRatio
        let idealWidth = min(max(preferredWidth, shellMinimumWidth), maximumWidth)

        return AgentContextInspectorColumnMetrics(
            minimumWidth: shellMinimumWidth,
            idealWidth: idealWidth,
            maximumWidth: maximumWidth
        )
    }
}

private struct AgentContextInspectorPresenter<PrimaryContent: View>: View {
    let drawerStore: AgentContextDrawerUIStore
    @ObservedObject var presentationStore: AgentContextDrawerPresentationStore
    let promptManager: PromptViewModel
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let oracleViewModel: OracleViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let activeAgentSessionID: UUID?
    let agentModeVM: AgentModeViewModel
    let windowID: Int
    let currentTabID: UUID?
    let primaryContent: PrimaryContent

    init(
        drawerStore: AgentContextDrawerUIStore,
        promptManager: PromptViewModel,
        runtimeVM: AgentRuntimeSidebarViewModel,
        contextBuilderAgentVM: ContextBuilderAgentViewModel,
        oracleViewModel: OracleViewModel,
        selectionCoordinator: WorkspaceSelectionCoordinator,
        activeAgentSessionID: UUID?,
        agentModeVM: AgentModeViewModel,
        windowID: Int,
        currentTabID: UUID?,
        @ViewBuilder primaryContent: () -> PrimaryContent
    ) {
        self.drawerStore = drawerStore
        _presentationStore = ObservedObject(wrappedValue: drawerStore.presentation)
        self.promptManager = promptManager
        _runtimeVM = ObservedObject(wrappedValue: runtimeVM)
        self.contextBuilderAgentVM = contextBuilderAgentVM
        self.oracleViewModel = oracleViewModel
        self.selectionCoordinator = selectionCoordinator
        self.activeAgentSessionID = activeAgentSessionID
        self.agentModeVM = agentModeVM
        self.windowID = windowID
        self.currentTabID = currentTabID
        self.primaryContent = primaryContent()
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AgentContextInspectorColumnSizing.metrics(forDetailWidth: geometry.size.width)

            primaryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: presentationBinding) {
                    AgentContextControlDrawerView(
                        drawerStore: drawerStore,
                        detailStore: drawerStore.detail,
                        isPresented: presentationStore.isPresented,
                        promptManager: promptManager,
                        runtimeVM: runtimeVM,
                        contextBuilderAgentVM: contextBuilderAgentVM,
                        oracleViewModel: oracleViewModel,
                        selectionCoordinator: selectionCoordinator,
                        windowID: windowID,
                        currentTabID: currentTabID,
                        activeAgentSessionID: activeAgentSessionID,
                        worktreeBindingsProvider: { sessionID, tabID in
                            agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: tabID)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipped()
                    .inspectorColumnWidth(
                        min: metrics.minimumWidth,
                        ideal: metrics.idealWidth,
                        max: metrics.maximumWidth
                    )
                }
        }
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { presentationStore.isPresented },
            set: { isPresented in
                if isPresented {
                    drawerStore.open()
                } else {
                    drawerStore.close()
                }
            }
        )
    }
}
