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

    func testClassifierReclaimsStaleTranslocatedManagedTarget() throws {
        // Managed destination lives inside an app bundle.
        let allowlist: Set = [bundledCLI.path]

        // Simulate a user-space link created while the app ran translocated:
        // it targets the same app bundle CLI, but under a now-removed App
        // Translocation mount (dangling; the path does not exist).
        let staleTranslocated = "/private/var/folders/xx/T/AppTranslocation/"
            + UUID().uuidString
            + "/d/RepoPrompt.app/Contents/MacOS/repoprompt-mcp"
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: staleTranslocated)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .managedStale(destination: staleTranslocated)
        )

        // A translocated path whose app-bundle suffix does NOT match any
        // managed destination must stay unmanaged.
        try FileManager.default.removeItem(at: linkURL)
        let foreignTranslocated = "/private/var/folders/xx/T/AppTranslocation/"
            + UUID().uuidString
            + "/d/Evil.app/Contents/MacOS/repoprompt-mcp"
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: foreignTranslocated)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .unmanaged
        )
    }

    func testUserSpaceManagerRepairsStaleTranslocatedSymlink() throws {
        // Reproduces the reported bug: the user-space link points at a CLI
        // inside a now-removed App Translocation mount (dangling). Because the
        // app has since moved to a stable location, the link must be reclaimed
        // and repaired rather than rejected as unmanaged.
        let staleTranslocated = "/private/var/folders/xx/T/AppTranslocation/"
            + UUID().uuidString
            + "/d/RepoPrompt.app/Contents/MacOS/repoprompt-mcp"
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: staleTranslocated)

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

    func testManagedDestinationsRecognizeNoSpaceAndLegacyUserSpaceLinks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let destinations = ManagedCLIPathPolicy.managedDestinations(currentBundledCLIPath: nil)

        XCTAssertTrue(
            destinations.contains(home.appendingPathComponent("RepoPrompt/repoprompt_ce_cli_debug").standardizedFileURL.path)
        )
        XCTAssertTrue(
            destinations.contains(
                home.appendingPathComponent(
                    "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"
                ).standardizedFileURL.path
            )
        )
        XCTAssertTrue(
            destinations.contains(
                home.appendingPathComponent(
                    "Library/Application Support/RepoPrompt CE/repoprompt_cli_debug"
                ).standardizedFileURL.path
            )
        )
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

    func testPathExistsNotOursErrorReportsProvidedPath() {
        // The message must name the actual offending path, not a hardcoded one.
        let path = "/Users/example/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli"
        let description = CLIPathInstaller.InstallError.pathExistsNotOurs(path: path).errorDescription
        XCTAssertEqual(description, "A file already exists at \(path) that wasn't created by RepoPrompt")
    }

    func testUserSymlinkInstallErrorDistinguishesConflictFromSetupFailure() throws {
        // A genuinely foreign occupant is reported as a real conflict.
        try Data("foreign".utf8).write(to: linkURL)
        let conflict = CLIPathInstaller.userSymlinkInstallError(userLink: linkURL.path, bundledPath: bundledCLI.path)
        guard case let .pathExistsNotOurs(path) = conflict else {
            return XCTFail("expected pathExistsNotOurs, got \(conflict)")
        }
        XCTAssertEqual(path, linkURL.path)

        // No occupant (e.g. a directory-creation or atomic-swap failure) is
        // reported as a setup failure, not a spurious conflict.
        try FileManager.default.removeItem(at: linkURL)
        let setupFailure = CLIPathInstaller.userSymlinkInstallError(userLink: linkURL.path, bundledPath: bundledCLI.path)
        guard case let .userSymlinkSetupFailed(path) = setupFailure else {
            return XCTFail("expected userSymlinkSetupFailed, got \(setupFailure)")
        }
        XCTAssertEqual(path, linkURL.path)
    }

    func testUserSymlinkSetupFailedErrorReportsProvidedPath() {
        // The setup-failure message must name the path and avoid claiming a conflict.
        let path = "/Users/example/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli"
        let description = CLIPathInstaller.InstallError.userSymlinkSetupFailed(path: path).errorDescription
        XCTAssertEqual(
            description,
            "Could not set up the CLI link at \(path). Check permissions for its parent directory and try again."
        )
    }

    func testClassifierRejectsTranslocatedPathWithoutAppBundleComponent() throws {
        // A path under /AppTranslocation/ but with no *.app component has no
        // app-bundle suffix to match, so it must remain unmanaged.
        let allowlist: Set = [bundledCLI.path]
        let noAppBundle = "/private/var/folders/xx/T/AppTranslocation/"
            + UUID().uuidString
            + "/d/repoprompt-mcp"
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: noAppBundle)
        XCTAssertEqual(
            ManagedCLIPathPolicy.classifySymlink(
                at: linkURL.path,
                desiredDestination: bundledCLI.path,
                managedDestinations: allowlist
            ),
            .unmanaged
        )
    }
}
