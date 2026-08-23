import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO
import XCTest
@testable import RepoPromptServicePersistence

final class SQLiteDatabaseExecutorTests: XCTestCase {
    func testTransactionAffinityPreventsConcurrentReadFromEnteringOpenTransaction() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        _ = try await database.query("CREATE TABLE values_table(value INTEGER NOT NULL)")
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            _ = try await database.query("INSERT INTO values_table(value) VALUES(1)")
        }

        let outsideRead = Task {
            try await database.query("SELECT COUNT(*) AS count FROM values_table").first?.column("count")?.integer
        }
        await Task.yield()
        let waiting = await database.metrics()
        XCTAssertEqual(waiting.waitingByClass[.interactive], 1)

        try await database.commitTransaction(transactionID)
        let outsideCount = try await outsideRead.value
        XCTAssertEqual(outsideCount, 1)
        try await database.close()
    }

    func testActiveTransactionReservationPreventsFreshAdmissionFromStealingContinuationCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32
        )
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        let unrelated = (0 ..< 31).map { _ in
            Task {
                try await database.query("SELECT 1", operationClass: .control)
            }
        }
        while await database.metrics().waitingByClass[.control, default: 0] < unrelated.count {
            await Task.yield()
        }

        let rows = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            try await database.query("SELECT 42 AS value", operationClass: .interactive)
        }
        XCTAssertEqual(rows.first?.column("value")?.integer, 42)
        try await database.rollbackTransaction(transactionID)
        for task in unrelated { _ = try await task.value }
        let metrics = await database.metrics()
        XCTAssertEqual(metrics.activeTransactionEncodedBytes, 0)
        XCTAssertLessThanOrEqual(
            metrics.maximumProducerEncodedBytesObserved,
            metrics.maximumProducerEncodedBytes
        )
        try await database.close()
    }

    func testTransactionReservationAndGeneratedStatementHeadroomStayWithinLimit() async throws {
        let maximumBytes = 1_048_576
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: maximumBytes
        )
        await database.suspendWorkerForTesting()
        let transactionID = UUID()
        let begin = Task {
            try await database.beginTransaction(
                transactionID,
                operationClass: .interactive,
                estimatedEncodedBytes: 400_000
            )
        }
        while await database.metrics().queuedByClass[.interactive, default: 0] != 1 {
            await Task.yield()
        }
        let unrelated = Task {
            try await database.query(
                "SELECT length(?)",
                [.text(String(repeating: "u", count: 300_000))],
                operationClass: .bulk
            )
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }
        await database.resumeWorkerForTesting()
        try await begin.value

        let rows = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            try await database.query(
                "SELECT length(?) AS size",
                [.text(String(repeating: "t", count: 300_000))],
                operationClass: .interactive
            )
        }
        XCTAssertEqual(rows.first?.column("size")?.integer, 300_000)
        try await database.rollbackTransaction(transactionID)
        _ = try await unrelated.value
        let metrics = await database.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumProducerEncodedBytesObserved, maximumBytes)
        try await database.close()
    }

    func testActiveTransactionContinuationCountsByteHeavyUnrelatedWaiters() async throws {
        let maximumBytes = 1_048_576
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: maximumBytes
        )
        let transactionID = UUID()
        try await database.beginTransaction(
            transactionID,
            operationClass: .interactive,
            estimatedEncodedBytes: 400_000
        )
        let unrelated = Task {
            try await database.query(
                "SELECT length(?)",
                [.text(String(repeating: "w", count: 600_000))],
                operationClass: .bulk
            )
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }

        do {
            _ = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
                try await database.query(
                    "SELECT length(?)",
                    [.text(String(repeating: "x", count: 50_000))],
                    operationClass: .interactive
                )
            }
            XCTFail("continuation bytes beyond the reservation must include retained waiters")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }
        let rows = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            try await database.query(
                "SELECT length(?) AS size",
                [.text(String(repeating: "y", count: 30_000))],
                operationClass: .interactive
            )
        }
        XCTAssertEqual(rows.first?.column("size")?.integer, 30_000)
        try await database.rollbackTransaction(transactionID)
        _ = try await unrelated.value
        let metrics = await database.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumProducerEncodedBytesObserved, maximumBytes)
        try await database.close()
    }

    func testExecutingBindingsRemainChargedWhileQueueAndWaiterSaturate() async throws {
        let maximumBytes = 1_048_576
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: maximumBytes
        )
        await database.suspendExecutionForTesting()
        let active = Task {
            try await database.query(
                "SELECT length(?)",
                [.text(String(repeating: "a", count: 600_000))],
                operationClass: .bulk
            )
        }
        while await database.metrics().activeJobEncodedBytes < 600_000 {
            await Task.yield()
        }
        let queued = (0 ..< 16).map { index in
            Task {
                try await database.query(
                    "SELECT length(?)",
                    [.text(index == 0 ? String(repeating: "q", count: 300_000) : "q")],
                    operationClass: .bulk
                )
            }
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 16 {
            await Task.yield()
        }
        let waiting = Task {
            try await database.query("SELECT 1", operationClass: .bulk)
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }
        let pressured = await database.metrics()
        XCTAssertGreaterThanOrEqual(pressured.activeJobEncodedBytes, 600_000)
        XCTAssertGreaterThanOrEqual(pressured.maximumProducerEncodedBytesObserved, 900_000)
        XCTAssertLessThanOrEqual(pressured.maximumProducerEncodedBytesObserved, maximumBytes)

        await database.resumeExecutionForTesting()
        _ = try await active.value
        for task in queued { _ = try await task.value }
        _ = try await waiting.value
        let drained = await database.metrics()
        XCTAssertEqual(drained.activeJobEncodedBytes, 0)
        XCTAssertEqual(drained.queuedEncodedBytes, 0)
        XCTAssertEqual(drained.waitingEncodedBytes, 0)
        try await database.close()
    }

    func testAdmissionGrantReservesCapacityAndOlderWaiterExecutesBeforeFreshArrival() async throws {
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32
        )
        _ = try await database.query("CREATE TABLE admission_order(value TEXT NOT NULL)")
        await database.suspendWorkerForTesting()
        let fillers = (0 ..< 16).map { index in
            Task {
                try await database.query(
                    "INSERT INTO admission_order(value) VALUES(?)",
                    [.text("filler-\(index)")],
                    operationClass: .bulk
                )
            }
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 16 {
            await Task.yield()
        }
        let older = Task {
            try await database.query(
                "INSERT INTO admission_order(value) VALUES('older')",
                operationClass: .bulk
            )
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }

        // Free exactly one slot. Whether the older waiter still owns an
        // actor-held grant or has transferred it into the queue, that slot must
        // remain reserved and the fresh arrival must continue waiting.
        fillers[0].cancel()
        _ = try? await fillers[0].value
        let fresh = Task {
            try await database.query(
                "INSERT INTO admission_order(value) VALUES('fresh')",
                operationClass: .bulk
            )
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] < 1 {
            await Task.yield()
        }
        let reserved = await database.metrics()
        XCTAssertLessThanOrEqual(reserved.queuedByClass.values.reduce(0, +), reserved.capacity)
        XCTAssertLessThanOrEqual(reserved.maximumWaitingDepthObserved, reserved.maximumAdmissionWaiters)

        await database.resumeWorkerForTesting()
        for filler in fillers.dropFirst() { _ = try await filler.value }
        _ = try await older.value
        _ = try await fresh.value
        let order = try await database.query(
            "SELECT value FROM admission_order WHERE value IN ('older','fresh') ORDER BY rowid"
        ).compactMap { $0.column("value")?.string }
        XCTAssertEqual(order, ["older", "fresh"])
        try await database.close()
    }

    func testOutstandingGrantMustTransferBeforeBeginActivates() async throws {
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32
        )
        await database.suspendWorkerForTesting()
        await database.suspendAdmissionGrantTransferForTesting()
        let fillers = (0 ..< 15).map { _ in
            Task { try await database.query("SELECT 1", operationClass: .bulk) }
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 15 {
            await Task.yield()
        }
        let transactionID = UUID()
        let begin = Task {
            try await database.beginTransaction(
                transactionID,
                operationClass: .bulk,
                estimatedEncodedBytes: 128
            )
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 16 {
            await Task.yield()
        }
        let unrelated = Task {
            try await database.query("SELECT 2", operationClass: .bulk)
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }

        await database.resumeWorkerForTesting()
        while await database.admissionGrantCountForTesting() != 1 {
            await Task.yield()
        }
        let blocked = await database.metrics()
        XCTAssertEqual(blocked.activeTransactionEncodedBytes, 0)
        XCTAssertEqual(blocked.waitingByClass[.bulk], 1)

        await database.resumeAdmissionGrantTransferForTesting()
        try await begin.value
        let continuation = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            try await database.query("SELECT 42 AS value", operationClass: .interactive)
        }
        XCTAssertEqual(continuation.first?.column("value")?.integer, 42)
        try await database.rollbackTransaction(transactionID)
        for filler in fillers { _ = try await filler.value }
        _ = try await unrelated.value
        let drained = await database.metrics()
        XCTAssertEqual(drained.activeTransactionEncodedBytes, 0)
        XCTAssertEqual(drained.activeJobEncodedBytes, 0)
        XCTAssertEqual(drained.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(drained.waitingByClass.values.reduce(0, +), 0)
        try await database.close()
    }

    func testCancelingOutstandingGrantRestartsBlockedBegin() async throws {
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32
        )
        await database.suspendWorkerForTesting()
        await database.suspendAdmissionGrantTransferForTesting()
        let fillers = (0 ..< 15).map { _ in
            Task { try await database.query("SELECT 1", operationClass: .bulk) }
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 15 {
            await Task.yield()
        }
        let transactionID = UUID()
        let begin = Task {
            try await database.beginTransaction(
                transactionID,
                operationClass: .bulk,
                estimatedEncodedBytes: 128
            )
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] != 16 {
            await Task.yield()
        }
        let grantee = Task {
            try await database.query("SELECT 2", operationClass: .bulk)
        }
        while await database.metrics().waitingByClass[.bulk, default: 0] != 1 {
            await Task.yield()
        }

        await database.resumeWorkerForTesting()
        while await database.admissionGrantCountForTesting() != 1 {
            await Task.yield()
        }
        let blocked = await database.metrics()
        XCTAssertEqual(blocked.activeTransactionEncodedBytes, 0)
        grantee.cancel()
        do {
            _ = try await grantee.value
            XCTFail("held admission grant must observe cancellation")
        } catch is CancellationError {}

        try await begin.value
        let continuation = try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            try await database.query("SELECT 42 AS value", operationClass: .interactive)
        }
        XCTAssertEqual(continuation.first?.column("value")?.integer, 42)
        try await database.rollbackTransaction(transactionID)
        for filler in fillers { _ = try await filler.value }
        await database.resumeAdmissionGrantTransferForTesting()
        let drained = await database.metrics()
        XCTAssertEqual(drained.activeTransactionEncodedBytes, 0)
        XCTAssertEqual(drained.activeJobEncodedBytes, 0)
        XCTAssertEqual(drained.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(drained.waitingByClass.values.reduce(0, +), 0)
        try await database.close()
    }

    func testControlAdmissionHasPilotSizedReservedCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        let metrics = await database.metrics()
        XCTAssertEqual(metrics.capacity, 256)
        XCTAssertGreaterThanOrEqual(metrics.reservedControlCapacity, 16)
        XCTAssertEqual(SQLiteDatabaseExecutor.maximumBulkRows, 256)
        XCTAssertEqual(SQLiteDatabaseExecutor.maximumBulkEncodedBytes, 1_048_576)
        try await database.close()
    }

    func testQueuedCancellationRemovesWorkAndFreesCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        await database.suspendWorkerForTesting()
        let queued = Task {
            try await database.query("SELECT 1", operationClass: .bulk)
        }
        while await database.metrics().queuedByClass[.bulk] != 1 { await Task.yield() }
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("queued database work should be canceled before execution")
        } catch is CancellationError {}
        let afterCancellation = await database.metrics()
        XCTAssertEqual(afterCancellation.queuedByClass[.bulk], 0)
        await database.resumeWorkerForTesting()
        try await database.close()
    }

    func testAdmissionWaitersAreBoundedAndCancellationReclaimsEverySlot() async throws {
        let database = try await SQLiteDatabaseExecutor.open(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32
        )
        await database.suspendWorkerForTesting()

        let queued = (0 ..< 16).map { _ in
            Task { try await database.query("SELECT 1", operationClass: .bulk) }
        }
        while await database.metrics().queuedByClass[.bulk] != 16 { await Task.yield() }
        let waiting = (0 ..< 16).map { _ in
            Task { try await database.query("SELECT 1", operationClass: .bulk) }
        }
        while await database.metrics().waitingByClass[.bulk] != 16 { await Task.yield() }

        do {
            _ = try await database.query("SELECT 1", operationClass: .bulk)
            XCTFail("non-control work beyond the bounded waiter reserve must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertTrue(error.retryable)
        }

        for task in queued + waiting { task.cancel() }
        for task in queued + waiting { _ = try? await task.value }
        while true {
            let current = await database.metrics()
            if current.queuedByClass[.bulk] == 0, current.waitingByClass[.bulk] == 0 { break }
            await Task.yield()
        }
        let metrics = await database.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumQueuedDepthObserved, metrics.capacity)
        XCTAssertLessThanOrEqual(metrics.maximumWaitingDepthObserved, metrics.maximumAdmissionWaiters)
        await database.resumeWorkerForTesting()
        try await database.close()
    }
}

final class SQLiteDatabaseExecutorFairnessTests: XCTestCase {
    func testEveryClassAdvancesUnderMixedPressureAndQueuesDrainWithinCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        await database.suspendWorkerForTesting()
        let jobs = (0 ..< 24).map { index in
            Task {
                let operationClass: SQLiteOperationClass = switch index % 3 {
                case 0: .control
                case 1: .interactive
                default: .bulk
                }
                return try await database.query("SELECT ? AS value", [.integer(index)], operationClass: operationClass)
            }
        }
        await Task.yield()
        let pressured = await database.metrics()
        XCTAssertLessThanOrEqual(pressured.queuedByClass.values.reduce(0, +), pressured.capacity)
        await database.resumeWorkerForTesting()
        for job in jobs { _ = try await job.value }
        let finished = await database.metrics()
        for operationClass in SQLiteOperationClass.allCases {
            XCTAssertGreaterThan(finished.completedByClass[operationClass, default: 0], 0)
            XCTAssertEqual(finished.queuedByClass[operationClass], 0)
        }
        try await database.close()
    }


    func testWholeSessionTranscriptIsRejectedBeforeBeginWhenRetainedInputExceedsBound() async throws {
        let store = try await SQLiteServiceStore.openForExecutorSaturationTesting(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: 1_048_576
        )
        let sessionID = UUID()
        let actor = ExternalActor(userID: "provider-fixture", username: "provider", displayName: "Provider")
        let entries = (1 ... 2).map { sequence in
            TranscriptEntry(
                entryID: UUID(),
                sessionSequence: Int64(sequence),
                kind: .assistant,
                content: String(repeating: "t", count: 600_000),
                actor: actor,
                timestamp: Date()
            )
        }
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            model: "fake",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 1,
            transcript: entries,
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 0)
        )
        do {
            _ = try await store.authorityStore_persistSession(
                snapshot,
                eventType: .sessionCreated,
                actor: actor,
                correlationID: UUID(),
                idempotency: nil
            )
            XCTFail("whole retained session input must be bounded before BEGIN")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }
        let metrics = await store.database.metrics()
        XCTAssertEqual(metrics.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(metrics.waitingByClass.values.reduce(0, +), 0)
        try await store.close(clean: false)
    }

    func testOversizedToolSessionIsRejectedBeforeBeginOrAdmission() async throws {
        let store = try await SQLiteServiceStore.openForExecutorSaturationTesting(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: 1_048_576
        )
        let sessionID = UUID()
        let actor = ExternalActor(userID: "provider-fixture", username: "provider", displayName: "Provider")
        let entries = (1 ... 2).map { sequence in
            TranscriptEntry(
                entryID: UUID(),
                sessionSequence: Int64(sequence),
                kind: .assistant,
                content: String(repeating: "t", count: 600_000),
                actor: actor,
                timestamp: Date()
            )
        }
        let session = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            model: "fake",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 1,
            transcript: entries,
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 0)
        )
        do {
            _ = try await store.authorityStore_persistToolInvocation(
                .init(
                    invocationID: UUID(),
                    toolName: "fake_tool",
                    state: "completed",
                    argumentDigest: String(repeating: "a", count: 64),
                    resultDigest: String(repeating: "b", count: 64)
                ),
                session: session,
                actor: actor,
                correlationID: UUID(),
                eventType: .toolCompleted
            )
            XCTFail("tool admission must account for the retained session before BEGIN")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }
        let metrics = await store.database.metrics()
        XCTAssertEqual(metrics.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(metrics.waitingByClass.values.reduce(0, +), 0)
        try await store.close(clean: false)
    }

    func testProductionStoreSixteenProviderRunsSaturateBackpressureFairlyAndCommitCancelPromptly() async throws {
        let store = try await SQLiteServiceStore.openForExecutorSaturationTesting(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: 4 * 1_048_576
        )
        let database = await store.database
        await database.suspendWorkerForTesting()
        let completionBaseline = await database.metrics().completedByClass

        let actor = ExternalActor(userID: "provider-fixture", username: "provider", displayName: "Provider")
        let sessions = (0 ..< 16).map { index in
            let id = UUID()
            return SessionSnapshot(
                sessionID: id,
                projectID: UUID(),
                parentSessionID: nil,
                rootSessionID: id,
                creator: actor,
                provider: .codex,
                model: "fake-\(index)",
                visibility: .privateSession,
                state: .idle,
                runGeneration: 1,
                turnEpoch: 1,
                revision: 1,
                transcript: [],
                interactions: [],
                cursor: .init(storeID: UUID(), globalSequence: 0)
            )
        }
        let runIDs = (0 ..< 16).map { _ in UUID() }
        let startedAt = Date()
        let runWrites = (0 ..< 15).map { index in
            Task {
                try await store.authorityStore_persistRun(.init(
                    runID: runIDs[index],
                    sessionID: sessions[index].sessionID,
                    provider: .codex,
                    providerSessionID: "fake-\(index)",
                    state: "running",
                    generation: 1,
                    turnEpoch: 1,
                    startReason: "saturation-test",
                    startedAt: startedAt
                ))
            }
        }
        let committedCancellation = Task {
            try await store.authorityStore_persistRun(.init(
                runID: runIDs[15],
                sessionID: sessions[15].sessionID,
                provider: .codex,
                providerSessionID: "fake-15",
                state: "canceled",
                generation: 1,
                turnEpoch: 1,
                startReason: "saturation-test",
                endReason: "canceled",
                startedAt: startedAt,
                endedAt: Date()
            ))
        }
        while await database.metrics().queuedByClass[.control, default: 0] < 16 {
            await Task.yield()
        }

        let diagnosticPayload = Data(
            ("{\"data\":\"" + String(repeating: "a", count: 64 * 1_024 - 11) + "\"}").utf8
        )
        let firstDiagnostics = sessions.prefix(8).map { session in
            Task {
                try await store.authorityStore_persistServiceDiagnostic(
                    projectID: session.projectID,
                    actor: actor,
                    correlationID: UUID(),
                    payload: diagnosticPayload
                )
            }
        }
        let firstTools = sessions.prefix(8).map { session in
            Task {
                try await store.authorityStore_persistToolInvocation(
                    .init(
                        invocationID: UUID(),
                        toolName: "fake_tool",
                        state: "completed",
                        argumentDigest: String(repeating: "a", count: 64),
                        resultDigest: String(repeating: "b", count: 64)
                    ),
                    session: session,
                    actor: actor,
                    correlationID: UUID(),
                    eventType: .toolCompleted
                )
            }
        }
        while true {
            let staged = await database.metrics()
            if staged.queuedByClass[.interactive, default: 0]
                + staged.queuedByClass[.bulk, default: 0] == 16
            {
                break
            }
            await Task.yield()
        }
        let diagnostics = firstDiagnostics + sessions.suffix(8).map { session in
            Task {
                try await store.authorityStore_persistServiceDiagnostic(
                    projectID: session.projectID,
                    actor: actor,
                    correlationID: UUID(),
                    payload: diagnosticPayload
                )
            }
        }
        let tools = firstTools + sessions.suffix(8).map { session in
            Task {
                try await store.authorityStore_persistToolInvocation(
                    .init(
                        invocationID: UUID(),
                        toolName: "fake_tool",
                        state: "completed",
                        argumentDigest: String(repeating: "a", count: 64),
                        resultDigest: String(repeating: "b", count: 64)
                    ),
                    session: session,
                    actor: actor,
                    correlationID: UUID(),
                    eventType: .toolCompleted
                )
            }
        }
        let checkpoint = Task { try await store.authorityStore_checkpoint() }

        let saturationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < saturationDeadline {
            let pressured = await database.metrics()
            let queued = pressured.queuedByClass.values.reduce(0, +)
            let waiting = pressured.waitingByClass.values.reduce(0, +)
            if queued == pressured.capacity, waiting > 0 { break }
            await Task.yield()
        }
        let pressured = await database.metrics()
        guard pressured.queuedByClass.values.reduce(0, +) == pressured.capacity,
              pressured.waitingByClass.values.reduce(0, +) > 0
        else {
            for task in runWrites { task.cancel() }
            for task in diagnostics { task.cancel() }
            for task in tools { task.cancel() }
            committedCancellation.cancel()
            checkpoint.cancel()
            await database.resumeWorkerForTesting()
            for task in runWrites { _ = try? await task.value }
            for task in diagnostics { _ = try? await task.value }
            for task in tools { _ = try? await task.value }
            _ = try? await committedCancellation.value
            _ = try? await checkpoint.value
            XCTFail("production workload did not reach capacity: \(pressured)")
            try await store.close(clean: false)
            return
        }
        XCTAssertEqual(pressured.queuedByClass.values.reduce(0, +), pressured.capacity)
        XCTAssertGreaterThan(pressured.waitingByClass.values.reduce(0, +), 0)
        XCTAssertGreaterThan(pressured.saturationCount, 0)
        XCTAssertGreaterThanOrEqual(pressured.maximumProducerEncodedBytesObserved, 8 * diagnosticPayload.count)
        XCTAssertLessThanOrEqual(
            pressured.maximumProducerEncodedBytesObserved,
            pressured.maximumProducerEncodedBytes
        )

        let canceledProducer = tools[15]
        canceledProducer.cancel()
        do {
            _ = try await canceledProducer.value
            XCTFail("queued production tool write should observe real cancellation")
        } catch is CancellationError {}
        let clock = ContinuousClock()
        let cancelStarted = clock.now
        await database.resumeWorkerForTesting()
        try await committedCancellation.value
        XCTAssertLessThan(cancelStarted.duration(to: clock.now), .seconds(1))
        let progressBeforeCanceledRunCommitted = await database.metrics().completedByClass
        for operationClass in SQLiteOperationClass.allCases {
            XCTAssertGreaterThan(
                progressBeforeCanceledRunCommitted[operationClass, default: 0],
                completionBaseline[operationClass, default: 0],
                "\(operationClass) must make production progress before the canceled run commits"
            )
        }

        for runWrite in runWrites { try await runWrite.value }
        for diagnostic in diagnostics { _ = try await diagnostic.value }
        for tool in tools.dropLast() { _ = try await tool.value }
        try await checkpoint.value
        let runCount = try await database.query("SELECT COUNT(*) AS count FROM runs")
            .first?.column("count")?.integer
        let eventCount = try await database.query("SELECT COUNT(*) AS count FROM events")
            .first?.column("count")?.integer
        XCTAssertEqual(runCount, 16)
        XCTAssertEqual(eventCount, 31)

        let metrics = await database.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumQueuedDepthObserved, metrics.capacity)
        XCTAssertLessThanOrEqual(metrics.maximumWaitingDepthObserved, metrics.maximumAdmissionWaiters)
        XCTAssertEqual(metrics.queuedEncodedBytes, 0)
        XCTAssertEqual(metrics.waitingEncodedBytes, 0)
        XCTAssertEqual(metrics.activeTransactionEncodedBytes, 0)
        XCTAssertGreaterThan(metrics.maximumProducerEncodedBytesObserved, 0)
        for operationClass in SQLiteOperationClass.allCases {
            XCTAssertGreaterThan(metrics.completedByClass[operationClass, default: 0], 0)
        }

        try await store.close(clean: false)
    }

    func testWeightedCycleAndAgingBoundAreDeterministic() async throws {
        let recorder = SQLiteCompletionRecorder()
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        await database.suspendWorkerForTesting()
        await database.installTestCompletionObserver { recorder.append($0) }

        let classes: [SQLiteOperationClass] =
            Array(repeating: .control, count: 12)
                + Array(repeating: .interactive, count: 6)
                + Array(repeating: .bulk, count: 3)
        let jobs = classes.map { operationClass in
            Task { try await database.query("SELECT 1", operationClass: operationClass) }
        }
        while await database.metrics().queuedByClass.values.reduce(0, +) != classes.count {
            await Task.yield()
        }
        await database.resumeWorkerForTesting()
        for job in jobs { _ = try await job.value }

        let completions = recorder.values
        let firstCycle = Array(completions.prefix(7))
        XCTAssertEqual(firstCycle.count(where: { $0 == .control }), 4)
        XCTAssertEqual(firstCycle.count(where: { $0 == .interactive }), 2)
        XCTAssertEqual(firstCycle.count(where: { $0 == .bulk }), 1)
        for operationClass in SQLiteOperationClass.allCases {
            let positions = completions.indices.filter { completions[$0] == operationClass }
            XCTAssertFalse(positions.isEmpty)
            if let first = positions.first {
                XCTAssertLessThanOrEqual(first, 8)
            }
        }
        try await database.close()
    }
}

private final class SQLiteCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SQLiteOperationClass] = []

    var values: [SQLiteOperationClass] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: SQLiteOperationClass) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
