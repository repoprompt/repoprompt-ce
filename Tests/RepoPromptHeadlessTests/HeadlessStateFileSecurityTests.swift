import Darwin
import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessStateFileSecurityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testBaseDirectoriesAndPersistedFilesEnforcePrivateModes() throws {
        let paths = HeadlessStatePaths(rootDirectory: try makeTemporaryDirectory().appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()

        XCTAssertEqual(try mode(at: paths.rootDirectory), 0o700)
        XCTAssertEqual(try mode(at: paths.workspacesDirectory), 0o700)
        XCTAssertEqual(try mode(at: paths.exportsDirectory), 0o700)

        let configurationStore = HeadlessConfigurationStore(paths: paths)
        _ = try configurationStore.loadOrCreate()
        let workspace = HeadlessWorkspaceDocument(name: "Secure", rootIDs: [])
        try HeadlessWorkspaceStore(paths: paths).save(workspace)

        XCTAssertEqual(try mode(at: paths.configFile), 0o600)
        XCTAssertEqual(
            try mode(at: paths.workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).json")),
            0o600
        )
        XCTAssertEqual(try mode(at: paths.configLockFile), 0o600)
        XCTAssertEqual(try mode(at: paths.workspaceLockFile(for: workspace.id)), 0o600)
    }

    func testConfigSymlinkAndDirectoryAreRejectedWithoutChangingTargetBytes() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let target = directory.appendingPathComponent("outside.json")
        let original = Data("outside".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(atPath: paths.configFile.path, withDestinationPath: target.path)

        XCTAssertThrowsError(try HeadlessConfigurationStore(paths: paths).loadOrCreate())
        XCTAssertEqual(try Data(contentsOf: target), original)

        try FileManager.default.removeItem(at: paths.configFile)
        try FileManager.default.createDirectory(at: paths.configFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try HeadlessConfigurationStore(paths: paths).loadOrCreate())
    }

    func testConfigHardLinkIsRejectedWithoutChangingSharedInode() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let outside = directory.appendingPathComponent("outside.json")
        let original = Data("outside".utf8)
        try original.write(to: outside)
        XCTAssertEqual(Darwin.link(outside.path, paths.configFile.path), 0)

        XCTAssertThrowsError(try HeadlessConfigurationStore(paths: paths).loadOrCreate())
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertEqual(try Data(contentsOf: paths.configFile), original)
    }

    func testWorkspaceSymlinkIsRejectedWithoutRepairRewrite() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let workspace = HeadlessWorkspaceDocument(name: "Outside", rootIDs: [])
        let outside = directory.appendingPathComponent("outside-workspace.json")
        let original = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(workspace)
        try original.write(to: outside)
        let workspacePath = paths.workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        try FileManager.default.createSymbolicLink(atPath: workspacePath.path, withDestinationPath: outside.path)

        XCTAssertThrowsError(try HeadlessWorkspaceStore(paths: paths).loadWorkspace(id: workspace.id))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testLockRejectsSymlinkAndUnsafeTypeAndSetsCloseOnExec() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let target = directory.appendingPathComponent("outside.lock")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: paths.configLockFile.path, withDestinationPath: target.path)
        XCTAssertThrowsError(try HeadlessFileLock(path: paths.configLockFile).lock())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")

        try FileManager.default.removeItem(at: paths.configLockFile)
        XCTAssertEqual(Darwin.mkfifo(paths.configLockFile.path, 0o600), 0)
        XCTAssertThrowsError(try HeadlessFileLock(path: paths.configLockFile).lock())
        try FileManager.default.removeItem(at: paths.configLockFile)

        FileManager.default.createFile(atPath: paths.configLockFile.path, contents: Data())
        XCTAssertEqual(Darwin.chmod(paths.configLockFile.path, 0o666), 0)
        var descriptorFlags: Int32 = 0
        let lock = HeadlessFileLock(path: paths.configLockFile) { descriptor in
            descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        }
        try lock.lock()
        defer { lock.unlock() }

        XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
        XCTAssertEqual(try mode(at: paths.configLockFile), 0o600)
    }

    func testReadRemainsAnchoredWhenStateRootIsReplacedAfterParentOpen() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        try HeadlessStateFileSecurity.writePrivateFile(
            Data("inside".utf8),
            to: paths.configFile,
            stateRoot: paths.rootDirectory
        )
        let movedState = directory.appendingPathComponent("MovedState", isDirectory: true)
        let outsideState = directory.appendingPathComponent("OutsideState", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideState, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideState.appendingPathComponent("config.json"))

        let data = try HeadlessStateFileSecurity.readPrivateFileIfPresent(
            at: paths.configFile,
            stateRoot: paths.rootDirectory
        ) { _ in
            try FileManager.default.moveItem(at: paths.rootDirectory, to: movedState)
            try FileManager.default.createSymbolicLink(
                atPath: paths.rootDirectory.path,
                withDestinationPath: outsideState.path
            )
        }

        XCTAssertEqual(String(data: try XCTUnwrap(data), encoding: .utf8), "inside")
    }

    func testWriteRemainsAnchoredWhenStateRootIsReplacedAfterParentOpen() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let movedState = directory.appendingPathComponent("MovedState", isDirectory: true)
        let outsideState = directory.appendingPathComponent("OutsideState", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideState, withIntermediateDirectories: true)
        let outsideConfig = outsideState.appendingPathComponent("config.json")
        try Data("outside".utf8).write(to: outsideConfig)

        try HeadlessStateFileSecurity.writePrivateFile(
            Data("anchored".utf8),
            to: paths.configFile,
            stateRoot: paths.rootDirectory,
            parentDirectoryOpenedHook: { _ in
                try FileManager.default.moveItem(at: paths.rootDirectory, to: movedState)
                try FileManager.default.createSymbolicLink(
                    atPath: paths.rootDirectory.path,
                    withDestinationPath: outsideState.path
                )
            }
        )

        XCTAssertEqual(
            try String(contentsOf: movedState.appendingPathComponent("config.json"), encoding: .utf8),
            "anchored"
        )
        XCTAssertEqual(try String(contentsOf: outsideConfig, encoding: .utf8), "outside")
    }

    func testLockCreationRemainsAnchoredWhenStateRootIsReplacedAfterParentOpen() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let movedState = directory.appendingPathComponent("MovedState", isDirectory: true)
        let outsideState = directory.appendingPathComponent("OutsideState", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideState, withIntermediateDirectories: true)

        let descriptor = try HeadlessStateFileSecurity.openPrivateLockFile(
            at: paths.configLockFile,
            stateRoot: paths.rootDirectory,
            parentDirectoryOpenedHook: { _ in
                try FileManager.default.moveItem(at: paths.rootDirectory, to: movedState)
                try FileManager.default.createSymbolicLink(
                    atPath: paths.rootDirectory.path,
                    withDestinationPath: outsideState.path
                )
            }
        )
        Darwin.close(descriptor)

        XCTAssertTrue(FileManager.default.fileExists(atPath: movedState.appendingPathComponent("config.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideState.appendingPathComponent("config.lock").path))
    }

    func testWorkspaceFilenamesAndDecodedIDsMustMatchBeforeAnyRewrite() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let store = HeadlessWorkspaceStore(paths: paths)

        let invalidName = paths.workspacesDirectory.appendingPathComponent("not-a-uuid.json")
        try Data("{}".utf8).write(to: invalidName)
        XCTAssertThrowsError(try store.loadWorkspaces())
        try FileManager.default.removeItem(at: invalidName)

        let filenameID = UUID()
        var document = HeadlessWorkspaceDocument(name: "Mismatched", rootIDs: [])
        document.id = UUID()
        let mismatchedFile = paths.workspacesDirectory.appendingPathComponent("\(filenameID.uuidString).json")
        let original = try HeadlessJSONFormatting.encoder(prettyPrinted: false).encode(document)
        try original.write(to: mismatchedFile)

        XCTAssertThrowsError(try store.loadWorkspace(id: filenameID))
        XCTAssertEqual(try Data(contentsOf: mismatchedFile), original)
    }

    func testOwnershipMismatchFailsClosed() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("owned.json")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        XCTAssertThrowsError(try HeadlessStateFileSecurity.validateOpenedDescriptor(
            descriptor,
            path: file.path,
            expectedKind: S_IFREG,
            requiredMode: 0o600,
            expectedOwner: Darwin.geteuid() &+ 1
        ))
    }

    func testStateRootSymlinkIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let actual = directory.appendingPathComponent("Actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let linked = directory.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: actual.path)

        XCTAssertThrowsError(try HeadlessStatePaths(rootDirectory: linked).ensureBaseDirectories())
    }

    private func mode(at url: URL) throws -> mode_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o777
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessStateSecurity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
