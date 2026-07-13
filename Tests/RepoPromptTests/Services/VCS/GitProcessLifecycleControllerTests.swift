import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// State-machine and escalation coverage for the PID/process-group based git
/// lifecycle controller: cancellation intent accrued before spawn, terminated
/// children reported at spawn, and SIGTERM→SIGKILL escalation against a child
/// that ignores SIGTERM.
final class GitProcessLifecycleControllerTests: XCTestCase {
    func testCancellationBeforeSpawnThrowsAndMarksSpawnCancelled() {
        let controller = GitProcessLifecycleController()
        controller.requestCancellation(terminationGrace: .seconds(1))

        XCTAssertThrowsError(try controller.checkCancellationBeforeSpawn()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNotNil(controller.cancellationErrorIfRequested())
        XCTAssertFalse(controller.shouldKeepNormalTimeout())

        // A caller that spawned anyway (cancellation raced the launch call)
        // must be told to treat the child as cancelled.
        let target = GitProcessLifecycleTarget(processIdentifier: 0, processGroupID: nil)
        XCTAssertEqual(
            controller.didSpawn(target: target, terminationGrace: .seconds(1)),
            .cancellationRequested
        )
    }

    func testTerminationBeforeSpawnReportsTerminatedState() {
        let controller = GitProcessLifecycleController()
        _ = controller.commitFinalization()

        let target = GitProcessLifecycleTarget(processIdentifier: 0, processGroupID: nil)
        XCTAssertEqual(
            controller.didSpawn(target: target, terminationGrace: .seconds(1)),
            .terminated
        )
        XCTAssertNil(controller.cancellationErrorIfRequested())
        XCTAssertFalse(controller.shouldKeepNormalTimeout())
    }

    func testCancellationAcceptedBeforeFinalizationIsCommitted() {
        let controller = GitProcessLifecycleController()
        let target = GitProcessLifecycleTarget(processIdentifier: 0, processGroupID: nil)
        XCTAssertEqual(
            controller.didSpawn(target: target, terminationGrace: .seconds(1)),
            .running
        )

        controller.requestCancellation(terminationGrace: .seconds(1))
        let finalization = controller.commitFinalization()

        XCTAssertTrue(finalization.cancellationRequested)
        XCTAssertTrue(finalization.requiresProcessGroupCleanup)
        XCTAssertNotNil(finalization.cancellationError)
        XCTAssertEqual(controller.commitFinalization(), finalization)
    }

    func testCancellationAfterFinalizationIsConsistentlyTooLate() {
        let controller = GitProcessLifecycleController()
        let target = GitProcessLifecycleTarget(processIdentifier: 0, processGroupID: nil)
        XCTAssertEqual(
            controller.didSpawn(target: target, terminationGrace: .seconds(1)),
            .running
        )

        let finalization = controller.commitFinalization()
        controller.requestCancellation(terminationGrace: .seconds(1))

        XCTAssertFalse(finalization.cancellationRequested)
        XCTAssertFalse(finalization.requiresProcessGroupCleanup)
        XCTAssertNil(controller.cancellationErrorIfRequested())
        XCTAssertEqual(controller.commitFinalization(), finalization)
    }

    func testCancellationEscalatesToSIGKILLWhenChildIgnoresSIGTERM() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf READY; while :; do sleep 0.05; done"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()
        let target = GitProcessLifecycleTarget(
            processIdentifier: spawned.pid,
            processGroupID: spawned.processGroupID
        )
        // Do not signal until the child confirms its TERM trap is installed.
        XCTAssertEqual(spawned.stdout.readData(ofLength: 5), Data("READY".utf8))

        let controller = GitProcessLifecycleController()
        XCTAssertEqual(
            controller.didSpawn(target: target, terminationGrace: .milliseconds(100)),
            .running
        )

        controller.requestCancellation(terminationGrace: .milliseconds(100))

        // The shell ignores SIGTERM, so only the armed SIGKILL escalation can
        // end it. Reap through the shared authority to avoid zombies.
        let outcome = try await ProcessTermination.waitForTerminationStatus(
            pid: spawned.pid,
            processGroupID: spawned.processGroupID,
            timeout: 5
        )
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, .uncaughtSignal(signal: SIGKILL))

        target.markTerminated()
        _ = controller.commitFinalization()
    }
}
