import Foundation
@testable import RepoPromptApp
import XCTest

final class CancellableProbeTests: XCTestCase {
    func testCancellationBeforeInstallationOrAttachmentPreservesWorkerCleanup() async {
        for cancelBeforeRun in [true, false] {
            let worker = HeldWorker()
            let consumerFinished = expectation(description: "cancelled consumer settled")
            let consumer = Task.detached {
                if cancelBeforeRun { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    let _: Int = try await CancellableProbe.run { complete in
                        let task = worker.start(complete)
                        if !cancelBeforeRun { withUnsafeCurrentTask { $0?.cancel() } }
                        return task
                    }
                    XCTFail("Cancelled probe returned a value")
                } catch { XCTAssertTrue(error is CancellationError) }
                consumerFinished.fulfill()
            }
            defer {
                consumer.cancel()
                worker.release()
            }
            await fulfillment(of: [consumerFinished], timeout: 5)
            XCTAssertEqual(worker.startCount, 1, "Cancellation must not abandon a pre-reserved worker")
            XCTAssertTrue(worker.isCancelled, "Late attachment must cancel the worker")
            XCTAssertTrue(worker.hasReservation, "Consumer cancellation must not release worker capacity")
            worker.release()
            await fulfillment(of: [worker.finished], timeout: 5)
            XCTAssertFalse(worker.hasReservation)
        }
    }

    func testCompletionBeforeAttachmentPreservesResultUnlessConsumerIsCancelled() async {
        for cancelAfterCompletion in [false, true] {
            let worker = HeldWorker()
            let consumerFinished = expectation(description: "early completion settled")
            let consumer = Task.detached {
                do {
                    let value: Int = try await CancellableProbe.run { complete in
                        complete(.success(42))
                        complete(.failure(ProbeError.failed))
                        let task = worker.start(complete)
                        if cancelAfterCompletion { withUnsafeCurrentTask { $0?.cancel() } }
                        return task
                    }
                    XCTAssertFalse(cancelAfterCompletion, "The final cancellation check must reject an early success")
                    XCTAssertEqual(value, 42, "Only the first completion can win")
                } catch {
                    XCTAssertTrue(cancelAfterCompletion)
                    XCTAssertTrue(error is CancellationError)
                }
                consumerFinished.fulfill()
            }
            defer {
                consumer.cancel()
                worker.release()
            }
            await fulfillment(of: [consumerFinished], timeout: 5)
            XCTAssertTrue(worker.isCancelled, "Attachment after settlement cancels even a successful worker")
            worker.release()
            await fulfillment(of: [worker.finished], timeout: 5)
            XCTAssertFalse(worker.hasReservation)
        }
    }

    func testWorkerFailurePreservesOriginalError() async {
        let consumerFinished = expectation(description: "failure settled")
        let consumer = Task.detached {
            do {
                let _: Int = try await CancellableProbe.run { complete in
                    Task.detached { complete(.failure(ProbeError.failed)) }
                }
                XCTFail("Failed probe returned a value")
            } catch { XCTAssertEqual(error as? ProbeError, .failed) }
            consumerFinished.fulfill()
        }
        defer { consumer.cancel() }
        await fulfillment(of: [consumerFinished], timeout: 5)
    }

    func testCompetingCompletionAndCancellationSettleOnce() async {
        for _ in 0 ..< 20 {
            let worker = HeldWorker()
            let consumerFinished = expectation(description: "racing consumer settled once")
            let consumer = Task.detached {
                do {
                    let value: Int = try await CancellableProbe.run { worker.start($0) }
                    XCTAssertEqual(value, 42)
                } catch { XCTAssertTrue(error is CancellationError) }
                consumerFinished.fulfill()
            }
            defer {
                consumer.cancel()
                worker.release()
            }
            await fulfillment(of: [worker.started], timeout: 5)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { consumer.cancel() }
                group.addTask { worker.release() }
            }
            await fulfillment(of: [consumerFinished, worker.finished], timeout: 5)
            XCTAssertEqual(worker.startCount, 1)
            XCTAssertFalse(worker.hasReservation)
        }
    }

    private enum ProbeError: Error { case failed }

    /// Models an adapter's pre-reserved slot and cancellation-insensitive worker lifetime.
    /// A continuation gate holds work without blocking the cooperative executor.
    private final class HeldWorker: @unchecked Sendable {
        let started = XCTestExpectation(description: "worker started")
        let finished = XCTestExpectation(description: "worker released reservation and completed")
        private let lock = NSLock()
        private var starts = 0
        private var reserved = true
        private var task: Task<Void, Never>?
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        var startCount: Int {
            lock.withLock { starts }
        }

        var hasReservation: Bool {
            lock.withLock { reserved }
        }

        var isCancelled: Bool {
            lock.withLock { task?.isCancelled == true }
        }

        func release() {
            let pending = lock.withLock {
                released = true
                let pending = releaseWaiter
                releaseWaiter = nil
                return pending
            }
            pending?.resume()
        }

        private func waitForRelease() async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if released { return true }
                    releaseWaiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }

        func start(_ complete: @escaping @Sendable (Result<Int, Error>) -> Void) -> Task<Void, Never> {
            lock.withLock { starts += 1 }
            let task = Task.detached { [self] in
                await waitForRelease()
                lock.withLock { reserved = false }
                complete(.success(42))
                finished.fulfill()
            }
            lock.withLock { self.task = task }
            started.fulfill()
            return task
        }
    }
}
