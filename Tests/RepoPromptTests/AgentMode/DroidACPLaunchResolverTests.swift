import Foundation
@testable import RepoPrompt
import XCTest

final class DroidACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExplicitPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = DroidACPLaunchResolver()
        let provider = DroidACPAgentProvider(
            config: DroidAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["exec", "--output-format", "acp"])
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
        let resolver = DroidACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = DroidAgentConfig(
            commandName: "droid",
            additionalPathHints: [],
            includeRepoPromptMCPServer: false
        )

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(probedPath, launch.command)
    }

    func testDroidHomeBinHintDoesNotLeakIntoNativeDefaultsOrOtherProviders() {
        XCTAssertEqual(CLILaunchProfiles.droidProviderSpecificPaths, [])
        XCTAssertFalse(CLILaunchProfiles.claudeCode.supplementalSearchPaths.contains(where: { $0.contains("droid") }))
        XCTAssertFalse(CLILaunchProfiles.codex.supplementalSearchPaths.contains(where: { $0.contains("droid") }))
        XCTAssertFalse(CLILaunchProfiles.openCode.supplementalSearchPaths.contains(where: { $0.contains("droid") }))
        XCTAssertFalse(CLILaunchProfiles.cursor.supplementalSearchPaths.contains(where: { $0.contains("droid") }))
    }

    func testRepeatedProbeRefreshesCurrentEnvironmentBeforeSpawn() async throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let firstExecutable = try makeExecutable(in: firstDirectory)
        let secondExecutable = try makeExecutable(in: secondDirectory)
        let environmentBox = DroidTestEnvironmentBox(environment: [
            "PATH": firstDirectory.path,
            "SHELL": "/bin/false"
        ])
        let resolver = DroidACPLaunchResolver(environmentProvider: { _ in
            await environmentBox.current()
        })
        let config = DroidAgentConfig(commandName: "droid", additionalPathHints: [])

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
        let resolver = DroidACPLaunchResolver(environmentProvider: { _ in [:] })

        XCTAssertThrowsError(
            try resolver.resolvedLaunch(
                for: DroidAgentConfig(commandName: "droid", additionalPathHints: [])
            )
        ) { error in
            guard case DroidACPLaunchResolutionError.environmentDiscoveryRequired = error else {
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
        let resolver = DroidACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = DroidAgentConfig(commandName: "droid", additionalPathHints: [])

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
            guard case DroidACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorldWritableExecutableDirectoryIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

        let support = try await DroidACPLaunchResolver().probeSupport(
            for: DroidAgentConfig(commandName: executable.path, additionalPathHints: [])
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
        let resolver = DroidACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = DroidAgentConfig(commandName: "droid", additionalPathHints: [])

        guard case .unsupported = try await resolver.probeSupport(for: config) else {
            return XCTFail("Expected failed support probe")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case DroidACPLaunchResolutionError.environmentDiscoveryRequired = error else {
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
        let resolver = DroidACPLaunchResolver()
        let config = DroidAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(in: directory, output: "replacement Droid ACP")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .droid,
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidACPLaunchResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func makeExecutable(
        in directory: URL,
        marker: URL? = nil,
        output: String = "Droid ACP support",
        exitStatus: Int32 = 0,
        sleepSeconds: Int? = nil
    ) throws -> URL {
        let executable = directory.appendingPathComponent("droid")
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

private actor DroidTestEnvironmentBox {
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
