import Foundation
import RepoPromptShared

struct MCPReadFileAutoSelectionDiagnosticEvent: Equatable, CustomStringConvertible {
    enum Kind: String {
        case acceptedHighWaterAdvanced = "accepted_high_water_advanced"
        case drainHighWaterCaptured = "drain_high_water_captured"
        case waiterRegistered = "waiter_registered"
        case waiterResumed = "waiter_resumed"
        case workerStarted = "worker_started"
        case workerStopped = "worker_stopped"
    }

    enum Lane: String {
        case canonical
        case mirror
    }

    let kind: Kind
    let lane: Lane
    let windowID: Int
    let workspaceID: UUID?
    let tabID: UUID
    let routeScope: String?
    let bindingGeneration: UInt64?
    let target: UInt64?
    let previousAcceptedHighWater: UInt64?
    let acceptedHighWater: UInt64
    let completedHighWater: UInt64
    let waiterCount: Int
    let workerActive: Bool
    let pendingWork: Bool
    let waiterID: UUID?
    let workerID: UUID?
    let requiredMirrorTicket: UInt64?

    var description: String {
        var fields = [
            "event=\(kind.rawValue)",
            "lane=\(lane.rawValue)",
            "window_id=\(windowID)",
            "tab_id=\(tabID.uuidString)",
            "accepted_high_water=\(acceptedHighWater)",
            "completed_high_water=\(completedHighWater)",
            "waiter_count=\(waiterCount)",
            "worker_active=\(workerActive)",
            "pending_work=\(pendingWork)"
        ]
        if let workspaceID { fields.append("workspace_id=\(workspaceID.uuidString)") }
        if let routeScope { fields.append("route=\(routeScope)") }
        if let bindingGeneration { fields.append("binding_generation=\(bindingGeneration)") }
        if let target { fields.append("target=\(target)") }
        if let previousAcceptedHighWater { fields.append("previous_accepted_high_water=\(previousAcceptedHighWater)") }
        if let waiterID { fields.append("waiter_id=\(waiterID.uuidString)") }
        if let workerID { fields.append("worker_id=\(workerID.uuidString)") }
        if let requiredMirrorTicket { fields.append("required_mirror_ticket=\(requiredMirrorTicket)") }
        return fields.joined(separator: " ")
    }
}

/// Structured diagnostics for the read/search auto-selection coordinator. Events are
/// available to tests unconditionally and are written to stderr only when MCP execution
/// or auto-selection tracing is enabled.
enum MCPReadFileAutoSelectionDiagnosticTracer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var testSink: (@Sendable (MCPReadFileAutoSelectionDiagnosticEvent) -> Void)?
    }

    private static let state = State()

    private static var tracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_MCP_AUTO_SELECTION_TRACE"] == "1"
                || MCPToolExecutionTracer.successTracingEnabled
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
        let sink: (@Sendable (MCPReadFileAutoSelectionDiagnosticEvent) -> Void)?
        state.lock.lock()
        sink = state.testSink
        state.lock.unlock()
        sink?(event)

        guard tracingEnabled else { return }
        guard let data = "[MCPAutoSelection] \(event)\n".data(using: .utf8) else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        BestEffortStderrWriter.write(data)
    }

    #if DEBUG
        static func setTestSink(_ sink: (@Sendable (MCPReadFileAutoSelectionDiagnosticEvent) -> Void)?) {
            state.lock.lock()
            state.testSink = sink
            state.lock.unlock()
        }
    #endif
}
