import Darwin
import Foundation
@testable import RepoPromptProcess
import XCTest

final class ProcessLauncherSignalDispositionTests: XCTestCase {
    private enum HelperEnvironment {
        static let isHelper = "REPOPROMPT_PROCESS_LAUNCHER_SIGTERM_HELPER"
        static let markerPath = "REPOPROMPT_PROCESS_LAUNCHER_SIGTERM_MARKER"
    }

    func testSpawnedChildResetsIgnoredParentSIGTERMToDefault() throws {
        if ProcessInfo.processInfo.environment[HelperEnvironment.isHelper] == "1" {
            try runSignalDispositionHelper()
            return
        }

        let root = try makeTestDirectory(name: "process-launcher-sigterm-helper")
        let markerURL = root.appendingPathComponent("passed")
        let result = try runHelperTestProcess(markerURL: markerURL)

        XCTAssertEqual(
            result.terminationStatus,
            0,
            "isolated SIGTERM helper XCTest failed:\n\(result.output)"
        )

        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8) else {
            XCTFail("isolated SIGTERM helper did not write its completion marker:\n\(result.output)")
            return
        }
        XCTAssertEqual(
            marker,
            "child-helper-passed\nfoundation-process-resets-sigterm\n",
            "Both child launch paths must restore SIGTERM: \(marker)\n\(result.output)"
        )
        print("ProcessLauncher SIGTERM helper observation:\n\(marker)")
    }

    private func runHelperTestProcess(markerURL: URL) throws -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "RepoPromptProcessTests.ProcessLauncherSignalDispositionTests",
            Bundle(for: ProcessLauncherSignalDispositionTests.self).bundleURL.path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment[HelperEnvironment.isHelper] = "1"
        environment[HelperEnvironment.markerPath] = markerURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        // A file cannot fill a pipe while the outer runner waits for its isolated helper.
        let outputURL = markerURL.deletingLastPathComponent().appendingPathComponent("helper.log")
        try Data().write(to: outputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + 30) == .timedOut {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            _ = completion.wait(timeout: .now() + 5)
            throw NSError(
                domain: "ProcessLauncherSignalDispositionTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Isolated SIGTERM test helper exceeded its deadline"]
            )
        }

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        return (process.terminationStatus, output)
    }

    private func runSignalDispositionHelper() throws {
        // Nested XCTest runners must retain the same provider refusal as the outer host.
        XCTAssertThrowsError(try ProviderProcessLaunchPolicy.check()) { error in
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal)
        }
        guard let markerPath = ProcessInfo.processInfo.environment[HelperEnvironment.markerPath] else {
            XCTFail("isolated SIGTERM helper marker path is missing")
            return
        }

        let spawned = try spawnWhileHelperIgnoresSIGTERM()
        var childWasReaped = false
        defer {
            if !childWasReaped {
                _ = Darwin.kill(spawned.pid, SIGKILL)
                var cleanupStatus: Int32 = 0
                while true {
                    let result = Darwin.waitpid(spawned.pid, &cleanupStatus, 0)
                    if result == spawned.pid || (result == -1 && errno != EINTR) {
                        break
                    }
                }
            }
            spawned.stdin?.closeFile()
            spawned.stdout.closeFile()
            spawned.stderr.closeFile()
        }

        let stdin = try XCTUnwrap(spawned.stdin)
        try stdin.write(contentsOf: Data("release\n".utf8))

        let stdout = spawned.stdout.readDataToEndOfFile()
        _ = spawned.stderr.readDataToEndOfFile()

        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(spawned.pid, &status, 0)
            if result == spawned.pid {
                childWasReaped = true
                break
            }
            if result == -1, errno == EINTR {
                continue
            }
            XCTFail("waitpid failed for isolated SIGTERM helper: errno=\(errno)")
            return
        }

        guard status & 0x7F == SIGTERM else {
            XCTFail("helper terminated unexpectedly with wait status \(status)")
            return
        }
        guard stdout.isEmpty else {
            XCTFail(
                "helper continued after self-sent SIGTERM: \(String(decoding: stdout, as: UTF8.self))"
            )
            return
        }

        let foundationObservation = try observeFoundationProcessSIGTERM()
        try Data(
            "child-helper-passed\nfoundation-process-\(foundationObservation)\n".utf8
        ).write(
            to: URL(fileURLWithPath: markerPath),
            options: .atomic
        )
    }

    private func spawnWhileHelperIgnoresSIGTERM() throws -> SpawnedProcess {
        // This disposition change occurs only in the dedicated child XCTest process. The
        // shared XCTest runner never changes its SIGTERM disposition.
        let previousDisposition = Darwin.signal(SIGTERM, SIG_IGN)
        defer {
            _ = Darwin.signal(SIGTERM, previousDisposition)
        }

        return try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: [
                "-c",
                "IFS= read -r _; kill -TERM \"$$\"; printf '%s\\n' 'child-survived-SIGTERM'"
            ],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            purpose: .tool
        )
    }

    private func observeFoundationProcessSIGTERM() throws -> String {
        let spawned = try spawnFoundationProcessWhileHelperIgnoresSIGTERM()
        defer {
            spawned.input.fileHandleForWriting.closeFile()
            spawned.output.fileHandleForReading.closeFile()
        }

        try spawned.input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        spawned.process.waitUntilExit()
        let stdout = spawned.output.fileHandleForReading.readDataToEndOfFile()

        if spawned.process.terminationReason == .uncaughtSignal,
           spawned.process.terminationStatus == SIGTERM,
           stdout.isEmpty
        {
            return "resets-sigterm"
        }
        if spawned.process.terminationReason == .exit,
           spawned.process.terminationStatus == 0,
           stdout == Data("foundation-process-survived\n".utf8)
        {
            return "inherits-ignored-sigterm"
        }

        throw NSError(
            domain: "ProcessLauncherSignalDispositionTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "unexpected Foundation.Process SIGTERM probe result: reason=\(String(describing: spawned.process.terminationReason)), status=\(spawned.process.terminationStatus), stdout=\(String(decoding: stdout, as: UTF8.self))"
            ]
        )
    }

    private func spawnFoundationProcessWhileHelperIgnoresSIGTERM() throws -> (
        process: Process,
        input: Pipe,
        output: Pipe
    ) {
        let previousDisposition = Darwin.signal(SIGTERM, SIG_IGN)
        defer {
            _ = Darwin.signal(SIGTERM, previousDisposition)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "IFS= read -r _; kill -TERM \"$$\"; printf '%s\\n' 'foundation-process-survived'"
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, input, output)
    }
}

/// Exercises the real launch boundary with a harmless shell fixture, never a provider CLI.
final class ProviderProcessLaunchPolicyTests: XCTestCase {
    func testNonXCTestProcessIgnoresUserArgumentsAndInheritedTestEnvironment() throws {
        let root = try makeTestDirectory()
        let source = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("ProviderLaunchPolicyProbe")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let policy = repository.appendingPathComponent("Sources/RepoPromptShared/ProviderProcessLaunchPolicy.swift")
        try """
        import Foundation
        guard NSClassFromString("XCTestCase") == nil else {
            print("unexpected-XCTest-host")
            exit(3)
        }
        print("non-XCTest-host")
        do {
            try ProviderProcessLaunchPolicy.check()
            print("provider-launch-allowed")
        } catch {
            print("provider-launch-refused")
            exit(2)
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        // Compile the real policy, not a copied classifier, into a non-XCTest tool fixture.
        // This runs inside the coordinated test job and never starts a provider CLI.
        let compiled = try runProbe(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc", "-package-name", "RepoPrompt", policy.path, source.path,
                "-o", executable.path
            ],
            environment: ProcessInfo.processInfo.environment,
            root: root
        )
        XCTAssertEqual(compiled.status, 0, compiled.output)
        guard compiled.status == 0 else { return }

        let cases: [(name: String, arguments: [String], environment: [String: String])] = [
            ("user paths and text", ["--cwd", "/proj/Foo.xctest", "text .xctest/Contents/MacOS/example"], [:]),
            ("inherited configuration", [], ["XCTestConfigurationFilePath": "/tmp/example.xctestconfiguration"]),
            ("inherited session", [], ["XCTestSessionIdentifier": UUID().uuidString]),
            ("combined production inputs", ["/proj/Foo.xctest", "text .xctest/example"], [
                "XCTestConfigurationFilePath": "/tmp/example.xctestconfiguration",
                "XCTestSessionIdentifier": UUID().uuidString,
                "XCTestBundlePath": "/tmp/example.xctest"
            ])
        ]
        for fixture in cases {
            // Do not inherit DYLD injection or the test runner's other environment.
            var environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
            environment.merge(fixture.environment) { _, value in value }
            let result = try runProbe(
                executable: executable, arguments: fixture.arguments, environment: environment, root: root
            )
            XCTAssertEqual(result.status, 0, "\(fixture.name): \(result.output)")
            XCTAssertEqual(result.output, "non-XCTest-host\nprovider-launch-allowed\n", fixture.name)
        }
    }

    private func runProbe(
        executable: URL, arguments: [String], environment: [String: String], root: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let log = root.appendingPathComponent("\(UUID().uuidString).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + 30) == .timedOut {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            _ = completion.wait(timeout: .now() + 5)
            throw NSError(
                domain: "ProviderProcessLaunchPolicyTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Non-provider policy probe exceeded its deadline"]
            )
        }
        return try (process.terminationStatus, String(contentsOf: log, encoding: .utf8))
    }

    func testProviderSpawnIsRefusedBeforeExecutingTheCommand() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        XCTAssertThrowsError(try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "touch \"$1\"", "fixture", marker.path],
            environment: [:],
            workingDirectory: nil,
            purpose: .provider
        )) { error in
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBufferedAndStreamingProvidersRefuseBeforeCommandResolution() async throws {
        let runner = CLIProcessRunner(config: .init(command: "missing-provider-for-refusal-test"))
        do {
            _ = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 1)
            XCTFail("A provider must not run without explicit XCTest opt-in")
        } catch {
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
        }
        do {
            _ = try await runner.runStreaming(args: [], stdin: nil, outputMode: .none, timeout: 1)
            XCTFail("A streaming provider must not run without explicit XCTest opt-in")
        } catch {
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
        }
    }

    func testFixtureProcessOptInDoesNotEscapeItsTaskScope() async throws {
        let runner = CLIProcessRunner(config: .init(command: "/bin/sh", shellLookupMode: .disabled))
        let result = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            try await runner.run(args: ["-c", "printf fixture-ok"], stdin: nil, outputMode: .none, timeout: 2)
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "fixture-ok")
        XCTAssertThrowsError(try ProviderProcessLaunchPolicy.check()) { error in
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal)
        }
    }
}
