import Darwin
import Dispatch
import Foundation
@testable import RepoPromptApp
import XCTest

/// Detailed exit-status decoding and real-child reaping through the shared
/// ProcessTermination authority: exited-vs-signaled semantics must survive
/// alongside the historical normalized `128 + signal` mapping.
final class ProcessTerminationExitStatusTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

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
            beforeReap: { target.markTerminated() }
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

    func testBlockedOutcomePublicationDoesNotDelayAnotherChildReap() async throws {
        let gate = BlockedOutcomePublicationGate()
        let cleanup = BlockedOutcomePublicationCleanup(gate: gate)
        addTeardownBlock {
            await cleanup.run()
        }
        let deadline = ProcessTerminationTestDeadline(timeout: 5)

        let childA = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 17"],
            environment: [:],
            workingDirectory: nil
        )
        let observerA = ChildProcessExitObserver(
            pid: childA.pid,
            beforePublishingOutcome: { gate.hold($0) }
        )
        await cleanup.track(childA, observer: observerA)
        closeFixtureHandles(childA)

        guard await gate.waitUntilHolding(timeout: deadline.remaining) else {
            XCTFail("Timed out waiting for child A's outcome publication gate")
            return
        }
        XCTAssertNil(
            observerA.signalRootProcessFamilyIfUnreaped(
                processGroupID: childA.processGroupID,
                signal: 0
            )
        )
        let heldOutcomeBeforeChildB = await observerA.wait(timeout: 0)
        XCTAssertNil(heldOutcomeBeforeChildB)

        let childB = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 23"],
            environment: [:],
            workingDirectory: nil
        )
        let observerB = ChildProcessExitObserver(pid: childB.pid)
        await cleanup.track(childB, observer: observerB)
        closeFixtureHandles(childB)

        guard let outcomeB = await observerB.wait(timeout: deadline.remaining) else {
            XCTFail("Timed out waiting for child B while child A publication remained gated")
            return
        }
        XCTAssertEqual(outcomeB, .exited(.exited(code: 23)))
        assertAlreadyReaped(childB.pid)
        let heldOutcomeAfterChildB = await observerA.wait(timeout: 0)
        XCTAssertNil(heldOutcomeAfterChildB)

        gate.release()
        guard let outcomeA = await observerA.wait(timeout: deadline.remaining) else {
            XCTFail("Timed out waiting for child A after releasing its publication gate")
            return
        }
        XCTAssertEqual(outcomeA, .exited(.exited(code: 17)))
        assertAlreadyReaped(childA.pid)

        await cleanup.run()
    }

    func testChildProcessExitObserverClosesSignalingBeforeDestructiveReap() async throws {
        let gate = BlockedPreReapGate()
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 29"],
            environment: [:],
            workingDirectory: nil
        )
        let observer = ChildProcessExitObserver(
            pid: spawned.pid,
            afterClosingRootSignalingBeforeReap: { gate.hold() }
        )
        let cleanup = ObservedProcessFixtureCleanup(
            observer: observer,
            processGroupID: spawned.processGroupID
        )
        addTeardownBlock {
            gate.release()
            await cleanup.run()
        }
        closeFixtureHandles(spawned)

        let reachedPreReapGate = await gate.waitUntilHolding(timeout: 2)
        XCTAssertTrue(reachedPreReapGate)
        XCTAssertNil(
            observer.signalRootProcessFamilyIfUnreaped(
                processGroupID: spawned.processGroupID,
                signal: 0
            )
        )
        assertTerminalChildStillAwaitingReap(spawned.pid)

        gate.release()
        let outcome = await observer.wait(timeout: 2)
        XCTAssertEqual(
            outcome,
            .exited(.exited(code: 29))
        )
        assertAlreadyReaped(spawned.pid)
        await cleanup.run()
    }

    func testChildProcessExitObserverSharesOneDetailedReap() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 19"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()
        let observer = ChildProcessExitObserver(pid: spawned.pid)

        let first = await observer.wait(timeout: 5)
        let second = await observer.wait(timeout: 0)
        XCTAssertEqual(first, .exited(.exited(code: 19)))
        XCTAssertEqual(second, first)

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("The observer must remain the root child's only destructive reaper")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .childOwnershipLost(pid: spawned.pid))
        }
    }

    func testTerminalChildProbeDoesNotConsumeExitStatus() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 31"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()

        let deadline = Date().addingTimeInterval(2)
        var observedTerminalStatus = false
        while Date() < deadline {
            if ProcessTermination.childIsTerminalOrAlreadyReaped(spawned.pid) {
                observedTerminalStatus = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let status = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
        XCTAssertTrue(observedTerminalStatus)
        XCTAssertEqual(status, .exited(code: 31))
        XCTAssertTrue(ProcessTermination.childIsTerminalOrAlreadyReaped(spawned.pid))
    }

    func testObservedTerminationEscalatesBeforeGroupOnlyCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTerminationExitStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let script = """
        import os
        import signal
        import time

        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                time.sleep(1)
        with open(\(String(reflecting: childPIDURL.path)), "w", encoding="utf-8") as handle:
            handle.write(str(child))
            handle.flush()
            os.fsync(handle.fileno())
        while True:
            time.sleep(1)
        """
        let spawned = try ProcessLauncher.spawn(
            command: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: directory.path
        )
        let observer = ChildProcessExitObserver(pid: spawned.pid)
        let cleanup = ObservedProcessFixtureCleanup(
            observer: observer,
            processGroupID: spawned.processGroupID
        )
        addTeardownBlock {
            await cleanup.run()
        }
        spawned.stdin?.closeFile()
        guard let childPID = await waitForPID(at: childPIDURL) else {
            return XCTFail("Timed out waiting for the descendant PID fixture")
        }

        await cleanup.run()

        let terminationOutcome = await observer.wait(timeout: 0)
        XCTAssertEqual(
            terminationOutcome,
            .exited(.uncaughtSignal(signal: SIGKILL))
        )
        let descendantIsAbsent = await waitUntilProcessIsAbsent(childPID)
        XCTAssertTrue(descendantIsAbsent, "SIGTERM-resistant descendant remained after group cleanup")

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("Observer-aware teardown must not perform or permit a second root reap")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .childOwnershipLost(pid: spawned.pid))
        }
    }

    func testObservedTerminationReturnsAfterBoundedKillGraceWhileOutcomePublicationIsBlocked() async throws {
        let gate = BlockedOutcomePublicationGate()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTerminationExitStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let script = """
        import os
        import signal
        import time

        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                time.sleep(1)
        with open(\(String(reflecting: childPIDURL.path)), "w", encoding="utf-8") as handle:
            handle.write(str(child))
            handle.flush()
            os.fsync(handle.fileno())
        os._exit(37)
        """
        let spawned = try ProcessLauncher.spawn(
            command: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: directory.path
        )
        let observer = ChildProcessExitObserver(
            pid: spawned.pid,
            beforePublishingOutcome: { gate.hold($0) }
        )
        let cleanup = ObservedProcessFixtureCleanup(
            observer: observer,
            processGroupID: spawned.processGroupID
        )
        addTeardownBlock {
            gate.release()
            await cleanup.run()
        }
        closeFixtureHandles(spawned)
        let reachedPublicationGate = await gate.waitUntilHolding(timeout: 2)
        XCTAssertTrue(reachedPublicationGate)
        let observedChildPID = await waitForPID(at: childPIDURL)
        let childPID = try XCTUnwrap(observedChildPID)

        let completion = ProcessTerminationCompletionProbe()
        let termination = Task {
            await ProcessTermination.terminateObservedProcessFamily(
                observer: observer,
                processGroupID: spawned.processGroupID,
                sigtermGrace: 0.02,
                sigkillGrace: 0.02
            )
            await completion.markComplete()
        }
        let returnedWhilePublicationWasBlocked = await completion.waitUntilComplete(timeout: 0.5)
        let descendantIsAbsent = await waitUntilProcessIsAbsent(childPID)
        gate.release()
        await termination.value

        XCTAssertTrue(returnedWhilePublicationWasBlocked)
        XCTAssertTrue(descendantIsAbsent)
        let outcome = await observer.wait(timeout: 2)
        XCTAssertEqual(
            outcome,
            .exited(.exited(code: 37))
        )
        assertAlreadyReaped(spawned.pid)
        await cleanup.run()
    }

    func testObservedTerminationRetriesWaitFailureAndEscalates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTerminationExitStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let readyURL = directory.appendingPathComponent("ready")
        let script = """
        import os
        import signal
        import time

        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(\(String(reflecting: readyURL.path)), "w", encoding="utf-8") as handle:
            handle.write("ready")
            handle.flush()
            os.fsync(handle.fileno())
        while True:
            time.sleep(1)
        """
        let spawned = try ProcessLauncher.spawn(
            command: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: directory.path
        )
        let statusObserver = FailOnceChildStatusObserver()
        let observer = ChildProcessExitObserver(
            pid: spawned.pid,
            statusObserver: { pid, beforeReap, completion in
                statusObserver.observe(
                    pid: pid,
                    beforeReap: beforeReap,
                    completion: completion
                )
            }
        )
        let cleanup = ObservedProcessFixtureCleanup(
            observer: observer,
            processGroupID: spawned.processGroupID
        )
        addTeardownBlock {
            await cleanup.run()
        }
        closeFixtureHandles(spawned)
        let fixtureIsReady = await waitUntilFileExists(readyURL, timeout: 2)
        XCTAssertTrue(fixtureIsReady)

        await ProcessTermination.terminateObservedProcessFamily(
            observer: observer,
            processGroupID: spawned.processGroupID,
            sigtermGrace: 0.05,
            sigkillGrace: 0.5
        )

        XCTAssertGreaterThanOrEqual(statusObserver.observationCount, 2)
        let outcome = await observer.wait(timeout: 0)
        XCTAssertEqual(
            outcome,
            .exited(.uncaughtSignal(signal: SIGKILL))
        )
        assertAlreadyReaped(spawned.pid)
        await cleanup.run()
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

    private func waitForPID(at url: URL, timeout: TimeInterval = 2) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitUntilProcessIsAbsent(_ pid: pid_t, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private func waitUntilFileExists(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func closeFixtureHandles(_ spawned: SpawnedProcess) {
        spawned.stdin?.closeFile()
        spawned.stdout.closeFile()
        spawned.stderr.closeFile()
    }

    private func assertAlreadyReaped(
        _ pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var status: Int32 = 0
        errno = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }

    private func assertTerminalChildStillAwaitingReap(
        _ pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var info = siginfo_t()
        errno = 0
        let result = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        XCTAssertEqual(result, 0, file: file, line: line)
        XCTAssertEqual(info.si_pid, pid, file: file, line: line)
    }
}

private struct ProcessTerminationTestDeadline {
    private let expiration: TimeInterval

    init(timeout: TimeInterval) {
        expiration = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
    }

    var remaining: TimeInterval {
        max(0, expiration - ProcessInfo.processInfo.systemUptime)
    }
}

private final class BlockedOutcomePublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let holdingSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var released = false

    func hold(_: ChildProcessExitObserver.Outcome) {
        lock.lock()
        let shouldWait = !released
        lock.unlock()
        holdingSemaphore.signal()
        if shouldWait {
            releaseSemaphore.wait()
        }
    }

    func waitUntilHolding(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [holdingSemaphore] in
                continuation.resume(
                    returning: holdingSemaphore.wait(timeout: .now() + max(timeout, 0)) == .success
                )
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private final class BlockedPreReapGate: @unchecked Sendable {
    private let lock = NSLock()
    private let holdingSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var released = false

    func hold() {
        lock.lock()
        let shouldWait = !released
        lock.unlock()
        holdingSemaphore.signal()
        if shouldWait {
            releaseSemaphore.wait()
        }
    }

    func waitUntilHolding(timeout: TimeInterval) async -> Bool {
        let timeout = DispatchTime.now() + max(timeout, 0)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [holdingSemaphore] in
                continuation.resume(returning: holdingSemaphore.wait(timeout: timeout) == .success)
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private final class FailOnceChildStatusObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func observe(
        pid: pid_t,
        beforeReap: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<ProcessExitStatus, ProcessTerminationError>) -> Void
    ) {
        lock.lock()
        attempts += 1
        let attempt = attempts
        lock.unlock()

        if attempt == 1 {
            completion(.failure(.waitFailed("injected transient wait failure")))
            return
        }
        ProcessTermination.observeChildStatus(
            pid: pid,
            beforeReap: beforeReap,
            completion: completion
        )
    }
}

private actor ProcessTerminationCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func waitUntilComplete(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if isComplete {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return isComplete
    }
}

private actor BlockedOutcomePublicationCleanup {
    private struct ObservedChild {
        let spawned: SpawnedProcess
        let observer: ChildProcessExitObserver
    }

    private let gate: BlockedOutcomePublicationGate
    private var children: [ObservedChild] = []
    private var didRun = false

    init(gate: BlockedOutcomePublicationGate) {
        self.gate = gate
    }

    func track(_ spawned: SpawnedProcess, observer: ChildProcessExitObserver) {
        children.append(ObservedChild(spawned: spawned, observer: observer))
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        gate.release()

        let ownedChildren = children
        children.removeAll()
        for child in ownedChildren {
            child.spawned.stdin?.closeFile()
            child.spawned.stdout.closeFile()
            child.spawned.stderr.closeFile()
        }
        for child in ownedChildren {
            if await child.observer.wait(timeout: 0) == nil {
                _ = child.observer.signalRootProcessFamilyIfUnreaped(
                    processGroupID: child.spawned.processGroupID,
                    signal: SIGKILL
                )
            }
        }
        for child in ownedChildren {
            _ = await child.observer.wait(timeout: 1)
        }
    }
}

private actor ObservedProcessFixtureCleanup {
    private let observer: ChildProcessExitObserver
    private let processGroupID: pid_t?
    private var didRun = false

    init(observer: ChildProcessExitObserver, processGroupID: pid_t?) {
        self.observer = observer
        self.processGroupID = processGroupID
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        await ProcessTermination.terminateObservedProcessFamily(
            observer: observer,
            processGroupID: processGroupID,
            sigtermGrace: 0.05,
            sigkillGrace: 0.5
        )
    }
}
