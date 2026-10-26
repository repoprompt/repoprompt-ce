import AppKit

/// Sidebar row action that copies a persistent Agent Mode session UUID to the clipboard.
///
/// Owns optional-UUID enablement and exact single-write clipboard semantics for the
/// `Copy Session ID` command in active, sub-agent, and archived sidebar row context menus.
@MainActor
struct AgentSidebarSessionIDCopyAction {
    typealias ClipboardWriter = @MainActor (String) -> Void

    static let menuTitle = "Copy Session ID"

    private let sessionID: UUID?
    private let clipboardWriter: ClipboardWriter
    /// Click-time revalidation of the captured identity. A row skipped by equality can hold an old
    /// capture; when this returns `false` the action fails closed with zero clipboard writes.
    private let isCurrent: (@MainActor (UUID) -> Bool)?

    init(
        sessionID: UUID?,
        isCurrent: (@MainActor (UUID) -> Bool)? = nil,
        clipboardWriter: @escaping ClipboardWriter
    ) {
        self.sessionID = sessionID
        self.isCurrent = isCurrent
        self.clipboardWriter = clipboardWriter
    }

    var isEnabled: Bool {
        sessionID != nil
    }

    func perform() {
        guard let sessionID, isCurrent?(sessionID) ?? true else { return }
        clipboardWriter(sessionID.uuidString)
    }

    static func systemClipboard(
        sessionID: UUID?,
        isCurrent: (@MainActor (UUID) -> Bool)? = nil
    ) -> Self {
        AgentSidebarSessionIDCopyAction(
            sessionID: sessionID,
            isCurrent: isCurrent,
            clipboardWriter: { value in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
            }
        )
    }
}
