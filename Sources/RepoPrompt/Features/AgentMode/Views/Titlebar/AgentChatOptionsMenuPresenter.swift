import AppKit

struct AgentChatOptionsMenuSnapshot: Equatable {
    let isPinned: Bool
}

struct AgentChatOptionsMenuActions {
    let togglePin: () -> Void
    let rename: () -> Void
    let stash: () -> Void
    let delete: () -> Void
}

private final class AgentChatOptionsMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbolName: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler(_:)), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performHandler(_ sender: NSMenuItem) {
        _ = sender
        handler()
    }
}

@MainActor
enum AgentChatOptionsMenuPresenter {
    static func popUp(
        below anchorView: NSView,
        snapshot: AgentChatOptionsMenuSnapshot,
        actions: AgentChatOptionsMenuActions
    ) {
        let menu = NSMenu(title: "Chat Options")
        menu.autoenablesItems = false
        menu.addItem(AgentChatOptionsMenuItem(
            title: snapshot.isPinned ? "Unpin Chat" : "Pin Chat",
            symbolName: snapshot.isPinned ? "pin.slash" : "pin",
            handler: actions.togglePin
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Rename Chat…",
            symbolName: "pencil",
            handler: actions.rename
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Stash Chat",
            symbolName: "tray.and.arrow.down",
            handler: actions.stash
        ))
        menu.addItem(.separator())
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Delete Chat…",
            symbolName: "trash",
            handler: actions.delete
        ))

        let menuOriginY = anchorView.isFlipped
            ? anchorView.bounds.maxY + 2
            : anchorView.bounds.minY - 2
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchorView.bounds.minX, y: menuOriginY),
            in: anchorView
        )
    }
}
