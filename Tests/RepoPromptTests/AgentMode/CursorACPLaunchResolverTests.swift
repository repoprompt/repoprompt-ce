import Darwin
import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptFoundation
@testable import RepoPromptProcess
import RepoPromptSettingsCore
import XCTest

final class CursorACPLaunchResolverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    #if DEBUG
        func testProductionResolversShareProbeOwnershipButInjectedResolversDoNot() {
            let first = CursorACPLaunchResolver()
            let second = CursorACPLaunchResolver()
            let isolated = makeResolver(path: "/bin")
            XCTAssertTrue(first.sharesProbeOwnershipForTesting(with: second))
            XCTAssertFalse(first.sharesProbeOwnershipForTesting(with: isolated))
        }
    #endif

    func testProductionDefaultFallsBackToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("cursor-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let cursorExecutable = try makeExecutable(named: "cursor-agent", in: packageDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: cursorExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        guard support == .supported else {
            return XCTFail("Expected supported Cursor entrypoint: \(support)")
        }
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(launch.command, try canonicalExecutablePath(cursorExecutable))
    }

    func testProductionDefaultRejectsUnverifiedGenericAgentBeforeProbe() async throws {
        let directory = try makeTemporaryDirectory()
        let probeMarker = directory.appendingPathComponent("generic-agent-probed")
        _ = try makeExecutable(
            named: "agent",
            in: directory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        let resolver = makeResolver(path: directory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        guard case .unsupported = support else {
            return XCTFail("Expected an unverified generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultRejectsCursorAgentSymlinkToGenericAgentBeforeProbe() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("unrelated-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let probeMarker = rootDirectory.appendingPathComponent("generic-agent-probed")
        let genericAgent = try makeExecutable(
            named: "agent",
            in: packageDirectory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: genericAgent
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        guard case .unsupported = support else {
            return XCTFail("Expected cursor-agent resolving to a generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultFallsThroughStaleCursorAgentToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let legacyDirectory = rootDirectory.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = rootDirectory.appendingPathComponent("current", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let legacyProbeMarker = rootDirectory.appendingPathComponent("legacy-probed")
        let legacyExecutable = try makeExecutable(
            named: "cursor-agent",
            in: legacyDirectory,
            marker: legacyProbeMarker,
            output: "Usage: cursor-agent [OPTIONS]"
        )
        let currentExecutable = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: legacyExecutable
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: currentExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [])

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        guard support == .supported else {
            return XCTFail("Expected supported Cursor entrypoint: \(support)")
        }
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyProbeMarker.path))
        XCTAssertEqual(launch.command, try canonicalExecutablePath(currentExecutable))
    }

    private func makeResolver(path: String) -> CursorACPLaunchResolver {
        CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "CursorACPLaunchResolverTests")
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "Cursor Agent ACP support"
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

final class ProviderEnvironmentFilteringTests: XCTestCase {
    func testDefaultPolicyPreservesAuthenticationAndToolchainValues() {
        let environment = ["OPENAI_API_KEY": "fixture", "CUSTOM_BACKEND_AUTH": "fixture", "SSH_AUTH_SOCK": "/fixture/socket", "NODE_PATH": "/fixture/runtime"]
        XCTAssertEqual(ProviderEnvironmentFiltering.applying(removedNames: [], to: environment), environment)
    }

    func testEachProviderUsesItsDeclaredPassThroughWithoutBackendGuessing() async {
        for provider in AgentProviderKind.allCases {
            let ambient = ["RPCE_TEST_TOKEN": "fixture", "RPCE_TEST_SOCKET": "/fixture/socket", "PATH": "/usr/bin"]
            let filtered = await ProviderEnvironmentFiltering.filter(
                ambient,
                for: provider,
                removedNamesProvider: { requestedProvider in
                    XCTAssertEqual(requestedProvider, provider.rawValue)
                    // Synthetic per-provider exception: no model/backend introspection.
                    return Set(["RPCE_TEST_TOKEN", "RPCE_TEST_SOCKET"]).subtracting(["RPCE_TEST_TOKEN"])
                }
            )
            XCTAssertEqual(filtered["RPCE_TEST_TOKEN"], "fixture")
            XCTAssertNil(filtered["RPCE_TEST_SOCKET"])
            XCTAssertEqual(filtered["PATH"], "/usr/bin")
        }
    }

    func testACPProvenanceDoesNotExemptCopiedAmbientSnapshot() async {
        let providers: [(ACPProviderID, AgentProviderKind)] = [(.openCode, .openCode), (.cursor, .cursor), (.grokBuild, .grokBuild), (.antigravity, .antigravity), (.devin, .devin)]
        for (id, provider) in providers {
            let configuration = ACPLaunchConfiguration(
                providerID: id, command: "/fixture/provider", arguments: [],
                environment: ["COPIED_TOKEN": "ambient", "APP_TOKEN": "explicit"],
                workingDirectory: nil, additionalPathHints: [], enableDebugLogging: false,
                explicitEnvironmentKeys: ["APP_TOKEN"]
            )
            let filtered = await ProviderEnvironmentFiltering.filterACP(
                ["COPIED_TOKEN": "ambient", "APP_TOKEN": "ambient"],
                launchConfiguration: configuration, for: provider,
                removedNamesProvider: { _ in ["COPIED_TOKEN", "APP_TOKEN"] }
            )
            XCTAssertNil(filtered["COPIED_TOKEN"])
            XCTAssertEqual(filtered["APP_TOKEN"], "explicit")
        }
        let undeclared = ACPLaunchConfiguration(
            providerID: .devin, command: "/fixture/provider", arguments: [], environment: ["COPIED_TOKEN": "ambient"],
            workingDirectory: nil, additionalPathHints: [], enableDebugLogging: false
        )
        XCTAssertTrue(undeclared.explicitEnvironmentKeys.isEmpty)
        let filtered = await ProviderEnvironmentFiltering.filterACP(
            undeclared.environment, launchConfiguration: undeclared, for: .devin,
            removedNamesProvider: { _ in ["COPIED_TOKEN"] }
        )
        XCTAssertNil(filtered["COPIED_TOKEN"])
    }

    func testExplicitOverridesSurviveButDynamicLoaderSanitizationStillWins() {
        let filtered = ProviderEnvironmentFiltering.applying(
            removedNames: ["TOKEN", "SSH_AUTH_SOCK"],
            to: ["TOKEN": "ambient", "SSH_AUTH_SOCK": "/fixture/socket", "token": "case-sensitive"],
            explicitOverrides: ["TOKEN": "explicit", "DYLD_INSERT_LIBRARIES": "/fixture/library"]
        )
        XCTAssertEqual(filtered["TOKEN"], "explicit")
        XCTAssertEqual(filtered["token"], "case-sensitive")
        XCTAssertNil(filtered["SSH_AUTH_SOCK"])
        XCTAssertNil(filtered["DYLD_INSERT_LIBRARIES"])
    }

    func testFinalRunnerFilterCannotBeUndoneByAmbientReconstructionOrCopiedSnapshot() async throws {
        let filter = ProviderEnvironmentFiltering.cliFilter(
            for: .openCode,
            explicitOverrides: ["RPCE_TEST_EXPLICIT": "configured"],
            removedNamesProvider: { _ in ["RPCE_TEST_AMBIENT", "RPCE_TEST_EXPLICIT", "RPCE_TEST_REMOVED"] }
        )
        let config = CLIProcessConfiguration(
            command: "/bin/sh",
            processPurpose: .tool,
            environment: ["RPCE_TEST_AMBIENT": "copied-snapshot", "RPCE_TEST_EXPLICIT": "copied-snapshot"],
            environmentFilter: filter,
            additionalPaths: [],
            shellLookupMode: .disabled
        )
        let result = try await CLIProcessRunner(config: config).run(
            args: ["-c", "printf '%s|%s|%s' \"${RPCE_TEST_AMBIENT-unset}\" \"${RPCE_TEST_EXPLICIT-unset}\" \"${RPCE_TEST_REMOVED-unset}\""],
            stdin: nil,
            outputMode: .none,
            timeout: 10,
            additionalEnvironment: ["RPCE_TEST_EXPLICIT": "runtime", "RPCE_TEST_REMOVED": "runtime"],
            additionalRemovedKeys: ["RPCE_TEST_REMOVED"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "unset|runtime|unset")
    }

    func testUnconfiguredToolRunnerRemainsUnfiltered() async throws {
        let config = CLIProcessConfiguration(
            command: "/bin/sh",
            processPurpose: .tool,
            environment: ["RPCE_TEST_AMBIENT": "unchanged"],
            additionalPaths: [],
            shellLookupMode: .disabled
        )
        XCTAssertNil(config.environmentFilter)
        let result = try await CLIProcessRunner(config: config).run(
            args: ["-c", "printf '%s' \"$RPCE_TEST_AMBIENT\""], stdin: nil, outputMode: .none, timeout: 10
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "unchanged")
    }
}
