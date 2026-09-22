import Foundation
@testable import RepoPromptApp
import XCTest

final class GrokBuildACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExactPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = GrokBuildACPLaunchResolver()
        let provider = GrokBuildACPAgentProvider(
            config: GrokBuildAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["agent", "--no-leader", "stdio"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testProviderPathHintsIncludeDotGrokBin() {
        XCTAssertTrue(CLIPathHints.grokBuild.contains("~/.grok/bin"))
        XCTAssertEqual(CLILaunchProfiles.grokBuild.commandName, "grok")
        XCTAssertTrue(CLILaunchProfiles.grokBuild.supplementalSearchPaths.contains("~/.grok/bin"))
    }

    func testNonGrokBareCommandIsRejected() async throws {
        let resolver = GrokBuildACPLaunchResolver(environmentProvider: { _ in [:] })
        let config = GrokBuildAgentConfig(commandName: "not-grok", additionalPathHints: [])
        let support = try await resolver.probeSupport(for: config)
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Grok Build ACP command"))
    }

    func testAbsolutePathWithWrongEntryBasenameIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grokd", in: directory)
        let resolver = GrokBuildACPLaunchResolver(environmentProvider: { _ in [:] })
        let support = try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [])
        )
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Grok Build ACP command"))
    }

    func testSupportProbeRequiresZeroExitStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory, exitStatus: 3)
        let resolver = GrokBuildACPLaunchResolver(environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] })
        let support = try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        )
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("exited with status 3"), "unexpected reason: \(reason)")
        _ = executable
    }

    func testSupportProbeRequiresStdioMarker() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "grok", in: directory, output: "no agent surface here")
        let resolver = GrokBuildACPLaunchResolver(environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] })
        let support = try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        )
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("did not advertise"), "unexpected reason: \(reason)")
    }

    func testOfficialInstallerSymlinkShapeIsAccepted() async throws {
        // `~/.grok/bin/grok` symlinks into `~/.grok/downloads/…`; the canonical target has a
        // different basename and must still validate.
        let directory = try makeTemporaryDirectory()
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        _ = try makeExecutable(named: "grok-real", in: downloads)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let symlink = binDirectory.appendingPathComponent("grok")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: downloads.appendingPathComponent("grok-real")
        )

        let resolver = GrokBuildACPLaunchResolver(environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": "/bin/false"] })
        let support = try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        )
        XCTAssertEqual(support, .supported)
        let launch = try resolver.resolvedLaunch(for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: []))
        XCTAssertTrue(launch.command.hasSuffix("grok-real"), "unexpected canonical command: \(launch.command)")
    }

    func testChangedExecutableIdentityFailsLaunchResolution() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = GrokBuildACPLaunchResolver()
        let config = GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [])
        _ = try resolver.resolvedLaunch(for: config)

        // Replace the executable so the cached identity no longer validates.
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(named: "grok", in: directory, output: "grok agent changed")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    // MARK: - Helpers

    private func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "GrokBuildACPLaunchResolverTests")
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "grok agent stdio support",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        lines.append("exit \(exitStatus)")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
