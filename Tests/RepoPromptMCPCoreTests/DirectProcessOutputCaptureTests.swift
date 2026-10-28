import Foundation
@testable import RepoPromptMCPCore
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DirectProcessOutputCaptureTests: XCTestCase {
    func testCancellationBeforeLaunchDoesNotExecuteTheCommand() async {
        let entered = expectation(description: "launch boundary reached")
        let finished = expectation(description: "cancelled invocation settled")
        let gate = DirectProcessTestGate()
        let probe = DirectProcessTestProbe()
        defer { gate.release() }
        let task = Task.detached {
            defer {
                probe.complete()
                finished.fulfill()
            }
            return await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
                beforeLaunch: { entered.fulfill()
                    await gate.wait()
                },
                afterSpawnBeforeRegistration: { probe.recordPID($0) }
            )) {
                await Self.captureResult {
                    try await DirectProcess.run("/bin/sh", arguments: ["-c", "printf unexpected"], isProvider: false)
                }
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        gate.release()
        guard await settle(finished, task: task, probe: probe, releaseFixture: { gate.release() }) else { return }
        await assertCancelled(task.value)
        XCTAssertNil(probe.pid)
    }

    func testCancellationAtSpawnHandoffEscalatesBeforeSubmittingInput() async {
        let registered = expectation(description: "spawned child held before registration")
        let ready = expectation(description: "child installed SIGTERM refusal")
        let finished = expectation(description: "cancelled invocation settled")
        let gate = DirectProcessTestGate()
        let probe = DirectProcessTestProbe()
        defer {
            gate.release()
            probe.forceStopIfNeeded()
        }
        let task = Task.detached {
            defer {
                probe.complete()
                finished.fulfill()
            }
            return await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
                afterSpawnBeforeRegistration: { pid in
                    probe.recordPID(pid)
                    registered.fulfill()
                    await gate.wait()
                },
                afterReadingOutput: { data in
                    if probe.appendUntilReady(data) { ready.fulfill() }
                },
                afterInputSubmission: { probe.recordInputSubmission() }
            )) {
                await Self.captureResult {
                    try await DirectProcess.run(
                        "/bin/sh", arguments: ["-c", "trap '' TERM; printf 'READY\\n'; exec /bin/sleep 30"],
                        input: Data("must not be delivered".utf8), isProvider: false
                    )
                }
            }
        }
        await fulfillment(of: [registered, ready], timeout: 5)
        task.cancel()
        gate.release()
        guard await settle(finished, task: task, probe: probe, releaseFixture: { gate.release() }) else { return }
        await assertCancelled(task.value)
        XCTAssertFalse(probe.inputSubmitted)
    }

    func testCancellationDuringInputBackpressureClosesOwnedPipes() async {
        let ready = expectation(description: "child is alive without reading stdin")
        let submitted = expectation(description: "large stdin operation submitted")
        let finished = expectation(description: "cancelled invocation settled")
        let probe = DirectProcessTestProbe()
        defer { probe.forceStopIfNeeded() }
        let task = Task.detached {
            defer {
                probe.complete()
                finished.fulfill()
            }
            return await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
                afterSpawnBeforeRegistration: { probe.recordPID($0) },
                afterReadingOutput: { data in
                    if probe.appendUntilReady(data) { ready.fulfill() }
                },
                afterInputSubmission: { submitted.fulfill() }
            )) {
                await Self.captureResult {
                    try await DirectProcess.run(
                        "/bin/sh", arguments: ["-c", "trap '' TERM; printf 'READY\\n'; exec /bin/sleep 30"],
                        input: Data(repeating: 65, count: 16 * 1024 * 1024), isProvider: false
                    )
                }
            }
        }
        await fulfillment(of: [ready, submitted], timeout: 5)
        task.cancel()
        guard await settle(finished, task: task, probe: probe) else { return }
        await assertCancelled(task.value)
    }

    func testOrdinaryRootExitCleansDescendantPipeWriters() async throws {
        let exited = expectation(description: "direct child exited while descendant remains")
        let finished = expectation(description: "owned family and output settled")
        let probe = DirectProcessTestProbe()
        defer { probe.forceStopIfNeeded() }
        let task = Task.detached {
            defer {
                probe.complete()
                finished.fulfill()
            }
            return await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
                afterSpawnBeforeRegistration: { probe.recordPID($0) },
                afterRootExit: {
                    probe.recordGroupAtRootExit()
                    exited.fulfill()
                }
            )) {
                await Self.captureResult {
                    try await DirectProcess.run(
                        "/bin/sh", arguments: ["-c", "/bin/sleep 30 & printf 'descendant=%s\\n' \"$!\""],
                        isProvider: false
                    )
                }
            }
        }
        await fulfillment(of: [exited], timeout: 5)
        guard await settle(finished, task: task, probe: probe) else { return }
        let output = try await task.value.get()
        XCTAssertTrue(output.hasPrefix("descendant="), output)
        XCTAssertTrue(probe.groupWasAliveAtRootExit)
    }

    func testRootExitSettlesWithExternalWriterOnCancellationOrDrainDeadline() async {
        for (separate, holdStderr, cancel) in [(false, false, true), (true, false, true), (true, true, true), (false, false, false)] {
            let exited = expectation(description: "sole observer reaped the direct child")
            let finished = expectation(description: "invocation settled with external writer retained")
            let gate = DirectProcessTestGate()
            let probe = DirectProcessTestProbe()
            let writer = DirectProcessTestRetainedWriter()
            defer {
                gate.release()
                writer.close()
                probe.forceStopIfNeeded()
            }
            let task = Task.detached {
                defer {
                    probe.complete()
                    finished.fulfill()
                }
                return await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
                    afterSpawnBeforeRegistration: { probe.recordPID($0) },
                    onSpawnedOutputWriters: { stdout, stderr in
                        writer.retain(holdStderr ? stderr : stdout)
                    },
                    afterRootExit: {
                        exited.fulfill()
                        await gate.wait()
                    }
                )) {
                    await Self.captureResult {
                        let arguments = ["-c", "printf 'output\\n'; printf 'diagnostic\\n' >&2"]
                        if separate {
                            return try await DirectProcess.runCapturingOutput(
                                "/bin/sh", arguments: arguments, isProvider: false
                            ).standardOutput
                        }
                        return try await DirectProcess.run("/bin/sh", arguments: arguments, isProvider: false)
                    }
                }
            }
            await fulfillment(of: [exited], timeout: 5)
            // This copy belongs to XCTest, outside the child's process group.
            // Root/family termination cannot make the observed stream reach EOF.
            XCTAssertTrue(writer.isOpen, "Fixture must retain an actual pipe writer: errno \(writer.copyError)")
            if cancel { task.cancel() }
            gate.release()
            guard await settle(finished, task: task, probe: probe, releaseFixture: {
                gate.release()
                writer.close()
            }) else { return }
            let result = await task.value
            if cancel {
                assertCancelled(result)
            } else if case let .failure(error) = result {
                let message = String(describing: error)
                XCTAssertTrue(message.contains("Process pipes did not finish"), message)
                XCTAssertTrue(message.contains("output"), message)
                XCTAssertTrue(message.contains("diagnostic"), message)
            } else {
                XCTFail("An unterminated output stream must fail instead of publishing incomplete successful output")
            }
            XCTAssertTrue(writer.isOpen, "The invocation must settle before the external writer closes")
        }
    }

    func testStoppedOutputDrainClosesWhileAnotherWriterRemainsOpen() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let submitted = expectation(description: "read submitted")
        let consumed = expectation(description: "prefix consumed")
        let closed = expectation(description: "owned reader relinquished")
        let group = DispatchGroup()
        let probe = DirectProcessTestProbe()
        let operation = DirectProcessPipeIO(
            reading: pipe.fileHandleForReading,
            completion: group,
            afterRead: { data in
                if probe.appendUntilReady(data) { consumed.fulfill() }
            },
            onSubmitted: { submitted.fulfill() },
            onClosed: { closed.fulfill() }
        )
        defer { operation.stop() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("READY\n".utf8))
        await fulfillment(of: [submitted, consumed], timeout: 5)
        operation.stop()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(operation.snapshot?.data, Data("READY\n".utf8))
        XCTAssertNotEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFD), -1)
    }

    func testStoppedInputWriteClosesWhileAnotherReaderRemainsOpen() async {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let closed = expectation(description: "owned writer relinquished")
        let group = DispatchGroup()
        let operation = DirectProcessPipeIO(
            writingTo: pipe.fileHandleForWriting, completion: group, onClosed: { closed.fulfill() }
        )
        defer { operation.stop() }
        operation.write(Data(repeating: 65, count: 16 * 1024 * 1024))
        operation.stop()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertNotEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFD), -1)
    }

    func testLaunchFailureDoesNotRegisterAChildOrSubmitInput() async {
        let probe = DirectProcessTestProbe()
        let result = await DirectProcess.lifecycleHooksTaskLocal.withValue(.init(
            afterSpawnBeforeRegistration: { probe.recordPID($0) },
            afterInputSubmission: { probe.recordInputSubmission() }
        )) {
            await Self.captureResult {
                try await DirectProcess.run(
                    "/missing-repoprompt-direct-process-fixture", arguments: [],
                    input: Data("unused".utf8), isProvider: false
                )
            }
        }
        guard case .failure = result else { return XCTFail("A failed launch must remain a failure") }
        XCTAssertNil(probe.pid)
        XCTAssertFalse(probe.inputSubmitted)
    }

    func testSeparateOutputPreservesWarningsWithoutChangingCombinedCapture() async throws {
        let arguments = ["-c", "printf 'payload\\n'; printf 'warning\\n' >&2"]
        let separate = try await DirectProcess.runCapturingOutput("/bin/sh", arguments: arguments, isProvider: false)
        XCTAssertEqual(separate.standardOutput, "payload\n")
        XCTAssertEqual(separate.standardError, "warning\n")

        let combined = try await DirectProcess.run("/bin/sh", arguments: arguments, isProvider: false)
        XCTAssertEqual(combined, "payload\nwarning\n")
    }

    func testSeparateOutputFailureRetainsBothDiagnosticStreams() async throws {
        do {
            _ = try await DirectProcess.runCapturingOutput(
                "/bin/sh", arguments: ["-c", "printf 'stdout detail\\n'; printf 'stderr failure\\n' >&2; exit 7"],
                isProvider: false
            )
            XCTFail("A failing command must not return successful captured output")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("stdout detail"), message)
            XCTAssertTrue(message.contains("stderr failure"), message)
        }
    }

    func testPipeReadStartsOnlyAfterAcquiringCaptureLock() {
        let mutex = NSLock()
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: mutex) {
            attemptedLock.signal()
        })
        let state = ReadState()
        let completed = DispatchGroup()

        mutex.lock()
        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                state.recordRead()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        // Acquisition was attempted while we still own the mutex. The pipe must be untouched.
        XCTAssertEqual(state.readCount, 0)
        mutex.unlock()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(capture.finish { Data() }.data, Data("A".utf8))
    }

    func testTerminalDrainWaitsForConsumedChunkToBeAccumulated() {
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: NSLock()) {
            attemptedLock.signal()
        })
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let state = ReadState()

        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                readStarted.signal()
                releaseRead.wait()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)
        completed.enter()
        DispatchQueue.global().async {
            state.store(capture.finish { Data("B".utf8) })
            completed.leave()
        }
        // The finalizer has attempted the same mutex while the consumed chunk is held.
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        releaseRead.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.snapshot?.data, Data("AB".utf8))
        XCTAssertEqual(state.snapshot?.truncated, false)
    }

    func testFinalizationSkipsLateReadersAndPreservesBoundedPrefix() {
        let capture = DirectProcessOutputCapture(limit: 4)
        capture.consume { Data("abc".utf8) }
        let snapshot = capture.finish { Data("def".utf8) }
        XCTAssertEqual(snapshot.data, Data("abcd".utf8))
        XCTAssertTrue(snapshot.truncated)
        capture.consume {
            XCTFail("A late callback must not consume the pipe after finalization")
            return Data("late".utf8)
        }
        XCTAssertEqual(capture.finish {
            XCTFail("Finalization must not drain the pipe twice")
            return Data()
        }, snapshot)

        let exact = DirectProcessOutputCapture(limit: 4)
        exact.consume { Data("abcd".utf8) }
        XCTAssertEqual(exact.finish { Data() }, .init(data: Data("abcd".utf8), truncated: false))
    }

    private static func captureResult(_ operation: () async throws -> String) async -> Result<String, Error> {
        do { return try await .success(operation()) }
        catch { return .failure(error) }
    }

    private func assertCancelled(_ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failure(error) = result else {
            return XCTFail("Cancellation must not publish successful output", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
    }

    private func settle(
        _ finished: XCTestExpectation,
        task: Task<Result<String, Error>, Never>,
        probe: DirectProcessTestProbe,
        releaseFixture: () -> Void = {}
    ) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(result, .completed, "Owned process cleanup exceeded its watchdog")
        if result != .completed {
            task.cancel()
            releaseFixture()
            probe.forceStopIfNeeded()
            let cleanup = await XCTWaiter.fulfillment(of: [probe.settledForCleanup], timeout: 5)
            XCTAssertEqual(cleanup, .completed, "Fixture cleanup failed to join the owned invocation")
        }
        return result == .completed
    }
}

private final class DirectProcessTestRetainedWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failure: Int32 = 0

    var copyError: Int32 {
        lock.withLock { failure }
    }

    var isOpen: Bool {
        lock.withLock {
            guard let handle else { return false }
            return fcntl(handle.fileDescriptor, F_GETFD) != -1
        }
    }

    func retain(_ descriptor: Int32) {
        lock.withLock {
            precondition(handle == nil)
            let copied = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            if copied == -1 {
                failure = errno
            } else {
                handle = FileHandle(fileDescriptor: copied, closeOnDealloc: true)
            }
        }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

private final class DirectProcessTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private final class DirectProcessTestProbe: @unchecked Sendable {
    let settledForCleanup = XCTestExpectation(description: "invocation joined after fixture cleanup")
    private let lock = NSLock()
    private var processID: Int32?
    private var completed = false
    private var output = Data()
    private var ready = false
    private var submitted = false
    private var groupAlive = false

    var pid: Int32? {
        lock.withLock { processID }
    }

    var inputSubmitted: Bool {
        lock.withLock { submitted }
    }

    var groupWasAliveAtRootExit: Bool {
        lock.withLock { groupAlive }
    }

    func recordPID(_ pid: Int32) {
        lock.withLock { processID = pid }
    }

    func recordInputSubmission() {
        lock.withLock { submitted = true }
    }

    func complete() {
        lock.withLock { completed = true }
        settledForCleanup.fulfill()
    }

    func appendUntilReady(_ data: Data) -> Bool {
        lock.withLock {
            guard !ready else { return false }
            output.append(data)
            guard String(decoding: output, as: UTF8.self).contains("READY\n") else { return false }
            ready = true
            return true
        }
    }

    func recordGroupAtRootExit() {
        lock.withLock {
            if let processID { groupAlive = killpg(processID, 0) == 0 }
        }
    }

    func forceStopIfNeeded() {
        lock.withLock {
            // Used only by a failed fixture watchdog while its owned invocation
            // is outstanding. Successful tests never send a second cleanup signal.
            if !completed, let processID { _ = killpg(processID, SIGKILL) }
        }
    }
}

private final class ObservedLock: NSLocking, @unchecked Sendable {
    private let mutex: NSLock
    private let onAttempt: @Sendable () -> Void

    init(mutex: NSLock, onAttempt: @escaping @Sendable () -> Void) {
        self.mutex = mutex
        self.onAttempt = onAttempt
    }

    func lock() {
        onAttempt()
        mutex.lock()
    }

    func unlock() {
        mutex.unlock()
    }
}

private final class ReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var storedSnapshot: DirectProcessOutputCapture.Snapshot?

    var readCount: Int {
        lock.withLock { count }
    }

    var snapshot: DirectProcessOutputCapture.Snapshot? {
        lock.withLock { storedSnapshot }
    }

    func recordRead() {
        lock.withLock { count += 1 }
    }

    func store(_ snapshot: DirectProcessOutputCapture.Snapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }
}
