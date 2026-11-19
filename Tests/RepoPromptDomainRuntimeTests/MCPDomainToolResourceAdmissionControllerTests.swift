import Foundation
import RepoPromptDomainRuntime
import XCTest

final class MCPDomainToolResourceAdmissionControllerTests: XCTestCase {
    func testCancellingHeadMiddleAndTailPreservesFIFOAndIndependentResource() async throws {
        let controller = MCPDomainToolResourceAdmissionController(limit: 1)
        defer { controller.close() }
        let resource = MCPDomainToolResourceAdmissionController.Resource.window(1)
        let blocker = try await controller.acquire(resource)
        let admitted = AdmissionOrder()
        var waiters: [Task<Void, Error>] = []
        for index in 0 ..< 6 {
            waiters.append(Task {
                let lease = try await controller.acquire(resource)
                await admitted.append(index)
                lease.release()
            })
            try await waitUntil("waiter \(index) queued") {
                controller.waiterCount(for: resource) == index + 1
            }
        }

        for index in [0, 2, 5] {
            waiters[index].cancel()
            guard case let .failure(error) = await waiters[index].result else {
                return XCTFail("Cancelled waiter \(index) acquired despite the held lease")
            }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(controller.waiterCount(for: resource), 3)

        let independent = try await controller.acquire(.window(2))
        XCTAssertEqual(controller.snapshot().activeLeaseCount, 2)
        XCTAssertTrue(independent.release())

        XCTAssertTrue(blocker.release())
        XCTAssertFalse(blocker.release())
        try await waitUntil("all survivors admitted") { await admitted.indices.count == 3 }
        let order = await admitted.indices
        XCTAssertEqual(order, [1, 3, 4])
        for index in order {
            try await waiters[index].value
        }
        XCTAssertEqual(controller.snapshot().activeLeaseCount, 0)
        XCTAssertEqual(controller.snapshot().waiterCount, 0)
    }

    func testCloseSettlesEveryQueuedResourceAndRejectsNewAcquisition() async throws {
        let controller = MCPDomainToolResourceAdmissionController(limit: 1)
        defer { controller.close() }
        let first = MCPDomainToolResourceAdmissionController.Resource.window(1)
        let second = MCPDomainToolResourceAdmissionController.Resource.window(2)
        let firstLease = try await controller.acquire(first)
        let secondLease = try await controller.acquire(second)
        let firstWaiter = Task { try await controller.acquire(first) }
        let secondWaiter = Task { try await controller.acquire(second) }
        try await waitUntil("both waiters queued") { controller.snapshot().waiterCount == 2 }

        XCTAssertEqual(controller.close(), 2)
        XCTAssertEqual(controller.close(), 0)
        for waiter in [firstWaiter, secondWaiter] {
            guard case let .failure(error) = await waiter.result else {
                return XCTFail("Closing should settle every queued waiter without granting another lease")
            }
            XCTAssertEqual(error as? MCPDomainToolResourceAdmissionController.AdmissionError, .closed)
        }
        XCTAssertEqual(controller.snapshot().waiterCount, 0)
        XCTAssertTrue(firstLease.release())
        XCTAssertTrue(secondLease.release())
        XCTAssertEqual(controller.snapshot().activeLeaseCount, 0)

        do {
            _ = try await controller.acquire(first)
            XCTFail("Closed controller acquired a new lease")
        } catch let error as MCPDomainToolResourceAdmissionController.AdmissionError {
            XCTAssertEqual(error, .closed)
        }
    }

    private func waitUntil(
        _ description: String,
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw AdmissionConditionTimeout(description: description)
            }
            await Task.yield()
        }
    }

    private struct AdmissionConditionTimeout: Error {
        let description: String
    }

    private actor AdmissionOrder {
        private(set) var indices: [Int] = []

        func append(_ index: Int) {
            indices.append(index)
        }
    }
}
