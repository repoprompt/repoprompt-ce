import Foundation
import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import SQLiteNIO
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
private struct InjectedPersistenceFault: Error {}

final class PersistenceTests: XCTestCase {
    func testLegacyWorktreeIdentityBackfillNeverOverwritesExistingMismatch() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let bindingID = UUID()
        let projectID = UUID()
        let rootID = UUID()
        let sessionID = UUID()
        let resource = OwnedResourceRecord(
            kind: .worktree,
            projectID: projectID,
            sessionID: sessionID,
            externalID: bindingID,
            internalPathIdentity: "/srv/repoprompt/worktrees/p/b",
            lifecycleState: .active,
            contentDigest: "persisted-mismatch",
            metadata: ["sourceRoot": "/srv/repoprompt/projects/source", "branch": "feature"]
        )
        try await store.reserveOwnedResource(resource)
        let authority = ActiveOwnedWorktreeSnapshot(
            bindingID: bindingID,
            projectID: projectID,
            rootID: rootID,
            sessionID: sessionID,
            physicalPath: resource.internalPathIdentity,
            sourceRoot: "/srv/repoprompt/projects/source",
            branch: "feature"
        )
        do {
            _ = try await store.backfillActiveWorktreeContentDigest(
                resourceID: resource.resourceID,
                authority: authority,
                contentDigest: "observed-different"
            )
            XCTFail("expected non-null identity mismatch rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .worktreeConflict)
        }
        let persisted = try await store.ownedResource(externalID: bindingID, kind: .worktree)
        XCTAssertEqual(persisted?.contentDigest, "persisted-mismatch")
        XCTAssertEqual(persisted?.lifecycleState, .active)

        let unownedBindingID = UUID()
        let unowned = OwnedResourceRecord(
            kind: .worktree,
            projectID: projectID,
            sessionID: sessionID,
            externalID: unownedBindingID,
            internalPathIdentity: "/srv/repoprompt/worktrees/p/unowned",
            lifecycleState: .active,
            metadata: ["sourceRoot": "/srv/repoprompt/projects/source", "branch": "unowned"]
        )
        try await store.reserveOwnedResource(unowned)
        let unownedAuthority = ActiveOwnedWorktreeSnapshot(
            bindingID: unownedBindingID,
            projectID: projectID,
            rootID: rootID,
            sessionID: sessionID,
            physicalPath: unowned.internalPathIdentity,
            sourceRoot: "/srv/repoprompt/projects/source",
            branch: "unowned"
        )
        do {
            _ = try await store.backfillActiveWorktreeContentDigest(
                resourceID: unowned.resourceID,
                authority: unownedAuthority,
                contentDigest: "must-not-be-blessed"
            )
            XCTFail("expected missing durable ownership rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .worktreeConflict)
        }
        let stillUnowned = try await store.ownedResource(externalID: unownedBindingID, kind: .worktree)
        XCTAssertNil(stillUnowned?.contentDigest)
        XCTAssertEqual(stillUnowned?.lifecycleState, .active)
        try await store.close()
    }

    func testEventsAreSignedBeforeDurablePublication() async throws {
        let key = PersistenceEventSigningKey(keyID: "event-v1", secret: Data("event-secret".utf8))
        let store = try await SQLiteServiceStore.open(storage: .memory, eventSigningKey: key)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: cursor)
        let event = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let expected = CanonicalSigning.hmacSHA256(message: event.digest, key: key.secret)
        XCTAssertEqual(event.digest, CanonicalSigning.bodyDigest(try event.persistenceSigningData()))
        XCTAssertEqual(event.keyID, key.keyID)
        XCTAssertEqual(event.signature, expected)
        let persisted = try await store.events(after: nil, limit: 1)
        XCTAssertEqual(persisted.events.first?.signature, expected)
        try await store.close()
    }

    func testLegacyBase64EventEnvelopeIsCanonicallyRepublished() async throws {
        let key = PersistenceEventSigningKey(keyID: "event-v1", secret: Data("event-secret".utf8))
        let store = try await SQLiteServiceStore.open(storage: .memory, eventSigningKey: key)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/private/source", writable: true)], revision: 1, cursor: cursor)
        let event = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let encoded = try JSONEncoder.serviceEncoder.encode(event)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["payload"] = try JSONEncoder.serviceEncoder.encode(event.payload).base64EncodedString()
        legacy["digest"] = "legacy-payload-only-digest"
        legacy["keyId"] = "legacy-key"
        legacy["signature"] = "legacy-signature"
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try await store.connection.query("UPDATE events SET envelope_json=? WHERE global_sequence=?", [.text(String(decoding: legacyData, as: UTF8.self)), .integer(Int(event.globalSequence))])

        let replayPage = try await store.events(after: nil, limit: 1)
        let replayed = try XCTUnwrap(replayPage.events.first)
        XCTAssertEqual(replayed.keyID, key.keyID)
        XCTAssertEqual(replayed.digest, CanonicalSigning.bodyDigest(try replayed.persistenceSigningData()))
        XCTAssertEqual(replayed.signature, CanonicalSigning.hmacSHA256(message: replayed.digest, key: key.secret))
        let republishedPayload = String(decoding: try JSONEncoder.serviceEncoder.encode(replayed.payload), as: UTF8.self)
        XCTAssertFalse(republishedPayload.contains("canonicalPath"), republishedPayload)
        try await store.close()
    }

    func testTransactionFaultBoundariesRollbackProjectionEventAndSequence() async throws {
        for faultPoint in [PersistenceFaultPoint.afterTransactionBegin, .afterEventInsertBeforeSequenceAdvance, .beforeTransactionCommit] {
            let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
            defer {
                try? FileManager.default.removeItem(at: database)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
            }
            let injector = PersistenceFaultInjector { observed in
                if observed == faultPoint { throw InjectedPersistenceFault() }
            }
            let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
            var store = try await SQLiteServiceStore.open(storage: .file(database.path), faultInjector: injector)
            let projectID = UUID()
            let cursor = try await store.nextCursor()
            let project = ProjectSnapshot(projectID: projectID, name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: cursor)

            do {
                _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
                XCTFail("Expected injected fault at \(faultPoint.rawValue)")
            } catch is InjectedPersistenceFault {}

            let rolledBackProject = try await store.project(id: projectID)
            let rolledBackEvents = try await store.events(after: nil, limit: 10)
            let rolledBackMetadata = try await store.metadata()
            XCTAssertNil(rolledBackProject)
            XCTAssertTrue(rolledBackEvents.events.isEmpty)
            XCTAssertEqual(rolledBackMetadata.nextGlobalSequence, 1)
            try await store.close()

            store = try await SQLiteServiceStore.open(storage: .file(database.path))
            let recoveryCursor = try await store.nextCursor()
            let recovered = ProjectSnapshot(projectID: projectID, name: "P", creator: actor, state: .active, roots: project.roots, revision: 1, cursor: recoveryCursor)
            let event = try await store.persistProject(recovered, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
            XCTAssertEqual(event.globalSequence, 1)
            try await store.close()
        }
    }

    func testConcurrentIdenticalProjectCreationReplaysCommittedWinner() async throws {
        let barrier = TwoPartyIdempotencyPreflightBarrier()
        let injector = PersistenceFaultInjector { point in
            await barrier.hit(point)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: injector)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "concurrent-owner", username: "owner", displayName: "Owner")

        async let first = authority.createProject(
            input: .init(name: "Concurrent workspace", roots: []),
            externalActor: actor,
            idempotencyKey: "same-create",
            requestDigest: "same-fingerprint"
        )
        async let second = authority.createProject(
            input: .init(name: "Concurrent workspace", roots: []),
            externalActor: actor,
            idempotencyKey: "same-create",
            requestDigest: "same-fingerprint"
        )
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult, secondResult)

        let projects = try await store.allProjects()
        XCTAssertEqual(projects, [firstResult])
        let events = try await store.events(after: nil, limit: 10)
        XCTAssertEqual(events.events.count(where: { $0.eventType == .projectCreated }), 1)
        let replay = try await store.idempotencyResult(.init(
            actorID: actor.userID,
            operation: "createProject",
            key: "same-create",
            requestDigest: "same-fingerprint"
        ))
        XCTAssertEqual(replay?.status, 201)
        XCTAssertEqual(try replay.map { try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: $0.response) }, firstResult)

        do {
            _ = try await authority.createProject(
                input: .init(name: "Different workspace", roots: []),
                externalActor: actor,
                idempotencyKey: "same-create",
                requestDigest: "different-fingerprint"
            )
            XCTFail("expected conflicting fingerprint rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        let finalProjects = try await store.allProjects()
        let finalEvents = try await store.events(after: nil, limit: 10)
        XCTAssertEqual(finalProjects.count, 1)
        XCTAssertEqual(finalEvents.events.count(where: { $0.eventType == .projectCreated }), 1)
        try await store.close()
    }

    func testAtomicProjectPublicationUsesMonotonicSequence() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectID = UUID()
        let firstCursor = try await store.nextCursor()
        let first = ProjectSnapshot(projectID: projectID, name: "One", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: firstCursor)
        let firstEvent = try await store.persistProject(first, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let secondCursor = try await store.nextCursor()
        let second = ProjectSnapshot(projectID: projectID, name: "Two", creator: actor, state: .active, roots: first.roots, revision: 2, cursor: secondCursor)
        let secondEvent = try await store.persistProject(second, eventType: .projectUpdated, actor: actor, correlationID: UUID(), idempotency: nil)
        XCTAssertEqual(firstEvent.globalSequence + 1, secondEvent.globalSequence)
        let page = try await store.events(after: nil, limit: 10)
        XCTAssertEqual(page.events.map(\.globalSequence), [1, 2])
        try await store.close()
    }

    func testRestoreChangesStoreNamespace() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let prior = try await store.metadata().storeID
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let priorCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: priorCursor)
        let idempotency = IdempotencyInput(actorID: actor.userID, operation: "createProject", key: "before-restore", requestDigest: "digest")
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: idempotency)
        let storedIdempotency = try await store.idempotencyResult(idempotency)
        XCTAssertNotNil(storedIdempotency)

        let activationToken = Data("restore-activation".utf8)
        let fresh = try await store.prepareRestoredStore(
            from: prior,
            backupSequence: 1,
            digest: "digest",
            activationToken: activationToken
        )
        _ = try await store.activateRestoredStore(activationToken: activationToken, instanceID: UUID())
        let restoredIdempotency = try await store.idempotencyResult(idempotency)
        XCTAssertNil(restoredIdempotency)
        XCTAssertNotEqual(prior, fresh)
        let restored = try await store.metadata()
        XCTAssertEqual(restored.storeID, fresh)
        XCTAssertEqual(restored.replayFloor, 1)
        let restoredEvents = try await store.events(after: nil, limit: 10)
        let restoredProject = try await store.project(id: project.projectID)
        XCTAssertTrue(restoredEvents.events.isEmpty)
        XCTAssertEqual(restoredProject?.cursor.storeID, fresh)
        do {
            _ = try await store.events(after: priorCursor, limit: 10)
            XCTFail("expected prior namespace to expire")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
        }
        try await store.close()
    }

    func testUncleanRestartInterruptsNonterminalRunExactlyOnce() async throws {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let projectCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: projectCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let sessionCursor = try await store.nextCursor()
        let sessionID = UUID()
        let session = SessionSnapshot(sessionID: sessionID, projectID: project.projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .running, runGeneration: 1, turnEpoch: 1, revision: 2, transcript: [], interactions: [], cursor: sessionCursor)
        _ = try await store.persistSession(session, eventType: .sessionResumed, actor: actor, correlationID: UUID(), idempotency: nil)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let recovered = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(recovered.state, .interrupted)
        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(events.events.count(where: { $0.eventType == .serviceRecovery }), 1)
        try await store.close()
    }

    func testTerminalCheckpointAndImmutableEventArchiveAdvanceReplayFloor() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: projectCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let sessionID = UUID()
        let sessionCursor = try await store.nextCursor()
        let session = SessionSnapshot(sessionID: sessionID, projectID: project.projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .completed, runGeneration: 1, turnEpoch: 1, revision: 2, transcript: [], interactions: [], cursor: sessionCursor)
        _ = try await store.persistSession(session, eventType: .sessionCompleted, actor: nil, correlationID: UUID(), idempotency: nil)
        let checkpoints = try await store.snapshotCheckpoints(scope: "session:\(sessionID.uuidString)")
        XCTAssertEqual(checkpoints.map(\.sequence), [2])

        let archivedID = try await store.archiveEvents(through: 1)
        let archiveID = try XCTUnwrap(archivedID)
        let archive = try await store.archivedEvents(archiveID: archiveID)
        XCTAssertEqual(archive.map(\.eventType), [.projectCreated])
        let preCompaction = try await store.snapshotCheckpoints(scope: "events:\(projectCursor.storeID.uuidString):pre-compaction")
        XCTAssertEqual(preCompaction.map(\.sequence), [1])
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.replayFloor, 1)
        do {
            _ = try await store.events(after: .init(storeID: projectCursor.storeID, globalSequence: 0), limit: 10)
            XCTFail("expected archived cursor to expire")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
        }
        try await store.close()
    }

    func testLegacyJSONImportPreservesHierarchyTranscriptAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("state.sqlite")
        let source = directory.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let records: [[String: Any]] = [
            [
                "id": parentID.uuidString, "workspaceID": projectID.uuidString, "name": "Parent", "agentKind": "codexExec", "agentModel": "gpt-test", "lastRunState": "completed",
                "items": [["id": UUID().uuidString, "timestamp": 10.0, "kind": "user", "text": "hello", "sequenceIndex": 0], ["id": UUID().uuidString, "timestamp": 11.0, "kind": "assistant", "text": "world", "sequenceIndex": 1]]
            ],
            [
                "id": childID.uuidString, "workspaceID": projectID.uuidString, "parentSessionID": parentID.uuidString, "name": "Child", "agentKind": "claudeCode", "lastRunState": "running",
                "items": [["id": UUID().uuidString, "timestamp": 12.0, "kind": "user", "text": "continue", "sequenceIndex": 0]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(to: source)

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let report = try await LegacySessionJSONImporter.run(source: source, store: store, projectRoot: directory)
        XCTAssertEqual(report.importedProjects, 1)
        XCTAssertEqual(report.importedSessions, 2)
        let parent = try await store.session(id: parentID)
        let child = try await store.session(id: childID)
        XCTAssertEqual(parent?.transcript.map(\.content), ["hello", "world"])
        XCTAssertEqual(child?.parentSessionID, parentID)
        XCTAssertEqual(child?.rootSessionID, parentID)
        XCTAssertEqual(child?.provider, .claudeCompatible)
        XCTAssertEqual(child?.state, .interrupted)
        let importedEvents = try await store.events(after: nil, limit: 20).events
        let projectEvent = try XCTUnwrap(importedEvents.first(where: { $0.projectID == projectID && $0.eventType == .projectCreated }))
        let projectPayload = String(decoding: try JSONEncoder.serviceEncoder.encode(projectEvent.payload), as: UTF8.self)
        XCTAssertFalse(projectPayload.contains(directory.path), projectPayload)
        XCTAssertFalse(projectPayload.contains("canonicalPath"), projectPayload)
        XCTAssertTrue(projectPayload.contains("rootCount"), projectPayload)
        try await store.close(clean: true)

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let repeated = try await LegacySessionJSONImporter.run(source: source, store: store, projectRoot: directory)
        XCTAssertEqual(repeated.importedProjects, 0)
        XCTAssertEqual(repeated.importedSessions, 0)
        let repeatedSessions = try await store.allSessions()
        XCTAssertEqual(repeatedSessions.count, 2)
        try await store.close()
    }

    func testLegacyJSONImportResumesAfterFaultWithoutDuplicateEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("state.sqlite")
        let source = directory.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let records: [[String: Any]] = [
            ["id": firstID.uuidString, "workspaceID": projectID.uuidString, "name": "One", "items": []],
            ["id": secondID.uuidString, "workspaceID": projectID.uuidString, "name": "Two", "items": []]
        ]
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(to: source)

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        do {
            _ = try await LegacySessionJSONImporter.run(source: source, store: store, projectRoot: directory, faultAfterImportedSessions: 1)
            XCTFail("expected injected import interruption")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
        }
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let resumed = try await LegacySessionJSONImporter.run(source: source, store: store, projectRoot: directory)
        XCTAssertEqual(resumed.importedProjects, 0)
        XCTAssertEqual(resumed.importedSessions, 1)
        let resumedSessions = try await store.allSessions()
        XCTAssertEqual(resumedSessions.count, 2)
        let events = try await store.events(after: nil, limit: 20)
        XCTAssertEqual(events.events.count(where: { $0.eventType == .sessionCreated }), 2)
        try await store.close()
    }

    func testContextUsageSurvivesInteractionRebuildAndSilentUpsert() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: projectCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let sessionCursor = try await store.nextCursor()
        let sessionID = UUID()
        let usage = ContextUsageWireSnapshot(modelContextWindow: 200_000, lastTotalTokens: 1_000, totalTotalTokens: 1_000)
        let session = SessionSnapshot(sessionID: sessionID, projectID: project.projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .idle, runGeneration: 0, turnEpoch: 0, revision: 1, transcript: [], interactions: [], cursor: sessionCursor, contextUsage: usage)
        _ = try await store.persistSession(session, eventType: .sessionCreated, actor: actor, correlationID: UUID(), idempotency: nil)

        let rebuiltOptional = try await store.sessionWithInteractions(id: sessionID)
        let rebuilt = try XCTUnwrap(rebuiltOptional)
        XCTAssertEqual(rebuilt.revision, 1)
        XCTAssertEqual(rebuilt.contextUsage?.lastTotalTokens, 1_000)
        XCTAssertEqual(rebuilt.contextUsage?.modelContextWindow, 200_000)

        try await store.upsertContextUsage(ContextUsageWireSnapshot(lastTotalTokens: 4_096, totalTotalTokens: 8_192), sessionID: sessionID)
        let updatedOptional = try await store.sessionWithInteractions(id: sessionID)
        let updated = try XCTUnwrap(updatedOptional)
        XCTAssertEqual(updated.revision, 1)
        XCTAssertEqual(updated.contextUsage?.lastTotalTokens, 4_096)
        XCTAssertEqual(updated.contextUsage?.totalTotalTokens, 8_192)
        XCTAssertEqual(updated.contextUsage?.modelContextWindow, 200_000)
        try await store.close()
    }
}

private actor TwoPartyIdempotencyPreflightBarrier {
    private var remaining = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hit(_ point: PersistenceFaultPoint) async {
        guard point == .afterIdempotencyPreflightMiss, remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}
