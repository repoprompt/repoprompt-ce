import Foundation

enum WorkspaceActionSentryTelemetry {
    static func trace<T>(
        actionName: String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let workspaceAction = workspaceAction(for: actionName)
        let attributes = attributes(action: workspaceAction, outcome: .started)
        SentryTelemetryBootstrap.addBreadcrumb(
            .workspaceAction,
            action: .workspaceActionStarted,
            attributes: attributes
        )
        return try await SentryTelemetryBootstrap.traceAsync(.workspaceAction, attributes: attributes) {
            do {
                let result = try await work()
                SentryTelemetryBootstrap.addBreadcrumb(
                    .workspaceAction,
                    action: .workspaceActionCompleted,
                    attributes: self.attributes(action: workspaceAction, outcome: .completed)
                )
                return result
            } catch {
                SentryTelemetryBootstrap.addBreadcrumb(
                    .workspaceAction,
                    action: .workspaceActionFailed,
                    attributes: self.attributes(action: workspaceAction, outcome: .failed, isError: true)
                )
                throw error
            }
        }
    }

    private static func attributes(
        action: SentryTelemetryBootstrap.WorkspaceAction,
        outcome: SentryTelemetryBootstrap.Outcome,
        isError: Bool = false
    ) -> [SentryTelemetryBootstrap.Attribute] {
        [
            .entrypoint(.mcp),
            .clientClass(.externalAgent),
            .toolName(.manageWorkspaces),
            .toolDomain(.workspace),
            .workspaceAction(action),
            .outcome(outcome),
            .isError(isError)
        ]
    }

    private static func workspaceAction(for actionName: String) -> SentryTelemetryBootstrap.WorkspaceAction {
        switch actionName {
        case "create":
            .create
        case "delete":
            .delete
        case "add_folder", "remove_folder":
            .folder
        case "hide", "unhide":
            .hide
        case "switch":
            .switchWorkspace
        case "list_tabs", "select_tab", "create_tab", "close_tab":
            .tab
        default:
            .switchWorkspace
        }
    }
}
