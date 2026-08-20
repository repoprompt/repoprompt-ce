import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class DesktopAgentAuthorityRestorationTests: XCTestCase {
    func testMissingPrototypeStoreIsNeitherReportedNorCreated() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let supportRoot = temporaryRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        var messages: [String] = []

        let observed = AppDomainRuntimeComposition.reportUnusedPrototypeAuthorityStoreIfPresent(
            applicationSupportRoot: supportRoot,
            log: { messages.append($0) }
        )

        XCTAssertFalse(observed)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportRoot.path))
    }

    func testExistingPrototypeStoreIsReportedWithoutOpeningOrMutatingIt() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let supportRoot = temporaryRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let databaseURL = AppDomainRuntimeComposition.prototypeAuthorityDatabaseURL(
            applicationSupportRoot: supportRoot
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinel = Data("prototype-authority-sentinel\u{0}not-a-database".utf8)
        try sentinel.write(to: databaseURL, options: .withoutOverwriting)
        let expectedMetadata = try metadata(at: databaseURL)
        var messages: [String] = []

        let observed = AppDomainRuntimeComposition.reportUnusedPrototypeAuthorityStoreIfPresent(
            applicationSupportRoot: supportRoot,
            log: { messages.append($0) }
        )
        let actualMetadata = try metadata(at: databaseURL)

        XCTAssertTrue(observed)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("will not be opened or migrated"))
        XCTAssertEqual(actualMetadata, expectedMetadata)
        XCTAssertEqual(try Data(contentsOf: databaseURL), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: databaseURL.deletingLastPathComponent().appendingPathComponent("repoprompt.sqlite-wal").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: databaseURL.deletingLastPathComponent().appendingPathComponent("repoprompt.sqlite-shm").path
        ))
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopAgentAuthorityRestorationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func metadata(at url: URL) throws -> FileMetadata {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileMetadata(
            device: value.st_dev,
            inode: value.st_ino,
            mode: value.st_mode,
            links: value.st_nlink,
            user: value.st_uid,
            group: value.st_gid,
            size: value.st_size,
            blocks: value.st_blocks,
            blockSize: value.st_blksize,
            accessSeconds: value.st_atimespec.tv_sec,
            accessNanoseconds: value.st_atimespec.tv_nsec,
            modificationSeconds: value.st_mtimespec.tv_sec,
            modificationNanoseconds: value.st_mtimespec.tv_nsec,
            statusSeconds: value.st_ctimespec.tv_sec,
            statusNanoseconds: value.st_ctimespec.tv_nsec
        )
    }

    private struct FileMetadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let links: nlink_t
        let user: uid_t
        let group: gid_t
        let size: off_t
        let blocks: blkcnt_t
        let blockSize: blksize_t
        let accessSeconds: Int
        let accessNanoseconds: Int
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let statusSeconds: Int
        let statusNanoseconds: Int
    }
}
