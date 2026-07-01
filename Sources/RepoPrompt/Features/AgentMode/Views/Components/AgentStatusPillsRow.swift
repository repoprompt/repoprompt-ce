import SwiftUI

struct AgentStatusPillsRow: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var oracleViewModel: OracleViewModel
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let windowID: Int

    private var snapshot: AgentStatusPillsSnapshot {
        statusPillsUI.snapshot
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPillsRow")
        #endif
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if let executionLocation = snapshot.executionLocation {
                    AgentExecutionLocationPill(
                        props: executionLocation,
                        loadExistingWorktrees: { try await agentModeVM.availableExecutionWorktrees(for: executionLocation.tabID) },
                        selectLocation: { choice, confirmation in
                            await agentModeVM.selectExecutionLocation(
                                choice,
                                for: executionLocation.tabID,
                                confirmedChange: confirmation
                            )
                        }
                    )
                }

                AgentWorkflowPill(
                    statusPillsUI: statusPillsUI,
                    windowID: windowID,
                    selectWorkflow: { agentModeVM.selectWorkflow($0) }
                )

                AgentInterviewPill(
                    isOn: snapshot.interviewFirst,
                    onToggle: { agentModeVM.toggleInterviewFirst() }
                )

                if let stagedSlashCommand = snapshot.stagedSlashCommand {
                    AgentStagedSlashCommandPill(staged: stagedSlashCommand)
                }
            }

            Spacer(minLength: 0)

            if let guidance = snapshot.autoEditPermissionGuidance {
                AgentAutoEditGuidanceBubble(
                    agentModeVM: agentModeVM,
                    runState: snapshot.runState,
                    guidance: guidance
                )
                .frame(maxWidth: 720)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                AgentOraclePill(
                    oracleViewModel: oracleViewModel,
                    windowID: windowID,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    activeRunID: snapshot.activeRunID
                )

                AgentContextPill(
                    promptManager: promptManager,
                    selectionCoordinator: selectionCoordinator,
                    runtimeVM: runtimeVM,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    worktreeBindingsProvider: { sessionID, tabID in
                        agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: tabID)
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: snapshot.selectedWorkflow?.id)
    }
}
