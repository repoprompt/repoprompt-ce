import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptMCPServer

private actor MCPRunToolStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

extension MCPToolExecutionRuntime {
    /// Optional projection of the legacy single-tool UI slot. It owns neither execution nor
    /// cancellation registration; a route without presentation uses the same execution path.
    struct Presentation {
        var began: @MainActor (UUID) -> Void = { _ in }
        var registered: @MainActor (UUID, @escaping () -> Void) -> Void = { _, _ in }
        var finished: @MainActor (UUID) -> Void = { _ in }
    }

    /// Execute one frozen invocation under its exact route, connection and catalog proof.
    /// Registration precedes provider dispatch; every exit uses the same completion owner.
    func execute<T>(
        _ invocation: MCPAppToolInvocation,
        ownerIdentity: ObjectIdentifier,
        indexedRunID: UUID?,
        waitCallOrigin: DomainAgentSessionLinkWaitInput? = nil,
        selfCallOrigin: AgentSelfMCPCallOrigin? = nil,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        validateInvocation: @escaping MCPToolInvocationValidator,
        presentation: Presentation = .init(),
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let name = invocation.toolName
        let invocationContext = invocation.context
        let routeID = invocation.windowID
        let toolToken = UUID()
        let capturedConnectionID = invocationContext.metadata.connectionID
        guard await validateInvocation(invocationContext, routeID, ownerIdentity) else {
            throw ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal
        }
        let registrationState = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.runToolRegistration,
            EditFlowPerf.Dimensions(toolName: name)
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPRunTool.registrationScheduled,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(toolName: name)
        )
        presentation.began(toolToken)

        let startGate = MCPRunToolStartGate()
        // Do not let the provider begin until registration and final dispatch validation finish.
        let task = Task {
            await startGate.wait()
            try Task.checkCancellation()
            guard await validateInvocation(invocationContext, routeID, ownerIdentity) else {
                throw ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal
            }
            return try await ServerNetworkManager.withConnectionID(capturedConnectionID) {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPRunTool.providerBegan,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(toolName: name)
                )
                do {
                    let result = try await EditFlowPerf.measure(
                        EditFlowPerf.Stage.MCPToolCall.providerExecution,
                        EditFlowPerf.Dimensions(toolName: name)
                    ) {
                        try await AgentSelfMCPCallOrigin.currentTaskLocal.withValue(selfCallOrigin) {
                            try await MCPInvocationContextBridge.withInvocation(invocationContext) {
                                try await AgentSessionLinkWaitCallOrigin.currentTaskLocal.withValue(waitCallOrigin) {
                                    try await body()
                                }
                            }
                        }
                    }
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.MCPRunTool.providerEnded,
                        correlation: lifecycleCorrelation,
                        EditFlowPerf.Dimensions(toolName: name, outcome: "success")
                    )
                    return result
                } catch {
                    let wasCancelled = error is CancellationError || MCPToolExecutionCancelledError.matches(error)
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.MCPRunTool.providerEnded,
                        correlation: lifecycleCorrelation,
                        EditFlowPerf.Dimensions(toolName: name, outcome: wasCancelled ? "cancelled" : "error")
                    )
                    throw error
                }
            }
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPRunTool.registrationMainActorEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(toolName: name)
        )
        presentation.registered(toolToken) { task.cancel() }
        registerToolExecution(
            executionID: toolToken, runID: indexedRunID, connectionID: capturedConnectionID,
            toolName: name, lifecycleCorrelation: lifecycleCorrelation, cancel: { task.cancel() }
        )
        if await !validateInvocation(invocationContext, routeID, ownerIdentity) {
            task.cancel()
            await startGate.open()
            unregisterToolExecution(executionID: toolToken, countAsEnded: false)
            presentation.finished(toolToken)
            throw ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal
        }
        await startGate.open()
        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolRegistration, registrationState)
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPRunTool.registrationEnded,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(toolName: name)
        )
        let cleanupExecution = makeCompletionHandler(
            executionID: toolToken, toolName: name, lifecycleCorrelation: lifecycleCorrelation,
            didFinish: { presentation.finished(toolToken) }
        )
        let cancellationState = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope,
            EditFlowPerf.Dimensions(toolName: name)
        )
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await cleanupExecution("cancelled") }
            }
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope, cancellationState)
            await cleanupExecution("success")
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPRunTool.returned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: name, outcome: "success")
            )
            return result
        } catch {
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope, cancellationState)
            task.cancel()
            let outcome = MCPToolExecutionCancelledError.matches(error) ? "cancelled" : "error"
            await cleanupExecution(outcome)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPRunTool.returned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: name, outcome: outcome)
            )
            if error is CancellationError { throw MCPToolExecutionCancelledError() }
            throw error
        }
    }
}
