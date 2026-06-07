import AppKit

@MainActor
final class DockMenuController: NSObject {
    private let requestNewWindow: @MainActor () -> Void

    init(requestNewWindow: @escaping @MainActor () -> Void = {
        AppWindowOpener.shared.requestMainWindowFromDock()
    }) {
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
    }
}
