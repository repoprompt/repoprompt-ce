import Foundation
@testable import RepoPromptApp
import XCTest

final class DevinACPLaunchResolverTests: XCTestCase {
    func testProviderProfileMatchesInstalledDevinConvention() {
        XCTAssertEqual(CLILaunchProfiles.devin.commandName, "devin")
        XCTAssertTrue(CLILaunchProfiles.devin.supplementalSearchPaths.contains("~/.local/bin"))
        XCTAssertTrue(CLIPathHints.devin.contains("~/.local/bin"))
    }

    func testNonDevinCommandIsRejected() async throws {
        let resolver = DevinACPLaunchResolver(environmentProvider: { _ in [:] })
        let support = try await resolver.probeSupport(
            for: DevinAgentConfig(commandName: "not-devin", additionalPathHints: [])
        )
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Devin ACP command"))
    }

    func testSupportProbeRequiresZeroExitStatus() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "devin", in: directory, exitStatus: 3)
        let resolver = DevinACPLaunchResolver(environmentProvider: { _ in
            ["PATH": directory.path, "SHELL": "/bin/false"]
        })

        let support = try await resolver.probeSupport(
            for: DevinAgentConfig(commandName: "devin", additionalPathHints: [])
        )

        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("`devin acp --help` exited with status 3"), "unexpected reason: \(reason)")
    }

    func testSupportProbeRequiresDevinACPHelpMarkers() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "devin", in: directory, output: "generic help")
        let resolver = DevinACPLaunchResolver(environmentProvider: { _ in
            ["PATH": directory.path, "SHELL": "/bin/false"]
        })

        let support = try await resolver.probeSupport(
            for: DevinAgentConfig(commandName: "devin", additionalPathHints: [])
        )

        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("did not advertise ACP support"), "unexpected reason: \(reason)")
    }

    func testBunStyleSymlinkShapeIsAcceptedAndLaunchesACP() async throws {
        let directory = try makeTemporaryDirectory()
        let targetDirectory = directory.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = try makeExecutable(named: "devin-entry", in: targetDirectory)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let symlink = binDirectory.appendingPathComponent("devin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let resolver = DevinACPLaunchResolver(environmentProvider: { _ in
            ["PATH": binDirectory.path, "SHELL": "/bin/false"]
        })
        let config = DevinAgentConfig(commandName: "devin", additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        let launch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertTrue(launch.command.hasSuffix("devin-entry"), "unexpected command: \(launch.command)")
        XCTAssertEqual(launch.executableIdentity.canonicalPath, launch.command)
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "DevinACPLaunchResolverTests")
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        output: String = "Run as an ACP (Agent Client Protocol) server over stdio",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let script = "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(exitStatus)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
