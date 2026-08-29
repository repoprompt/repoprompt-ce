import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexModelPollingServiceTests: XCTestCase {
    func testLastSubscriberStopsOwnedClientAndLaterSubscriberRestartsPolling() async {
        let client = PollingClientSpy()
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true
        )

        let firstListCall = expectation(description: "first model list call")
        await client.fulfill(
            PollingExpectationSignal(firstListCall),
            whenListCallCountReaches: 1
        )
        let firstConsumer = await makeConsumer(service: service)
        await fulfillment(of: [firstListCall], timeout: 2)

        let firstStopCall = expectation(description: "first model client stop")
        await client.fulfill(
            PollingExpectationSignal(firstStopCall),
            whenStopCallCountReaches: 1
        )
        firstConsumer.cancel()
        await firstConsumer.value
        await fulfillment(of: [firstStopCall], timeout: 2)

        let secondListCall = expectation(description: "second model list call")
        await client.fulfill(
            PollingExpectationSignal(secondListCall),
            whenListCallCountReaches: 2
        )
        let secondConsumer = await makeConsumer(service: service)
        await fulfillment(of: [secondListCall], timeout: 2)

        let secondStopCall = expectation(description: "second model client stop")
        await client.fulfill(
            PollingExpectationSignal(secondStopCall),
            whenStopCallCountReaches: 2
        )
        secondConsumer.cancel()
        await secondConsumer.value
        await fulfillment(of: [secondStopCall], timeout: 2)

        await service.shutdown()
    }

    func testManagedSignOutSuspensionRestartsPollingAfterAuthenticationWithoutTerminalShutdown() async {
        let client = PollingClientSpy()
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true
        )
        let initialListCall = expectation(description: "initial model list call")
        await client.fulfill(
            PollingExpectationSignal(initialListCall),
            whenListCallCountReaches: 1
        )
        let consumer = await makeConsumer(service: service)
        await fulfillment(of: [initialListCall], timeout: 2)

        let suspensionStopCall = expectation(description: "managed sign-out stopped model client")
        await client.fulfill(
            PollingExpectationSignal(suspensionStopCall),
            whenStopCallCountReaches: 1
        )
        await service.suspendForManagedSignOut()
        await fulfillment(of: [suspensionStopCall], timeout: 2)
        let isSuspended = await service.test_isSuspendedForManagedSignOut()
        let subscriberCount = await service.test_subscriberCount()
        let callsAtSuspension = await client.listCallCount
        XCTAssertTrue(isSuspended)
        XCTAssertEqual(subscriberCount, 1)

        await service.refreshNow()
        let callsAfterSuspendedRefresh = await client.listCallCount
        XCTAssertEqual(callsAfterSuspendedRefresh, callsAtSuspension)

        let resumedListCall = expectation(description: "model polling resumed after authentication")
        await client.fulfill(
            PollingExpectationSignal(resumedListCall),
            whenListCallCountReaches: callsAtSuspension + 1
        )
        await service.resumeAfterManagedAuthentication()
        let remainsSuspended = await service.test_isSuspendedForManagedSignOut()
        XCTAssertFalse(remainsSuspended)
        await fulfillment(of: [resumedListCall], timeout: 2)

        consumer.cancel()
        await consumer.value
        await service.shutdown()
    }

    func testBufferedSnapshotIsRejectedAfterManagedLogoutInvalidatesItsAuthToken() async {
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
        let firstListCall = expectation(description: "snapshot model list call")
        await client.fulfill(
            PollingExpectationSignal(firstListCall),
            whenListCallCountReaches: 1
        )
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        await fulfillment(of: [firstListCall], timeout: 2)
        await service.refreshNow()
        let latestBeforeSuspend = await service.latestSnapshot()
        XCTAssertNotNil(latestBeforeSuspend)

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
}

private final class PollingExpectationSignal: @unchecked Sendable {
    let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private actor PollingClientSpy: CodexModelListingClient {
    private struct PendingSignal {
        let target: Int
        let signal: PollingExpectationSignal
    }

    private let models: [CodexAppServerClient.RemoteModel]
    private(set) var listCallCount = 0
    private(set) var stopCallCount = 0
    private var listCallSignals: [PendingSignal] = []
    private var stopCallSignals: [PendingSignal] = []

    init(models: [CodexAppServerClient.RemoteModel] = []) {
        self.models = models
    }

    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        listCallCount += 1
        Self.fulfillSatisfiedSignals(&listCallSignals, count: listCallCount)
        return models
    }

    func stop() async {
        stopCallCount += 1
        Self.fulfillSatisfiedSignals(&stopCallSignals, count: stopCallCount)
    }

    func fulfill(
        _ signal: PollingExpectationSignal,
        whenListCallCountReaches target: Int
    ) {
        Self.register(
            signal,
            target: target,
            currentCount: listCallCount,
            pending: &listCallSignals
        )
    }

    func fulfill(
        _ signal: PollingExpectationSignal,
        whenStopCallCountReaches target: Int
    ) {
        Self.register(
            signal,
            target: target,
            currentCount: stopCallCount,
            pending: &stopCallSignals
        )
    }

    private static func register(
        _ signal: PollingExpectationSignal,
        target: Int,
        currentCount: Int,
        pending: inout [PendingSignal]
    ) {
        if currentCount >= target {
            signal.fulfill()
        } else {
            pending.append(PendingSignal(target: target, signal: signal))
        }
    }

    private static func fulfillSatisfiedSignals(
        _ pending: inout [PendingSignal],
        count: Int
    ) {
        let satisfied = pending.filter { count >= $0.target }
        pending.removeAll { count >= $0.target }
        for entry in satisfied {
            entry.signal.fulfill()
        }
    }
}
