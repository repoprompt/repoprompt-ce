import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionDataServiceDeletionTests: XCTestCase {
    func testBatchDeleteIgnoresTraversalAndAbsoluteMetadataIndexFilenames() async throws {
        let cases: [(String, (URL) -> String)] = [
            ("traversal", { _ in "../external-sentinel.json" }),
            ("absolute", { storageURL in
                storageURL.appendingPathComponent("external-sentinel.json").path
            })
        ]

        for (label, filenameForStorageURL) in cases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
            let sentinelURL = fixture.storageURL.appendingPathComponent("external-sentinel.json")
            try Data("sentinel-\(label)".utf8).write(to: sentinelURL, options: .atomic)
            try writeMetadataIndex(filename: filenameForStorageURL(fixture.storageURL), fixture: fixture)

            let failures = await fixture.service.deleteAgentSessions(
                forComposeTabIDs: [fixture.tabID],
                for: fixture.workspace
            )

            XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path), label)
        }
    }

    func testDestructiveCommitFenceRefusesAfterAuthorityEndsAndKeepsTheFile() async throws {
        for authorityHolds in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
            let filename = agentSessionFilename(for: fixture.sessionID)
            let fileURL = fixture.agentSessionsFolder.appendingPathComponent(filename)
            try writeSession(
                AgentSession(
                    id: fixture.sessionID, workspaceID: fixture.workspace.id, composeTabID: fixture.tabID,
                    name: "Fenced deletion", itemCount: 0
                ),
                to: fileURL
            )
            // The fence runs after admission and writer draining, at the commit point itself.
            let fence: @Sendable () async -> Bool = { authorityHolds }
            do {
                try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                    try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
                }
                XCTAssertTrue(authorityHolds, "a refused fence must throw")
            } catch is AgentSessionDestructiveCommitRefused {
                XCTAssertFalse(authorityHolds)
            }
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: fileURL.path), !authorityHolds,
                "authority that ended before commit deletes nothing"
            )
        }
    }

    @MainActor
    func testPendingDeletionDoesNotDiscardAnAlreadyAdmittedSaveBeforeItsCommitFence() async throws {
        for authorityHolds in [false, true] {
            let registry = AgentSessionDeletionRegistry.shared
            registry.test_reset()
            let fixture = try makeFixture()
            addTeardownBlock {
                await fixture.service.test_setBeforeSessionWriteHook(nil)
                await MainActor.run { registry.test_reset() }
                try? FileManager.default.removeItem(at: fixture.storageURL)
            }
            var session = AgentSession(
                id: fixture.sessionID, workspaceID: fixture.workspace.id, composeTabID: fixture.tabID,
                name: "Before concurrent save", itemCount: 0
            )
            let fileURL = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
            let writerFence = TestReleaseFence(name: "admitted session writer")
            let commitFence = TestReleaseFence(name: "reversible deletion commit fence")
            defer {
                writerFence.release()
                commitFence.release()
            }
            await fixture.service.test_setBeforeSessionWriteHook { url in
                guard url.standardizedFileURL == fileURL.standardizedFileURL else { return }
                await writerFence.enterAndWait()
            }
            session.name = "Admitted save must survive refusal"
            let pendingSession = session
            let saveTask = Task { try await fixture.service.saveAgentSession(pendingSession, for: fixture.workspace) }
            addTeardownBlock {
                writerFence.release()
                commitFence.release()
                _ = await saveTask.result
            }
            guard await writerFence.waitUntilEntered() else { return }
            let deletionTask = Task {
                let fence: @Sendable () async -> Bool = {
                    await commitFence.enterAndWait()
                    return authorityHolds
                }
                try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                    try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
                }
            }
            addTeardownBlock {
                writerFence.release()
                commitFence.release()
                _ = await deletionTask.result
            }
            await fixture.service.test_waitUntilDeletionTombstone(for: fileURL)
            writerFence.release()
            guard await commitFence.waitUntilEntered() else { return }
            _ = try await saveTask.value

            XCTAssertTrue(registry.isDeletionInProgress(sessionID: fixture.sessionID))
            let duringAdmission = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(duringAdmission.name, pendingSession.name)
            let metadataDuringAdmission = try await fixture.service.listAgentSessionsMeta(for: fixture.workspace)
            XCTAssertEqual(metadataDuringAdmission.first { $0.id == fixture.sessionID }?.name, pendingSession.name)
            await assertSaveBlockedByDeletion(pendingSession, fixture: fixture)

            commitFence.release()
            do {
                try await deletionTask.value
                XCTAssertTrue(authorityHolds)
            } catch is AgentSessionDestructiveCommitRefused {
                XCTAssertFalse(authorityHolds)
            }
            XCTAssertEqual(FileManager.default.fileExists(atPath: fileURL.path), !authorityHolds)
            if authorityHolds {
                XCTAssertEqual(registry.state(forSessionID: fixture.sessionID), .committed)
                let metadata = try await fixture.service.listAgentSessionsMeta(for: fixture.workspace)
                XCTAssertFalse(metadata.contains { $0.id == fixture.sessionID })
                await assertSaveBlockedByDeletion(pendingSession, fixture: fixture)
            } else {
                XCTAssertNil(registry.state(forSessionID: fixture.sessionID))
                let retained = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
                XCTAssertEqual(retained.name, pendingSession.name)
                session.name = "Save after refused deletion"
                _ = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
                let metadata = try await fixture.service.listAgentSessionsMeta(for: fixture.workspace)
                XCTAssertEqual(metadata.first { $0.id == fixture.sessionID }?.name, session.name)
            }
        }
    }

    @MainActor
    func testOverlappingDeletionRefusalCannotReleasePendingOrCommittedSaveFence() async throws {
        for refusalFinishesFirst in [false, true] {
            let registry = AgentSessionDeletionRegistry.shared
            registry.test_reset()
            let fixture = try makeFixture()
            addTeardownBlock {
                await MainActor.run { registry.test_reset() }
                try? FileManager.default.removeItem(at: fixture.storageURL)
            }
            let session = AgentSession(id: fixture.sessionID, workspaceID: fixture.workspace.id, composeTabID: fixture.tabID)
            let fileURL = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
            let refusedFence = TestReleaseFence(name: "overlapping refused deletion")
            let allowedFence = TestReleaseFence(name: "overlapping allowed deletion")
            defer {
                refusedFence.release()
                allowedFence.release()
            }
            let refusedTask = Task {
                let fence: @Sendable () async -> Bool = {
                    await refusedFence.enterAndWait()
                    return false
                }
                try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                    try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
                }
            }
            addTeardownBlock {
                refusedFence.release()
                allowedFence.release()
                _ = await refusedTask.result
            }
            guard await refusedFence.waitUntilEntered() else { return }
            let allowedTask = Task {
                let fence: @Sendable () async -> Bool = {
                    await allowedFence.enterAndWait()
                    return true
                }
                try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                    try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
                }
            }
            addTeardownBlock {
                refusedFence.release()
                allowedFence.release()
                _ = await allowedTask.result
            }
            guard await allowedFence.waitUntilEntered() else { return }
            if !refusalFinishesFirst {
                allowedFence.release()
                try await allowedTask.value
                XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            }
            refusedFence.release()
            do {
                try await refusedTask.value
                XCTFail("The refused deletion must report refusal")
            } catch is AgentSessionDestructiveCommitRefused {}
            await assertSaveBlockedByDeletion(session, fixture: fixture)
            if refusalFinishesFirst {
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
                XCTAssertTrue(registry.isDeletionInProgress(sessionID: fixture.sessionID))
                allowedFence.release()
                try await allowedTask.value
            }
            XCTAssertEqual(registry.state(forSessionID: fixture.sessionID), .committed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            await assertSaveBlockedByDeletion(session, fixture: fixture)
            let metadata = try await fixture.service.listAgentSessionsMeta(for: fixture.workspace)
            XCTAssertFalse(metadata.contains { $0.id == fixture.sessionID })
        }
    }

    @MainActor
    func testCommittedDeletionRejectsSaveReturningFromItsWrite() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        registry.test_reset()
        let fixture = try makeFixture()
        addTeardownBlock {
            await fixture.service.test_setAfterSessionWriteHook(nil)
            await MainActor.run { registry.test_reset() }
            try? FileManager.default.removeItem(at: fixture.storageURL)
        }
        var session = AgentSession(id: fixture.sessionID, workspaceID: fixture.workspace.id, composeTabID: fixture.tabID)
        let fileURL = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
        let metadataURL = fixture.agentSessionsFolder.appendingPathComponent("AgentSessionIndex.json")
        let writeCompletionFence = TestReleaseFence(name: "completed session write before deletion check")
        defer { writeCompletionFence.release() }
        await fixture.service.test_setAfterSessionWriteHook { url in
            guard url.standardizedFileURL == fileURL.standardizedFileURL else { return }
            await writeCompletionFence.enterAndWait()
        }
        session.name = "Save paused after writing its transcript"
        let pendingSession = session
        let saveTask = Task { try await fixture.service.saveAgentSession(pendingSession, for: fixture.workspace) }
        addTeardownBlock {
            writeCompletionFence.release()
            _ = await saveTask.result
        }
        guard await writeCompletionFence.waitUntilEntered() else { return }
        let deletionTask = Task { try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace) }
        addTeardownBlock {
            writeCompletionFence.release()
            _ = await deletionTask.result
        }
        await fixture.service.test_waitUntilDeletionTombstone(for: fileURL)
        let deletionState = await registry.waitForDeletionAttemptToSettle(sessionID: fixture.sessionID)
        XCTAssertEqual(deletionState, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        writeCompletionFence.release()
        do {
            _ = try await saveTask.value
            XCTFail("A save returning after committed deletion must not acknowledge durability")
        } catch let AgentSessionDataError.sessionDeleted(sessionID) {
            XCTAssertEqual(sessionID, fixture.sessionID)
        }
        try await deletionTask.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let metadata = try await fixture.service.listAgentSessionsMeta(for: fixture.workspace)
        XCTAssertFalse(metadata.contains { $0.id == fixture.sessionID })
        let diskIndex = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(contentsOf: metadataURL))
        XCTAssertFalse(diskIndex.entries.contains { $0.id == fixture.sessionID })
        await assertSaveBlockedByDeletion(session, fixture: fixture)
    }

    func testBatchDeleteIgnoresNestedAndMalformedMetadataIndexFilenames() async throws {
        let cases: [(String, String, String)] = [
            ("nested", "nested/nested-sentinel.json", "nested/nested-sentinel.json"),
            ("malformed", "AgentSession-not-a-uuid.json", "AgentSession-not-a-uuid.json")
        ]

        for (label, indexFilename, targetRelativePath) in cases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
            let targetURL = fixture.agentSessionsFolder.appendingPathComponent(targetRelativePath)
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("sentinel-\(label)".utf8).write(to: targetURL, options: .atomic)
            try writeMetadataIndex(filename: indexFilename, fixture: fixture)

            let failures = await fixture.service.deleteAgentSessions(
                forComposeTabIDs: [fixture.tabID],
                for: fixture.workspace
            )

            XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), label)
        }
    }

    func testBatchDeleteRejectsMismatchedFilenameAndDecodedSessionID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let otherSessionID = UUID()
        let mismatchedFilename = agentSessionFilename(for: otherSessionID)
        let mismatchedURL = fixture.agentSessionsFolder.appendingPathComponent(mismatchedFilename)
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Mismatched session identity",
                itemCount: 0
            ),
            to: mismatchedURL
        )
        try writeMetadataIndex(filename: mismatchedFilename, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatchedURL.path))
    }

    func testBatchDeleteRejectsMismatchedComposeTabID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let otherTabID = UUID()
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: otherTabID,
                name: "Mismatched tab identity",
                itemCount: 0
            ),
            to: sessionURL
        )
        try writeMetadataIndex(filename: sessionURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testBatchDeleteRejectsSymlinkedSessionFileAndPreservesExternalSentinel() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sentinelURL = fixture.storageURL.appendingPathComponent("symlink-sentinel.json")
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Symlink sentinel",
                itemCount: 0
            ),
            to: sentinelURL
        )
        let symlinkURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sentinelURL)
        try writeMetadataIndex(filename: symlinkURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    func testBatchDeleteRemovesValidIndexedSessionFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Valid session",
                itemCount: 0
            ),
            to: sessionURL
        )
        try writeMetadataIndex(filename: sessionURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testDeletingSessionRemovesItsRetainedAttachmentFolderOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Session with images",
                itemCount: 0
            ),
            to: sessionURL
        )
        try writeMetadataIndex(filename: sessionURL.lastPathComponent, fixture: fixture)
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let ownImage = try writeRetainedImage(in: store, sessionID: fixture.sessionID)
        let otherImage = try writeRetainedImage(in: store, sessionID: UUID())

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownImage.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherImage.path))
    }

    func testDeletingSessionByIDRemovesItsRetainedAttachmentFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Session with images",
                itemCount: 0
            ),
            to: sessionURL
        )
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let ownImage = try writeRetainedImage(in: store, sessionID: fixture.sessionID)

        try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownImage.path))
    }

    func testDeletionDrainsPausedRetentionBeforeRemovingImages() async throws {
        try await checkPausedRetentionDeletion(authorityHolds: true)
    }

    func testFailedDeletionPreservesPausedRetentionAndItsRewrittenPaths() async throws {
        try await checkPausedRetentionDeletion(authorityHolds: false)
    }

    private func checkPausedRetentionDeletion(authorityHolds: Bool) async throws {
        let fixture = try makeFixture()
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(AgentSession(id: fixture.sessionID, workspaceID: fixture.workspace.id, name: "Paused images", itemCount: 0), to: sessionURL)
        let attachment = try writeTemporaryImage(fixture: fixture)
        let gate = TestReleaseFence(name: "attachment move before deletion")
        defer { gate.release() }
        await fixture.service.test_setBeforeAttachmentRetentionHook { _ in await gate.enterAndWait() }
        let move = Task {
            await fixture.service.retainConsumedAttachments(
                [attachment], sessionID: fixture.sessionID, store: store, workspaceDirectory: fixture.storageURL
            )
        }
        addTeardownBlock {
            gate.release()
            _ = await move.value
            await fixture.service.test_setBeforeAttachmentRetentionHook(nil)
            try? FileManager.default.removeItem(at: fixture.storageURL)
        }
        guard await gate.waitUntilEntered() else { return }
        let deletion = Task {
            let fence: @Sendable () async -> Bool = { authorityHolds }
            try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
            }
        }
        addTeardownBlock {
            gate.release()
            _ = await deletion.result
        }
        await fixture.service.test_waitUntilDeletionTombstone(for: sessionURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path), "Deletion must wait for the admitted move")
        gate.release()
        do {
            try await deletion.value
            XCTAssertTrue(authorityHolds)
        } catch is AgentSessionDestructiveCommitRefused {
            XCTAssertFalse(authorityHolds)
        }
        let result = await move.value
        XCTAssertEqual(result.retained.isEmpty, authorityHolds, "Only committed deletions suppress rewritten paths")
        XCTAssertEqual(FileManager.default.fileExists(atPath: sessionURL.path), !authorityHolds)
        XCTAssertEqual(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: fixture.sessionID).path), !authorityHolds)
        if case let .localFile(path) = attachment.source {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testLateRetentionCannotRecreateDeletedSessionFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let attachment = try writeTemporaryImage(fixture: fixture)
        // An absent transcript is still durably deleted and must fence a late worker admission.
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try await fixture.service.deleteAgentSessionFile(sessionURL)
        let result = await fixture.service.retainConsumedAttachments(
            [attachment], sessionID: fixture.sessionID, store: store, workspaceDirectory: fixture.storageURL
        )
        XCTAssertTrue(result.retained.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: fixture.sessionID).path))
        if case let .localFile(path) = attachment.source {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Rejected consumed images are cleaned up")
        }
    }

    func testDeletionDrainsHandoffCopyForBothSourceAndDestination() async throws {
        for deleteParent in [true, false] {
            let fixture = try makeFixture()
            let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
            let childID = UUID()
            let source = try writeTemporaryImage(fixture: fixture)
            let attachment = try XCTUnwrap(store.retain(
                [source], sessionID: fixture.sessionID,
                temporaryRoot: AgentAttachmentStore.managedStorageRootURL(for: fixture.storageURL)
            ).retained[source.id])
            guard case let .localFile(parentPath) = attachment.source else { return XCTFail("Missing parent image") }
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: parentPath))
            for id in [fixture.sessionID, childID] {
                try writeSession(
                    AgentSession(id: id, workspaceID: fixture.workspace.id, name: "Handoff copy", itemCount: 0),
                    to: fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: id))
                )
            }
            let gate = TestReleaseFence(name: "handoff copy before deletion")
            defer { gate.release() }
            await fixture.service.test_setBeforeHandoffAttachmentCopyHook { _ in await gate.enterAndWait() }
            let copy = Task {
                try await fixture.service.copyHandoffAttachments(
                    [attachment], sourceSessionID: fixture.sessionID, destinationSessionID: childID,
                    store: store, temporaryRoot: nil
                )
            }
            addTeardownBlock {
                gate.release()
                _ = await copy.result
                await fixture.service.test_setBeforeHandoffAttachmentCopyHook(nil)
                try? FileManager.default.removeItem(at: fixture.storageURL)
            }
            guard await gate.waitUntilEntered() else { return }
            let deletedID = deleteParent ? fixture.sessionID : childID
            let deletedURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: deletedID))
            let deletion = Task {
                try await fixture.service.deleteAgentSession(id: deletedID, for: fixture.workspace)
            }
            addTeardownBlock {
                gate.release()
                _ = await deletion.result
            }
            await fixture.service.test_waitUntilDeletionTombstone(for: deletedURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: deletedURL.path), "Deletion must join the admitted copy")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: parentPath)), originalBytes)
            gate.release()
            try await deletion.value
            do {
                let copied = try await copy.value
                XCTAssertTrue(deleteParent, "A committed child deletion must refuse copied paths")
                let child = try XCTUnwrap(copied[attachment.id])
                guard case let .localFile(childPath) = child.source else { return XCTFail("Missing child image") }
                XCTAssertTrue(store.isRetainedPath(childPath, sessionID: childID))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: childPath)), originalBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: parentPath))
            } catch let AgentSessionDataError.sessionDeleted(id) {
                XCTAssertFalse(deleteParent)
                XCTAssertEqual(id, childID)
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: childID).path))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: parentPath)), originalBytes)
            }
            // The tombstone also refuses a later operation, rather than letting it recreate files.
            do {
                _ = try await fixture.service.copyHandoffAttachments(
                    [attachment], sourceSessionID: fixture.sessionID, destinationSessionID: childID,
                    store: store, temporaryRoot: nil
                )
                XCTFail("A deleted source or destination must close copy admission")
            } catch let AgentSessionDataError.sessionDeleted(id) {
                XCTAssertEqual(id, deletedID)
            }
        }
    }

    func testCancelledHandoffCopyLeavesParentUntouchedAndNoChildFiles() async throws {
        let fixture = try makeFixture()
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let attachment = try writeTemporaryImage(fixture: fixture)
        let childID = UUID()
        let gate = TestReleaseFence(name: "handoff copy before cancellation")
        defer { gate.release() }
        await fixture.service.test_setBeforeHandoffAttachmentCopyHook { _ in await gate.enterAndWait() }
        let copy = Task {
            try await fixture.service.copyHandoffAttachments(
                [attachment], sourceSessionID: fixture.sessionID, destinationSessionID: childID,
                store: store, temporaryRoot: AgentAttachmentStore.managedStorageRootURL(for: fixture.storageURL)
            )
        }
        addTeardownBlock {
            gate.release()
            _ = await copy.result
            await fixture.service.test_setBeforeHandoffAttachmentCopyHook(nil)
            try? FileManager.default.removeItem(at: fixture.storageURL)
        }
        guard await gate.waitUntilEntered() else { return }
        copy.cancel()
        gate.release()
        do {
            _ = try await copy.value
            XCTFail("Cancellation must fail the copy")
        } catch is CancellationError {}
        guard case let .localFile(path) = attachment.source else { return XCTFail("Missing source path") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: childID).path))
    }

    func testFailedDeletionReopensRetentionAdmission() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let attachment = try writeTemporaryImage(fixture: fixture)
        let fence: @Sendable () async -> Bool = { false }
        do {
            try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
            }
            XCTFail("Deletion must fail when its authority ends")
        } catch is AgentSessionDestructiveCommitRefused {}
        let result = await fixture.service.retainConsumedAttachments(
            [attachment], sessionID: fixture.sessionID, store: store, workspaceDirectory: fixture.storageURL
        )
        XCTAssertNotNil(result.retained[attachment.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: fixture.sessionID).path))
    }

    func testLateRetentionWaitsForAllOverlappingFailedDeletions() async throws {
        try await checkLateRetentionAcrossOverlappingDeletions(secondDeletionCommits: false)
    }

    func testLateRetentionStaysFencedWhenAnOverlappingDeletionCommits() async throws {
        try await checkLateRetentionAcrossOverlappingDeletions(secondDeletionCommits: true)
    }

    private func checkLateRetentionAcrossOverlappingDeletions(secondDeletionCommits: Bool) async throws {
        let fixture = try makeFixture()
        let store = AgentSessionAttachmentStore(agentSessionsFolder: fixture.agentSessionsFolder)
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(AgentSession(id: fixture.sessionID, workspaceID: fixture.workspace.id, name: "Overlapping deletion", itemCount: 0), to: sessionURL)
        let attachment = try writeTemporaryImage(fixture: fixture)
        let firstGate = TestReleaseFence(name: "first deletion at commit")
        let secondGate = TestReleaseFence(name: "second deletion at commit")
        defer {
            firstGate.release()
            secondGate.release()
        }
        let firstDeletion = Task {
            let fence: @Sendable () async -> Bool = { await firstGate.enterAndWait()
                return false
            }
            try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                try await fixture.service.deleteAgentSessionFile(sessionURL)
            }
        }
        addTeardownBlock {
            firstGate.release()
            secondGate.release()
            _ = await firstDeletion.result
            try? FileManager.default.removeItem(at: fixture.storageURL)
        }
        guard await firstGate.waitUntilEntered() else { return }
        let secondDeletion = Task {
            let fence: @Sendable () async -> Bool = { await secondGate.enterAndWait()
                return secondDeletionCommits
            }
            try await AgentSessionDataService.destructiveCommitFence.withValue(fence) {
                try await fixture.service.deleteAgentSessionFile(sessionURL)
            }
        }
        addTeardownBlock {
            firstGate.release()
            secondGate.release()
            _ = await secondDeletion.result
        }
        guard await secondGate.waitUntilEntered() else { return }
        let retention = Task {
            await fixture.service.retainConsumedAttachments(
                [attachment], sessionID: fixture.sessionID, store: store, workspaceDirectory: fixture.storageURL
            )
        }
        addTeardownBlock {
            firstGate.release()
            secondGate.release()
            _ = await retention.value
        }
        try await AsyncTestWait.waitUntil("late retention waits for deletion outcomes") {
            await fixture.service.test_attachmentRetentionDeletionWaiterCount(for: sessionURL) == 1
        }
        firstGate.release()
        do {
            try await firstDeletion.value
            XCTFail("The first deletion must be refused")
        } catch is AgentSessionDestructiveCommitRefused {}
        let remainingWaiters = await fixture.service.test_attachmentRetentionDeletionWaiterCount(for: sessionURL)
        XCTAssertEqual(remainingWaiters, 1, "One failed attempt must not reopen admission while another owns deletion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: fixture.sessionID).path))
        if case let .localFile(path) = attachment.source {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Reversible deletion must not discard a late consumed image")
        }
        secondGate.release()
        do {
            try await secondDeletion.value
            XCTAssertTrue(secondDeletionCommits)
        } catch is AgentSessionDestructiveCommitRefused {
            XCTAssertFalse(secondDeletionCommits)
        }
        let result = await retention.value
        XCTAssertEqual(Set(result.retained.keys), secondDeletionCommits ? [] : [attachment.id])
        XCTAssertEqual(FileManager.default.fileExists(atPath: sessionURL.path), !secondDeletionCommits)
        XCTAssertEqual(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: fixture.sessionID).path), !secondDeletionCommits)
        if let retained = result.retained[attachment.id], case let .localFile(path) = retained.source {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Failed deletions must leave a usable rewritten path")
        }
        if case let .localFile(path) = attachment.source {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    private func writeTemporaryImage(fixture: BatchDeleteFixture) throws -> AgentFileAttachment {
        let root = AgentAttachmentStore.managedStorageRootURL(for: fixture.storageURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        return AgentFileAttachment(source: .localFile(path: image.path), title: "Consumed image")
    }

    private func writeRetainedImage(in store: AgentSessionAttachmentStore, sessionID: UUID) throws -> URL {
        let folder = store.sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageURL = folder.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        return imageURL
    }

    @MainActor
    func testTerminationRefusesDeletionWithoutDiscardingSaveBeforeAdmission() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        registry.test_reset()
        let fixture = try makeFixture()
        addTeardownBlock {
            await fixture.service.test_setBeforeSessionWriteHook(nil)
            await fixture.service.test_setBeforeDeletionAdmissionHook(nil)
            await MainActor.run { registry.test_reset() }
            try? FileManager.default.removeItem(at: fixture.storageURL)
        }
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        var session = AgentSession(
            id: fixture.sessionID,
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Session preserved during termination",
            itemCount: 0
        )
        try writeSession(session, to: sessionURL)
        let saveFence = TestReleaseFence(name: "save before deletion admission")
        let admissionFence = TestReleaseFence(name: "deletion before registry admission")
        defer {
            saveFence.release()
            admissionFence.release()
        }
        await fixture.service.test_setBeforeSessionWriteHook { url in
            guard url.standardizedFileURL == sessionURL.standardizedFileURL else { return }
            await saveFence.enterAndWait()
        }
        await fixture.service.test_setBeforeDeletionAdmissionHook { url in
            guard url.standardizedFileURL == sessionURL.standardizedFileURL else { return }
            await admissionFence.enterAndWait()
        }
        session.name = "Save admitted before deletion"
        let pendingSession = session
        let saveTask = Task {
            try await fixture.service.saveAgentSession(
                pendingSession,
                for: fixture.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
        }
        addTeardownBlock {
            saveFence.release()
            admissionFence.release()
            _ = await saveTask.result
        }
        guard await saveFence.waitUntilEntered() else { return }
        let deletionTask = Task {
            try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
        }
        addTeardownBlock {
            saveFence.release()
            admissionFence.release()
            _ = await deletionTask.result
        }
        guard await admissionFence.waitUntilEntered() else { return }

        XCTAssertTrue(registry.freezeNewDeletionAdmissionForTermination())
        saveFence.release()
        let savedBeforeAdmission = try await saveTask.value
        XCTAssertEqual(savedBeforeAdmission.standardizedFileURL, sessionURL.standardizedFileURL)
        let beforeAdmission = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: sessionURL))
        XCTAssertEqual(beforeAdmission.name, pendingSession.name)

        admissionFence.release()
        do {
            try await deletionTask.value
            XCTFail("Termination must refuse deletion before the session file is removed")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected deletion error: \(error)")
        }

        let afterRejection = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: sessionURL))
        XCTAssertEqual(afterRejection.name, pendingSession.name)
        XCTAssertNil(registry.state(forSessionID: fixture.sessionID))
        session.name = "Saved after deletion was refused"
        let savedURL = try await fixture.service.saveAgentSession(
            session,
            for: fixture.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        XCTAssertEqual(savedURL.standardizedFileURL, sessionURL.standardizedFileURL)
        let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: sessionURL))
        XCTAssertEqual(saved.name, session.name)
    }

    private struct BatchDeleteFixture {
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let storageURL: URL
        let agentSessionsFolder: URL
        let sessionID: UUID
        let tabID: UUID
    }

    @MainActor
    private func assertSaveBlockedByDeletion(
        _ session: AgentSession,
        fixture: BatchDeleteFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
            XCTFail("Deletion must keep new writes fenced", file: file, line: line)
        } catch let AgentSessionDataError.sessionDeleted(sessionID) {
            XCTAssertEqual(sessionID, session.id, file: file, line: line)
        } catch {
            XCTFail("Unexpected save error: \(error)", file: file, line: line)
        }
    }

    private func makeFixture() throws -> BatchDeleteFixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionDataServiceDeletionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentSessionsFolder = storageURL.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(
            name: "Agent Session Deletion",
            repoPaths: ["/tmp/repo"],
            customStoragePath: storageURL
        )
        return BatchDeleteFixture(
            service: AgentSessionDataService(),
            workspace: workspace,
            storageURL: storageURL,
            agentSessionsFolder: agentSessionsFolder,
            sessionID: UUID(),
            tabID: UUID()
        )
    }

    private func writeMetadataIndex(filename: String, fixture: BatchDeleteFixture) throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 1)
        let record = AgentSessionMetadataRecord(
            id: fixture.sessionID,
            filename: filename,
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Indexed session",
            savedAt: timestamp,
            lastUserMessageAt: nil,
            itemCount: 0,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: timestamp
        )
        let index = AgentSessionMetadataIndex(entries: [record])
        let indexURL = fixture.agentSessionsFolder.appendingPathComponent("AgentSessionIndex.json")
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func writeSession(_ session: AgentSession, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
    }

    private func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }
}

final class AgentSessionMetadataCommitTests: XCTestCase {
    func testOlderWriteCompletionCannotReplaceNewerMetadata() async throws {
        let fixture = try makeFixture()
        let fence = TestReleaseFence(name: "older save before metadata publication")
        var session = fixture.session
        let fileURL = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
        await fixture.service.test_setAfterSessionWriteHook { _ in await fence.enterAndWait() }
        session.name = "Older completed save"
        session.items = [
            AgentChatItemPersist(from: AgentChatItem(
                timestamp: Date(timeIntervalSinceReferenceDate: 100), kind: .user, text: "Older message"
            ))
        ]
        let olderSession = session
        let older = Task { try await fixture.service.saveAgentSession(olderSession, for: fixture.workspace) }
        addTeardownBlock {
            fence.release()
            _ = await older.result
            await fixture.service.test_setAfterSessionWriteHook(nil)
        }
        guard await fence.waitUntilEntered() else { return }
        await fixture.service.test_setAfterSessionWriteHook(nil)
        session.name = "Newer saved name"
        let latestUserMessageAt = Date(timeIntervalSinceReferenceDate: 300)
        session.items += [
            AgentChatItemPersist(from: AgentChatItem(
                timestamp: Date(timeIntervalSinceReferenceDate: 200), kind: .assistant, text: "Newer reply", sequenceIndex: 1
            )),
            AgentChatItemPersist(from: AgentChatItem(
                timestamp: latestUserMessageAt, kind: .user, text: "Newest message", sequenceIndex: 2
            ))
        ]
        _ = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
        fence.release()
        _ = try await older.value

        try await assertStoredAndIndexed(
            session, fileURL: fileURL, fixture: fixture,
            expectedItemCount: 3, expectedLastUserMessageAt: latestUserMessageAt
        )
    }

    func testMetadataOnlyLoadCannotPublishOverANewerSave() async throws {
        let fixture = try makeFixture()
        let fence = TestReleaseFence(name: "loaded metadata before publication")
        var session = fixture.session
        let fileURL = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
        await fixture.service.test_setBeforeLoadRepairWriteHook { _ in await fence.enterAndWait() }
        let loading = Task { try await fixture.service.loadAgentSession(from: fileURL) }
        addTeardownBlock {
            fence.release()
            _ = await loading.result
            await fixture.service.test_setBeforeLoadRepairWriteHook(nil)
        }
        guard await fence.waitUntilEntered() else { return }
        session.name = "Saved while old metadata was loading"
        _ = try await fixture.service.saveAgentSession(session, for: fixture.workspace)
        fence.release()
        _ = try await loading.value

        try await assertStoredAndIndexed(session, fileURL: fileURL, fixture: fixture)
    }

    func testCoalescedWritesPublishOnlyTheWinningPayloadAndKeepOtherFilesIndependent() async throws {
        let fixture = try makeFixture()
        let fence = TestReleaseFence(name: "first coalesced write")
        let fileURL = try await fixture.service.saveAgentSession(fixture.session, for: fixture.workspace)
        await fixture.service.test_setBeforeSessionWriteHook { url in
            guard url.standardizedFileURL == fileURL.standardizedFileURL else { return }
            await fence.enterAndWait()
        }
        var firstSession = fixture.session
        firstSession.name = "Superseded write"
        let firstPayload = firstSession
        let first = Task { try await fixture.service.saveAgentSession(firstPayload, for: fixture.workspace) }
        addTeardownBlock {
            fence.release()
            _ = await first.result
            await fixture.service.test_setBeforeSessionWriteHook(nil)
        }
        guard await fence.waitUntilEntered() else { return }
        var winner = fixture.session
        winner.name = "Winning coalesced write"
        let winningPayload = winner
        let second = Task { try await fixture.service.saveAgentSession(winningPayload, for: fixture.workspace) }
        addTeardownBlock {
            fence.release()
            _ = await second.result
        }
        try await AsyncTestWait.waitUntil("both coalesced writes admitted") {
            await fixture.service.test_pendingSessionWriteCount(for: fileURL) == 2
        }
        let independent = AgentSession(id: UUID(), workspaceID: fixture.workspace.id, name: "Independent session")
        let independentURL = try await fixture.service.saveAgentSession(independent, for: fixture.workspace)
        try await assertStoredAndIndexed(independent, fileURL: independentURL, fixture: fixture)
        fence.release()
        _ = try await first.value
        _ = try await second.value

        try await assertStoredAndIndexed(winner, fileURL: fileURL, fixture: fixture)
        let publicationCount = await fixture.service.test_pendingMetadataPublicationCount()
        XCTAssertEqual(publicationCount, 0)
    }

    func testCoalescedWriterReturnsReceiptOnlyToTheCommittedOwner() async throws {
        let fixture = try makeFixture()
        let writer = AgentSessionDiskWriter()
        let fence = TestReleaseFence(name: "first coalesced write")
        let fileURL = fixture.storageURL.appendingPathComponent("coalesced.json")
        await writer.test_setBeforeWriteHook { url in
            guard url == fileURL.standardizedFileURL else { return }
            await fence.enterAndWait()
        }
        let first = Task { try await writer.enqueueAndWait(data: Data("first".utf8), url: fileURL) }
        addTeardownBlock {
            fence.release()
            _ = await first.result
        }
        guard await fence.waitUntilEntered() else { return }
        let winningData = Data("winning coalesced payload".utf8)
        let second = Task { try await writer.enqueueAndWait(data: winningData, url: fileURL) }
        addTeardownBlock {
            fence.release()
            _ = await second.result
        }
        try await AsyncTestWait.waitUntil("both coalesced writes admitted") {
            await writer.test_pendingWriteCount(for: fileURL) == 2
        }
        let independentURL = fixture.storageURL.appendingPathComponent("independent.json")
        let independentReceipt = try await writer.enqueueAndWait(data: Data("independent".utf8), url: independentURL)
        XCTAssertNotNil(independentReceipt)
        XCTAssertEqual(try Data(contentsOf: independentURL), Data("independent".utf8))
        fence.release()
        let firstReceipt = try await first.value
        let winningReceipt = try await second.value
        XCTAssertNil(firstReceipt, "A superseded caller has no metadata publication authority")
        let receipt = try XCTUnwrap(winningReceipt)
        XCTAssertEqual(try Data(contentsOf: fileURL), winningData)
        XCTAssertEqual(receipt.observedFileSize, Int64(winningData.count))
        let signature = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(receipt.observedFileModificationDate, signature.contentModificationDate)
    }

    func testCommittedWriteKeepsItsReceiptWhenSuccessorFailsInTheSameDrain() async throws {
        let fixture = try makeFixture()
        let firstFence = TestReleaseFence(name: "A before disk")
        let secondFence = TestReleaseFence(name: "B after A committed, before disk")
        let publicationFence = TestReleaseFence(name: "receipt before metadata publication")
        let fileURL = try await fixture.service.saveAgentSession(fixture.session, for: fixture.workspace)
        await fixture.service.test_setBeforeSessionWriteHook { _ in await firstFence.enterAndWait() }
        var session = fixture.session
        session.name = "Last successful write"
        let messageDate = Date(timeIntervalSinceReferenceDate: 300)
        session.items = [AgentChatItemPersist(from: AgentChatItem(
            timestamp: messageDate, kind: .user, text: "Committed message"
        ))]
        let successfulPayload = session
        let successful = Task { try await fixture.service.saveAgentSession(successfulPayload, for: fixture.workspace) }
        addTeardownBlock {
            firstFence.release()
            secondFence.release()
            publicationFence.release()
            _ = await successful.result
            await fixture.service.test_setBeforeSessionWriteHook(nil)
            await fixture.service.test_setAfterSessionWriteHook(nil)
        }
        guard await firstFence.waitUntilEntered() else { return }
        await fixture.service.test_setBeforeSessionWriteHook { _ in await secondFence.enterAndWait() }
        var failedSession = session
        failedSession.name = "Must not be indexed"
        failedSession.items = []
        let failedPayload = failedSession
        let failed = Task { try await fixture.service.saveAgentSession(failedPayload, for: fixture.workspace) }
        addTeardownBlock {
            firstFence.release()
            secondFence.release()
            publicationFence.release()
            _ = await failed.result
        }
        try await AsyncTestWait.waitUntil("A and B admitted to the same drain") {
            await fixture.service.test_pendingSessionWriteCount(for: fileURL) == 2
        }
        firstFence.release()
        guard await secondFence.waitUntilEntered() else { return }
        let committedData = try Data(contentsOf: fileURL)
        let committed = try JSONDecoder().decode(AgentSession.self, from: committedData)
        XCTAssertEqual(committed.name, successfulPayload.name, "A physically committed before B starts")
        let backupURL = fixture.storageURL.appendingPathComponent("successful-session-backup.json")
        try FileManager.default.moveItem(at: fileURL, to: backupURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        try Data("block atomic replacement".utf8).write(to: fileURL.appendingPathComponent("sentinel"))
        let obstructedWaiterCount = await fixture.service.test_pendingSessionWriteCount(for: fileURL)
        XCTAssertEqual(obstructedWaiterCount, 2, "The obstruction must not hide the admitted drain")
        // Hold successful callbacks until the original committed inode is restored. B must fail
        // a real atomic replacement; neither caller has left this disk-writer drain yet.
        await fixture.service.test_setAfterSessionWriteHook { _ in await publicationFence.enterAndWait() }
        secondFence.release()
        try await AsyncTestWait.waitUntil("same drain finished before restoring A") {
            await fixture.service.test_pendingSessionWriteCount(for: fileURL) == 0
        }
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: backupURL, to: fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), committedData)
        publicationFence.release()
        switch await failed.result {
        case .success:
            XCTFail("Replacing a directory with session data must fail")
        case let .failure(error):
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteUnknown.rawValue)
        }
        switch await successful.result {
        case let .success(savedURL):
            XCTAssertEqual(savedURL, fileURL)
        case let .failure(error):
            XCTFail("A committed successfully and must not receive B's error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), committedData, "No caller may replace restored A during publication")
        try await assertStoredAndIndexed(
            session, fileURL: fileURL, fixture: fixture,
            expectedItemCount: 1, expectedLastUserMessageAt: messageDate
        )
        let publicationCount = await fixture.service.test_pendingMetadataPublicationCount()
        XCTAssertEqual(publicationCount, 0)
    }

    private struct Fixture {
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let session: AgentSession
        let storageURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionMetadataCommitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storageURL) }
        let workspace = WorkspaceModel(name: "Metadata receipts", repoPaths: [], customStoragePath: storageURL)
        return Fixture(
            service: AgentSessionDataService(), workspace: workspace,
            session: AgentSession(id: UUID(), workspaceID: workspace.id, name: "Initial session"),
            storageURL: storageURL
        )
    }

    private func assertStoredAndIndexed(
        _ expected: AgentSession, fileURL: URL, fixture: Fixture,
        expectedItemCount: Int? = nil, expectedLastUserMessageAt: Date? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(stored.name, expected.name, file: file, line: line)
        let fast = try await fixture.service.fastMetadataRecordsIfAvailable(for: fixture.workspace)
        let record = try XCTUnwrap(fast?.records.first { $0.id == expected.id }, file: file, line: line)
        XCTAssertEqual(record.name, expected.name, file: file, line: line)
        let expectedRecord = AgentSessionMetadataRecord.record(
            from: stored, fileURL: fileURL, observedFileSize: nil, observedFileModificationDate: nil
        )
        XCTAssertEqual(record.savedAt, stored.savedAt, file: file, line: line)
        XCTAssertEqual(record.transcriptProjectionCounts, expectedRecord.transcriptProjectionCounts, file: file, line: line)
        XCTAssertEqual(record.transcriptTurnCount, expectedRecord.transcriptTurnCount, file: file, line: line)
        XCTAssertEqual(record.firstActivityAt, expectedRecord.firstActivityAt, file: file, line: line)
        XCTAssertEqual(record.lastActivityAt, expectedRecord.lastActivityAt, file: file, line: line)
        if let expectedItemCount {
            XCTAssertEqual(stored.itemCount, expectedItemCount, file: file, line: line)
            XCTAssertEqual(record.itemCount, expectedItemCount, file: file, line: line)
            XCTAssertEqual(record.lastUserMessageAt, expectedLastUserMessageAt, file: file, line: line)
        }
        XCTAssertEqual(record.observedFileSize, Int64(data.count), file: file, line: line)
        let signature = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(record.observedFileModificationDate, signature.contentModificationDate, file: file, line: line)
        let indexURL = fileURL.deletingLastPathComponent().appendingPathComponent("AgentSessionIndex.json")
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(contentsOf: indexURL))
        let diskRecord = index.entries.first { $0.id == expected.id }
        XCTAssertEqual(diskRecord?.name, expected.name, file: file, line: line)
        XCTAssertEqual(diskRecord?.savedAt, stored.savedAt, file: file, line: line)
        XCTAssertEqual(diskRecord?.transcriptProjectionCounts, expectedRecord.transcriptProjectionCounts, file: file, line: line)
        XCTAssertEqual(diskRecord?.transcriptTurnCount, expectedRecord.transcriptTurnCount, file: file, line: line)
        XCTAssertEqual(diskRecord?.firstActivityAt, expectedRecord.firstActivityAt, file: file, line: line)
        XCTAssertEqual(diskRecord?.lastActivityAt, expectedRecord.lastActivityAt, file: file, line: line)
        XCTAssertEqual(diskRecord?.observedFileSize, Int64(data.count), file: file, line: line)
        XCTAssertEqual(diskRecord?.observedFileModificationDate, signature.contentModificationDate, file: file, line: line)
        if let expectedItemCount {
            XCTAssertEqual(diskRecord?.itemCount, expectedItemCount, file: file, line: line)
            XCTAssertEqual(diskRecord?.lastUserMessageAt, expectedLastUserMessageAt, file: file, line: line)
        }
    }
}

// MARK: - AgentSessionTitlePolicyTests

final class AgentSessionTitlePolicyTests: XCTestCase {
    func testStaleTurnClosureCannotCloseAnotherRefinement() throws {
        let turn = UUID()
        let metadata = try XCTUnwrap(AgentSessionTitlePolicy.apply(.seed("Stable title policy", turnID: turn), to: nil, name: "T1"))
        XCTAssertNil(try AgentSessionTitlePolicy.apply(.closeRefinement(turnID: UUID()), to: metadata, name: "T1"))
        let closed = try AgentSessionTitlePolicy.apply(.closeRefinement(turnID: turn), to: metadata, name: "T1")
        XCTAssertEqual(closed?.state?.refinement.phase, "closed")
    }

    private func seeded(_ task: String = "# Session title ownership", turn: UUID) throws -> AgentSessionTitleMetadata {
        try XCTUnwrap(AgentSessionTitlePolicy.apply(.seed(task, turnID: turn), to: nil, name: "T17"))
    }

    func testWrapperHeavySeedsAndActivityLeads() {
        XCTAssertEqual(AgentSessionTitlePolicy.seed(from: "# Deep Plan Mode\n\n# Session title ownership\nYou are an agent"), "Session title ownership")
        XCTAssertEqual(AgentSessionTitlePolicy.seed(from: "<file_map>\nwrong topic\n</file_map><task>Debug launch artifact reuse</task>"), "Debug launch artifact reuse")
        XCTAssertNil(AgentSessionTitlePolicy.seed(from: "You are the single bounded DESIGN CRITIC\n<context>wrong topic</context>"))
        XCTAssertEqual(AgentSessionTitlePolicy.seed(from: "Prepare debug launch reuse PR"), "Debug launch reuse PR")
    }

    func testWrapperOnlyPayloadDoesNotConsumeFirstMeaningfulTask() throws {
        XCTAssertNil(try AgentSessionTitlePolicy.apply(.seed("You are the bounded critic\n<context>Injected context</context>", turnID: UUID()), to: nil, name: "T17"))
    }

    func testUndoRestoresUnknownAssociationFieldsFromBeforeEnvelope() throws {
        let human = try XCTUnwrap(AgentSessionTitlePolicy.apply(.humanRename("Subject"), to: nil, name: "T1"))
        let report = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/app/pull/42", relationship: "created")
        let associated = try XCTUnwrap(AgentSessionTitlePolicy.apply(.associate([report], human: false), to: human, name: "Subject"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(associated)) as? [String: Any])
        var prs = try XCTUnwrap(object["pullRequests"] as? [[String: Any]])
        prs[0]["futureEvidence"] = "preserve"
        object["pullRequests"] = prs
        let before = try JSONDecoder().decode(AgentSessionTitleMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        let after = try XCTUnwrap(AgentSessionTitlePolicy.apply(.correct(add: [], remove: [report.identity], human: false), to: before, name: "Subject"))
        let undo = try XCTUnwrap(AgentSessionTitlePolicy.apply(.restore(before), to: after, name: "Subject"))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(undo)) as? [String: Any])
        XCTAssertEqual((restored["pullRequests"] as? [[String: Any]])?.first?["futureEvidence"] as? String, "preserve")
        XCTAssertEqual(undo.revision, (after.revision ?? 0) + 1)
    }

    func testOneProposalAndOneQualityCorrection() throws {
        let turn = UUID()
        let start = try seeded(turn: turn)
        let rejected = try XCTUnwrap(AgentSessionTitlePolicy.apply(.agentProposal("Prepare debug launch reuse PR", turnID: turn), to: start, name: "unused"))
        XCTAssertEqual(rejected.state?.baseTitle, start.state?.baseTitle)
        XCTAssertEqual(rejected.state?.refinement.qualityRejections, 1)
        let final = try XCTUnwrap(AgentSessionTitlePolicy.apply(.agentProposal("Debug launch artifact reuse", turnID: turn), to: rejected, name: "unused"))
        XCTAssertEqual(final.state?.baseTitle, "Debug launch artifact reuse")
        XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.agentProposal("Another topic", turnID: turn), to: final, name: "unused"))
    }

    func testHumanOwnershipBeatsDelegatedAdminEvenForTNumberAndSameText() throws {
        let turn = UUID()
        let start = try seeded("T17", turn: turn)
        let human = try XCTUnwrap(AgentSessionTitlePolicy.apply(.humanRename(" T17 "), to: start, name: "T17"))
        XCTAssertEqual(human.state?.source, "human")
        XCTAssertEqual(human.state?.baseTitle, "T17")
        XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.adminRename("Replacement"), to: human, name: "T17"))
        XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.agentProposal("Replacement", turnID: turn), to: human, name: "T17"))
        XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.adminRename("Replacement"), to: nil, name: "Legacy manual title"))
    }

    func testDelegatedStartupTitleIsFinalAndContinuationDoesNotReopen() throws {
        let title = try XCTUnwrap(AgentSessionTitlePolicy.apply(.startupProposal("Session naming evidence"), to: nil, name: "Agent Session"))
        XCTAssertEqual(title.state?.source, "agentProposal")
        XCTAssertEqual(title.state?.refinement.phase, "closed")
        XCTAssertNil(try AgentSessionTitlePolicy.apply(.seed("A new turn", turnID: UUID()), to: title, name: "unused"))
    }

    func testPRCompositionPreservesManualBaseAndCanonicalOrder() throws {
        let human = try XCTUnwrap(AgentSessionTitlePolicy.apply(.humanRename("My  exact subject"), to: nil, name: "T1"))
        let first = try AgentSessionPullRequestEvidence.report(url: "https://github.com/Acme/App/pull/123?x=y", relationship: "created")
        let second = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/app/pull/12", relationship: "related")
        let result = try XCTUnwrap(AgentSessionTitlePolicy.apply(.associate([first, second], human: false), to: human, name: "unused"))
        XCTAssertEqual(result.state?.displayName, "PR #12, #123 — My exact subject")
        XCTAssertEqual(result.state?.source, "human")
        XCTAssertNil(try AgentSessionTitlePolicy.apply(.associate([first], human: false), to: result, name: "unused"))
        let third = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/tools/pull/12", relationship: "created")
        let multi = try XCTUnwrap(AgentSessionTitlePolicy.apply(.associate([third], human: false), to: result, name: "unused"))
        XCTAssertEqual(multi.state?.displayName, "PR acme/app#12, acme/app#123, acme/tools#12 — My exact subject")
    }

    func testHumanSuppressionBlocksReportsAndRemovalCannotHitCapacity() throws {
        var metadata = try seeded(turn: UUID())
        for number in 1 ... 65 {
            let report = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/app/pull/\(number)", relationship: "created")
            metadata = try XCTUnwrap(AgentSessionTitlePolicy.apply(.associate([report], human: true), to: metadata, name: "unused"))
            XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.correct(add: [], remove: [report.identity], human: false), to: metadata, name: "unused"))
            metadata = try XCTUnwrap(AgentSessionTitlePolicy.apply(.correct(add: [], remove: [report.identity], human: true), to: metadata, name: "unused"))
            XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.associate([report], human: false), to: metadata, name: "unused"))
        }
        XCTAssertEqual(metadata.state?.suppressedPullRequests.count, 65)
        XCTAssertEqual(metadata.state?.pullRequests.count, 0)
    }

    func testOpaqueFutureAndUnknownFieldsRoundTripWithoutIntegerLoss() throws {
        let data = Data("{\"metadataVersion\":2,\"revision\":18446744073709551615,\"future\":{\"id\":18446744073709551614}}".utf8)
        let opaque = try JSONDecoder().decode(AgentSessionTitleMetadata.self, from: data)
        XCTAssertNil(opaque.state)
        XCTAssertEqual(opaque.revision, UInt64.max)
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionTitleMetadata.self, from: JSONEncoder().encode(opaque)), opaque)
        XCTAssertThrowsError(try AgentSessionTitlePolicy.apply(.humanRename("Do not discard future state"), to: opaque, name: "Stored title"))
        let known = try seeded(turn: UUID())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        object["future"] = ["nested": "keep me"]
        let extended = try JSONDecoder().decode(AgentSessionTitleMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        let edited = try XCTUnwrap(AgentSessionTitlePolicy.apply(.humanRename("Human"), to: extended, name: "unused"))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        XCTAssertEqual((encoded["future"] as? [String: String])?["nested"], "keep me")
    }

    func testStrictPRURLIdentity() throws {
        for invalid in ["https://github.com/a/b/issues/1", "http://github.com/a/b/pull/1", "https://github.com/a/b/pull/0", "https://github.com/a/b/pull/1e2", "https://github.com/a/b/pull/18446744073709551616", "https://user@github.com/a/b/pull/1", "https://untrusted.example/a/b/pull/1"] {
            XCTAssertThrowsError(try AgentSessionPullRequestIdentity(url: invalid), invalid)
        }
        let identity = try AgentSessionPullRequestIdentity(url: "https://github.com/A/B/pull/9007199254740993")
        XCTAssertEqual(identity.number, 9_007_199_254_740_993)
        XCTAssertEqual(identity.url, "https://github.com/a/b/pull/9007199254740993")
    }
}

// MARK: - AgentSessionTitlePersistenceTests

final class AgentSessionTitlePersistenceTests: XCTestCase {
    private func fixture() throws -> (AgentSessionDataService, WorkspaceModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("title-persistence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (AgentSessionDataService(), WorkspaceModel(name: "Title tests", repoPaths: [], customStoragePath: directory), directory)
    }

    func testSuspendedLoadRepairCannotOverwriteNewerPRTitle() async throws {
        let (service, workspace, directory) = try fixture()
        let folder = directory.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var original = AgentSession(workspaceID: workspace.id, name: "T1")
        original.serializationVersion = AgentSession.currentSerializationVersion - 1
        let file = folder.appendingPathComponent("AgentSession-\(original.id.uuidString).json")
        try JSONEncoder().encode(original).write(to: file)
        let fence = TestReleaseFence(name: "title load repair admission")
        await service.test_setBeforeLoadRepairWriteHook { _ in await fence.enterAndWait() }
        let loading = Task { try await service.loadAgentSession(from: file) }
        addTeardownBlock {
            fence.release()
            _ = await loading.result
            await service.test_setBeforeLoadRepairWriteHook(nil)
        }
        guard await fence.waitUntilEntered() else { return }
        _ = try await service.commitTitleMutation(
            id: original.id,
            workspace: workspace,
            expectedRevision: 0,
            fallbackName: "T1",
            command: .humanRename("New subject")
        )
        let report = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/app/pull/42", relationship: "created")
        _ = try await service.commitTitleMutation(
            id: original.id,
            workspace: workspace,
            expectedRevision: 1,
            fallbackName: "T1",
            command: .associate([report], human: false)
        )
        _ = try await service.saveAgentSession(original, for: workspace)
        fence.release()
        let loaded = try await loading.value
        XCTAssertEqual(loaded.name, "PR #42 — New subject")
        let stored = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
        XCTAssertEqual(stored.titleMetadata?.revision, 2)
        XCTAssertEqual(stored.name, loaded.name)
    }

    func testCASAndStaleTranscriptSaveKeepNewestTitleAndPR() async throws {
        let (service, workspace, _) = try fixture()
        let session = AgentSession(workspaceID: workspace.id, composeTabID: UUID(), name: "T1")
        let file = try await service.saveAgentSession(session, for: workspace)
        let before = try await service.prepareTitleState(id: session.id, workspace: workspace, fallbackName: "wrong")
        XCTAssertEqual(before.revision, 0)
        let named = try await service.commitTitleMutation(
            id: session.id,
            workspace: workspace,
            expectedRevision: 0,
            fallbackName: "wrong",
            command: .humanRename("Permanent subject")
        )
        XCTAssertEqual(named.revision, 1)
        do {
            _ = try await service.commitTitleMutation(
                id: session.id,
                workspace: workspace,
                expectedRevision: 0,
                fallbackName: "wrong",
                command: .humanRename("Stale window")
            )
            XCTFail("Expected a CAS conflict")
        } catch { XCTAssertEqual(error as? AgentSessionTitleError, .conflict) }
        let report = try AgentSessionPullRequestEvidence.report(url: "https://github.com/acme/app/pull/123", relationship: "created")
        let associated = try await service.commitTitleMutation(
            id: session.id,
            workspace: workspace,
            expectedRevision: 1,
            fallbackName: "wrong",
            command: .associate([report], human: false)
        )
        XCTAssertEqual(associated.persistenceState, "pending")
        _ = try await service.saveAgentSession(session, for: workspace)
        let stored = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
        XCTAssertEqual(stored.name, "PR #123 — Permanent subject")
        XCTAssertEqual(stored.titleMetadata?.revision, 2)
        XCTAssertEqual(stored.titleMetadata?.state?.source, "human")
        let fresh = AgentSessionDataService()
        let header = try await fresh.loadAgentSessionStub(from: file, recoverMissingMetadata: false, persistRecoveredMetadata: false)
        XCTAssertEqual(header.titleMetadata, stored.titleMetadata)
        let metadata = try await fresh.listAgentSessionsMeta(for: workspace)
        XCTAssertEqual(metadata.first?.titleMetadata, stored.titleMetadata)
        let receipt = try await service.prepareTitleState(id: session.id, workspace: workspace, fallbackName: "wrong")
        XCTAssertEqual(receipt.persistenceState, "persisted")
    }

    func testFutureOpaqueMetadataSurvivesNilSnapshotSave() async throws {
        let (service, workspace, _) = try fixture()
        let opaque = try JSONDecoder().decode(
            AgentSessionTitleMetadata.self,
            from: Data("{\"metadataVersion\":2,\"revision\":18446744073709551615,\"extra\":{\"number\":18446744073709551614}}".utf8)
        )
        var original = AgentSession(workspaceID: workspace.id, name: "Future visible name", titleMetadata: opaque)
        let file = try await service.saveAgentSession(original, for: workspace)
        original.titleMetadata = nil
        original.name = "Stale name"
        _ = try await service.saveAgentSession(original, for: workspace)
        let stored = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
        XCTAssertEqual(stored.titleMetadata, opaque)
        XCTAssertEqual(stored.name, "Future visible name")
    }

    func testLegacyHeaderReadDoesNotRewriteOrCreateDerivedTitleMetadata() async throws {
        let (service, workspace, _) = try fixture()
        let original = AgentSession(workspaceID: workspace.id, name: "Legacy manual title")
        let file = try await service.saveAgentSession(original, for: workspace)
        let bytes = try Data(contentsOf: file)
        let stub = try await service.loadAgentSessionStub(from: file, recoverMissingMetadata: false, persistRecoveredMetadata: false)
        XCTAssertNil(stub.titleMetadata)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let record = AgentSessionMetadataRecord.record(from: original, fileURL: file, observedFileSize: nil, observedFileModificationDate: nil)
        XCTAssertTrue(record.matchesIndexedSessionMetadata(record))
        XCTAssertTrue(record.lacksTranscriptDerivedFields)
        XCTAssertNil(record.titleMetadata)
    }

    func testReorderedEnqueueCannotSupersedePreparedSuccessor() async throws {
        let (_, _, directory) = try fixture()
        let file = directory.appendingPathComponent("writer.json")
        let writer = AgentSessionDiskWriter()
        let newer = try await writer.enqueueAndWait(data: Data("newer".utf8), url: file, preparationSequence: 2)
        let older = try await writer.enqueueAndWait(data: Data("older".utf8), url: file, preparationSequence: 1)
        XCTAssertNotNil(newer)
        XCTAssertNil(older)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
    }

    func testMalformedCurrentResetPreservesRecoveryAndCannotBeUndoneByOldOpaqueSave() async throws {
        let (service, workspace, directory) = try fixture()
        let malformed = try JSONDecoder().decode(
            AgentSessionTitleMetadata.self,
            from: Data("{\"metadataVersion\":1,\"revision\":9,\"baseTitle\":42}".utf8)
        )
        let original = AgentSession(workspaceID: workspace.id, name: "PR #123 — Keep visible text", titleMetadata: malformed)
        let file = try await service.saveAgentSession(original, for: workspace)
        let bytes = try Data(contentsOf: file)
        let reset = try await service.resetMalformedTitle(id: original.id, workspace: workspace, expectedRevision: 9)
        XCTAssertEqual(reset.metadata?.state?.baseTitle, original.name)
        XCTAssertEqual(reset.metadata?.state?.source, "human")
        XCTAssertEqual(reset.revision, 10)
        _ = try await service.saveAgentSession(original, for: workspace)
        let stored = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
        XCTAssertEqual(stored.titleMetadata, reset.metadata)
        let recovery = directory.appendingPathComponent("AgentSessions/.title-metadata-recovery")
        let copies = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), bytes)
    }
}

// MARK: - AgentSessionTitleLifecycleTests

@MainActor
final class AgentSessionTitleLifecycleTests: XCTestCase {
    func testActivityIsEphemeralAndReasoningDoesNotReplaceIt() {
        let session = AgentTabSession(tabID: UUID())
        session.runState = .running
        session.titleTaskTurnID = UUID()
        session.activeTaskTurnID = session.titleTaskTurnID
        session.activeTask = "Checking title persistence"
        session.runningStatusSource = .reasoning
        session.runningStatusText = "Considering alternatives"
        XCTAssertEqual(session.displayedRunningStatusText, "Checking title persistence")
        session.runningStatusSource = .reconnect
        session.runningStatusText = "Reconnecting"
        XCTAssertEqual(session.displayedRunningStatusText, "Reconnecting")
        session.runState = .waitingForApproval
        XCTAssertEqual(session.displayedRunningStatusText, "Waiting for approval")
        session.runState = .idle
        XCTAssertNil(session.activeTask)
        XCTAssertNil(session.activeTaskTurnID)
    }

    func testSameSessionNewBindingGenerationClearsRuntimeTitleState() throws {
        let session = AgentTabSession(tabID: UUID())
        let id = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id))
        session.titleMetadata = try AgentSessionTitlePolicy.apply(.humanRename("Subject"), to: nil, name: "T1")
        session.titleTaskTurnID = UUID()
        session.activeTaskTurnID = session.titleTaskTurnID
        session.activeTask = "Old task"
        session.unreportedPullRequestNotice = "Old notice"
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id))
        XCTAssertNil(session.titleMetadata)
        XCTAssertNil(session.activeTask)
        XCTAssertNil(session.titleTaskTurnID)
        XCTAssertNil(session.unreportedPullRequestNotice)
    }

    func testSessionlessHumanTitlePromotesOnlyToFirstDurableIdentity() throws {
        var tab = ComposeTabState(name: "T17")
        let metadata = try XCTUnwrap(AgentSessionTitlePolicy.apply(.humanRename("T17"), to: nil, name: tab.name))
        tab.agentTitleProjection = .init(sessionID: nil, titleMetadata: metadata)
        let first = UUID()
        tab.activeAgentSessionID = first
        XCTAssertEqual(tab.agentTitleProjection?.sessionID, first)
        XCTAssertEqual(tab.agentTitleProjection?.titleMetadata.state?.source, "human")
        tab.activeAgentSessionID = UUID()
        XCTAssertNil(tab.agentTitleProjection)
    }
}

// MARK: - AgentSessionPullRequestEvidenceTests

final class AgentSessionPullRequestEvidenceTests: XCTestCase {
    private func event(_ command: String = "gh pr create --repo owner/repo", output: String = "https://github.com/owner/repo/pull/42\n", exit: Int? = 0, truncated: Bool = false) -> AgentNativeCommandCompletion {
        .init(invocationID: UUID(), command: command, argv: nil, exitCode: exit, output: output, isError: false, isTruncated: truncated)
    }

    func testOrdinaryNativeCommandsDoNotReadRepositoryHostConfiguration() {
        var lookups = 0
        func hosts() -> Set<String> {
            lookups += 1
            return ["github.com"]
        }
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event("git status"), trustedHosts: hosts()), .ignored)
        XCTAssertEqual(lookups, 0)
        _ = AgentSessionNativePullRequestObserver.observe(event(), trustedHosts: hosts())
        XCTAssertEqual(lookups, 1)
    }

    func testLiteralNativeCreationAndRepositoryArguments() {
        for command in ["gh pr create --repo owner/repo", "gh pr create -Rowner/repo", "gh pr create --title 'Literal title' -R owner/repo"] {
            guard case let .association(value) = AgentSessionNativePullRequestObserver.observe(event(command)) else { return XCTFail(command) }
            XCTAssertEqual(value.identity.number, 42)
            XCTAssertEqual(value.provenance, "observedShellCreation")
        }
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event("gh pr create -Rother/repo")), .notice("repository_conflict"))
    }

    func testAmbiguousOrIncompleteOutputNeverAssociates() {
        for value in [event(output: "Created https://github.com/owner/repo/pull/42"), event(output: "https://github.com/owner/repo/pull/41\nhttps://github.com/owner/repo/pull/42"), event(exit: nil), event(truncated: true), event(output: "https://unknown.example/owner/repo/pull/42")] {
            guard case .notice = AgentSessionNativePullRequestObserver.observe(value) else { return XCTFail("Expected nonmutating notice") }
        }
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event(exit: 1)), .ignored)
    }

    func testShellCompositionCannotBecomeEvidence() {
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event("gh pr create && echo https://github.com/owner/repo/pull/42")), .notice("unsupported_command_shape"))
        for command in ["echo gh pr create", "zsh -lc 'gh pr create'", "mcp__Bash gh pr create"] {
            XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event(command)), .ignored)
        }
    }

    func testNativeDecoderRequiresInvocationArgumentsAndRetainsTruncation() {
        let result = #"{"command":"gh pr create","exitCode":0,"stdout":"https://github.com/owner/repo/pull/42","output_truncated":true}"#
        let event = AgentNativeCommandCompletion.decode(invocationID: UUID(), argsJSON: nil, resultJSON: result, isError: false)
        XCTAssertNil(event.command, "Tool output cannot supply invocation provenance")
        XCTAssertTrue(event.isTruncated)
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(event), .ignored)
    }

    func testWorktreeRemoteHostUsesCommonRepositoryConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-hosts-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main/.git", isDirectory: true)
        let admin = main.appendingPathComponent("worktrees/lane", isDirectory: true)
        let lane = root.appendingPathComponent("lane", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true)
        try Data("gitdir: ../main/.git/worktrees/lane\n".utf8).write(to: lane.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: admin.appendingPathComponent("commondir"))
        try Data("[remote \"origin\"]\n url = https://git.example/acme/app.git\n".utf8).write(to: main.appendingPathComponent("config"))
        XCTAssertEqual(AgentSessionPullRequestHosts.configured(repositoryPaths: [lane.path]), ["github.com", "git.example"])
    }

    func testDryRunIsNeverCreationEvidence() {
        let value = AgentNativeCommandCompletion(
            invocationID: UUID(),
            command: nil,
            argv: ["gh", "pr", "create", "--dry-run", "--body", "Preview\nhttps://github.com/owner/repo/pull/42"],
            exitCode: 0,
            output: "https://github.com/owner/repo/pull/42",
            isError: false,
            isTruncated: false
        )
        XCTAssertEqual(AgentSessionNativePullRequestObserver.observe(value), .notice("non_creating_command"))
    }

    func testConfiguredRemoteHostsDoNotTrustUnrelatedConfigURLs() {
        let config = "[remote \"origin\"]\n url = git@git.example:owner/repo.git\n[other]\n url = https://untrusted.example/repo"
        XCTAssertEqual(AgentSessionPullRequestHosts.remoteHosts(config: config), ["git.example"])
    }

    func testEnterpriseRequiresExplicitTrustedHost() throws {
        let url = "https://git.example/owner/repo/pull/42"
        XCTAssertThrowsError(try AgentSessionPullRequestEvidence.report(url: url, relationship: "created"))
        let value = try AgentSessionPullRequestEvidence.report(url: url, relationship: "created", trustedHosts: ["git.example"])
        XCTAssertEqual(value.identity.host, "git.example")
    }
}
