import Foundation
import OSLog

/// Global actor to coordinate "runID became routed" events between:
/// - Producers: `MCPServerViewModel.registerRunIDMapping` (success) and `cleanupRunIDMapping` (failure)
/// - Consumers: `AgentRunCoordinator.releaseGateWhenRouted`
///
/// This replaces the polling loop in `releaseGateWhenRouted` with an event-driven wait.
/// Follows the same continuation-based pattern as `HeadlessAgentConnectionGate`.
actor MCPRoutingWaiter {
    static let shared = MCPRoutingWaiter()

    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "RoutingWaiter")

    /// TTL for terminal state entries (prevents memory leaks from late signals)
    private static let terminalStateTTL: TimeInterval = 120 // 2 minutes

    /// State for each runID being waited on
    private struct WaitingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct WaitState {
        var continuations: [WaitingContinuation] = []
        var expiryTask: Task<Void, Never>? // TTL cleanup for terminal states
        var isTerminal: Bool = false // success or failure already signaled
        var didRoute: Bool = false // true if success, false if failure/timeout
    }

    private var waitersByRunID: [UUID: WaitState] = [:]

    // MARK: - Public API

    /// Register a runID before any routing signals are expected.
    /// Idempotent: calling multiple times is a no-op.
    func register(runID: UUID) {
        if waitersByRunID[runID] == nil {
            waitersByRunID[runID] = WaitState()
            log.debug("register: runID=\(runID.uuidString)")
        }
    }

    /// Wait until the runID is routed to a window/connection, or timeout/failure occurs.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time for this waiter to wait. If <= 0, waits indefinitely.
    ///     A timeout affects only this waiter; other waiters remain pending for the run-level signal.
    /// - Returns: `true` if routing succeeded, `false` on failure, cancellation, or this waiter's timeout.
    func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        // Fast path: already resolved
        if let state = waitersByRunID[runID], state.isTerminal {
            log.info("waitUntilRouted fast-path: runID=\(runID.uuidString) didRoute=\(state.didRoute)")
            return state.didRoute
        }

        // Safety check: runID must be registered before waiting.
        guard waitersByRunID[runID] != nil else {
            log.warning("waitUntilRouted: unregistered runID \(runID.uuidString) - returning false")
            return false
        }

        // Wait via continuation with per-waiter identity for targeted timeout/cancellation.
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Check again in case resolved while setting up
                if let state = waitersByRunID[runID], state.isTerminal {
                    continuation.resume(returning: state.didRoute)
                } else {
                    let timeoutTask: Task<Void, Never>? = if timeoutSeconds > 0 {
                        Task { [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(timeoutSeconds))
                                await self?.handleTimeout(runID: runID, waiterID: waiterID)
                            } catch {
                                // Task cancelled, no-op
                            }
                        }
                    } else {
                        nil
                    }
                    waitersByRunID[runID]?.continuations.append(
                        WaitingContinuation(
                            id: waiterID,
                            continuation: continuation,
                            timeoutTask: timeoutTask
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.handleCancellation(runID: runID, waiterID: waiterID) }
        }
    }

    /// Called when a runID is successfully bound to a connection/window.
    /// Resumes all waiters with `true`.
    func notifyRouted(runID: UUID) async {
        guard resolve(runID: runID, routed: true) else { return }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "routing_waiter_signalled",
                fields: ["outcome": "routed"]
            )
        #endif
    }

    /// Called when routing is known to be impossible (cleanup, cancellation, etc).
    /// Resumes all waiters with `false`.
    func notifyFailed(runID: UUID) async {
        guard resolve(runID: runID, routed: false) else { return }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "routing_waiter_signalled",
                fields: ["outcome": "failed"]
            )
        #endif
    }

    // MARK: - Internal

    @discardableResult
    private func resolve(runID: UUID, routed: Bool) -> Bool {
        guard var state = waitersByRunID[runID] else {
            log.warning("resolve: unregistered runID \(runID.uuidString) routed=\(routed) - ignoring")
            return false
        }

        // Already resolved - ignore duplicate
        if state.isTerminal {
            log.debug("resolve (already terminal): runID=\(runID.uuidString)")
            return false
        }

        // Mark as terminal
        state.isTerminal = true
        state.didRoute = routed

        // Schedule TTL cleanup for terminal state
        state.expiryTask = scheduleExpiry(runID: runID)

        // Resume all waiting continuations
        let continuations = state.continuations
        state.continuations = []

        // Update state before resuming to avoid races
        waitersByRunID[runID] = state

        log.info("resolve: runID=\(runID.uuidString) routed=\(routed) resumingCount=\(continuations.count)")

        for waiter in continuations {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: routed)
        }
        return true
    }

    /// Schedules automatic cleanup of terminal state after TTL expires
    private func scheduleExpiry(runID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.terminalStateTTL * 1_000_000_000))
                await self?.handleExpiry(runID: runID)
            } catch {
                // Task cancelled, no-op
            }
        }
    }

    /// Handles TTL expiry for terminal state entries
    private func handleExpiry(runID: UUID) {
        guard let state = waitersByRunID[runID], state.isTerminal else {
            return
        }
        waitersByRunID.removeValue(forKey: runID)
        log.debug("TTL expiry: removed terminal state for runID=\(runID.uuidString)")
    }

    /// Handles timeout of one waiter without terminally resolving the runID.
    private func handleTimeout(runID: UUID, waiterID: UUID) {
        guard var state = waitersByRunID[runID], !state.isTerminal else { return }
        guard let index = state.continuations.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.continuations.remove(at: index)
        waitersByRunID[runID] = state
        log.info("waiter timeout: runID=\(runID.uuidString) waiterID=\(waiterID.uuidString)")
        waiter.continuation.resume(returning: false)
    }

    /// Handles cancellation of a single waiter without resolving the entire runID.
    /// Removes only the specific cancelled waiter and resumes it with `false`.
    /// Other waiters for the same runID are unaffected.
    private func handleCancellation(runID: UUID, waiterID: UUID) {
        guard var state = waitersByRunID[runID], !state.isTerminal else { return }
        guard let index = state.continuations.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.continuations.remove(at: index)
        waitersByRunID[runID] = state
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: false)
    }

    /// Clean up state for a runID that is no longer needed.
    /// Call this after the run is fully complete to prevent memory leaks.
    /// Note: With TTL eviction, explicit cleanup is optional but recommended
    /// to free memory sooner when the run is known to be complete.
    func cleanup(runID: UUID) {
        guard let state = waitersByRunID.removeValue(forKey: runID) else { return }
        state.expiryTask?.cancel()
        for waiter in state.continuations {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: false)
        }
        log.debug("cleanup: runID=\(runID.uuidString) resumedCount=\(state.continuations.count)")
    }

    #if DEBUG
        func debugContinuationCount(runID: UUID) -> Int {
            waitersByRunID[runID]?.continuations.count ?? 0
        }
    #endif
}

// MARK: - Static Async Methods (for async callers)

extension MCPRoutingWaiter {
    /// Register a runID before any routing signals are expected.
    static func register(runID: UUID) async {
        await shared.register(runID: runID)
    }

    /// Wait until the runID is routed or timeout/failure.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time to wait. If <= 0, waits indefinitely.
    static func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await shared.waitUntilRouted(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    /// Notify that a runID was successfully routed (async version).
    static func notifyRouted(runID: UUID) async {
        await shared.notifyRouted(runID: runID)
    }

    /// Notify that a runID failed to route (async version).
    static func notifyFailed(runID: UUID) async {
        await shared.notifyFailed(runID: runID)
    }

    /// Clean up state for a completed runID.
    static func cleanup(runID: UUID) async {
        await shared.cleanup(runID: runID)
    }

    #if DEBUG
        static func debugContinuationCount(runID: UUID) async -> Int {
            await shared.debugContinuationCount(runID: runID)
        }
    #endif
}

// MARK: - Fire-and-Forget Signal Methods (for sync callers)

extension MCPRoutingWaiter {
    /// Fire-and-forget notification that runID was successfully routed.
    /// Safe to call from @MainActor or any synchronous context.
    /// Uses Task.detached so the notification survives parent task cancellation.
    nonisolated static func signalRouted(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyRouted(runID: runID)
        }
    }

    /// Fire-and-forget notification that routing failed or will never happen.
    /// Safe to call from @MainActor or any synchronous context.
    /// Uses Task.detached so the notification survives parent task cancellation.
    nonisolated static func signalFailed(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyFailed(runID: runID)
        }
    }
}
