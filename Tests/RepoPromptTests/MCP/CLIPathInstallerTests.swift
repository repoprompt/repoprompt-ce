import Foundation
@testable import RepoPrompt
import XCTest

final class CLIPathInstallerTests: XCTestCase {
    private var root: URL!
    private var bundledCLI: URL!
    private var linkURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPathInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundledCLI = root.appendingPathComponent("RepoPrompt.app/Contents/MacOS/repoprompt-mcp")
        try FileManager.default.createDirectory(at: bundledCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: bundledCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)
        linkURL = root.appendingPathComponent("repoprompt_ce_cli_debug")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClassifierHandlesMissingCurrentDanglingAndUnmanagedEntries() throws {
        let allowlist: Set = [bundledCLI.path]
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .missing
        )

        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: bundledCLI)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .managedCurrent(destination: bundledCLI.path)
        )

        try FileManager.default.removeItem(at: bundledCLI)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .managedStale(destination: bundledCLI.path)
        )

        try FileManager.default.removeItem(at: linkURL)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: foreign)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .unmanaged
        )

        try FileManager.default.removeItem(at: linkURL)
        try Data("foreign".utf8).write(to: linkURL)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .unmanaged
        )
    }

    func testUserSpaceManagerCreatesMissingLinkAndRefusesUnmanagedOccupants() throws {
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: bundledCLI)
        XCTAssertTrue(
            CLISymlinkManagerUserSpace.ensureLocalSymlink(
                userSymlinkURL: linkURL,
                bundledCLIURL: bundledCLI
            )
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), bundledCLI.path)

        try FileManager.default.removeItem(at: linkURL)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: foreign)
        XCTAssertFalse(
            CLISymlinkManagerUserSpace.ensureLocalSymlink(
                userSymlinkURL: linkURL,
                bundledCLIURL: bundledCLI
            )
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), foreign.path)

        try FileManager.default.removeItem(at: linkURL)
        try Data("do not replace".utf8).write(to: linkURL)
        XCTAssertFalse(
            CLISymlinkManagerUserSpace.ensureLocalSymlink(
                userSymlinkURL: linkURL,
                bundledCLIURL: bundledCLI
            )
        )
        XCTAssertEqual(try String(contentsOf: linkURL), "do not replace")
    }

    func testUserSpaceManagerRepairsRecognizedMovedAppDestination() throws {
        let recognizedOldPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp")
            .path
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: recognizedOldPath)

        XCTAssertTrue(
            CLISymlinkManagerUserSpace.ensureLocalSymlink(
                userSymlinkURL: linkURL,
                bundledCLIURL: bundledCLI
            )
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), bundledCLI.path)
    }

    func testUserSpaceManagerRollsBackRacedUnmanagedReplacement() throws {
        let recognizedOldPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp")
            .path
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: recognizedOldPath)
        let foreign = root.appendingPathComponent("foreign")

        let installed = CLISymlinkManagerUserSpace.ensureLocalSymlink(
            userSymlinkURL: linkURL,
            bundledCLIURL: bundledCLI,
            beforeCommit: {
                try? FileManager.default.removeItem(at: self.linkURL)
                try? FileManager.default.createSymbolicLink(at: self.linkURL, withDestinationURL: foreign)
            }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), foreign.path)
    }

    func testPrivilegedShellCommandReplacesAndRemovesOnlyManagedLinks() throws {
        let installURL = root.appendingPathComponent("bin/rpce-cli-debug")
        try FileManager.default.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldTarget = root.appendingPathComponent("old-managed").path
        try FileManager.default.createSymbolicLink(atPath: installURL.path, withDestinationPath: oldTarget)

        let installCommand = CLIPathInstaller.test_atomicManagedSymlinkInstallCommand(
            installPath: installURL.path,
            desiredDestination: bundledCLI.path,
            managedDestinations: [oldTarget, bundledCLI.path]
        )
        let install = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", installCommand]
        )
        XCTAssertEqual(install.terminationStatus, 0, install.outputText)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installURL.path), bundledCLI.path)

        let removalCommand = CLIPathInstaller.test_managedSymlinkRemovalCommand(
            installPath: installURL.path,
            managedDestinations: [oldTarget, bundledCLI.path]
        )
        let removal = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", removalCommand]
        )
        XCTAssertEqual(removal.terminationStatus, 0, removal.outputText)
        XCTAssertNil(BootstrapSocketOwnership.identity(atPath: installURL.path))

        try Data("foreign".utf8).write(to: installURL)
        let refusal = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", installCommand]
        )
        XCTAssertEqual(refusal.terminationStatus, 73, refusal.outputText)
        XCTAssertEqual(try String(contentsOf: installURL), "foreign")
    }

    func testPrivilegedWrapperOwnershipRecheckRejectsMarkerBelowLineEight() throws {
        let installURL = root.appendingPathComponent("bin/claude-rpce-debug")
        try FileManager.default.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("managed-wrapper")
        let source = "#!/bin/bash\n\(ManagedCLIPathPolicy.currentClaudeWrapperMarker)\nexec claude\n"
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let racedContent = (1 ... 8).map { "# foreign line \($0)" }.joined(separator: "\n")
            + "\n\(ManagedCLIPathPolicy.currentClaudeWrapperMarker)\nexec foreign\n"
        try racedContent.write(to: installURL, atomically: true, encoding: .utf8)

        let command = CLIPathInstaller.test_atomicManagedWrapperInstallCommand(
            sourcePath: sourceURL.path,
            installPath: installURL.path
        )
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", command]
        )

        XCTAssertEqual(result.terminationStatus, 73, result.outputText)
        XCTAssertEqual(try String(contentsOf: installURL), racedContent)
    }

    func testWrapperMarkerMustBeExactHeaderLine() {
        let current = "#!/bin/bash\n\(ManagedCLIPathPolicy.currentClaudeWrapperMarker)\nexec claude\n"
        XCTAssertTrue(ManagedCLIPathPolicy.isManagedWrapper(current))
        XCTAssertTrue(ManagedCLIPathPolicy.isManagedWrapper("#!/bin/bash\n\(ManagedCLIPathPolicy.legacyClaudeWrapperMarkers[0])\n"))
        XCTAssertFalse(ManagedCLIPathPolicy.isManagedWrapper("#!/bin/bash\necho '\(ManagedCLIPathPolicy.currentClaudeWrapperMarker)'\n"))
        XCTAssertFalse(ManagedCLIPathPolicy.isManagedWrapper("#!/bin/bash\necho unrelated\n"))
    }
}
