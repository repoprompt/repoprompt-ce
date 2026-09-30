import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorFigmaMCPDisableExecutorTests: XCTestCase {
    func testUsesFixedCommandRetainedEnvironmentAndRestrictedLaunchConfiguration() async throws {
        let environment = [
            "HOME": "/tmp/cursor-figma-home",
            "PATH": "/reviewed/bin",
            "LANG": "en_US.UTF-8"
        ]
        let launch = try makeLaunch(executablePath: "/bin/sh", environment: environment)
        let recorder = CursorDisableInvocationRecorder()
        let executor = CursorFigmaMCPDisableExecutor { invocation in
            await recorder.record(invocation)
            return .init(status: 0, timedOut: false)
        }

        let outcome = await executor.disable(retainedLaunch: launch)
        let invocation = await recorder.invocation

        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(invocation?.arguments, ["mcp", "disable", "figma"])
        XCTAssertEqual(invocation?.timeout, 30)
        XCTAssertEqual(invocation?.cancelChildOnTaskCancellation, true)
        XCTAssertEqual(invocation?.configuration.command, FileSystemService.realpathString("/bin/sh"))
        XCTAssertEqual(invocation?.configuration.environment, environment)
        XCTAssertEqual(invocation?.configuration.additionalPaths, [])
        XCTAssertEqual(invocation?.configuration.shellLookupMode, .disabled)
        XCTAssertEqual(invocation?.configuration.captureStdoutTailBytes, 0)
        XCTAssertEqual(invocation?.configuration.captureStderrTailBytes, 0)
        XCTAssertEqual(invocation?.configuration.logStdinSampleBytes, 0)
        XCTAssertEqual(invocation?.configuration.discardOutput, true)
        XCTAssertEqual(invocation?.configuration.enableDebugLogging, false)
    }

    func testRejectsLaunchFromUnreviewedExecutableVersionBeforeSpawn() async throws {
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: "/bin/sh")
        let launch = FigmaMCPProviderResolvedLoginLaunch(
            executableEntryPath: "/bin/sh",
            executableIdentity: identity,
            environment: ["PATH": "/bin"],
            executableVersion: "unreviewed"
        )
        let executor = CursorFigmaMCPDisableExecutor { _ in
            XCTFail("An unreviewed launch must not spawn")
            return .init(status: 0, timedOut: false)
        }

        let outcome = await executor.disable(retainedLaunch: launch)
        XCTAssertEqual(outcome, .failed)
    }

    func testRevalidatesRetainedExecutableIdentityBeforeSpawn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-disable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let launch = try makeLaunch(executablePath: executable.path, environment: ["PATH": "/bin"])

        try FileManager.default.removeItem(at: executable)
        try writeExecutable("#!/bin/sh\nexit 1\n", to: executable)

        let executor = CursorFigmaMCPDisableExecutor { _ in
            XCTFail("A replaced executable must not spawn")
            return .init(status: 0, timedOut: false)
        }
        let outcome = await executor.disable(retainedLaunch: launch)
        XCTAssertEqual(outcome, .failed)
    }

    func testTimeoutFailureAndCancellationAreReported() async throws {
        let launch = try makeLaunch(executablePath: "/bin/sh", environment: ["PATH": "/bin"])
        let timedOut = CursorFigmaMCPDisableExecutor { _ in .init(status: 0, timedOut: true) }
        let failed = CursorFigmaMCPDisableExecutor { _ in .init(status: 1, timedOut: false) }

        let timedOutOutcome = await timedOut.disable(retainedLaunch: launch)
        let failedOutcome = await failed.disable(retainedLaunch: launch)
        XCTAssertEqual(timedOutOutcome, .timedOut)
        XCTAssertEqual(failedOutcome, .failed)

        let probe = CursorDisableCancellationProbe()
        let cancellable = CursorFigmaMCPDisableExecutor { invocation in
            try await probe.run(invocation)
        }
        let task = Task { await cancellable.disable(retainedLaunch: launch) }
        for _ in 0 ..< 100 {
            if await probe.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let didStart = await probe.started
        XCTAssertTrue(didStart)
        task.cancel()
        let cancelledOutcome = await task.value
        let observedCancellation = await probe.observedCancellation
        XCTAssertEqual(cancelledOutcome, .cancelled)
        XCTAssertTrue(observedCancellation)
    }

    private func makeLaunch(
        executablePath: String,
        environment: [String: String]
    ) throws -> FigmaMCPProviderResolvedLoginLaunch {
        try FigmaMCPProviderResolvedLoginLaunch(
            executableEntryPath: executablePath,
            executableIdentity: ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executablePath),
            environment: environment,
            executableVersion: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private actor CursorDisableInvocationRecorder {
    private(set) var invocation: CursorFigmaMCPDisableExecutor.ProcessInvocation?

    func record(_ invocation: CursorFigmaMCPDisableExecutor.ProcessInvocation) {
        self.invocation = invocation
    }
}

private actor CursorDisableCancellationProbe {
    private(set) var started = false
    private(set) var observedCancellation = false

    func run(
        _ invocation: CursorFigmaMCPDisableExecutor.ProcessInvocation
    ) async throws -> CursorFigmaMCPDisableExecutor.ProcessResult {
        XCTAssertTrue(invocation.cancelChildOnTaskCancellation)
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return .init(status: 0, timedOut: false)
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }
}
