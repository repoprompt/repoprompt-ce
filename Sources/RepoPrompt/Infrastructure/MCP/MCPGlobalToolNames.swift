import Foundation

/// Stable internal namespace for app-wide MCP tool names.
enum MCPGlobalToolName {
    static let appSettings = "app_settings"
    static let bindContext = "bind_context"
    static let manageWorkspaces = "manage_workspaces"

    static let orderedToolNames = [
        appSettings,
        bindContext,
        manageWorkspaces
    ]
}
