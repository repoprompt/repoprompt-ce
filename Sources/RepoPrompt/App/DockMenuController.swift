import AppKit

@MainActor
final class DockMenuController: NSObject {
    private let activateApplication: @MainActor () -> Void
    private let requestNewWindow: @MainActor () -> Void

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        },
        requestNewWindow: @escaping @MainActor () -> Void = {
            AppWindowOpener.shared.requestMainWindowFromDock()
        }
    ) {
        self.activateApplication = activateApplication
        self.requestNewWindow = requestNewWindow
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
        return menu
    }

    @objc private func openNewWindow(_ sender: Any?) {
        requestNewWindow()
        activateApplication()
    }
}
