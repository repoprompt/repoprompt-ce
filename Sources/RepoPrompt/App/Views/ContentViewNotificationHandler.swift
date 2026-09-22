import SwiftUI

// MARK: - Content View Notification Handler

struct ContentViewNotificationHandler: ViewModifier {
    let windowState: WindowState
    let onShowWizard: () -> Void
    let onShowMCPPopover: () -> Void
    let onShowCreatePresetSheet: () -> Void
    let onShowMCPStatusSheet: () -> Void
    let onShowRecommendationWizard: () -> Void
    let onAppWillRestartForUpdate: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showAgentOnboardingWizard)) { _ in
                onShowWizard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMCPServerPopover)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id != windowState.windowID
                {
                    return
                }
                onShowMCPPopover()
            }
            .modifier(SettingsNotificationHandler(windowState: windowState))
            .onReceive(NotificationCenter.default.publisher(for: .showCreatePresetSheet)) { note in
                // Only react if the notification's windowID matches this window
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowCreatePresetSheet()
                }
            }
            // Listen for notifications to show MCP status
            .onReceive(NotificationCenter.default.publisher(for: .showMCPStatusWindow)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowMCPStatusSheet()
                }
            }
            // Listen for notifications to open recommendation wizard
            .onReceive(NotificationCenter.default.publisher(for: .showRecommendationWizard)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowRecommendationWizard()
                }
            }
            // Listen for app restart notifications and close all sheets
            .onReceive(NotificationCenter.default.publisher(for: .appWillRestartForUpdate)) { _ in
                onAppWillRestartForUpdate()
            }
    }
}

// MARK: - Settings Notification Handler

/// Extracted to reduce type-checker load on ContentView.body
private struct SettingsNotificationHandler: ViewModifier {
    let windowState: WindowState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsPopover)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAPISettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .apiGeneral)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showManageWorkspacesTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .manageWorkspaces)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showManagePresetsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .managePresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMCPSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .mcp)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCLIProvidersTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .cliProviders)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentModeSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .agentMode)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showModelRouterSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .modelRouter)
            }
            .modifier(AgentModeDeepLinkNotificationHandler(windowState: windowState))
            .onReceive(NotificationCenter.default.publisher(for: .showModelPresetsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .modelPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCopyPresetsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .copyPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showChatPresetsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .chatPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showContextBuilderSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .contextBuilder)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showLicenseUpdatesTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .licenseUpdates)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcutsSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .keyboardShortcuts)
            }
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let sender = note.object as? WindowState {
            return sender === windowState
        }
        if let id = note.userInfo?["windowID"] as? Int {
            return id == windowState.windowID
        }
        let target = WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
            ?? WindowStatesManager.shared.latestWindowState
        return target === windowState
    }

    private func openSettings(tab: SettingsTab?) {
        SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: tab)
    }
}

// MARK: - Agent Mode Deep Link Notification Handler

/// Handles the newer Agent-Mode sidebar deep-link notifications
/// (Agent Models / Agent Permissions / Workspace Approvals) as a separate
/// modifier so the parent `SettingsNotificationHandler` stays small enough
/// for the Swift type-checker. Keeps the window-scoping identical to the
/// parent handler — only routes to a different settings tab.
///
/// SEARCH-HELPER: AgentModeDeepLinkNotificationHandler, Agent Mode deep link,
/// Models settings tab handler, Permissions settings tab handler
private struct AgentModeDeepLinkNotificationHandler: ViewModifier {
    let windowState: WindowState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showAgentModelsSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .agentModels)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentPermissionsSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .agentPermissions)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWorkspaceApprovalsSettingsTab)) { note in
                guard noteTargetsCurrentWindow(note) else { return }
                openSettings(tab: .permissions)
            }
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let sender = note.object as? WindowState {
            return sender === windowState
        }
        if let id = note.userInfo?["windowID"] as? Int {
            return id == windowState.windowID
        }
        let target = WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
            ?? WindowStatesManager.shared.latestWindowState
        return target === windowState
    }

    private func openSettings(tab: SettingsTab?) {
        SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: tab)
    }
}
