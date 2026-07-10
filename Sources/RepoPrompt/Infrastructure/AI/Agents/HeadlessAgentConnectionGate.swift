import Foundation
import OSLog
import RepoPromptShared

/// Outcome of a bounded wait on the headless agent connection gate.
enum HeadlessAgentConnectionWaitOutcome {
    case resumed
    case timedOut
}

/// Acquiring the gate exceeded its deadline (see #419).
///
/// Deliberately distinct from `CancellationError` so a provisioning timeout is not
/// misclassified as an intentional cancel by `catch is CancellationError` branches
/// (e.g. the `agent_run` start path). Callers that fail fast on cancellation should
/// keep treating `CancellationError` as a cancel and surface this as a retryable error.
struct HeadlessAgentConnectionAcquireTimeoutError: Error, CustomStringConvertible, LocalizedError {
    private static let message = "Timed out waiting to acquire the headless agent connection gate. Another agent start may still be in progress; please retry."
    var description: String {
        Self.message
    }

    /// Surfaced via `error.localizedDescription` by callers that finalize the run as failed.
    var errorDescription: String? {
        Self.message
    }
}

/// Global gate to serialize headless agent connections and prevent racing.
/// This ensures that only one headless agent (discovery, delegate-edit, or future types)
/// installs its connection policy and spawns at a time, preventing MCP connection conflicts.
actor HeadlessAgentConnectionGate {
    static let shared = HeadlessAgentConnectionGate()

    struct Snapshot {
        let activeConnectionID: UUID?
        let queueDepth: Int
    }

    struct AcquisitionResult {
        let acquired: Bool
        let activeConnectionIDAtStart: UUID?
        let queueDepthAtStart: Int
        let queueDepthAtAcquire: Int
        let waitDurationMS: Double
        /// True when acquisition failed specifically because the deadline elapsed
        /// (vs. task cancellation), so callers can tell a provisioning timeout from
        /// an intentional cancel. See #419.
        let timedOut: Bool

        init(
            acquired: Bool,
            activeConnectionIDAtStart: UUID?,
            queueDepthAtStart: Int,
            queueDepthAtAcquire: Int,
            waitDurationMS: Double,
            timedOut: Bool = false
        ) {
            self.acquired = acquired
            self.activeConnectionIDAtStart = activeConnectionIDAtStart
            self.queueDepthAtStart = queueDepthAtStart
            self.queueDepthAtAcquire = queueDepthAtAcquire
            self.waitDurationMS = waitDurationMS
            self.timedOut = timedOut
        }
    }

    struct ReleaseResult {
        let released: Bool
        let activeConnectionIDBeforeRelease: UUID?
        let queueDepthBeforeRelease: Int
        let resumedWaiter: Bool
    }

    private var activeConnectionID: UUID?
    private struct WaitingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<HeadlessAgentConnectionWaitOutcome, Never>
    }

    private var waitingContinuations: [WaitingContinuation] = []
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]

    private let log = Logger(subsystem: "com.repoprompt.agents", category: "ConnectionGate")

    /// Wait for any currently connecting agent to finish before proceeding.
    ///
    /// - Note: This method and its static wrapper currently have no production
    ///   callers — production bootstraps route through `acquireWithDiagnostics`,
    ///   which atomically waits and acquires. This is most likely dead code,
    ///   retained for symmetry/future use. If you call it, wire it through the
    ///   same fail-fast contract as `acquireWithDiagnostics`. See #419.
    ///
    /// A bounded `deadline` keeps a stalled peer connection from blocking this
    /// wait indefinitely; on expiry the wait simply returns so the caller can
    /// proceed to acquire (which queues with its own deadline). See #419.
    func waitForClearConnection(
        deadline: Duration? = MCPTimeoutPolicy.headlessAgentConnectionAcquireDeadline
    ) async {
        guard let currentConnectionID = activeConnectionID else { return }
        log.info("Gate busy; waiting (current=\(currentConnectionID.uuidString))")
        let waiterID = UUID()
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<HeadlessAgentConnectionWaitOutcome, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: .resumed)
                        return
                    }
                    waitingContinuations.append(WaitingContinuation(id: waiterID, continuation: continuation))
                    if let deadline {
                        scheduleDeadline(for: waiterID, deadline: deadline)
                    }
                }
            },
            onCancel: {
                Task { await self.cancelWaitingContinuation(with: waiterID) }
            }
        )
    }

    /// Note: Intentionally no logging here to avoid actor hop complexity during cancellation
    /// which can cause resource starvation/deadlock.
    private func cancelWaitingContinuation(with id: UUID) {
        cancelDeadlineTask(for: id)
        if let index = waitingContinuations.firstIndex(where: { $0.id == id }) {
            let waiter = waitingContinuations.remove(at: index)
            waiter.continuation.resume(returning: .resumed)
        }
    }

    /// Schedule a deadline after which `waiterID` is resumed with `.timedOut`.
    private func scheduleDeadline(for waiterID: UUID, deadline: Duration) {
        deadlineTasks[waiterID] = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            await self?.timeoutWaiter(waiterID)
        }
    }

    private func timeoutWaiter(_ waiterID: UUID) {
        cancelDeadlineTask(for: waiterID)
        guard let index = waitingContinuations.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waitingContinuations.remove(at: index)
        log.info("Gate waiter timed out (id=\(waiterID.uuidString))")
        waiter.continuation.resume(returning: .timedOut)
    }

    private func cancelDeadlineTask(for waiterID: UUID) {
        deadlineTasks.removeValue(forKey: waiterID)?.cancel()
    }

    /// Atomically waits until the gate is free, then marks it owned by `gateID`.
    ///
    /// IMPORTANT: This method re-checks ownership after every suspension so that a resumed waiter
    /// cannot overwrite a gate acquisition by a task that arrived between resume and re-entry.
    /// Returns diagnostics used by the MCP bootstrap history/perf surfaces.
    func acquireWithDiagnostics(
        _ gateID: UUID,
        deadline: Duration? = MCPTimeoutPolicy.headlessAgentConnectionAcquireDeadline
    ) async -> AcquisitionResult {
        let startUptime = ProcessInfo.processInfo.systemUptime
        let activeConnectionIDAtStart = activeConnectionID
        let queueDepthAtStart = waitingContinuations.count

        while let currentConnectionID = activeConnectionID {
            log.info("Gate busy; waiting to acquire (gateID=\(gateID.uuidString), current=\(currentConnectionID.uuidString))")
            let waiterID = UUID()
            let outcome = await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<HeadlessAgentConnectionWaitOutcome, Never>) in
                        if Task.isCancelled {
                            continuation.resume(returning: .resumed)
                            return
                        }
                        waitingContinuations.append(WaitingContinuation(id: waiterID, continuation: continuation))
                        if let deadline {
                            scheduleDeadline(for: waiterID, deadline: deadline)
                        }
                    }
                },
                onCancel: {
                    Task { await self.cancelWaitingContinuation(with: waiterID) }
                }
            )
            cancelDeadlineTask(for: waiterID)
            if Task.isCancelled {
                return AcquisitionResult(
                    acquired: false,
                    activeConnectionIDAtStart: activeConnectionIDAtStart,
                    queueDepthAtStart: queueDepthAtStart,
                    queueDepthAtAcquire: waitingContinuations.count,
                    waitDurationMS: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
                )
            }
            if outcome == .timedOut {
                log.info("Gate acquire timed out before acquisition (gateID=\(gateID.uuidString))")
                return AcquisitionResult(
                    acquired: false,
                    activeConnectionIDAtStart: activeConnectionIDAtStart,
                    queueDepthAtStart: queueDepthAtStart,
                    queueDepthAtAcquire: waitingContinuations.count,
                    waitDurationMS: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000,
                    timedOut: true
                )
            }
        }
        if Task.isCancelled {
            return AcquisitionResult(
                acquired: false,
                activeConnectionIDAtStart: activeConnectionIDAtStart,
                queueDepthAtStart: queueDepthAtStart,
                queueDepthAtAcquire: waitingContinuations.count,
                waitDurationMS: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
            )
        }
        activeConnectionID = gateID
        log.info("Gate acquired atomically (gateID=\(gateID.uuidString))")
        return AcquisitionResult(
            acquired: true,
            activeConnectionIDAtStart: activeConnectionIDAtStart,
            queueDepthAtStart: queueDepthAtStart,
            queueDepthAtAcquire: waitingContinuations.count,
            waitDurationMS: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
    }

    func acquire(_ gateID: UUID) async -> Bool {
        await acquireWithDiagnostics(gateID).acquired
    }

    /// Mark an agent as beginning connection
    func beginConnection(_ gateID: UUID) {
        activeConnectionID = gateID
        log.info("Gate begin (gateID=\(gateID.uuidString))")
    }

    func completeConnectionReturningDiagnostics(_ gateID: UUID) -> ReleaseResult {
        let activeConnectionIDBeforeRelease = activeConnectionID
        let queueDepthBeforeRelease = waitingContinuations.count
        guard activeConnectionID == gateID else {
            let currentConnectionID = activeConnectionID?.uuidString ?? "nil"
            log.info("Gate release no-op (gateID=\(gateID.uuidString), current=\(currentConnectionID))")
            return ReleaseResult(
                released: false,
                activeConnectionIDBeforeRelease: activeConnectionIDBeforeRelease,
                queueDepthBeforeRelease: queueDepthBeforeRelease,
                resumedWaiter: false
            )
        }
        activeConnectionID = nil
        log.info("Gate released (gateID=\(gateID.uuidString))")

        // Resume ONE waiting agent (FIFO)
        let resumedWaiter: Bool
        if let next = waitingContinuations.first {
            cancelDeadlineTask(for: next.id)
            waitingContinuations.removeFirst()
            log.info("Resuming waiting gate permit (id=\(next.id.uuidString))")
            next.continuation.resume(returning: .resumed)
            resumedWaiter = true
        } else {
            resumedWaiter = false
        }
        return ReleaseResult(
            released: true,
            activeConnectionIDBeforeRelease: activeConnectionIDBeforeRelease,
            queueDepthBeforeRelease: queueDepthBeforeRelease,
            resumedWaiter: resumedWaiter
        )
    }

    func completeConnectionReturningStatus(_ gateID: UUID) -> Bool {
        completeConnectionReturningDiagnostics(gateID).released
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

    func completeIfActiveWithDiagnostics(_ gateID: UUID) -> ReleaseResult {
        completeConnectionReturningDiagnostics(gateID)
    }

    func snapshot() -> Snapshot {
        Snapshot(activeConnectionID: activeConnectionID, queueDepth: waitingContinuations.count)
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
        for waiter in waitingContinuations {
            cancelDeadlineTask(for: waiter.id)
            waiter.continuation.resume(returning: .resumed)
        }
        waitingContinuations.removeAll()
    }
}

// MARK: - Static Convenience Methods

extension HeadlessAgentConnectionGate {
    /// Wait for any in-progress agent connection to complete before proceeding.
    /// - Note: Most likely dead code — no production callers (see instance method).
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

    static func acquireWithDiagnostics(_ gateID: UUID) async -> AcquisitionResult {
        await HeadlessAgentConnectionGate.shared.acquireWithDiagnostics(gateID)
    }

    static func snapshot() async -> Snapshot {
        await HeadlessAgentConnectionGate.shared.snapshot()
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

    static func completeIfActiveWithDiagnostics(_ gateID: UUID) async -> ReleaseResult {
        await HeadlessAgentConnectionGate.shared.completeIfActiveWithDiagnostics(gateID)
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
