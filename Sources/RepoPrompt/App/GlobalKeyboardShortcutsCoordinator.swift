import AppKit
import Foundation
import KeyboardShortcuts

@MainActor
final class GlobalKeyboardShortcutsCoordinator {
    static let shared = GlobalKeyboardShortcutsCoordinator()

    private var didRegisterHandlers = false

    private init() {}

    func ensureHandlersRegistered() {
        guard !didRegisterHandlers else { return }
        didRegisterHandlers = true

        registerPresetShortcuts()
        registerWorkspaceShortcuts()
        registerComposeTabShortcuts()
        registerFontScaleShortcuts()
        registerAgentShortcuts()
    }

    // MARK: - Registration helpers

    private func register(_ name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name) {
            Task { @MainActor in
                action()
            }
        }
    }

    // MARK: - Context helpers

    private func focusedWindowState() -> WindowState? {
        WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
    }

    private func guardedFocusedWindowState() -> WindowState? {
        guard NSApplication.shared.isActive else { return nil }
        guard let win = focusedWindowState(), win.isCurrentlyFocused else { return nil }
        return win
    }

    // MARK: - Presets

    private func registerPresetShortcuts() {
        register(.switchToPreset1) { [weak self] in self?.switchToPreset(1) }
        register(.switchToPreset2) { [weak self] in self?.switchToPreset(2) }
        register(.switchToPreset3) { [weak self] in self?.switchToPreset(3) }
        register(.switchToPreset4) { [weak self] in self?.switchToPreset(4) }
        register(.switchToPreset5) { [weak self] in self?.switchToPreset(5) }
        register(.switchToPreset6) { [weak self] in self?.switchToPreset(6) }
        register(.switchToPreset7) { [weak self] in self?.switchToPreset(7) }
        register(.switchToPreset8) { [weak self] in self?.switchToPreset(8) }
        register(.switchToPreset9) { [weak self] in self?.switchToPreset(9) }
    }

    private func switchToPreset(_ index: Int) {
        guard let win = guardedFocusedWindowState() else { return }
        Task {
            await win.workspaceManager.switchToPreset(index, isWindowFocused: true)
        }
    }

    // MARK: - Workspace

    private func registerWorkspaceShortcuts() {
        register(.cmdS) { [weak self] in self?.saveWorkspace() }
        register(.cmdShiftS) { [weak self] in self?.saveAndExitWorkspace() }
        register(.cmdOptionS) { [weak self] in self?.saveCurrentPresetOrPromptCreate() }
        register(.cmdOptionP) { [weak self] in self?.createPreset() }
    }

    private func saveWorkspace() {
        guard let win = guardedFocusedWindowState() else { return }
        win.workspaceManager.pollAndSaveState()
    }

    private func saveAndExitWorkspace() {
        guard let win = guardedFocusedWindowState() else { return }
        guard let fallback = win.workspaceManager.workspaces.first(where: { $0.isSystemWorkspace }) else { return }
        Task {
            win.workspaceManager.pollAndSaveState()
            _ = await win.workspaceManager.requestWorkspaceSwitch(to: fallback)
        }
    }

    private func saveCurrentPresetOrPromptCreate() {
        guard let win = guardedFocusedWindowState() else { return }
        if win.workspaceManager.activeWorkspace?.presets.isEmpty ?? true {
            NotificationCenter.default.post(
                name: .showCreatePresetSheet,
                object: nil,
                userInfo: ["windowID": win.windowID]
            )
        } else {
            Task { await win.workspaceManager.saveCurrentPreset() }
        }
    }

    private func createPreset() {
        guard let win = guardedFocusedWindowState() else { return }
        NotificationCenter.default.post(
            name: .showCreatePresetSheet,
            object: nil,
            userInfo: ["windowID": win.windowID]
        )
    }

    // MARK: - Compose tabs

    private func registerComposeTabShortcuts() {
        register(.newComposeTab) { [weak self] in self?.createNewComposeTab() }
        register(.closeComposeTab) { [weak self] in self?.closeComposeTab() }
        register(.nextComposeTab) { [weak self] in self?.focusAdjacentComposeTab(forward: true) }
        register(.previousComposeTab) { [weak self] in self?.focusAdjacentComposeTab(forward: false) }

        register(.switchToComposeTab1) { [weak self] in self?.switchToComposeTab(0) }
        register(.switchToComposeTab2) { [weak self] in self?.switchToComposeTab(1) }
        register(.switchToComposeTab3) { [weak self] in self?.switchToComposeTab(2) }
        register(.switchToComposeTab4) { [weak self] in self?.switchToComposeTab(3) }
        register(.switchToComposeTab5) { [weak self] in self?.switchToComposeTab(4) }
        register(.switchToComposeTab6) { [weak self] in self?.switchToComposeTab(5) }
        register(.switchToComposeTab7) { [weak self] in self?.switchToComposeTab(6) }
        register(.switchToComposeTab8) { [weak self] in self?.switchToComposeTab(7) }
        register(.switchToComposeTab9) { [weak self] in self?.switchToComposeTab(8) }
    }

    private func createNewComposeTab() {
        guard let win = guardedFocusedWindowState() else { return }
        win.startNewAgentSessionFromGlobalShortcut()
    }

    private func closeComposeTab() {
        guard let win = guardedFocusedWindowState() else { return }
        win.closeActiveComposeTabFromShortcut()
    }

    private func focusAdjacentComposeTab(forward: Bool) {
        guard let win = guardedFocusedWindowState() else { return }
        guard win.promptManager.composeTabCount > 1 else { return }

        let tabs = win.promptManager.currentComposeTabs
        let activeTabID = win.promptManager.activeComposeTabID
        guard let targetTabID = win.agentModeViewModel.adjacentSidebarSessionTabID(
            from: activeTabID,
            forward: forward,
            in: tabs,
            currentTabID: activeTabID
        ) else {
            return
        }
        Task { await win.promptManager.switchComposeTab(targetTabID) }
    }

    private func switchToComposeTab(_ index: Int) {
        guard let win = guardedFocusedWindowState() else { return }

        let tabs = win.promptManager.currentComposeTabs
        guard index < tabs.count else { return }

        let activeTabID = win.promptManager.activeComposeTabID
        guard let tabID = win.agentModeViewModel.sessionSidebarShortcutTabID(
            at: index,
            in: tabs,
            currentTabID: activeTabID
        ) else {
            return
        }
        Task { await win.promptManager.switchComposeTab(tabID) }
    }

    // MARK: - Font scale

    private func registerFontScaleShortcuts() {
        register(.increaseFontScale) { FontScaleManager.shared.increase() }
        register(.decreaseFontScale) { FontScaleManager.shared.decrease() }
    }

    // MARK: - Agent

    private func registerAgentShortcuts() {
        register(.agentNewChat) { [weak self] in self?.startNewAgentSessionFromShortcut() }
        register(.toggleNavigationSidebar) { [weak self] in self?.toggleNavigationSidebarFromShortcut() }
        register(.previousParentAgentSession) { [weak self] in self?.focusAdjacentParentAgentSession(forward: false) }
        register(.nextParentAgentSession) { [weak self] in self?.focusAdjacentParentAgentSession(forward: true) }
        register(.showCurrentWindowAgentNavigationHUD) { [weak self] in self?.showAgentNavigationHUD(mode: .currentWindow) }
        register(.showAllAgentsNavigationHUD) { [weak self] in self?.showAgentNavigationHUD(mode: .allAgents) }
    }

    private func startNewAgentSessionFromShortcut() {
        guard let win = guardedFocusedWindowState() else { return }
        win.startNewAgentSessionFromGlobalShortcut()
    }

    private func toggleNavigationSidebarFromShortcut() {
        guard let win = guardedFocusedWindowState() else { return }
        NotificationCenter.default.post(
            name: .toggleRepoPromptNavigationSidebar,
            object: nil,
            userInfo: ["windowID": win.windowID]
        )
    }

    private func focusAdjacentParentAgentSession(forward: Bool) {
        guard let win = guardedFocusedWindowState() else { return }
        let tabs = win.promptManager.currentComposeTabs
        let activeTabID = win.promptManager.activeComposeTabID
        guard let targetTabID = win.agentModeViewModel.adjacentParentSidebarSessionTabID(
            from: activeTabID,
            forward: forward,
            in: tabs
        ) else {
            return
        }
        Task { await win.promptManager.switchComposeTab(targetTabID) }
    }

    private func showAgentNavigationHUD(mode: AgentNavigationHUDMode) {
        guard let win = guardedFocusedWindowState() else { return }
        NotificationCenter.default.post(
            name: .showAgentNavigationHUD,
            object: nil,
            userInfo: [
                AgentNavigationHUDNotificationUserInfoKey.windowID: win.windowID,
                AgentNavigationHUDNotificationUserInfoKey.mode: mode.rawValue
            ]
        )
    }
}
