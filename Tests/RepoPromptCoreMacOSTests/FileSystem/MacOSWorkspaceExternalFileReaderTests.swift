import Darwin
import Foundation
@testable import RepoPromptCore
@testable import RepoPromptCoreMacOS
import XCTest

final class MacOSWorkspaceExternalFileReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testReadsOrdinaryFileAndResolvesDirectoryWithCloseOnExec() throws {
        let fixture = try makeFixture()
        let folder = fixture.skillsRoot.appendingPathComponent("example", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try Data("skill body".utf8).write(to: file)
        let descriptorFlags = LockedValue<Int32>(0)
        let reader = MacOSWorkspaceExternalFileReader { _, descriptor in
            descriptorFlags.value = Darwin.fcntl(descriptor, F_GETFD)
        }

        XCTAssertEqual(
            try reader.resolveDirectory(atAbsolutePath: folder.path, allowedDirectories: fixture.allowedDirectories),
            folder.path
        )
        XCTAssertEqual(
            try reader.resolveRegularFile(atAbsolutePath: file.path, allowedDirectories: fixture.allowedDirectories),
            file.path
        )
        XCTAssertEqual(
            String(data: try reader.readRegularFile(atAbsolutePath: file.path, allowedDirectories: fixture.allowedDirectories), encoding: .utf8),
            "skill body"
        )
        XCTAssertNotEqual(descriptorFlags.value & FD_CLOEXEC, 0)
    }

    func testAllowsInRootSymlinkAndRejectsEscapeSymlink() throws {
        let fixture = try makeFixture()
        let real = fixture.skillsRoot.appendingPathComponent("real.md")
        try Data("inside".utf8).write(to: real)
        let internalLink = fixture.skillsRoot.appendingPathComponent("internal.md")
        try FileManager.default.createSymbolicLink(atPath: internalLink.path, withDestinationPath: real.path)

        let outside = try makeTemporaryDirectory().appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let escapeLink = fixture.skillsRoot.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(atPath: escapeLink.path, withDestinationPath: outside.path)

        let reader = MacOSWorkspaceExternalFileReader()
        XCTAssertEqual(
            try reader.resolveRegularFile(atAbsolutePath: internalLink.path, allowedDirectories: fixture.allowedDirectories),
            real.path
        )
        XCTAssertEqual(
            String(data: try reader.readRegularFile(atAbsolutePath: internalLink.path, allowedDirectories: fixture.allowedDirectories), encoding: .utf8),
            "inside"
        )
        XCTAssertNil(try reader.resolveRegularFile(atAbsolutePath: escapeLink.path, allowedDirectories: fixture.allowedDirectories))
        XCTAssertThrowsError(try reader.readRegularFile(atAbsolutePath: escapeLink.path, allowedDirectories: fixture.allowedDirectories))
    }

    func testSupportsSymlinkedAllowedRoot() throws {
        let home = try makeTemporaryDirectory()
        let actualRoot = home.appendingPathComponent("actual-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let actualFile = actualRoot.appendingPathComponent("SKILL.md")
        try Data("linked root".utf8).write(to: actualFile)

        let linkedRoot = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: actualRoot.path)
        let linkedFile = linkedRoot.appendingPathComponent("SKILL.md")
        let reader = MacOSWorkspaceExternalFileReader()
        let allowedDirectories = AgentSupportDirectoryCatalog.builtInAlwaysReadableDirectories(homeDirectoryURL: home)

        XCTAssertEqual(
            try reader.resolveRegularFile(atAbsolutePath: linkedFile.path, allowedDirectories: allowedDirectories),
            linkedFile.path
        )
        XCTAssertEqual(
            String(data: try reader.readRegularFile(atAbsolutePath: linkedFile.path, allowedDirectories: allowedDirectories), encoding: .utf8),
            "linked root"
        )
    }

    func testRejectsDirectoryMasqueradingAsFile() throws {
        let fixture = try makeFixture()
        let directory = fixture.skillsRoot.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reader = MacOSWorkspaceExternalFileReader()

        XCTAssertNil(try reader.resolveRegularFile(atAbsolutePath: directory.path, allowedDirectories: fixture.allowedDirectories))
        XCTAssertThrowsError(try reader.readRegularFile(atAbsolutePath: directory.path, allowedDirectories: fixture.allowedDirectories))
    }

    func testLeafReplacementAfterValidationReadsOpenedDescriptor() throws {
        let fixture = try makeFixture()
        let target = fixture.skillsRoot.appendingPathComponent("target.md")
        try Data("original".utf8).write(to: target)
        let swapped = LockedValue(false)
        let reader = MacOSWorkspaceExternalFileReader { path, _ in
            guard path == target.path, !swapped.value else { return }
            swapped.value = true
            try? FileManager.default.removeItem(at: target)
            try? Data("replacement".utf8).write(to: target)
        }

        let data = try reader.readRegularFile(atAbsolutePath: target.path, allowedDirectories: fixture.allowedDirectories)
        XCTAssertEqual(String(data: data, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
    }

    func testIntermediateReplacementAfterValidationReadsOpenedDescriptor() throws {
        let fixture = try makeFixture()
        let directory = fixture.skillsRoot.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.md")
        try Data("inside".utf8).write(to: target)

        let outsideDirectory = try makeTemporaryDirectory()
        try Data("outside".utf8).write(to: outsideDirectory.appendingPathComponent("target.md"))
        let movedDirectory = fixture.skillsRoot.appendingPathComponent("dir-opened", isDirectory: true)
        let swapped = LockedValue(false)
        let reader = MacOSWorkspaceExternalFileReader { path, _ in
            guard path == target.path, !swapped.value else { return }
            swapped.value = true
            try? FileManager.default.moveItem(at: directory, to: movedDirectory)
            try? FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: outsideDirectory.path)
        }

        let data = try reader.readRegularFile(atAbsolutePath: target.path, allowedDirectories: fixture.allowedDirectories)
        XCTAssertEqual(String(data: data, encoding: .utf8), "inside")
    }

    private func makeFixture() throws -> (home: URL, skillsRoot: URL, allowedDirectories: [AlwaysReadableDirectory]) {
        let home = try makeTemporaryDirectory()
        let skillsRoot = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        return (
            home,
            skillsRoot,
            AgentSupportDirectoryCatalog.builtInAlwaysReadableDirectories(homeDirectoryURL: home)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptExternalReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
