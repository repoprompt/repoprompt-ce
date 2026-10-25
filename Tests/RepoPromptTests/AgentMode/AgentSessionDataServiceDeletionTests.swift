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

    private func writeTemporaryImage(fixture: BatchDeleteFixture) throws -> AgentImageAttachment {
        let root = AgentAttachmentStore.managedStorageRootURL(for: fixture.storageURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        return AgentImageAttachment(source: .localFile(path: image.path), title: "Consumed image")
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
