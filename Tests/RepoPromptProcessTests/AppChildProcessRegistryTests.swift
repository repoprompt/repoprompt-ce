import Darwin
import Foundation
@testable import RepoPromptProcess
import XCTest

final class AppChildProcessRegistryTests: XCTestCase {
    func testEmergencyExitKillsOwnedGroupWithoutStealingOwnerExitStatus() async throws {
        let owned = try spawn("trap '' TERM; /bin/sleep 60 & echo $!; wait")
        defer { cleanup(owned) }
        let unrelated = try spawn("exec /bin/sleep 60")
        defer { cleanup(unrelated) }
        let registry = AppChildProcessRegistry()
        registry.register(pid: owned.pid, processGroupID: owned.pid)
        let data = owned.stdout.availableData
        let descendantPID = try XCTUnwrap(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getpgid(descendantPID), owned.pid)

        await registry.terminateForAppExit()
        var status: Int32 = 0
        var reaped: pid_t = 0
        let reapDeadline = ContinuousClock.now + .seconds(2)
        repeat {
            reaped = ProcessLauncher.childProcessRegistry.waitpid(owned.pid, &status, WNOHANG)
            if reaped == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        } while reaped == 0 && ContinuousClock.now < reapDeadline
        XCTAssertEqual(reaped, owned.pid)
        XCTAssertEqual(
            ProcessTermination.decodeWaitStatus(status),
            .uncaughtSignal(signal: SIGKILL),
            "Emergency cleanup must leave the sole owner's full exit status intact"
        )
        XCTAssertEqual(kill(unrelated.pid, 0), 0, "Unregistered children must not be signaled")
        let descendantDeadline = ContinuousClock.now + .seconds(2)
        while kill(descendantPID, 0) == 0, ContinuousClock.now < descendantDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(descendantPID, 0), -1, "Owned provider descendants must not survive quit")
        _ = await ProcessTermination.terminateAndReap(pid: unrelated.pid, processGroupID: unrelated.processGroupID)
    }

    func testEmergencyExitUnblocksCancellationIgnoringACPStyleStdinWrite() async throws {
        let process = try spawn("exec /bin/sleep 60")
        defer {
            cleanup(process)
        }
        let registry = AppChildProcessRegistry()
        registry.register(pid: process.pid, processGroupID: process.pid)
        let descriptor = try XCTUnwrap(process.stdinDescriptor)
        let enteredWrite = expectation(description: "entered blocking pipe write")
        let failedWrite = expectation(description: "blocked write released")
        let writer = Task.detached {
            let start = ContinuousClock.now
            enteredWrite.fulfill()
            do {
                // Far larger than the pipe buffer, with a child that never reads stdin.
                try FDWriteSupport.writeAll(Data(repeating: 0x61, count: 1_000_000), to: descriptor)
                XCTFail("Unread pipe unexpectedly accepted the full frame")
            } catch {
                XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(20))
                XCTAssertEqual(error as? FDWriteError, .brokenPipe(errno: EPIPE))
                failedWrite.fulfill()
            }
        }
        await fulfillment(of: [enteredWrite], timeout: 1)
        try? await Task.sleep(for: .milliseconds(30))
        writer.cancel()
        await registry.terminateForAppExit()
        await fulfillment(of: [failedWrite], timeout: 1)
        let outcome = try await ProcessTermination.waitForTermination(
            pid: process.pid,
            processGroupID: process.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(outcome.exitCode, 128 + SIGKILL)
        XCTAssertFalse(outcome.timedOut)
    }

    func testNormalReapPreservesExitStatusAndClosesSignalOwnership() async throws {
        let process = try spawn("exit 23")
        defer {
            cleanup(process)
        }
        let result = try await ProcessTermination.waitForTermination(
            pid: process.pid,
            processGroupID: process.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(result.exitCode, 23)
        XCTAssertFalse(result.timedOut)
        var status: Int32 = 0
        XCTAssertEqual(ProcessLauncher.childProcessRegistry.waitpid(process.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testExitClosesAdmissionAndWaitsForAlreadyAdmittedLaunchPublication() async throws {
        let registry = AppChildProcessRegistry()
        XCTAssertTrue(registry.beginLaunch())
        let cleanupTask = Task { await registry.terminateForAppExit() }
        var fenced = false
        let fenceDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < fenceDeadline {
            if !registry.beginLaunch() {
                fenced = true
                break
            }
            registry.finishLaunch()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fenced, "Quit must fence new launches")
        let process = try spawn("exec /bin/sleep 60")
        defer { cleanup(process) }
        registry.register(pid: process.pid, processGroupID: process.pid)
        registry.finishLaunch()
        await cleanupTask.value
        let outcome = try await ProcessTermination.waitForTermination(
            pid: process.pid,
            processGroupID: process.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(outcome.exitCode, 128 + SIGKILL, "A pre-quit admitted launch must be swept on publication")
    }

    private func cleanup(_ process: SpawnedProcess) {
        // Check unreaped child ownership before signaling: successful tests may already have
        // consumed this PID, and cleanup must never target a recycled process group.
        var info = siginfo_t()
        if let groupID = process.processGroupID,
           Darwin.waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
        {
            _ = ProcessTermination.signalProcessGroupOnly(processGroupID: groupID, signal: SIGKILL)
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            var status: Int32 = 0
            while ProcessLauncher.childProcessRegistry.waitpid(process.pid, &status, WNOHANG) == 0,
                  ProcessInfo.processInfo.systemUptime < deadline
            {
                usleep(10000)
            }
        }
        process.stdin?.closeFile()
        process.stdout.closeFile()
        process.stderr.closeFile()
    }

    private func spawn(_ script: String) throws -> SpawnedProcess {
        try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil
        )
    }
}
