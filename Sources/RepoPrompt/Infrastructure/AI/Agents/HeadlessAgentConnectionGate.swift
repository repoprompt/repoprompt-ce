import Foundation
import OSLog

/// Global gate to serialize headless agent connections and prevent racing.
/// This ensures that only one headless agent (discovery, delegate-edit, or future types)
/// installs its connection policy and spawns at a time, preventing MCP connection conflicts.
actor HeadlessAgentConnectionGate {
    static let shared = HeadlessAgentConnectionGate()

    private var activeConnectionID: UUID?
    private struct WaitingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waitingContinuations: [WaitingContinuation] = []

    private let log = Logger(subsystem: "com.repoprompt.agents", category: "ConnectionGate")

    /// Wait for any currently connecting agent to finish before proceeding
    func waitForClearConnection() async {
        if let currentConnectionID = activeConnectionID {
            log.info("Gate busy; waiting (current=\(currentConnectionID.uuidString))")
            let waiterID = UUID()
            await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        waitingContinuations.append(WaitingContinuation(id: waiterID, continuation: continuation))
                    }
                },
                onCancel: {
                    Task { await self.cancelWaitingContinuation(with: waiterID) }
                }
            )
        }
    }

    /// Note: Intentionally no logging here to avoid actor hop complexity during cancellation
    /// which can cause resource starvation/deadlock.
    private func cancelWaitingContinuation(with id: UUID) {
        if let index = waitingContinuations.firstIndex(where: { $0.id == id }) {
            let waiter = waitingContinuations.remove(at: index)
            waiter.continuation.resume()
        }
    }

    /// Atomically waits until the gate is free, then marks it owned by `gateID`.
    ///
    /// IMPORTANT: This method re-checks ownership after every suspension so that a resumed waiter
    /// cannot overwrite a gate acquisition by a task that arrived between resume and re-entry.
    /// Returns false if the task was cancelled before acquisition completed.
    func acquire(_ gateID: UUID) async -> Bool {
        while let currentConnectionID = activeConnectionID {
            log.info("Gate busy; waiting to acquire (gateID=\(gateID.uuidString), current=\(currentConnectionID.uuidString))")
            let waiterID = UUID()
            await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        waitingContinuations.append(WaitingContinuation(id: waiterID, continuation: continuation))
                    }
                },
                onCancel: {
                    Task { await self.cancelWaitingContinuation(with: waiterID) }
                }
            )
            if Task.isCancelled { return false }
        }
        if Task.isCancelled { return false }
        activeConnectionID = gateID
        log.info("Gate acquired atomically (gateID=\(gateID.uuidString))")
        return true
    }

    /// Mark an agent as beginning connection
    func beginConnection(_ gateID: UUID) {
        activeConnectionID = gateID
        log.info("Gate begin (gateID=\(gateID.uuidString))")
    }

    func completeConnectionReturningStatus(_ gateID: UUID) -> Bool {
        guard activeConnectionID == gateID else {
            let currentConnectionID = activeConnectionID?.uuidString ?? "nil"
            log.info("Gate release no-op (gateID=\(gateID.uuidString), current=\(currentConnectionID))")
            return false
        }
        activeConnectionID = nil
        log.info("Gate released (gateID=\(gateID.uuidString))")

        // Resume ONE waiting agent (FIFO)
        if !waitingContinuations.isEmpty {
            let next = waitingContinuations.removeFirst()
            log.info("Resuming waiting gate permit (id=\(next.id.uuidString))")
            next.continuation.resume()
        }
        return true
    }

    /// Signal that an agent connection completed, unblocking next agent.
    /// This is idempotent - only the first call with the matching agentID releases the gate.
    func completeConnection(_ gateID: UUID) {
        guard activeConnectionID == gateID else { return }
        _ = completeConnectionReturningStatus(gateID)
    }

    func completeIfActive(_ gateID: UUID) -> Bool {
        completeConnectionReturningStatus(gateID)
    }

    @discardableResult
    func withPermit<T>(
        for gateID: UUID,
        _ body: () async throws -> T,
        onBeforeRelease: (() async -> Void)? = nil
    ) async throws -> T {
        if activeConnectionID != nil {
            log.info("Gate awaiting clear (gateID=\(gateID.uuidString))")
        } else {
            log.info("Gate clear (gateID=\(gateID.uuidString))")
        }
        let acquired = await acquire(gateID)
        guard acquired else { throw CancellationError() }
        do {
            let value = try await body()
            if let cb = onBeforeRelease {
                await cb()
            }
            let released = completeConnectionReturningStatus(gateID)
            log.info("Gate released after success (gateID=\(gateID.uuidString), released=\(released))")
            return value
        } catch {
            if let cb = onBeforeRelease {
                await cb()
            }
            let released = completeConnectionReturningStatus(gateID)
            log.info("Gate released after error (gateID=\(gateID.uuidString), released=\(released))")
            throw error
        }
    }

    #if DEBUG
        func debugWaitingCount() -> Int {
            waitingContinuations.count
        }

        func debugActiveConnectionID() -> UUID? {
            activeConnectionID
        }
    #endif

    /// Cancel all waiting agents (e.g., on app shutdown)
    func cancelAll() {
        activeConnectionID = nil
        for continuation in waitingContinuations {
            continuation.continuation.resume()
        }
        waitingContinuations.removeAll()
    }
}

// MARK: - Static Convenience Methods

extension HeadlessAgentConnectionGate {
    /// Wait for any in-progress agent connection to complete before proceeding
    static func waitForClearConnection() async {
        await HeadlessAgentConnectionGate.shared.waitForClearConnection()
    }

    /// Signal that an agent began connecting
    static func beginConnection(_ gateID: UUID) async {
        await HeadlessAgentConnectionGate.shared.beginConnection(gateID)
    }

    /// Atomically waits for the gate to be free, then marks it owned.
    /// Returns false if cancelled before acquisition.
    static func acquire(_ gateID: UUID) async -> Bool {
        await HeadlessAgentConnectionGate.shared.acquire(gateID)
    }

    /// Signal that an agent connection completed
    static func completeConnection(_ gateID: UUID) async {
        await HeadlessAgentConnectionGate.shared.completeConnection(gateID)
    }

    /// Cancel all waiting agents
    static func cancelAll() async {
        await HeadlessAgentConnectionGate.shared.cancelAll()
    }

    static func completeIfActive(_ gateID: UUID) async -> Bool {
        await HeadlessAgentConnectionGate.shared.completeIfActive(gateID)
    }

    static func withPermit<T>(
        for gateID: UUID,
        _ body: () async throws -> T,
        onBeforeRelease: (() async -> Void)? = nil
    ) async throws -> T {
        try await HeadlessAgentConnectionGate.shared.withPermit(
            for: gateID,
            body,
            onBeforeRelease: onBeforeRelease
        )
    }
}
