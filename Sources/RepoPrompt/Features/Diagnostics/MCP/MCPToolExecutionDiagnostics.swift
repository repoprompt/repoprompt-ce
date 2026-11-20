import Foundation
import RepoPromptInstrumentation
import RepoPromptMCPServer
import RepoPromptShared

struct AppMCPToolExecutionHandlerPhaseRecorderFactory: MCPToolExecutionHandlerPhaseRecorderFactory {
    func make(
        origin: Duration,
        now: @escaping @Sendable () async -> Duration
    ) -> any MCPToolExecutionHandlerPhaseRecording {
        MCPToolExecutionHandlerPhaseRecorder(origin: origin, now: now)
    }
}

/// Per-invocation progress state. Providers use the task-local accessor while the
/// connection manager retains this recorder explicitly for watchdog escalation.
final class MCPToolExecutionHandlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let origin: Duration
    private let now: @Sendable () async -> Duration
    private var latest: MCPToolExecutionHandlerPhaseSnapshot?

    init(
        origin: Duration,
        now: @escaping @Sendable () async -> Duration
    ) {
        self.origin = origin
        self.now = now
    }

    @discardableResult
    package func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition
    ) async -> MCPToolExecutionHandlerPhaseSnapshot {
        let current = await now()
        let snapshot = MCPToolExecutionHandlerPhaseSnapshot(
            phase: phase,
            transition: transition,
            elapsedMilliseconds: max(0, current.mcpMilliseconds - origin.mcpMilliseconds)
        )
        store(snapshot)
        return snapshot
    }

    package func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func store(_ snapshot: MCPToolExecutionHandlerPhaseSnapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }
}

enum MCPToolExecutionTracer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var testSink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
    }

    private static let state = State()

    static var successTracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_MCP_EXECUTION_TRACE"] == "1"
                || UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: MCPToolExecutionTraceEvent) {
        // Release-safe concurrency evidence ingestion (counts and bounded latency
        // aggregates only; see MCPToolConcurrencyEvidenceRecorder).
        MCPToolConcurrencyEvidenceRecorder.shared.recordExecutionTraceEvent(event)
        let sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
        state.lock.lock()
        sink = state.testSink
        state.lock.unlock()
        sink?(event)

        guard event.isAlwaysEmitted || successTracingEnabled else { return }
        guard let data = "[MCPToolExecution] \(event)\n".data(using: .utf8) else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        // Best-effort raw write; FileHandle.write raises an uncatchable ObjC
        // exception if stderr's pipe is already closed.
        BestEffortStderrWriter.write(data)
    }

    #if DEBUG
        static func setTestSink(_ sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?) {
            state.lock.lock()
            state.testSink = sink
            state.lock.unlock()
        }
    #endif
}

/// App-owned implementation of the extracted lifecycle event contract.
struct AppMCPToolExecutionEventSink: MCPToolExecutionEventSink {
    func record(_ event: MCPToolExecutionDiagnosticEvent) {
        let contractKind: MCPToolExecutionContract.Kind = switch event.contractKind {
        case .bounded: .bounded
        case .longSynchronousCancellable: .longSynchronousCancellable
        case .lifecycleManagedCancellable: .lifecycleManagedCancellable
        case .interactiveCancellable: .interactiveCancellable
        case .workspaceLifecycleCancellable: .workspaceLifecycleCancellable
        }
        let cleanupDisposition: MCPToolExecutionCleanupDisposition? = switch event.cleanupDisposition {
        case .forceDisconnect: .forceDisconnect
        case .detachAndSettle: .detachAndSettle
        case nil: nil
        }
        let cancellationOrigin: MCPToolExecutionCancellationOrigin? = switch event.cancellationOrigin {
        case .watchdogDeadline: .watchdogDeadline
        case .requestCancellation: .requestCancellation
        case .clientDeadline: .clientDeadline
        case .serverExportEnvelope: .serverExportEnvelope
        case nil: nil
        }
        MCPToolExecutionTracer.emit(MCPToolExecutionTraceEvent(
            toolName: event.toolName,
            operationIdentity: MCPDomainToolOperationIdentity(
                canonicalTool: event.canonicalTool,
                normalizedOperation: event.normalizedOperation
            ),
            connectionID: event.connectionID,
            invocationID: event.invocationID,
            runID: event.runID,
            requestIdentity: event.requestIdentity,
            contractKind: contractKind,
            executionDeadlineSeconds: event.executionDeadlineSeconds,
            cleanupGraceSeconds: event.cleanupGraceSeconds,
            cleanupDisposition: cleanupDisposition,
            phase: event.phase,
            elapsedMilliseconds: event.elapsedMilliseconds,
            cancellationRequested: event.cancellationRequested,
            cancellationOutcome: event.cancellationOutcome?.rawValue,
            cancellationOrigin: cancellationOrigin,
            settlement: event.settlement?.rawValue,
            graceOutcome: event.graceOutcome?.rawValue,
            escalationReason: event.escalationReason?.rawValue,
            handlerPhase: event.handlerPhase,
            handlerPhaseAgeMilliseconds: event.handlerPhaseAgeMilliseconds
        ))
    }
}
