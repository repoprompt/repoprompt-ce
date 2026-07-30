@testable import RepoPromptApp
import XCTest

final class CodexModelPollingServiceTests: XCTestCase {
    func testActiveSubscriberStopsOwnedClientAfterRefreshAndKeepsCache() async throws {
        let client = PollingClientSpy()
        await client.setProcessSnapshot(.init(pid: 4242, appearsAlive: true))
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true,
            stopClientAfterRefresh: true
        )

        let consumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 1 }
        try await waitUntil { await client.stopCallCount >= 1 }

        let snapshot = await service.runtimeSnapshot()
        XCTAssertEqual(snapshot.subscriberCount, 1)
        XCTAssertTrue(snapshot.isPolling)
        XCTAssertEqual(snapshot.processSnapshot?.pid, 4242)
        XCTAssertEqual(snapshot.processSnapshot?.appearsAlive, false)
        let firstCachedModelIDs = await service.latestSnapshot()?.models.map(\.id)
        XCTAssertEqual(firstCachedModelIDs, ["polling-test-model-1"])

        await service.refreshNow()
        try await waitUntil { await client.listCallCount >= 2 }
        try await waitUntil { await client.stopCallCount >= 2 }
        let secondCachedModelIDs = await service.latestSnapshot()?.models.map(\.id)
        XCTAssertEqual(secondCachedModelIDs, ["polling-test-model-2"])

        consumer.cancel()
        await consumer.value
        await service.shutdown()
    }

    func testLastSubscriberStopsOwnedClientAndLaterSubscriberRestartsPolling() async throws {
        let client = PollingClientSpy()
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true
        )

        let firstConsumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 1 }
        firstConsumer.cancel()
        await firstConsumer.value
        try await waitUntil { await client.stopCallCount >= 1 }

        let secondConsumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 2 }
        secondConsumer.cancel()
        await secondConsumer.value
        try await waitUntil { await client.stopCallCount >= 2 }

        await service.shutdown()
    }

    func testSubscriberAndRefreshArrivingDuringIdleStopWaitForTheSameLifecycleOperation() async throws {
        let stopGate = PollingAsyncGate()
        let client = PollingClientSpy(stopGate: stopGate)
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: false,
            stopClientWhenIdle: true,
            stopClientAfterRefresh: true
        )

        let firstConsumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount == 1 }
        await stopGate.waitUntilArrived()

        firstConsumer.cancel()
        await firstConsumer.value
        let refresh = Task { await service.refreshNow() }
        let secondConsumer = await makeConsumer(service: service)

        try await Task.sleep(for: .milliseconds(50))
        let listCallsWhileStopping = await client.listCallCount
        let stopCallsWhileStopping = await client.stopCallCount
        XCTAssertEqual(listCallsWhileStopping, 1)
        XCTAssertEqual(stopCallsWhileStopping, 1)

        await stopGate.release()
        await refresh.value
        await service.refreshNow()
        try await waitUntil { await client.listCallCount == 2 }

        secondConsumer.cancel()
        await secondConsumer.value
        await service.shutdown()
    }

    private func makeConsumer(
        service: CodexModelPollingService
    ) async -> Task<Void, Never> {
        let stream = await service.subscribe()
        return Task {
            for await _ in stream {}
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor PollingClientSpy: CodexModelListingClient {
    private(set) var listCallCount = 0
    private(set) var stopCallCount = 0
    private var processSnapshot: CodexAppServerClient.ProcessSnapshot?
    private let stopGate: PollingAsyncGate?

    init(stopGate: PollingAsyncGate? = nil) {
        self.stopGate = stopGate
    }

    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        listCallCount += 1
        processSnapshot = .init(pid: processSnapshot?.pid ?? 4242, appearsAlive: true)
        return [
            CodexAppServerClient.RemoteModel(
                id: "polling-test-model-\(listCallCount)",
                model: "polling-test-model-\(listCallCount)",
                displayName: "Polling Test Model \(listCallCount)",
                description: "",
                isDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            )
        ]
    }

    func stop() async {
        stopCallCount += 1
        if let stopGate {
            await stopGate.arriveAndWait()
        }
        if let snapshot = processSnapshot {
            processSnapshot = .init(pid: snapshot.pid, appearsAlive: false)
        }
    }

    func currentProcessSnapshot() async -> CodexAppServerClient.ProcessSnapshot? {
        processSnapshot
    }

    func setProcessSnapshot(_ snapshot: CodexAppServerClient.ProcessSnapshot?) {
        processSnapshot = snapshot
    }
}

private actor PollingAsyncGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
