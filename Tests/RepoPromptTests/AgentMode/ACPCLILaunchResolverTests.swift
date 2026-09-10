import Foundation
@testable import RepoPromptApp
import XCTest

/// Covers the shared `<cli> acp` launch resolution both new ACP providers depend on:
/// profile pinning, basename safety, the `--help` advertisement preflight, and the
/// resolved-launch shape (canonical path, `acp` arguments, captured environment).
final class ACPCLILaunchResolverTests: XCTestCase {
    private struct Fixture {
        let spec: ACPCLILaunchSpec
        let config: any ACPCLILaunchConfiguring
        let helpOutput: String
        let hint: String
    }

    private var fixtures: [Fixture] {
        [
            Fixture(
                spec: .devin,
                config: DevinAgentConfig(additionalPathHints: []),
                helpOutput: "Run as an ACP (Agent Client Protocol) server over stdio",
                hint: "~/.local/bin"
            ),
            Fixture(
                spec: .omp,
                config: OMPAgentConfig(additionalPathHints: []),
                helpOutput: "Run Oh My Pi as an ACP server over stdio",
                hint: "~/.bun/bin"
            )
        ]
    }

    func testProviderProfilesPinCommandsAndSearchHints() {
        XCTAssertEqual(CLILaunchProfiles.devin.commandName, "devin")
        XCTAssertEqual(CLILaunchProfiles.omp.commandName, "omp")
        XCTAssertTrue(CLIPathHints.devin.contains("~/.local/bin"))
        XCTAssertTrue(CLIPathHints.omp.contains("~/.bun/bin"))
        for fixture in fixtures {
            XCTAssertEqual(fixture.spec.commandName, fixture.spec.profile.commandName)
            XCTAssertEqual(fixture.spec.launchArguments, ["acp"])
            XCTAssertEqual(fixture.spec.helpArguments, ["acp", "--help"])
            XCTAssertTrue(
                fixture.spec.profile.supplementalSearchPaths.contains(fixture.hint),
                "\(fixture.spec.displayName) must search \(fixture.hint)"
            )
        }
    }

    func testProviderKindsMapToTheirACPProviderIDs() {
        XCTAssertEqual(AgentProviderKind.devin.acpProviderID, .devin)
        XCTAssertEqual(AgentProviderKind.omp.acpProviderID, .omp)
        XCTAssertEqual(AgentProviderKind.devin.providerBindingID, .devin)
        XCTAssertEqual(AgentProviderKind.omp.providerBindingID, .omp)
    }

    func testForeignCommandBasenameIsRefused() async throws {
        for fixture in fixtures {
            let resolver = ACPCLILaunchResolver(spec: fixture.spec, launchEnvironmentProvider: { _ in
                ACPLaunchEnvironment(environment: [:])
            })
            let support = try await resolver.probeSupport(
                for: ImpostorConfig(commandName: "not-\(fixture.spec.commandName)")
            )
            guard case let .unsupported(reason) = support else {
                return XCTFail("expected unsupported for \(fixture.spec.displayName), got \(support)")
            }
            XCTAssertTrue(
                reason.contains("Refusing unsafe \(fixture.spec.displayName) ACP command"),
                "unexpected reason: \(reason)"
            )
        }
    }

    func testSupportProbeRequiresZeroExitStatus() async throws {
        for fixture in fixtures {
            let directory = try makeTestDirectory(name: "ACPCLILaunchResolverExit")
            try makeExecutable(named: fixture.spec.commandName, in: directory, output: fixture.helpOutput, exitStatus: 3)
            let resolver = makeResolver(fixture.spec, path: directory)

            let support = try await resolver.probeSupport(for: fixture.config)

            guard case let .unsupported(reason) = support else {
                return XCTFail("expected unsupported for \(fixture.spec.displayName), got \(support)")
            }
            XCTAssertTrue(
                reason.contains("`\(fixture.spec.commandName) acp --help` exited with status 3"),
                "unexpected reason: \(reason)"
            )
        }
    }

    func testSupportProbeRequiresEveryACPHelpAdvertisement() async throws {
        for fixture in fixtures {
            let directory = try makeTestDirectory(name: "ACPCLILaunchResolverHelp")
            try makeExecutable(named: fixture.spec.commandName, in: directory, output: "generic help")
            let resolver = makeResolver(fixture.spec, path: directory)

            let support = try await resolver.probeSupport(for: fixture.config)

            guard case let .unsupported(reason) = support else {
                return XCTFail("expected unsupported for \(fixture.spec.displayName), got \(support)")
            }
            XCTAssertTrue(reason.contains("did not advertise ACP support"), "unexpected reason: \(reason)")
        }
    }

    func testProbeResolvesSymlinkedExecutableAndCarriesLaunchShape() async throws {
        for fixture in fixtures {
            let directory = try makeTestDirectory(name: "ACPCLILaunchResolverSymlink")
            let packageDirectory = directory.appendingPathComponent("package", isDirectory: true)
            try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            let target = try makeExecutable(
                named: "\(fixture.spec.commandName)-entry",
                in: packageDirectory,
                output: fixture.helpOutput
            )
            let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: binDirectory.appendingPathComponent(fixture.spec.commandName),
                withDestinationURL: target
            )
            let resolver = makeResolver(fixture.spec, path: binDirectory)

            let support = try await resolver.probeSupport(for: fixture.config)
            XCTAssertEqual(support, .supported)

            let launch = try resolver.resolvedLaunch(for: fixture.config)
            XCTAssertEqual(launch.arguments, ["acp"])
            XCTAssertEqual(launch.command, launch.executableIdentity.canonicalPath)
            XCTAssertTrue(
                launch.command.hasSuffix("\(fixture.spec.commandName)-entry"),
                "unexpected command: \(launch.command)"
            )
            // Devin's isolated MCP-configuration overlay derives the native config root
            // from this captured environment, so it must survive resolution.
            XCTAssertEqual(launch.environment["PATH"], binDirectory.path)
        }
    }

    func testBareCommandWithoutProbeRequiresEnvironmentDiscovery() {
        for fixture in fixtures {
            let resolver = ACPCLILaunchResolver(spec: fixture.spec, launchEnvironmentProvider: { _ in
                ACPLaunchEnvironment(environment: [:])
            })
            XCTAssertThrowsError(try resolver.resolvedLaunch(for: fixture.config)) { error in
                XCTAssertEqual(
                    error as? ACPCLILaunchResolutionError,
                    .environmentDiscoveryRequired(
                        agent: fixture.spec.displayName,
                        command: fixture.spec.commandName
                    )
                )
            }
        }
    }

    func testExecutableInsideApplicationBundleIsRefused() async throws {
        let spec = ACPCLILaunchSpec.devin
        let directory = try makeTestDirectory(name: "ACPCLILaunchResolverAppBundle")
        let bundleBin = directory
            .appendingPathComponent("Impostor.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)
        let executable = try makeExecutable(named: spec.commandName, in: bundleBin)
        let resolver = makeResolver(spec, path: bundleBin)

        // The bundled executable is named as an explicit absolute path: PATH discovery
        // would otherwise fall through to a real CLI installed on the host machine and
        // report `.supported` for a different binary entirely.
        let support = try await resolver.probeSupport(
            for: DevinAgentConfig(commandName: executable.path, additionalPathHints: [])
        )

        guard case let .unsupported(reason) = support else {
            return XCTFail("expected unsupported, got \(support)")
        }
        XCTAssertTrue(
            reason.contains("Refusing Devin ACP executable inside an application bundle"),
            "unexpected reason: \(reason)"
        )
    }

    // MARK: - Helpers

    private struct ImpostorConfig: ACPCLILaunchConfiguring {
        let commandName: String
        let additionalPathHints: [String] = []
        let enableDebugLogging = false
    }

    private func makeResolver(_ spec: ACPCLILaunchSpec, path: URL) -> ACPCLILaunchResolver {
        ACPCLILaunchResolver(spec: spec, launchEnvironmentProvider: { _ in
            ACPLaunchEnvironment(environment: ["PATH": path.path, "SHELL": "/bin/false"])
        })
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        output: String = "Run as an ACP server over stdio",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let script = "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(exitStatus)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
