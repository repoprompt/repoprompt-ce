import Foundation
import OSLog

struct MCPRoutingWaitClock {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static func continuous() -> MCPRoutingWaitClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return MCPRoutingWaitClock(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in
                try await clock.sleep(for: duration)
            }
        )
    }
}

enum MCPRoutingWaitFailure: Equatable {
    case signalled
    case cleanedUp
    case notRegistered
}

enum MCPRoutingWaitOutcome: Equatable {
    case routed
    case failed(MCPRoutingWaitFailure)
    case timedOutBeforeConnection
    case timedOutAfterConnection
    case cancelled

    var routed: Bool {
        self == .routed
    }
}

struct MCPRoutingWaitPolicy: Equatable {
    let noConnectionTimeout: Duration
    let observedConnectionGrace: Duration

    init(noConnectionTimeout: Duration, observedConnectionGrace: Duration) {
        self.noConnectionTimeout = noConnectionTimeout
        self.observedConnectionGrace = observedConnectionGrace
    }

    init(noConnectionTimeoutSeconds: TimeInterval, observedConnectionGraceSeconds: TimeInterval) {
        self.init(
            noConnectionTimeout: .milliseconds(Int64((noConnectionTimeoutSeconds * 1000).rounded())),
            observedConnectionGrace: .milliseconds(Int64((observedConnectionGraceSeconds * 1000).rounded()))
        )
    }
}

/// Coordinates run routing, matching-connection observation, deadlines, and cleanup.
///
/// All transitions are actor serialized. A matching connection only extends waiters that
/// explicitly selected an adaptive policy; the legacy Boolean APIs retain one absolute deadline.
actor MCPRoutingWaiter {
    static let shared = MCPRoutingWaiter()

    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "RoutingWaiter")
    private let clock: MCPRoutingWaitClock
    private let beforeWaiterEnrollment: (@Sendable () async -> Void)?

    /// The shared production waiter uses ``ContinuousClock``. Manual timing and enrollment gates
    /// are accepted only by explicitly constructed waiters used by deterministic tests.
    init(
        clock: MCPRoutingWaitClock = .continuous(),
        beforeWaiterEnrollment: (@Sendable () async -> Void)? = nil
    ) {
        self.clock = clock
        self.beforeWaiterEnrollment = beforeWaiterEnrollment
    }

    /// Terminal cache entries are bounded independently from routing-policy TTLs. Observation
    /// never refreshes this TTL, so late signals cannot retain run state without bound.
    private static let terminalStateTTL: Duration = .seconds(120)

    private enum DeadlinePhase {
        case absolute
        case beforeConnection
        case afterConnection
    }

    private struct WaitingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<MCPRoutingWaitOutcome, Never>
        let adaptiveGrace: Duration?
        var deadlineGeneration: UInt64
        var timeoutTask: Task<Void, Never>?
        let progressLifecycle: MCPBootstrapRoutingProgressLifecycle?
    }

    private struct ConnectionObservationContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct WaitState {
        var continuations: [WaitingContinuation] = []
        var connectionObservationContinuations: [ConnectionObservationContinuation] = []
        var expiryTask: Task<Void, Never>?
        var terminalOutcome: MCPRoutingWaitOutcome?
        var firstConnectionObservation: Duration?
    }

    private var waitersByRunID: [UUID: WaitState] = [:]

    // MARK: - Public API

    func register(runID: UUID) {
        if waitersByRunID[runID] == nil {
            waitersByRunID[runID] = WaitState()
            log.debug("register: runID=\(runID.uuidString)")
        }
    }

    func currentTerminalOutcome(runID: UUID) -> MCPRoutingWaitOutcome? {
        waitersByRunID[runID]?.terminalOutcome
    }

    /// Legacy compatibility API. Observation deliberately does not extend this absolute deadline.
    func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await waitForRoutingOutcome(runID: runID, timeoutSeconds: timeoutSeconds).routed
    }

    /// Legacy typed API with one absolute deadline. Observation is diagnostic only;
    /// nonpositive timeout values preserve the documented indefinite-wait behavior.
    func waitForRoutingOutcome(
        runID: UUID,
        timeoutSeconds: TimeInterval,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle? = nil
    ) async -> MCPRoutingWaitOutcome {
        let duration: Duration? = if timeoutSeconds > 0 {
            .milliseconds(Int64((timeoutSeconds * 1000).rounded()))
        } else {
            nil
        }
        return await waitForRoutingOutcome(
            runID: runID,
            initialTimeout: duration,
            adaptiveGrace: nil,
            initialPhase: .absolute,
            progressLifecycle: progressLifecycle
        )
    }

    /// Adaptive API. The first exact matching-connection observation replaces the absence
    /// deadline with one bounded grace deadline measured from that first observation.
    func waitForRoutingOutcome(
        runID: UUID,
        policy: MCPRoutingWaitPolicy,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle? = nil
    ) async -> MCPRoutingWaitOutcome {
        await waitForRoutingOutcome(
            runID: runID,
            initialTimeout: policy.noConnectionTimeout,
            adaptiveGrace: policy.observedConnectionGrace,
            initialPhase: .beforeConnection,
            progressLifecycle: progressLifecycle
        )
    }

    private func waitForRoutingOutcome(
        runID: UUID,
        initialTimeout: Duration?,
        adaptiveGrace: Duration?,
        initialPhase: DeadlinePhase,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle?
    ) async -> MCPRoutingWaitOutcome {
        if Task.isCancelled {
            await progressLifecycle?.fenceAfterWaitOutcome(.cancelled)
            return .cancelled
        }

        var didBackfillObservedConnection = false
        while let state = waitersByRunID[runID] {
            if let outcome = state.terminalOutcome {
                if state.firstConnectionObservation != nil {
                    await progressLifecycle?.recordChildConnectionObserved()
                }
                await progressLifecycle?.fenceAfterWaitOutcome(outcome)
                return outcome
            }
            guard state.firstConnectionObservation != nil, !didBackfillObservedConnection else { break }
            await progressLifecycle?.recordChildConnectionObserved()
            didBackfillObservedConnection = true
            if Task.isCancelled {
                await progressLifecycle?.fenceAfterWaitOutcome(.cancelled)
                return .cancelled
            }
        }
        guard waitersByRunID[runID] != nil else {
            await progressLifecycle?.fenceAfterWaitOutcome(.failed(.notRegistered))
            log.warning("waitForRoutingOutcome: unregistered runID \(runID.uuidString)")
            return .failed(.notRegistered)
        }

        let waiterID = UUID()
        await beforeWaiterEnrollment?()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPRoutingWaitOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard var current = waitersByRunID[runID] else {
                    continuation.resume(returning: .failed(.cleanedUp))
                    return
                }
                if let outcome = current.terminalOutcome {
                    continuation.resume(returning: outcome)
                    return
                }

                // Recompute from actor-current state at the exact enrollment boundary. Any
                // observation delivered while an earlier await was suspended must replace the
                // absence deadline with one grace window measured from the sticky first sighting.
                let firstObservation = current.firstConnectionObservation
                let deadline: Duration?
                let phase: DeadlinePhase
                if let adaptiveGrace, let firstObservation {
                    let elapsed = clock.now() - firstObservation
                    deadline = max(.zero, adaptiveGrace - elapsed)
                    phase = .afterConnection
                } else {
                    deadline = initialTimeout.map { max(.zero, $0) }
                    phase = initialPhase
                }

                let generation: UInt64 = 1
                let timeoutTask: Task<Void, Never>? = if let deadline {
                    scheduleDeadline(
                        runID: runID,
                        waiterID: waiterID,
                        generation: generation,
                        phase: phase,
                        after: deadline
                    )
                } else {
                    nil
                }
                current.continuations.append(
                    WaitingContinuation(
                        id: waiterID,
                        continuation: continuation,
                        adaptiveGrace: adaptiveGrace,
                        deadlineGeneration: generation,
                        timeoutTask: timeoutTask,
                        progressLifecycle: progressLifecycle
                    )
                )
                waitersByRunID[runID] = current
            }
        } onCancel: {
            Task { await self.handleCancellation(runID: runID, waiterID: waiterID) }
        }
        await progressLifecycle?.fenceAfterWaitOutcome(outcome)
        return outcome
    }

    func waitUntilConnectionObserved(runID: UUID) async -> Bool {
        guard let state = waitersByRunID[runID] else { return false }
        if state.firstConnectionObservation != nil { return true }
        if state.terminalOutcome != nil { return false }

        let observerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var current = waitersByRunID[runID] else {
                    continuation.resume(returning: false)
                    return
                }
                if current.firstConnectionObservation != nil {
                    continuation.resume(returning: true)
                } else if current.terminalOutcome != nil {
                    continuation.resume(returning: false)
                } else {
                    current.connectionObservationContinuations.append(
                        ConnectionObservationContinuation(id: observerID, continuation: continuation)
                    )
                    waitersByRunID[runID] = current
                }
            }
        } onCancel: {
            Task { await self.cancelConnectionObservation(runID: runID, observerID: observerID) }
        }
    }

    /// Records only the first exact run-owned policy match. Duplicate/replacement connections
    /// never restart grace, including after a recoverable route rollback.
    @discardableResult
    func notifyConnectionObserved(runID: UUID) async -> Bool {
        guard var state = waitersByRunID[runID],
              state.terminalOutcome == nil,
              state.firstConnectionObservation == nil
        else { return false }

        state.firstConnectionObservation = clock.now()
        let observers = state.connectionObservationContinuations
        state.connectionObservationContinuations = []
        let progressLifecycles = state.continuations.compactMap(\.progressLifecycle)

        for index in state.continuations.indices {
            guard let grace = state.continuations[index].adaptiveGrace else { continue }
            state.continuations[index].timeoutTask?.cancel()
            state.continuations[index].deadlineGeneration &+= 1
            let generation = state.continuations[index].deadlineGeneration
            let waiterID = state.continuations[index].id
            state.continuations[index].timeoutTask = scheduleDeadline(
                runID: runID,
                waiterID: waiterID,
                generation: generation,
                phase: .afterConnection,
                after: max(.zero, grace)
            )
        }
        waitersByRunID[runID] = state
        for progressLifecycle in progressLifecycles {
            await progressLifecycle.recordChildConnectionObserved()
        }
        observers.forEach { $0.continuation.resume(returning: true) }

        return true
    }

    func connectionWasObserved(runID: UUID) -> Bool {
        waitersByRunID[runID]?.firstConnectionObservation != nil
    }

    func notifyRouted(runID: UUID) async {
        guard await resolve(runID: runID, outcome: .routed) else { return }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "routing_waiter_signalled",
                fields: ["outcome": "routed"]
            )
        #endif
    }

    func notifyFailed(runID: UUID) async {
        guard await resolve(runID: runID, outcome: .failed(.signalled)) else { return }
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
    private func resolve(runID: UUID, outcome: MCPRoutingWaitOutcome) async -> Bool {
        guard var state = waitersByRunID[runID], state.terminalOutcome == nil else { return false }
        state.terminalOutcome = outcome
        state.expiryTask = scheduleExpiry(runID: runID)

        let continuations = state.continuations
        let observers = state.connectionObservationContinuations
        state.continuations = []
        state.connectionObservationContinuations = []
        waitersByRunID[runID] = state

        for waiter in continuations {
            if state.firstConnectionObservation != nil {
                await waiter.progressLifecycle?.recordChildConnectionObserved()
            }
            await waiter.progressLifecycle?.fenceAfterWaitOutcome(outcome)
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: outcome)
        }
        observers.forEach { $0.continuation.resume(returning: false) }
        return true
    }

    private func scheduleDeadline(
        runID: UUID,
        waiterID: UUID,
        generation: UInt64,
        phase: DeadlinePhase,
        after duration: Duration
    ) -> Task<Void, Never> {
        let sleep = clock.sleep
        return Task { [weak self] in
            do {
                try await sleep(duration)
                await self?.handleDeadline(
                    runID: runID,
                    waiterID: waiterID,
                    generation: generation,
                    phase: phase
                )
            } catch {
                // Replaced or cancelled deadline.
            }
        }
    }

    private func handleDeadline(
        runID: UUID,
        waiterID: UUID,
        generation: UInt64,
        phase: DeadlinePhase
    ) async {
        guard var state = waitersByRunID[runID], state.terminalOutcome == nil,
              let index = state.continuations.firstIndex(where: {
                  $0.id == waiterID && $0.deadlineGeneration == generation
              })
        else { return }

        let waiter = state.continuations.remove(at: index)
        waitersByRunID[runID] = state
        let outcome: MCPRoutingWaitOutcome = switch phase {
        case .afterConnection:
            .timedOutAfterConnection
        case .absolute:
            state.firstConnectionObservation == nil
                ? .timedOutBeforeConnection
                : .timedOutAfterConnection
        case .beforeConnection:
            .timedOutBeforeConnection
        }
        if state.firstConnectionObservation != nil {
            await waiter.progressLifecycle?.recordChildConnectionObserved()
        }
        await waiter.progressLifecycle?.fenceAfterWaitOutcome(outcome)
        waiter.continuation.resume(returning: outcome)
    }

    private func handleCancellation(runID: UUID, waiterID: UUID) async {
        guard var state = waitersByRunID[runID], state.terminalOutcome == nil,
              let index = state.continuations.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = state.continuations.remove(at: index)
        waitersByRunID[runID] = state
        await waiter.progressLifecycle?.fenceAfterWaitOutcome(.cancelled)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    private func cancelConnectionObservation(runID: UUID, observerID: UUID) {
        guard var state = waitersByRunID[runID],
              let index = state.connectionObservationContinuations.firstIndex(where: { $0.id == observerID })
        else { return }
        let observer = state.connectionObservationContinuations.remove(at: index)
        waitersByRunID[runID] = state
        observer.continuation.resume(returning: false)
    }

    private func scheduleExpiry(runID: UUID) -> Task<Void, Never> {
        let sleep = clock.sleep
        return Task { [weak self] in
            do {
                try await sleep(Self.terminalStateTTL)
                await self?.handleExpiry(runID: runID)
            } catch {
                // Explicit cleanup.
            }
        }
    }

    private func handleExpiry(runID: UUID) {
        guard let state = waitersByRunID[runID], state.terminalOutcome != nil else { return }
        waitersByRunID.removeValue(forKey: runID)
    }

    func cleanup(runID: UUID) {
        guard let state = waitersByRunID.removeValue(forKey: runID) else { return }
        state.expiryTask?.cancel()
        for waiter in state.continuations {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .failed(.cleanedUp))
        }
        for connectionObservationContinuation in state.connectionObservationContinuations {
            connectionObservationContinuation.continuation.resume(returning: false)
        }
    }

    #if DEBUG
        func debugContinuationCount(runID: UUID) -> Int {
            waitersByRunID[runID]?.continuations.count ?? 0
        }
    #endif
}

// MARK: - Static Async Methods

extension MCPRoutingWaiter {
    static func register(runID: UUID) async {
        await shared.register(runID: runID)
    }

    static func currentTerminalOutcome(runID: UUID) async -> MCPRoutingWaitOutcome? {
        await shared.currentTerminalOutcome(runID: runID)
    }

    static func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await shared.waitUntilRouted(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    static func waitForRoutingOutcome(
        runID: UUID,
        timeoutSeconds: TimeInterval,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle? = nil
    ) async -> MCPRoutingWaitOutcome {
        await shared.waitForRoutingOutcome(
            runID: runID,
            timeoutSeconds: timeoutSeconds,
            progressLifecycle: progressLifecycle
        )
    }

    static func waitForRoutingOutcome(
        runID: UUID,
        policy: MCPRoutingWaitPolicy,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle? = nil
    ) async -> MCPRoutingWaitOutcome {
        await shared.waitForRoutingOutcome(
            runID: runID,
            policy: policy,
            progressLifecycle: progressLifecycle
        )
    }

    static func waitUntilConnectionObserved(runID: UUID) async -> Bool {
        await shared.waitUntilConnectionObserved(runID: runID)
    }

    @discardableResult
    static func notifyConnectionObserved(runID: UUID) async -> Bool {
        await shared.notifyConnectionObserved(runID: runID)
    }

    static func connectionWasObserved(runID: UUID) async -> Bool {
        await shared.connectionWasObserved(runID: runID)
    }

    static func notifyRouted(runID: UUID) async {
        await shared.notifyRouted(runID: runID)
    }

    static func notifyFailed(runID: UUID) async {
        await shared.notifyFailed(runID: runID)
    }

    static func cleanup(runID: UUID) async {
        await shared.cleanup(runID: runID)
    }

    #if DEBUG
        static func debugContinuationCount(runID: UUID) async -> Int {
            await shared.debugContinuationCount(runID: runID)
        }
    #endif
}

// MARK: - Fire-and-Forget Signal Methods

extension MCPRoutingWaiter {
    nonisolated static func signalRouted(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyRouted(runID: runID)
        }
    }

    nonisolated static func signalFailed(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyFailed(runID: runID)
        }
    }
}
