import Darwin
import Foundation
@testable import RepoPromptApp
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
            "RepoPromptTests.ProcessLauncherSignalDispositionTests",
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
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
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
                    if result == spawned.pid || (result == -1 && errno != EINTR) { break }
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
            if result == -1, errno == EINTR { continue }
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
            workingDirectory: nil
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
