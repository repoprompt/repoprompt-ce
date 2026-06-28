import Foundation
@testable import RepoPrompt
import XCTest

final class GrokACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExactPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(commandName: executable.path, additionalPathHints: []),
            launchResolver: GrokACPLaunchResolver()
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))
        let session = try provider.makeSessionConfiguration(for: makeRunRequest(workspacePath: directory.path), mcpServer: .repoPrompt)

        XCTAssertEqual(launch.providerID, .grok)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["agent", "stdio"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
        XCTAssertEqual(session.workingDirectory, directory.standardizedFileURL.path)
        XCTAssertEqual(session.mcpServers, [.repoPrompt])
    }

    func testLaunchArgumentsIncludeSelectedModelAndAlwaysApprove() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                modelString: "grok-build",
                alwaysApprove: true
            ),
            launchResolver: GrokACPLaunchResolver()
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        // `--always-approve` and `-m` live on the `agent` parent and must precede `stdio`.
        XCTAssertEqual(launch.arguments, ["agent", "--always-approve", "-m", "grok-build", "stdio"])
    }

    func testDefaultModelSelectionOmitsModelFlag() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(commandName: executable.path, additionalPathHints: [], modelString: "default"),
            launchResolver: GrokACPLaunchResolver()
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.arguments, ["agent", "stdio"])
    }

    func testSessionConfigurationOmitsMCPServerWhenDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false),
            launchResolver: GrokACPLaunchResolver()
        )

        let session = try provider.makeSessionConfiguration(for: makeRunRequest(workspacePath: directory.path), mcpServer: .repoPrompt)

        XCTAssertEqual(session.mcpServers, [])
    }

    func testBareGrokUsesCapturedEnvironmentAndCachesCanonicalPathForSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let probePathRecord = directory.appendingPathComponent("probe-path")
        let executable = try makeExecutable(in: directory, marker: probePathRecord)
        let environment = [
            "PATH": directory.path,
            "SHELL": "/bin/false"
        ]
        let resolver = GrokACPLaunchResolver(environmentProvider: { _ in environment })
        let config = GrokAgentConfig(commandName: "grok", additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["agent", "stdio"])
        XCTAssertEqual(probedPath, launch.command)
    }

    func testBareGrokFallsBackToAgentHelpWhenStdioHelpFails() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = directory.appendingPathComponent("grok")
        let script = [
            "#!/bin/sh",
            "if [ \"$1 $2 $3\" = \"agent stdio --help\" ]; then",
            "  exit 2",
            "fi",
            "if [ \"$1 $2\" = \"agent --help\" ]; then",
            "  printf '%s\\n' 'Usage: grok agent stdio'",
            "  exit 0",
            "fi",
            "exit 3"
        ].joined(separator: "\n")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = GrokACPLaunchResolver(environmentProvider: { _ in ["PATH": directory.path] })
        let config = GrokAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["agent", "stdio"])
    }

    func testBareGrokWithoutSuccessfulPreflightFailsClosed() {
        let resolver = GrokACPLaunchResolver(environmentProvider: { _ in [:] })

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: GrokAgentConfig(commandName: "grok", additionalPathHints: []))) { error in
            guard case GrokACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnsafeConfiguredCommandIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("ran")
        _ = try makeExecutable(named: "not-grok", in: directory, marker: marker)
        let config = GrokAgentConfig(commandName: "not-grok", additionalPathHints: [directory.path])

        let support = try await GrokACPLaunchResolver().probeSupport(for: config)

        guard case let .unsupported(reason) = support else {
            return XCTFail("Expected unsupported result")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Grok ACP command"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedProbeDoesNotLeaveSpawnableCacheAndReplacementCanRecover() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory, exitStatus: 2)
        let environment = [
            "PATH": directory.path,
            "SHELL": "/bin/false"
        ]
        let resolver = GrokACPLaunchResolver(environmentProvider: { _ in environment })
        let config = GrokAgentConfig(commandName: "grok", additionalPathHints: [])

        guard case .unsupported = try await resolver.probeSupport(for: config) else {
            return XCTFail("Expected failed support probe")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case GrokACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: executable)
        let replacement = try makeExecutable(in: directory)
        let replacementSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(replacementSupport, .supported)
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, try canonicalExecutablePath(replacement))
    }

    func testCachedIdentityDriftFailsBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = GrokACPLaunchResolver()
        let config = GrokAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(in: directory, output: "replacement grok stdio help")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNormalizeErrorSurfacesGrokReloginOnAuthenticationRequired() {
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(commandName: "grok", additionalPathHints: [])
        )
        let authError = NSError(
            domain: "ACP",
            code: -32000,
            userInfo: [NSLocalizedDescriptionKey: "ACP request failed: Authentication required (code -32000)"]
        )

        guard case let .invalidConfiguration(detail) = provider.normalizeError(authError) as? AIProviderError else {
            return XCTFail("Expected invalidConfiguration for the -32000 authentication error")
        }
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("grok login"))
    }

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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokACPLaunchResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    @discardableResult
    private func makeExecutable(
        named name: String = "grok",
        in directory: URL,
        marker: URL? = nil,
        output: String = "Grok agent stdio ACP support",
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
