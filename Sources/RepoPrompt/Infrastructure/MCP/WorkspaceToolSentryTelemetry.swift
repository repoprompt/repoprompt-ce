import Foundation

enum WorkspaceToolSentryTelemetry {
    static func span<T>(
        operation: SentryTelemetryBootstrap.SpanOperation,
        toolName: SentryTelemetryBootstrap.ToolName,
        completionAttributes: (T) -> [SentryTelemetryBootstrap.Attribute] = { _ in [] },
        _ work: () async throws -> T
    ) async rethrows -> T {
        let attributes = attributes(toolName: toolName, outcome: .started)
        SentryTelemetryBootstrap.addBreadcrumb(
            .workspaceTool,
            action: .mcpToolStarted,
            attributes: attributes
        )
        return try await SentryTelemetryBootstrap.spanAsync(operation, attributes: attributes) { _ in
            do {
                let result = try await work()
                SentryTelemetryBootstrap.addBreadcrumb(
                    .workspaceTool,
                    action: .mcpToolCompleted,
                    attributes: self.attributes(toolName: toolName, outcome: .completed)
                        + completionAttributes(result)
                )
                return result
            } catch {
                SentryTelemetryBootstrap.addBreadcrumb(
                    .workspaceTool,
                    action: .mcpToolFailed,
                    attributes: self.attributes(toolName: toolName, outcome: .failed, isError: true)
                )
                throw error
            }
        }
    }

    private static func attributes(
        toolName: SentryTelemetryBootstrap.ToolName,
        outcome: SentryTelemetryBootstrap.Outcome,
        isError: Bool = false
    ) -> [SentryTelemetryBootstrap.Attribute] {
        [
            .entrypoint(.mcp),
            .clientClass(.externalAgent),
            .toolName(toolName),
            .toolDomain(toolName.domain),
            .outcome(outcome),
            .isError(isError)
        ]
    }
}
