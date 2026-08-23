import Foundation
import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class DurabilityOperationsTests: XCTestCase {
    func testEventArchiveCompressionBoundsLiteralBeforeTwoByteRun() throws {
        let input = Data(Array(0 ..< 127).map(UInt8.init) + [200, 200])
        let compressed = EventArchiveCompression.compress(input)
        XCTAssertEqual(try EventArchiveCompression.decompress(compressed), input)
    }

    func testRetentionRequiresEventsOutsideBothCountAndAgeWindows() {
        let policy = EventRetentionPolicy(
            minimumLiveEventCount: 100_000,
            minimumLiveAge: 30 * 24 * 60 * 60,
            maximumArchiveBatch: 10_000
        )
        XCTAssertNil(policy.eligibleThrough(latestSequence: 100_000, ageEligibleThrough: 100_000, replayFloor: 0))
        XCTAssertEqual(
            policy.eligibleThrough(latestSequence: 200_000, ageEligibleThrough: 99_999, replayFloor: 0),
            10_000
        )
        XCTAssertNil(policy.eligibleThrough(latestSequence: 200_000, ageEligibleThrough: 99_999, replayFloor: 99_999))
        XCTAssertEqual(
            policy.eligibleThrough(latestSequence: 200_000, ageEligibleThrough: 150_000, replayFloor: 99_999),
            100_000
        )
    }

    func testRetentionArchivesOnlyContiguousPrefixOutsideBothWindows() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectID = UUID()
        var roots = [ProjectRootSnapshot(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)]
        for revision in 1 ... 8 {
            let cursor = try await store.nextCursor()
            let project = ProjectSnapshot(
                projectID: projectID,
                name: "P\(revision)",
                creator: actor,
                state: .active,
                roots: roots,
                revision: Int64(revision),
                cursor: cursor
            )
            let event = try await store.persistProject(
                project,
                eventType: revision == 1 ? .projectCreated : .projectUpdated,
                actor: actor,
                correlationID: UUID(),
                idempotency: nil
            )
            try await store.markEventOutboxDispatched(event.cursor)
            roots = project.roots
        }
        let old = Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
        _ = try await store.database.query("UPDATE events SET timestamp=? WHERE global_sequence<=4", [.float(old)])
        let archiveID = try await store.enforceEventRetention(
            policy: .init(minimumLiveEventCount: 3, minimumLiveAge: 30 * 24 * 60 * 60),
            now: Date()
        )
        let unwrappedArchiveID = try XCTUnwrap(archiveID)
        let archived = try await store.archivedEvents(archiveID: unwrappedArchiveID)
        XCTAssertEqual(archived.map(\.globalSequence), [1, 2, 3, 4])
        let live = try await store.events(after: nil, limit: 20)
        XCTAssertEqual(live.events.map(\.globalSequence), [5, 6, 7, 8])
        try await store.close()
    }

    func testMaintenanceDrainsLargeBacklogInBoundedLinearBulkSegments() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        addTeardownBlock { try? await store.close() }
        let projectID = UUID()
        let payloadText = String(repeating: "retention-payload", count: 16)
        for index in 0 ..< 513 {
            let event = try await store.persistServiceDiagnostic(
                projectID: projectID,
                actor: nil,
                correlationID: UUID(),
                payload: Data("{\"data\":\"\(payloadText)\",\"index\":\(index)}".utf8)
            )
            try await store.markEventOutboxDispatched(event.cursor)
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-retention-maintenance-\(UUID().uuidString)", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let worktrees = root.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path
        )
        let maintenance = DurabilityOperationsService(
            store: store,
            reconciler: reconciler,
            retentionPolicy: .init(
                minimumLiveEventCount: 7,
                minimumLiveAge: 0,
                maximumArchiveBatch: 31
            )
        )

        let producerHighWaterBeforeRetention = await store.database.metrics().maximumProducerEncodedBytesObserved
        let snapshot = await maintenance.runOnce(now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(snapshot.archivedSegments, 17)
        XCTAssertNil(snapshot.lastErrorCode)

        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.replayFloor, 506)
        XCTAssertEqual(metadata.nextGlobalSequence, 514)
        let live = try await store.events(after: nil, limit: 20)
        XCTAssertEqual(live.events.map(\.globalSequence), Array(507 ... 513).map(Int64.init))
        let retentionMetrics = await store.database.metrics()
        XCTAssertGreaterThan(
            retentionMetrics.maximumProducerEncodedBytesObserved,
            max(producerHighWaterBeforeRetention, 3 * SQLiteDatabaseExecutor.maximumBulkEncodedBytes)
        )
        let segments = try await store.database.query(
            "SELECT archive_id,first_sequence,last_sequence,event_count FROM event_archive_blobs ORDER BY first_sequence",
            operationClass: .bulk
        )
        XCTAssertEqual(segments.count, 17)
        XCTAssertEqual(segments.dropLast().map { $0.column("event_count")?.integer }, Array(repeating: 31, count: 16))
        XCTAssertEqual(segments.last?.column("event_count")?.integer, 10)
        XCTAssertEqual(segments.first?.column("first_sequence")?.integer, 1)
        XCTAssertEqual(segments.last?.column("last_sequence")?.integer, 506)
        var archivedSequences: [Int64] = []
        for segment in segments {
            let archiveID = try XCTUnwrap(
                segment.column("archive_id")?.string.flatMap(UUID.init(uuidString:))
            )
            archivedSequences.append(contentsOf: try await store.archivedEvents(archiveID: archiveID).map(\.globalSequence))
        }
        XCTAssertEqual(archivedSequences, Array(1 ... 506).map(Int64.init))

        let observation = await store.eventRetentionObservationForTesting()
        XCTAssertEqual(observation.candidateQueryCount, 17)
        XCTAssertEqual(observation.archiveMutationCount, 17)
        XCTAssertLessThanOrEqual(observation.maximumScannedRows, 31)
        XCTAssertLessThanOrEqual(observation.maximumMaterializedRows, 31)
        XCTAssertEqual(observation.totalScannedRows, 506)
        XCTAssertEqual(observation.totalMaterializedRows, 506)
        XCTAssertLessThanOrEqual(
            observation.maximumScannedEnvelopeBytes,
            SQLiteDatabaseExecutor.maximumBulkEncodedBytes
        )
        XCTAssertLessThanOrEqual(
            observation.maximumMaterializedEnvelopeBytes,
            SQLiteDatabaseExecutor.maximumBulkEncodedBytes
        )
        try await store.close()
    }

    func testRetentionUsesBulkLaneWithProviderPressureBackpressureFairnessAndCancellation() async throws {
        let store = try await SQLiteServiceStore.openForExecutorSaturationTesting(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: 12 * 1_048_576
        )
        let database = await store.database
        let projectID = UUID()
        let seedPayload = Data(("{\"data\":\"" + String(repeating: "s", count: 8 * 1_024) + "\"}").utf8)
        for _ in 0 ..< 96 {
            let event = try await store.persistServiceDiagnostic(
                projectID: projectID,
                actor: nil,
                correlationID: UUID(),
                payload: seedPayload
            )
            try await store.markEventOutboxDispatched(event.cursor)
        }

        let recorder = RetentionCompletionRecorder()
        await database.installTestCompletionObserver { recorder.append($0) }
        await database.suspendWorkerForTesting()
        let retention = Task {
            try await store.enforceEventRetention(
                policy: .init(minimumLiveEventCount: 0, minimumLiveAge: 0, maximumArchiveBatch: 32),
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }
        let startedAt = Date()
        let providerRuns = (0 ..< 16).map { index in
            Task {
                try await store.persistRun(.init(
                    runID: UUID(),
                    sessionID: UUID(),
                    provider: .codex,
                    providerSessionID: "retention-provider-\(index)",
                    state: "running",
                    generation: 1,
                    turnEpoch: 1,
                    startReason: "retention-pressure",
                    startedAt: startedAt
                ))
            }
        }
        let diagnosticPayload = Data(("{\"data\":\"" + String(repeating: "d", count: 32 * 1_024) + "\"}").utf8)
        let diagnostics = (0 ..< 16).map { _ in
            Task {
                try await store.persistServiceDiagnostic(
                    projectID: projectID,
                    actor: nil,
                    correlationID: UUID(),
                    payload: diagnosticPayload
                )
            }
        }

        let saturationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < saturationDeadline {
            let metrics = await database.metrics()
            if metrics.queuedByClass.values.reduce(0, +) == metrics.capacity,
               metrics.waitingByClass.values.reduce(0, +) > 0
            {
                break
            }
            await Task.yield()
        }
        let pressured = await database.metrics()
        XCTAssertEqual(pressured.queuedByClass.values.reduce(0, +), pressured.capacity)
        XCTAssertGreaterThan(pressured.waitingByClass.values.reduce(0, +), 0)
        XCTAssertGreaterThan(pressured.saturationCount, 0)
        XCTAssertLessThanOrEqual(
            pressured.maximumProducerEncodedBytesObserved,
            pressured.maximumProducerEncodedBytes
        )

        diagnostics[15].cancel()
        do {
            _ = try await diagnostics[15].value
            XCTFail("queued production diagnostic should observe cancellation")
        } catch is CancellationError {}

        await database.resumeWorkerForTesting()
        let archiveID = try await retention.value
        XCTAssertNotNil(archiveID)
        for run in providerRuns { try await run.value }
        for diagnostic in diagnostics.dropLast() { _ = try await diagnostic.value }

        let completions = recorder.values
        for operationClass in SQLiteOperationClass.allCases {
            let first = try XCTUnwrap(completions.firstIndex(of: operationClass))
            XCTAssertLessThanOrEqual(first, 8, "\(operationClass) must progress within the scheduler aging bound")
        }
        let observation = await store.eventRetentionObservationForTesting()
        XCTAssertLessThanOrEqual(observation.maximumScannedRows, 32)
        XCTAssertLessThanOrEqual(observation.maximumMaterializedRows, 32)
        XCTAssertLessThanOrEqual(
            observation.maximumMaterializedEnvelopeBytes,
            SQLiteDatabaseExecutor.maximumBulkEncodedBytes
        )
        let finished = await database.metrics()
        XCTAssertGreaterThan(
            finished.maximumProducerEncodedBytesObserved,
            SQLiteDatabaseExecutor.maximumBulkEncodedBytes
        )
        XCTAssertLessThanOrEqual(
            finished.maximumProducerEncodedBytesObserved,
            finished.maximumProducerEncodedBytes
        )
        XCTAssertEqual(finished.queuedEncodedBytes, 0)
        XCTAssertEqual(finished.waitingEncodedBytes, 0)
        XCTAssertEqual(finished.activeTransactionEncodedBytes, 0)
        try await store.close(clean: false)
    }

    func testCanceledRetentionAfterBeginPreservesLiveBytesFloorAndArchiveLedger() async throws {
        let gate = RetentionCancellationGate()
        let injector = PersistenceFaultInjector { point in
            if point == .beforeTransactionCommit { await gate.pauseIfArmed() }
        }
        let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: injector)
        addTeardownBlock { try? await store.close() }
        let projectID = UUID()
        for index in 0 ..< 8 {
            let event = try await store.persistServiceDiagnostic(
                projectID: projectID,
                actor: nil,
                correlationID: UUID(),
                payload: Data("{\"index\":\(index)}".utf8)
            )
            try await store.markEventOutboxDispatched(event.cursor)
        }
        let beforeRows = try await store.database.query(
            "SELECT global_sequence,envelope_json FROM events ORDER BY global_sequence",
            operationClass: .bulk
        )
        let completionBaseline = await store.database.metrics().completedByClass
        await gate.arm()
        let retention = Task {
            try await store.enforceEventRetention(
                policy: .init(minimumLiveEventCount: 0, minimumLiveAge: 0, maximumArchiveBatch: 4),
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }
        await gate.waitUntilPaused()
        retention.cancel()
        await gate.release()
        do {
            _ = try await retention.value
            XCTFail("canceled archive transaction unexpectedly committed")
        } catch is CancellationError {}

        let cancellationMetrics = await store.database.metrics()
        XCTAssertEqual(
            cancellationMetrics.completedByClass[.interactive],
            completionBaseline[.interactive]
        )
        XCTAssertGreaterThan(
            cancellationMetrics.completedByClass[.bulk, default: 0],
            completionBaseline[.bulk, default: 0]
        )
        let metadata = try await store.metadata()
        let afterRows = try await store.database.query(
            "SELECT global_sequence,envelope_json FROM events ORDER BY global_sequence",
            operationClass: .bulk
        )
        let archiveCount = try await store.database.query(
            "SELECT COUNT(*) AS count FROM event_archive_blobs",
            operationClass: .bulk
        ).first?.column("count")?.integer
        let checkpointCount = try await store.database.query(
            "SELECT COUNT(*) AS count FROM snapshot_checkpoints WHERE retention_class='pre_compaction'",
            operationClass: .bulk
        ).first?.column("count")?.integer
        XCTAssertEqual(metadata.replayFloor, 0)
        XCTAssertEqual(
            beforeRows.compactMap { $0.column("global_sequence")?.integer },
            afterRows.compactMap { $0.column("global_sequence")?.integer }
        )
        XCTAssertEqual(
            beforeRows.compactMap { $0.column("envelope_json")?.string },
            afterRows.compactMap { $0.column("envelope_json")?.string }
        )
        XCTAssertEqual(archiveCount, 0)
        XCTAssertEqual(checkpointCount, 0)
        try await store.close()
    }

    func testConcurrentRetentionRetriesStaleFloorWithoutDuplicateArchiveRanges() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        addTeardownBlock { try? await store.close() }
        let projectID = UUID()
        for index in 0 ..< 8 {
            let event = try await store.persistServiceDiagnostic(
                projectID: projectID,
                actor: nil,
                correlationID: UUID(),
                payload: Data("{\"index\":\(index)}".utf8)
            )
            try await store.markEventOutboxDispatched(event.cursor)
        }
        let database = await store.database
        await database.suspendWorkerForTesting()
        let first = Task {
            try await store.enforceEventRetention(
                policy: .init(minimumLiveEventCount: 0, minimumLiveAge: 0, maximumArchiveBatch: 4),
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }
        let second = Task {
            try await store.enforceEventRetention(
                policy: .init(minimumLiveEventCount: 0, minimumLiveAge: 0, maximumArchiveBatch: 4),
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }
        while await database.metrics().queuedByClass[.bulk, default: 0] < 2 {
            await Task.yield()
        }
        await database.resumeWorkerForTesting()
        let firstArchiveID = try await first.value
        let secondArchiveID = try await second.value
        let archiveIDs = [firstArchiveID, secondArchiveID].compactMap { $0 }
        XCTAssertEqual(Set(archiveIDs).count, 2)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.replayFloor, 8)
        let ranges = try await database.query(
            "SELECT first_sequence,last_sequence FROM event_archive_blobs ORDER BY first_sequence",
            operationClass: .bulk
        )
        XCTAssertEqual(ranges.compactMap { $0.column("first_sequence")?.integer }, [1, 5])
        XCTAssertEqual(ranges.compactMap { $0.column("last_sequence")?.integer }, [4, 8])
        try await store.close()
    }

    func testInvalidArchiveBatchFailsBeforeMutation() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        addTeardownBlock { try? await store.close() }
        _ = try await store.persistServiceDiagnostic(
            projectID: UUID(),
            actor: nil,
            correlationID: UUID(),
            payload: Data("{\"value\":1}".utf8)
        )
        do {
            _ = try await store.archiveEvents(through: 1, maximumBatch: 0)
            XCTFail("invalid archive batch unexpectedly mutated retention state")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        let metadata = try await store.metadata()
        let archiveCount = try await store.database.query(
            "SELECT COUNT(*) AS count FROM event_archive_blobs",
            operationClass: .bulk
        ).first?.column("count")?.integer
        XCTAssertEqual(metadata.replayFloor, 0)
        XCTAssertEqual(archiveCount, 0)
        try await store.close()
    }

    func testArchiveSegmentsAndProtectedCheckpointsAreImmutable() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(
            projectID: UUID(),
            name: "P",
            creator: actor,
            state: .active,
            roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)],
            revision: 1,
            cursor: cursor
        )
        let event = try await store.persistProject(
            project,
            eventType: .projectCreated,
            actor: actor,
            correlationID: UUID(),
            idempotency: nil
        )
        try await store.markEventOutboxDispatched(event.cursor)
        let optionalArchiveID = try await store.archiveEvents(through: 1)
        let archiveID = try XCTUnwrap(optionalArchiveID)
        let archived = try await store.archivedEvents(archiveID: archiveID)
        XCTAssertEqual(archived.count, 1)
        do {
            _ = try await store.database.query("UPDATE event_archive_blobs SET compression='invalid'")
            XCTFail("expected immutable archive trigger")
        } catch {}
        do {
            _ = try await store.database.query("DELETE FROM snapshot_checkpoints WHERE retention_class='pre_compaction'")
            XCTFail("expected protected checkpoint trigger")
        } catch {}
        let details = try await store.snapshotCheckpointDetails(scope: "events:\(cursor.storeID.uuidString):pre-compaction")
        XCTAssertEqual(details.map(\.retentionClass), ["pre_compaction"])
        try await store.close()
    }

    func testRestoreRequiresOneTimeActivationFence() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let prior = try await store.metadata().storeID
        let token = Data("restore-token".utf8)
        let fresh = try await store.prepareRestoredStore(
            from: prior,
            backupSequence: 0,
            digest: "backup-digest",
            activationToken: token
        )
        let preparedMetadata = try await store.metadata()
        XCTAssertEqual(preparedMetadata.activationState, "restore_prepared")
        do {
            _ = try await store.activateRestoredStore(activationToken: Data("wrong".utf8), instanceID: UUID())
            XCTFail("expected activation fence")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .quiescing)
        }
        let instanceID = UUID()
        let activated = try await store.activateRestoredStore(activationToken: token, instanceID: instanceID)
        XCTAssertEqual(activated, fresh)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.activationState, "active")
        XCTAssertEqual(metadata.activationInstanceID, instanceID)
        do {
            _ = try await store.activateRestoredStore(activationToken: token, instanceID: UUID())
            XCTFail("expected token to be single use")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .quiescing)
        }
        try await store.close()
    }

    func testOwnedResourceReservationsAndHealthAreDurable() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let externalID = UUID()
        let record = OwnedResourceRecord(
            kind: .artifact,
            externalID: externalID,
            internalPathIdentity: "/var/lib/repoprompt/artifacts/test",
            lifecycleState: .preparing,
            retentionDeadline: Date().addingTimeInterval(-1)
        )
        try await store.reserveOwnedResource(record)
        let prepared = try await store.transitionOwnedResource(
            resourceID: record.resourceID,
            expectedStates: [.preparing],
            to: .prepared,
            observedBytes: 4,
            contentDigest: "digest",
            cleanupError: nil
        )
        XCTAssertEqual(prepared.lifecycleState, .prepared)
        let fetched = try await store.ownedResource(externalID: externalID, kind: .artifact)
        XCTAssertEqual(fetched?.contentDigest, "digest")
        let health = try await store.ownedResourceHealth(now: Date())
        XCTAssertEqual(health.abandonedReservations, 1)
        try await store.close()
    }

    func testMutationDrainStopsAdmissionAndWaitsForAcceptedMutation() async throws {
        let controller = AuthorityMutationGate()
        let capability = await controller.capability()
        let mutation = Task {
            try await capability.perform {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let drainTask = Task { await controller.drain(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(30))
        do {
            _ = try await capability.perform { true }
            XCTFail("stale capability unexpectedly admitted during drain")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        }
        try await mutation.value
        let snapshot = await drainTask.value
        XCTAssertFalse(snapshot.drainTimedOut)
        XCTAssertEqual(snapshot.inFlightMutations, 0)
        XCTAssertFalse(snapshot.acceptingMutations)
    }

    func testMutationDrainHasHardDeadline() async {
        let controller = AuthorityMutationGate()
        let capability = await controller.capability()
        let mutation = Task {
            try await capability.perform {
                try await Task.sleep(for: .seconds(1))
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let started = Date()
        let snapshot = await controller.drain(timeout: .milliseconds(50))
        XCTAssertTrue(snapshot.drainTimedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        mutation.cancel()
        _ = try? await mutation.value
    }

    func testSessionEventCounterSurvivesArchiveDeletion() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectID = UUID()
        let roots = [ProjectRootSnapshot(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)]
        let sessionID = UUID()
        for revision in 1 ... 3 {
            let cursor = try await store.nextCursor()
            let session = SessionSnapshot(
                sessionID: sessionID,
                projectID: projectID,
                parentSessionID: nil,
                rootSessionID: sessionID,
                creator: actor,
                provider: .codex,
                model: nil,
                visibility: .privateSession,
                state: .running,
                runGeneration: 1,
                turnEpoch: 1,
                revision: Int64(revision),
                transcript: [],
                interactions: [],
                cursor: cursor
            )
            if revision == 1 {
                let project = ProjectSnapshot(projectID: projectID, name: "P", creator: actor, state: .active, roots: roots, revision: 1, cursor: cursor)
                _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
            }
            let sessionCursor = try await store.nextCursor()
            let persisted = SessionSnapshot(
                sessionID: session.sessionID,
                projectID: session.projectID,
                parentSessionID: nil,
                rootSessionID: sessionID,
                creator: actor,
                provider: .codex,
                model: nil,
                visibility: .privateSession,
                state: .running,
                runGeneration: 1,
                turnEpoch: 1,
                revision: Int64(revision),
                transcript: [],
                interactions: [],
                cursor: sessionCursor
            )
            _ = try await store.persistSession(persisted, eventType: .sessionResumed, actor: actor, correlationID: UUID(), idempotency: nil)
        }
        _ = try await store.archiveEvents(through: 3)
        let counter = try await store.database.query(
            "SELECT event_count FROM session_event_counters WHERE session_id=?",
            [.text(sessionID.uuidString)]
        ).first?.column("event_count")?.integer
        XCTAssertEqual(counter, 3)
        try await store.close()
    }

    func testTransactionGateSerializesConcurrentOwnedResourceReservations() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 50 {
                group.addTask {
                    try await store.reserveOwnedResource(OwnedResourceRecord(
                        kind: .artifactTemporary,
                        externalID: UUID(),
                        internalPathIdentity: "/tmp/repoprompt-transaction-gate-\(index)",
                        lifecycleState: .preparing
                    ))
                }
            }
            try await group.waitForAll()
        }
        let resources = try await store.ownedResources(states: nil)
        XCTAssertEqual(resources.count, 50)
        try await store.close()
    }
}

private actor RetentionCancellationGate {
    private var armed = false
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        paused = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        while !paused { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class RetentionCompletionRecorder: @unchecked Sendable {
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
