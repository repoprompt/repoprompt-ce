import Foundation
import RepoPromptACPProviders
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptProcess
import XCTest

final class GrokBuildACPLaunchResolverOwnerTests: XCTestCase {
    func testNonGrokBareCommandIsRejected() async throws {
        let resolver = makeResolver(environmentProvider: { _ in [:] })
        let config = GrokBuildAgentConfig(commandName: "not-grok", additionalPathHints: [])
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Grok Build ACP command"))
    }

    func testAbsolutePathWithWrongEntryBasenameIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grokd", in: directory)
        let resolver = makeResolver(environmentProvider: { _ in [:] })
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [])
        ) }
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Grok Build ACP command"))
    }

    func testSupportProbeRequiresZeroExitStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory, exitStatus: 3)
        let resolver = makeResolver(environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] })
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        ) }
        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(reason.contains("exited with status 3"), "unexpected reason: \(reason)")
        _ = executable
    }

    func testSupportProbeRequiresStdioMarker() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "grok", in: directory, output: "no agent surface here")
        let resolver = makeResolver(environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] })
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        ) }
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

        let resolver = makeResolver(environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": "/bin/false"] })
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(
            for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: [])
        ) }
        XCTAssertEqual(support, .supported)
        let launch = try resolver.resolvedLaunch(for: GrokBuildAgentConfig(commandName: "grok", additionalPathHints: []))
        XCTAssertTrue(launch.command.hasSuffix("grok-real"), "unexpected canonical command: \(launch.command)")
    }

    func testChangedExecutableIdentityFailsLaunchResolution() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = makeResolver()
        let config = GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [])
        _ = try resolver.resolvedLaunch(for: config)

        // Replace the executable so the cached identity no longer validates.
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(named: "grok", in: directory, output: "grok agent changed")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testPhysicalProbeUsesSuppliedFilterAndParentHelpArgumentsWithStderrMarker() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = directory.appendingPathComponent("grok")
        let marker = directory.appendingPathComponent("arguments")
        let script = """
        #!/bin/sh
        printf '%s' "$*" > '\(marker.path)'
        if [ "$#" -eq 2 ] && [ "$1" = agent ] && [ "$2" = --help ] && [ "$RPCE_GROK_PROBE" = filtered ]; then
            printf 'STDIO\\n' >&2
            exit 0
        fi
        exit 3
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = GrokBuildACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: [:]) },
            supplementalPathProvider: { $0 },
            environmentFilter: { environment, _ in
                var filtered = environment
                filtered["RPCE_GROK_PROBE"] = "filtered"
                return filtered
            },
            failureRecorder: { _, _ in XCTFail("Valid executable must not report a path failure") }
        )
        let config = GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [])
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        XCTAssertEqual(support, .supported)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "agent --help")
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).arguments, ["agent", "--no-leader", "stdio"])
    }

    func testSuppliedConfigurationValuesRemainUnchanged() {
        let config = GrokBuildAgentConfig(
            commandName: " grok ",
            additionalPathHints: ["~/custom", "~/custom", "relative"],
            enableDebugLogging: true,
            modelString: " custom-model ",
            includeRepoPromptMCPServer: false,
            alwaysApproveTools: true,
            discoveryMode: true,
            apiKey: " fixture-credential ",
            backgroundFeatureEnvironment: ["CUSTOM_FEATURE": "unchanged"]
        )
        XCTAssertEqual(config.commandName, " grok ")
        XCTAssertEqual(config.additionalPathHints, ["~/custom", "~/custom", "relative"])
        XCTAssertTrue(config.enableDebugLogging)
        XCTAssertEqual(config.modelString, " custom-model ")
        XCTAssertFalse(config.includeRepoPromptMCPServer)
        XCTAssertTrue(config.alwaysApproveTools)
        XCTAssertTrue(config.discoveryMode)
        // Configuration carries the supplied credential; only the launch adapter interprets it.
        XCTAssertEqual(config.apiKey, " fixture-credential ")
        XCTAssertEqual(config.backgroundFeatureEnvironment, ["CUSTOM_FEATURE": "unchanged"])
    }

    func testSuppliedPathPolicyAndEnvironmentSourceReachFailureDiagnostics() async throws {
        let directory = try makeTemporaryDirectory()
        let hintDirectory = try makeTemporaryDirectory()
        let recorder = FailureRecorder()
        let resolver = GrokBuildACPLaunchResolver(
            launchEnvironmentProvider: { _ in
                ACPLaunchEnvironment(environment: ["PATH": directory.path, "SHELL": "/bin/false"], shellEnvironmentSource: .enrichedFallback)
            },
            supplementalPathProvider: { configuredPaths in
                XCTAssertEqual(configuredPaths, ["supplied-hint"])
                return [hintDirectory.path]
            },
            environmentFilter: { environment, _ in environment },
            failureRecorder: { recorder.record($0, $1) }
        )
        let support = try await resolver.probeSupport(for: GrokBuildAgentConfig(additionalPathHints: ["supplied-hint"]))
        guard case let .unsupported(reason) = support else { return XCTFail("Expected missing executable failure") }
        XCTAssertTrue(reason.contains(directory.appendingPathComponent("grok").path), reason)
        XCTAssertTrue(reason.contains(hintDirectory.appendingPathComponent("grok").path), reason)
        XCTAssertTrue(reason.contains("fallback PATH"), reason)
        let recorded = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(recorded.0, .enrichedFallback)
        XCTAssertEqual(recorded.1, 2)
    }

    func testCanonicalApplicationBundleExecutableIsRefused() throws {
        let directory = try makeTemporaryDirectory()
        let bundle = directory.appendingPathComponent("Unsafe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let executable = try makeExecutable(named: "grok", in: bundle)
        let entry = directory.appendingPathComponent("grok")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: executable)
        let canonicalPath = try XCTUnwrap(FileSystemService.realpathString(executable.path))
        XCTAssertThrowsError(try makeResolver().resolvedLaunch(for: GrokBuildAgentConfig(commandName: entry.path, additionalPathHints: []))) { error in
            guard case let GrokBuildACPLaunchResolutionError.unsafeApplicationPath(path) = error else {
                return XCTFail("Expected canonical application path refusal, got \(error)")
            }
            XCTAssertEqual(path, canonicalPath)
        }
    }

    // MARK: - Helpers

    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (ShellEnvironmentSource?, Int)?

        func record(_ source: ShellEnvironmentSource?, _ count: Int) {
            lock.withLock { value = (source, count) }
        }

        func snapshot() -> (ShellEnvironmentSource?, Int)? {
            lock.withLock { value }
        }
    }

    private func makeResolver(
        environmentProvider: @escaping @Sendable (Bool) async -> [String: String] = { _ in [:] }
    ) -> GrokBuildACPLaunchResolver {
        GrokBuildACPLaunchResolver(
            launchEnvironmentProvider: { await ACPLaunchEnvironment(environment: environmentProvider($0)) },
            supplementalPathProvider: { CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0) },
            environmentFilter: { environment, _ in environment },
            failureRecorder: { _, _ in }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GrokBuildACPLaunchResolverOwnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        output: String = "grok agent stdio support",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let lines = ["#!/bin/sh", "printf '%s\\n' '\(output)'", "exit \(exitStatus)"]
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
