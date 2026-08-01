@testable import RepoPromptApp
import XCTest

final class CodexModelPollingServiceTests: XCTestCase {
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

    func testManagedSignOutSuspensionRestartsPollingAfterAuthenticationWithoutTerminalShutdown() async throws {
        let client = PollingClientSpy()
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true
        )
        let consumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 1 }

        await service.suspendForManagedSignOut()
        let isSuspended = await service.test_isSuspendedForManagedSignOut()
        let subscriberCount = await service.test_subscriberCount()
        let callsAtSuspension = await client.listCallCount
        let stopCallsAtSuspension = await client.stopCallCount
        XCTAssertTrue(isSuspended)
        XCTAssertEqual(subscriberCount, 1)
        XCTAssertGreaterThanOrEqual(stopCallsAtSuspension, 1)

        await service.refreshNow()
        let callsAfterSuspendedRefresh = await client.listCallCount
        XCTAssertEqual(callsAfterSuspendedRefresh, callsAtSuspension)

        await service.resumeAfterManagedAuthentication()
        let remainsSuspended = await service.test_isSuspendedForManagedSignOut()
        XCTAssertFalse(remainsSuspended)
        try await waitUntil { await client.listCallCount > callsAtSuspension }

        consumer.cancel()
        await consumer.value
        await service.shutdown()
    }

    func testBufferedSnapshotIsRejectedAfterManagedLogoutInvalidatesItsAuthToken() async throws {
        let model = CodexAppServerClient.RemoteModel(
            id: "stale-\(UUID().uuidString)",
            model: "stale-model",
            displayName: "Stale Model",
            description: "Test model",
            isDefault: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
        let client = PollingClientSpy(models: [model])
        let service = CodexModelPollingService(client: client)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        try await waitUntil { await service.latestSnapshot() != nil }

        let fence = CodexManagedSessionFence.shared
        let logoutToken = await MainActor.run { fence.beginLogout() }
        await service.suspendForManagedSignOut()

        let bufferedSnapshot = await iterator.next()
        let isAuthorized = await MainActor.run {
            bufferedSnapshot?.isAuthorizedForPublication ?? true
        }
        XCTAssertFalse(isAuthorized)
        let latestAfterSuspend = await service.latestSnapshot()
        XCTAssertNil(latestAfterSuspend)

        await MainActor.run {
            fence.finishLogout(token: logoutToken, succeeded: false)
        }
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
    private let models: [CodexAppServerClient.RemoteModel]
    private(set) var listCallCount = 0
    private(set) var stopCallCount = 0

    init(models: [CodexAppServerClient.RemoteModel] = []) {
        self.models = models
    }

    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        listCallCount += 1
        return models
    }

    func stop() async {
        stopCallCount += 1
    }
}
