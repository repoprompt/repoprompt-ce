import AppKit
import Combine

/// SwiftUI supplies a standard Close item independently of our explicit commands.
/// Keep that item clickable, but let the configurable close-session/window binding
/// own its keyboard equivalent. Never strip unrelated responder-chain shortcuts.
@MainActor
final class ManagedCloseMenuShortcut {
    private var observations: Set<AnyCancellable> = []

    init() {
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.reconcile() }
                .store(in: &observations)
        }
    }

    func reconcile() {
        guard let menu = NSApplication.shared.mainMenu else { return }
        Self.removeAutomaticCloseEquivalent(in: menu)
    }

    static func removeAutomaticCloseEquivalent(in menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(NSWindow.performClose(_:)),
               item.keyEquivalent == "w",
               item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == .command
            {
                item.keyEquivalent = ""
            }
            if let submenu = item.submenu { removeAutomaticCloseEquivalent(in: submenu) }
        }
    }
}
