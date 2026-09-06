import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CLIProcessRunnerCancellationTests: XCTestCase {
    func testStreamingCancellationInvokesOneLifecycleCallbackAndReusesGate() async throws {
        let reaper = RecordingChildStatusObserver()
        let lifecycle = ProcessLifecycleProbe()
        let started = expectation(description: "streaming process started")
        let consumerStarted = expectation(description: "stream consumer entered")
        let terminated = expectation(description: "streaming process terminated")
        let secondStarted = expectation(description: "second process started after gate release")
        let secondTerminated = expectation(description: "second process terminated")

        let taskBag = TestTaskCancellationBag()
        let runner = makeRunner(statusObserver: { pid, beforeReap, completion in
            reaper.observe(pid: pid, beforeReap: beforeReap, completion: completion)
        })
        addTeardownBlock {
            taskBag.cancelAll()
            await runner.cancelAll()
            let processesTerminated = await lifecycle.waitForAllProcessesToTerminate()
            if !processesTerminated {
                XCTFail("owned streaming processes did not terminate during bounded teardown")
            }
        }

        let stream = try await runner.runStreaming(
            args: ["-c", "exec /bin/sleep 60"],
            stdin: nil,
            outputMode: .none,
            timeout: 10,
            onProcessStarted: { pid in
                await lifecycle.recordStarted(pid)
                started.fulfill()
            },
            onProcessTerminated: { pid in
                await lifecycle.recordTerminated(pid)
                terminated.fulfill()
            }
        )

        let consumerOutcome = ConsumerOutcomeProbe()
        let consumerFinished = expectation(description: "stream consumer finished")
        let consumer = Task {
            defer { consumerFinished.fulfill() }
            do {
                var iterator = stream.makeAsyncIterator()
                consumerStarted.fulfill()
                while let _ = try await iterator.next() {}
                await consumerOutcome.recordSuccess()
            } catch {
                if error is CancellationError {
                    await consumerOutcome.recordCancelled()
                } else {
                    var failure: ConsumerOutcomeProbe.Failure = if let runnerError = error as? CLIProcessRunnerError {
                        .cliProcessRunner(runnerError)
                    } else {
                        .unexpected(String(describing: error))
                    }
                    await consumerOutcome.record(failure: failure)
                }
            }
        }
        taskBag.add(consumer)

        await fulfillment(of: [started, consumerStarted], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [consumerFinished], timeout: 5)
        guard let consumerResult = await consumerOutcome.value else {
            consumer.cancel()
            return
        }
        switch consumerResult {
        case .success, .cancelled:
            break
        case let .failure(failure):
            XCTFail("unexpected cancellation stream error: \(failure.diagnostic)")
        }
        await fulfillment(of: [terminated], timeout: 5)

        let firstPIDValue = await lifecycle.firstStartedPID()
        let firstPID = try XCTUnwrap(firstPIDValue)
        let firstTerminationCount = await lifecycle.terminationCount(for: firstPID)
        XCTAssertEqual(firstTerminationCount, 1)
        XCTAssertEqual(reaper.registrationCount, 1)
        XCTAssertEqual(reaper.reapBoundaryCount(for: firstPID), 1)

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: firstPID)
            XCTFail("stream cancellation must not leave an unconsumed root status")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .childOwnershipLost(pid: firstPID))
        }

        let secondTask = Task {
            try await runner.runStreaming(
                args: ["-c", "exit 0"],
                stdin: nil,
                outputMode: .none,
                timeout: 2,
                onProcessStarted: { pid in
                    await lifecycle.recordStarted(pid)
                    secondStarted.fulfill()
                },
                onProcessTerminated: { pid in
                    await lifecycle.recordTerminated(pid)
                    secondTerminated.fulfill()
                }
            )
        }
        taskBag.add(secondTask)
        await fulfillment(of: [secondStarted], timeout: 2)
        guard await lifecycle.startedCount == 2 else {
            secondTask.cancel()
            return
        }
        let secondStream = try await secondTask.value
        let secondStatusProbe = StreamStatusProbe()
        let secondOutcome = ConsumerOutcomeProbe()
        let secondConsumerFinished = expectation(description: "normal-completion consumer finished")
        let secondConsumer = Task {
            defer { secondConsumerFinished.fulfill() }
            do {
                for try await event in secondStream {
                    if case let .terminated(status, timedOut) = event {
                        await secondStatusProbe.record(status: status, timedOut: timedOut)
                    }
                }
                await secondOutcome.recordSuccess()
            } catch {
                if error is CancellationError {
                    await secondOutcome.recordCancelled()
                } else {
                    var failure: ConsumerOutcomeProbe.Failure = if let runnerError = error as? CLIProcessRunnerError {
                        .cliProcessRunner(runnerError)
                    } else {
                        .unexpected(String(describing: error))
                    }
                    await secondOutcome.record(failure: failure)
                }
            }
        }
        taskBag.add(secondConsumer)
        await fulfillment(of: [secondConsumerFinished, secondTerminated], timeout: 5)
        guard let secondResult = await secondOutcome.value else {
            secondConsumer.cancel()
            return
        }
        switch secondResult {
        case .success:
            break
        case .cancelled:
            XCTFail("normal-completion control was cancelled")
        case let .failure(failure):
            XCTFail("normal-completion control failed: \(failure.diagnostic)")
        }
        let secondStatus = await secondStatusProbe.value
        XCTAssertEqual(secondStatus, 0)
        let finalTerminationCount = await lifecycle.terminationCount
        XCTAssertEqual(finalTerminationCount, 2)
        XCTAssertEqual(reaper.registrationCount, 2)
        XCTAssertEqual(reaper.reapBoundaryCount, 2)
    }

    func testStreamingNormalCompletionDrainsOutputBeforeTerminalEvent() async throws {
        let reaper = RecordingChildStatusObserver()
        let lifecycle = ProcessLifecycleProbe()
        let runner = makeRunner(statusObserver: { pid, beforeReap, completion in
            reaper.observe(pid: pid, beforeReap: beforeReap, completion: completion)
        })
        addTeardownBlock {
            await runner.cancelAll()
            let processTerminated = await lifecycle.waitForAllProcessesToTerminate()
            if !processTerminated {
                XCTFail("owned streaming process did not terminate during bounded teardown")
            }
        }

        let stream = try await runner.runStreaming(
            args: [
                "-c",
                "printf 'stdout-before-exit\\n'; printf 'stderr-before-exit\\n' >&2"
            ],
            stdin: nil,
            outputMode: .none,
            timeout: 2,
            onProcessStarted: { pid in
                await lifecycle.recordStarted(pid)
            },
            onProcessTerminated: { pid in
                await lifecycle.recordTerminated(pid)
            }
        )

        var stdout = Data()
        var stderr = Data()
        var terminalCount = 0
        var terminalStatus: Int32?
        var terminalTimedOut: Bool?
        var sawOutputAfterTerminal = false
        for try await event in stream {
            switch event {
            case let .stdout(chunk):
                if terminalCount > 0 { sawOutputAfterTerminal = true }
                stdout.append(chunk)
            case let .stderr(chunk):
                if terminalCount > 0 { sawOutputAfterTerminal = true }
                stderr.append(chunk)
            case let .terminated(status, timedOut):
                terminalCount += 1
                terminalStatus = status
                terminalTimedOut = timedOut
            }
        }

        XCTAssertEqual(stdout, Data("stdout-before-exit\n".utf8))
        XCTAssertEqual(stderr, Data("stderr-before-exit\n".utf8))
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(terminalStatus, 0)
        XCTAssertEqual(terminalTimedOut, false)
        XCTAssertFalse(sawOutputAfterTerminal)
        let terminationCount = await lifecycle.terminationCount
        XCTAssertEqual(terminationCount, 1)
    }

    func testStreamingTimeoutReportsUnresolvedBeforeLateObservationAndCleansOnce() async throws {
        let delayedObserver = DelayedChildStatusObserver()
        let lifecycle = ProcessLifecycleProbe()
        let started = expectation(description: "timeout process started")
        let terminated = expectation(description: "timeout process eventually terminated")
        let secondStarted = expectation(description: "gate-reuse control started")
        let secondTerminated = expectation(description: "gate reuse process terminated")

        let taskBag = TestTaskCancellationBag()
        let runner = makeRunner(statusObserver: { pid, beforeReap, completion in
            delayedObserver.observe(pid: pid, beforeReap: beforeReap, completion: completion)
        })
        addTeardownBlock {
            taskBag.cancelAll()
            delayedObserver.releaseObservation()
            await runner.cancelAll()
            let processesTerminated = await lifecycle.waitForAllProcessesToTerminate()
            if !processesTerminated {
                XCTFail("owned streaming processes did not terminate during bounded teardown")
            }
        }

        let stream = try await runner.runStreaming(
            args: ["-c", "exec /bin/sleep 60"],
            stdin: nil,
            outputMode: .none,
            timeout: 0.01,
            onProcessStarted: { pid in
                await lifecycle.recordStarted(pid)
                started.fulfill()
            },
            onProcessTerminated: { pid in
                await lifecycle.recordTerminated(pid)
                terminated.fulfill()
            }
        )
        await fulfillment(of: [started], timeout: 2)

        let consumerOutcome = ConsumerOutcomeProbe()
        let consumerFinished = expectation(description: "timeout stream consumer finished")
        let consumer = Task {
            defer { consumerFinished.fulfill() }
            do {
                for try await _ in stream {}
                await consumerOutcome.recordSuccess()
            } catch {
                if error is CancellationError {
                    await consumerOutcome.recordCancelled()
                } else {
                    var failure: ConsumerOutcomeProbe.Failure = if let runnerError = error as? CLIProcessRunnerError {
                        .cliProcessRunner(runnerError)
                    } else {
                        .unexpected(String(describing: error))
                    }
                    await consumerOutcome.record(failure: failure)
                }
            }
        }
        taskBag.add(consumer)
        await fulfillment(of: [consumerFinished], timeout: 5)
        guard let consumerResult = await consumerOutcome.value else {
            consumer.cancel()
            return
        }
        switch consumerResult {
        case .success, .cancelled:
            XCTFail("unresolved owned process must finish the stream with a failure")
        case let .failure(failure):
            switch failure {
            case let .cliProcessRunner(error):
                guard case let .waitFailed(message) = error else {
                    XCTFail("expected CLIProcessRunnerError.waitFailed, got \(error.localizedDescription)")
                    break
                }
                XCTAssertTrue(
                    message.contains("did not settle after bounded termination"),
                    "missing unresolved-owner diagnostic: \(message)"
                )
                XCTAssertTrue(
                    message.contains("exit observer remains responsible for cleanup"),
                    "missing observer-ownership diagnostic: \(message)"
                )
            case let .unexpected(message):
                XCTFail("expected CLIProcessRunnerError.waitFailed, got \(message)")
            }
        }

        // Start a normal-completion control before releasing the delayed
        // observation. No scheduler timing is used as a permit-retention oracle;
        // source review covers finalizer-owned release.
        let secondTask = Task {
            try await runner.runStreaming(
                args: ["-c", "exit 0"],
                stdin: nil,
                outputMode: .none,
                timeout: 2,
                onProcessStarted: { pid in
                    await lifecycle.recordStarted(pid)
                    secondStarted.fulfill()
                },
                onProcessTerminated: { pid in
                    await lifecycle.recordTerminated(pid)
                    secondTerminated.fulfill()
                }
            )
        }
        taskBag.add(secondTask)
        delayedObserver.releaseObservation()
        await fulfillment(of: [terminated, secondStarted], timeout: 5)
        let firstPIDValue = await lifecycle.firstStartedPID()
        let firstPID = try XCTUnwrap(firstPIDValue)
        let firstTerminationCount = await lifecycle.terminationCount(for: firstPID)
        XCTAssertEqual(firstTerminationCount, 1)
        XCTAssertEqual(delayedObserver.reapBoundaryCount(for: firstPID), 1)

        guard await lifecycle.startedCount == 2 else {
            secondTask.cancel()
            return
        }
        let secondStream = try await secondTask.value
        let secondStatusProbe = StreamStatusProbe()
        let secondOutcome = ConsumerOutcomeProbe()
        let secondConsumerFinished = expectation(description: "late-observation control consumer finished")
        let secondConsumer = Task {
            defer { secondConsumerFinished.fulfill() }
            do {
                for try await event in secondStream {
                    if case let .terminated(status, timedOut) = event {
                        await secondStatusProbe.record(status: status, timedOut: timedOut)
                    }
                }
                await secondOutcome.recordSuccess()
            } catch {
                if error is CancellationError {
                    await secondOutcome.recordCancelled()
                } else {
                    var failure: ConsumerOutcomeProbe.Failure = if let runnerError = error as? CLIProcessRunnerError {
                        .cliProcessRunner(runnerError)
                    } else {
                        .unexpected(String(describing: error))
                    }
                    await secondOutcome.record(failure: failure)
                }
            }
        }
        taskBag.add(secondConsumer)
        await fulfillment(of: [secondConsumerFinished, secondTerminated], timeout: 5)
        guard let secondResult = await secondOutcome.value else {
            secondConsumer.cancel()
            return
        }
        switch secondResult {
        case .success:
            break
        case .cancelled:
            XCTFail("late-observation gate-reuse control was cancelled")
        case let .failure(failure):
            XCTFail("late-observation gate-reuse control failed: \(failure.diagnostic)")
        }
        let secondStatus = await secondStatusProbe.value
        XCTAssertEqual(secondStatus, 0)
        let finalTerminationCount = await lifecycle.terminationCount
        XCTAssertEqual(finalTerminationCount, 2)
        XCTAssertEqual(delayedObserver.reapBoundaryCount, 2)
    }

    func testWaitForTerminationStatusReportsOwnershipLossInsteadOfExitZero() async throws {
        let timeouts: [TimeInterval?] = [nil, 1]
        for timeout in timeouts {
            let spawned = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", "exit 0"],
                environment: [:],
                workingDirectory: nil
            )
            let fixture = OwnedFixtureCleanup(spawned)
            addTeardownBlock { await fixture.cleanup() }
            defer { fixture.closeHandles() }

            let firstStatus = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            fixture.markSettled()
            XCTAssertEqual(firstStatus, .exited(code: 0))

            do {
                _ = try await ProcessTermination.waitForTerminationStatus(
                    pid: spawned.pid,
                    processGroupID: spawned.processGroupID,
                    timeout: timeout
                )
                XCTFail("ECHILD without a reaped status must not become exit 0")
            } catch let error as ProcessTerminationError {
                XCTAssertEqual(error, .childOwnershipLost(pid: spawned.pid))
            }
        }
    }

    func testWaitForTerminationStatusPreservesRealTerminalResult() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            environment: [:],
            workingDirectory: nil
        )
        let fixture = OwnedFixtureCleanup(spawned)
        addTeardownBlock { await fixture.cleanup() }
        defer { fixture.closeHandles() }

        let result = try await ProcessTermination.waitForTerminationStatus(
            pid: spawned.pid,
            processGroupID: spawned.processGroupID,
            timeout: 2
        )
        fixture.markSettled()
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, .exited(code: 7))
    }

    private func makeRunner(
        statusObserver: @escaping ChildProcessExitObserver.StatusObserver
    ) -> CLIProcessRunner {
        CLIProcessRunner(
            config: CLIProcessConfiguration(command: "/bin/sh", enableDebugLogging: false),
            processExitObserverFactory: { pid in
                ChildProcessExitObserver(pid: pid, statusObserver: statusObserver)
            }
        )
    }
}

private final class RecordingChildStatusObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations = 0
    private var reapBoundaries: [pid_t: Int] = [:]

    var registrationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    var reapBoundaryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reapBoundaries.values.reduce(0, +)
    }

    func reapBoundaryCount(for pid: pid_t) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reapBoundaries[pid, default: 0]
    }

    func observe(
        pid: pid_t,
        beforeReap: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<ProcessExitStatus, ProcessTerminationError>) -> Void
    ) {
        lock.lock()
        registrations += 1
        lock.unlock()
        ProcessTermination.observeChildStatus(
            pid: pid,
            beforeReap: { [self] in
                lock.lock()
                reapBoundaries[pid, default: 0] += 1
                lock.unlock()
                beforeReap()
            },
            completion: completion
        )
    }
}

private final class DelayedChildStatusObserver: @unchecked Sendable {
    private struct PendingObservation: @unchecked Sendable {
        let pid: pid_t
        let beforeReap: @Sendable () -> Void
        let completion: @Sendable (Result<ProcessExitStatus, ProcessTerminationError>) -> Void
    }

    private let lock = NSLock()
    private var pendingObservations: [PendingObservation] = []
    private var releaseRequested = false
    private var forwarding = false
    private var registrations = 0
    private var reapBoundaries: [pid_t: Int] = [:]

    var registrationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    var reapBoundaryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reapBoundaries.values.reduce(0, +)
    }

    func reapBoundaryCount(for pid: pid_t) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reapBoundaries[pid, default: 0]
    }

    func observe(
        pid: pid_t,
        beforeReap: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<ProcessExitStatus, ProcessTerminationError>) -> Void
    ) {
        lock.lock()
        registrations += 1
        pendingObservations.append(
            PendingObservation(pid: pid, beforeReap: beforeReap, completion: completion)
        )
        let shouldForward = releaseRequested && !forwarding
        if shouldForward {
            forwarding = true
        }
        lock.unlock()
        if shouldForward {
            forwardPendingObservations()
        }
    }

    func releaseObservation() {
        lock.lock()
        releaseRequested = true
        let shouldForward = !forwarding
        if shouldForward {
            forwarding = true
        }
        lock.unlock()
        if shouldForward {
            forwardPendingObservations()
        }
    }

    private func forwardPendingObservations() {
        while true {
            lock.lock()
            guard releaseRequested, !pendingObservations.isEmpty else {
                forwarding = false
                lock.unlock()
                return
            }
            let observation = pendingObservations.removeFirst()
            lock.unlock()

            ProcessTermination.observeChildStatus(
                pid: observation.pid,
                beforeReap: { [self] in
                    lock.lock()
                    reapBoundaries[observation.pid, default: 0] += 1
                    lock.unlock()
                    observation.beforeReap()
                },
                completion: observation.completion
            )
        }
    }
}

private actor StreamStatusProbe {
    private var terminalStatus: Int32?

    var value: Int32? {
        terminalStatus
    }

    func record(status: Int32, timedOut: Bool) {
        terminalStatus = timedOut ? nil : status
    }
}

private actor ConsumerOutcomeProbe {
    enum Failure: @unchecked Sendable {
        case cliProcessRunner(CLIProcessRunnerError)
        case unexpected(String)

        var diagnostic: String {
            switch self {
            case let .cliProcessRunner(error):
                error.localizedDescription
            case let .unexpected(message):
                message
            }
        }
    }

    enum Outcome: @unchecked Sendable {
        case success
        case cancelled
        case failure(Failure)
    }

    private var storedOutcome: Outcome?

    var value: Outcome? {
        storedOutcome
    }

    func recordSuccess() {
        storedOutcome = .success
    }

    func recordCancelled() {
        storedOutcome = .cancelled
    }

    func record(failure: Failure) {
        storedOutcome = .failure(failure)
    }
}

private final class TestTaskCancellationBag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelActions: [@Sendable () -> Void] = []
    private var cancellationRequested = false

    func add(_ task: Task<some Any, some Error>) {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            task.cancel()
            return
        }
        cancelActions.append { task.cancel() }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        cancellationRequested = true
        let actions = cancelActions
        cancelActions.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }
}

private actor ProcessLifecycleProbe {
    private var startedPIDs: [pid_t] = []
    private var terminatedPIDs: [pid_t] = []

    func recordStarted(_ pid: pid_t) {
        startedPIDs.append(pid)
    }

    func recordTerminated(_ pid: pid_t) {
        terminatedPIDs.append(pid)
    }

    func firstStartedPID() -> pid_t? {
        startedPIDs.first
    }

    var startedCount: Int {
        startedPIDs.count
    }

    var terminationCount: Int {
        terminatedPIDs.count
    }

    func terminationCount(for pid: pid_t) -> Int {
        terminatedPIDs.count(where: { $0 == pid })
    }

    func waitForAllProcessesToTerminate() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while terminatedPIDs.count < startedPIDs.count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private final class OwnedFixtureCleanup: @unchecked Sendable {
    private let spawned: SpawnedProcess
    private let lock = NSLock()
    private var settled = false
    private var cleanupStarted = false
    private var handlesClosed = false

    init(_ spawned: SpawnedProcess) {
        self.spawned = spawned
    }

    func markSettled() {
        lock.lock()
        settled = true
        lock.unlock()
    }

    func closeHandles() {
        lock.lock()
        guard !handlesClosed else {
            lock.unlock()
            return
        }
        handlesClosed = true
        lock.unlock()
        spawned.stdin?.closeFile()
        spawned.stdout.closeFile()
        spawned.stderr.closeFile()
    }

    func cleanup() async {
        lock.lock()
        guard !cleanupStarted else {
            lock.unlock()
            return
        }
        cleanupStarted = true
        let needsReap = !settled
        lock.unlock()

        if needsReap {
            _ = await ProcessTermination.terminateAndReap(
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                sigtermGrace: 0.25,
                sigkillGrace: 0.25
            )
            markSettled()
        }
        closeHandles()
    }
}
