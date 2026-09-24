import Foundation
import os
import RepoPromptDomainRuntime

/// Explicit app-only opt-in. Retained by the CB generation, never inferred from model/origin.
@MainActor
final class ContextBuilderOracleGroupSupervision {
    typealias Clock = @MainActor @Sendable () -> TimeInterval
    typealias Sleep = @MainActor @Sendable (TimeInterval) async throws -> Void

    nonisolated let cancellation = ContextBuilderOracleCancellation()
    let configuration: ContextBuilderFollowUpFinalizationConfiguration
    let clock: Clock
    let sleep: Sleep
    private var lanes: [ContextBuilderOracleLaneScope] = []

    init(
        configuration: ContextBuilderFollowUpFinalizationConfiguration = .production,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.sleep = sleep
    }

    func makeLane(sessionID: UUID) -> ContextBuilderOracleLaneScope {
        let lane = ContextBuilderOracleLaneScope(sessionID: sessionID, group: self)
        lanes.append(lane)
        return lane
    }

    nonisolated func cancel() {
        cancellation.request()
        Task { @MainActor in
            for lane in self.lanes {
                lane.checkDeadlines()
            }
        }
    }
}

/// Synchronous cancellation intent is observable even before its MainActor cleanup is scheduled.
struct ContextBuilderOracleCancellation {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isRequested: Bool {
        state.withLock { $0 }
    }

    func request() {
        state.withLock { $0 = true }
    }
}

/// Owns one lane from adapter entry through local drainage. All terminal decisions are
/// non-suspending on MainActor; neither provider-stop nor hub fulfilment is success admission.
@MainActor
final class ContextBuilderOracleLaneScope {
    enum Phase: String { case startup, streaming, finalization }
    private enum Terminal {
        case success
        case failure(Error)
    }

    let sessionID: UUID
    private(set) var queryID: UUID?
    private(set) var streamID: ChatStreamID?
    private(set) var phase = Phase.startup
    var partialResponse: String?
    var executionProfile: OracleExecutionProfile?
    private let configuration: ContextBuilderFollowUpFinalizationConfiguration
    private let clock: ContextBuilderOracleGroupSupervision.Clock
    private let sleep: ContextBuilderOracleGroupSupervision.Sleep
    private let groupCancellation: ContextBuilderOracleCancellation
    nonisolated let cancellation = ContextBuilderOracleCancellation()
    private let startedAt: TimeInterval
    private var lastActivityAt: TimeInterval
    private var providerStopped = false
    private var finalizationStarted = false
    private var terminal: Terminal?
    private var ownedTasks: [Task<Void, Never>] = []
    private var cancelOperation: (() -> Void)?
    private var releaseOwned: (() async -> Void)?
    private var releaseTask: Task<Void, Never>?
    private var drained = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    #if DEBUG
        var ownedTaskCountForTesting: Int {
            ownedTasks.count
        }

        var hasDrainedForTesting: Bool {
            drained
        }
    #endif

    func cancelAndDrain() async {
        cancellation.request()
        checkDeadlines()
        guard !drained else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    init(sessionID: UUID, group: ContextBuilderOracleGroupSupervision) {
        self.sessionID = sessionID
        configuration = group.configuration
        clock = group.clock
        sleep = group.sleep
        groupCancellation = group.cancellation
        startedAt = group.clock()
        lastActivityAt = startedAt
    }

    var terminalError: Error? {
        if case let .failure(error) = terminal { return error }
        return nil
    }

    var isLive: Bool {
        checkDeadlines()
        return terminal == nil
    }

    /// Check old deadlines before renewal, at the actual normalized-output observation time.
    /// Reporting is downstream and cannot renew this state or backdate terminal admission.
    @discardableResult
    func checkDeadlines(at observationTime: TimeInterval? = nil) -> Bool {
        guard terminal == nil else { return false }
        if cancellation.isRequested || groupCancellation.isRequested {
            latch(.failure(CancellationError()))
            return false
        }
        let now = observationTime ?? clock()
        let kind: ContextBuilderFollowUpTimeoutSnapshot.Kind? = if now - startedAt >= configuration.overallTimeout {
            .overall
        } else if now - lastActivityAt >= configuration.inactivityTimeout {
            .inactivity
        } else {
            nil
        }
        if let kind {
            let budget = kind == .overall ? configuration.overallTimeout : configuration.inactivityTimeout
            // Only configured local values and a closed phase enum; typed domain errors do not truncate.
            let message = "Context Builder Oracle exceeded its \(String(format: "%.0f", budget))s \(kind.rawValue) budget during \(phase.rawValue)."
            latch(.failure(OracleLaneFailure(code: "context_builder_\(kind.rawValue)_timeout", message: message)))
            return false
        }
        return true
    }

    func checkpoint() throws {
        guard checkDeadlines() else { throw terminalError ?? CancellationError() }
    }

    func bind(queryID: UUID) -> Bool {
        let now = clock()
        guard self.queryID == nil, checkDeadlines(at: now) else { return false }
        self.queryID = queryID
        phase = .streaming
        lastActivityAt = now
        return true
    }

    func bindStream(_ streamID: ChatStreamID) -> Bool {
        guard isLive else { return false }
        self.streamID = streamID
        return true
    }

    @discardableResult
    func observeActivity() -> Bool {
        let observedAt = clock()
        guard checkDeadlines(at: observedAt) else { return false }
        lastActivityAt = observedAt
        return true
    }

    func observeProviderStop() {
        let now = clock()
        guard !providerStopped, checkDeadlines(at: now) else { return }
        providerStopped = true
        phase = .finalization
        lastActivityAt = now
    }

    func observeFinalizationStart() {
        let now = clock()
        guard !finalizationStarted, checkDeadlines(at: now) else { return }
        finalizationStarted = true
        phase = .finalization
        lastActivityAt = now
    }

    func admitSuccess() throws {
        try checkpoint()
        latch(.success)
    }

    func admitFailure(_ error: Error) {
        guard checkDeadlines() else { return }
        latch(.failure(error))
    }

    func retain(_ task: Task<Void, Never>) {
        ownedTasks.append(task)
        if terminal != nil { task.cancel() }
    }

    private func latch(_ outcome: Terminal) {
        guard terminal == nil else { return }
        terminal = outcome // Revoke commit authority BEFORE cancellation or any cleanup await.
        if case .failure = outcome { cancelOperation?() }
        ownedTasks.forEach { $0.cancel() }
        if releaseTask == nil, let releaseOwned {
            releaseTask = Task { await releaseOwned() }
        }
    }

    func run(
        oracle: OracleViewModel,
        operation: @escaping @MainActor () async throws -> OracleLaneExecutionResponse
    ) async throws -> OracleLaneExecutionResponse {
        releaseOwned = { await oracle.releaseContextBuilderLane(self) }
        let work = Task { @MainActor in
            do {
                try self.checkpoint()
                let result = try await operation()
                // Normal success was admitted at the strict waiter boundary. This fallback also
                // makes this owner safe for a setup-only operation in deterministic tests.
                if self.terminal == nil { try self.admitSuccess() }
                return result
            } catch {
                self.admitFailure(error)
                throw error
            }
        }
        cancelOperation = { work.cancel() }
        let poll = Task { @MainActor in
            while self.terminal == nil {
                do { try await self.sleep(self.configuration.checkInterval) }
                catch {
                    if !Task.isCancelled { self.admitFailure(error) }
                    return
                }
                guard !Task.isCancelled else { return }
                self.checkDeadlines()
            }
        }
        let result = await withTaskCancellationHandler {
            if Task.isCancelled {
                cancellation.request()
                checkDeadlines()
            }
            return await work.result
        } onCancel: {
            self.cancellation.request()
            Task { @MainActor in self.checkDeadlines() }
        }
        poll.cancel()
        await releaseTask?.value // Exact stream + hub dependency release precedes producer/finalizer joins.
        await poll.value
        while !ownedTasks.isEmpty {
            let tasks = ownedTasks
            ownedTasks.removeAll()
            for task in tasks {
                await task.value
            }
        }
        releaseOwned = nil
        cancelOperation = nil
        releaseTask = nil
        drained = true
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let failure = terminalError as? OracleLaneFailure {
            throw OracleLaneFailure(
                code: failure.code, message: failure.message,
                partialResponse: failure.partialResponse ?? partialResponse,
                executionProfile: failure.executionProfile ?? executionProfile
            )
        }
        if terminalError is CancellationError {
            throw OracleLaneCancellation(partialResponse: partialResponse, executionProfile: executionProfile)
        }
        if let terminalError { throw terminalError }
        return try result.get()
    }
}
