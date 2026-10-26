import SwiftUI

struct ContextBuilderView: View {
    var availableWidth: CGFloat
    @ObservedObject var windowState: WindowState
    @ObservedObject var contextBuilderAgentViewModel: ContextBuilderAgentViewModel

    var body: some View {
        ContextBuilderAgentView(
            viewModel: contextBuilderAgentViewModel,
            oracleViewModel: windowState.oracleViewModel,
            windowID: windowState.windowID,
            availableWidth: availableWidth,
            openGeneratedAnswerChat: openGeneratedAnswerChat(route:)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if windowState.kind != .contextBuilder {
                windowState.kind = .contextBuilder
            }
        }
        .onDisappear {
            guard !windowState.isClosing,
                  !WindowStatesManager.shared.isTerminating else { return }
            if windowState.kind == .contextBuilder {
                windowState.kind = .standard
            }
        }
    }

    private func openGeneratedAnswerChat(route: ContextBuilderGeneratedAnswerRoute) {
        Task { @MainActor in
            let workspaceManager = windowState.workspaceManager
            guard let workspace = workspaceManager.workspace(withID: route.workspaceID) else { return }

            if workspaceManager.activeWorkspaceID != route.workspaceID {
                let result = await workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
                guard result.didSwitch else { return }
            }

            guard workspaceManager.activeWorkspace?.composeTabs.contains(where: { $0.id == route.tabID }) == true else {
                return
            }
            if windowState.promptManager.activeComposeTabID != route.tabID {
                await windowState.promptManager.switchComposeTab(route.tabID)
            }
            guard workspaceManager.activeWorkspaceID == route.workspaceID,
                  windowState.promptManager.activeComposeTabID == route.tabID
            else { return }

            windowState.oracleViewModel.selectSession(byShortID: route.chatID)
        }
    }
}
