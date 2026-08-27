#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceContextAuthorityTests: XCTestCase {
    func testEphemeralDocumentsCannotEnterDurableWorkspaceAuthority() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let document = try fixture.document(prompt: "temporary", ephemeral: true)

        let registered = await runtime.workspaceStore.registerReadDocument(document)
        XCTAssertTrue(registered.document.metadata.isEphemeral)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))

        let createEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        )
        let created = await runtime.workspaceStore.execute(createEnvelope)
        XCTAssertEqual(created.disposition, .invalid)
        XCTAssertEqual(created.errorCode, .invalidDocument)
        XCTAssertEqual(created.diagnostic, "ephemeral_workspace_not_persistable")

        let replayedCreate = await runtime.workspaceStore.execute(createEnvelope)
        XCTAssertEqual(replayedCreate.disposition, .deduplicated)
        XCTAssertEqual(replayedCreate.errorCode, .invalidDocument)
        XCTAssertEqual(replayedCreate.diagnostic, "ephemeral_workspace_not_persistable")

        let replaced = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .replaceWorkingDocument(document)
        ))
        XCTAssertEqual(replaced.disposition, .invalid)
        XCTAssertEqual(replaced.errorCode, .invalidDocument)
        XCTAssertEqual(replaced.diagnostic, "ephemeral_workspace_not_persistable")
        let catalog = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(catalog.workspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
    }

    func testPersistedEphemeralWorkspaceRejectsSaveAndConflictResolutionCommands() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.workspaceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = try fixture.document(prompt: "legacy ephemeral", ephemeral: true)
        try document.documentBytes.write(to: fixture.workspaceFile)
        try fixture.writeLegacyIndex()

        let runtime = fixture.runtime()
        try await runtime.start()
        let loaded = await runtime.workspaceStore.snapshot()
        XCTAssertEqual(loaded.workspaces.first?.document.metadata.isEphemeral, true)

        let save = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .invalid)
        XCTAssertEqual(save.errorCode, .invalidDocument)
        XCTAssertEqual(save.diagnostic, "ephemeral_workspace_not_persistable")

        let resolve = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .resolveExternalConflict(
                workspaceID: fixture.workspaceID,
                acceptExternal: true,
                protectedAgentIdentities: []
            )
        ))
        XCTAssertEqual(resolve.disposition, .invalid)
        XCTAssertEqual(resolve.errorCode, .invalidDocument)
        XCTAssertEqual(resolve.diagnostic, "ephemeral_workspace_not_persistable")
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), document.documentBytes)
    }

    func testAwaitedReadRegistrationRoutesMissingWorkspaceWithoutPersistence() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let document = try fixture.document(prompt: "ephemeral")

        let registered = await runtime.workspaceStore.registerReadDocument(document)
        XCTAssertEqual(registered.document.contentDigest, document.contentDigest)
        XCTAssertEqual(registered.contexts.first?.metadata.identity.contextID, fixture.contextID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        let catalog = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(catalog.workspaces.isEmpty)

        let connectionID = UUID()
        let registrationOutcome = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try XCTUnwrap(registrationOutcome.snapshot.connections.first?.registration)
        let bound = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .context(
                DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.contextID),
                explicit: true
            ),
            operationID: UUID()
        )
        XCTAssertEqual(bound.disposition, .applied)
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        XCTAssertEqual(handle.workspaceRevision, registered.revisions.workingRevision)
        XCTAssertEqual(handle.contextRevision, registered.contexts.first?.revisions.workingRevision)

        let rejectedReplace = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .replaceWorkingDocument(document)
        ))
        XCTAssertEqual(rejectedReplace.disposition, .invalid)
        let stillRegistered = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertNotNil(stillRegistered)

        // A different newer canonical document supersedes the transient overlay.
        let canonicalDocument = try fixture.document(prompt: "canonical")
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(canonicalDocument)
        ))
        XCTAssertEqual(created.disposition, .applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        let registeredCanonicalSnapshot = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        let canonicalSnapshot = try XCTUnwrap(registeredCanonicalSnapshot)
        XCTAssertEqual(canonicalSnapshot.document.contentDigest, canonicalDocument.contentDigest)
        XCTAssertNotEqual(canonicalSnapshot.document.contentDigest, document.contentDigest)
    }

    func testCommandOutcomesReportCanonicalStateWhileReadOverlayIsActive() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        let canonicalDocument = try fixture.document(prompt: "canonical")
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(canonicalDocument)
        ))
        XCTAssertEqual(created.disposition, .applied)

        let overlayDocument = try fixture.document(prompt: "overlay")
        let overlay = await runtime.workspaceStore.registerReadDocument(overlayDocument)
        XCTAssertNotEqual(
            overlay.document.contentDigest,
            canonicalDocument.contentDigest,
            "Fixture must produce a divergent overlay digest for the assertion to be meaningful."
        )
        let canonicalWhileOverlayActive = await runtime.workspaceStore.canonicalWorkspaceSnapshot(
            fixture.workspaceID
        )
        XCTAssertEqual(canonicalWhileOverlayActive?.document.contentDigest, canonicalDocument.contentDigest)
        XCTAssertEqual(canonicalWhileOverlayActive?.revisions, created.workspace?.revisions)
        XCTAssertEqual(canonicalWhileOverlayActive?.health, .writable)

        // Transient outcome path: a catalog-revision conflict is recorded while the overlay shadows
        // read routing. The outcome must still report canonical record state.
        let transientEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 999_999,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        )
        let transient = await runtime.workspaceStore.execute(transientEnvelope)
        XCTAssertEqual(transient.disposition, .conflict)
        XCTAssertEqual(
            transient.workspace?.document.contentDigest,
            canonicalDocument.contentDigest,
            "Transient command outcomes must report canonical state, not the read overlay."
        )
        XCTAssertEqual(transient.resultingDigest, canonicalDocument.contentDigest)

        // A deduplicated replay of a transient failure is not a completed canonical transition:
        // the read overlay must survive it.
        let replayedTransient = await runtime.workspaceStore.execute(transientEnvelope)
        XCTAssertEqual(replayedTransient.disposition, .deduplicated)
        let overlayAfterTransientReplay = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(
            overlayAfterTransientReplay?.document.contentDigest,
            overlayDocument.contentDigest,
            "A replayed transient failure must not supersede the read overlay."
        )

        // Global dedup replay path: delete drops the canonical record but keeps the recorded
        // operation. A replay while a fresh overlay is registered must not resurrect overlay state.
        let deleteEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        )
        let deleted = await runtime.workspaceStore.execute(deleteEnvelope)
        XCTAssertEqual(deleted.disposition, .applied)

        _ = await runtime.workspaceStore.registerReadDocument(overlayDocument)
        let replayed = await runtime.workspaceStore.execute(deleteEnvelope)
        XCTAssertEqual(replayed.disposition, .deduplicated)
        XCTAssertNil(
            replayed.workspace,
            "Global dedup replay must report canonical (absent) state, not the read overlay."
        )
        let overlayAfterCompletedReplay = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertNil(
            overlayAfterCompletedReplay,
            "A deduplicated replay of a completed command must supersede the read overlay exactly like its original execution."
        )
    }

    func testSubscriptionBootstrapsBeforePublishingFirstProjection() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        let subscription = await runtime.workspaceStore.subscribe()

        XCTAssertTrue(subscription.snapshot.isBootstrapped)
        XCTAssertEqual(subscription.snapshot.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        XCTAssertEqual(subscription.snapshot.workspaces.first?.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
    }

    func testLegacyCatalogMigrationUsesCanonicalSanitizedWorkspaceDirectory() async throws {
        let fixture = try Fixture.make(workspaceName: "  Team / Docs  ")
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        try await runtime.start()
        let snapshot = await runtime.workspaceStore.snapshot()
        let migrated = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(migrated.document.workspaceID, fixture.workspaceID)
        XCTAssertEqual(migrated.document.fileURL, fixture.workspaceFile)
        XCTAssertEqual(migrated.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
    }

    func testExplicitCreatePersistsAndDeletePrunesCatalogDespiteStaleLegacyIndex() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let document = try fixture.document(prompt: "created")
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        ))

        XCTAssertEqual(created.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), document.documentBytes)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let restored = await restarted.workspaceStore.snapshot()
        XCTAssertEqual(restored.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        let deleted = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: restored.catalogRevision,
            expectedWorkspaceRevision: restored.workspaces.first?.revisions.workingRevision,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(deleted.disposition, .applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        _ = await restarted.shutdown()
        try fixture.writeLegacyIndex()

        // The intentionally stale legacy index still names the workspace. Runtime catalog
        // deletion truth must prevent resurrection or false degraded state.
        let finalRuntime = fixture.runtime(generation: 3)
        try await finalRuntime.start()
        let finalSnapshot = await finalRuntime.workspaceStore.snapshot()
        XCTAssertTrue(finalSnapshot.workspaces.isEmpty)
        XCTAssertEqual(finalSnapshot.health, .writable)
    }

    func testDeleteKeepsAuthoritativeTombstoneWhenArtifactCleanupFails() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let snapshot = await runtime.workspaceStore.snapshot()
        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        let workspaceDirectory = fixture.workspaceFile.deletingLastPathComponent()
        let workspaceRoot = workspaceDirectory.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: workspaceDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: workspaceRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workspaceRoot.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workspaceDirectory.path
            )
        }

        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: snapshot.catalogRevision,
            expectedWorkspaceRevision: workspace.revisions.workingRevision,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        )
        let deleted = await runtime.workspaceStore.execute(envelope)

        XCTAssertEqual(deleted.disposition, .applied)
        XCTAssertNil(deleted.errorCode)
        XCTAssertTrue(deleted.diagnostic?.hasPrefix("artifact_cleanup_incomplete:") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDirectory.path))
        let authoritativeAfter = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(authoritativeAfter.workspaces.isEmpty)

        let replayed = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(replayed.disposition, .deduplicated)
        XCTAssertEqual(replayed.diagnostic, deleted.diagnostic)
        let authoritativeAfterReplay = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(authoritativeAfterReplay.workspaces.isEmpty)

        _ = await runtime.shutdown()
        let restartedRuntime = fixture.runtime()
        try await restartedRuntime.start()
        defer { Task { _ = await restartedRuntime.shutdown() } }
        let replayedAfterRestart = await restartedRuntime.workspaceStore.execute(envelope)
        XCTAssertEqual(replayedAfterRestart.disposition, .deduplicated)
        XCTAssertEqual(replayedAfterRestart.diagnostic, deleted.diagnostic)
        let authoritativeAfterRestart = await restartedRuntime.workspaceStore.snapshot()
        XCTAssertTrue(authoritativeAfterRestart.workspaces.isEmpty)
    }

    func testRecreateSameWorkspaceIDClearsDeletionSidecarAcrossRestart() async throws {
        let fixture = try Fixture.make(includeWorkspace: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let original = try fixture.document(
            prompt: "created before delete",
            name: "Renamed before deletion"
        )
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(original)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let workspaceDirectory = fixture.workspaceFile.deletingLastPathComponent()
        let retainedArtifact = workspaceDirectory
            .appendingPathComponent("Chats", isDirectory: true)
            .appendingPathComponent("old-chat.json")
        try FileManager.default.createDirectory(
            at: retainedArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: retainedArtifact)
        let deleted = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: created.catalogRevision,
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(deleted.disposition, .applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDirectory.path))

        let recreatedDocument = try fixture.document(prompt: "recreated identity survives restart")
        let recreated = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: deleted.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(recreatedDocument)
        ))
        XCTAssertEqual(recreated.disposition, .applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedArtifact.path))
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let restored = await restarted.workspaceStore.snapshot()
        XCTAssertEqual(restored.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        XCTAssertEqual(restored.workspaces.first?.document.documentBytes, recreatedDocument.documentBytes)
        XCTAssertEqual(restored.health, .writable)
    }

    func testPendingSaveJournalRecoversCommittedDocumentWithoutManufacturedConflict() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let changed = try fixture.document(prompt: "crash-safe")
        let working = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))
        XCTAssertEqual(working.disposition, .applied)
        _ = await runtime.shutdown()

        let journalURL = try XCTUnwrap(
            try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
                .first { $0.path.contains("working-journals") && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json" }
        )
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let journal = try decoder.decode(DomainWorkingJournal.self, from: Data(contentsOf: journalURL))
        let operationID = UUID()
        let pending = DomainWorkingJournal(
            workspaceID: journal.workspaceID,
            fileURL: journal.fileURL,
            revisions: journal.revisions,
            savedDigest: journal.savedDigest,
            workingDocument: changed.documentBytes,
            contextRevisions: journal.contextRevisions,
            contextDigests: journal.contextDigests,
            contextTombstones: journal.contextTombstones,
            operations: journal.operations,
            pendingSave: DomainPendingSave(operationID: operationID, documentDigest: changed.contentDigest),
            updatedAt: Date()
        )
        try encoder.encode(pending).write(to: journalURL, options: .atomic)
        try changed.documentBytes.write(to: fixture.workspaceFile, options: .atomic)

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recoveredSnapshot = await restarted.workspaceStore.snapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot.workspaces.first)
        XCTAssertEqual(recovered.health, .writable)
        XCTAssertNil(recovered.revisions.dirtyRevision)
        XCTAssertEqual(recovered.revisions.savedRevision, recovered.revisions.workingRevision)
        XCTAssertEqual(recovered.document.documentBytes, changed.documentBytes)

        let editedAfterRecovery = try fixture.document(prompt: "edited after recovery")
        let edit = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(editedAfterRecovery)
        ))
        XCTAssertEqual(edit.disposition, .applied)
        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: edit.after?.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertNil(save.after?.dirtyRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), editedAfterRecovery.documentBytes)
    }

    func testContendedLockIsCancellableAndDoesNotBlockAuthoritySnapshots() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let first = try await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "seed lock"))
        ))
        XCTAssertEqual(first.disposition, .applied)

        let lockURL = try XCTUnwrap(try allFiles(
            below: fixture.storageRoot.appendingPathComponent("DomainRuntime", isDirectory: true)
        ).first {
            $0.lastPathComponent == "workspace-\(fixture.workspaceID.uuidString).lock"
        })
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let blockedDocument = try fixture.document(prompt: "blocked")
        let mutation = Task {
            await runtime.workspaceStore.execute(.init(
                operationID: UUID(),
                expectedWorkspaceRevision: 1,
                origin: .standalone,
                command: .replaceWorkingDocument(blockedDocument)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = await runtime.workspaceStore.snapshot()
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(250))
        XCTAssertEqual(snapshot.workspaces.first?.revisions.workingRevision, 1)
        mutation.cancel()
        let cancelled = await mutation.value
        XCTAssertEqual(cancelled.disposition, .failed)
        XCTAssertEqual(cancelled.errorCode, .cancelled)
    }

    func testBootstrapIsReadOnlyAndFirstWorkingMutationCreatesJournalAndRollbackWithoutRewritingSavedDocument() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.workspaceFile)
        let runtime = fixture.runtime(legacyDefaults: ["GlobalCustomStorageURL": Data("legacy".utf8)])

        try await runtime.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storageRoot.appendingPathComponent("DomainRuntime").path))
        let initial = await runtime.workspaceStore.snapshot()
        XCTAssertEqual(initial.workspaces.first?.revisions, .initial)

        let changed = try fixture.document(prompt: "working")
        let outcome = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))

        XCTAssertEqual(outcome.disposition, .applied)
        XCTAssertEqual(outcome.after, .init(workingRevision: 1, savedRevision: 0, dirtyRevision: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), original)
        let runtimeFiles = try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json" })
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "manifest.json" })
        XCTAssertTrue(runtimeFiles.contains { $0.lastPathComponent == "legacy-runtime-defaults.json" })
    }

    func testExplicitSaveAdvancesSavedRevisionAndRestartRecoversDirtyWorkingState() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let changed = try fixture.document(prompt: "recover me")
        let mutation = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        ))
        XCTAssertEqual(mutation.disposition, .applied)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.document.documentBytes, changed.documentBytes)
        XCTAssertEqual(recovered?.revisions.dirtyRevision, 1)

        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertEqual(save.after, .init(workingRevision: 1, savedRevision: 1, dirtyRevision: nil))
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), changed.documentBytes)
    }

    func testOperationDeduplicationCollisionAndWriterCASAreDeterministic() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = fixture.runtime(runtimeID: UUID())
        let second = fixture.runtime(runtimeID: UUID())
        try await first.start()
        try await second.start()
        let operationID = UUID()
        let changed = try fixture.document(prompt: "first writer")
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        )

        let applied = await first.workspaceStore.execute(envelope)
        let duplicate = await first.workspaceStore.execute(envelope)
        XCTAssertEqual(applied.disposition, .applied)
        XCTAssertEqual(duplicate.disposition, .deduplicated)

        let unchangedOperationID = UUID()
        let unchangedEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: unchangedOperationID,
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(changed)
        )
        let unchanged = await first.workspaceStore.execute(unchangedEnvelope)
        XCTAssertEqual(unchanged.disposition, .unchanged)
        let restarted = fixture.runtime(runtimeID: UUID())
        try await restarted.start()
        let restartedDuplicate = await restarted.workspaceStore.execute(unchangedEnvelope)
        XCTAssertEqual(restartedDuplicate.disposition, .deduplicated)

        let collision = try await first.workspaceStore.execute(.init(
            operationID: operationID,
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "collision"))
        ))
        XCTAssertEqual(collision.errorCode, .operationIDCollision)

        let staleDocument = try fixture.document(prompt: "stale runtime intent replayed")
        let staleWriter = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(staleDocument)
        ))
        XCTAssertEqual(staleWriter.disposition, .applied)
        XCTAssertEqual(staleWriter.after?.workingRevision, 2)
        XCTAssertEqual(staleWriter.workspace?.document.documentBytes, staleDocument.documentBytes)

        let firstCreatedID = UUID()
        let secondCreatedID = UUID()
        let firstCreatedURL = fixture.storageRoot
            .appendingPathComponent("Workspaces/Workspace-First-\(firstCreatedID.uuidString)/workspace.json")
        let secondCreatedURL = fixture.storageRoot
            .appendingPathComponent("Workspaces/Workspace-Second-\(secondCreatedID.uuidString)/workspace.json")
        let firstCreatedDocument = try fixture.document(
            workspaceID: firstCreatedID,
            contextID: UUID(),
            fileURL: firstCreatedURL,
            prompt: "catalog winner"
        )
        let secondCreatedDocument = try fixture.document(
            workspaceID: secondCreatedID,
            contextID: UUID(),
            fileURL: secondCreatedURL,
            prompt: "catalog stale writer"
        )
        let catalogWinner = await first.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(firstCreatedDocument)
        ))
        XCTAssertEqual(catalogWinner.disposition, .applied)
        let staleCatalogWriter = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(secondCreatedDocument)
        ))
        XCTAssertEqual(staleCatalogWriter.disposition, .conflict)
        XCTAssertEqual(staleCatalogWriter.errorCode, .stateConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCreatedURL.path))
    }

    func testContextCASFailsClosedWhenOneCommandChangesMultipleContexts() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let secondContextID = UUID()
        let twoContexts = try fixture.document(prompts: [
            fixture.contextID: "first initial",
            secondContextID: "second initial"
        ])
        let seeded = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(twoContexts)
        ))
        XCTAssertEqual(seeded.disposition, .applied)
        let bothChanged = try fixture.document(prompts: [
            fixture.contextID: "first changed",
            secondContextID: "second changed"
        ])
        let rejected = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            expectedContextRevision: 1,
            origin: .standalone,
            command: .replaceWorkingDocument(bothChanged)
        ))
        XCTAssertEqual(rejected.disposition, .conflict)
        XCTAssertEqual(rejected.diagnostic, "context_revision_scope_mismatch")
    }

    func testSuccessfulExternalReloadSupersedesReadOverlay() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        // Shadow the clean canonical record with a divergent read overlay.
        let overlayDocument = try fixture.document(prompt: "overlay")
        let overlay = await runtime.workspaceStore.registerReadDocument(overlayDocument)
        let shadowed = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(shadowed?.document.contentDigest, overlay.document.contentDigest)

        // A successful external reload of a changed saved document is a completed canonical
        // transition: read routing must serve the reloaded document, not the stale overlay.
        let external = try fixture.document(prompt: "external clean")
        try external.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        await runtime.workspaceStore.reloadExternalChanges()

        let routed = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(
            routed?.document.contentDigest,
            external.contentDigest,
            "External reload must clear the read overlay so reads serve the reloaded canonical document."
        )
        XCTAssertNotEqual(routed?.document.contentDigest, overlayDocument.contentDigest)

        // An unchanged follow-up reload must not resurrect anything.
        await runtime.workspaceStore.reloadExternalChanges()
        let stable = await runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(stable?.document.contentDigest, external.contentDigest)
    }

    func testExternalReloadPreservesDirtyLocalDocumentWithoutUserAction() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        let external = try fixture.document(prompt: "external clean")
        try external.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        let cleanReload = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(cleanReload, .changed)
        var snapshot = await runtime.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(snapshot?.document.documentBytes, external.documentBytes)
        XCTAssertNil(snapshot?.revisions.dirtyRevision)

        let working = try fixture.document(prompt: "local dirty preserved")
        let result = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: snapshot?.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(working)
        ))
        XCTAssertEqual(result.disposition, .applied)

        let changedExternal = try fixture.document(prompt: "external saved baseline")
        try changedExternal.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        let dirtyReload = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(dirtyReload, .changed)
        snapshot = await runtime.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(snapshot?.health, .writable)
        XCTAssertEqual(snapshot?.document.documentBytes, working.documentBytes)
        XCTAssertNotNil(snapshot?.revisions.dirtyRevision)
        _ = await runtime.shutdown()

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.document.documentBytes, working.documentBytes)
        XCTAssertEqual(recovered?.health, .writable)
        XCTAssertNotNil(recovered?.revisions.dirtyRevision)
        let stableReload = await restarted.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(stableReload, .unchanged)

        let save = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered?.revisions.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(save.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), working.documentBytes)
    }

    func testDirtyExternalRebaseRefreshesWhenSameWorkingRevisionWasSavedByAnotherRuntime() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = fixture.runtime(runtimeID: UUID())
        let second = fixture.runtime(runtimeID: UUID())
        try await first.start()
        try await second.start()

        let local = try fixture.document(prompt: "first runtime captured local working bytes")
        let firstWrite = await first.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(local)
        ))
        XCTAssertEqual(firstWrite.disposition, .applied)
        let firstRevisions = try XCTUnwrap(firstWrite.after)
        XCTAssertEqual(firstRevisions.workingRevision, 1)
        XCTAssertEqual(firstRevisions.savedRevision, 0)
        XCTAssertEqual(firstRevisions.dirtyRevision, 1)

        let secondAdoption = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(local)
        ))
        XCTAssertEqual(secondAdoption.disposition, .unchanged)
        XCTAssertEqual(secondAdoption.after, firstRevisions)
        let secondSave = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: firstRevisions.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(secondSave.disposition, .applied)
        let secondRevisions = try XCTUnwrap(secondSave.after)
        XCTAssertEqual(secondRevisions.workingRevision, 1)
        XCTAssertEqual(secondRevisions.savedRevision, 1)
        XCTAssertNil(secondRevisions.dirtyRevision)

        let staleFirstSnapshot = await first.workspaceStore.snapshot()
        let staleFirst = try XCTUnwrap(staleFirstSnapshot.workspaces.first)
        XCTAssertEqual(staleFirst.revisions, firstRevisions)
        XCTAssertEqual(staleFirst.document.documentBytes, local.documentBytes)

        let activity = await first.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .changed)
        let reconciledSnapshot = await first.workspaceStore.snapshot()
        let reconciled = try XCTUnwrap(reconciledSnapshot.workspaces.first)
        XCTAssertEqual(reconciled.health, .writable)
        XCTAssertEqual(reconciled.revisions, secondRevisions)
        XCTAssertEqual(reconciled.document.documentBytes, local.documentBytes)

        let journalURL = try XCTUnwrap(
            try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
                .first {
                    $0.path.contains("working-journals")
                        && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json"
                }
        )
        let journal = try JSONDecoder().decode(
            DomainWorkingJournal.self,
            from: Data(contentsOf: journalURL)
        )
        XCTAssertNil(
            journal.workingDocument,
            "A clean conflict rebase must not leave crash recovery working bytes."
        )

        _ = await first.shutdown()
        _ = await second.shutdown()
        let restarted = fixture.runtime(runtimeID: UUID(), generation: 2)
        try await restarted.start()
        let recoveredSnapshot = await restarted.workspaceStore.snapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot.workspaces.first)
        XCTAssertEqual(recovered.health, .writable)
        XCTAssertEqual(recovered.revisions, secondRevisions)
        XCTAssertEqual(recovered.document.documentBytes, local.documentBytes)
    }

    func testDirtyExternalRebaseReplaysCapturedLocalDocumentWhenJournalAdvancesBeforeCommit() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = fixture.runtime(runtimeID: UUID())
        let second = fixture.runtime(runtimeID: UUID())
        try await first.start()
        try await second.start()

        let firstOperationID = UUID()
        let firstDocument = try fixture.document(prompt: "first runtime local working state")
        let firstWrite = await first.workspaceStore.execute(.init(
            operationID: firstOperationID,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(firstDocument)
        ))
        XCTAssertEqual(firstWrite.disposition, .applied)
        XCTAssertEqual(firstWrite.after?.workingRevision, 1)

        let secondOperationID = UUID()
        let secondDocument = try fixture.document(prompt: "second runtime advances journal")
        let secondEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: secondOperationID,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(secondDocument)
        )
        let secondStore = second.workspaceStore
        let workspaceID = fixture.workspaceID
        await first.workspaceStore.testSetBeforeExternalReconciliation { detectedWorkspaceID in
            guard detectedWorkspaceID == workspaceID else { return }
            let secondWrite = await secondStore.execute(secondEnvelope)
            XCTAssertEqual(secondWrite.disposition, .applied)
            XCTAssertEqual(secondWrite.after?.workingRevision, 2)
        }

        let external = try fixture.document(prompt: "external saved baseline")
        try external.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        let activity = await first.workspaceStore.reloadExternalChanges()
        await first.workspaceStore.testSetBeforeExternalReconciliation(nil)
        XCTAssertEqual(activity, .changed)
        let firstSnapshot = await first.workspaceStore.snapshot()
        let reconciled = try XCTUnwrap(firstSnapshot.workspaces.first)
        XCTAssertEqual(reconciled.health, .writable)
        XCTAssertEqual(reconciled.revisions.workingRevision, 3)
        XCTAssertNotNil(reconciled.revisions.dirtyRevision)
        XCTAssertEqual(reconciled.document.documentBytes, firstDocument.documentBytes)

        let restarted = fixture.runtime(runtimeID: UUID(), generation: 2)
        try await restarted.start()
        let restartedSnapshot = await restarted.workspaceStore.snapshot()
        let recovered = try XCTUnwrap(restartedSnapshot.workspaces.first)
        XCTAssertEqual(recovered.health, .writable)
        XCTAssertEqual(recovered.revisions.workingRevision, 3)
        XCTAssertEqual(recovered.document.documentBytes, firstDocument.documentBytes)
        let replayedSecondWrite = await restarted.workspaceStore.execute(secondEnvelope)
        XCTAssertEqual(replayedSecondWrite.disposition, .deduplicated)
        XCTAssertEqual(
            replayedSecondWrite.workspace?.document.documentBytes,
            firstDocument.documentBytes
        )
    }

    func testSaveReplaysCapturedLocalDocumentAfterJournalRevisionRace() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = fixture.runtime(runtimeID: UUID())
        let second = fixture.runtime(runtimeID: UUID())
        try await first.start()
        try await second.start()

        let local = try fixture.document(prompt: "local working state saved after revision race")
        let localWrite = await first.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(local)
        ))
        XCTAssertEqual(localWrite.disposition, .applied)
        XCTAssertEqual(localWrite.after?.workingRevision, 1)

        let competing = try fixture.document(prompt: "competing runtime journal state")
        let competingWrite = await second.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(competing)
        ))
        XCTAssertEqual(competingWrite.disposition, .applied)
        XCTAssertEqual(competingWrite.after?.workingRevision, 2)

        let saved = await first.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: localWrite.after?.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(saved.after?.workingRevision, 3)
        XCTAssertEqual(saved.after?.savedRevision, 3)
        XCTAssertNil(saved.after?.dirtyRevision)
        XCTAssertEqual(saved.workspace?.document.documentBytes, local.documentBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), local.documentBytes)

        _ = await first.shutdown()
        _ = await second.shutdown()
        let restarted = fixture.runtime(runtimeID: UUID(), generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.health, .writable)
        XCTAssertNil(recovered?.revisions.dirtyRevision)
        XCTAssertEqual(recovered?.document.documentBytes, local.documentBytes)
    }

    func testDomainDecodeIgnoresMalformedAndComposedDuplicateStashedIdentityClaims() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let sessionID = UUID()
        let composed = try fixture.agentDocument(
            prompt: "composed agent",
            activeAgentSessionID: sessionID,
            isPinned: true,
            location: .composed
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: composed.documentBytes) as? [String: Any]
        )
        let composedTab = try XCTUnwrap((object["composeTabs"] as? [[String: Any]])?.first)
        object["stashedTabs"] = [
            ["malformed": true],
            [
                "id": UUID().uuidString,
                "tab": composedTab,
                "stashedAt": 0
            ]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: fixture.workspaceFile
        )

        XCTAssertEqual(decoded.metadata.agentIdentityClaims, composed.metadata.agentIdentityClaims)
    }

    func testSaveTimeExternalChangeRebasesAndSavesLocalDocumentAutomatically() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let initialCatalog = await runtime.workspaceStore.snapshot()
        let initial = try XCTUnwrap(initialCatalog.workspaces.first)
        let local = try fixture.document(prompt: "local dirty state retained across save recovery")
        let working = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: initial.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(local)
        ))
        XCTAssertEqual(working.disposition, .applied)

        let external = try fixture.document(prompt: "external bytes changed immediately before explicit save")
        try external.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        let saved = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: working.after?.workingRevision,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(saved.workspace?.health, .writable)
        XCTAssertNil(saved.after?.dirtyRevision)
        XCTAssertEqual(saved.workspace?.document.documentBytes, local.documentBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceFile), local.documentBytes)

        _ = await runtime.shutdown()
        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let recovered = await restarted.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(recovered?.health, .writable)
        XCTAssertNil(recovered?.revisions.dirtyRevision)
        XCTAssertEqual(recovered?.document.documentBytes, local.documentBytes)
    }

    func testCatalogIdentityMismatchIsUnavailableWithoutMisrouting() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.workspaceFile)) as? [String: Any]
        )
        let embeddedWorkspaceID = UUID()
        object["id"] = embeddedWorkspaceID.uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.workspaceFile, options: .atomic)

        let runtime = fixture.runtime()
        try await runtime.start()
        let snapshot = await runtime.workspaceStore.snapshot()
        XCTAssertTrue(snapshot.workspaces.isEmpty)
        let catalogIdentity = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(catalogIdentity.disposition, .readOnly)
        XCTAssertEqual(catalogIdentity.diagnostic, "workspace_document_unavailable")
        let embeddedIdentity = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: embeddedWorkspaceID)
        ))
        XCTAssertEqual(embeddedIdentity.disposition, .invalid)
        XCTAssertEqual(embeddedIdentity.diagnostic, "workspace_not_found")
    }

    func testDuplicateCatalogAndContextIDsDegradeInsteadOfTrapping() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let indexURL = fixture.storageRoot
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("workspacesIndex.json")
        var index = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]]
        )
        try index.append(XCTUnwrap(index.first))
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: indexURL, options: .atomic)

        let runtime = fixture.runtime()
        try await runtime.start()
        let snapshot = await runtime.workspaceStore.snapshot()
        XCTAssertEqual(snapshot.health, .degradedReadOnly(reason: "duplicate_workspace_catalog_id"))
        XCTAssertTrue(snapshot.workspaces.isEmpty)

        var documentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.workspaceFile)) as? [String: Any]
        )
        var contexts = try XCTUnwrap(documentObject["composeTabs"] as? [[String: Any]])
        try contexts.append(XCTUnwrap(contexts.first))
        documentObject["composeTabs"] = contexts
        let duplicateContextBytes = try JSONSerialization.data(
            withJSONObject: documentObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try DomainWorkspaceDocument.decode(
                documentBytes: duplicateContextBytes,
                fileURL: fixture.workspaceFile
            )
        ) { error in
            XCTAssertEqual(error as? DomainWorkspaceDocumentError, .invalidContext(fixture.contextID))
        }

        let validDocument = try fixture.document(prompt: "saved")
        let duplicateMetadata = DomainWorkspaceMetadata(
            workspaceID: validDocument.metadata.workspaceID,
            schemaVersion: validDocument.metadata.schemaVersion,
            name: validDocument.metadata.name,
            repoPaths: validDocument.metadata.repoPaths,
            customStoragePath: validDocument.metadata.customStoragePath,
            isSystemWorkspace: validDocument.metadata.isSystemWorkspace,
            isHiddenInMenus: validDocument.metadata.isHiddenInMenus,
            isEphemeral: validDocument.metadata.isEphemeral,
            activeContextID: validDocument.metadata.activeContextID,
            contexts: validDocument.metadata.contexts + validDocument.metadata.contexts
        )
        let duplicateDocument = DomainWorkspaceDocument(
            workspaceID: validDocument.workspaceID,
            fileURL: validDocument.fileURL,
            documentBytes: duplicateContextBytes,
            metadata: duplicateMetadata
        )
        let rejected = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            origin: .standalone,
            command: .replaceWorkingDocument(duplicateDocument)
        ))
        XCTAssertEqual(rejected.disposition, .invalid)
        XCTAssertEqual(rejected.errorCode, .invalidDocument)
        XCTAssertEqual(rejected.diagnostic, "duplicate_context_id")
    }

    func testCorruptWorkingDocumentFallsBackToSavedBytesReadOnly() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let working = try await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "working before corruption"))
        ))
        XCTAssertEqual(working.disposition, .applied)
        _ = await runtime.shutdown()

        let journalURL = try XCTUnwrap(
            try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
                .first {
                    $0.path.contains("working-journals")
                        && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json"
                }
        )
        let decoder = JSONDecoder()
        let journal = try decoder.decode(DomainWorkingJournal.self, from: Data(contentsOf: journalURL))
        let corrupt = DomainWorkingJournal(
            workspaceID: journal.workspaceID,
            fileURL: journal.fileURL,
            revisions: journal.revisions,
            savedDigest: journal.savedDigest,
            workingDocument: Data("not-json".utf8),
            contextRevisions: journal.contextRevisions,
            contextDigests: journal.contextDigests,
            contextTombstones: journal.contextTombstones,
            operations: journal.operations,
            pendingSave: journal.pendingSave,
            updatedAt: Date()
        )
        try JSONEncoder().encode(corrupt).write(to: journalURL, options: .atomic)

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let restartedSnapshot = await restarted.workspaceStore.snapshot()
        let recovered = try XCTUnwrap(restartedSnapshot.workspaces.first)
        XCTAssertEqual(recovered.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
        XCTAssertEqual(recovered.health, .degradedReadOnly(reason: "working_document_decode_failed"))
        XCTAssertNil(recovered.revisions.dirtyRevision)
        let rejected = try await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "must not replace fallback"))
        ))
        XCTAssertEqual(rejected.disposition, .readOnly)
    }

    func testFutureJournalDegradesToReadOnlyWithoutDiscardingSavedDocument() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        _ = try await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "journal"))
        ))
        _ = await runtime.shutdown()
        let journal = try XCTUnwrap(
            try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
                .first {
                    $0.path.contains("working-journals")
                        && $0.lastPathComponent == "\(fixture.workspaceID.uuidString).json"
                }
        )
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let runtimeSnapshot = await restarted.snapshot()
        let workspace = await restarted.workspaceStore.snapshot().workspaces.first
        // Workspace-scoped damage must not brick the whole runtime: the catalog stays
        // writable while the damaged workspace alone rejects mutations.
        XCTAssertEqual(runtimeSnapshot.lifecycle, .ready)
        XCTAssertEqual(runtimeSnapshot.workspaceHealth, .writable)
        XCTAssertEqual(workspace?.document.documentBytes, try Data(contentsOf: fixture.workspaceFile))
        XCTAssertFalse(workspace?.health.acceptsMutations ?? true)
        let rejected = try await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: workspace?.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "must not apply"))
        ))
        XCTAssertEqual(rejected.disposition, .readOnly)
        XCTAssertEqual(rejected.errorCode, .workspaceReadOnlyDegraded)
        XCTAssertEqual(rejected.diagnostic, workspace?.health.reason)
    }

    func testTwoWindowCaptureRevisionConflictPreventsLostUpdate() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        // Both windows capture their CAS expectation at revision 0, before either commits.
        let windowA = try fixture.document(prompt: "window A capture")
        let windowB = try fixture.document(prompt: "window B capture")
        let firstOperationID = UUID()
        let winner = await runtime.workspaceStore.execute(.init(
            operationID: firstOperationID,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: 1),
            command: .replaceWorkingDocument(windowA)
        ))
        XCTAssertEqual(winner.disposition, .applied)

        let loser = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: 2),
            command: .replaceWorkingDocument(windowB)
        ))
        XCTAssertEqual(loser.disposition, .conflict)
        XCTAssertEqual(loser.errorCode, .stateConflict)
        XCTAssertEqual(loser.diagnostic, "workspace_revision_mismatch")
        // The losing window receives the authoritative state instead of silently
        // overwriting it with its up-to-200ms-stale capture.
        XCTAssertEqual(loser.workspace?.document.documentBytes, windowA.documentBytes)

        let refreshedRevision = try XCTUnwrap(loser.workspace?.revisions.workingRevision)
        let retry = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: refreshedRevision,
            origin: .appPresentation(windowID: 2),
            command: .replaceWorkingDocument(windowB)
        ))
        XCTAssertEqual(retry.disposition, .applied)
        let final = await runtime.workspaceStore.snapshot().workspaces.first
        XCTAssertEqual(final?.document.documentBytes, windowB.documentBytes)

        // The winner's original operation still deduplicates after the retry landed,
        // proving journal-adopted operation history survived the interleaving.
        let replay = await runtime.workspaceStore.execute(.init(
            operationID: firstOperationID,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: 1),
            command: .replaceWorkingDocument(windowA)
        ))
        XCTAssertEqual(replay.disposition, .deduplicated)
    }

    func testBoundedOperationIndexEvictsOldestDeterministicallyAtScales() {
        func operation(_ ordinal: Int) -> DomainRecordedOperation {
            DomainRecordedOperation(
                fingerprint: "fingerprint-\(ordinal)",
                recordedAt: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                outcome: DomainCommandOutcome(
                    operationID: UUID(),
                    disposition: .applied,
                    before: nil,
                    after: nil,
                    catalogRevision: 0,
                    resultingDigest: nil
                )
            )
        }

        for scale in [1, 10, 100] {
            let capacity = 10
            var index = BoundedDomainOperationIndex(capacity: capacity)
            var inserted: [DomainRecordedOperation] = []
            for ordinal in 0 ..< scale {
                let recorded = operation(ordinal)
                inserted.append(recorded)
                index.insert(recorded)
            }
            XCTAssertEqual(index.count, min(scale, capacity), "scale \(scale)")
            for retained in inserted.suffix(capacity) {
                XCTAssertEqual(
                    index[retained.operationID]?.fingerprint,
                    retained.fingerprint,
                    "scale \(scale) retains the newest \(capacity) operations"
                )
            }
            for evicted in inserted.dropLast(capacity) {
                XCTAssertNil(index[evicted.operationID], "scale \(scale) evicts oldest first")
            }
        }

        // replace(with:) trims to the newest entries by recorded time, matching the
        // durable journal trim, so bootstrap and reload adoption stay bounded too.
        var replaced = BoundedDomainOperationIndex(capacity: 10)
        replaced.replace(with: (0 ..< 100).map(operation))
        XCTAssertEqual(replaced.count, 10)
    }

    func testUnavailableWorkspaceDegradesOnlyItselfAndRecoversWhenDocumentReturns() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let secondID = UUID()
        let secondURL = fixture.storageRoot
            .appendingPathComponent("Workspaces/Workspace-Second-\(secondID.uuidString)/workspace.json")
        let secondDocument = try fixture.document(
            workspaceID: secondID,
            contextID: UUID(),
            fileURL: secondURL,
            prompt: "second workspace"
        )
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(secondDocument)
        ))
        XCTAssertEqual(created.disposition, .applied)
        _ = await runtime.shutdown()

        // Simulate an unplugged volume: the document and its journal are unreachable.
        try FileManager.default.removeItem(at: secondURL)
        for journal in try allFiles(below: fixture.storageRoot.appendingPathComponent("DomainRuntime"))
            where journal.lastPathComponent == "\(secondID.uuidString).json"
        {
            try FileManager.default.removeItem(at: journal)
        }

        let restarted = fixture.runtime(generation: 2)
        try await restarted.start()
        let snapshot = await restarted.workspaceStore.snapshot()
        XCTAssertEqual(snapshot.health, .writable)
        XCTAssertEqual(snapshot.workspaces.map(\.document.workspaceID), [fixture.workspaceID])
        let runtimeSnapshot = await restarted.snapshot()
        XCTAssertEqual(runtimeSnapshot.lifecycle, .ready)

        // Mutating the unavailable workspace fails closed and scoped...
        let rejected = await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: nil,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: secondID)
        ))
        XCTAssertEqual(rejected.disposition, .readOnly)
        XCTAssertEqual(rejected.errorCode, .runtimeReadOnlyDegraded)
        XCTAssertEqual(rejected.diagnostic, "workspace_document_unavailable")

        // ...while the healthy workspace keeps full mutation authority.
        let healthy = try await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "healthy edit"))
        ))
        XCTAssertEqual(healthy.disposition, .applied)

        // The document returning is picked up by the reload probe and restores authority.
        try FileManager.default.createDirectory(
            at: secondURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try secondDocument.documentBytes.write(to: secondURL, options: .atomic)
        let activity = await restarted.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .changed)
        let recovered = await restarted.workspaceStore.workspaceSnapshot(secondID)
        XCTAssertEqual(recovered?.health, .writable)
        let applied = try await restarted.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: recovered?.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(
                workspaceID: secondID,
                contextID: UUID(),
                fileURL: secondURL,
                prompt: "second workspace edited"
            ))
        ))
        XCTAssertEqual(applied.disposition, .applied)
    }

    func testExternalReloadActivityReportsFastPathChangeAndRecovery() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()

        // No-change poll takes the metadata fast path and reports unchanged.
        var activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .unchanged)

        // Prove the fast path performs no document read: with unchanged metadata but an
        // unreadable file, a read-based probe would degrade instead of staying unchanged.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.workspaceFile.path
        )
        activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .unchanged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.workspaceFile.path
        )

        // A real external change is detected through the metadata delta.
        let changed = try fixture.document(prompt: "external change")
        try changed.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .changed)
        var workspace = await runtime.workspaceStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(workspace?.document.documentBytes, changed.documentBytes)

        // Invalid external bytes degrade only this workspace and keep recovery pending.
        try Data("not json".utf8).write(to: fixture.workspaceFile, options: .atomic)
        activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .recoveryPending)
        workspace = await runtime.workspaceStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(workspace?.health, .degradedReadOnly(reason: "external_workspace_decode_failed"))
        activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .recoveryPending)

        // Restoring the exact previously valid bytes recovers health even though the digest
        // matches saved authority and the document probe reports an unchanged payload.
        try changed.documentBytes.write(to: fixture.workspaceFile, options: .atomic)
        activity = await runtime.workspaceStore.reloadExternalChanges()
        XCTAssertEqual(activity, .changed)
        workspace = await runtime.workspaceStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(workspace?.health, .writable)
        XCTAssertEqual(workspace?.document.documentBytes, changed.documentBytes)
        let mutation = try await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: workspace?.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(prompt: "post recovery edit"))
        ))
        XCTAssertEqual(mutation.disposition, .applied)

        // Cancellation is a transient poll outcome, not evidence that saved bytes are invalid.
        let cancelledActivity = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runtime.workspaceStore.reloadExternalChanges()
        }.value
        XCTAssertEqual(cancelledActivity, .recoveryPending)
        workspace = await runtime.workspaceStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(workspace?.health, .writable)

        let persistence = DomainPersistenceCoordinator(
            configuration: runtime.configuration,
            identity: runtime.identity
        )
        let cancelledConflictRefresh = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await persistence.refreshWorkspace(
                workspaceID: fixture.workspaceID,
                fallbackFileURL: fixture.workspaceFile
            )
        }.value
        XCTAssertNil(cancelledConflictRefresh)
    }

    func testExpiredLaunchTokenIssueOrderCompactsWithinFixedStorageBound() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let context = DomainContextIdentity(
            workspaceID: fixture.workspaceID,
            contextID: fixture.contextID
        )

        var lastToken: DomainRunLaunchToken?
        for _ in 0 ..< DomainRoutingCoordinator.maximumTokenRecords * 3 {
            lastToken = try await runtime.routingCoordinator.issueLaunchToken(.init(
                runID: UUID(),
                context: context,
                expectedContextRevision: 0,
                windowID: nil,
                clientPrincipal: "test",
                providerIdentifier: "fixture",
                runPurpose: "bounded-order-regression",
                lifetime: .zero
            ))
        }
        let expired = try await runtime.routingCoordinator.redeemLaunchToken(
            material: XCTUnwrap(lastToken).material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(expired, .expired)

        let counts = await runtime.routingCoordinator.tokenBookkeepingCounts()
        XCTAssertLessThanOrEqual(counts.records, 1)
        XCTAssertLessThanOrEqual(
            counts.issueOrderStorage,
            DomainRoutingCoordinator.maximumTokenRecords * 2
        )
        XCTAssertEqual(counts.pendingRunContexts, 0)
    }

    func testBindRevisionCASRejectsStaleObservationAndAdmitsExactlyOneConcurrentWinner() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        try await runtime.start()
        let coordinator = runtime.routingCoordinator
        let context = DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.contextID)

        // Phase 1: a publication that advances routing after the reader observed its revision
        // makes the reader's CAS bind fail closed without mutating the reader's binding, and a
        // retry against the conflict outcome's re-observed revision succeeds.
        let readerID = UUID()
        let registeredReader = await coordinator.registerConnection(connectionID: readerID, operationID: UUID())
        let readerRegistration = try XCTUnwrap(registeredReader.snapshot.connections.first {
            $0.registration.connectionID == readerID
        }?.registration)
        let observedRevision = registeredReader.snapshot.revision

        let concurrentID = UUID()
        let registeredConcurrent = await coordinator.registerConnection(
            connectionID: concurrentID,
            operationID: UUID()
        )
        let concurrentRegistration = try XCTUnwrap(registeredConcurrent.snapshot.connections.first {
            $0.registration.connectionID == concurrentID
        }?.registration)
        let concurrentBound = await coordinator.bind(
            connection: concurrentRegistration,
            binding: .context(context, explicit: false),
            operationID: UUID()
        )
        XCTAssertEqual(concurrentBound.disposition, .applied)

        let stale = await coordinator.bind(
            connection: readerRegistration,
            binding: .context(context, explicit: true),
            operationID: UUID(),
            expectedRevision: observedRevision
        )
        XCTAssertEqual(stale.disposition, .conflict)
        XCTAssertEqual(stale.diagnostic, "routing_revision_mismatch")
        XCTAssertEqual(
            stale.snapshot.connections.first { $0.registration.connectionID == readerID }?.binding,
            .unbound,
            "A stale CAS bind must not mutate the connection binding."
        )

        let retried = await coordinator.bind(
            connection: readerRegistration,
            binding: .context(context, explicit: true),
            operationID: UUID(),
            expectedRevision: stale.snapshot.revision
        )
        XCTAssertEqual(retried.disposition, .applied)
        let handle = try await coordinator.resolveReadContext(connection: readerRegistration)
        XCTAssertEqual(handle.context, context)
        XCTAssertEqual(handle.bindingKind, .explicit)

        // Phase 2: concurrent CAS binds sharing one observed revision admit exactly one winner;
        // every loser reports the revision conflict and no binding is silently clobbered.
        var racers: [DomainConnectionRegistration] = []
        for _ in 0 ..< 8 {
            let racerID = UUID()
            let registered = await coordinator.registerConnection(connectionID: racerID, operationID: UUID())
            try racers.append(XCTUnwrap(registered.snapshot.connections.first {
                $0.registration.connectionID == racerID
            }?.registration))
        }
        let sharedRevision = await coordinator.snapshot().revision
        let outcomes = await withTaskGroup(of: DomainRoutingOutcome.self) { group in
            for racer in racers {
                group.addTask {
                    await coordinator.bind(
                        connection: racer,
                        binding: .context(context, explicit: false),
                        operationID: UUID(),
                        expectedRevision: sharedRevision
                    )
                }
            }
            var collected: [DomainRoutingOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        XCTAssertEqual(outcomes.count(where: { $0.disposition == .applied }), 1)
        XCTAssertEqual(outcomes.count(where: { $0.disposition == .conflict }), racers.count - 1)
        XCTAssertTrue(
            outcomes.filter { $0.disposition == .conflict }
                .allSatisfy { $0.diagnostic == "routing_revision_mismatch" }
        )
    }

    func testRoutingGenerationsAndRunLaunchTokensAreAuthoritativeAndSingleUse() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let runtime = fixture.runtime(generation: 9)
        try await runtime.start()
        let connectionID = UUID()
        let registered = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try XCTUnwrap(registered.snapshot.connections.first?.registration)
        let context = DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.contextID)
        let bound = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .context(context, explicit: true),
            operationID: UUID()
        )
        XCTAssertEqual(bound.disposition, .applied)
        let readHandle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        XCTAssertEqual(readHandle.context, context)
        XCTAssertEqual(readHandle.runtimeID, runtime.identity.runtimeID)
        XCTAssertEqual(readHandle.runtimeGeneration, runtime.identity.lifecycleGeneration)
        XCTAssertEqual(readHandle.connectionID, connectionID)
        XCTAssertEqual(readHandle.bindingKind, .explicit)

        _ = await runtime.routingCoordinator.openWindow(
            windowID: 99,
            activeWorkspaceID: nil,
            activeContextID: nil,
            presentationRevision: 1,
            operationID: UUID()
        )
        let refreshed = try await runtime.routingCoordinator.refreshReadContext(readHandle)
        XCTAssertEqual(refreshed.context, readHandle.context)
        XCTAssertEqual(refreshed.workspaceRevision, readHandle.workspaceRevision)
        XCTAssertEqual(refreshed.contextRevision, readHandle.contextRevision)
        XCTAssertNotEqual(refreshed.routingRevision, readHandle.routingRevision)

        _ = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let currentRegistration = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        XCTAssertEqual(currentRegistration.connectionID, connectionID)
        XCTAssertEqual(currentRegistration.runtimeID, runtime.identity.runtimeID)
        XCTAssertEqual(currentRegistration.generation, registration.generation + 1)
        let stale = await runtime.routingCoordinator.bind(
            connection: registration,
            binding: .unbound,
            operationID: UUID()
        )
        XCTAssertEqual(stale.disposition, .staleGeneration)
        let current = await runtime.routingCoordinator.bind(
            connection: currentRegistration,
            binding: .context(context, explicit: true),
            operationID: UUID()
        )
        XCTAssertEqual(current.disposition, .applied)
        let restartedHandle = try await runtime.routingCoordinator.resolveReadContext(connection: currentRegistration)
        XCTAssertEqual(restartedHandle.context, context)

        let token = try await runtime.routingCoordinator.issueLaunchToken(.init(
            runID: UUID(),
            context: context,
            expectedContextRevision: 0,
            windowID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture",
            runPurpose: "test"
        ))
        let rejectedIdentity = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "other",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(rejectedIdentity, .identityMismatch)
        let accepted = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        let runRegistration: DomainConnectionRegistration
        if case let .accepted(redemption) = accepted {
            runRegistration = redemption.binding.registration
        } else {
            XCTFail("Launch token was not accepted: \(accepted)")
            return
        }
        let runReleased = await runtime.routingCoordinator.unregisterConnection(
            runRegistration,
            operationID: UUID()
        )
        XCTAssertEqual(runReleased.disposition, .applied)
        XCTAssertFalse(runReleased.snapshot.connections.contains {
            $0.registration.connectionID == runRegistration.connectionID
        })
        let staleRunRelease = await runtime.routingCoordinator.unregisterConnection(
            runRegistration,
            operationID: UUID()
        )
        XCTAssertEqual(staleRunRelease.disposition, .unchanged)

        let firstWindow = await runtime.routingCoordinator.openWindow(
            windowID: 7,
            activeWorkspaceID: fixture.workspaceID,
            activeContextID: fixture.contextID,
            presentationRevision: 1,
            operationID: UUID()
        )
        let firstGeneration = try XCTUnwrap(firstWindow.snapshot.windows.first?.generation)
        _ = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: firstGeneration,
            operationID: UUID()
        )
        let secondWindow = await runtime.routingCoordinator.openWindow(
            windowID: 7,
            activeWorkspaceID: fixture.workspaceID,
            activeContextID: fixture.contextID,
            presentationRevision: 1,
            operationID: UUID()
        )
        let secondGeneration = try XCTUnwrap(secondWindow.snapshot.windows.first?.generation)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        let staleUnregister = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: firstGeneration,
            operationID: UUID()
        )
        XCTAssertEqual(staleUnregister.disposition, .staleGeneration)
        XCTAssertEqual(staleUnregister.snapshot.windows.first?.generation, secondGeneration)
        _ = await runtime.routingCoordinator.unregisterWindow(
            windowID: 7,
            generation: secondGeneration,
            operationID: UUID()
        )
        let latePublication = await runtime.routingCoordinator.registerWindow(
            DomainWindowDescriptor(
                windowID: 7,
                generation: secondGeneration,
                activeWorkspaceID: fixture.workspaceID,
                activeContextID: fixture.contextID,
                isClosing: false,
                presentationRevision: 2
            ),
            operationID: UUID()
        )
        XCTAssertEqual(latePublication.disposition, .staleGeneration)
        XCTAssertFalse(latePublication.snapshot.windows.contains { $0.windowID == 7 })

        let replay = await runtime.routingCoordinator.redeemLaunchToken(
            material: token.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(replay, .alreadyConsumed)

        let foreignRuntimeToken = try await runtime.routingCoordinator.issueLaunchToken(.init(
            runID: UUID(),
            context: context,
            expectedContextRevision: 0,
            windowID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture",
            runPurpose: "foreign-runtime"
        ))
        let foreignRuntime = await runtime.routingCoordinator.redeemLaunchToken(
            material: foreignRuntimeToken.material,
            runtimeID: UUID(),
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(foreignRuntime, .generationMismatch)

        let expiredToken = try await runtime.routingCoordinator.issueLaunchToken(.init(
            runID: UUID(),
            context: context,
            expectedContextRevision: 0,
            windowID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture",
            runPurpose: "expired",
            lifetime: .zero
        ))
        let expired = await runtime.routingCoordinator.redeemLaunchToken(
            material: expiredToken.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: 9,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "test",
            providerIdentifier: "fixture"
        )
        XCTAssertEqual(expired, .expired)
    }

    private func allFiles(below root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath }
    }
}

private struct Fixture {
    let root: URL
    let storageRoot: URL
    let workspaceID: UUID
    let contextID: UUID
    let workspaceName: String
    let workspaceFile: URL

    static func make(
        includeWorkspace: Bool = true,
        workspaceName: String = "Fixture"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-context-authority-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let workspaceRoot = storageRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let contextID = UUID()
        let directory = workspaceRoot.appendingPathComponent(
            DomainWorkspaceStoragePath.directoryName(name: workspaceName, id: workspaceID),
            isDirectory: true
        )
        let workspaceFile = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let fixture = Fixture(
            root: root,
            storageRoot: storageRoot,
            workspaceID: workspaceID,
            contextID: contextID,
            workspaceName: workspaceName,
            workspaceFile: workspaceFile
        )
        if includeWorkspace {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fixture.document(prompt: "saved").documentBytes.write(to: workspaceFile)
        }
        if includeWorkspace {
            try fixture.writeLegacyIndex()
        }
        return fixture
    }

    func writeLegacyIndex() throws {
        let index: [[String: Any]] = [[
            "id": workspaceID.uuidString,
            "name": workspaceName,
            "customStoragePath": NSNull(),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false
        ]]
        let workspaceRoot = storageRoot.appendingPathComponent("Workspaces", isDirectory: true)
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: workspaceRoot.appendingPathComponent("workspacesIndex.json"))
    }

    func runtime(
        runtimeID: UUID = UUID(),
        generation: UInt64 = 1,
        legacyDefaults: [String: Data] = [:]
    ) -> MCPDomainRuntime {
        MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "fixture-profile",
                storageDirectory: storageRoot,
                eventDirectory: root.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                legacyRuntimeDefaults: legacyDefaults,
                externalReloadInterval: nil
            ),
            runtimeID: runtimeID,
            lifecycleGeneration: generation
        )
    }

    func document(
        prompt: String,
        name: String = "Fixture",
        ephemeral: Bool = false
    ) throws -> DomainWorkspaceDocument {
        try document(
            workspaceID: workspaceID,
            contextID: contextID,
            fileURL: workspaceFile,
            prompt: prompt,
            name: name,
            ephemeral: ephemeral
        )
    }

    func document(prompts: [UUID: String]) throws -> DomainWorkspaceDocument {
        let ordered = prompts.sorted { $0.key.uuidString < $1.key.uuidString }
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Fixture",
            "repoPaths": ["/tmp/repo"],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": ordered.first?.key.uuidString ?? contextID.uuidString,
            "composeTabs": ordered.map { id, prompt in
                [
                    "id": id.uuidString,
                    "name": "Context",
                    "prompt": prompt,
                    "unknownFutureField": ["preserved": true]
                ] as [String: Any]
            },
            "unknownWorkspaceField": "preserved"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: workspaceFile)
    }

    func document(
        workspaceID: UUID,
        contextID: UUID,
        fileURL: URL,
        prompt: String,
        name: String = "Fixture",
        ephemeral: Bool = false
    ) throws -> DomainWorkspaceDocument {
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": name,
            "repoPaths": ["/tmp/repo"],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "ephemeralFlag": ephemeral,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": prompt,
                "unknownFutureField": ["preserved": true]
            ]],
            "unknownWorkspaceField": "preserved"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: fileURL)
    }

    func agentDocument(
        prompt: String,
        activeAgentSessionID: UUID,
        isPinned: Bool,
        location: DomainWorkspaceTabLocation
    ) throws -> DomainWorkspaceDocument {
        let tab: [String: Any] = [
            "id": contextID.uuidString,
            "name": "Context",
            "prompt": prompt,
            "activeAgentSessionID": activeAgentSessionID.uuidString,
            "isPinned": isPinned
        ]
        var object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": workspaceName,
            "repoPaths": ["/tmp/repo"],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "composeTabs": []
        ]
        switch location {
        case .composed:
            object["activeComposeTabID"] = contextID.uuidString
            object["composeTabs"] = [tab]
        case .stashed:
            object["stashedTabs"] = [[
                "id": UUID().uuidString,
                "tab": tab,
                "stashedAt": "2026-08-06T00:00:00Z"
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(documentBytes: data, fileURL: workspaceFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
