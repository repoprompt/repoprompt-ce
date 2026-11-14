import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import SwiftUI

struct AgentStatusPillsRow: View {
    @Environment(\.agentModePerfRecorder) private var perfRecorder
    let agentModeVM: AgentModeViewModel?
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let computerUse: AgentComputerUseComposerProps
    let computerUseTarget: AgentComposerSubmitTarget?
    let toggleComputerUse: (UUID, ObjectIdentifier) async -> Void
    let openContextDrawerFiles: () -> Void
    let oracleViewModel: OracleViewModel?
    let promptManager: PromptViewModel?
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let runtimeVM: AgentRuntimeSidebarViewModel?
    let windowID: Int
    var subject = AgentComposerSubject.currentTab
    var projectChip: AnyView?
    var setAutoEdit: ((Bool) -> Void)?
    var selectWorkflow: ((AgentWorkflowDefinition?) -> Void)?

    private var snapshot: AgentStatusPillsSnapshot {
        statusPillsUI.snapshot
    }

    private func openAgentDecisionsSettings(section: SettingsWindowCoordinator.AgentDecisionsSection) {
        NotificationCenter.default.post(
            name: .showModelRouterSettingsTab,
            object: nil,
            userInfo: [
                "windowID": windowID,
                "agentDecisionsSection": section
            ]
        )
    }

    private var contextSummary: String {
        guard !subject.isDraft, let tabID = snapshot.currentTabID, let selectionCoordinator else { return "Context" }
        let selection = selectionCoordinator.selectionSnapshot(for: tabID, flushPendingUIIfActive: false)
        guard let selection else { return "Context" }
        return AgentContextFileCodemapCountSummary.selectionDisplayText(from: AgentContextExportResolver.selectionSummary(for: selection.selection)).compact
    }

    var body: some View {
        #if DEBUG
            let _ = perfRecorder.increment("ui.body.statusPillsRow")
        #endif
        Group {
            if subject.isCurrent {
                // Preserve the regular workspace's native layout unchanged.
                HStack(spacing: 12) {
                    leadingPills
                    Spacer(minLength: 0)
                    autoEditGuidance
                    Spacer(minLength: 0)
                    trailingPills
                }
            } else {
                // The additional project chip must not compress Workflow or displace the
                // trailing context controls. Use the same native horizontal-strip behavior
                // as the composer footer, and keep each leading pill at its natural width.
                HStack(spacing: 12) {
                    ScrollView(.horizontal) {
                        leadingPills.fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: AgentPillMetrics.height())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailingPills.fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: snapshot.selectedWorkflow?.id)
    }

    private var leadingPills: some View {
        HStack(spacing: 6) {
            if let projectChip { projectChip }
            if let executionLocation = snapshot.executionLocation, let agentModeVM {
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
                settingsStore: agentModeVM?.modelRouterSettingsStore ?? .shared,
                windowID: windowID,
                selectWorkflow: { if let selectWorkflow { selectWorkflow($0) } else { agentModeVM?.selectWorkflow($0) } }
            )

            AgentMonitorPill(statusPillsUI: statusPillsUI)

            AgentInterviewPill(
                isOn: snapshot.interviewFirst,
                onToggle: { if subject.isCurrent { agentModeVM?.toggleInterviewFirst() } else { openContextDrawerFiles() } }
            )

            if let agentModeVM, !subject.isDraft {
                AgentRepromptPill(
                    props: snapshot.reprompt,
                    store: agentModeVM.repromptUIStore,
                    viewModel: agentModeVM,
                    setEnabled: { enabled, provider in
                        if subject.isCurrent { agentModeVM.setRepromptEnabled(enabled, acknowledgingProviderID: provider) }
                        else { openContextDrawerFiles() }
                    },
                    openSettings: {
                        NotificationCenter.default.post(name: .showAgentModelsSettingsTab, object: nil, userInfo: ["windowID": windowID])
                    }
                )

            } else {
                AgentIconTogglePill(systemImage: "wand.and.stars", isOn: snapshot.autoEditEnabled, isBusy: false, onToggle: { setAutoEdit?(!snapshot.autoEditEnabled) })
                    .hoverTooltip("Auto Edit for this draft", .top)
            }

            AgentModelRouterPill(
                props: snapshot.modelRouter,
                onToggle: { if let agentModeVM { agentModeVM.toggleGlobalModelRouter() } else { openAgentDecisionsSettings(section: .modelRouter) } },
                onOpenSettings: { openAgentDecisionsSettings(section: .modelRouter) }
            )

            AgentAutoEffortPill(
                props: snapshot.autoEffort,
                onToggle: { if let agentModeVM { agentModeVM.toggleAutoEffort() } else { openAgentDecisionsSettings(section: .autoEffort) } },
                onOpenSettings: { openAgentDecisionsSettings(section: .autoEffort) }
            )

            if computerUse.isVisible, let target = computerUseTarget,
               target.route == .existingAgentSession
            {
                AgentIconTogglePill(
                    systemImage: "desktopcomputer",
                    isOn: computerUse.isOn,
                    isBusy: computerUse.isBusy,
                    onToggle: {
                        Task { await toggleComputerUse(target.tabID, target.expectedSourceTabSessionIdentity) }
                    }
                )
                .disabled(computerUse.isBusy)
                .hoverTooltip(subject.isCurrent ? "Computer Use \(computerUse.isOn ? "on" : "off") for this chat" : "Open this session in its workspace to change Computer Use", .top)
                .accessibilityLabel("Computer Use \(computerUse.isOn ? "on" : "off") for this chat")
                .accessibilityValue(computerUse.isOn ? "On" : "Off")
                .accessibilityAddTraits(computerUse.isOn ? .isSelected : [])
            }

            if let stagedSlashCommand = snapshot.stagedSlashCommand {
                AgentStagedSlashCommandPill(staged: stagedSlashCommand)
            }
        }
    }

    @ViewBuilder private var autoEditGuidance: some View {
        if let guidance = snapshot.autoEditPermissionGuidance, let agentModeVM {
            AgentAutoEditGuidanceBubble(
                agentModeVM: agentModeVM,
                runState: snapshot.runState,
                guidance: guidance
            )
            .frame(maxWidth: 720)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var trailingPills: some View {
        HStack(spacing: 6) {
            // Value-only input: quota updates re-render the pill, never this row.
            if let usageTarget = ProviderQuotaSettingsTarget(agent: snapshot.selectedAgent) {
                AgentUsageLimitsPill(target: usageTarget, windowID: windowID)
            }

            if subject.isCurrent, let oracleViewModel, let promptManager, let selectionCoordinator, let runtimeVM, let agentModeVM {
                AgentOraclePill(
                    oracleViewModel: oracleViewModel,
                    windowID: windowID,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    activeRunID: snapshot.activeRunID
                )

                AgentContextPill(
                    promptManager: promptManager,
                    openContextDrawerFiles: openContextDrawerFiles,
                    selectionCoordinator: selectionCoordinator,
                    runtimeVM: runtimeVM,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    worktreeBindingsProvider: { sessionID, tabID in
                        agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: tabID)
                    }
                )
            } else {
                AgentWorkspaceContextPill(title: "Oracle", systemImage: "brain", action: openContextDrawerFiles)
                AgentWorkspaceContextPill(title: contextSummary, systemImage: "square.stack.3d.up", action: openContextDrawerFiles)
            }
        }
    }
}

/// The normal context-chip chrome with an explicit workspace-open action when the owning
/// window's context/Oracle editor cannot be embedded for a non-current subject.
struct AgentWorkspaceContextPill: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @ObservedObject private var fonts = FontScaleManager.shared
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(fonts.preset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AgentPillMetrics.horizontalPadding())
                .frame(height: AgentPillMetrics.height())
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
        }.buttonStyle(.plain).hoverTooltip("Open this project/session in its workspace to use \(title)", .top)
    }
}
