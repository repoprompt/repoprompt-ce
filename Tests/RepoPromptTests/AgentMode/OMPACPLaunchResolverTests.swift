import Foundation
@testable import RepoPromptApp
import XCTest

final class OMPACPLaunchResolverTests: XCTestCase {
    func testProviderProfileMatchesInstalledOMPConvention() {
        XCTAssertEqual(CLILaunchProfiles.omp.commandName, "omp")
        XCTAssertTrue(CLILaunchProfiles.omp.supplementalSearchPaths.contains("~/.bun/bin"))
        XCTAssertTrue(CLIPathHints.omp.contains("~/.bun/bin"))
    }

    func testNonOMPCommandIsRejected() async throws {
        let resolver = OMPACPLaunchResolver(environmentProvider: { _ in [:] })
        let support = try await resolver.probeSupport(
            for: OMPAgentConfig(commandName: "not-omp", additionalPathHints: [])
        )
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe OMP ACP command"))
    }

    func testSupportProbeRequiresZeroExitStatus() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "omp", in: directory, exitStatus: 3)
        let resolver = OMPACPLaunchResolver(environmentProvider: { _ in
            ["PATH": directory.path, "SHELL": "/bin/false"]
        })

        let support = try await resolver.probeSupport(
            for: OMPAgentConfig(commandName: "omp", additionalPathHints: [])
        )

        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("`omp acp --help` exited with status 3"), "unexpected reason: \(reason)")
    }

    func testSupportProbeRequiresOMPACKPHelpMarkers() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "omp", in: directory, output: "generic help")
        let resolver = OMPACPLaunchResolver(environmentProvider: { _ in
            ["PATH": directory.path, "SHELL": "/bin/false"]
        })

        let support = try await resolver.probeSupport(
            for: OMPAgentConfig(commandName: "omp", additionalPathHints: [])
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
        let target = try makeExecutable(named: "omp-entry", in: targetDirectory)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let symlink = binDirectory.appendingPathComponent("omp")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let resolver = OMPACPLaunchResolver(environmentProvider: { _ in
            ["PATH": binDirectory.path, "SHELL": "/bin/false"]
        })
        let config = OMPAgentConfig(commandName: "omp", additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        let launch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertTrue(launch.command.hasSuffix("omp-entry"), "unexpected command: \(launch.command)")
        XCTAssertEqual(launch.executableIdentity.canonicalPath, launch.command)
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "OMPACPLaunchResolverTests")
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        output: String = "Run Oh My Pi as an ACP (Agent Client Protocol) server over stdio",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let script = "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(exitStatus)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
