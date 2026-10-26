import AppKit
import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import RepoPromptInstrumentation
import RepoPromptSettingsCore

@MainActor
final class GlobalKeyboardShortcutsCoordinator {
    static let shared = GlobalKeyboardShortcutsCoordinator()

    lazy var bindingDisplay = KeyboardShortcutBindingDisplay()
    let closeMenuShortcut = ManagedCloseMenuShortcut()

    private var didRegisterHandlers = false
    private var localBindingObserver: NSObjectProtocol?

    private init() {
        // The library registers a hot key whenever an assignment is saved (recorder, reset, or a
        // first-launch default). Drop local bindings synchronously, before AppKit can deliver another
        // key event; the app-wide registration update arrives a run-loop turn later. Initializing the
        // names here first keeps their default-writing static initializers out of the observer.
        KeyboardShortcuts.disable(LocalKeyboardShortcut.names)
        localBindingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { KeyboardShortcuts.disable(LocalKeyboardShortcut.names) }
        }
    }

    func ensureHandlersRegistered() {
        guard !didRegisterHandlers else { return }
        didRegisterHandlers = true

        registerApplicationShortcuts()
        registerPresetShortcuts()
        registerWorkspaceShortcuts()
        registerComposeTabShortcuts()
        registerFontScaleShortcuts()
        registerAgentShortcuts()
        registerAgentWorkflowShortcuts()
    }

    /// Callback guards cannot yield an intercepted Carbon event back to AppKit.
    /// Unregister window-only bindings outside main windows so native dialog/editor keys work.
    func updateRegistrationContext(hasEligibleMainWindow: Bool) {
        // The library registers a Carbon hot key whenever an assignment is saved, including first-launch
        // defaults, even for names without handlers. Local bindings must never swallow their keys, so
        // drop them first (before the handler guard), then restore any global binding sharing those keys.
        KeyboardShortcuts.disable(LocalKeyboardShortcut.names)
        guard didRegisterHandlers else { return }
        let catalog = KeyboardShortcutCatalog.sections.flatMap(\.bindings).map(\.name)
            .filter { !LocalKeyboardShortcut.names.contains($0) }
        let applicationNames = Set(KeyboardShortcutCatalog.applicationNames).union([.closeComposeTab])
        let names = catalog.filter { !applicationNames.contains($0) }
        if hasEligibleMainWindow {
            KeyboardShortcuts.enable(names)
        } else {
            KeyboardShortcuts.disable(names)
        }
        // Last, so application commands (and window close) survive any shared-key disable above.
        // `enable` registers system-wide Carbon hot keys immediately; never do so while inactive.
        if KeyboardShortcuts.isEnabled {
            KeyboardShortcuts.enable(catalog.filter { applicationNames.contains($0) })
        }
    }

    // MARK: - Registration helpers

    private func register(_ name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name) {
            Task { @MainActor in
                guard NSApplication.shared.isActive,
                      !WindowStatesManager.shared.isTerminating,
                      GlobalSettingsStore.shared.enableKeyboardShortcuts()
                else { return }
                action()
            }
        }
    }

    // MARK: - Context helpers

    private func focusedWindowState() -> WindowState? {
        WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
    }

    private func focusedOrLatestWindowState() -> WindowState? {
        focusedWindowState() ?? WindowStatesManager.shared.latestWindowState
    }

    private func guardedFocusedWindowState() -> WindowState? {
        guard NSApplication.shared.isActive else { return nil }
        guard NSApplication.shared.modalWindow == nil,
              let keyWindow = NSApplication.shared.keyWindow,
              keyWindow.attachedSheet == nil,
              let win = WindowStatesManager.shared.allWindows.first(where: { $0.nsWindow === keyWindow }),
              !win.isClosing
        else { return nil }
        return win
    }

    /// On the first HUD shortcut after app activation, the Carbon handler can fire
    /// before our SwiftUI focus flag has updated. Route to the front/latest
    /// RepoPrompt window so the first press still opens the HUD.
    private func guardedHUDWindowState() -> WindowState? {
        guard NSApplication.shared.isActive,
              GlobalSettingsStore.shared.enableKeyboardShortcuts(),
              NSApplication.shared.modalWindow == nil
        else { return nil }
        if NSApplication.shared.keyWindow != nil { return guardedFocusedWindowState() }
        return focusedOrLatestWindowState()
    }

    // MARK: - Application

    private var updateAction: (@MainActor () -> Void)?

    func installUpdateAction(_ action: @escaping @MainActor () -> Void) {
        updateAction = action
    }

    func openSettings() {
        guard let win = focusedOrLatestWindowState() else { return }
        SettingsWindowCoordinator.shared.open(windowState: win)
    }

    private func registerApplicationShortcuts() {
        register(.newWorkspaceWindow) { AppWindowOpener.shared.requestMainWindowFromDock() }
        register(.showAppSettings) { [weak self] in self?.openSettings() }
        register(.closeAppWindow) { NSApplication.shared.keyWindow?.performClose(nil) }
        register(.checkForUpdates) { [weak self] in self?.updateAction?() }
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
        Task { await win.workspaceManager.saveAndExitToFallback() }
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
        if let win = guardedFocusedWindowState() {
            win.closeActiveComposeTabFromShortcut()
        } else if NSApplication.shared.modalWindow == nil,
                  let keyWindow = NSApplication.shared.keyWindow,
                  keyWindow.attachedSheet == nil,
                  !WindowStatesManager.shared.allWindows.contains(where: { $0.nsWindow === keyWindow })
        {
            // Preserve standard Close in Settings/auxiliary windows without a second Cmd-W binding.
            keyWindow.performClose(nil)
        }
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
        if selectAgentNavigationHUDResultIfPresented(index, in: win) {
            return
        }

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

    private func selectAgentNavigationHUDResultIfPresented(_ index: Int, in win: WindowState) -> Bool {
        let request = AgentNavigationHUDHandledRequest()
        NotificationCenter.default.post(
            name: .selectAgentNavigationHUDResult,
            object: nil,
            userInfo: [
                AgentNavigationHUDNotificationUserInfoKey.windowID: win.windowID,
                AgentNavigationHUDNotificationUserInfoKey.resultIndex: index,
                AgentNavigationHUDNotificationUserInfoKey.handledRequest: request
            ]
        )
        return request.handled
    }

    // MARK: - Font scale

    private func registerFontScaleShortcuts() {
        register(.increaseFontScale) { [weak self] in
            guard self?.guardedFocusedWindowState() != nil else { return }
            FontScaleManager.shared.increase()
        }
        register(.decreaseFontScale) { [weak self] in
            guard self?.guardedFocusedWindowState() != nil else { return }
            FontScaleManager.shared.decrease()
        }
        register(.resetFontScale) { [weak self] in
            guard self?.guardedFocusedWindowState() != nil else { return }
            FontScaleManager.shared.reset()
        }
    }

    // MARK: - Agent workflow

    private func registerAgentWorkflowShortcuts() {
        register(.stopAgentRun) { [weak self] in self?.stopAgentRunFromShortcut() }
        register(.focusAgentComposer) { [weak self] in self?.guardedFocusedWindowState()?.focusAgentComposerFromShortcut() }
        register(.reopenStashedAgentSession) { [weak self] in
            self?.guardedFocusedWindowState()?.reopenLastStashedAgentSessionFromShortcut()
        }
        register(.nextAttentionAgentSession) { [weak self] in
            self?.guardedFocusedWindowState()?.focusNextAttentionAgentSessionFromShortcut()
        }
    }

    private func stopAgentRunFromShortcut() {
        guard let win = guardedFocusedWindowState() else { return }
        if win.stopAgentRunFromShortcut() { return }
        // Carbon cannot yield the press back to AppKit. With nothing to stop, give the default ⌘.
        // its native meaning (cancelOperation:, the Escape equivalent) so editors and Re-prompt keep it.
        guard Self.shouldForwardNativeCancel(stopShortcut: KeyboardShortcuts.getShortcut(for: .stopAgentRun)) else { return }
        let cancel = #selector(NSResponder.cancelOperation(_:))
        if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView {
            // Enter the text system's command path so delegates (the composer's Escape handling) see it.
            textView.doCommand(by: cancel)
        } else {
            NSApplication.shared.sendAction(cancel, to: nil, from: nil)
        }
    }

    /// Only the conventional ⌘. means cancel natively; a remapped Stop key has no fallback.
    static func shouldForwardNativeCancel(stopShortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        stopShortcut == KeyboardShortcuts.Shortcut(.period, modifiers: [.command])
    }

    // MARK: - Agent

    private func registerAgentShortcuts() {
        for action in AgentChatShortcutAction.allCases {
            register(action.shortcutName) { [weak self] in
                self?.guardedFocusedWindowState()?.performAgentChatShortcut(action)
            }
        }
        register(.agentNewChat) { [weak self] in self?.startNewAgentSessionFromShortcut() }
        register(.toggleNavigationSidebar) { [weak self] in self?.toggleNavigationSidebarFromShortcut() }
        register(.toggleContextComposer) { [weak self] in self?.toggleContextComposerFromShortcut() }
        register(.previousParentAgentSession) { [weak self] in self?.focusAdjacentParentAgentSession(forward: false) }
        register(.nextParentAgentSession) { [weak self] in self?.focusAdjacentParentAgentSession(forward: true) }
        registerHUDShortcut(.showCurrentWindowAgentNavigationHUD, mode: .currentWindow)
        registerHUDShortcut(.showAllAgentsNavigationHUD, mode: .allAgents)
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

    private func toggleContextComposerFromShortcut() {
        guard let win = guardedFocusedWindowState() else { return }
        toggleContextComposer(in: win)
    }

    private func toggleContextComposer(in win: WindowState) {
        win.agentModeViewModel.toggleContextComposerIfActive()
    }

    #if DEBUG
        func test_toggleContextComposer(in win: WindowState) {
            toggleContextComposer(in: win)
        }
    #endif

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

    private func registerHUDShortcut(_ name: KeyboardShortcuts.Name, mode: AgentNavigationHUDMode) {
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
            // Carbon's physical event timestamp must be captured in the callback,
            // not after a potentially delayed main-actor Task hop.
            let eventTimestamp: TimeInterval? = if let event = GetCurrentEvent(),
                                                   GetEventClass(event) == UInt32(kEventClassKeyboard),
                                                   [UInt32(kEventHotKeyPressed), UInt32(kEventRawKeyDown)].contains(GetEventKind(event))
            {
                GetEventTime(event)
            } else {
                // The library's menu-tracking monitor may have no current Carbon
                // key event. Never use an unrelated event to suppress a real press.
                nil
            }
            let callbackAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                self?.showAgentNavigationHUD(mode: mode, eventTimestamp: eventTimestamp, callbackAt: callbackAt)
            }
        }
    }

    private func showAgentNavigationHUD(mode: AgentNavigationHUDMode, eventTimestamp: TimeInterval?, callbackAt: TimeInterval) {
        guard let win = guardedHUDWindowState() else {
            #if DEBUG
                focusedOrLatestWindowState()?.agentModeViewModel.perfRecorder.event("hud.command.ignored", fields: ["reason": "inactiveOrNoWindow"])
            #endif
            return
        }
        #if DEBUG
            win.agentModeViewModel.perfRecorder.event("hud.command.dispatched", fields: [
                "mode": mode.rawValue,
                "taskHopMS": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - callbackAt) * 1000),
                "hasEventTimestamp": String(eventTimestamp != nil)
            ])
        #endif
        var userInfo: [String: Any] = [
            AgentNavigationHUDNotificationUserInfoKey.windowID: win.windowID,
            AgentNavigationHUDNotificationUserInfoKey.mode: mode.rawValue
        ]
        if let eventTimestamp { userInfo[AgentNavigationHUDNotificationUserInfoKey.eventTimestamp] = eventTimestamp }
        NotificationCenter.default.post(
            name: .showAgentNavigationHUD,
            object: nil,
            userInfo: userInfo
        )
    }
}
