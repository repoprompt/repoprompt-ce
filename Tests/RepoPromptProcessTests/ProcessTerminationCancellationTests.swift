import Darwin
import Foundation
@testable import RepoPromptProcess
import XCTest

#if DEBUG
    /// Regression coverage for #481: cancelling a task that is waiting on a child must not turn the
    /// SIGTERM → SIGKILL escalation into a busy poll. Both tests count reaper sleeps through the
    /// DEBUG task-local seam; before the fix each count was in the thousands because `Task.sleep`
    /// returns immediately on a cancelled task.
    final class ProcessTerminationCancellationTests: XCTestCase {
        private final class PollCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        private struct ReadinessTimeout: Error {}

        /// Default escalation is 2 s SIGTERM grace + 1 s SIGKILL grace at a 50 ms cadence, so a
        /// correctly sleeping reaper takes at most ~60 laps; allow jitter headroom. The pre-fix busy
        /// loop produced 21,601 laps in the same window.
        private static let defaultGracePollBound = 120

        /// Explicit 0.2 s + 0.2 s group cleanup takes at most ~8 laps at a 50 ms cadence. The
        /// pre-fix busy loop produced 5,701 laps in that window.
        private static let shortGracePollBound = 40

        /// Generous completion bound; the real regression signal is the poll count.
        private static let completionBound: Duration = .seconds(10)

        func testCancelledWaitKeepsReaperPollCadenceForTermResistantRoot() async throws {
            let marker = try makeTestDirectory().appendingPathComponent("ready")
            // The marker is written only after SIGTERM is ignored, so cancellation never races the trap.
            let child = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", "trap '' TERM; : > \"$1\"; exec /bin/sleep 30", "fixture", marker.path],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                purpose: .tool
            )
            let pid = child.pid
            let processGroupID = child.processGroupID
            Self.closeHandles(child)

            let counter = PollCounter()
            // Started before the readiness wait so a readiness failure still has a reaper; only the
            // cancellation is gated on readiness.
            let waiter = Task {
                try await ProcessTermination.$reaperPollObserverForTesting.withValue({ counter.increment() }) {
                    try await ProcessTermination.waitForTermination(pid: pid, processGroupID: processGroupID, timeout: nil)
                }
            }
            addTeardownBlock {
                waiter.cancel()
                // The waiter owns the destructive reap; never race it from teardown.
                _ = try? await waiter.value
                Self.killAndReapIfStillOwned(pid)
            }
            // Hang backstop only, never the completion bound: a killed child always unblocks the reaper.
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                Self.signalIfStillOwned(pid, SIGKILL)
            }
            defer { watchdog.cancel() }

            try await Self.waitForMarker(marker)
            // Let the outer wait loop take at least one lap before cancelling it.
            try await Task.sleep(nanoseconds: 150_000_000)
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            waiter.cancel()
            let (exitCode, timedOut) = try await waiter.value
            let elapsed = clock.now - cancelledAt

            XCTAssertLessThan(elapsed, Self.completionBound, "cancelled cleanup must settle within the grace windows")
            XCTAssertFalse(timedOut)
            XCTAssertEqual(exitCode, 128 + SIGKILL, "a TERM-resistant child must be escalated to SIGKILL")
            XCTAssertGreaterThan(counter.count, 0, "cleanup must run through the reaper's poll loop")
            XCTAssertLessThanOrEqual(
                counter.count,
                Self.defaultGracePollBound,
                "reaper busy-polled after cancellation (#481); laps=\(counter.count)"
            )
            Self.assertChildReaped(pid)
        }

        func testCancelledGroupCleanupKeepsPollCadenceAfterRootReap() async throws {
            let marker = try makeTestDirectory().appendingPathComponent("ready")
            // The root exits at once; a TERM-resistant descendant keeps the process group alive. The
            // descendant writes the marker only after it ignores SIGTERM.
            let child = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", "(trap '' TERM; : > \"$1\"; exec /bin/sleep 30) & exit 0", "fixture", marker.path],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                purpose: .tool
            )
            let rootPID = child.pid
            let processGroupID = child.processGroupID ?? child.pid
            Self.closeHandles(child)
            addTeardownBlock {
                // A readiness failure leaves the root unreaped; the orphaned descendant is not this
                // process's child to reap, so the group kill is best effort.
                Self.killAndReapIfStillOwned(rootPID)
                _ = killpg(processGroupID, SIGKILL)
            }
            XCTAssertEqual(child.processGroupID, rootPID, "spawn must make the child its process-group leader")

            try await Self.waitForMarker(marker)
            let (rootExitCode, _) = try await ProcessTermination.waitForTermination(
                pid: rootPID,
                processGroupID: processGroupID,
                timeout: nil
            )
            XCTAssertEqual(rootExitCode, 0)
            XCTAssertEqual(killpg(processGroupID, 0), 0, "the descendant must keep the group alive after the root reap")

            let counter = PollCounter()
            let clock = ContinuousClock()
            let started = clock.now
            let cleanup = Task {
                // Returns immediately once cancelled, so the cleanup below always runs cancelled.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await ProcessTermination.$reaperPollObserverForTesting.withValue({ counter.increment() }) {
                    await ProcessTermination.terminateProcessGroupAfterRootReap(
                        processGroupID: processGroupID,
                        sigtermGrace: 0.2,
                        sigkillGrace: 0.2
                    )
                }
            }
            cleanup.cancel()
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                _ = killpg(processGroupID, SIGKILL)
            }
            defer { watchdog.cancel() }
            await cleanup.value
            let elapsed = clock.now - started

            XCTAssertLessThan(elapsed, Self.completionBound, "cancelled group cleanup must settle within its grace windows")
            XCTAssertGreaterThan(counter.count, 0, "group cleanup must run through its poll loop")
            XCTAssertLessThanOrEqual(
                counter.count,
                Self.shortGracePollBound,
                "group cleanup busy-polled after cancellation (#481); laps=\(counter.count)"
            )
            // launchd reaps the orphaned descendant asynchronously after SIGKILL.
            try await Self.waitForProcessGroupToVanish(processGroupID)
        }

        // MARK: - Helpers

        private static func closeHandles(_ child: SpawnedProcess) {
            try? child.stdin?.close()
            try? child.stdout.close()
            try? child.stderr.close()
        }

        private static func waitForMarker(_ url: URL, timeout: Duration = .seconds(5)) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while !FileManager.default.fileExists(atPath: url.path) {
                guard clock.now < deadline else { throw ReadinessTimeout() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        private static func waitForProcessGroupToVanish(
            _ processGroupID: pid_t,
            timeout: Duration = .seconds(10),
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while killpg(processGroupID, 0) == 0 || errno == EPERM {
                guard clock.now < deadline else {
                    XCTFail("process group \(processGroupID) survived cancelled cleanup", file: file, line: line)
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        private static func assertChildReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG)
            let reapErrno = errno
            XCTAssertEqual(reaped, -1, "child status must already have been consumed by the reaper", file: file, line: line)
            XCTAssertEqual(reapErrno, ECHILD, file: file, line: line)
            let signalled = kill(pid, 0)
            let signalErrno = errno
            XCTAssertEqual(signalled, -1, "child must be gone after cancelled cleanup", file: file, line: line)
            XCTAssertEqual(signalErrno, ESRCH, file: file, line: line)
        }

        /// Non-destructive ownership probe: `true` while `pid` is this process's unreaped child.
        /// `ECHILD` after the reaper consumed the status means a recycled PID must not be signalled.
        private static func isOwnedChild(_ pid: pid_t) -> Bool {
            while true {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 { return true }
                if errno == EINTR { continue }
                return false
            }
        }

        private static func signalIfStillOwned(_ pid: pid_t, _ signal: Int32) {
            guard isOwnedChild(pid) else { return }
            _ = kill(pid, signal)
        }

        private static func killAndReapIfStillOwned(_ pid: pid_t) {
            guard isOwnedChild(pid) else { return }
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }
#endif
