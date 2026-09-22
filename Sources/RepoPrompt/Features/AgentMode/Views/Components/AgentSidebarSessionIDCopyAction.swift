import AppKit

/// Sidebar row action that copies a persistent Agent Mode session UUID to the clipboard.
///
/// Owns optional-UUID enablement and exact single-write clipboard semantics for the
/// `Copy session ID` command in active, sub-agent, and archived sidebar row context menus.
@MainActor
struct AgentSidebarSessionIDCopyAction {
    typealias ClipboardWriter = @MainActor (String) -> Void

    static let menuTitle = "Copy session ID"

    private let sessionID: UUID?
    private let clipboardWriter: ClipboardWriter

    init(
        sessionID: UUID?,
        clipboardWriter: @escaping ClipboardWriter
    ) {
        self.sessionID = sessionID
        self.clipboardWriter = clipboardWriter
    }

    var isEnabled: Bool {
        sessionID != nil
    }

    func perform() {
        guard let sessionID else { return }
        clipboardWriter(sessionID.uuidString)
    }

    static func systemClipboard(sessionID: UUID?) -> Self {
        AgentSidebarSessionIDCopyAction(
            sessionID: sessionID,
            clipboardWriter: { value in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
            }
        )
    }
}
