import Foundation
import MCP
import RepoPromptDomainRuntime

/// App-owned tasks deliberately have no connection cancellation registration.
/// Feature execution still owns Oracle claims and drains lanes before returning.
@MainActor
final class MCPLongRunningJobCenter {
    typealias Owner = DomainLongRunningJobStore.Owner
    typealias Snapshot = DomainLongRunningJobStore.Snapshot
    typealias Body = @MainActor (MCPLongRunningJobProgress) async throws -> Value

    let store: DomainLongRunningJobStore
    private struct Worker {
        let owner: Owner
        let task: Task<Void, Never>
    }

    private struct Admission {
        let owner: Owner
        var cancelled = false
    }

    private var admitting: [UUID: Admission] = [:]
    private var workers: [UUID: Worker] = [:]
    #if DEBUG
        var admissionDidRegister: ((UUID) async -> Void)?
    #endif
    private var closingWindows: Set<Int> = []

    init(store: DomainLongRunningJobStore = DomainLongRunningJobStore()) {
        self.store = store
    }

    /// `admissible` runs synchronously immediately before admission is recorded, so an owner closed during
    /// awaited preparation is rejected here; one closed afterwards is seen by the owner's cancellation sweep.
    func start(tool: String, owner: Owner, admissible: () throws -> Void = {}, register: (UUID, @escaping () -> Void) -> Void = { _, _ in }, unregister: @escaping (UUID) -> Void = { _ in }, onNotStarted: @escaping @MainActor () -> Void = {}, body: @escaping Body) async throws -> Snapshot {
        let id = UUID()
        var handedOff = false
        var registered = false
        var cleanupPending = true
        func abandonPreparation() {
            guard cleanupPending else { return }
            cleanupPending = false
            onNotStarted()
        }
        defer {
            admitting.removeValue(forKey: id)
            if !handedOff {
                abandonPreparation()
                if registered { unregister(id) }
            }
        }
        guard !closingWindows.contains(owner.windowID) else { throw MCPError.invalidRequest("Window is closing") }
        try Task.checkCancellation()
        try admissible()
        // Registration can publish the ticket before this actor installs its worker.
        // Keep cancellation intent through that handoff, including owner teardown.
        admitting[id] = Admission(owner: owner)
        // Run cancellation must see admission too; connection cancellation intentionally does not.
        register(id) { [weak self] in self?.cancel(id: id) }
        registered = true
        let snapshot = try await store.register(id: id, tool: tool, owner: owner)
        #if DEBUG
            await admissionDidRegister?(id)
        #endif
        if admitting[id]?.cancelled == true {
            abandonPreparation()
            await store.finish(id: id, error: "Cancelled during admission", cancelled: true)
            return await store.snapshot(id: id) ?? snapshot
        }
        guard !closingWindows.contains(owner.windowID) else {
            abandonPreparation()
            await store.finish(id: id, error: "Window closed during admission", cancelled: true)
            throw MCPError.invalidRequest("Window is closing")
        }
        // No request-owned await between ownership commit and launching this unstructured task.
        let progress = MCPLongRunningJobProgress(id: id, store: store)
        let task = Task { [self] in
            var enteredBody = false
            do {
                try Task.checkCancellation()
                enteredBody = true
                let result = try await body(progress)
                await progress.settled(result)
                let fields = result.objectValue ?? [:]
                let oracleFields = fields["plan"]?.objectValue ?? fields["review"]?.objectValue ?? fields
                let lanes: [Value] = if case let .array(values)? = oracleFields["oracle_results"] { values } else { [] }
                // Settled lanes can be completed while cancellation aborts the remaining export.
                // Its retained error acknowledges cancellation without rewriting the canonical result.
                let cancelled = Task.isCancelled && (fields["oracle_export_error"] != nil || fields["status"]?.stringValue == "cancelled" || oracleFields["status"]?.stringValue == "cancelled" || lanes.contains(where: { $0.objectValue?["status"]?.stringValue == "cancelled" }))
                workers.removeValue(forKey: id)
                unregister(id)
                await store.finish(id: id, result: result, cancelled: cancelled)
            } catch {
                if !enteredBody { onNotStarted() }
                workers.removeValue(forKey: id)
                unregister(id)
                await store.finish(id: id, error: String(error.localizedDescription.prefix(2000)), cancelled: Task.isCancelled || error is CancellationError)
            }
        }
        handedOff = true
        workers[id] = Worker(owner: owner, task: task)
        return snapshot
    }

    func cancel(id: UUID) {
        if admitting[id] != nil { admitting[id]?.cancelled = true }
        guard let worker = workers[id] else { return }
        worker.task.cancel()
        Task { await store.cancelling(id: id) }
    }

    func cancel(where predicate: (Owner) -> Bool) {
        for (id, admission) in admitting where predicate(admission.owner) {
            cancel(id: id)
        }
        for (id, worker) in workers where predicate(worker.owner) {
            cancel(id: id)
        }
    }

    func close(windowID: Int) {
        closingWindows.insert(windowID)
        cancel { $0.windowID == windowID }
    }

    func control(operation: MCPLongRunningJobOperation, tool: String, authorize: (Owner) async throws -> Void) async throws -> Value {
        guard let id = operation.id else { throw MCPError.internalError("Expected job control operation") }
        guard let snapshot = await store.snapshot(id: id) else { return Self.expired(id: id) }
        guard snapshot.tool == tool else { throw MCPError.invalidParams("job_id belongs to a different tool") }
        try await authorize(snapshot.owner)
        switch operation {
        case .cancel:
            cancel(id: id)
            await store.cancelling(id: id)
        case let .wait(_, timeout):
            return await store.wait(id: id, timeout: timeout)?.value() ?? Self.expired(id: id)
        default:
            break
        }
        return await store.snapshot(id: id)?.value() ?? Self.expired(id: id)
    }

    static func expired(id: UUID) -> Value {
        .object([
            "job_id": .string(id.uuidString),
            "job": .object(["id": .string(id.uuidString), "status": .string("expired"), "message": .string("No live or retained job. Tickets expire after app restart or retention. Recover durable Oracle text using lane chat IDs from an earlier snapshot and oracle_chat_log; do not automatically repeat paid work.")])
        ])
    }
}

@MainActor
enum MCPLongRunningJobOperation {
    case blocking
    case start(detach: Bool, timeout: TimeInterval)
    case poll(UUID)
    case wait(UUID, TimeInterval)
    case cancel(UUID)

    var id: UUID? {
        switch self {
        case let .poll(id), let .wait(id, _), let .cancel(id): id
        default: nil
        }
    }

    static func parse(_ args: [String: Value]) throws -> Self {
        guard let raw = args["op"] else {
            guard args["job_id"] == nil, args["detach"] == nil, args["timeout"] == nil else { throw MCPError.invalidParams("job_id, detach, and timeout require op") }
            return .blocking
        }
        guard let op = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { throw MCPError.invalidParams("op must be start, poll, wait, or cancel") }
        let defaultWait = AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds()
        if op == "start" {
            guard args["job_id"] == nil else { throw MCPError.invalidParams("start does not accept job_id") }
            if let detach = args["detach"], detach.boolValue == nil { throw MCPError.invalidParams("detach must be boolean") }
            return try .start(detach: args["detach"]?.boolValue ?? false, timeout: AgentRunMCPToolService.resolvedStartTimeoutSeconds(args["timeout"], capturedDefaultWaitSeconds: defaultWait))
        }
        guard ["poll", "wait", "cancel"].contains(op) else { throw MCPError.invalidParams("op must be start, poll, wait, or cancel") }
        let allowed: Set = op == "wait" ? ["op", "job_id", "timeout"] : ["op", "job_id"]
        guard args.keys.allSatisfy({ $0.hasPrefix("_") || allowed.contains($0) }) else { throw MCPError.invalidParams("op=\(op) accepts only job_id\(op == "wait" ? " and timeout" : "")") }
        guard let rawID = args["job_id"]?.stringValue, let id = UUID(uuidString: rawID) else { throw MCPError.invalidParams("job_id must be a UUID from a start response") }
        switch op {
        case "poll": return .poll(id)
        case "cancel": return .cancel(id)
        default: return try .wait(id, AgentRunMCPToolService.resolvedWaitTimeoutSeconds(args["timeout"], capturedDefaultWaitSeconds: defaultWait))
        }
    }

    static func executionArgs(_ args: [String: Value]) -> [String: Value] {
        args.filter { !["op", "job_id", "detach", "timeout"].contains($0.key) }
    }
}

/// Structural progress only: streamed response bodies never enter the ticket snapshot.
@MainActor
final class MCPLongRunningJobProgress {
    let id: UUID
    let store: DomainLongRunningJobStore
    private var groupID: OracleGroupID?
    private var turnID: OracleTurnID?
    private var lanes: [[String: Value]] = []
    private var sequences: [Int: UInt64] = [:]

    init(id: UUID, store: DomainLongRunningJobStore) {
        self.id = id
        self.store = store
    }

    func phase(_ phase: String, stage: String) async {
        await store.update(id: id, fields: ["phase": .string(phase), "stage": .string(stage)])
    }

    func prepared(group: OracleGroupID, turn: OracleTurnID, members: [OracleGroupMember]) async {
        guard groupID != group || turnID != turn else { return }
        groupID = group
        turnID = turn
        sequences.removeAll()
        lanes = members.map { ["lane_index": .int($0.laneID.index), "label": .string(OracleRosterContract.displayLabel(laneIndex: $0.laneID.index)), "chat_id": .string($0.publicChatID), "model_id": .string($0.model.modelID), "status": .string("pending")] }
        await store.update(id: id, fields: ["oracle_group_id": .string(group.rawValue.uuidString), "oracle_lanes": .array(lanes.map(Value.object))])
    }

    func progress(_ event: OracleProgressEvent) async {
        guard event.groupID == groupID, event.turnID == turnID,
              let index = event.laneID?.index, let sequence = event.sequence,
              sequences[index].map({ sequence > $0 }) ?? true,
              let position = lanes.firstIndex(where: { $0["lane_index"]?.intValue == index }) else { return }
        sequences[index] = sequence
        guard !["settled", "completed", "failed", "cancelled", "timed_out"].contains(lanes[position]["status"]?.stringValue ?? "") else { return }
        switch event.kind {
        case .laneStarted: lanes[position]["status"] = .string("streaming")
        case .laneSettled:
            // Progress is provisional; only settled(_:) publishes canonical lane outcomes.
            lanes[position]["status"] = .string("settled")
        default: return
        }
        await store.update(id: id, fields: ["oracle_lanes": .array(lanes.map(Value.object))])
    }

    func settled(_ value: Value) async {
        guard let outer = value.objectValue else { return }
        let result = outer["plan"]?.objectValue ?? outer["review"]?.objectValue ?? outer
        var fields: [String: Value] = [:]
        if let chat = result["chat_id"] { fields["chat_id"] = chat }
        if let group = result["oracle_group_id"] { fields["oracle_group_id"] = group }
        if case let .array(results)? = result["oracle_results"] {
            fields["oracle_lanes"] = .array(results.map { lane in
                let object = lane.objectValue ?? [:]
                var projection = object.filter { ["lane_index", "label", "chat_id", "model_id", "status"].contains($0.key) }
                if let error = object["error"]?.objectValue {
                    projection["error_code"] = error["code"]
                    if OracleLaneError.indicatesTimeout(code: error["code"]?.stringValue, message: error["message"]?.stringValue) { projection["status"] = .string("timed_out") }
                }
                return .object(projection)
            })
        }
        await store.update(id: id, fields: fields)
    }
}
