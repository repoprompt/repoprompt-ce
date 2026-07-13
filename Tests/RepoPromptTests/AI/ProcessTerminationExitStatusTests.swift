import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// Detailed exit-status decoding and real-child reaping through the shared
/// ProcessTermination authority: exited-vs-signaled semantics must survive
/// alongside the historical normalized `128 + signal` mapping.
final class ProcessTerminationExitStatusTests: XCTestCase {
    func testDecodeWaitStatusPreservesExitSignalAndFallbackSemantics() {
        // Raw waitpid statuses: exit code lives in the high byte, an uncaught
        // signal in the low 7 bits, and 0x7F marks a stopped child.
        let exitZero = ProcessTermination.decodeWaitStatus(0)
        XCTAssertEqual(exitZero, .exited(code: 0))
        XCTAssertEqual(exitZero.normalizedExitCode, 0)
        XCTAssertEqual(exitZero.terminationStatus, 0)
        XCTAssertEqual(exitZero.terminationReason, .exit)

        let exitThree = ProcessTermination.decodeWaitStatus(3 << 8)
        XCTAssertEqual(exitThree, .exited(code: 3))
        XCTAssertEqual(exitThree.normalizedExitCode, 3)
        XCTAssertEqual(exitThree.terminationStatus, 3)

        let sigterm = ProcessTermination.decodeWaitStatus(SIGTERM)
        XCTAssertEqual(sigterm, .uncaughtSignal(signal: SIGTERM))
        XCTAssertEqual(sigterm.normalizedExitCode, 128 + SIGTERM)
        XCTAssertEqual(sigterm.terminationStatus, SIGTERM)
        XCTAssertEqual(sigterm.terminationReason, .uncaughtSignal)

        // Stopped/other statuses fall back to the raw value, matching the
        // historical normalized behavior.
        let stopped = ProcessTermination.decodeWaitStatus(0x7F)
        XCTAssertEqual(stopped, .exited(code: 0x7F))
        XCTAssertEqual(stopped.normalizedExitCode, 0x7F)
    }

    func testBlockingReapChildStatusPreservesExitAndSignalSemantics() async throws {
        let exiting = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            environment: [:],
            workingDirectory: nil
        )
        exiting.stdin?.closeFile()
        let target = GitProcessLifecycleTarget(
            processIdentifier: exiting.pid,
            processGroupID: exiting.processGroupID
        )
        let exitStatus = try await ProcessTermination.reapChildStatus(
            pid: exiting.pid,
            onReaped: { target.markTerminated() }
        )
        XCTAssertEqual(exitStatus, .exited(code: 7))
        XCTAssertFalse(target.isRunning)

        let signaled = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "kill -KILL $$"],
            environment: [:],
            workingDirectory: nil
        )
        signaled.stdin?.closeFile()
        let signalStatus = try await ProcessTermination.reapChildStatus(pid: signaled.pid)
        XCTAssertEqual(signalStatus, .uncaughtSignal(signal: SIGKILL))
    }

    func testBlockingReapChildStatusTreatsECHILDAsOwnershipError() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 0"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()
        let firstStatus = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
        XCTAssertEqual(firstStatus, .exited(code: 0))

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("A second sole-reaper wait must not fabricate a successful exit")
        } catch let error as ProcessTerminationError {
            guard case let .childOwnershipLost(pid) = error else {
                return XCTFail("Expected childOwnershipLost, got \(error)")
            }
            XCTAssertEqual(pid, spawned.pid)
        } catch {
            XCTFail("Expected ProcessTerminationError, got \(error)")
        }
    }

    func testWaitForTerminationStatusReportsRealChildExitAndSignal() async throws {
        let exiting = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 3"],
            environment: [:],
            workingDirectory: nil
        )
        exiting.stdin?.closeFile()
        let exitOutcome = try await ProcessTermination.waitForTerminationStatus(
            pid: exiting.pid,
            processGroupID: exiting.processGroupID,
            timeout: 5
        )
        XCTAssertFalse(exitOutcome.timedOut)
        XCTAssertEqual(exitOutcome.status, .exited(code: 3))

        let signaled = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "kill -KILL $$"],
            environment: [:],
            workingDirectory: nil
        )
        signaled.stdin?.closeFile()
        let signalOutcome = try await ProcessTermination.waitForTerminationStatus(
            pid: signaled.pid,
            processGroupID: signaled.processGroupID,
            timeout: 5
        )
        XCTAssertFalse(signalOutcome.timedOut)
        XCTAssertEqual(signalOutcome.status, .uncaughtSignal(signal: SIGKILL))
        XCTAssertEqual(signalOutcome.status.normalizedExitCode, 128 + SIGKILL)
    }
}
