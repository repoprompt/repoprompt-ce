#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import Foundation
import RepoPromptVCS
import XCTest

final class GitMetadataFileReaderTests: XCTestCase {
    func testMetadataReaderPreservesBytesAndAuthorizedRegularSymlinks() throws {
        let base = try fixture()
        let file = base.appendingPathComponent("metadata ")
        let link = base.appendingPathComponent("link")
        let bytes = Data(" ../literal path \t\n\0".utf8)
        try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try VCSMetadataFileReader.contents(of: file), bytes)
        XCTAssertEqual(try VCSMetadataFileReader.contents(of: link), bytes)
        XCTAssertThrowsError(try VCSMetadataFileReader.contents(of: base))

        let root = base.appendingPathComponent("root")
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let pointer = git.appendingPathComponent("pointer ")
        try Data(".\n".utf8).write(to: pointer)
        try FileManager.default.createSymbolicLink(at: git.appendingPathComponent("commondir"), withDestinationURL: pointer)
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        XCTAssertNoThrow(try GitReadRepositoryBinding(layout: layout))
    }

    func testMetadataReaderRejectsOversizedFilesWithoutAcceptingTruncatedPrefixes() throws {
        let base = try fixture()
        let file = base.appendingPathComponent("metadata")
        let bytes = Data(repeating: 0x41, count: 4096)
        try bytes.write(to: file)
        XCTAssertEqual(try VCSMetadataFileReader.contents(of: file), bytes)
        try (bytes + Data([0x42])).write(to: file)
        XCTAssertThrowsError(try VCSMetadataFileReader.contents(of: file))
    }

    func testScopedResolverRejectsFIFOMetadataWithoutWaitingForAWriter() throws {
        for name in ["normal-commondir", "gitfile", "linked-commondir", "linked-backpointer"] {
            let base = try fixture()
            let root = base.appendingPathComponent("root")
            let dotGit = root.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fifo: URL
            switch name {
            case "gitfile":
                fifo = dotGit
            case "normal-commondir":
                try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
                fifo = dotGit.appendingPathComponent("commondir")
            default:
                let git = base.appendingPathComponent("main/.git/worktrees/linked")
                try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
                try Data("gitdir: \(git.path)\n".utf8).write(to: dotGit)
                if name == "linked-commondir" {
                    try Data("\(dotGit.path)\n".utf8).write(to: git.appendingPathComponent("gitdir"))
                    fifo = git.appendingPathComponent("commondir")
                } else {
                    try Data("../..\n".utf8).write(to: git.appendingPathComponent("commondir"))
                    fifo = git.appendingPathComponent("gitdir")
                }
            }
            let watchdog = try MetadataFIFOReadWatchdog(at: fifo)
            defer { _ = watchdog.finish() }
            XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]), name)
            XCTAssertFalse(watchdog.finish(), "\(name) waited for a FIFO writer instead of rejecting the file type")
        }
    }

    func testBindingSnapshotAndRevalidationRejectFIFOMetadata() throws {
        for revalidate in [false, true] {
            let base = try fixture()
            let root = base.appendingPathComponent("root")
            let git = root.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            let binding = try GitReadRepositoryBinding(layout: layout)
            let watchdog = try MetadataFIFOReadWatchdog(at: git.appendingPathComponent("commondir"))
            defer { _ = watchdog.finish() }
            if revalidate {
                XCTAssertThrowsError(try binding.revalidate())
            } else {
                XCTAssertThrowsError(try GitReadRepositoryBinding(layout: layout))
            }
            XCTAssertFalse(watchdog.finish(), "Binding reads must reject FIFOs before waiting on them")
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

/// A failure must not strand the XCTest process in the old blocking open. Only
/// the watchdog supplies a writer; passing reads must finish without its rescue.
private final class MetadataFIFOReadWatchdog: @unchecked Sendable {
    private let completed = DispatchSemaphore(value: 0)
    private let settled = DispatchGroup()
    private let lock = NSLock()
    private var rescued = false

    init(at url: URL) throws {
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        settled.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { settled.leave() }
            guard completed.wait(timeout: .now() + 5) == .timedOut else { return }
            lock.withLock { rescued = true }
            let descriptor = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let bytes = Data(repeating: 0x78, count: 4097)
            // Later reads must also terminate if the old resolver retries this
            // path while constructing or revalidating the binding.
            try? FileManager.default.removeItem(at: url)
            try? bytes.write(to: url)
            _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    func finish() -> Bool {
        completed.signal()
        let finished = settled.wait(timeout: .now() + 6) == .success
        return !finished || lock.withLock { rescued }
    }
}
