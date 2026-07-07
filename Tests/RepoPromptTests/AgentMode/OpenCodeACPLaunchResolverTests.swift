import Foundation
@testable import RepoPrompt
import XCTest

final class OpenCodeACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExplicitPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = OpenCodeACPLaunchResolver()
        let provider = OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testBareCommandUsesCapturedEnvironmentAndCachesCanonicalPathForSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let probePathRecord = directory.appendingPathComponent("probe-path")
        let executable = try makeExecutable(in: directory, marker: probePathRecord)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = OpenCodeAgentConfig(
            commandName: "opencode",
            additionalPathHints: [],
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false
        )

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(probedPath, launch.command)
    }

    func testDefaultProfileResolvesOpenCodeFromProviderSpecificHomeBin() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let minimalPath = try makeTemporaryDirectory()
        let openCodeBin = fakeHome.appendingPathComponent(".opencode/bin", isDirectory: true)
        let nativeFallbackBin = fakeHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeFallbackBin, withIntermediateDirectories: true)
        let executable = try makeExecutable(in: openCodeBin)
        _ = try makeExecutable(in: nativeFallbackBin, output: "Native fallback OpenCode ACP support")
        let environment = [
            "HOME": fakeHome.path,
            "PATH": minimalPath.path,
            "SHELL": "/bin/false"
        ]
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in environment })
        let config = OpenCodeAgentConfig(
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false
        )

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
    }

    func testOpenCodeHomeBinHintDoesNotLeakIntoNativeDefaultsOrOtherProviders() {
        let openCodeHomeBin = "~/.opencode/bin"

        XCTAssertEqual(CLILaunchProfiles.openCodeProviderSpecificPaths, [openCodeHomeBin])
        XCTAssertEqual(CLILaunchProfiles.openCode.supplementalSearchPaths.first, openCodeHomeBin)
        XCTAssertFalse(CLINativePathDefaults.defaultAdditionalPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.claudeCode.supplementalSearchPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.codex.supplementalSearchPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.cursor.supplementalSearchPaths.contains(openCodeHomeBin))
    }

    func testRepeatedProbeRefreshesCurrentEnvironmentBeforeSpawn() async throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let firstExecutable = try makeExecutable(in: firstDirectory)
        let secondExecutable = try makeExecutable(in: secondDirectory)
        let environmentBox = OpenCodeTestEnvironmentBox(environment: [
            "PATH": firstDirectory.path,
            "SHELL": "/bin/false"
        ])
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in
            await environmentBox.current()
        })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        let firstSupport = try await resolver.probeSupport(for: config)
        let firstLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(firstSupport, .supported)
        XCTAssertEqual(firstLaunch.command, try canonicalExecutablePath(firstExecutable))

        await environmentBox.set([
            "PATH": secondDirectory.path,
            "SHELL": "/bin/false"
        ])
        let secondSupport = try await resolver.probeSupport(for: config)
        let secondLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(secondSupport, .supported)
        XCTAssertEqual(secondLaunch.command, try canonicalExecutablePath(secondExecutable))
    }

    func testBareCommandWithoutSuccessfulPreflightFailsClosed() {
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in [:] })

        XCTAssertThrowsError(
            try resolver.resolvedLaunch(
                for: OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])
            )
        ) { error in
            guard case OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancelledSupportProbePropagatesCancellationAndLeavesNoBareCommandCache() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-started")
        _ = try makeExecutable(in: directory, marker: marker, sleepSeconds: 30)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        let probe = Task { try await resolver.probeSupport(for: config) }
        let didStartProbe = await waitUntilFileExists(marker)
        XCTAssertTrue(didStartProbe)
        probe.cancel()
        do {
            _ = try await probe.value
            XCTFail("Expected support probe cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not converted into an unsupported result.
        }

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorldWritableExecutableDirectoryIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

        let support = try await OpenCodeACPLaunchResolver().probeSupport(
            for: OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])
        )

        guard case .unsupported = support else {
            return XCTFail("Expected unsafe launch path to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedProbeDoesNotLeaveSpawnableCacheAndReplacementCanRecover() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory, exitStatus: 2)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        guard case .unsupported = try await resolver.probeSupport(for: config) else {
            return XCTFail("Expected failed support probe")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: executable)
        let replacement = try makeExecutable(in: directory)
        let replacementSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(replacementSupport, .supported)
        XCTAssertEqual(
            try resolver.resolvedLaunch(for: config).command,
            try canonicalExecutablePath(replacement)
        )
    }

    func testCachedIdentityDriftFailsBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = OpenCodeACPLaunchResolver()
        let config = OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(in: directory, output: "replacement OpenCode ACP")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSessionNewTimeoutNormalizesToOpenCodeRecoveryGuidance() {
        let provider = makeProviderForNormalization()
        let timeout = ACPRequestTimeoutError(
            method: "session/new",
            timeoutSeconds: 30,
            launchDescription: "/Users/me/.opencode/bin/opencode acp",
            diagnosticHint: "The process wrote stdout, but no matching ACP response arrived for this request.",
            agentIdentity: "OpenCode 1.17.11"
        )

        let normalized = provider.normalizeError(timeout)

        guard case let AIProviderError.invalidConfiguration(detail) = normalized else {
            return XCTFail("Unexpected normalized error: \(normalized)")
        }
        XCTAssertTrue(detail.contains("OpenCode ACP did not finish session startup"))
        XCTAssertTrue(detail.contains("opencode upgrade"))
        XCTAssertTrue(detail.contains("opencode acp --help"))
        XCTAssertTrue(detail.contains("OpenCode 1.17.11"))
        XCTAssertTrue(detail.contains("session/new timed out"))
    }

    func testPromptTimeoutDoesNotUseOpenCodeStartupGuidance() {
        let provider = makeProviderForNormalization()
        let timeout = ACPRequestTimeoutError(
            method: "session/prompt",
            timeoutSeconds: 30,
            launchDescription: "opencode acp",
            diagnosticHint: nil,
            agentIdentity: "OpenCode 1.17.14"
        )

        let normalized = provider.normalizeError(timeout)

        guard case let AIProviderError.apiError(source) = normalized else {
            return XCTFail("Unexpected normalized error: \(normalized)")
        }
        XCTAssertEqual((source as? ACPRequestTimeoutError), timeout)
    }

    private func makeProviderForNormalization() -> OpenCodeACPAgentProvider {
        OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(commandName: "opencode"),
            launchResolver: OpenCodeACPLaunchResolver()
        )
    }

    private func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "OpenCodeACPLaunchResolverTests")
    }

    @discardableResult
    private func makeExecutable(
        in directory: URL,
        marker: URL? = nil,
        output: String = "OpenCode ACP support",
        exitStatus: Int32 = 0,
        sleepSeconds: Int? = nil
    ) throws -> URL {
        let executable = directory.appendingPathComponent("opencode")
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        if let sleepSeconds {
            lines.append("exec /bin/sleep \(sleepSeconds)")
        }
        lines.append("printf '%s\\n' '\(output)'")
        lines.append("exit \(exitStatus)")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitUntilFileExists(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            await Task.yield()
        } while Date() < deadline
        return false
    }
}

private actor OpenCodeTestEnvironmentBox {
    private var environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func current() -> [String: String] {
        environment
    }

    func set(_ environment: [String: String]) {
        self.environment = environment
    }
}
