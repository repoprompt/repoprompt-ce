import Foundation
import RepoPromptShared

struct MCPToolExecutionTraceEvent: Equatable, CustomStringConvertible {
    enum Phase: String {
        case contractSelected = "execution_contract_selected"
        case started = "execution_started"
        case handlerCompleted = "execution_handler_completed"
        case deadlineExpired = "execution_deadline_expired"
        case cancellationRequested = "execution_cancellation_requested"
        case settledDuringGrace = "execution_settled_during_grace"
        case cleanupGraceExpired = "execution_cleanup_grace_expired"
        case connectionForceDisconnectRequested = "connection_force_disconnect_requested"
    }

    let toolName: String
    let connectionID: UUID
    let invocationID: UUID
    let runID: UUID?
    let contractKind: MCPToolExecutionContract.Kind
    let executionDeadlineSeconds: Double?
    let cleanupGraceSeconds: Double?
    let phase: Phase
    let elapsedMilliseconds: Double
    let cancellationRequested: Bool?
    let cancellationOutcome: String?
    let graceOutcome: String?
    let escalationReason: String?

    var isAlwaysEmitted: Bool {
        switch phase {
        case .deadlineExpired, .cancellationRequested, .settledDuringGrace,
             .cleanupGraceExpired, .connectionForceDisconnectRequested:
            true
        case .contractSelected, .started, .handlerCompleted:
            false
        }
    }

    var description: String {
        var fields = [
            "phase=\(phase.rawValue)",
            "tool=\(toolName)",
            "connection_id=\(connectionID.uuidString)",
            "invocation_id=\(invocationID.uuidString)",
            "contract=\(contractKind.rawValue)",
            "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        ]
        if let runID { fields.append("run_id=\(runID.uuidString)") }
        if let executionDeadlineSeconds { fields.append("deadline_s=\(executionDeadlineSeconds)") }
        if let cleanupGraceSeconds { fields.append("grace_s=\(cleanupGraceSeconds)") }
        if let cancellationRequested { fields.append("cancellation_requested=\(cancellationRequested)") }
        if let cancellationOutcome { fields.append("cancellation_outcome=\(cancellationOutcome)") }
        if let graceOutcome { fields.append("grace_outcome=\(graceOutcome)") }
        if let escalationReason { fields.append("escalation_reason=\(escalationReason)") }
        return fields.joined(separator: " ")
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
        let sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
        state.lock.lock()
        sink = state.testSink
        state.lock.unlock()
        sink?(event)

        guard event.isAlwaysEmitted || successTracingEnabled else { return }
        let data = Data("[MCPToolExecution] \(event)\n".utf8)
        MCPBestEffortRawFDWriter.write(data)
    }

    #if DEBUG
        static func setTestSink(_ sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?) {
            state.lock.lock()
            state.testSink = sink
            state.lock.unlock()
        }
    #endif
}

extension Duration {
    var mcpSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var mcpMilliseconds: Double {
        mcpSeconds * 1000
    }
}
