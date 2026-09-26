import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

/// View-lifetime behaviour of the MainActor quota store.
///
/// The store is the only quota type on the main actor, so the contract under test is about
/// lifetime and publication discipline: nothing starts while opted out, everything
/// view-scoped stops on disappear, and freshness ages without spending a provider read.
@MainActor
final class CodexQuotaUIStoreTests: XCTestCase {
    // MARK: - Test doubles

    private actor FakeQuotaClient: CodexQuotaAppServerClient {
        private(set) var requestedMethods: [String] = []
        private var notificationContinuation: AsyncStream<CodexAppServerClient.Notification>.Continuation?
        private let response: [String: Any]

        init(response: [String: Any]) {
            self.response = response
        }

        func startIfNeeded() async throws {}

        func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
            let (stream, continuation) = AsyncStream<CodexAppServerClient.Notification>.makeStream()
            notificationContinuation = continuation
            return stream
        }

        func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
            requestedMethods.append(method)
            return response
        }

        func stop() async {}

        func readCount() -> Int {
            requestedMethods.count
        }
    }

    /// Test clock the store reads through its injected `now` closure.
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) {
            current = start
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    private final class SettingsFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) {
            self.value = value
        }

        var current: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func readResponse(usedPercent: Int, windowDurationMins: Int = 300) -> [String: Any] {
        [
            "accountId": "acct-123",
            "rateLimits": [
                "limitId": "codex",
                "limitName": "Codex",
                "primary": ["usedPercent": usedPercent, "windowDurationMins": windowDurationMins]
            ]
        ]
    }

    private func makeStore(
        enabled: Bool,
        clock: MutableClock,
        flag: SettingsFlag,
        client: FakeQuotaClient,
        freshnessInterval: TimeInterval = 0
    ) -> (CodexQuotaUIStore, CodexProviderQuotaService) {
        _ = enabled
        let service = CodexProviderQuotaService(
            clientFactory: { client },
            accountIDProvider: { "acct-123" },
            requestTimeout: 5,
            now: { clock.now }
        )
        let store = CodexQuotaUIStore(
            service: service,
            settingsProvider: { flag.current },
            now: { clock.now },
            freshnessInterval: freshnessInterval
        )
        return (store, service)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: - Activate / deactivate

    func testActivateWhileOptedOutStartsNothing() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(false)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: false, clock: clock, flag: flag, client: client)

        store.activate()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(store.state, .hidden)
        let subscribers = await service.test_subscriberCount()
        XCTAssertEqual(subscribers, 0, "an opted-out surface never subscribes")
        let reads = await client.readCount()
        XCTAssertEqual(reads, 0, "and never spends a read")
    }

    func testEnablingWhileSurfaceIsInactiveStartsNothing() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: true, clock: clock, flag: flag, client: client)

        // Models an app_settings write while the Settings pane is closed. Persisted intent
        // may change, but surface observation remains the activation boundary.
        store.setEnabled(true)
        let enabled = await waitUntil { await service.test_status() == .idle }
        XCTAssertTrue(enabled)

        XCTAssertEqual(store.state, .hidden)
        let subscribers = await service.test_subscriberCount()
        let hasTransport = await service.test_hasTransport()
        let reads = await client.readCount()
        XCTAssertEqual(subscribers, 0)
        XCTAssertFalse(hasTransport)
        XCTAssertEqual(reads, 0)
    }

    func testActivateSubscribesAndDeactivateReleases() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: true, clock: clock, flag: flag, client: client)

        store.activate()
        let subscribed = await waitUntil { await service.test_subscriberCount() == 1 }
        XCTAssertTrue(subscribed, "an enabled surface observes")

        let loaded = await waitUntil {
            if case .loaded = store.state { true } else { false }
        }
        XCTAssertTrue(loaded, "and projects a snapshot")

        store.deactivate()
        let released = await waitUntil { await service.test_subscriberCount() == 0 }
        XCTAssertTrue(released, "disappearing releases the subscription")
        let tornDown = await waitUntil { await service.test_hasTransport() == false }
        XCTAssertTrue(tornDown, "which lets the service reclaim its transport")
    }

    func testActivateDeactivateActivateReSubscribesExactlyOnce() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: true, clock: clock, flag: flag, client: client)

        store.activate()
        _ = await waitUntil { await service.test_subscriberCount() == 1 }
        store.deactivate()
        _ = await waitUntil { await service.test_subscriberCount() == 0 }
        store.activate()

        let resubscribed = await waitUntil { await service.test_subscriberCount() == 1 }
        XCTAssertTrue(resubscribed, "reappearing observes again")

        // Repeated activate must not stack observers.
        store.activate()
        try? await Task.sleep(nanoseconds: 120_000_000)
        let subscribers = await service.test_subscriberCount()
        XCTAssertEqual(subscribers, 1, "activate is idempotent")
    }

    func testDisablingViaSettingsTearsDownWhileTheSurfaceStaysVisible() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: true, clock: clock, flag: flag, client: client)

        store.activate()
        _ = await waitUntil { await service.test_subscriberCount() == 1 }

        // The pane is still on screen; only the setting changed.
        flag.set(false)
        store.setEnabled(false)

        XCTAssertEqual(store.state, .hidden)
        let tornDown = await waitUntil { await service.test_hasTransport() == false }
        XCTAssertTrue(tornDown, "disabling stops the process without waiting for the pane to close")
        let released = await waitUntil { await service.test_subscriberCount() == 0 }
        XCTAssertTrue(released)
    }

    // MARK: - Freshness revalidation

    func testFreshnessRevalidationAgesWordingWithoutSpendingARead() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        // Fast interval so the test does not wait a real minute.
        let (store, service) = makeStore(
            enabled: true,
            clock: clock,
            flag: flag,
            client: client,
            freshnessInterval: 0.05
        )

        store.activate()
        let loaded = await waitUntil {
            if case .loaded = store.state { true } else { false }
        }
        XCTAssertTrue(loaded)
        let readsAfterPriming = await client.readCount()

        guard case let .loaded(_, freshFootnote, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertNil(freshFootnote, "a fresh reading carries no age caveat")

        // Age the clock past the 5-hour window's horizon without any provider event.
        clock.advance(by: 3 * 3600)

        let aged = await waitUntil {
            if case let .loaded(_, footnote, _) = store.state { return footnote != nil }
            return false
        }
        XCTAssertTrue(aged, "wording ages on its own")

        guard case let .loaded(_, staleFootnote, _) = store.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(try? XCTUnwrap(staleFootnote), "Last seen 3 hours ago — may be out of date")

        let readsAfterAging = await client.readCount()
        XCTAssertEqual(readsAfterAging, readsAfterPriming, "revalidation issues no provider read")
        _ = service
    }

    func testFreshnessRevalidationIsEqualityGated() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, _) = makeStore(
            enabled: true,
            clock: clock,
            flag: flag,
            client: client,
            freshnessInterval: 0.05
        )

        store.activate()
        let loaded = await waitUntil {
            if case .loaded = store.state { true } else { false }
        }
        XCTAssertTrue(loaded)

        var publications = 0
        let cancellable = store.$state.sink { _ in publications += 1 }
        defer { cancellable.cancel() }

        // The clock does not move, so every revalidation projects an identical value.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThanOrEqual(
            publications,
            1,
            "an unchanged projection must not republish and invalidate the view"
        )
    }

    func testFreshnessRevalidationStopsOnDeactivate() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, _) = makeStore(
            enabled: true,
            clock: clock,
            flag: flag,
            client: client,
            freshnessInterval: 0.05
        )

        store.activate()
        let loaded = await waitUntil {
            if case .loaded = store.state { true } else { false }
        }
        XCTAssertTrue(loaded)

        store.deactivate()
        let stateAtDeactivate = store.state
        clock.advance(by: 3 * 3600)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(
            store.state,
            stateAtDeactivate,
            "no view-lifetime work survives disappear"
        )
    }

    // MARK: - Refresh latch

    func testRefreshIsIgnoredWhileHidden() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(false)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, _) = makeStore(enabled: false, clock: clock, flag: flag, client: client)

        store.activate()
        store.refresh()

        XCTAssertFalse(store.isRefreshing, "a hidden surface never latches")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let reads = await client.readCount()
        XCTAssertEqual(reads, 0)
    }

    func testDeactivateReleasesTheRefreshLatch() async {
        let clock = MutableClock(start)
        let flag = SettingsFlag(true)
        let client = FakeQuotaClient(response: readResponse(usedPercent: 62))
        let (store, service) = makeStore(enabled: true, clock: clock, flag: flag, client: client)

        store.activate()
        _ = await waitUntil { await service.test_subscriberCount() == 1 }
        let loaded = await waitUntil {
            if case .loaded = store.state { true } else { false }
        }
        XCTAssertTrue(loaded)

        store.refresh()
        XCTAssertTrue(store.isRefreshing, "a manual refresh latches the spinner")

        store.deactivate()
        XCTAssertFalse(
            store.isRefreshing,
            "a surface that disappears mid-refresh must not come back stuck in a spinner"
        )
    }
}
