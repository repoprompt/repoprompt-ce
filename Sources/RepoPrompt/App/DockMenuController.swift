import AppKit
import RepoPromptSettingsCore

@MainActor
final class DockMenuController: NSObject {
    private let activateApplication: @MainActor () -> Void
    private let requestNewWindow: @MainActor () -> Void
    private let requestCommandCenter: @MainActor () -> Void
    private let commandCenterEnabled: @MainActor () -> Bool

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        },
        requestNewWindow: @escaping @MainActor () -> Void = {
            AppWindowOpener.shared.requestMainWindowFromDock()
        },
        requestCommandCenter: @escaping @MainActor () -> Void = { AppWindowOpener.shared.commandCenter.show() },
        commandCenterEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() }
    ) {
        self.activateApplication = activateApplication
        self.requestNewWindow = requestNewWindow
        self.requestCommandCenter = requestCommandCenter
        self.commandCenterEnabled = commandCenterEnabled
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(openNewWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        if commandCenterEnabled() {
            let centerItem = NSMenuItem(title: "Command Center", action: #selector(openCommandCenter(_:)), keyEquivalent: "")
            centerItem.target = self
            menu.addItem(centerItem)
        }
        return menu
    }

    @objc private func openCommandCenter(_ sender: Any?) {
        guard commandCenterEnabled() else { return }
        requestCommandCenter()
        activateApplication()
    }

    @objc private func openNewWindow(_ sender: Any?) {
        requestNewWindow()
        activateApplication()
    }
}
