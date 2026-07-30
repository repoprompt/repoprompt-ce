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

    private func makeConsumer(
        service: CodexModelPollingService
    ) async -> Task<Void, Never> {
        let stream = await service.subscribe()
        return Task {
            for await _ in stream {}
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await AsyncTestWait.waitUntil(
            "Codex model polling condition",
            timeout: timeout,
            condition: condition
        )
    }
}

private actor PollingClientSpy: CodexModelListingClient {
    private(set) var listCallCount = 0
    private(set) var stopCallCount = 0

    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        listCallCount += 1
        return []
    }

    func stop() async {
        stopCallCount += 1
    }
}
