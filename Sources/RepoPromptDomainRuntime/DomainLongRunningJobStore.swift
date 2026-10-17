import Foundation
import MCP

/// Transient execution handles. Durable Oracle conversations remain owned by their existing stores.
package actor DomainLongRunningJobStore {
    package struct Owner: Equatable {
        package let windowID: Int
        package let workspaceID: UUID?
        package let tabID: UUID
        package let sessionID: UUID?
        package let runID: UUID?

        package init(windowID: Int, workspaceID: UUID?, tabID: UUID, sessionID: UUID?, runID: UUID?) {
            self.windowID = windowID
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.sessionID = sessionID
            self.runID = runID
        }
    }

    package enum Status: String {
        case running, cancelling, completed, failed, cancelled
        package var isTerminal: Bool {
            self == .completed || self == .failed || self == .cancelled
        }
    }

    package struct Snapshot {
        package let id: UUID
        package let tool: String
        package let owner: Owner
        package var status: Status = .running
        package var startedAt: Date
        package var updatedAt: Date
        package var finishedAt: Date?
        package var revision: Int = 1
        package var progress: [String: Value] = [:]
        package var result: Value?
        package var error: String?

        package var isTerminal: Bool {
            status.isTerminal
        }

        package func value(now: Date = Date()) -> Value {
            var metadata = progress
            metadata.merge([
                "id": .string(id.uuidString), "kind": .string(tool), "status": .string(status.rawValue),
                "context_id": .string(owner.tabID.uuidString), "revision": .int(revision),
                "started_at": .string(ISO8601DateFormatter().string(from: startedAt)),
                "updated_at": .string(ISO8601DateFormatter().string(from: updatedAt)),
                "elapsed_seconds": .double((finishedAt ?? now).timeIntervalSince(startedAt))
            ]) { _, new in new }
            if let finishedAt { metadata["finished_at"] = .string(ISO8601DateFormatter().string(from: finishedAt)) }
            if let error { metadata["error"] = .object(["code": .string(status.rawValue), "message": .string(error)]) }
            var response = result?.objectValue ?? [:]
            response["job_id"] = .string(id.uuidString)
            response["job"] = .object(metadata)
            if !isTerminal {
                response["next_action"] = .string("Call \(tool) op=wait or poll with job_id=\(id.uuidString). Do not re-issue the execution request or continue its chats until terminal. Wait timeout does not cancel the job.")
            }
            return .object(response)
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Snapshot?, Never>
        let timer: Task<Void, Never>
    }

    private var records: [UUID: Snapshot] = [:]
    private var waiters: [UUID: [UUID: Waiter]] = [:]
    private let retention: TimeInterval
    private let maximumRetained: Int
    private let now: @Sendable () -> Date

    package init(retention: TimeInterval = 3600, maximumRetained: Int = 64, now: @escaping @Sendable () -> Date = Date.init) {
        self.retention = retention
        self.maximumRetained = maximumRetained
        self.now = now
    }

    /// Non-mutating preflight for feature control-token acquisition. Registration rechecks atomically.
    package func checkAdmission(owner: Owner) throws {
        prune()
        if let active = records.values.first(where: { !$0.isTerminal && $0.owner.windowID == owner.windowID && $0.owner.workspaceID == owner.workspaceID && $0.owner.tabID == owner.tabID }) {
            throw MCPError.invalidRequest("context_job_busy: job_id=\(active.id.uuidString), context_id=\(active.owner.tabID.uuidString), tool=\(active.tool). Poll, wait, or cancel the existing job; do not repeat paid work.")
        }
        guard records.values.count(where: { !$0.isTerminal }) < 16 else {
            throw MCPError.invalidRequest("Too many active long-running jobs; wait or cancel before starting another")
        }
    }

    package func register(id: UUID, tool: String, owner: Owner) throws -> Snapshot {
        try checkAdmission(owner: owner)
        let date = now()
        let snapshot = Snapshot(id: id, tool: tool, owner: owner, startedAt: date, updatedAt: date)
        records[id] = snapshot
        return snapshot
    }

    package func snapshot(id: UUID) -> Snapshot? {
        prune()
        return records[id]
    }

    package func update(id: UUID, fields: [String: Value]) {
        guard var record = records[id], !record.isTerminal else { return }
        record.progress.merge(fields) { _, new in new }
        record.updatedAt = now()
        record.revision += 1
        records[id] = record
    }

    package func cancelling(id: UUID) {
        guard var record = records[id], !record.isTerminal else { return }
        record.status = .cancelling
        record.updatedAt = now()
        record.revision += 1
        records[id] = record
    }

    package func finish(id: UUID, result: Value? = nil, error: String? = nil, cancelled: Bool = false) {
        guard var record = records[id], !record.isTerminal else { return }
        record.status = cancelled ? .cancelled : (error == nil ? .completed : .failed)
        record.result = result
        record.error = error
        record.finishedAt = now()
        record.updatedAt = record.finishedAt!
        record.revision += 1
        records[id] = record
        for waiter in waiters.removeValue(forKey: id)?.values ?? [UUID: Waiter]().values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: record)
        }
        prune()
    }

    /// The observer's cancellation only removes its continuation, never the worker.
    package func wait(id: UUID, timeout: TimeInterval) async -> Snapshot? {
        guard let snapshot = snapshot(id: id) else { return nil }
        guard !snapshot.isTerminal, timeout > 0, !Task.isCancelled else { return snapshot }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: records[id])
                    return
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    releaseWaiter(id: id, waiterID: waiterID)
                }
                waiters[id, default: [:]][waiterID] = Waiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.releaseWaiter(id: id, waiterID: waiterID) }
        }
    }

    private func releaseWaiter(id: UUID, waiterID: UUID) {
        guard let waiter = waiters[id]?.removeValue(forKey: waiterID) else { return }
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: records[id])
    }

    private func prune() {
        let terminal = records.values.filter(\.isTerminal).sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt! < $1.finishedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (index, snapshot) in terminal.enumerated()
            where now().timeIntervalSince(snapshot.finishedAt!) >= retention || index < terminal.count - maximumRetained
        {
            records.removeValue(forKey: snapshot.id)
        }
    }
}
