import Foundation
import MCP

/// Runs immutable MCP reply projection work away from MainActor while preserving
/// explicit MainActor handoff diagnostics for the capture and resume segments.
enum MCPProviderProjectionWorker {
    private struct WorkerCompletion<Output: Sendable> {
        let output: Output
        let mainActorScheduledAt: UInt64
    }

    private struct WorkerProjectionError: Error, @unchecked Sendable {
        let underlying: any Error
        let mainActorScheduledAt: UInt64
    }

    @MainActor
    static func run<Output: Sendable>(
        toolName: String,
        phase: String,
        operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        let correlation = EditFlowPerf.currentLifecycleCorrelation
        let priority = Task.currentPriority

        #if DEBUG
            let captureScheduledAt = DispatchTime.now().uptimeNanoseconds
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: phase,
                    observerType: "provider_projection_capture"
                )
            )
            let captureEnteredAt = DispatchTime.now().uptimeNanoseconds
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: phase,
                    observerType: "provider_projection_capture",
                    queueDelayMicroseconds: elapsedMicroseconds(from: captureScheduledAt, to: captureEnteredAt)
                )
            )
        #endif

        #if DEBUG
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: phase,
                    observerType: "provider_projection_capture",
                    durationMicroseconds: elapsedMicroseconds(
                        from: captureEnteredAt,
                        to: DispatchTime.now().uptimeNanoseconds
                    )
                )
            )
        #endif

        let worker = Task.detached(priority: priority) {
            do {
                try Task.checkCancellation()
                let workerState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPProviderProjection.workerBody,
                    EditFlowPerf.Dimensions(toolName: toolName, outcome: phase)
                )
                defer {
                    EditFlowPerf.end(
                        EditFlowPerf.Stage.MCPProviderProjection.workerBody,
                        workerState,
                        EditFlowPerf.Dimensions(toolName: toolName, outcome: phase)
                    )
                }
                let output = try operation()
                try Task.checkCancellation()
                let scheduledAt = DispatchTime.now().uptimeNanoseconds
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: phase,
                        observerType: "provider_projection_resume"
                    )
                )
                return WorkerCompletion(output: output, mainActorScheduledAt: scheduledAt)
            } catch {
                let scheduledAt = DispatchTime.now().uptimeNanoseconds
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: "error",
                        observerType: "provider_projection_resume"
                    )
                )
                throw WorkerProjectionError(
                    underlying: error,
                    mainActorScheduledAt: scheduledAt
                )
            }
        }

        let completion: WorkerCompletion<Output>
        do {
            completion = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            let workerError = error as? WorkerProjectionError
            #if DEBUG
                let enteredAt = DispatchTime.now().uptimeNanoseconds
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: "error",
                        observerType: "provider_projection_resume",
                        queueDelayMicroseconds: elapsedMicroseconds(
                            from: workerError?.mainActorScheduledAt ?? enteredAt,
                            to: enteredAt
                        )
                    )
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: "error",
                        observerType: "provider_projection_resume",
                        durationMicroseconds: elapsedMicroseconds(
                            from: enteredAt,
                            to: DispatchTime.now().uptimeNanoseconds
                        )
                    )
                )
            #endif
            throw workerError?.underlying ?? error
        }

        #if DEBUG
            let resumeEnteredAt = DispatchTime.now().uptimeNanoseconds
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: phase,
                    observerType: "provider_projection_resume",
                    queueDelayMicroseconds: elapsedMicroseconds(
                        from: completion.mainActorScheduledAt,
                        to: resumeEnteredAt
                    )
                )
            )
            defer {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: phase,
                        observerType: "provider_projection_resume",
                        durationMicroseconds: elapsedMicroseconds(
                            from: resumeEnteredAt,
                            to: DispatchTime.now().uptimeNanoseconds
                        )
                    )
                )
            }
        #endif

        return completion.output
    }

    @MainActor
    static func encode(
        _ dto: some Codable & Sendable,
        toolName: String,
        phase: String = "value_encoding"
    ) async throws -> Value {
        try await run(toolName: toolName, phase: phase) {
            try Value(dto)
        }
    }

    #if DEBUG
        private nonisolated static func elapsedMicroseconds(from start: UInt64, to end: UInt64) -> Int {
            Int(end >= start ? (end - start) / 1000 : 0)
        }
    #endif
}
