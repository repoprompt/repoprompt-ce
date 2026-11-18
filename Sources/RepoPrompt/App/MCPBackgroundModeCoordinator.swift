import AppKit

@MainActor
final class MCPBackgroundModeCoordinator: NSObject {
    static let shared = MCPBackgroundModeCoordinator()

    private var statusItem: NSStatusItem?
    private(set) var backgroundedWindowID: Int?

    var isBackgrounded: Bool {
        backgroundedWindowID != nil
    }

    func background(windowState: WindowState) {
        guard let window = windowState.nsWindow else { return }
        backgroundedWindowID = windowState.windowID
        installStatusItemIfNeeded()
        updateStatusMenu(with: windowState)
        // Hide the window without tearing down its SwiftUI scene.
        window.orderOut(nil)
    }

    func restore() {
        let windowID = backgroundedWindowID
        backgroundedWindowID = nil
        removeStatusItem()

        guard let windowID else { return }
        let state = WindowStatesManager.shared.window(withID: windowID)
        if let window = state?.nsWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func clearIfBackgroundedWindow(windowID: Int) {
        guard backgroundedWindowID == windowID else { return }
        backgroundedWindowID = nil
        removeStatusItem()
    }

    func resetForTermination() {
        backgroundedWindowID = nil
        removeStatusItem()
    }

    func showConnectionsDashboard() {
        let windows = WindowStatesManager.shared.allWindows.filter { !$0.isClosing && $0.nsWindow != nil }
        let keyWindow = NSApplication.shared.keyWindow
        let target = windows.first { $0.nsWindow === (keyWindow?.sheetParent ?? keyWindow) }
            ?? windows.last { $0.nsWindow?.isVisible == true }
            ?? windows.last
        guard let target else { return }
        showConnectionsDashboard(in: target)
    }

    private func showConnectionsDashboard(in target: WindowState) {
        guard !WindowStatesManager.shared.isTerminating,
              NSApplication.shared.modalWindow == nil,
              !target.isClosing, let window = target.nsWindow, window.attachedSheet == nil
        else { return }
        if backgroundedWindowID == target.windowID {
            restore()
        } else {
            if window.isMiniaturized { window.deminiaturize(nil) }
            target.focusWindowIfPossible()
        }
        NotificationCenter.default.post(name: .showMCPStatusWindow, object: nil, userInfo: ["windowID": target.windowID])
    }

    @objc private func showConnectionsDashboardAction(_ sender: Any?) {
        guard let backgroundedWindowID,
              let target = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == backgroundedWindowID })
        else { return }
        showConnectionsDashboard(in: target)
    }

    @objc private func restoreAction(_ sender: Any?) {
        restore()
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = smallAppIconImage()
            button.imagePosition = .imageOnly
            button.title = ""
        }
        statusItem = item
    }

    private func smallAppIconImage() -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        if let image = NSImage(named: "RepoPromptLogoNoBg_Monochrome") {
            image.size = size
            image.isTemplate = false
            return image
        }
        guard let base = NSApp.applicationIconImage else { return nil }
        let image = (base.copy() as? NSImage) ?? base
        image.size = size
        return image
    }

    private func updateStatusMenu(with windowState: WindowState) {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let workspaceTitle = "MCP Active: \(windowState.workspaceDisplayName)"
        let workspaceItem = NSMenuItem(title: workspaceTitle, action: nil, keyEquivalent: "")
        workspaceItem.isEnabled = false
        menu.addItem(workspaceItem)
        menu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show RepoPrompt", action: #selector(restoreAction(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let connectionsItem = NSMenuItem(title: "Show MCP Connections…", action: #selector(showConnectionsDashboardAction(_:)), keyEquivalent: "")
        connectionsItem.target = self
        menu.addItem(connectionsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit RepoPrompt", action: #selector(quitAction(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }
}
