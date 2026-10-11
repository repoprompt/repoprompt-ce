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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path), title: "shot.png")

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
                AgentImageAttachment(source: .localFile(path: userFile.path)),
                AgentImageAttachment(source: .localFile(path: nestedFile.path)),
                AgentImageAttachment(source: .localFile(path: missing.path)),
                AgentImageAttachment(source: .url("https://example.com/remote.png"))
            ],
            sessionID: UUID(),
            temporaryRoot: temporaryRoot
        )

        XCTAssertTrue(result.retained.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedFile.path))
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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))

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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))

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
        let lost = AgentImageAttachment(
            source: .localFile(path: temporaryRoot.appendingPathComponent("gone.png").path),
            title: "lost.png"
        )
        let kept = folder.appendingPathComponent("\(lost.id.uuidString).jpg")
        try Data("kept".utf8).write(to: kept)
        let present = temporaryRoot.appendingPathComponent("present.png")
        try Data("present".utf8).write(to: present)
        let stillThere = AgentImageAttachment(source: .localFile(path: present.path))
        let noCopy = AgentImageAttachment(source: .localFile(path: temporaryRoot.appendingPathComponent("never.png").path))

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
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
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
