import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO

enum SQLiteOperationClass: String, CaseIterable, Sendable {
    case control
    case interactive
    case bulk
}

struct SQLiteDatabaseExecutorMetrics: Sendable, Equatable {
    let capacity: Int
    let reservedControlCapacity: Int
    let maximumAdmissionWaiters: Int
    let queuedByClass: [SQLiteOperationClass: Int]
    let waitingByClass: [SQLiteOperationClass: Int]
    let maximumQueuedDepthObserved: Int
    let maximumWaitingDepthObserved: Int
    let maximumProducerEncodedBytes: Int
    let queuedEncodedBytes: Int
    let waitingEncodedBytes: Int
    let activeTransactionEncodedBytes: Int
    let activeJobEncodedBytes: Int
    let maximumProducerEncodedBytesObserved: Int
    let saturationCount: Int
    let completedByClass: [SQLiteOperationClass: Int]
    let totalWaitNanosecondsByClass: [SQLiteOperationClass: UInt64]
    let totalExecuteNanosecondsByClass: [SQLiteOperationClass: UInt64]
}

enum SQLiteExecutionContext {
    @TaskLocal static var transactionID: UUID?
    @TaskLocal static var operationClass: SQLiteOperationClass?
}

/// The sole owner of a SQLite connection.
///
/// All statements are admitted to one bounded scheduler and executed by one
/// worker. Transaction-affine statements are the only work eligible between
/// BEGIN and COMMIT/ROLLBACK, so actor reentrancy cannot expose a partially
/// applied transaction to unrelated reads.
actor SQLiteDatabaseExecutor {
    static let defaultCapacity = 256
    static let defaultReservedControlCapacity = 32
    static let defaultMaximumAdmissionWaiters = 256
    static let maximumBulkRows = 256
    static let maximumBulkEncodedBytes = 1_048_576
    static let defaultMaximumProducerEncodedBytes = 32 * 1_048_576

    private enum Work: Sendable {
        case query(String, [SQLiteData])
        case begin
        case commit
        case rollback

        var beginsTransaction: Bool {
            if case .begin = self { return true }
            return false
        }
    }

    private struct Job {
        let id: UUID
        let sequence: UInt64
        let operationClass: SQLiteOperationClass
        let transactionID: UUID?
        let work: Work
        let encodedBytes: Int
        let enqueuedAtNanoseconds: UInt64
        let continuation: CheckedContinuation<[SQLiteRow], Error>
    }

    private struct AdmissionWaiter {
        let id: UUID
        let sequence: UInt64
        let operationClass: SQLiteOperationClass
        let transactionID: UUID?
        let encodedBytes: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let connection: SQLiteConnection
    private let capacity: Int
    private let reservedControlCapacity: Int
    private let maximumAdmissionWaiters: Int
    private let maximumProducerEncodedBytes: Int
    private var queues: [SQLiteOperationClass: [Job]] = [
        .control: [],
        .interactive: [],
        .bulk: [],
    ]
    private var admissionWaiters: [SQLiteOperationClass: [AdmissionWaiter]] = [
        .control: [],
        .interactive: [],
        .bulk: [],
    ]
    /// Actor-owned grants keep a resumed waiter's slot and byte budget reserved
    /// until that exact producer atomically transfers the grant into a job.
    private var admissionGrants: [UUID: AdmissionWaiter] = [:]
    private var grantedEncodedBytes = 0
    private var activeTransactionID: UUID?
    private var activeTransactionEncodedBytes = 0
    private var activeJobEncodedBytes = 0
    private var failedClosed = false
    private var nextSequence: UInt64 = 1
    private var workerRunning = false
    private var closed = false
    private var saturationCount = 0
    private var maximumQueuedDepthObserved = 0
    private var maximumWaitingDepthObserved = 0
    private var queuedEncodedBytes = 0
    private var waitingEncodedBytes = 0
    private var maximumProducerEncodedBytesObserved = 0
    private var completedByClass: [SQLiteOperationClass: Int] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var totalWaitNanosecondsByClass: [SQLiteOperationClass: UInt64] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var totalExecuteNanosecondsByClass: [SQLiteOperationClass: UInt64] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var bypasses: [SQLiteOperationClass: Int] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private let weightedCycle: [SQLiteOperationClass] = [
        .control, .control, .control, .control,
        .interactive, .interactive,
        .bulk,
    ]
    private var cycleIndex = 0
    private var testCompletionObserver: (@Sendable (SQLiteOperationClass) -> Void)?
    private var workerSuspendedForTesting = false
    private var admissionGrantTransferSuspendedForTesting = false
    private var testGrantTransferContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var executionSuspendedForTesting = false
    private var testExecutionContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init(
        connection: SQLiteConnection,
        capacity: Int,
        reservedControlCapacity: Int,
        maximumAdmissionWaiters: Int,
        maximumProducerEncodedBytes: Int
    ) {
        self.connection = connection
        self.capacity = capacity
        self.reservedControlCapacity = reservedControlCapacity
        self.maximumAdmissionWaiters = maximumAdmissionWaiters
        self.maximumProducerEncodedBytes = maximumProducerEncodedBytes
    }

    static func open(
        storage: SQLiteConnection.Storage,
        capacity: Int = defaultCapacity,
        reservedControlCapacity: Int = defaultReservedControlCapacity,
        maximumAdmissionWaiters: Int = defaultMaximumAdmissionWaiters,
        maximumProducerEncodedBytes: Int = defaultMaximumProducerEncodedBytes
    ) async throws -> SQLiteDatabaseExecutor {
        guard capacity > 0,
              reservedControlCapacity >= 16,
              reservedControlCapacity < capacity,
              maximumAdmissionWaiters >= reservedControlCapacity,
              maximumProducerEncodedBytes >= maximumBulkEncodedBytes
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Invalid SQLite executor capacity configuration"
            )
        }
        let connection = try await SQLiteConnection.open(storage: storage)
        return SQLiteDatabaseExecutor(
            connection: connection,
            capacity: capacity,
            reservedControlCapacity: reservedControlCapacity,
            maximumAdmissionWaiters: maximumAdmissionWaiters,
            maximumProducerEncodedBytes: maximumProducerEncodedBytes
        )
    }

    /// Package-internal SQL seam. Production callers outside the persistence
    /// module can submit only typed `SQLiteServiceStore` operations.
    func query(
        _ sql: String,
        _ bindings: [SQLiteData] = [],
        operationClass: SQLiteOperationClass? = nil,
        estimatedEncodedBytes: Int = 0
    ) async throws -> [SQLiteRow] {
        let resolvedClass = operationClass ?? SQLiteExecutionContext.operationClass ?? .interactive
        let accountedBytes = max(
            estimatedEncodedBytes,
            sql.utf8.count + bindings.reduce(0) { $0 + Self.retainedBytes(for: $1) }
        )
        return try await submit(
            .query(sql, bindings),
            operationClass: resolvedClass,
            transactionID: SQLiteExecutionContext.transactionID,
            encodedBytes: accountedBytes
        )
    }

    private static func retainedBytes(for value: SQLiteData) -> Int {
        switch value {
        case .integer, .float:
            MemoryLayout<UInt64>.size
        case let .text(value):
            value.utf8.count
        case let .blob(value):
            value.readableBytes
        case .null:
            0
        }
    }

    func beginTransaction(
        _ transactionID: UUID,
        operationClass: SQLiteOperationClass = .control,
        estimatedEncodedBytes: Int = 0
    ) async throws {
        _ = try await submit(
            .begin,
            operationClass: operationClass,
            transactionID: transactionID,
            encodedBytes: estimatedEncodedBytes
        )
    }

    func commitTransaction(_ transactionID: UUID) async throws {
        _ = try await submit(.commit, operationClass: .control, transactionID: transactionID, encodedBytes: 0)
    }

    func rollbackTransaction(_ transactionID: UUID) async throws {
        _ = try await submitUncancelled(
            .rollback,
            operationClass: .control,
            transactionID: transactionID,
            encodedBytes: 0
        )
    }

    func metrics() -> SQLiteDatabaseExecutorMetrics {
        SQLiteDatabaseExecutorMetrics(
            capacity: capacity,
            reservedControlCapacity: reservedControlCapacity,
            maximumAdmissionWaiters: maximumAdmissionWaiters,
            queuedByClass: Dictionary(uniqueKeysWithValues: SQLiteOperationClass.allCases.map {
                ($0, queues[$0, default: []].count)
            }),
            waitingByClass: Dictionary(uniqueKeysWithValues: SQLiteOperationClass.allCases.map { operationClass in
                let granted = admissionGrants.values.count(where: { $0.operationClass == operationClass })
                return (operationClass, admissionWaiters[operationClass, default: []].count + granted)
            }),
            maximumQueuedDepthObserved: maximumQueuedDepthObserved,
            maximumWaitingDepthObserved: maximumWaitingDepthObserved,
            maximumProducerEncodedBytes: maximumProducerEncodedBytes,
            queuedEncodedBytes: queuedEncodedBytes,
            waitingEncodedBytes: waitingEncodedBytes,
            activeTransactionEncodedBytes: activeTransactionEncodedBytes,
            activeJobEncodedBytes: activeJobEncodedBytes,
            maximumProducerEncodedBytesObserved: maximumProducerEncodedBytesObserved,
            saturationCount: saturationCount,
            completedByClass: completedByClass,
            totalWaitNanosecondsByClass: totalWaitNanosecondsByClass,
            totalExecuteNanosecondsByClass: totalExecuteNanosecondsByClass
        )
    }

    func installTestCompletionObserver(
        _ observer: @escaping @Sendable (SQLiteOperationClass) -> Void
    ) {
        testCompletionObserver = observer
    }

    func suspendWorkerForTesting() {
        workerSuspendedForTesting = true
    }

    func resumeWorkerForTesting() {
        workerSuspendedForTesting = false
        startWorkerIfNeeded()
    }

    func suspendAdmissionGrantTransferForTesting() {
        admissionGrantTransferSuspendedForTesting = true
    }

    func admissionGrantCountForTesting() -> Int {
        admissionGrants.count
    }

    func resumeAdmissionGrantTransferForTesting() {
        admissionGrantTransferSuspendedForTesting = false
        let continuations = testGrantTransferContinuations.values
        testGrantTransferContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func suspendExecutionForTesting() {
        executionSuspendedForTesting = true
    }

    func resumeExecutionForTesting() {
        executionSuspendedForTesting = false
        let continuations = testExecutionContinuations.values
        testExecutionContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func close() async throws {
        guard !closed else { return }
        if failedClosed {
            closed = true
            try await connection.close()
            activeTransactionID = nil
            activeTransactionEncodedBytes = 0
            activeJobEncodedBytes = 0
            return
        }
        guard activeTransactionID == nil,
              activeJobEncodedBytes == 0,
              queuedCount == 0,
              waitingCount == 0
        else {
            throw ServiceAPIError(
                code: .persistenceUnavailable,
                message: "Cannot close SQLite while work is active",
                retryable: true
            )
        }
        closed = true
        try await connection.close()
    }

    private var queuedCount: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }

    private var nonControlQueuedCount: Int {
        queues[.interactive, default: []].count + queues[.bulk, default: []].count
    }

    private var waitingCount: Int {
        admissionWaiters.values.reduce(0) { $0 + $1.count } + admissionGrants.count
    }

    private var nonControlWaitingCount: Int {
        admissionWaiters[.interactive, default: []].count
            + admissionWaiters[.bulk, default: []].count
            + admissionGrants.values.count(where: { $0.operationClass != .control })
    }

    private var nonControlGrantCount: Int {
        admissionGrants.values.count(where: { $0.operationClass != .control })
    }

    private func hasAdmissionCapacity(
        for operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        encodedBytes: Int
    ) -> Bool {
        if let activeTransactionID, transactionID != activeTransactionID { return false }
        guard queuedCount + admissionGrants.count < capacity else { return false }
        guard activeTransactionEncodedBytes + activeJobEncodedBytes
            + queuedEncodedBytes + waitingEncodedBytes + encodedBytes <= maximumProducerEncodedBytes
        else { return false }
        if operationClass == .control { return true }
        return nonControlQueuedCount + nonControlGrantCount < capacity - reservedControlCapacity
    }

    private func canGrantAdmission(_ waiter: AdmissionWaiter) -> Bool {
        if let activeTransactionID, waiter.transactionID != activeTransactionID { return false }
        guard queuedCount + admissionGrants.count < capacity else { return false }
        // The waiter's bytes are already retained and counted in
        // waitingEncodedBytes, so granting changes ownership without adding
        // memory. Only the slot/class reservation must be checked here.
        if waiter.operationClass == .control { return true }
        return nonControlQueuedCount + nonControlGrantCount < capacity - reservedControlCapacity
    }

    private func waitForAdmission(
        _ operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        jobID: UUID,
        encodedBytes: Int,
        checksCancellation: Bool
    ) async throws -> UInt64? {
        while true {
            guard !closed, !failedClosed else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "SQLite executor is unavailable")
            }
            if checksCancellation { try Task.checkCancellation() }
            if let grant = admissionGrants[jobID] {
                if admissionGrantTransferSuspendedForTesting {
                    await withCheckedContinuation { continuation in
                        testGrantTransferContinuations[jobID] = continuation
                    }
                    continue
                }
                _ = admissionGrants.removeValue(forKey: jobID)
                grantedEncodedBytes -= grant.encodedBytes
                waitingEncodedBytes -= grant.encodedBytes
                if let activeTransactionID, grant.transactionID != activeTransactionID {
                    // BEGIN may have activated after this producer was granted.
                    // Re-admit it with its original age only after the owning
                    // transaction completes; never let a stale grant cross the
                    // transaction-affinity boundary.
                    let sequence = grant.sequence
                    try await withCheckedThrowingContinuation { continuation in
                        admissionWaiters[operationClass, default: []].append(.init(
                            id: jobID,
                            sequence: sequence,
                            operationClass: operationClass,
                            transactionID: transactionID,
                            encodedBytes: encodedBytes,
                            continuation: continuation
                        ))
                        waitingEncodedBytes += encodedBytes
                        maximumWaitingDepthObserved = max(maximumWaitingDepthObserved, waitingCount)
                        recordProducerEncodedHighWater()
                    }
                    continue
                }
                return grant.sequence
            }
            let transactionContinuation = activeTransactionID != nil && transactionID == activeTransactionID
            let mustQueueBehindOlderWaiter = waitingCount > 0 && !transactionContinuation
            if !mustQueueBehindOlderWaiter,
               hasAdmissionCapacity(
                   for: operationClass,
                   transactionID: transactionID,
                   encodedBytes: encodedBytes
               )
            {
                return nil
            }

            saturationCount += 1
            let canWait = waitingCount < maximumAdmissionWaiters
                && (operationClass == .control
                    || nonControlWaitingCount < maximumAdmissionWaiters - reservedControlCapacity)
                && activeTransactionEncodedBytes + activeJobEncodedBytes
                + queuedEncodedBytes + waitingEncodedBytes + encodedBytes <= maximumProducerEncodedBytes
            guard canWait else {
                throw ServiceAPIError(
                    code: .rateLimited,
                    message: "SQLite admission is saturated",
                    retryable: true
                )
            }
            let sequence = nextSequence
            nextSequence &+= 1
            try await withCheckedThrowingContinuation { continuation in
                admissionWaiters[operationClass, default: []].append(.init(
                    id: jobID,
                    sequence: sequence,
                    operationClass: operationClass,
                    transactionID: transactionID,
                    encodedBytes: encodedBytes,
                    continuation: continuation
                ))
                waitingEncodedBytes += encodedBytes
                maximumWaitingDepthObserved = max(maximumWaitingDepthObserved, waitingCount)
                recordProducerEncodedHighWater()
            }
        }
    }

    private func submit(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        encodedBytes: Int
    ) async throws -> [SQLiteRow] {
        let jobID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await enqueue(
                work,
                operationClass: operationClass,
                transactionID: transactionID,
                jobID: jobID,
                encodedBytes: encodedBytes,
                checksCancellation: true
            )
        } onCancel: {
            Task { await self.cancel(jobID: jobID) }
        }
    }

    private func submitUncancelled(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        encodedBytes: Int
    ) async throws -> [SQLiteRow] {
        try await enqueue(
            work,
            operationClass: operationClass,
            transactionID: transactionID,
            jobID: UUID(),
            encodedBytes: encodedBytes,
            checksCancellation: false
        )
    }

    private func enqueue(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        jobID: UUID,
        encodedBytes: Int,
        checksCancellation: Bool
    ) async throws -> [SQLiteRow] {
        guard !closed, !failedClosed else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "SQLite executor is unavailable")
        }
        guard encodedBytes >= 0, encodedBytes <= maximumProducerEncodedBytes else {
            throw ServiceAPIError(
                code: .rateLimited,
                message: "SQLite operation exceeds the encoded producer-memory bound",
                retryable: true
            )
        }
        // BEGIN reserves the transaction body's typed inputs until terminal
        // COMMIT/ROLLBACK. Every generated statement/binding remains additional
        // retained headroom while SQLite is executing; the reservation is not
        // consumable because the original typed value is still captured.
        let chargedEncodedBytes = encodedBytes
        let grantedSequence = try await waitForAdmission(
            operationClass,
            transactionID: transactionID,
            jobID: jobID,
            encodedBytes: chargedEncodedBytes,
            checksCancellation: checksCancellation
        )
        // Cancellation can race a grant being transferred into this actor.
        // Recheck before materializing an ordinary job and immediately make
        // the released reservation available to the next oldest waiter.
        do {
            if checksCancellation { try Task.checkCancellation() }
        } catch {
            resumeAdmissionWaiters()
            startWorkerIfNeeded()
            throw error
        }
        let sequence: UInt64
        if let grantedSequence {
            sequence = grantedSequence
        } else {
            sequence = nextSequence
            nextSequence &+= 1
        }
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(
                id: jobID,
                sequence: sequence,
                operationClass: operationClass,
                transactionID: transactionID,
                work: work,
                encodedBytes: chargedEncodedBytes,
                enqueuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                continuation: continuation
            )
            let insertionIndex = queues[operationClass, default: []]
                .firstIndex(where: { $0.sequence > sequence })
                ?? queues[operationClass, default: []].endIndex
            queues[operationClass, default: []].insert(job, at: insertionIndex)
            queuedEncodedBytes += chargedEncodedBytes
            maximumQueuedDepthObserved = max(maximumQueuedDepthObserved, queuedCount)
            recordProducerEncodedHighWater()
            startWorkerIfNeeded()
        }
    }

    private func cancel(jobID: UUID) {
        if let grant = admissionGrants.removeValue(forKey: jobID) {
            grantedEncodedBytes -= grant.encodedBytes
            waitingEncodedBytes -= grant.encodedBytes
            testGrantTransferContinuations.removeValue(forKey: jobID)?.resume()
            resumeAdmissionWaiters()
            startWorkerIfNeeded()
            return
        }
        for operationClass in SQLiteOperationClass.allCases {
            if let index = admissionWaiters[operationClass, default: []].firstIndex(where: { $0.id == jobID }) {
                let waiter = admissionWaiters[operationClass, default: []].remove(at: index)
                waitingEncodedBytes -= waiter.encodedBytes
                waiter.continuation.resume(throwing: CancellationError())
                resumeAdmissionWaiters()
                startWorkerIfNeeded()
                return
            }
        }
        for operationClass in SQLiteOperationClass.allCases {
            if let index = queues[operationClass, default: []].firstIndex(where: { $0.id == jobID }) {
                let job = queues[operationClass, default: []].remove(at: index)
                queuedEncodedBytes -= job.encodedBytes
                job.continuation.resume(throwing: CancellationError())
                if activeTransactionID == nil {
                    resumeAdmissionWaiters()
                    startWorkerIfNeeded()
                }
                return
            }
        }
    }

    private func failClosedAfterRollbackError() {
        failedClosed = true
        activeJobEncodedBytes = 0
        let error = ServiceAPIError(
            code: .persistenceUnavailable,
            message: "SQLite transaction rollback could not be confirmed",
            retryable: false
        )
        for grant in admissionGrants.values {
            grantedEncodedBytes -= grant.encodedBytes
            waitingEncodedBytes -= grant.encodedBytes
        }
        admissionGrants.removeAll()
        let testContinuations = testGrantTransferContinuations.values
        testGrantTransferContinuations.removeAll()
        for continuation in testContinuations { continuation.resume() }
        for operationClass in SQLiteOperationClass.allCases {
            let jobs = queues[operationClass, default: []]
            queues[operationClass] = []
            for job in jobs {
                queuedEncodedBytes -= job.encodedBytes
                job.continuation.resume(throwing: error)
            }
            let waiters = admissionWaiters[operationClass, default: []]
            admissionWaiters[operationClass] = []
            for waiter in waiters {
                waitingEncodedBytes -= waiter.encodedBytes
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func startWorkerIfNeeded() {
        guard !workerRunning, !workerSuspendedForTesting else { return }
        workerRunning = true
        Task { await workerLoop() }
    }

    private func workerLoop() async {
        while let job = dequeueEligibleJob() {
            // Move retained bytes from the queue into the executing slot before
            // admitting another producer. BEGIN transfers its typed reservation
            // into activeTransactionEncodedBytes instead of double-counting it as
            // an executing SQL binding.
            if job.work.beginsTransaction {
                activeTransactionID = job.transactionID
                activeTransactionEncodedBytes = job.encodedBytes
                activeJobEncodedBytes = 0
            } else {
                activeJobEncodedBytes = job.encodedBytes
            }
            recordProducerEncodedHighWater()
            // Once BEGIN is selected, keep its newly freed bounded slot for
            // transaction-affine statements through COMMIT/ROLLBACK. Ordinary
            // work can wake another producer because its executing bytes remain
            // charged until SQLite returns.
            if activeTransactionID == nil, !job.work.beginsTransaction {
                resumeAdmissionWaiters()
            }
            if executionSuspendedForTesting {
                await withCheckedContinuation { continuation in
                    testExecutionContinuations[job.id] = continuation
                }
            }
            let startedAt = DispatchTime.now().uptimeNanoseconds
            totalWaitNanosecondsByClass[job.operationClass, default: 0] &+=
                startedAt &- job.enqueuedAtNanoseconds
            do {
                let rows: [SQLiteRow]
                switch job.work {
                case let .query(sql, bindings):
                    rows = try await connection.query(sql, bindings)
                case .begin:
                    rows = try await connection.query("BEGIN IMMEDIATE")
                case .commit:
                    rows = try await connection.query("COMMIT")
                case .rollback:
                    rows = try await connection.query("ROLLBACK")
                }
                activeJobEncodedBytes = 0
                if case .commit = job.work {
                    activeTransactionID = nil
                    activeTransactionEncodedBytes = 0
                } else if case .rollback = job.work {
                    activeTransactionID = nil
                    activeTransactionEncodedBytes = 0
                }
                if activeTransactionID == nil { resumeAdmissionWaiters() }
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                totalExecuteNanosecondsByClass[job.operationClass, default: 0] &+=
                    finishedAt &- startedAt
                completedByClass[job.operationClass, default: 0] += 1
                testCompletionObserver?(job.operationClass)
                job.continuation.resume(returning: rows)
            } catch {
                activeJobEncodedBytes = 0
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                totalExecuteNanosecondsByClass[job.operationClass, default: 0] &+=
                    finishedAt &- startedAt
                if case .begin = job.work {
                    activeTransactionID = nil
                    activeTransactionEncodedBytes = 0
                    resumeAdmissionWaiters()
                } else if case .commit = job.work {
                    // A failed commit still needs a matching rollback before any
                    // unrelated statement is allowed to execute.
                } else if case .rollback = job.work {
                    failClosedAfterRollbackError()
                } else if activeTransactionID == nil {
                    resumeAdmissionWaiters()
                }
                job.continuation.resume(throwing: error)
            }
        }
        workerRunning = false
        if hasEligibleJob { startWorkerIfNeeded() }
    }

    private var hasEligibleJob: Bool {
        if let activeTransactionID {
            return queues.values.contains { queue in
                queue.contains { $0.transactionID == activeTransactionID }
            }
        }
        if beginIsBlockedByOutstandingGrant { return false }
        return queuedCount > 0
    }

    private var beginIsBlockedByOutstandingGrant: Bool {
        !admissionGrants.isEmpty
            && queues.values.contains { queue in queue.contains(where: { $0.work.beginsTransaction }) }
    }

    private func dequeueEligibleJob() -> Job? {
        if let activeTransactionID {
            let candidates = SQLiteOperationClass.allCases.compactMap { operationClass -> (SQLiteOperationClass, Int, Job)? in
                guard let index = queues[operationClass, default: []].firstIndex(where: {
                    $0.transactionID == activeTransactionID
                }) else { return nil }
                return (operationClass, index, queues[operationClass, default: []][index])
            }
            guard let selected = candidates.min(by: { $0.2.sequence < $1.2.sequence }) else { return nil }
            let job = queues[selected.0, default: []].remove(at: selected.1)
            queuedEncodedBytes -= job.encodedBytes
            return job
        }

        // A producer granted before BEGIN must either transfer into its original
        // sequence position or be canceled before transaction affinity activates.
        // Otherwise a stale unrelated grant could fill the only continuation slot.
        guard !beginIsBlockedByOutstandingGrant else { return nil }
        let nonempty = SQLiteOperationClass.allCases.filter { !queues[$0, default: []].isEmpty }
        guard !nonempty.isEmpty else { return nil }

        let aged = nonempty.filter { bypasses[$0, default: 0] >= 8 }
        let selectedClass: SQLiteOperationClass
        if let selected = aged.min(by: {
            queues[$0, default: []][0].sequence < queues[$1, default: []][0].sequence
        }) {
            selectedClass = selected
        } else {
            var selected: SQLiteOperationClass?
            for _ in weightedCycle.indices {
                let candidate = weightedCycle[cycleIndex]
                cycleIndex = (cycleIndex + 1) % weightedCycle.count
                if !queues[candidate, default: []].isEmpty {
                    selected = candidate
                    break
                }
            }
            selectedClass = selected ?? nonempty[0]
        }

        for operationClass in SQLiteOperationClass.allCases {
            if operationClass == selectedClass {
                bypasses[operationClass] = 0
            } else if !queues[operationClass, default: []].isEmpty {
                bypasses[operationClass, default: 0] += 1
            }
        }
        let job = queues[selectedClass, default: []].removeFirst()
        queuedEncodedBytes -= job.encodedBytes
        return job
    }

    private func resumeAdmissionWaiters() {
        // Wake only work whose slot and byte budget can be reserved now. The
        // actor-owned grant prevents a fresh arrival from stealing that capacity
        // before the selected producer resumes and materializes its job.
        let eligible = SQLiteOperationClass.allCases.compactMap { operationClass -> AdmissionWaiter? in
            guard let waiter = admissionWaiters[operationClass, default: []].first,
                  canGrantAdmission(waiter)
            else { return nil }
            return waiter
        }
        guard let selected = eligible.min(by: { $0.sequence < $1.sequence }),
              let index = admissionWaiters[selected.operationClass, default: []].firstIndex(where: { $0.id == selected.id })
        else { return }
        let waiter = admissionWaiters[selected.operationClass, default: []].remove(at: index)
        admissionGrants[waiter.id] = waiter
        grantedEncodedBytes += waiter.encodedBytes
        waiter.continuation.resume()
    }

    private func recordProducerEncodedHighWater() {
        maximumProducerEncodedBytesObserved = max(
            maximumProducerEncodedBytesObserved,
            activeTransactionEncodedBytes + activeJobEncodedBytes + queuedEncodedBytes + waitingEncodedBytes
        )
    }
}
