import Foundation

enum MCPToolSentryTelemetry {
    static func recordStarted(toolName: String) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .mcpTool,
            action: .mcpToolStarted,
            attributes: attributes(
                toolName: toolName,
                outcome: .started,
                isError: false
            )
        )
    }

    static func recordCompleted(toolName: String) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .mcpTool,
            action: .mcpToolCompleted,
            attributes: attributes(
                toolName: toolName,
                outcome: .completed,
                isError: false
            )
        )
    }

    static func recordCancelled(toolName: String) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .mcpTool,
            action: .mcpToolCancelled,
            attributes: attributes(
                toolName: toolName,
                outcome: .cancelled,
                isError: true,
                errorKind: .cancelled
            )
        )
    }

    static func recordFailed(
        toolName: String,
        errorKind: SentryTelemetryBootstrap.ErrorKind = .error
    ) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .mcpTool,
            action: .mcpToolFailed,
            attributes: attributes(
                toolName: toolName,
                outcome: .failed,
                isError: true,
                errorKind: errorKind
            )
        )
    }

    static func recordTimedOut(toolName: String) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .mcpTool,
            action: .mcpToolTimedOut,
            attributes: attributes(
                toolName: toolName,
                outcome: .timedOut,
                isError: true,
                errorKind: .timeout
            )
        )
    }

    static func attributes(
        toolName: String,
        outcome: SentryTelemetryBootstrap.Outcome,
        isError: Bool,
        errorKind: SentryTelemetryBootstrap.ErrorKind? = nil
    ) -> [SentryTelemetryBootstrap.Attribute] {
        var attributes: [SentryTelemetryBootstrap.Attribute] = [
            .entrypoint(.mcp),
            .clientClass(.externalAgent),
            .outcome(outcome),
            .isError(isError)
        ]
        if let knownToolName = SentryTelemetryBootstrap.ToolName(rawToolName: toolName) {
            attributes.append(.toolName(knownToolName))
            attributes.append(.toolDomain(knownToolName.domain))
        } else {
            attributes.append(.toolDomain(.mcp))
        }
        if let errorKind {
            attributes.append(.errorKind(errorKind))
        }
        return attributes
    }
}
