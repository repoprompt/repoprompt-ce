import AppKit
import KeyboardShortcuts

struct AgentChatOptionsMenuTarget: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let agentSessionID: UUID
    let tabName: String
}

enum AgentSessionHandoffPrompt {
    private static func quotedSingleLineTitle(_ title: String) -> String {
        let reflected = String(reflecting: title)
        var rendered = ""
        rendered.reserveCapacity(reflected.utf8.count)
        for scalar in reflected.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                rendered += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                rendered.unicodeScalars.append(scalar)
            }
        }
        return rendered
    }

    static func render(
        target: AgentChatOptionsMenuTarget,
        cliCommandName: String,
        instructions: String = ""
    ) -> String {
        let prompt = """
        Use RepoPrompt CE to continue this exact Agent Mode session.

        Session title: \(quotedSingleLineTitle(target.tabName))
        Window ID: \(target.windowID)
        Workspace ID: \(target.workspaceID.uuidString)
        Context ID (compose tab): \(target.tabID.uuidString)
        Agent session ID: \(target.agentSessionID.uuidString)

        MCP:
        1. Call `bind_context` with `{"op":"bind","window_id":\(target.windowID),"context_id":"\(target.tabID.uuidString)"}`.
        2. Call `agent_manage` with `{"op":"extract_handoff","session_id":"\(target.agentSessionID.uuidString)"}`.
        3. Consume the returned `<forked_session>` XML before continuing.

        CLI equivalent (`\(cliCommandName)`):
        `\(cliCommandName) -w \(target.windowID) --context-id \(target.tabID.uuidString) -c agent_manage -j '{"op":"extract_handoff","session_id":"\(target.agentSessionID.uuidString)"}'`
        """
        guard !instructions.isEmpty else {
            return prompt
        }
        return prompt + "\n\nAdditional instructions:\n" + instructions
    }
}

struct AgentChatOptionsMenuSnapshot: Equatable {
    let target: AgentChatOptionsMenuTarget
    let isPinned: Bool
    /// Generation-bearing capture for Copy Session ID.
    ///
    /// `AgentChatOptionsMenuTarget` compares tab name and session ID but carries no binding
    /// generations, so a tab that rebinds to the *same* session ID between menu open and click would
    /// still validate. Carrying the exact incarnation here closes that gap. `nil` means the current
    /// session is not an eligible oversight endpoint and the item is not offered.
    let copySessionIDTarget: AgentSessionCopyIDTarget?

    init(
        target: AgentChatOptionsMenuTarget,
        isPinned: Bool,
        copySessionIDTarget: AgentSessionCopyIDTarget? = nil
    ) {
        self.target = target
        self.isPinned = isPinned
        self.copySessionIDTarget = copySessionIDTarget
    }
}

enum AgentChatShortcutAction: CaseIterable {
    case pin, rename, stash, handoff, copySessionID, delete

    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .pin: .pinAgentSession
        case .rename: .renameAgentSession
        case .stash: .stashAgentSession
        case .handoff: .handoffAgentSession
        case .copySessionID: .copyAgentSessionID
        case .delete: .deleteAgentSession
        }
    }

    func perform(snapshot: AgentChatOptionsMenuSnapshot, actions: AgentChatOptionsMenuActions) {
        switch self {
        case .pin: actions.togglePin(snapshot.target)
        case .rename: actions.rename(snapshot.target)
        case .stash: actions.stash(snapshot.target)
        case .handoff: actions.copyHandoffPrompt(snapshot.target)
        case .copySessionID:
            if let target = snapshot.copySessionIDTarget { actions.copySessionID(target) }
        case .delete: actions.delete(snapshot.target)
        }
    }
}

struct AgentChatOptionsMenuActions {
    let togglePin: (AgentChatOptionsMenuTarget) -> Void
    let rename: (AgentChatOptionsMenuTarget) -> Void
    let stash: (AgentChatOptionsMenuTarget) -> Void
    let copyHandoffPrompt: (AgentChatOptionsMenuTarget) -> Void
    let copySessionID: (AgentSessionCopyIDTarget) -> Void
    let delete: (AgentChatOptionsMenuTarget) -> Void
}

private final class AgentChatOptionsMenuItem: NSMenuItem {
    private let handler: () -> Void

    @MainActor
    init(title: String, symbolName: String, shortcutName: KeyboardShortcuts.Name, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler(_:)), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        // Keep `title` the plain action name and show the current assignment as a native key
        // equivalent so AppKit renders and announces it as a shortcut. This transient pop-up menu is
        // never part of `NSApp.mainMenu`, the only menu the recorder scans for conflicts, so it
        // reserves no keys. While the menu tracks, KeyboardShortcuts' event-tracking monitor
        // consumes registered shortcuts first, so a press still dispatches exactly once.
        setShortcut(KeyboardShortcuts.getShortcut(for: shortcutName))
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
    static func makeMenu(
        snapshot: AgentChatOptionsMenuSnapshot,
        actions: AgentChatOptionsMenuActions
    ) -> NSMenu {
        let target = snapshot.target
        let menu = NSMenu(title: "Chat Options")
        menu.autoenablesItems = false
        menu.addItem(AgentChatOptionsMenuItem(
            title: snapshot.isPinned ? "Unpin" : "Pin",
            symbolName: snapshot.isPinned ? "pin.slash" : "pin",
            shortcutName: .pinAgentSession,
            handler: { actions.togglePin(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Rename",
            symbolName: "pencil",
            shortcutName: .renameAgentSession,
            handler: { actions.rename(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Stash",
            symbolName: "tray.and.arrow.down",
            shortcutName: .stashAgentSession,
            handler: { actions.stash(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Handoff",
            symbolName: "arrow.right.doc.on.clipboard",
            shortcutName: .handoffAgentSession,
            handler: { actions.copyHandoffPrompt(target) }
        ))
        if let copySessionIDTarget = snapshot.copySessionIDTarget {
            menu.addItem(AgentChatOptionsMenuItem(
                title: "Copy Session ID",
                symbolName: "doc.on.doc",
                shortcutName: .copyAgentSessionID,
                handler: { actions.copySessionID(copySessionIDTarget) }
            ))
        }
        menu.addItem(.separator())
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Delete",
            symbolName: "trash",
            shortcutName: .deleteAgentSession,
            handler: { actions.delete(target) }
        ))
        return menu
    }

    static func popUp(
        below anchorView: NSView,
        snapshot: AgentChatOptionsMenuSnapshot,
        actions: AgentChatOptionsMenuActions
    ) {
        let menu = makeMenu(snapshot: snapshot, actions: actions)
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
