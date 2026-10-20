import Foundation

extension MCPServerViewModel {
    @MainActor
    func notifyContextBuilderCommit(_ tab: ComposeTabState) {
        guard !tab.name.isEmpty else { return }
        NotificationService.shared.notifyContextBuilderComplete(tabName: tab.name, tabID: tab.id, fallbackToDockBounce: true)
    }

    static func hint(_ hint: MCPTabContextHint, matches context: MCPTabContextSnapshot) -> Bool {
        guard hint.tabID == context.tabID else { return false }
        if let workspaceID = hint.workspaceID, context.workspaceID != workspaceID {
            return false
        }
        if let windowID = hint.windowID, context.windowID != windowID {
            return false
        }
        return true
    }
}
