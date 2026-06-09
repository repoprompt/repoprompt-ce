import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessStateTransactionTests: XCTestCase {
    func testConcurrentWorkspaceCreationDoesNotRestoreRevokedPermission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessStateTransactionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        let rootDirectory = directory.appendingPathComponent("AllowedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let root = try HeadlessRootAccessPolicy.makeAllowedRoot(path: rootDirectory.path, name: "Root")
        let setupStore = HeadlessConfigurationStore(paths: paths)
        _ = try setupStore.update { configuration in
            configuration.allowedRoots = [root]
            configuration.permissions.writeFiles = true
        }

        let statusFile = directory.appendingPathComponent("permission-revocation-status")
        let process = try PermissionRevocationProcess(
            process: permissionRevocationProcess(paths: paths, statusFile: statusFile)
        )
        let hostStore = HeadlessConfigurationStore(paths: paths)
        let host = HeadlessHost(
            configurationStore: hostStore,
            catalogMutationLoadedHook: {
                try process.run()
                let status = try Self.waitForStatusFile(statusFile)
                if status == "acquired" {
                    process.waitUntilExit()
                }
            }
        )

        let workspace = try await host.createWorkspace(name: "Concurrent", rootTokens: [root.name])
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "blocked")
        let finalConfiguration = try setupStore.loadOrCreate()
        XCTAssertFalse(finalConfiguration.permissions.writeFiles)
        XCTAssertEqual(finalConfiguration.activeWorkspaceID, workspace.id)
        XCTAssertEqual(
            try HeadlessWorkspaceStore(paths: paths).loadWorkspace(id: workspace.id)?.rootIDs,
            [root.id]
        )
    }

    private func permissionRevocationProcess(paths: HeadlessStatePaths, statusFile: URL) throws -> Process {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 is required for the cross-process lock regression.")
        }
        let headlessExecutable = try builtHeadlessExecutable()

        let script = #"""
        import fcntl
        import os
        import subprocess
        import sys

        state_dir, status_path, executable = sys.argv[1], sys.argv[2], sys.argv[3]
        lock_path = os.path.join(state_dir, "config.lock")
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                status = "acquired"
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except BlockingIOError:
                status = "blocked"
        finally:
            os.close(lock_fd)
        with open(status_path, "w", encoding="utf-8") as status_file:
            status_file.write(status)
            status_file.flush()
            os.fsync(status_file.fileno())
        subprocess.run(
            [executable, "--state-dir", state_dir, "config", "permissions", "set", "write_files", "false"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        """#

        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script, paths.rootDirectory.path, statusFile.path, headlessExecutable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func builtHeadlessExecutable() throws -> URL {
        let startingURLs = [
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            Bundle(for: Self.self).bundleURL.standardizedFileURL
        ]
        for startingURL in startingURLs {
            var directory = startingURL
            for _ in 0 ..< 10 {
                directory.deleteLastPathComponent()
                let candidate = directory.appendingPathComponent("repoprompt-headless", isDirectory: false)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw HeadlessCommandError("Unable to locate the built repoprompt-headless executable for the cross-process regression.")
    }

    private static func waitForStatusFile(_ url: URL) throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let status = try? String(contentsOf: url, encoding: .utf8), !status.isEmpty {
                return status
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HeadlessCommandError("Timed out waiting for concurrent permission revocation to attempt config.lock.")
    }
}

private final class PermissionRevocationProcess: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func run() throws {
        try process.run()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }
}
