import CoreGraphics
import Foundation
import ImageIO
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

final class AgentSessionAttachmentStoreTests: XCTestCase {
    private var baseURL: URL!
    private var agentSessionsFolder: URL!
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionAttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        agentSessionsFolder = baseURL.appendingPathComponent("AgentSessions", isDirectory: true)
        temporaryRoot = baseURL.appendingPathComponent("agent_attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    func testRetainMovesTemporaryCopyIntoSessionFolderAndRewritesSource() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let sessionID = UUID()
        let temporaryFile = temporaryRoot.appendingPathComponent("\(UUID().uuidString).png")
        try Data("small image".utf8).write(to: temporaryFile)
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path), title: "shot.png")

        let result = store.retain([attachment], sessionID: sessionID, temporaryRoot: temporaryRoot)

        let retained = try XCTUnwrap(result.retained[attachment.id])
        guard case let .localFile(path) = retained.source else {
            return XCTFail("Retained attachment must stay a local file")
        }
        let expected = store.sessionFolderURL(sessionID: sessionID)
            .appendingPathComponent("\(attachment.id.uuidString).png").path
        XCTAssertEqual(path, expected)
        XCTAssertEqual(retained.id, attachment.id)
        XCTAssertEqual(retained.title, "shot.png")
        XCTAssertEqual(retained.createdAt, attachment.createdAt)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("small image".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertTrue(store.isRetainedPath(path, sessionID: sessionID))
        XCTAssertFalse(store.isRetainedPath(path, sessionID: UUID()))
        XCTAssertEqual(result.evictedPaths, [])
    }

    func testGenericFileFactsSurviveRetentionRepairAndHandoffWithoutImageConversion() throws {
        let limits = AgentSessionAttachmentStore.Limits(
            maxRetainedImageBytes: 1, downscaledLongEdgePixels: 1, maxSessionFolderBytes: .max
        )
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder, limits: limits)
        let parentID = UUID()
        let childID = UUID()
        let source = temporaryRoot.appendingPathComponent("document.pdf")
        // ImageIO-readable bytes deliberately exercise the kind fence, not decoder failure.
        try writeNoisePNG(to: source, width: 16, height: 16)
        let bytes = try Data(contentsOf: source)
        let attachment = AgentFileAttachment(
            source: .localFile(path: source.path), title: "Document",
            kind: .pdf, fileName: "document.pdf", byteCount: bytes.count
        )
        let retained = try XCTUnwrap(store.retain([attachment], sessionID: parentID, temporaryRoot: temporaryRoot).retained[attachment.id])
        let repaired = try XCTUnwrap(store.repairMissingPaths([attachment], sessionID: parentID)[attachment.id])
        let copied = try XCTUnwrap(store.copyForHandoff(
            [attachment], sourceSessionID: parentID, destinationSessionID: childID, temporaryRoot: temporaryRoot
        )[attachment.id])
        for result in [retained, repaired, copied] {
            XCTAssertEqual(result.kind, .pdf)
            XCTAssertEqual(result.fileName, attachment.fileName)
            XCTAssertEqual(result.byteCount, bytes.count)
            guard case let .localFile(path) = result.source else { return XCTFail("Expected local copy") }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        }
    }

    func testRetainNeverMovesFilesOutsideTheTemporaryRoot() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let userFile = baseURL.appendingPathComponent("user-original.png")
        try Data("original".utf8).write(to: userFile)
        let nestedDirectory = temporaryRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedFile = nestedDirectory.appendingPathComponent("deep.png")
        try Data("nested".utf8).write(to: nestedFile)
        let missing = temporaryRoot.appendingPathComponent("already-gone.png")

        let result = store.retain(
            [
                AgentFileAttachment(source: .localFile(path: userFile.path)),
                AgentFileAttachment(source: .localFile(path: nestedFile.path)),
                AgentFileAttachment(source: .localFile(path: missing.path)),
                AgentFileAttachment(source: .url("https://example.com/remote.png"))
            ],
            sessionID: UUID(),
            temporaryRoot: temporaryRoot
        )

        XCTAssertTrue(result.retained.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedFile.path))
    }

    func testHandoffCopiesOwnedImagesAndRepairsCapturedTemporaryPathsWithoutMovingTheParent() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let parentID = UUID()
        let childID = UUID()
        let original = temporaryRoot.appendingPathComponent("original.png")
        let bytes = Data("parent image".utf8)
        try bytes.write(to: original)
        let attachment = AgentFileAttachment(source: .localFile(path: original.path), title: "Keep this image")
        let retained = try XCTUnwrap(store.retain([attachment], sessionID: parentID, temporaryRoot: temporaryRoot).retained[attachment.id])
        guard case let .localFile(parentPath) = retained.source else { return XCTFail("Expected retained image") }

        // Handoff captured the temporary path before retention finished. The same ID resolves only
        // under the captured parent's folder, then gets an independently owned child copy.
        let copied = try store.copyForHandoff(
            [attachment, attachment], sourceSessionID: parentID, destinationSessionID: childID,
            temporaryRoot: temporaryRoot
        )
        let child = try XCTUnwrap(copied[attachment.id])
        guard case let .localFile(childPath) = child.source else { return XCTFail("Expected child image") }
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(child.id, attachment.id)
        XCTAssertEqual(child.title, attachment.title)
        XCTAssertEqual(child.createdAt, attachment.createdAt)
        XCTAssertNotEqual(childPath, parentPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: parentPath)), bytes)
        XCTAssertTrue(store.isRetainedPath(childPath, sessionID: childID))
        XCTAssertFalse(store.isRetainedPath(childPath, sessionID: parentID))
        store.removeSessionFolder(sessionID: parentID)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: childPath)), bytes)
        XCTAssertTrue(store.isRetainedPath(childPath, sessionID: childID))
    }

    func testHumanHandoffOmitsOnlyMissingImagesAndCopiesRemainingBytesIndependently() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let parentID = UUID()
        let goodURL = temporaryRoot.appendingPathComponent("good.png")
        let bytes = Data("independent".utf8)
        try bytes.write(to: goodURL)
        let good = AgentFileAttachment(source: .localFile(path: goodURL.path))
        let missing = AgentFileAttachment(source: .localFile(path: temporaryRoot.appendingPathComponent("gone.png").path))
        for attachments in [[missing, good], [missing]] {
            let childID = UUID()
            let copied = try store.copyForHandoff(
                attachments, sourceSessionID: parentID, destinationSessionID: childID,
                temporaryRoot: temporaryRoot, missingImagePolicy: .omitMissingImagesForHumanHandoff
            )
            XCTAssertNil(copied[missing.id])
            XCTAssertEqual(copied.count, attachments.count - 1)
            if let copy = copied[good.id], case let .localFile(path) = copy.source {
                try FileManager.default.removeItem(at: goodURL)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
                try bytes.write(to: goodURL)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: childID).path))
            }
        }
        XCTAssertThrowsError(try store.copyForHandoff(
            [missing], sourceSessionID: parentID, destinationSessionID: UUID(), temporaryRoot: temporaryRoot
        ))
    }

    func testHumanOmissionDoesNotRelaxNonImageCapDestinationOrDuplicateFailures() throws {
        let store = AgentSessionAttachmentStore(
            agentSessionsFolder: agentSessionsFolder,
            limits: .init(maxRetainedImageBytes: .max, downscaledLongEdgePixels: 4096, maxSessionFolderBytes: 1)
        )
        let source = temporaryRoot.appendingPathComponent("source.png")
        try Data("too large".utf8).write(to: source)
        let good = AgentFileAttachment(source: .localFile(path: source.path))
        let missing = AgentFileAttachment(source: .localFile(path: temporaryRoot.appendingPathComponent("missing.pdf").path), kind: .pdf)
        for attachments in [[missing], [good]] {
            XCTAssertThrowsError(try store.copyForHandoff(
                attachments, sourceSessionID: UUID(), destinationSessionID: UUID(), temporaryRoot: temporaryRoot,
                missingImagePolicy: .omitMissingImagesForHumanHandoff
            ))
        }
        let normal = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let childID = UUID()
        try FileManager.default.createDirectory(at: normal.sessionFolderURL(sessionID: childID), withIntermediateDirectories: true)
        XCTAssertThrowsError(try normal.copyForHandoff(
            [missing], sourceSessionID: UUID(), destinationSessionID: childID, temporaryRoot: temporaryRoot,
            missingImagePolicy: .omitMissingImagesForHumanHandoff
        ))
        XCTAssertThrowsError(try normal.copyForHandoff(
            [good, AgentFileAttachment(id: good.id, source: missing.source)],
            sourceSessionID: UUID(), destinationSessionID: UUID(), temporaryRoot: temporaryRoot,
            missingImagePolicy: .omitMissingImagesForHumanHandoff
        ))
        XCTAssertEqual(try Data(contentsOf: source), Data("too large".utf8))
    }

    func testHumanHandoffRejectsUnsafeEntriesAndAmbiguousRetainedCopies() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let parentID = UUID()
        let missingURL = temporaryRoot.appendingPathComponent("gone.png")
        let missing = AgentFileAttachment(source: .localFile(path: missingURL.path))
        let folder = store.sessionFolderURL(sessionID: parentID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("\(missing.id.uuidString).png")
        let second = folder.appendingPathComponent("\(missing.id.uuidString).jpg")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        func reject(_ attachment: AgentFileAttachment = missing) {
            XCTAssertThrowsError(try store.copyForHandoff(
                [attachment], sourceSessionID: parentID, destinationSessionID: UUID(),
                temporaryRoot: temporaryRoot, missingImagePolicy: .omitMissingImagesForHumanHandoff
            ))
        }
        reject()
        try FileManager.default.removeItem(at: second)
        let copied = try store.copyForHandoff(
            [missing], sourceSessionID: parentID, destinationSessionID: UUID(),
            temporaryRoot: temporaryRoot, missingImagePolicy: .omitMissingImagesForHumanHandoff
        )
        XCTAssertNotNil(copied[missing.id], "moved temporary images must resolve their retained bytes")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: baseURL.appendingPathComponent("absent"))
        reject()
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: baseURL.appendingPathComponent("absent-folder"))
        reject()
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: missingURL, withDestinationURL: baseURL.appendingPathComponent("absent"))
        reject()
        reject(AgentFileAttachment(source: .localFile(path: baseURL.appendingPathComponent("foreign-missing.png").path)))
        let foreign = baseURL.appendingPathComponent("foreign.png")
        try Data("foreign".utf8).write(to: foreign)
        reject(AgentFileAttachment(source: .localFile(path: foreign.path)))
    }

    func testHandoffFailureDiscardsPartialCopiesWithoutTouchingSourcesOrExistingDestination() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let source = temporaryRoot.appendingPathComponent("source.png")
        let bytes = Data("original source".utf8)
        try bytes.write(to: source)
        let good = AgentFileAttachment(source: .localFile(path: source.path))
        let foreign = baseURL.appendingPathComponent("foreign.png")
        try bytes.write(to: foreign)
        let symlink = temporaryRoot.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        for badPath in [temporaryRoot.appendingPathComponent("missing.png").path, foreign.path, symlink.path] {
            let childID = UUID()
            XCTAssertThrowsError(try store.copyForHandoff(
                [good, AgentFileAttachment(source: .localFile(path: badPath))],
                sourceSessionID: UUID(), destinationSessionID: childID, temporaryRoot: temporaryRoot
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: childID).path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path), [])
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        }

        let occupiedID = UUID()
        let occupiedFolder = store.sessionFolderURL(sessionID: occupiedID)
        try FileManager.default.createDirectory(at: occupiedFolder, withIntermediateDirectories: true)
        let sentinel = occupiedFolder.appendingPathComponent("existing.png")
        try bytes.write(to: sentinel)
        XCTAssertThrowsError(try store.copyForHandoff(
            [good], sourceSessionID: UUID(), destinationSessionID: occupiedID, temporaryRoot: temporaryRoot
        ))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testHandoffRejectsOversizedSetsAndAmbiguousAttachmentIDsWithoutEvictingImages() throws {
        let store = AgentSessionAttachmentStore(
            agentSessionsFolder: agentSessionsFolder,
            limits: .init(maxRetainedImageBytes: .max, downscaledLongEdgePixels: 4096, maxSessionFolderBytes: 6)
        )
        let first = temporaryRoot.appendingPathComponent("first.png")
        let second = temporaryRoot.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let attachment = AgentFileAttachment(source: .localFile(path: first.path))
        for secondID in [UUID(), attachment.id] {
            XCTAssertThrowsError(try store.copyForHandoff(
                [attachment, AgentFileAttachment(id: secondID, source: .localFile(path: second.path))],
                sourceSessionID: UUID(), destinationSessionID: UUID(), temporaryRoot: temporaryRoot
            ))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path), [])
            XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
            XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        }
    }

    func testSymlinkedSessionFolderCannotBorrowAnotherSessionsImages() throws {
        let store = AgentSessionAttachmentStore(
            agentSessionsFolder: agentSessionsFolder,
            limits: .init(maxRetainedImageBytes: .max, downscaledLongEdgePixels: 4096, maxSessionFolderBytes: 0)
        )
        let ownerID = UUID()
        let linkedID = UUID()
        let attachmentID = UUID()
        let ownerFolder = store.sessionFolderURL(sessionID: ownerID)
        try FileManager.default.createDirectory(at: ownerFolder, withIntermediateDirectories: true)
        let image = ownerFolder.appendingPathComponent("\(attachmentID.uuidString).png")
        try Data("owner image".utf8).write(to: image)
        let linkedFolder = store.sessionFolderURL(sessionID: linkedID)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: ownerFolder)
        let linkedImage = linkedFolder.appendingPathComponent(image.lastPathComponent)
        XCTAssertFalse(store.isRetainedPath(linkedImage.path, sessionID: linkedID))
        XCTAssertNil(store.locateRetainedFile(attachmentID: attachmentID, sessionID: linkedID))
        XCTAssertTrue(store.enforceSessionCap(sessionID: linkedID).isEmpty)
        let temporary = temporaryRoot.appendingPathComponent("new.png")
        try Data("replacement".utf8).write(to: temporary)
        let result = store.retain(
            [AgentFileAttachment(id: attachmentID, source: .localFile(path: temporary.path))],
            sessionID: linkedID, temporaryRoot: temporaryRoot
        )
        XCTAssertTrue(result.retained.isEmpty)
        XCTAssertEqual(try Data(contentsOf: image), Data("owner image".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testOversizedImageIsKeptAsDownscaledCopy() throws {
        let limits = AgentSessionAttachmentStore.Limits(
            maxRetainedImageBytes: 1024,
            downscaledLongEdgePixels: 64,
            maxSessionFolderBytes: .max
        )
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder, limits: limits)
        let sessionID = UUID()
        let temporaryFile = temporaryRoot.appendingPathComponent("\(UUID().uuidString).png")
        try writeNoisePNG(to: temporaryFile, width: 256, height: 128)
        let originalSize = try XCTUnwrap(fileSize(temporaryFile))
        XCTAssertGreaterThan(originalSize, limits.maxRetainedImageBytes)
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))

        let result = store.retain([attachment], sessionID: sessionID, temporaryRoot: temporaryRoot)

        guard case let .localFile(path)? = result.retained[attachment.id]?.source else {
            return XCTFail("Oversized image must still be retained")
        }
        let pixelSize = try XCTUnwrap(pixelSize(of: URL(fileURLWithPath: path)))
        XCTAssertEqual(max(pixelSize.width, pixelSize.height), 64)
        XCTAssertEqual(pixelSize.width / pixelSize.height, 2, accuracy: 0.05)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertTrue(store.isRetainedPath(path, sessionID: sessionID))
    }

    func testSessionCapEvictsOldestImagesFirst() throws {
        let limits = AgentSessionAttachmentStore.Limits(
            maxRetainedImageBytes: .max,
            downscaledLongEdgePixels: 4096,
            maxSessionFolderBytes: 250
        )
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder, limits: limits)
        let sessionID = UUID()
        let folder = store.sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let oldest = folder.appendingPathComponent("oldest.png")
        let middle = folder.appendingPathComponent("middle.png")
        try Data(repeating: 1, count: 100).write(to: oldest)
        try Data(repeating: 2, count: 100).write(to: middle)
        try setModificationDate(now.addingTimeInterval(-200), of: oldest)
        try setModificationDate(now.addingTimeInterval(-100), of: middle)
        let temporaryFile = temporaryRoot.appendingPathComponent("\(UUID().uuidString).png")
        try Data(repeating: 3, count: 100).write(to: temporaryFile)
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))

        let result = store.retain([attachment], sessionID: sessionID, temporaryRoot: temporaryRoot, now: now)

        XCTAssertEqual(result.evictedPaths, [oldest.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        guard case let .localFile(path)? = result.retained[attachment.id]?.source else {
            return XCTFail("The newest image must survive the cap")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testRemoveSessionFolderDeletesOnlyThatSession() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let removed = UUID()
        let kept = UUID()
        for sessionID in [removed, kept] {
            let folder = store.sessionFolderURL(sessionID: sessionID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("img".utf8).write(to: folder.appendingPathComponent("a.png"))
        }

        AgentSessionAttachmentStore.removeSessionFolder(sessionID: removed, agentSessionsFolder: agentSessionsFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: removed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: kept).path))
    }

    func testSweepRemovesOrphanedFoldersAndStaleUnpendingTemporaryFiles() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        // Files are created now and the sweep runs "eight days later": addedToDirectoryDate cannot
        // be backdated, so the clock moves instead.
        let now = Date().addingTimeInterval(8 * 24 * 60 * 60)
        let live = UUID()
        let orphan = UUID()
        let freshOrphan = UUID()
        let protectedOrphan = UUID()
        try Data("{}".utf8).write(to: agentSessionsFolder.appendingPathComponent("AgentSession-\(live.uuidString).json"))
        for sessionID in [live, orphan, freshOrphan, protectedOrphan] {
            try FileManager.default.createDirectory(at: store.sessionFolderURL(sessionID: sessionID), withIntermediateDirectories: true)
        }
        try setModificationDate(now, of: store.sessionFolderURL(sessionID: freshOrphan))
        let unrelated = store.rootURL.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let stale = temporaryRoot.appendingPathComponent("stale.png")
        let pending = temporaryRoot.appendingPathComponent("pending.png")
        let fresh = temporaryRoot.appendingPathComponent("fresh.png")
        for file in [stale, pending, fresh] {
            try Data("img".utf8).write(to: file)
        }
        try setModificationDate(now, of: fresh)

        let result = AgentSessionAttachmentStore.sweep(
            agentSessionsFolder: agentSessionsFolder,
            temporaryRoot: temporaryRoot,
            protectedSessionIDs: [protectedOrphan],
            protectedTemporaryPaths: [pending.path],
            now: now
        )

        XCTAssertEqual(result.removedSessionFolders, [orphan])
        XCTAssertEqual(result.removedTemporaryFiles, [stale.standardizedFileURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: live).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: freshOrphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(sessionID: protectedOrphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testRepairMissingPathsLocatesKeptCopyByAttachmentID() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let sessionID = UUID()
        let folder = store.sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lost = AgentFileAttachment(
            source: .localFile(path: temporaryRoot.appendingPathComponent("gone.png").path),
            title: "lost.png"
        )
        let kept = folder.appendingPathComponent("\(lost.id.uuidString).jpg")
        try Data("kept".utf8).write(to: kept)
        let present = temporaryRoot.appendingPathComponent("present.png")
        try Data("present".utf8).write(to: present)
        let stillThere = AgentFileAttachment(source: .localFile(path: present.path))
        let noCopy = AgentFileAttachment(source: .localFile(path: temporaryRoot.appendingPathComponent("never.png").path))

        let repaired = store.repairMissingPaths([lost, stillThere, noCopy], sessionID: sessionID)

        XCTAssertEqual(Set(repaired.keys), [lost.id])
        XCTAssertEqual(repaired[lost.id]?.source, .localFile(path: kept.path))
        XCTAssertEqual(repaired[lost.id]?.title, "lost.png")
        XCTAssertEqual(repaired[lost.id]?.createdAt, lost.createdAt)
        XCTAssertTrue(store.repairMissingPaths([lost], sessionID: UUID()).isEmpty, "Another session's folder is never searched")
    }

    func testRetainedPathRejectsSymlinksInAndOutOfTheSessionFolder() throws {
        let store = AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder)
        let sessionID = UUID()
        let folder = store.sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.appendingPathComponent("real.png")
        try Data("real".utf8).write(to: real)
        let outside = baseURL.appendingPathComponent("secret.png")
        try Data("secret".utf8).write(to: outside)
        let linkInFolder = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linkInFolder, withDestinationURL: outside)
        let otherFolder = store.sessionFolderURL(sessionID: UUID())
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let linkToRetained = otherFolder.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: linkToRetained, withDestinationURL: real)

        XCTAssertTrue(store.isRetainedPath(real.path, sessionID: sessionID))
        XCTAssertFalse(store.isRetainedPath(linkInFolder.path, sessionID: sessionID))
        XCTAssertFalse(store.isRetainedPath(linkToRetained.path, sessionID: sessionID))
        XCTAssertFalse(store.isRetainedPath(folder.appendingPathComponent("../\(sessionID.uuidString)x/a.png").path, sessionID: sessionID))
    }

    // MARK: - Helpers

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> Int64? {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Writes a noisy (poorly compressible) opaque PNG so its size exceeds a small byte limit.
    private func writeNoisePNG(to url: URL, width: Int, height: Int) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        var seed: UInt32 = 0x1234_5678
        for index in pixels.indices where index % 4 != 3 {
            seed = seed &* 1_103_515_245 &+ 12345
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
        let cgImage = try XCTUnwrap(image)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
