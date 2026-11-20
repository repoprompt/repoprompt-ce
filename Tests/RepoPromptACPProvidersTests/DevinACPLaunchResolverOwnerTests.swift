import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptFoundation
import RepoPromptProcess
import XCTest

final class DevinACPLaunchResolverOwnerTests: XCTestCase {
    func testResolvedLaunchAlwaysHoldsTheBareACPSubcommand() throws {
        // `makeLaunchConfiguration` prepends the permission flag to the resolver's argv, so
        // the resolver must never emit a wrapper/shim invocation ahead of `acp`.
        let directory = try makeTestDirectory(name: "DevinResolvedLaunchInvariant")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try makeResolver().resolvedLaunch(
            for: DevinAgentConfig(commandName: executable.path, additionalPathHints: CLILaunchProfiles.devinProviderSpecificPaths)
        )
        XCTAssertEqual(resolved.arguments, ["acp"])
        XCTAssertEqual((resolved.command as NSString).lastPathComponent, "devin")
    }

    func testConcurrentProbeDoesNotInvalidateAResolvedBareCommandLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinConcurrentBareCommandLaunch")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\necho 'Run as an ACP server over stdio'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let gate = DevinProbeEnvironmentGate(environment: ["PATH": directory.path])
        let resolver = makeResolver(launchEnvironmentProvider: { _ in
            await gate.nextEnvironment()
        })
        let config = DevinAgentConfig(commandName: "devin", additionalPathHints: CLILaunchProfiles.devinProviderSpecificPaths, includeRepoPromptMCPServer: false)

        let initialSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        XCTAssertEqual(initialSupport, .supported)
        let secondProbe = Task { try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) } }
        await gate.waitForSecondCall()
        let resolved = Result { try resolver.resolvedLaunch(for: config) }
        await gate.releaseSecondCall()
        let secondSupport = try await secondProbe.value
        XCTAssertEqual(secondSupport, .supported)

        XCTAssertEqual(
            try resolved.get().command,
            try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        )
    }

    func testFilteredPhysicalProbeRequiresBothMarkersAndPreservesLaunchAfterFailure() async throws {
        let directory = try makeTestDirectory(name: "DevinPhysicalProbe")
        let executable = try makeExecutable(in: directory, script: """
        #!/bin/sh
        [ "$#" -eq 2 ] && [ "$1" = acp ] && [ "$2" = --help ] || exit 23
        case "$RPCE_DEVIN_PROBE_MODE" in
            complete) printf 'Run as an ACP\\n'; printf 'server over stdio\\n' >&2 ;;
            first) printf 'Run as an ACP\\n' ;;
            second) printf 'server over stdio\\n' >&2 ;;
            nonzero) printf 'Run as an ACP server over stdio\\n'; exit 7 ;;
            *) exit 23 ;;
        esac
        """)
        let mode = ProbeMode()
        let resolver = DevinACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: ["PATH": directory.path, "SHELL": "/bin/false"]) },
            supplementalPathProvider: { $0 },
            environmentFilter: { environment, _ in
                var filtered = environment
                filtered["RPCE_DEVIN_PROBE_MODE"] = await mode.current()
                return filtered
            },
            failureRecorder: { _, _ in XCTFail("Valid executable must not report path failure") }
        )
        let config = DevinAgentConfig(commandName: "devin", additionalPathHints: [])
        let canonicalPath = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        let cases: [(String, String?)] = [
            ("complete", nil),
            ("first", "did not advertise ACP support"),
            ("second", "did not advertise ACP support"),
            ("nonzero", "exited with status 7"),
            ("complete", nil)
        ]
        for (requestedMode, failure) in cases {
            await mode.set(requestedMode)
            let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
            if let failure {
                guard case let .unsupported(reason) = support else { return XCTFail("Expected unsupported: \(requestedMode)") }
                XCTAssertTrue(reason.contains(failure), reason)
            } else {
                XCTAssertEqual(support, .supported)
            }
            let resolved = try resolver.resolvedLaunch(for: config)
            XCTAssertEqual(resolved.command, canonicalPath, requestedMode)
            XCTAssertEqual(resolved.arguments, ["acp"], requestedMode)
        }
    }

    func testCancelledSupportProbeKeepsTheResolvedBareCommandLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinCancelledProbe")
        let executable = try makeExecutable(in: directory)
        let gate = DevinProbeEnvironmentGate(environment: ["PATH": directory.path])
        let resolver = makeResolver(launchEnvironmentProvider: { _ in await gate.nextEnvironment() })
        let config = DevinAgentConfig(commandName: "devin", additionalPathHints: [])
        let initialSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        XCTAssertEqual(initialSupport, .supported)

        let secondProbe = Task { try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) } }
        await gate.waitForSecondCall()
        secondProbe.cancel()
        await gate.releaseSecondCall()
        do {
            _ = try await secondProbe.value
            XCTFail("Cancellation must throw rather than publish an unsupported result")
        } catch is CancellationError {
            // The last successful executable remains available after this cancelled attempt.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        let resolved = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(resolved.command, try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath)
        XCTAssertEqual(resolved.arguments, ["acp"])
    }

    func testConfiguredCommandAndCanonicalApplicationRefusalsKeepSpecificErrors() throws {
        let directory = try makeTestDirectory(name: "DevinCommandRefusals")
        let wrongPath = directory.appendingPathComponent("other").path
        let cases: [(String, DevinACPLaunchResolutionError)] = [
            ("", .missingConfiguredCommand),
            ("other", .unsafeConfiguredCommand("other")),
            (wrongPath, .unsafeConfiguredCommand(wrongPath)),
            ("relative/devin", .exactPathNotFound("relative/devin")),
            ("devin", .environmentDiscoveryRequired("devin"))
        ]
        let resolver = makeResolver()
        for (command, expectedError) in cases {
            XCTAssertThrowsError(try resolver.resolvedLaunch(for: DevinAgentConfig(commandName: command, additionalPathHints: []))) { error in
                XCTAssertEqual(error as? DevinACPLaunchResolutionError, expectedError)
            }
        }
        let bundle = directory.appendingPathComponent("Unsafe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let executable = try makeExecutable(in: bundle)
        let entry = directory.appendingPathComponent("devin")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: executable)
        let canonicalPath = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: DevinAgentConfig(commandName: entry.path, additionalPathHints: []))) { error in
            XCTAssertEqual(error as? DevinACPLaunchResolutionError, .unsafeApplicationPath(canonicalPath))
        }
    }

    func testSuppliedPathsAndEnvironmentSourceReachFailureDiagnostics() async throws {
        let directory = try makeTestDirectory(name: "DevinDiagnosticPath")
        let hintDirectory = try makeTestDirectory(name: "DevinDiagnosticHint")
        let recorder = FailureRecorder()
        let resolver = DevinACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: ["PATH": directory.path, "SHELL": "/bin/false"], shellEnvironmentSource: .enrichedFallback) },
            supplementalPathProvider: { paths in
                XCTAssertEqual(paths, ["configured-hint"])
                return [hintDirectory.path]
            },
            environmentFilter: { environment, _ in environment },
            failureRecorder: { recorder.record($0, $1) }
        )
        let support = try await resolver.probeSupport(for: DevinAgentConfig(additionalPathHints: ["configured-hint"]))
        guard case let .unsupported(reason) = support else { return XCTFail("Expected missing command failure") }
        XCTAssertTrue(reason.contains(directory.appendingPathComponent("devin").path), reason)
        XCTAssertTrue(reason.contains(hintDirectory.appendingPathComponent("devin").path), reason)
        XCTAssertTrue(reason.contains("fallback PATH"), reason)
        let recorded = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(recorded.0, .enrichedFallback)
        XCTAssertEqual(recorded.1, 2)
    }

    private actor ProbeMode {
        private var value = "complete"
        func current() -> String {
            value
        }

        func set(_ value: String) {
            self.value = value
        }
    }

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

    private func makeExecutable(in directory: URL, script: String = "#!/bin/sh\necho 'Run as an ACP server over stdio'\n") throws -> URL {
        let executable = directory.appendingPathComponent("devin")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeResolver(
        launchEnvironmentProvider: @escaping DevinACPLaunchResolver.EnvironmentProvider = { _ in ACPLaunchEnvironment(environment: [:]) }
    ) -> DevinACPLaunchResolver {
        DevinACPLaunchResolver(
            launchEnvironmentProvider: launchEnvironmentProvider,
            supplementalPathProvider: { CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0) },
            environmentFilter: { environment, _ in environment },
            failureRecorder: { _, _ in }
        )
    }

    private func makeTestDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor DevinProbeEnvironmentGate {
    private let environment: [String: String]
    private var callCount = 0
    private var secondCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSecondCallContinuation: CheckedContinuation<Void, Never>?

    init(environment: [String: String]) {
        self.environment = environment
    }

    func nextEnvironment() async -> ACPLaunchEnvironment {
        callCount += 1
        if callCount == 2 {
            let waiters = secondCallWaiters
            secondCallWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseSecondCallContinuation = continuation
            }
        }
        return ACPLaunchEnvironment(environment: environment)
    }

    func waitForSecondCall() async {
        guard callCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondCallWaiters.append(continuation)
        }
    }

    func releaseSecondCall() {
        releaseSecondCallContinuation?.resume()
        releaseSecondCallContinuation = nil
    }
}
