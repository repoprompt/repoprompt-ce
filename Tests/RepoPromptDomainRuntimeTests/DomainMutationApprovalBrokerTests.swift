import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainMutationApprovalBrokerTests: XCTestCase {
    func testRequestsArePresentedAndSettledInFIFOOrder() async throws {
        let broker = DomainMutationApprovalBroker()
        let recorder = ApprovalRecorder()
        await broker.registerPresenter(recorder.presenter())
        let firstRequest = request(summary: "first")
        let secondRequest = request(summary: "second")

        let firstTask = Task { await broker.request(firstRequest) }
        try await waitForActive(firstRequest.id, broker: broker)
        let secondTask = Task { await broker.request(secondRequest) }
        try await waitForQueue([secondRequest.id], broker: broker)

        await broker.resolve(requestID: firstRequest.id, approved: true, alwaysAllow: true)
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .approved(alwaysAllow: true))
        try await waitForActive(secondRequest.id, broker: broker)
        await broker.resolve(requestID: secondRequest.id, approved: false)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .denied)

        let events = await recorder.events
        XCTAssertEqual(events, [
            .presented(firstRequest.id),
            .dismissed(firstRequest.id),
            .presented(secondRequest.id),
            .dismissed(secondRequest.id),
        ])
    }

    func testCancellationSettlesActiveAndQueuedRequestsAndLateResponsesAreIgnored() async throws {
        let broker = DomainMutationApprovalBroker()
        let recorder = ApprovalRecorder()
        await broker.registerPresenter(recorder.presenter())
        let activeRequest = request(summary: "active", windowID: 9)
        let queuedRequest = request(summary: "queued", windowID: 9)
        let activeTask = Task { await broker.request(activeRequest) }
        try await waitForActive(activeRequest.id, broker: broker)
        let queuedTask = Task { await broker.request(queuedRequest) }
        try await waitForQueue([queuedRequest.id], broker: broker)

        await broker.cancel(windowID: 9)
        let activeResult = await activeTask.value
        let queuedResult = await queuedTask.value
        XCTAssertEqual(activeResult, .cancelled)
        XCTAssertEqual(queuedResult, .cancelled)
        await broker.resolve(requestID: activeRequest.id, approved: true)
        await broker.resolve(requestID: queuedRequest.id, approved: true)

        let snapshot = await broker.snapshot()
        XCTAssertNil(snapshot.activeRequestID)
        XCTAssertTrue(snapshot.queuedRequestIDs.isEmpty)
        let events = await recorder.events
        XCTAssertEqual(events, [
            .presented(activeRequest.id),
            .dismissed(activeRequest.id),
        ])
    }

    func testTimeoutDefaultsToDenyAndPresenterLossSettlesPendingRequests() async throws {
        let broker = DomainMutationApprovalBroker()
        let recorder = ApprovalRecorder()
        await broker.registerPresenter(recorder.presenter())
        let expiring = request(summary: "expiring", deadline: Date().addingTimeInterval(0.02))
        let timeoutTask = Task { await broker.request(expiring) }
        let timeoutResult = await timeoutTask.value
        XCTAssertEqual(timeoutResult, .timeout)

        let active = request(summary: "active")
        let queued = request(summary: "queued")
        let activeTask = Task { await broker.request(active) }
        try await waitForActive(active.id, broker: broker)
        let queuedTask = Task { await broker.request(queued) }
        try await waitForQueue([queued.id], broker: broker)
        await broker.unregisterPresenter()

        let activeResult = await activeTask.value
        let queuedResult = await queuedTask.value
        XCTAssertEqual(activeResult, .presenterUnavailable)
        XCTAssertEqual(queuedResult, .presenterUnavailable)
        let snapshot = await broker.snapshot()
        XCTAssertNil(snapshot.activeRequestID)
        XCTAssertTrue(snapshot.queuedRequestIDs.isEmpty)
    }

    func testPresenterDeadlineReleasesQueueWhenPresentationHangs() async throws {
        let firstDeadline = Date().addingTimeInterval(60)
        let deadlineGate = ApprovalPresentationGate()
        let broker = DomainMutationApprovalBroker(waitForDeadline: { deadline in
            if deadline == firstDeadline {
                await deadlineGate.wait()
            } else {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            }
        })
        let gate = ApprovalPresentationGate()
        let firstRequest = request(summary: "blocked", deadline: firstDeadline)
        let secondRequest = request(summary: "queued")
        let presenter = DomainMutationApprovalPresenter(
            present: { request in
                if request.id == firstRequest.id {
                    await gate.wait()
                }
                return true
            },
            dismiss: { _ in }
        )
        await broker.registerPresenter(presenter)

        let firstTask = Task { await broker.request(firstRequest) }
        try await waitForActive(firstRequest.id, broker: broker)
        let secondTask = Task { await broker.request(secondRequest) }
        try await waitForQueue([secondRequest.id], broker: broker)

        await deadlineGate.release()
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .timeout)
        try await waitForActive(secondRequest.id, broker: broker)
        await broker.resolve(requestID: secondRequest.id, approved: true)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .approved(alwaysAllow: false))
        await gate.release()
        await broker.shutdown()
    }

    func testCallerTaskCancellationSettlesRequestExactlyOnce() async throws {
        let broker = DomainMutationApprovalBroker()
        let recorder = ApprovalRecorder()
        await broker.registerPresenter(recorder.presenter())
        let pending = request(summary: "cancelled")
        let task = Task { await broker.request(pending) }
        try await waitForActive(pending.id, broker: broker)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        await broker.resolve(requestID: pending.id, approved: true)
        let snapshot = await broker.snapshot()
        XCTAssertNil(snapshot.activeRequestID)
    }

    private func request(
        summary: String,
        windowID: Int? = 1,
        deadline: Date = Date().addingTimeInterval(5)
    ) -> DomainMutationApprovalRequest {
        DomainMutationApprovalRequest(
            principalSummary: "test client",
            toolName: "manage_workspaces",
            action: "create",
            risk: .medium,
            summary: summary,
            windowID: windowID,
            deadline: deadline
        )
    }

    private func waitForActive(
        _ requestID: UUID,
        broker: DomainMutationApprovalBroker
    ) async throws {
        for _ in 0 ..< 500 {
            if await broker.snapshot().activeRequestID == requestID { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Approval request never became active")
    }

    private func waitForQueue(
        _ requestIDs: [UUID],
        broker: DomainMutationApprovalBroker
    ) async throws {
        for _ in 0 ..< 500 {
            if await broker.snapshot().queuedRequestIDs == requestIDs { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Approval request queue did not match expected order")
    }
}

private actor ApprovalPresentationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ApprovalRecorder {
    enum Event: Equatable, Sendable {
        case presented(UUID)
        case dismissed(UUID)
    }

    private(set) var events: [Event] = []

    nonisolated func presenter() -> DomainMutationApprovalPresenter {
        DomainMutationApprovalPresenter(
            present: { request in
                await self.record(.presented(request.id))
                return true
            },
            dismiss: { requestID in
                await self.record(.dismissed(requestID))
            }
        )
    }

    private func record(_ event: Event) {
        events.append(event)
    }
}
