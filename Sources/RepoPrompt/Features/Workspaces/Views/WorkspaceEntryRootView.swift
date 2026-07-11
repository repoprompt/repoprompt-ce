//
//  WorkspaceEntryRootView.swift
//  RepoPrompt
//

import SwiftUI

/// Full-window entry view. Routes between full-screen onboarding and workspace chooser.
struct WorkspaceEntryRootView: View {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel
    @ObservedObject var windowState: WindowState
    @Binding var tab: WorkspaceEntryTab

    var onboardingViewModel: AgentOnboardingWizardViewModel?
    let onCreateOnboardingViewModelIfNeeded: () -> Void
    let onContinueToMain: () -> Void

    var body: some View {
        Group {
            switch tab {
            case .setupGuide:
                setupGuideContent
            case .workspaces:
                workspaceChooserContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Full-Screen Onboarding

    @ViewBuilder
    private var setupGuideContent: some View {
        if let vm = onboardingViewModel {
            AgentOnboardingWizardView(
                viewModel: vm,
                windowID: windowState.windowID,
                onDismiss: {
                    // Skip All / Get Started → go to workspace chooser
                    tab = .workspaces
                },
                onContinueToMain: {
                    onContinueToMain()
                }
            )
        } else {
            Color.clear
                .onAppear { onCreateOnboardingViewModelIfNeeded() }
        }
    }

    // MARK: - Workspace Chooser

    private var workspaceChooserContent: some View {
        WorkspaceLandingView(
            workspaceManager: workspaceManager,
            onOpenWorkspace: { ws in
                Task {
                    _ = await workspaceManager.requestWorkspaceSwitch(to: ws)
                }
            },
            onManageWorkspaces: {
                NotificationCenter.default.post(
                    name: .showManageWorkspacesTab,
                    object: nil,
                    userInfo: ["windowID": windowState.windowID]
                )
            },
            onSelectFolder: {
                Task { await openFolder() }
            },
            maxRecent: 10,
            maxWidth: 900,
            topPadding: 0,
            horizontalPadding: 32,
            layoutStyle: .expanded,
            greetingText: "Welcome to RepoPrompt",
            onSetupGuide: {
                onCreateOnboardingViewModelIfNeeded()
                onboardingViewModel?.resetToStart()
                tab = .setupGuide
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @MainActor
    private func openFolder() async {
        do {
            try await workspaceManager.pickFolderAndOpenWorkspace(
                title: "Open Folder",
                message: "Choose a folder to create a new workspace.",
                behavior: .createNewWorkspace
            )
        } catch {
            // User cancelled or error
        }
    }
}
