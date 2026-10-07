import RepoPromptInstrumentation
import SwiftUI

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @StateObject private var agentNavigationHUD = AgentNavigationHUDViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var agentNavigationHUDCommands = AgentNavigationHUDCommandDeduplicator()

    /// A workspace approval is only this window's business when it targets this
    /// window (or targets none). The manager is a process-wide singleton, so every
    /// consumer of its pending request must apply this same scope.
    private var presentedWorkspaceApprovalRequest: WorkspaceApprovalRequest? {
        guard let request = workspaceApprovalManager.pendingRequest,
              workspaceApprovalManager.isApprovalOverlayVisible,
              WorkspaceApprovalPresentationPolicy.shouldPresent(
                  targetWindowID: workspaceApprovalManager.presentedTargetWindowID,
                  inWindowID: viewModel.state.windowID
              )
        else { return nil }
        return request
    }

    private var isBlockingOverlayVisible: Bool {
        showWorkspaceSwitchOverlay
            || (viewModel.state.mcpServer.pendingClientID != nil && viewModel.state.mcpServer.isApprovalOverlayVisible)
            || presentedWorkspaceApprovalRequest != nil
    }

    var body: some View {
        ZStack {
            routedContent
                .blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
                .animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

            VStack {
                CodeStructureSettlementLimitNoticeBanner(server: viewModel.state.mcpServer)
                Spacer(minLength: 0)
            }
            .padding(16)
            .zIndex(997)

            if agentNavigationHUD.isPresented {
                AgentNavigationHUDView(
                    viewModel: agentNavigationHUD,
                    windowState: viewModel.state
                )
                .transition(hudTransition)
                .zIndex(998)
            }

            if showWorkspaceSwitchOverlay {
                WorkspaceSwitchLoadingOverlay {
                    await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                }
                .zIndex(999)
            }

            // MCP Client Approval Overlay
            if let clientID = viewModel.state.mcpServer.pendingClientID,
               viewModel.state.mcpServer.isApprovalOverlayVisible
            {
                MCPApprovalOverlayView(clientID: clientID)
                    .environmentObject(viewModel.state.mcpServer)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1000)
            }

            // Workspace Operation Approval Overlay
            if let request = presentedWorkspaceApprovalRequest {
                WorkspaceApprovalOverlayView(
                    approvalManager: workspaceApprovalManager,
                    request: request,
                    respondingWindowID: viewModel.state.windowID
                )
                .id(request.id)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1001)
            }
        }
        .animation(hudAnimation, value: agentNavigationHUD.isPresented)
        .onReceive(NotificationCenter.default.publisher(for: .showAgentNavigationHUD)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            #if DEBUG
                let startMS = viewModel.state.agentModeViewModel.perfRecorder.timestampMSIfEnabled()
                defer { viewModel.state.agentModeViewModel.perfRecorder.durationEvent("hud.command.shell", startMS: startMS) }
            #endif
            guard !isBlockingOverlayVisible else {
                recordHUDCommandIgnored("blockingOverlay")
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            let rawMode = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentNavigationHUDMode.init(rawValue:)) ?? .currentWindow
            guard !agentNavigationHUDCommands.isDuplicate(
                mode: mode,
                eventTimestamp: note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.eventTimestamp] as? TimeInterval
            ) else {
                recordHUDCommandIgnored("duplicateEvent")
                return
            }
            guard viewModel.rootRoute != .workspaceEntry || mode == .allAgents else {
                recordHUDCommandIgnored("workspaceEntry")
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            animateHUD {
                agentNavigationHUD.present(mode: mode, currentWindow: viewModel.state)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentSessionLinkOverseerProjectionDidChange)) { note in
            guard agentNavigationHUD.isPresented,
                  let owner = note.object as? AgentModeViewModel,
                  agentNavigationHUD.snapshot.mode == .allAgents || owner === viewModel.state.agentModeViewModel
            else { return }
            agentNavigationHUD.refreshOversightRoles(from: owner)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentNavigationHUDResult)) { note in
            guard noteTargetsCurrentWindow(note), agentNavigationHUD.isPresented else { return }
            (note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.handledRequest] as? AgentNavigationHUDHandledRequest)?.handled = true
            guard let index = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.resultIndex] as? Int else { return }
            Task {
                await agentNavigationHUD.selectItem(atDisplayIndex: index, currentWindow: viewModel.state)
            }
        }
        .onChange(of: isBlockingOverlayVisible) { _, isVisible in
            if isVisible {
                recordHUDCommandIgnored("overlayBecameVisible")
                animateHUD { agentNavigationHUD.dismiss() }
            }
        }
        .onChange(of: viewModel.state.promptManager.activeComposeTabID) { _, _ in
            if agentNavigationHUD.isPresented, !agentNavigationHUD.isRouting {
                recordHUDCommandIgnored("activeTabChanged")
                animateHUD { agentNavigationHUD.dismiss() }
            }
        }
    }

    private var hudTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var hudAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.18, extraBounce: 0)
    }

    private func animateHUD(_ action: () -> Void) {
        withAnimation(hudAnimation) {
            action()
        }
    }

    private func recordHUDCommandIgnored(_ reason: String) {
        #if DEBUG
            viewModel.state.agentModeViewModel.perfRecorder.event("hud.command.ignored", fields: ["reason": reason])
        #endif
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let id = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int {
            return id == viewModel.state.windowID
        }
        return true
    }

    @ViewBuilder
    private var routedContent: some View {
        if viewModel.rootRoute == .workspaceEntry {
            WorkspaceEntryRootView(
                workspaceManager: viewModel.workspaceManager,
                windowState: viewModel.state,
                tab: $viewModel.workspaceEntryTab,
                onboardingViewModel: viewModel.onboardingViewModel,
                onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
                onContinueToMain: {
                    viewModel.continueFromOnboarding()
                }
            )
        } else {
            AgentModeView(
                windowState: viewModel.state,
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager
            )
        }
    }
}

/// Observes the per-window MCP model directly so a settlement recovery redraws
/// without depending on an unrelated `ContentViewModel` publication.
private struct CodeStructureSettlementLimitNoticeBanner: View {
    @ObservedObject var server: MCPServerViewModel

    var body: some View {
        if let notice = server.codeStructureSettlementLimitNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)
                    Text(notice.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 720, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.orange.opacity(0.5), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(notice.title). \(notice.message)")
        }
    }
}
