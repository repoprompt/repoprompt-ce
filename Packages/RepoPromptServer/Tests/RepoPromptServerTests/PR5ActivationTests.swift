import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptMCPAdapter
import RepoPromptRuntimeModel
import RepoPromptServiceProtocol
import RepoPromptShared
import RepoPromptWorkspaceRuntimeCore
import XCTest
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@_spi(Testing) import RepoPromptHeadlessRuntime
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

private struct PR5InjectedFailure: Error {}

private actor PR5ArmedPersistenceFault {
    private var point: PersistenceFaultPoint?

    func arm(_ point: PersistenceFaultPoint) { self.point = point }

    func hit(_ observed: PersistenceFaultPoint) throws {
        guard observed == point else { return }
        point = nil
        throw PR5InjectedFailure()
    }
}

private actor PR5NthPersistenceFault {
    private var point: PersistenceFaultPoint?
    private var targetOccurrence = 0
    private var observedOccurrences = 0
    private var prerequisite: PersistenceFaultPoint?
    private var prerequisiteObserved = false

    func arm(
        _ point: PersistenceFaultPoint,
        occurrence: Int = 1,
        after prerequisite: PersistenceFaultPoint? = nil
    ) {
        self.point = point
        targetOccurrence = occurrence
        observedOccurrences = 0
        self.prerequisite = prerequisite
        prerequisiteObserved = prerequisite == nil
    }

    func hit(_ observed: PersistenceFaultPoint) throws {
        if observed == prerequisite { prerequisiteObserved = true }
        guard prerequisiteObserved, observed == point else { return }
        observedOccurrences += 1
        guard observedOccurrences == targetOccurrence else { return }
        point = nil
        throw PR5InjectedFailure()
    }
}

private actor PR5PostCommitGate {
    private var paused = false
    private var released = false

    func pause() async {
        paused = true
        while !released { await Task.yield() }
    }

    func waitUntilPaused() async {
        while !paused { await Task.yield() }
    }

    func release() {
        released = true
    }
}

private enum PR5TestSupport {
    static let actor = ExternalActor(userID: "pr5-user", username: "pr5", displayName: "PR5")

    static func persistProject(
        in store: SQLiteServiceStore,
        name: String = "PR5"
    ) async throws -> EventEnvelope {
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(
            projectID: UUID(),
            name: name,
            creator: actor,
            state: .active,
            roots: [],
            revision: 1,
            cursor: cursor
        )
        return try await store.persistProject(
            project,
            eventType: .projectCreated,
            actor: actor,
            correlationID: UUID(),
            idempotency: nil
        )
    }

    static func event(storeID: UUID, sequence: Int64, projectID: UUID = UUID()) -> EventEnvelope {
        EventEnvelope(
            eventID: UUID(),
            storeID: storeID,
            globalSequence: sequence,
            timestamp: Date(),
            projectID: projectID,
            sessionID: nil,
            agentID: nil,
            parentAgentID: nil,
            rootSessionID: nil,
            runID: nil,
            sessionSequence: nil,
            eventType: .sessionUpdated,
            generation: nil,
            turnEpoch: nil,
            actor: nil,
            correlationID: UUID(),
            causationID: nil,
            payload: .init(object: [:]),
            digest: "d\(sequence)",
            keyID: "test",
            signature: "s\(sequence)"
        )
    }

    static func makeAuthority(
        store: SQLiteServiceStore,
        dispatcher: any AgentProviderDispatcher,
        hooks: RepoPromptHeadlessAuthorityHooks = .none
    ) async throws -> (RepoPromptHeadlessAuthority, SessionSnapshot, URL) {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: dispatcher, hooks: hooks)
        let project = try await authority.createProject(
            input: .init(name: "PR5", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "pr5-project-\(UUID().uuidString)",
            requestDigest: "pr5-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "pr5-session-\(UUID().uuidString)",
            requestDigest: "pr5-session"
        )
        return (authority, session, root)
    }
}

final class SchemaV8MigrationTests: XCTestCase {
    func testFreshStoreActivatesSchemaV8AndAllImmutableTables() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 9)
        let names = try await store.database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('authority_transitions','provider_event_receipts','event_outbox','idempotency_tombstones') ORDER BY name"
        ).compactMap { $0.column("name")?.string }
        XCTAssertEqual(names, [
            "authority_transitions",
            "event_outbox",
            "idempotency_tombstones",
            "provider_event_receipts",
        ])
        let ledger = try await store.database.query(
            "SELECT digest FROM schema_migrations WHERE version=8"
        ).first?.column("digest")?.string
        XCTAssertEqual(ledger, SchemaV8.canonicalDigest)
    }
}

final class AuthorityTransitionFaultInjectionTests: XCTestCase {
    func testStartReservationRollsBackEverySharedLifecycleTransactionBoundaryBeforeProviderLaunch() async throws {
        let points: [PersistenceFaultPoint] = [
            .afterAuthorityStateCAS,
            .afterAuthorityRunWrite,
            .afterAuthorityTransitionWrite,
            .afterAuthorityPresentationWrite,
            .afterAuthoritySessionWrite,
            .afterAuthorityAgentWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ]
        for point in points {
            let armed = PR5ArmedPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await armed.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .held)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            await armed.arm(point)

            do {
                _ = try await authority.execute(
                    command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                    sessionID: session.sessionID,
                    externalActor: PR5TestSupport.actor,
                    idempotencyKey: "start-boundary-\(point.rawValue)",
                    requestDigest: "start-boundary"
                )
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}

            let persistedRun = try await store.latestRun(sessionID: session.sessionID)
            let persistedSession = try await store.session(id: session.sessionID)
            let transitions = try await store.nonfinalAuthorityTransitions()
            let executionCalls = await provider.executionCallCount()
            let persistedEventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let persistedOutboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            XCTAssertNil(persistedRun)
            XCTAssertEqual(persistedSession?.state, session.state)
            XCTAssertTrue(transitions.isEmpty)
            XCTAssertEqual(executionCalls, 0)
            XCTAssertEqual(persistedEventCount, eventCount)
            XCTAssertEqual(persistedOutboxCount, outboxCount)
            try await store.close()
        }
    }

    func testCancelTransitionRollsBackEverySharedLifecycleTransactionBoundary() async throws {
        let points: [PersistenceFaultPoint] = [
            .afterAuthorityStateCAS,
            .afterAuthorityRunWrite,
            .afterAuthorityTransitionWrite,
            .afterAuthorityPresentationWrite,
            .afterAuthoritySessionWrite,
            .afterAuthorityAgentWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ]
        for point in points {
            let armed = PR5ArmedPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await armed.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .held)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "boundary-start-\(point.rawValue)",
                requestDigest: "boundary-start"
            )
            let latestRun = try await store.latestRun(sessionID: session.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let transitionCount = try await store.database.query("SELECT COUNT(*) AS value FROM authority_transitions").first?.column("value")?.integer

            await armed.arm(point)
            do {
                _ = try await authority.execute(
                    command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
                    sessionID: session.sessionID,
                    externalActor: PR5TestSupport.actor,
                    idempotencyKey: "boundary-cancel-\(point.rawValue)",
                    requestDigest: "boundary-cancel"
                )
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}

            let persistedRun = try await store.latestRun(sessionID: session.sessionID)
            let persistedSession = try await store.session(id: session.sessionID)
            let persistedEventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let persistedOutboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let persistedTransitionCount = try await store.database.query("SELECT COUNT(*) AS value FROM authority_transitions").first?.column("value")?.integer
            let cancelCallCount = await provider.cancelCallCount()
            XCTAssertEqual(persistedRun?.state, "running")
            XCTAssertEqual(persistedSession?.state, .running)
            XCTAssertEqual(persistedEventCount, eventCount)
            XCTAssertEqual(persistedOutboxCount, outboxCount)
            XCTAssertEqual(persistedTransitionCount, transitionCount)
            XCTAssertEqual(cancelCallCount, 0, "Provider side effect ran despite rollback at \(point.rawValue)")
            await provider.abandon(run.runID)
            await authority.waitForProviderRunsToSettle()
            try await store.close()
        }
    }

    func testCompleteFinalizationFaultsBecomeDurablyReconcilingAcrossEverySharedBoundary() async throws {
        let points: [PersistenceFaultPoint] = [
            .afterAuthorityStateCAS,
            .afterAuthorityRunWrite,
            .afterAuthorityTransitionWrite,
            .afterAuthorityPresentationWrite,
            .afterAuthoritySessionWrite,
            .afterAuthorityAgentWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ]
        for point in points {
            let fault = PR5NthPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await fault.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .terminalHeld)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "complete-start-\(point.rawValue)",
                requestDigest: "complete-start"
            )
            let latestRun = try await store.latestRun(sessionID: session.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            await fault.arm(point)
            await provider.complete(run.runID)
            await authority.waitForProviderRunsToSettle()

            let persistedRun = try await store.latestRun(sessionID: session.sessionID)
            let transitions = try await store.nonfinalAuthorityTransitions()
            let finalizedComplete = try await store.database.query(
                "SELECT COUNT(*) AS value FROM authority_transitions WHERE run_id=? AND kind='complete' AND state='finalized'",
                [.text(run.runID.uuidString)]
            ).first?.column("value")?.integer
            XCTAssertEqual(persistedRun?.state, "reconciliationRequired", "boundary \(point.rawValue)")
            XCTAssertEqual(transitions.last?.state, .reconciliationRequired, "boundary \(point.rawValue)")
            XCTAssertEqual(finalizedComplete, 0, "boundary \(point.rawValue)")
            try await store.close()
        }
    }

    func testFailFinalizationFaultsBecomeDurablyReconcilingAcrossEverySharedBoundary() async throws {
        let points: [PersistenceFaultPoint] = [
            .afterAuthorityStateCAS,
            .afterAuthorityRunWrite,
            .afterAuthorityTransitionWrite,
            .afterAuthorityPresentationWrite,
            .afterAuthoritySessionWrite,
            .afterAuthorityAgentWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ]
        for point in points {
            let fault = PR5NthPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await fault.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .failureHeld)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "fail-start-\(point.rawValue)",
                requestDigest: "fail-start"
            )
            let latestRun = try await store.latestRun(sessionID: session.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            switch point {
            case .afterEventInsertBeforeOutboxInsert,
                 .afterOutboxInsertBeforeSequenceAdvance:
                await fault.arm(point, occurrence: 2)
            case .beforeTransactionCommit:
                await fault.arm(point, after: .afterAuthorityAgentWrite)
            default:
                await fault.arm(point)
            }
            await provider.fail(run.runID)
            await authority.waitForProviderRunsToSettle()

            let persistedRun = try await store.latestRun(sessionID: session.sessionID)
            let transitions = try await store.nonfinalAuthorityTransitions()
            let finalizedFail = try await store.database.query(
                "SELECT COUNT(*) AS value FROM authority_transitions WHERE run_id=? AND kind='fail' AND state='finalized'",
                [.text(run.runID.uuidString)]
            ).first?.column("value")?.integer
            XCTAssertEqual(persistedRun?.state, "reconciliationRequired", "boundary \(point.rawValue)")
            XCTAssertEqual(transitions.last?.state, .reconciliationRequired, "boundary \(point.rawValue)")
            XCTAssertEqual(finalizedFail, 0, "boundary \(point.rawValue)")
            try await store.close()
        }
    }

    func testEventAndPendingOutboxRollbackTogetherAtEveryNewCrashBoundary() async throws {
        for point in [
            PersistenceFaultPoint.afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
        ] {
            let injector = PersistenceFaultInjector { observed in
                if observed == point { throw PR5InjectedFailure() }
            }
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: injector)
            do {
                _ = try await PR5TestSupport.persistProject(in: store)
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}

            let metadata = try await store.metadata()
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events")
                .first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox")
                .first?.column("value")?.integer
            let projectCount = try await store.database.query("SELECT COUNT(*) AS value FROM projects")
                .first?.column("value")?.integer
            XCTAssertEqual(metadata.nextGlobalSequence, 1)
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(outboxCount, 0)
            XCTAssertEqual(projectCount, 0)
            try await store.close()
        }
    }
}

final class ProviderEventAtomicityTests: XCTestCase {
    func testReceiptProjectionEventAndOutboxRollbackAsOneUnitAtEveryFrameBoundary() async throws {
        for point in [
            PersistenceFaultPoint.afterProviderEventReceiptInsert,
            .afterProviderSessionWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ] {
            let armed = PR5ArmedPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await armed.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .held)
            let (authority, created, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: created.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "atomic-\(point.rawValue)", requestDigest: "atomic")
            let latestRun = try await store.latestRun(sessionID: created.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            let storedBefore = try await store.session(id: created.sessionID)
            let before = try XCTUnwrap(storedBefore)
            let entry = TranscriptEntry(entryID: UUID(), sessionSequence: (before.transcript.map(\.sessionSequence).max() ?? 0) + 1, kind: .assistant, content: "atomic", actor: nil, timestamp: Date())
            let proposed = before.replacing(revision: before.revision + 1, transcript: before.transcript + [entry])
            let identity = ProviderEventIdentity(runID: run.runID, providerEventID: "atomic-frame", payloadDigest: "digest", generation: run.generation, turnEpoch: run.turnEpoch, eventKind: "assistantFinal", connectionGeneration: 1, providerSequence: 2)
            let mutation = ProviderEventMutation(identity: identity, sessionEvent: .init(snapshot: proposed, eventType: .transcriptMessage, correlationID: UUID()))
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            await armed.arm(point)
            do {
                _ = try await store.applyProviderEvent(mutation)
                XCTFail("Expected injected provider-frame failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}
            let receiptCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM provider_event_receipts WHERE provider_event_id='atomic-frame'").first?.column("value")?.integer
            let eventCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let sessionAfterFailure = try await store.session(id: created.sessionID)
            XCTAssertEqual(receiptCountAfterFailure, 0)
            XCTAssertEqual(eventCountAfterFailure, eventCount)
            XCTAssertEqual(outboxCountAfterFailure, outboxCount)
            XCTAssertEqual(sessionAfterFailure?.revision, before.revision)
            let retried = try await store.applyProviderEvent(mutation)
            XCTAssertTrue(retried.applied)
            await provider.abandon(run.runID)
            await authority.waitForProviderRunsToSettle()
            try await store.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testExactReplayIsNoOpWhileIdenticalPayloadAtNextSequenceIsDistinctAndGapsFail() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .held)
        let (authority, created, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: created.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "sequence", requestDigest: "sequence")
        let latestRun = try await store.latestRun(sessionID: created.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        let storedBase = try await store.session(id: created.sessionID)
        let base = try XCTUnwrap(storedBase)
        func mutation(sequence: Int64, eventID: String, digest: String = "same") -> ProviderEventMutation {
            let entry = TranscriptEntry(entryID: UUID(), sessionSequence: sequence, kind: .assistant, content: "same", actor: nil, timestamp: Date())
            let snapshot = base.replacing(revision: base.revision + sequence - 1, transcript: base.transcript + [entry])
            return ProviderEventMutation(identity: .init(runID: run.runID, providerEventID: eventID, payloadDigest: digest, generation: run.generation, turnEpoch: run.turnEpoch, eventKind: "assistantFinal", connectionGeneration: 1, providerSequence: sequence), sessionEvent: .init(snapshot: snapshot, eventType: .transcriptMessage, correlationID: UUID()))
        }
        let second = mutation(sequence: 2, eventID: "two")
        let applied = try await store.applyProviderEvent(second)
        let duplicate = try await store.applyProviderEvent(second)
        XCTAssertTrue(applied.applied)
        XCTAssertFalse(duplicate.applied)
        do {
            _ = try await store.applyProviderEvent(mutation(sequence: 4, eventID: "four"))
            XCTFail("Expected sequence gap")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .dependencyUnavailable) }
        do {
            _ = try await store.applyProviderEvent(mutation(sequence: 2, eventID: "two", digest: "different"))
            XCTFail("Expected provider identity conflict")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .idempotencyConflict) }
        let third = try await store.applyProviderEvent(mutation(sequence: 3, eventID: "three"))
        let reconnected = ProviderEventMutation(identity: .init(
            runID: run.runID,
            providerEventID: "two",
            payloadDigest: "reconnected",
            generation: run.generation,
            turnEpoch: run.turnEpoch,
            eventKind: "progress",
            connectionGeneration: 2,
            providerSequence: 1
        ))
        let reconnectResult = try await store.applyProviderEvent(reconnected)
        let receiptCount = try await store.database.query("SELECT COUNT(*) AS value FROM provider_event_receipts WHERE run_id=?", [.text(run.runID.uuidString)]).first?.column("value")?.integer
        XCTAssertTrue(third.applied)
        XCTAssertTrue(reconnectResult.applied)
        XCTAssertEqual(receiptCount, 4)
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()
        try await store.close()
    }
}

private actor PR5FailOnceHook {
    private var pending = true

    func hit(_: EventEnvelope) throws {
        if pending {
            pending = false
            throw PR5InjectedFailure()
        }
    }
}

private actor PR5PublishedSequenceRecorder {
    private var sequences: [Int64] = []

    func record(_ event: EventEnvelope) {
        sequences.append(event.globalSequence)
    }

    func values() -> [Int64] {
        sequences
    }
}

final class OrderedEventOutboxTests: XCTestCase {
    func testPublishMarkCrashRedeliversNWithoutBypassingNPlusOneOrDuplicatingConsumer() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let first = try await PR5TestSupport.persistProject(in: store, name: "N")
        let second = try await PR5TestSupport.persistProject(in: store, name: "N+1")
        let hub = ServiceEventHub(subscriberBufferLimit: 8)
        let stream = await hub.subscribe(consumer: .sse)
        let failOnce = PR5FailOnceHook()
        let dispatcher = OrderedEventOutboxDispatcher(
            store: store,
            hub: hub,
            hooks: .init(afterPublishBeforeDispatchedMarker: { event in
                try await failOnce.hit(event)
            })
        )

        do {
            try await dispatcher.drainStartupWatermark(second.cursor)
            XCTFail("Expected simulated crash after publish and before marker")
        } catch is PR5InjectedFailure {}
        let statesAfterCrash = try await store.database.query(
            "SELECT global_sequence,state,dispatch_attempt_count FROM event_outbox ORDER BY global_sequence"
        )
        XCTAssertEqual(statesAfterCrash.map { $0.column("state")?.string }, ["pending", "pending"])
        XCTAssertEqual(statesAfterCrash.map { $0.column("dispatch_attempt_count")?.integer }, [1, 0])

        var firstIterator = stream.makeAsyncIterator()
        let deliveredBeforeCrash = try await firstIterator.next()
        XCTAssertEqual(deliveredBeforeCrash?.globalSequence, first.globalSequence)
        await hub.finish()

        // Recreate both host-owned components. The client reconnects from its
        // greatest applied cursor, so redelivered N is suppressed while N+1 is
        // delivered only after N's marker commits.
        let restartedHub = ServiceEventHub(subscriberBufferLimit: 8)
        let restartedStream = await restartedHub.subscribe(
            consumer: .sse,
            after: deliveredBeforeCrash?.cursor
        )
        let restartedDispatcher = OrderedEventOutboxDispatcher(
            store: store,
            hub: restartedHub
        )
        try await restartedDispatcher.drainStartupWatermark(first.cursor)
        let statesAfterBoundedDrain = try await store.database.query(
            "SELECT global_sequence,state,dispatch_attempt_count FROM event_outbox ORDER BY global_sequence"
        )
        XCTAssertEqual(statesAfterBoundedDrain.map { $0.column("state")?.string }, ["dispatched", "pending"])
        XCTAssertEqual(statesAfterBoundedDrain.map { $0.column("dispatch_attempt_count")?.integer }, [2, 0])

        try await restartedDispatcher.drainStartupWatermark(second.cursor)
        await restartedHub.finish()
        var restartedIterator = restartedStream.makeAsyncIterator()
        let deliveredAfterRestart = try await restartedIterator.next()
        let exhausted = try await restartedIterator.next()
        XCTAssertEqual(deliveredAfterRestart?.globalSequence, second.globalSequence)
        XCTAssertNil(exhausted)
        let states = try await store.database.query(
            "SELECT state FROM event_outbox ORDER BY global_sequence"
        ).compactMap { $0.column("state")?.string }
        XCTAssertEqual(states, ["dispatched", "dispatched"])
        try await store.close()
    }

    func testStopCancelsWorkerBeforeSingleOwnerDrain() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        var expected: [Int64] = []
        for index in 0 ..< 32 {
            let event = try await PR5TestSupport.persistProject(in: store, name: "stop-\(index)")
            expected.append(event.globalSequence)
        }
        let recorder = PR5PublishedSequenceRecorder()
        let dispatcher = OrderedEventOutboxDispatcher(
            store: store,
            hub: ServiceEventHub(subscriberBufferLimit: 64),
            batchLimit: 4,
            hooks: .init(afterPublishBeforeDispatchedMarker: { event in
                await recorder.record(event)
            })
        )

        await dispatcher.start()
        await dispatcher.stop(drain: true)

        let recorded = await recorder.values()
        XCTAssertEqual(recorded, expected)
        let states = try await store.database.query(
            "SELECT state FROM event_outbox ORDER BY global_sequence"
        ).compactMap { $0.column("state")?.string }
        XCTAssertEqual(states, Array(repeating: "dispatched", count: expected.count))
        try await store.close()
    }

    func testPendingOutboxRowIsHardRetentionFloorAndDispatchedPrefixCanArchive() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let event = try await PR5TestSupport.persistProject(in: store)
        let pendingArchive = try await store.archiveEvents(through: event.globalSequence)
        let pendingEvents = try await store.events(after: nil, limit: 10).events
        XCTAssertNil(pendingArchive)
        XCTAssertEqual(pendingEvents.count, 1)

        try await store.markEventOutboxDispatched(event.cursor)
        let dispatchedArchive = try await store.archiveEvents(through: event.globalSequence)
        let remainingEvents = try await store.events(after: nil, limit: 10).events
        XCTAssertNotNil(dispatchedArchive)
        XCTAssertTrue(remainingEvents.isEmpty)
        let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox")
            .first?.column("value")?.integer
        XCTAssertEqual(outboxCount, 0)
        try await store.close()
    }
}

final class EventConsumerDedupeContractTests: XCTestCase {
    func testNamedRegistryGuardsActualConsumersAcrossDispatcherAndHubRestart() async throws {
        let registrations = ServiceEventConsumerRegistry.registrations
        XCTAssertEqual(Set(registrations.map(\.kind)), Set(ServiceEventConsumerKind.allCases))
        XCTAssertEqual(registrations.first(where: { $0.kind == .sse })?.deliveryMode, .cursorGatedLive)
        XCTAssertEqual(registrations.first(where: { $0.kind == .portal })?.deliveryMode, .absent)
        XCTAssertEqual(registrations.first(where: { $0.kind == .mcpNotification })?.deliveryMode, .absent)
        XCTAssertEqual(registrations.first(where: { $0.kind == .counter })?.deliveryMode, .durableQuery)
        XCTAssertEqual(registrations.first(where: { $0.kind == .projection })?.deliveryMode, .durableQuery)

        for kind in ServiceEventConsumerKind.allCases where kind != .sse {
            let rejected = await ServiceEventHub().subscribe(consumer: kind)
            var iterator = rejected.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("Expected non-live consumer registration rejection for \(kind.rawValue)")
            } catch let error as ServiceAPIError {
                XCTAssertEqual(error.code, .capabilityMissing)
            }
        }

        let storeID = UUID()
        let duplicate = PR5TestSupport.event(storeID: storeID, sequence: 1)
        let firstHub = ServiceEventHub(subscriberBufferLimit: 4)
        let firstStream = await firstHub.subscribe(consumer: .sse)
        await firstHub.publish(duplicate)
        var firstIterator = firstStream.makeAsyncIterator()
        let firstDelivery = try await firstIterator.next()
        XCTAssertEqual(firstDelivery?.cursor, duplicate.cursor)
        await firstHub.finish()

        // Crash after publish/before the outbox marker: a new dispatcher and hub
        // redeliver sequence 1, while the reconnect cursor suppresses it.
        let restartedHub = ServiceEventHub(subscriberBufferLimit: 4)
        let restartedStream = await restartedHub.subscribe(consumer: .sse, after: duplicate.cursor)
        await restartedHub.publish(duplicate)
        let next = PR5TestSupport.event(storeID: storeID, sequence: 2, projectID: duplicate.projectID)
        await restartedHub.publish(next)
        await restartedHub.finish()
        var restartedIterator = restartedStream.makeAsyncIterator()
        let restartedDelivery = try await restartedIterator.next()
        let restartedExhaustion = try await restartedIterator.next()
        XCTAssertEqual(restartedDelivery?.cursor, next.cursor)
        XCTAssertNil(restartedExhaustion)
    }

    func testGateRejectsDuplicateAndStoreChangeUntilExplicitResnapshot() {
        let firstStore = UUID()
        let secondStore = UUID()
        var gate = EventDeliveryCursorGate()
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 1)))
        XCTAssertFalse(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 1)))
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 2)))
        XCTAssertFalse(gate.shouldDeliver(.init(storeID: secondStore, globalSequence: 1)))
        XCTAssertEqual(gate.greatestDelivered, .init(storeID: firstStore, globalSequence: 2))
        gate.resetForNewStore(.init(storeID: secondStore, globalSequence: 0))
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: secondStore, globalSequence: 1)))
    }
}

final class EventReplayLiveRaceTests: XCTestCase {
    func testRegisterFirstLiveGateDropsReplayOverlapAndPreservesNextSequence() async throws {
        let storeID = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 8)
        let stream = await hub.subscribe(consumer: .sse, after: .init(storeID: storeID, globalSequence: 10))
        let replayOverlap = PR5TestSupport.event(storeID: storeID, sequence: 10)
        let live = PR5TestSupport.event(
            storeID: storeID,
            sequence: 11,
            projectID: replayOverlap.projectID
        )
        await hub.publish(replayOverlap)
        await hub.publish(live)
        await hub.finish()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let exhausted = try await iterator.next()
        XCTAssertEqual(first?.globalSequence, 11)
        XCTAssertNil(exhausted)
    }

    func testSlowSubscriberTerminatesWithLastSafeCursor() async throws {
        let storeID = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 1)
        let stream = await hub.subscribe(consumer: .sse)
        await hub.publish(PR5TestSupport.event(storeID: storeID, sequence: 1))
        await hub.publish(PR5TestSupport.event(storeID: storeID, sequence: 2))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.globalSequence, 1)
        do {
            _ = try await iterator.next()
            XCTFail("Expected slow-consumer termination")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertEqual(error.cursor, .init(storeID: storeID, globalSequence: 1))
        }
    }

    func testStoreIdentityChangeTerminatesRegisteredConsumer() async throws {
        let firstStore = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 2)
        let stream = await hub.subscribe(consumer: .sse, after: .init(storeID: firstStore, globalSequence: 4))
        await hub.publish(PR5TestSupport.event(storeID: UUID(), sequence: 1))
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected resnapshot requirement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
            XCTAssertEqual(error.cursor, .init(storeID: firstStore, globalSequence: 4))
        }
    }
}

final class MCPInvocationIdentityContractTests: XCTestCase {
    func testJSONRPCIdentityNeverSynthesizesDurableApplicationInvocation() {
        let identity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(1),
            connectionID: UUID().uuidString,
            connectionGeneration: 1,
            requestOrdinal: 1
        )
        XCTAssertNil(identity.appInvocationID)

        let appInvocationID = UUID().uuidString.lowercased()
        let explicit = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(1),
            connectionID: UUID().uuidString,
            connectionGeneration: 1,
            appInvocationID: appInvocationID,
            requestOrdinal: 1
        )
        XCTAssertEqual(explicit.appInvocationID, appInvocationID)
        let binding = AuthorityMCPBinding(
            sessionID: UUID(),
            actor: PR5TestSupport.actor,
            appInvocationID: explicit.appInvocationID
        )
        XCTAssertEqual(binding.appInvocationID, appInvocationID)
    }

    func testTransportMetadataPreservesHostIdentityAcrossReconnectAndIsolatesReusedJSONRPCID() throws {
        let sessionID = UUID()
        let base = AuthorityMCPBinding(sessionID: sessionID, actor: PR5TestSupport.actor)
        let firstAppInvocationID = UUID().uuidString.lowercased()
        let secondAppInvocationID = UUID().uuidString.lowercased()
        let sharedJSONRPCID = JSONRPCBridgeID.number(7)
        let firstConnection = MCPRequestTimelineIdentity(
            jsonRPCRequestID: sharedJSONRPCID,
            connectionID: "connection-a",
            connectionGeneration: 1,
            requestOrdinal: 8
        )
        let reconnected = MCPRequestTimelineIdentity(
            jsonRPCRequestID: sharedJSONRPCID,
            connectionID: "connection-b",
            connectionGeneration: 2,
            requestOrdinal: 1
        )
        let reusedJSONRPCID = MCPRequestTimelineIdentity(
            jsonRPCRequestID: sharedJSONRPCID,
            connectionID: "connection-b",
            connectionGeneration: 2,
            requestOrdinal: 2
        )
        let first = try RepoPromptMCPStdioExecution.requestTimelineIdentity(
            metadataAppInvocationID: firstAppInvocationID.uppercased(),
            inherited: firstConnection
        )
        let replay = try RepoPromptMCPStdioExecution.requestTimelineIdentity(
            metadataAppInvocationID: firstAppInvocationID,
            inherited: reconnected
        )
        let fresh = try RepoPromptMCPStdioExecution.requestTimelineIdentity(
            metadataAppInvocationID: secondAppInvocationID,
            inherited: reusedJSONRPCID
        )

        XCTAssertEqual(first?.connectionID, "connection-a")
        XCTAssertEqual(replay?.connectionID, "connection-b")
        XCTAssertEqual(
            RepoPromptMCPStdioExecution.invocationBinding(base, timelineIdentity: first).appInvocationID,
            firstAppInvocationID
        )
        XCTAssertEqual(
            RepoPromptMCPStdioExecution.invocationBinding(base, timelineIdentity: replay).appInvocationID,
            firstAppInvocationID
        )
        XCTAssertEqual(
            RepoPromptMCPStdioExecution.invocationBinding(base, timelineIdentity: fresh).appInvocationID,
            secondAppInvocationID
        )
        let staleServingBinding = base.withAppInvocationID(firstAppInvocationID)
        XCTAssertNil(
            RepoPromptMCPStdioExecution.invocationBinding(
                staleServingBinding,
                timelineIdentity: nil
            ).appInvocationID
        )
        let direct = try DirectHeadlessMCPService.requestTimelineIdentity(
            metadataAppInvocationID: firstAppInvocationID,
            inherited: reconnected
        )
        XCTAssertEqual(direct, replay)
        XCTAssertNil(try RepoPromptMCPStdioExecution.requestTimelineIdentity(
            metadataAppInvocationID: nil,
            inherited: nil
        ))
        XCTAssertThrowsError(try RepoPromptMCPStdioExecution.requestTimelineIdentity(
            metadataAppInvocationID: "not-a-uuid",
            inherited: firstConnection
        ))
    }

    func testMissingHostIdentityRejectsLifecycleBeforeToolReservation() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .immediate)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await RepoPromptAuthorityMCPService.admitted(
            authority: authority,
            portalSettings: PortalDesktopSettingsService(store: store),
            admissionGate: AuthorityMutationGate()
        )
        let arguments = try JSONSerialization.data(
            withJSONObject: ["op": "start", "message": "must not reserve"],
            options: [.sortedKeys]
        )
        do {
            _ = try await service.invoke(
                toolName: "agent_run",
                argumentsJSON: arguments,
                binding: .init(sessionID: session.sessionID, actor: PR5TestSupport.actor)
            )
            XCTFail("Expected missing durable invocation identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyRequired)
        }
        let toolStarts = try await authority.events(after: nil, limit: 100).events
            .count(where: { $0.eventType == .toolStarted })
        XCTAssertEqual(toolStarts, 0)
        let transitions = try await store.nonfinalAuthorityTransitions()
        let executionCalls = await provider.executionCallCount()
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertEqual(executionCalls, 0)
        try await store.close()
    }
}

private actor PR5ProviderDispatcher: AgentProviderDispatcher {
    enum Mode {
        case immediate
        case held
        case launchHeld
        case terminalHeld
        case failureHeld
        case cancelAmbiguous
        case cancelRacingCompletion
    }

    private let mode: Mode
    private var active: Set<UUID> = []
    private var cancelRequests: Int = 0
    private var executionRequests: Int = 0
    private var launchContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var launchReservationWaiters: [CheckedContinuation<UUID, Never>] = []
    private var executionContinuations: [UUID: CheckedContinuation<ProviderExecutionResult, Error>] = [:]
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(mode: Mode) {
        self.mode = mode
    }

    func capabilities() -> [ProviderCapability] {
        [.init(kind: .codex, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: false)]
    }

    func preflight() -> [ProviderCapability] { capabilities() }
    func recoverProcessFamilies() async throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt: String,
        workingDirectory _: String,
        maximumBytes _: Int,
        runID: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        let runID = runID ?? UUID()
        await onProviderSessionIdentity("native-\(runID.uuidString)")
        return try await executeBody(runID: runID, output: "provider:\(prompt)")
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        active.insert(request.runID)
        defer { active.remove(request.runID) }
        executionRequests += 1
        if mode == .launchHeld {
            await withCheckedContinuation {
                launchContinuations[request.runID] = $0
                let waiters = launchReservationWaiters
                launchReservationWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: request.runID) }
            }
        }
        try await request.acknowledgeLaunch()
        if mode != .failureHeld {
            await onEvent(.providerIdentity("native-\(request.runID.uuidString)"))
        }
        let result = try await executeBody(runID: request.runID, output: "provider:\(request.prompt)")
        if mode != .terminalHeld {
            await onEvent(.framed(providerEventID: "assistant-final", providerSequence: 2, event: .assistantFinal(result.output)))
            // Exact redelivery must be discarded by the durable provider receipt.
            await onEvent(.framed(providerEventID: "assistant-final", providerSequence: 2, event: .assistantFinal(result.output)))
            await onEvent(.completed(providerSessionID: result.providerSessionID))
        }
        active.remove(request.runID)
        return result
    }

    func cancel(runID: UUID) throws {
        cancelRequests += 1
        if mode == .cancelAmbiguous { throw PR5InjectedFailure() }
        active.remove(runID)
        if mode == .cancelRacingCompletion {
            executionContinuations.removeValue(forKey: runID)?.resume(returning: .init(
                output: "racing completion",
                providerSessionID: "native-\(runID.uuidString)"
            ))
        } else {
            executionContinuations.removeValue(forKey: runID)?.resume(throwing: CancellationError())
        }
    }

    func hasActiveRun(_ runID: UUID) -> Bool { active.contains(runID) }
    func activeRunIDs() -> Set<UUID> { active }
    func cancelCallCount() -> Int { cancelRequests }
    func executionCallCount() -> Int { executionRequests }

    func waitForLaunchReservation() async -> UUID {
        if let runID = launchContinuations.keys.first { return runID }
        return await withCheckedContinuation { launchReservationWaiters.append($0) }
    }

    func acknowledgeLaunch(_ runID: UUID) {
        launchContinuations.removeValue(forKey: runID)?.resume()
    }

    func waitUntilStarted(_ runID: UUID) async {
        if executionContinuations[runID] != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters[runID, default: []].append(continuation)
        }
    }

    func complete(_ runID: UUID) {
        active.remove(runID)
        executionContinuations.removeValue(forKey: runID)?.resume(returning: .init(
            output: "",
            providerSessionID: "native-\(runID.uuidString)"
        ))
    }

    func fail(_ runID: UUID) {
        active.remove(runID)
        executionContinuations.removeValue(forKey: runID)?.resume(throwing: PR5InjectedFailure())
    }

    func abandon(_ runID: UUID) {
        active.remove(runID)
        executionContinuations.removeValue(forKey: runID)?.resume(throwing: CancellationError())
    }

    private func executeBody(runID: UUID, output: String) async throws -> ProviderExecutionResult {
        switch mode {
        case .immediate:
            for waiter in startWaiters.removeValue(forKey: runID) ?? [] { waiter.resume() }
            active.remove(runID)
            return .init(output: output, providerSessionID: "native-\(runID.uuidString)")
        case .held, .launchHeld, .terminalHeld, .failureHeld, .cancelAmbiguous, .cancelRacingCompletion:
            return try await withCheckedThrowingContinuation { continuation in
                executionContinuations[runID] = continuation
                for waiter in startWaiters.removeValue(forKey: runID) ?? [] { waiter.resume() }
            }
        }
    }
}

final class IdempotencyRetryContractTests: XCTestCase {
    func testConflictingDigestUpsertFailsInsideTransactionInsteadOfCommittingNoOp() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let first = IdempotencyInput(actorID: "actor", operation: "mutation", key: "shared", requestDigest: "digest-a")
        try await store.saveIdempotency(first, status: 202, response: Data("first".utf8))
        do {
            try await store.saveIdempotency(
                .init(actorID: "actor", operation: "mutation", key: "shared", requestDigest: "digest-b"),
                status: 202,
                response: Data("second".utf8)
            )
            XCTFail("Expected conflicting upsert to fail")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        let replay = try await store.existingIdempotency(first)
        XCTAssertEqual(replay?.0, Data("first".utf8))
        try await store.close()
    }

    func testSameLifecycleIdentityReplaysReceiptAndConflictingDigestIsRejected() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .immediate)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = SessionCommand.resumeSession(expectedRunID: nil, providerResumeMode: .fresh)
        let first = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        let replay = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        XCTAssertEqual(replay.commandID, first.commandID)
        do {
            _ = try await authority.execute(
                command: command,
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "app-invocation-1",
                requestDigest: "digest-b"
            )
            XCTFail("Expected idempotency conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        await authority.waitForProviderRunsToSettle()
        let reconnectedAuthority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        try await reconnectedAuthority.recover()
        let droppedResponseReplay = try await reconnectedAuthority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        XCTAssertEqual(droppedResponseReplay.commandID, first.commandID)
        let executionCalls = await provider.executionCallCount()
        XCTAssertEqual(executionCalls, 1)
        let completed = try await reconnectedAuthority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(completed.transcript.filter { $0.kind == .assistant }.count, 1)
        let transitionCount = try await store.database.query(
            "SELECT COUNT(*) AS value FROM authority_transitions WHERE kind='start'"
        ).first?.column("value")?.integer
        XCTAssertEqual(transitionCount, 1)
        let providerReceiptCount = try await store.database.query(
            "SELECT COUNT(*) AS value FROM provider_event_receipts"
        ).first?.column("value")?.integer
        XCTAssertEqual(providerReceiptCount, 2)
        _ = try await store.database.query(
            "DELETE FROM idempotency_records WHERE actor_id=? AND operation='resumeSession' AND idempotency_key='app-invocation-1'",
            [.text(PR5TestSupport.actor.userID)]
        )
        let transitionReplay = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        XCTAssertEqual(transitionReplay.commandID, first.commandID)
        _ = try await store.database.query(
            "UPDATE authority_transitions SET response_body=NULL WHERE actor_id=? AND operation='resumeSession' AND idempotency_key='app-invocation-1'",
            [.text(PR5TestSupport.actor.userID)]
        )
        do {
            _ = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "app-invocation-1", requestDigest: "digest-a")
            XCTFail("Expected expired durable response to require resnapshot")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .operationReconciling)
        }
        try await store.close()
    }
}

final class WorkspaceLaunchAcknowledgementTests: XCTestCase {
    func testFailedAcknowledgementForcesTerminationWhenChildIgnoresSIGTERM() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let runner = LocalWorkspaceCommandRunner()

        do {
            _ = try await runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do :; done"],
                workingDirectory: root.path,
                maximumBytes: 1024,
                launchValidation: {},
                launchAcknowledgement: {
                    for _ in 0 ..< 100 {
                        if FileManager.default.fileExists(atPath: pidFile.path) {
                            throw PR5InjectedFailure()
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw ServiceAPIError(
                        code: .dependencyUnavailable,
                        message: "Child did not reach the launch boundary"
                    )
                }
            )
            XCTFail("Expected acknowledgement persistence failure")
        } catch is PR5InjectedFailure {}

        let text = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        #if canImport(Darwin) || canImport(Glibc)
            errno = 0
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        #endif
    }
}

final class ProviderLaunchAcknowledgementTests: XCTestCase {
    func testStartRemainsLaunchReservedUntilProviderAcknowledgesAndThenFinalizesRunning() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .launchHeld)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Task {
            try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "launch-held",
                requestDigest: "launch-held"
            )
        }
        let reservedRunID = await provider.waitForLaunchReservation()
        let reserved = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(reserved)
        XCTAssertEqual(run.runID, reservedRunID)
        let reservedSession = try await store.session(id: session.sessionID)
        let reservedRun = try await store.latestRun(sessionID: session.sessionID)
        let reservedTransitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(reservedSession?.state, .preparing)
        XCTAssertEqual(reservedRun?.state, "launchReserved")
        XCTAssertEqual(reservedTransitions.first?.state, .prepared)

        await provider.acknowledgeLaunch(run.runID)
        let receipt = try await start.value
        XCTAssertEqual(receipt.status, "accepted")
        let runningSession = try await store.session(id: session.sessionID)
        let runningRun = try await store.latestRun(sessionID: session.sessionID)
        let runningTransitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(runningSession?.state, .running)
        XCTAssertEqual(runningRun?.state, "running")
        XCTAssertTrue(runningTransitions.isEmpty)

        await provider.waitUntilStarted(run.runID)
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()
        try await store.close()
    }

    func testPostLaunchPreAcknowledgementFaultBecomesDurablyReconcilingAndRetryDoesNotRelaunch() async throws {
        let armed = PR5ArmedPersistenceFault()
        let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { point in
            try await armed.hit(point)
        })
        let provider = PR5ProviderDispatcher(mode: .launchHeld)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Task {
            try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "launch-ambiguous",
                requestDigest: "launch-ambiguous"
            )
        }
        let reservedRunID = await provider.waitForLaunchReservation()
        let reserved = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(reserved)
        XCTAssertEqual(run.runID, reservedRunID)
        await armed.arm(.afterAuthorityStateCAS)
        await provider.acknowledgeLaunch(run.runID)
        do {
            _ = try await start.value
            XCTFail("Expected ambiguous launch acknowledgement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .operationReconciling)
        }
        let reconcilingRun = try await store.latestRun(sessionID: session.sessionID)
        let reconcilingTransitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(reconcilingRun?.state, "reconciliationRequired")
        XCTAssertEqual(reconcilingTransitions.first?.state, .reconciliationRequired)
        let replay = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "launch-ambiguous",
            requestDigest: "launch-ambiguous"
        )
        XCTAssertEqual(replay.status, "pending")
        let executionCalls = await provider.executionCallCount()
        XCTAssertEqual(executionCalls, 1)
        await authority.waitForProviderRunsToSettle()

        let recovered = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        try await recovered.recover()
        let recoveredSession = try await recovered.sessionSnapshot(sessionID: session.sessionID)
        let recoveredRun = try await store.latestRun(sessionID: session.sessionID)
        let recoveredTransitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(recoveredSession.state, .interrupted)
        XCTAssertEqual(recoveredRun?.state, "interrupted")
        XCTAssertTrue(recoveredTransitions.isEmpty)
        let readiness = await RepoPromptReadinessService(authority: recovered, store: store).snapshot(forceRefresh: true)
        XCTAssertTrue(readiness.ready)
        try await store.close()
    }
}

final class CancellationPrecedenceTests: XCTestCase {
    func testCommittedCancelRequestedFencesRacingProviderCompletion() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .cancelRacingCompletion)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "cancel-race-start",
            requestDigest: "cancel-race-start"
        )
        let latestRun = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        _ = try await authority.execute(
            command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "cancel-race",
            requestDigest: "cancel-race"
        )
        let canceledSession = try await store.session(id: session.sessionID)
        let canceledRun = try await store.latestRun(sessionID: session.sessionID)
        XCTAssertEqual(canceledSession?.state, .canceled)
        XCTAssertEqual(canceledRun?.state, "canceled")
        let winners = try await store.database.query(
            "SELECT kind FROM authority_transitions WHERE run_id=? AND state='finalized' AND kind IN ('cancel','complete','fail','interrupt')",
            [.text(run.runID.uuidString)]
        ).compactMap { $0.column("kind")?.string }
        XCTAssertEqual(winners, ["cancel"])
        try await store.close()
    }
}

final class ArchiveProposalCommitTests: XCTestCase {
    func testArchiveCommitFailureDoesNotMutateSessionAuthorityMemory() async throws {
        let armed = PR5ArmedPersistenceFault()
        let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { point in
            try await armed.hit(point)
        })
        let provider = PR5ProviderDispatcher(mode: .immediate)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        await armed.arm(.beforeTransactionCommit)
        do {
            _ = try await authority.execute(
                command: .archiveSession(expectedRevision: session.revision),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "archive-fault",
                requestDigest: "archive-fault"
            )
            XCTFail("Expected archive transaction failure")
        } catch is PR5InjectedFailure {}
        let memory = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let durable = try await store.session(id: session.sessionID)
        XCTAssertEqual(memory.state, session.state)
        XCTAssertEqual(memory.revision, session.revision)
        XCTAssertEqual(durable?.state, session.state)
        XCTAssertEqual(durable?.revision, session.revision)
        try await store.close()
    }
}

final class PostCommitMemoryApplyTests: XCTestCase {
    func testEveryRunLifecycleCommitPrecedesInMemoryApply() async throws {
        let cases: [(mode: PR5ProviderDispatcher.Mode, kind: AuthorityTransitionKind, durable: SessionLifecycleState, memory: SessionLifecycleState)] = [
            (.launchHeld, .start, .running, .preparing),
            (.held, .cancel, .canceled, .running),
            (.terminalHeld, .complete, .completed, .running),
            (.failureHeld, .fail, .failed, .running),
        ]
        for testCase in cases {
            let gate = PR5PostCommitGate()
            let hooks = RepoPromptHeadlessAuthorityHooks(
                afterRunTransitionCommitBeforeMemoryApply: { transition in
                    if transition.kind == testCase.kind, transition.state == .finalized {
                        await gate.pause()
                    }
                }
            )
            let store = try await SQLiteServiceStore.open(storage: .memory)
            let provider = PR5ProviderDispatcher(mode: testCase.mode)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(
                store: store,
                dispatcher: provider,
                hooks: hooks
            )
            defer { try? FileManager.default.removeItem(at: root) }

            if testCase.kind == .start {
                let start = Task {
                    try await authority.execute(
                        command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                        sessionID: session.sessionID,
                        externalActor: PR5TestSupport.actor,
                        idempotencyKey: "post-commit-start",
                        requestDigest: "post-commit-start"
                    )
                }
                let runID = await provider.waitForLaunchReservation()
                await provider.acknowledgeLaunch(runID)
                await gate.waitUntilPaused()
                let durable = try await store.session(id: session.sessionID)
                let memory = try await authority.inMemorySessionSnapshot(sessionID: session.sessionID)
                XCTAssertEqual(durable?.state, testCase.durable)
                XCTAssertEqual(memory.state, testCase.memory)
                await gate.release()
                _ = try await start.value
                await provider.waitUntilStarted(runID)
                await provider.abandon(runID)
            } else {
                _ = try await authority.execute(
                    command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                    sessionID: session.sessionID,
                    externalActor: PR5TestSupport.actor,
                    idempotencyKey: "post-commit-start-\(testCase.kind.rawValue)",
                    requestDigest: "post-commit-start"
                )
                let latestRun = try await store.latestRun(sessionID: session.sessionID)
                let run = try XCTUnwrap(latestRun)
                await provider.waitUntilStarted(run.runID)
                let commandTask: Task<CommandReceipt, Error>?
                switch testCase.kind {
                case .cancel:
                    commandTask = Task {
                        try await authority.execute(
                            command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
                            sessionID: session.sessionID,
                            externalActor: PR5TestSupport.actor,
                            idempotencyKey: "post-commit-cancel",
                            requestDigest: "post-commit-cancel"
                        )
                    }
                case .complete:
                    commandTask = nil
                    await provider.complete(run.runID)
                case .fail:
                    commandTask = nil
                    await provider.fail(run.runID)
                case .start, .interrupt:
                    XCTFail("Unexpected lifecycle case")
                    commandTask = nil
                }
                await gate.waitUntilPaused()
                let durable = try await store.session(id: session.sessionID)
                let memory = try await authority.inMemorySessionSnapshot(sessionID: session.sessionID)
                XCTAssertEqual(durable?.state, testCase.durable, "kind \(testCase.kind.rawValue)")
                XCTAssertEqual(memory.state, testCase.memory, "kind \(testCase.kind.rawValue)")
                await gate.release()
                if let commandTask { _ = try await commandTask.value }
            }
            await authority.waitForProviderRunsToSettle()
            try await store.close()
        }
    }

    func testArchiveCommitPrecedesInMemoryApply() async throws {
        let gate = PR5PostCommitGate()
        let hooks = RepoPromptHeadlessAuthorityHooks(
            afterSessionCommitBeforeMemoryApply: { operation, _ in
                if operation == "archiveSession" { await gate.pause() }
            }
        )
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .immediate)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider, hooks: hooks)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = Task {
            try await authority.execute(
                command: .archiveSession(expectedRevision: session.revision),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "archive-post-commit",
                requestDigest: "archive-post-commit"
            )
        }
        await gate.waitUntilPaused()
        let durable = try await store.session(id: session.sessionID)
        let memory = try await authority.inMemorySessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(durable?.state, .archived)
        XCTAssertEqual(memory.state, session.state)
        await gate.release()
        _ = try await archive.value
        try await store.close()
    }
}

final class ProviderLifecycleRecoveryTests: XCTestCase {
    func testUncleanRunningProviderIsInterruptedAtomicallyWhenNativeRunIsAbsent() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .held)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "restart-start",
            requestDigest: "restart-start"
        )
        let latestRun = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()

        let recovered = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        try await recovered.recover()
        let snapshot = try await recovered.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(snapshot.state, .interrupted)
        let recoveredRun = try await store.latestRun(sessionID: session.sessionID)
        let persistedRun = try XCTUnwrap(recoveredRun)
        XCTAssertEqual(persistedRun.state, "interrupted")
        let pending = try await store.nonfinalAuthorityTransitions()
        XCTAssertTrue(pending.isEmpty)
        try await store.close()
    }

    func testAmbiguousProviderCancellationRemainsDurablyReconciling() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .cancelAmbiguous)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "ambiguous-start",
            requestDigest: "ambiguous-start"
        )
        let latestRun = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        do {
            _ = try await authority.execute(
                command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "ambiguous-cancel",
                requestDigest: "ambiguous-cancel"
            )
            XCTFail("Expected reconciliation-required result")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .operationReconciling)
        }
        let transitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(transitions.last?.state, .reconciliationRequired)
        let cancelRequestedRun = try await store.latestRun(sessionID: session.sessionID)
        XCTAssertEqual(cancelRequestedRun?.state, "cancelRequested")
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0
        )
        let blocked = await readiness.snapshot(forceRefresh: true)
        XCTAssertFalse(blocked.ready)
        XCTAssertEqual(
            blocked.checks.first(where: { $0.name == "authority-transitions" })?.ready,
            false
        )

        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()
        let reconciled = await readiness.snapshot(forceRefresh: true)
        let recoveredSession = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let recoveredRun = try await store.latestRun(sessionID: session.sessionID)
        let recoveredTransitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertTrue(reconciled.ready, "\(reconciled.checks)")
        XCTAssertEqual(recoveredSession.state, .canceled)
        XCTAssertEqual(recoveredRun?.state, "canceled")
        XCTAssertTrue(recoveredTransitions.isEmpty)
        try await store.close()
    }
}

final class SustainedProviderConcurrencyTests: XCTestCase {
    func testOneAssembledAuthoritySustainsSixteenCrossProjectRunsWithoutLeakage() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .held)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        var sessions: [SessionSnapshot] = []
        var roots: [URL] = []
        for index in 0 ..< 16 {
            let root = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            let project = try await authority.createProject(
                input: .init(name: "PR5-\(index)", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "concurrent-project-\(index)",
                requestDigest: "concurrent-project-\(index)"
            )
            sessions.append(try await authority.createSession(
                input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "concurrent-session-\(index)",
                requestDigest: "concurrent-session-\(index)"
            ))
        }
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, session) in sessions.enumerated() {
                group.addTask {
                    _ = try await authority.execute(
                        command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                        sessionID: session.sessionID,
                        externalActor: PR5TestSupport.actor,
                        idempotencyKey: "concurrent-run-\(index)",
                        requestDigest: "concurrent-run-\(index)"
                    )
                }
            }
            try await group.waitForAll()
        }
        var runs: [ProviderRunSnapshot] = []
        for session in sessions {
            let latestRun = try await store.latestRun(sessionID: session.sessionID)
            let run = try XCTUnwrap(latestRun)
            runs.append(run)
            await provider.waitUntilStarted(run.runID)
        }
        let simultaneouslyActive = await provider.activeRunIDs()
        XCTAssertEqual(simultaneouslyActive, Set(runs.map(\.runID)))
        XCTAssertEqual(simultaneouslyActive.count, 16)
        for run in runs { await provider.complete(run.runID) }
        await authority.waitForProviderRunsToSettle()

        let expectedProjectIDs = Set(sessions.map(\.projectID))
        let events = try await store.events(after: nil, limit: 10_000).events
        XCTAssertEqual(events.map(\.globalSequence), Array(1 ... Int64(events.count)))
        XCTAssertTrue(events.allSatisfy { expectedProjectIDs.contains($0.projectID) })
        for (session, run) in zip(sessions, runs) {
            let snapshot = try await authority.sessionSnapshot(sessionID: session.sessionID)
            XCTAssertEqual(snapshot.state, .completed)
            XCTAssertEqual(run.sessionID, session.sessionID)
            let rawSessionEvents = events.filter { $0.sessionID == session.sessionID }
            XCTAssertFalse(rawSessionEvents.isEmpty)
            XCTAssertTrue(rawSessionEvents.allSatisfy { $0.projectID == session.projectID })
        }
        let rawRunOwnershipRows = try await store.database.query(
            "SELECT COUNT(*) AS run_count,COUNT(DISTINCT r.session_id) AS session_count,COUNT(DISTINCT s.project_id) AS project_count FROM runs r JOIN sessions s ON s.session_id=r.session_id WHERE r.generation>=1"
        )
        let rawRunOwnership = try XCTUnwrap(rawRunOwnershipRows.first)
        XCTAssertEqual(rawRunOwnership.column("run_count")?.integer, 16)
        XCTAssertEqual(rawRunOwnership.column("session_count")?.integer, 16)
        XCTAssertEqual(rawRunOwnership.column("project_count")?.integer, 16)
        let uncovered = try await store.database.query(
            "SELECT COUNT(*) AS value FROM events e LEFT JOIN event_outbox o ON o.global_sequence=e.global_sequence WHERE o.global_sequence IS NULL"
        ).first?.column("value")?.integer
        XCTAssertEqual(uncovered, 0)
        try await store.close()
    }
}
