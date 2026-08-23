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
            _ = try await store.persistProject(
                project,
                eventType: revision == 1 ? .projectCreated : .projectUpdated,
                actor: actor,
                correlationID: UUID(),
                idempotency: nil
            )
            roots = project.roots
        }
        let old = Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
        _ = try await store.connection.query("UPDATE events SET timestamp=? WHERE global_sequence<=4", [.float(old)])
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
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let optionalArchiveID = try await store.archiveEvents(through: 1)
        let archiveID = try XCTUnwrap(optionalArchiveID)
        let archived = try await store.archivedEvents(archiveID: archiveID)
        XCTAssertEqual(archived.count, 1)
        do {
            _ = try await store.connection.query("UPDATE event_archive_blobs SET compression='invalid'")
            XCTFail("expected immutable archive trigger")
        } catch {}
        do {
            _ = try await store.connection.query("DELETE FROM snapshot_checkpoints WHERE retention_class='pre_compaction'")
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
        let counter = try await store.connection.query(
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
