import Foundation
import RepoPromptACPProviders
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
@testable import RepoPromptProcess
import XCTest

final class OpenCodeACPLaunchResolverTests: XCTestCase {
    func testInjectedManagedOverlayReceivesResolvedWorkingDirectoryAndFlags() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let config = OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false, includeManagedConfigOverlay: true, cleanupLegacyPersistentConfig: false)
        let names = ACPToolNameResolution(isRepoPromptServerIdentifier: { _ in false }, canonicalRepoPromptToolName: { _ in nil }, isRepoPromptToolNameWithServerPrefix: { _ in false })
        let provider = OpenCodeACPAgentProvider(
            config: config,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/usr/bin/true"),
            launchResolver: OpenCodeACPLaunchResolver(),
            toolNames: names,
            prepareManagedOverlay: { config, server, workingDirectory in
                XCTAssertFalse(config.includeRepoPromptMCPServer)
                XCTAssertFalse(config.cleanupLegacyPersistentConfig)
                XCTAssertEqual(server.command, "/usr/bin/true")
                return workingDirectory
            }
        )
        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.environment["OPENCODE_CONFIG_CONTENT"], directory.standardizedFileURL.path)
    }

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

    func testOpenCodeHomeBinHintDoesNotLeakIntoNativeDefaultsOrOtherProviders() {
        let openCodeHomeBin = "~/.opencode/bin"

        XCTAssertEqual(CLILaunchProfiles.openCodeProviderSpecificPaths, [openCodeHomeBin])
        XCTAssertEqual(CLILaunchProfiles.openCode.supplementalSearchPaths.first, openCodeHomeBin)
        XCTAssertFalse(CLINativePathDefaults.defaultAdditionalPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.claudeCode.supplementalSearchPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.codex.supplementalSearchPaths.contains(openCodeHomeBin))
        XCTAssertFalse(CLILaunchProfiles.cursor.supplementalSearchPaths.contains(openCodeHomeBin))
    }

    func testWorldWritableExecutableDirectoryIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await OpenCodeACPLaunchResolver().probeSupport(
            for: OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])
        ) }

        guard case .unsupported = support else {
            return XCTFail("Expected unsafe launch path to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testGroupWritableExecutableFileIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: executable.path)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await OpenCodeACPLaunchResolver().probeSupport(
            for: OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])
        ) }

        guard case .unsupported = support else {
            return XCTFail("Expected unsafe launch path to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNonHomebrewGroupWritableAncestorIsRejectedWithoutExecution() async throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("group-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await OpenCodeACPLaunchResolver().probeSupport(
            for: OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])
        ) }

        guard case .unsupported = support else {
            return XCTFail("Expected unsafe launch path to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCachedIdentityDriftFailsBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = OpenCodeACPLaunchResolver()
        let config = OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(in: directory, output: "replacement OpenCode ACP")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent("opencode")
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
