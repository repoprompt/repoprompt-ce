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
            AgentModeChatDetailView(
                agentModeVM: agentModeVM,
                transcriptUI: agentModeVM.ui.transcript,
                runInteractionUI: agentModeVM.ui.runInteraction,
                statusPillsUI: statusPillsUI,
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
            .onReceive(promptManager.fileManager.$selectedFiles.map(\.count).removeDuplicates()) { _ in
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
            AgentModeChatDetailView(
                agentModeVM: agentModeVM,
                transcriptUI: agentModeVM.ui.transcript,
                runInteractionUI: agentModeVM.ui.runInteraction,
                statusPillsUI: statusPillsUI,
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
            .onReceive(promptManager.fileManager.$selectedFiles.map(\.count).removeDuplicates()) { _ in
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
            agentModeVM.syncRuntimeMetricsUIState(liveSelectedFileCount: nil)
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
        agentModeVM.syncRuntimeMetricsUIState(
            liveSelectedFileCount: AgentContextExportResolver.explicitSelectionFileCount(selection)
        )
    }
}
