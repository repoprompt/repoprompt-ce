// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

/// Owns provider-return -> format -> observer -> handler-result order. App callbacks
/// supply presentation and live observer routing, not a second execution pipeline.
package struct MCPToolCompletionPublisher: Sendable {
    package let toolName: String
    package let supervisor: MCPToolExecutionSupervisor
    package let gate: MCPToolPublicationGate
    package let beforeFormatting: @Sendable () async -> Void
    package let beforeObservers: @Sendable () async -> Void
    package let format: @Sendable (Value) -> [Tool.Content]
    package let notify: @Sendable (Value, Bool, Bool) async -> Void
    package let errorResult: @Sendable (Error) -> CallTool.Result
    package let logError: @Sendable (Error) -> Void
    package let finish: @Sendable (CallTool.Result, String) -> CallTool.Result

    package init(
        toolName: String,
        supervisor: MCPToolExecutionSupervisor,
        gate: MCPToolPublicationGate,
        beforeFormatting: @escaping @Sendable () async -> Void,
        beforeObservers: @escaping @Sendable () async -> Void,
        format: @escaping @Sendable (Value) -> [Tool.Content],
        notify: @escaping @Sendable (Value, Bool, Bool) async -> Void,
        errorResult: @escaping @Sendable (Error) -> CallTool.Result,
        logError: @escaping @Sendable (Error) -> Void,
        finish: @escaping @Sendable (CallTool.Result, String) -> CallTool.Result
    ) {
        self.toolName = toolName
        self.supervisor = supervisor
        self.gate = gate
        self.beforeFormatting = beforeFormatting
        self.beforeObservers = beforeObservers
        self.format = format
        self.notify = notify
        self.errorResult = errorResult
        self.logError = logError
        self.finish = finish
    }

    /// The caller's exact window ownership scope encloses this entire sequence.
    /// Global dispatch intentionally does not perform window publication checks.
    package func dispatchAndComplete(
        operation: @escaping @Sendable () async throws -> Value,
        windowScoped: Bool,
        release: @Sendable () -> Void
    ) async throws -> CallTool.Result {
        let value = try await EditFlowPerf.measure(
            EditFlowPerf.Stage.MCPToolCall.dispatch,
            EditFlowPerf.Dimensions(toolName: toolName),
            operation: operation
        )
        release()
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
            EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, state) }
        if windowScoped { await supervisor.reportPostProviderPhase(.promptExportFormatting) }
        await beforeFormatting()
        if windowScoped { try await gate.validate() }
        let blocks = EditFlowPerf.measure(
            EditFlowPerf.Stage.MCPToolCall.formatResult,
            EditFlowPerf.Dimensions(toolName: toolName)
        ) { format(value) }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPToolCall.formatResultReturned,
            EditFlowPerf.Dimensions(toolName: toolName)
        )
        if windowScoped {
            await supervisor.reportPostProviderPhase(.promptExportFormatting, transition: .completed)
            await supervisor.reportPostProviderPhase(.promptExportPublication)
        }
        await beforeObservers()
        if windowScoped { try await gate.validate() }
        await EditFlowPerf.measure(
            EditFlowPerf.Stage.MCPToolCall.completionObservers,
            EditFlowPerf.Dimensions(toolName: toolName)
        ) {
            let shouldNotify = windowScoped ? true : await gate.isPublicationCurrent()
            if shouldNotify {
                await notify(value, false, windowScoped)
            }
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
            EditFlowPerf.Dimensions(toolName: toolName, status: "success")
        )
        if windowScoped {
            try await gate.validate()
            await supervisor.reportPostProviderPhase(.promptExportPublication, transition: .completed)
        }
        return finish(CallTool.Result(content: blocks, isError: false), "success")
    }

    /// Contract failures are handled before this fallback, including the existing
    /// cleanup-unresponsive abort boundary which must retain its resource lease.
    package func failure(_ error: Error, windowScoped: Bool) async -> CallTool.Result {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
            EditFlowPerf.Dimensions(toolName: toolName, outcome: "dispatchError")
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, state) }
        logError(error)
        await EditFlowPerf.measure(
            EditFlowPerf.Stage.MCPToolCall.completionObservers,
            EditFlowPerf.Dimensions(toolName: toolName)
        ) {
            if await gate.isCompletionObserverCurrent() {
                await notify(.object(["error": .string(error.localizedDescription), "tool": .string(toolName)]), true, windowScoped)
            }
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
            EditFlowPerf.Dimensions(toolName: toolName, status: "dispatchError")
        )
        return finish(errorResult(error), "dispatchError")
    }
}
