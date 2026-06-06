import Foundation
@testable import RepoPrompt
import XCTest

final class DebugCLIInstallerScriptTests: XCTestCase {
    func testInstallRepairsManagedChainAtomicallyAndUninstallPreservesUserLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let install = try fixture.run("install")
        XCTAssertEqual(install.status, 0, install.output)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.pathLink.path), fixture.userLink.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.userLink.path), fixture.bundledCLI.path)

        let uninstall = try fixture.run("uninstall")
        XCTAssertEqual(uninstall.status, 0, uninstall.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pathLink.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.userLink.path))
    }

    func testInstallRefusesUnmanagedUserSymlinkAndFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let foreign = fixture.root.appendingPathComponent("foreign")
        try FileManager.default.createSymbolicLink(at: fixture.userLink, withDestinationURL: foreign)

        let symlinkResult = try fixture.run("install")
        XCTAssertNotEqual(symlinkResult.status, 0)
        XCTAssertTrue(symlinkResult.output.contains("unmanaged user-space symlink"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.userLink.path), foreign.path)

        try FileManager.default.removeItem(at: fixture.userLink)
        try Data("foreign".utf8).write(to: fixture.userLink)
        let fileResult = try fixture.run("install")
        XCTAssertNotEqual(fileResult.status, 0)
        XCTAssertEqual(try String(contentsOf: fixture.userLink), "foreign")
    }

    func testInstallFailsNoninteractivelyWhenInstallDirectoryIsUnwritable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.pathLink.deletingLastPathComponent().path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.pathLink.deletingLastPathComponent().path
            )
        }

        let result = try fixture.run("install")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("not writable"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pathLink.path))
    }

    func testStatusDistinguishesUnmanagedDanglingPathLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(
            atPath: fixture.pathLink.path,
            withDestinationPath: fixture.root.appendingPathComponent("foreign-missing").path
        )

        let result = try fixture.run("status")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PATH command: unmanaged symlink"), result.output)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let appBundle: URL
        let bundledCLI: URL
        let userLink: URL
        let pathLink: URL
        let script: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("DebugCLIInstallerScriptTests-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            appBundle = root.appendingPathComponent("RepoPrompt.app", isDirectory: true)
            bundledCLI = appBundle.appendingPathComponent("Contents/MacOS/repoprompt-mcp")
            userLink = home.appendingPathComponent("Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug")
            pathLink = root.appendingPathComponent("bin/rpce-cli-debug")
            script = try RepoRoot.url().appendingPathComponent("Scripts/install_debug_cli.sh")

            try FileManager.default.createDirectory(at: bundledCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: userLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: pathLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho rpce-test-version\n".write(to: bundledCLI, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)
        }

        func run(_ action: String) throws -> (status: Int32, output: String) {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["REPOPROMPT_DEBUG_APP_BUNDLE"] = appBundle.path
            environment["REPOPROMPT_DEBUG_CLI_INSTALL_PATH"] = pathLink.path
            let result = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, action],
                environment: environment
            )
            return (result.terminationStatus, result.outputText)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
