import Darwin
import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessSecureFileAccessTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testRejectsFIFOAndDirectoryReadsWithoutBlocking() throws {
        let fixture = try makeRoot()
        let fifo = fixture.url.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)

        let access = HeadlessSecureFileAccess()
        XCTAssertThrowsError(try access.readRegularFile(root: fixture.root, relativePath: "pipe", maximumBytes: 1024))
        XCTAssertThrowsError(try access.readRegularFile(root: fixture.root, relativePath: "", maximumBytes: 1024))
    }

    func testRejectsLeafAndIntermediateSymlinks() throws {
        let fixture = try makeRoot()
        let realDirectory = fixture.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: realDirectory.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: fixture.url.appendingPathComponent("leaf.txt").path, withDestinationPath: realDirectory.appendingPathComponent("file.txt").path)
        try FileManager.default.createSymbolicLink(atPath: fixture.url.appendingPathComponent("linked-dir").path, withDestinationPath: realDirectory.path)

        let resolver = HeadlessPathResolver(roots: [fixture.root])
        XCTAssertThrowsError(try resolver.resolve("leaf.txt"))
        XCTAssertThrowsError(try resolver.resolve("linked-dir/file.txt"))
    }

    func testOpenedDescriptorsAreCloseOnExec() throws {
        let fixture = try makeRoot()
        let directory = fixture.url.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: directory.appendingPathComponent("file.txt"))

        var descriptorFlags: [String: Int32] = [:]
        let access = HeadlessSecureFileAccess { relativePath, descriptor in
            descriptorFlags[relativePath] = Darwin.fcntl(descriptor, F_GETFD)
        }

        _ = try access.inspect(root: fixture.root, relativePath: "")
        _ = try access.readRegularFile(root: fixture.root, relativePath: "dir/file.txt", maximumBytes: 1024)

        for relativePath in ["", "dir", "dir/file.txt"] {
            let flags = try XCTUnwrap(descriptorFlags[relativePath], relativePath)
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0, relativePath)
        }
    }

    func testLeafSwapAfterOpenReadsValidatedDescriptor() throws {
        let fixture = try makeRoot()
        let target = fixture.url.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        var swapped = false
        let access = HeadlessSecureFileAccess { relativePath, _ in
            guard relativePath == "target.txt", !swapped else { return }
            swapped = true
            try? FileManager.default.removeItem(at: target)
            try? Data("replacement".utf8).write(to: target)
        }

        let snapshot = try access.readRegularFile(root: fixture.root, relativePath: "target.txt", maximumBytes: 1024)
        XCTAssertEqual(String(data: snapshot.data, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
    }

    func testIntermediateSwapAfterOpenStaysWithinOpenedDirectory() throws {
        let fixture = try makeRoot()
        let directory = fixture.url.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: directory.appendingPathComponent("file.txt"))

        let outside = try makeTemporaryDirectory()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("file.txt"))
        let movedDirectory = fixture.url.appendingPathComponent("dir-opened", isDirectory: true)
        var swapped = false
        let access = HeadlessSecureFileAccess { relativePath, _ in
            guard relativePath == "dir", !swapped else { return }
            swapped = true
            try? FileManager.default.moveItem(at: directory, to: movedDirectory)
            try? FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: outside.path)
        }

        let snapshot = try access.readRegularFile(root: fixture.root, relativePath: "dir/file.txt", maximumBytes: 1024)
        XCTAssertEqual(String(data: snapshot.data, encoding: .utf8), "inside")
    }

    private func makeRoot() throws -> (url: URL, root: HeadlessAllowedRoot) {
        let url = try makeTemporaryDirectory()
        return (
            url,
            HeadlessAllowedRoot(
                id: UUID(),
                name: "Root",
                path: url.path,
                resolvedPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
                addedAt: Date()
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rpce-headless-secure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
