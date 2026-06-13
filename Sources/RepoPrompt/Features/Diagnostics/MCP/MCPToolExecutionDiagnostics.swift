import Foundation
import RepoPromptShared

enum MCPToolExecutionHandlerPhase: String, Equatable {
    case manageSelectionAutoSelectionDrain = "manage_selection.auto_selection_drain"
    case manageSelectionIngressWait = "manage_selection.ingress_wait"
    case manageSelectionConstruction = "manage_selection.selection_construction"
    case manageSelectionPersistence = "manage_selection.persistence"
    case manageSelectionReplyConstruction = "manage_selection.reply_construction"
    case fileActionsPreMutationChecks = "file_actions.pre_mutation_checks"
    case fileActionsCatalogEligibility = "file_actions.catalog_eligibility"
    case fileActionsMutationIO = "file_actions.mutation_io"
    case fileActionsPostMutationCatalog = "file_actions.post_mutation_catalog"
    case fileActionsPostMutationSelection = "file_actions.post_mutation_selection"
    case fileActionsReplyConstruction = "file_actions.reply_construction"
}

enum MCPToolExecutionHandlerPhaseTransition: String, Equatable {
    case started
    case completed
}

struct MCPToolExecutionHandlerPhaseSnapshot: Equatable {
    let phase: MCPToolExecutionHandlerPhase
    let transition: MCPToolExecutionHandlerPhaseTransition
    let elapsedMilliseconds: Double
}

/// Per-invocation progress state. Providers use the task-local accessor while the
/// connection manager retains this recorder explicitly for watchdog escalation.
final class MCPToolExecutionHandlerPhaseRecorder: @unchecked Sendable {
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

    func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition
    ) async {
        let current = await now()
        store(MCPToolExecutionHandlerPhaseSnapshot(
            phase: phase,
            transition: transition,
            elapsedMilliseconds: max(0, current.mcpMilliseconds - origin.mcpMilliseconds)
        ))
    }

    func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot? {
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

enum MCPToolExecutionHandlerPhaseContext {
    @TaskLocal
    static var recorder: MCPToolExecutionHandlerPhaseRecorder?

    static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started
    ) async {
        guard let recorder else { return }
        await recorder.report(phase, transition: transition)
    }
}

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
    let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
    let handlerPhaseAgeMilliseconds: Double?

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
        if let handlerPhase {
            fields.append("handler_phase=\(handlerPhase.phase.rawValue)")
            fields.append("handler_phase_transition=\(handlerPhase.transition.rawValue)")
            fields.append("handler_phase_elapsed_ms=\(String(format: "%.3f", handlerPhase.elapsedMilliseconds))")
        }
        if let handlerPhaseAgeMilliseconds {
            fields.append("handler_phase_age_ms=\(String(format: "%.3f", handlerPhaseAgeMilliseconds))")
        }
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

extension Duration {
    var mcpSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var mcpMilliseconds: Double {
        mcpSeconds * 1000
    }
}
