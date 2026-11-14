import SwiftUI

@MainActor
private func notificationTargetsWindow(_ note: Notification, windowState: WindowState) -> Bool {
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
        presetNotifications(modelNotifications(generalNotifications(content)))
    }

    /// Opaque results bound each notification chain without changing modifier order.
    private func generalNotifications(_ content: some View) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsPopover)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAPISettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .apiGeneral)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showManageWorkspacesTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .manageWorkspaces)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showManagePresetsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .managePresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMCPSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .mcp)
            }
    }

    private func modelNotifications(_ content: some View) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showCLIProvidersTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .cliProviders)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentModeSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .agentMode)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showModelRouterSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                if let section = note.userInfo?["agentDecisionsSection"]
                    as? SettingsWindowCoordinator.AgentDecisionsSection
                {
                    SettingsWindowCoordinator.shared.openAgentDecisions(
                        windowState: windowState,
                        section: section
                    )
                } else {
                    SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .modelRouter)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showNotificationSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .notifications)
            }
            .modifier(AgentModeDeepLinkNotificationHandler(windowState: windowState))
    }

    private func presetNotifications(_ content: some View) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showModelPresetsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .modelPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCopyPresetsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .copyPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showChatPresetsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .chatPresets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showContextBuilderSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .contextBuilder)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showLicenseUpdatesTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .licenseUpdates)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcutsSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .keyboardShortcuts)
            }
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
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .agentModels)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentPermissionsSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .agentPermissions)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWorkspaceApprovalsSettingsTab)) { note in
                guard notificationTargetsWindow(note, windowState: windowState) else { return }
                SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .permissions)
            }
    }
}
