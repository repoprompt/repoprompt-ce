import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptFoundation
@testable import RepoPromptProcess
import XCTest

final class OpenCodeACPLaunchResolverOwnerTests: XCTestCase {
    func testProviderSkipsOverlayOperationWhenDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let config = OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false, includeManagedConfigOverlay: false)
        let names = ACPToolNameResolution(isRepoPromptServerIdentifier: { _ in false }, canonicalRepoPromptToolName: { _ in nil }, isRepoPromptToolNameWithServerPrefix: { _ in false })
        let provider = OpenCodeACPAgentProvider(
            config: config,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/usr/bin/true"),
            launchResolver: makeTestResolver(environmentProvider: { _ in [:] }),
            toolNames: names,
            prepareManagedOverlay: { _, _, _ in
                XCTFail("Disabled overlay must not invoke app composition")
                throw CancellationError()
            }
        )
        let request = ACPRunRequest(agentKind: .openCode, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let launch = try provider.makeLaunchConfiguration(for: request)
        XCTAssertNil(launch.environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
    }

    func testInjectedFailureRecorderReceivesResolutionSourceAndCandidateCount() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (ShellEnvironmentSource?, Int)?
            func record(_ source: ShellEnvironmentSource?, _ count: Int) {
                lock.withLock { value = (source, count) }
            }

            func snapshot() -> (ShellEnvironmentSource?, Int)? {
                lock.withLock { value }
            }
        }
        let directory = try makeTemporaryDirectory()
        let recorder = Recorder()
        let resolver = OpenCodeACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: ["PATH": directory.path], shellEnvironmentSource: .enrichedFallback) },
            probeRunner: { _, _ in XCTFail("Unresolved command must not probe")
                throw CancellationError()
            },
            recordFailure: { recorder.record($0, $1) }
        )
        let support = try await resolver.probeSupport(for: OpenCodeAgentConfig(commandName: "missing-\(UUID().uuidString)", additionalPathHints: []))
        guard case .unsupported = support else { return XCTFail("Expected unsupported result") }
        let recorded = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(recorded.0, .enrichedFallback)
        XCTAssertGreaterThan(recorded.1, 0)
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
        let resolver = makeTestResolver(environmentProvider: { _ in environment })
        let config = OpenCodeAgentConfig(
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false
        )

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
    }

    func testUnsupportedBareCommandReportsCheckedCandidatesAndReasons() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let pathDirectory = try makeTemporaryDirectory()
        let hintDirectory = try makeTemporaryDirectory()
        let commandName = "opencode-fixture-\(UUID().uuidString)"
        let nonExecutable = hintDirectory.appendingPathComponent(commandName)
        try "not executable\n".write(to: nonExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)
        let environment = [
            "HOME": fakeHome.path,
            "PATH": pathDirectory.path,
            "SHELL": "/bin/false"
        ]
        let resolver = makeTestResolver(launchEnvironmentProvider: { _ in
            ACPLaunchEnvironment(environment: environment, shellEnvironmentSource: .enrichedFallback)
        })
        let config = OpenCodeAgentConfig(
            commandName: commandName,
            additionalPathHints: [hintDirectory.path],
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false
        )

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        guard case let .unsupported(reason) = support else {
            return XCTFail("Expected unsupported result with diagnostic reason")
        }
        XCTAssertTrue(reason.contains("Tried:"), reason)
        XCTAssertTrue(reason.contains(hintDirectory.appendingPathComponent(commandName).path), reason)
        XCTAssertTrue(reason.contains("not executable"), reason)
        XCTAssertTrue(reason.contains(pathDirectory.appendingPathComponent(commandName).path), reason)
        XCTAssertTrue(reason.contains("missing"), reason)
        XCTAssertTrue(reason.contains("fallback PATH"), reason)
        XCTAssertTrue(reason.contains("PATH may not match Terminal"), reason)
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
        let resolver = makeTestResolver(environmentProvider: { _ in
            await environmentBox.current()
        })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        let firstSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        let firstLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(firstSupport, .supported)
        XCTAssertEqual(firstLaunch.command, try canonicalExecutablePath(firstExecutable))

        await environmentBox.set([
            "PATH": secondDirectory.path,
            "SHELL": "/bin/false"
        ])
        let secondSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        let secondLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(secondSupport, .supported)
        XCTAssertEqual(secondLaunch.command, try canonicalExecutablePath(secondExecutable))
    }

    func testBareCommandWithoutSuccessfulPreflightFailsClosed() {
        let resolver = makeTestResolver(environmentProvider: { _ in [:] })

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

    private func makeTestResolver(environmentProvider: @escaping @Sendable (Bool) async -> [String: String]) -> OpenCodeACPLaunchResolver {
        makeTestResolver(launchEnvironmentProvider: { await ACPLaunchEnvironment(environment: environmentProvider($0)) })
    }

    private func makeTestResolver(launchEnvironmentProvider: @escaping OpenCodeACPLaunchResolver.EnvironmentProvider) -> OpenCodeACPLaunchResolver {
        OpenCodeACPLaunchResolver(launchEnvironmentProvider: launchEnvironmentProvider, probeRunner: { launch, config in
            let processConfig = CLIProcessConfiguration(command: launch.command, additionalPaths: [], enableDebugLogging: config.enableDebugLogging, shellLookupMode: .fallbackOnly)
            return try await CLIProcessRunner(config: processConfig).run(args: ["acp", "--help"], stdin: nil, outputMode: .none, timeout: 10, cancelChildOnTaskCancellation: true)
        }, recordFailure: { _, _ in })
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCodeACPResolverOwnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeExecutable(in directory: URL, output: String = "OpenCode ACP support") throws -> URL {
        let executable = directory.appendingPathComponent("opencode")
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
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
