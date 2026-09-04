import AppKit

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
}

struct AgentChatOptionsMenuActions {
    let togglePin: (AgentChatOptionsMenuTarget) -> Void
    let rename: (AgentChatOptionsMenuTarget) -> Void
    let stash: (AgentChatOptionsMenuTarget) -> Void
    let copyHandoffPrompt: (AgentChatOptionsMenuTarget) -> Void
    let delete: (AgentChatOptionsMenuTarget) -> Void
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
            handler: { actions.togglePin(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Rename",
            symbolName: "pencil",
            handler: { actions.rename(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Stash",
            symbolName: "tray.and.arrow.down",
            handler: { actions.stash(target) }
        ))
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Handoff",
            symbolName: "arrow.right.doc.on.clipboard",
            handler: { actions.copyHandoffPrompt(target) }
        ))
        menu.addItem(.separator())
        menu.addItem(AgentChatOptionsMenuItem(
            title: "Delete",
            symbolName: "trash",
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
