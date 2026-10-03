import Foundation
@testable import RepoPromptApp
import XCTest

/// Lifecycle contract for the Codex quota service.
///
/// The properties under test are the ones that keep an opt-in observability feature from
/// costing anything when it is off: no transport while disabled, no polling loop, reads
/// single-flighted, and publication equality-gated.
final class CodexProviderQuotaServiceTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fake transport

    private actor FakeQuotaClient: CodexQuotaAppServerClient {
        private(set) var startCount = 0
        private(set) var completedStartCount = 0
        private(set) var stopCount = 0
        private(set) var requestedMethods: [String] = []
        private var notificationContinuation: AsyncStream<CodexAppServerClient.Notification>.Continuation?
        private var response: [String: Any]
        private var failure: Error?
        /// Artificial latency so overlapping calls genuinely overlap.
        private var responseDelayNanos: UInt64 = 0
        private var holdStarts = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        init(response: [String: Any]) {
            self.response = response
        }

        func setResponse(_ response: [String: Any]) {
            self.response = response
        }

        func setFailure(_ failure: Error?) {
            self.failure = failure
        }

        func setResponseDelay(nanos: UInt64) {
            responseDelayNanos = nanos
        }

        func holdTransportStarts() {
            holdStarts = true
        }

        func releaseTransportStarts() {
            holdStarts = false
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }

        func startIfNeeded() async throws {
            startCount += 1
            if holdStarts {
                await withCheckedContinuation { startWaiters.append($0) }
            }
            completedStartCount += 1
            if let failure { throw failure }
        }

        func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
            let (stream, continuation) = AsyncStream<CodexAppServerClient.Notification>.makeStream()
            notificationContinuation = continuation
            return stream
        }

        func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
            requestedMethods.append(method)
            if responseDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: responseDelayNanos)
            }
            if let failure { throw failure }
            return response
        }

        func stop() async {
            stopCount += 1
        }

        func emit(_ notification: CodexAppServerClient.Notification) {
            notificationContinuation?.yield(notification)
        }

        func finishNotifications() {
            notificationContinuation?.finish()
            notificationContinuation = nil
        }

        func waitForSubscription(timeout: TimeInterval = 2) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if notificationContinuation != nil { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }
    }

    private func readResponse(primaryUsedPercent: Int) -> [String: Any] {
        [
            "accountId": "acct-123",
            "rateLimits": [
                "limitId": "codex",
                "limitName": "Codex",
                "primary": ["usedPercent": primaryUsedPercent, "windowDurationMins": 300]
            ]
        ]
    }

    private func makeService(
        client: FakeQuotaClient,
        accountID: String? = "acct-123"
    ) -> (CodexProviderQuotaService, @Sendable () -> Int) {
        let factoryCount = FactoryCounter()
        let service = CodexProviderQuotaService(
            clientFactory: {
                factoryCount.increment()
                return client
            },
            accountIDProvider: { accountID },
            requestTimeout: 5,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return (service, { factoryCount.value })
    }

    private final class FactoryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            value = value.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    /// Polls a condition instead of sleeping a fixed duration for a positive assertion.
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: - Disabled means genuinely inert

    func testDisabledServiceCreatesNoClientProcessOrSubscription() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let (service, factoryCount) = makeService(client: client)

        // Subscribing while disabled must not start anything.
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first, .disabled)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(factoryCount(), 0, "no client is constructed while opted out")
        let startCount = await client.startCount
        let methods = await client.requestedMethods
        XCTAssertEqual(startCount, 0, "no process is started")
        XCTAssertEqual(methods, [], "no read is issued")
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport)
    }

    func testDisablingTearsDownTransportAndDiscardsSnapshot() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded, "expected a loaded snapshot")

        await service.setEnabled(false)
        let status = await service.test_status()
        XCTAssertEqual(status, .disabled)
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport, "the client is released on opt-out")
        let stopped = await waitUntil { await client.stopCount >= 1 }
        XCTAssertTrue(stopped, "the owned process is stopped")
    }

    // MARK: - Reads

    func testEnabledServiceIssuesExactlyOnePrimingReadAndDoesNotPoll() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream

        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        // There is no timer: waiting must not produce further reads.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let methods = await client.requestedMethods
        XCTAssertEqual(methods, ["account/rateLimits/read"], "primed once, never polled")
    }

    func testConcurrentRefreshesAreSingleFlighted() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        await client.setResponseDelay(nanos: 200_000_000)
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        // Let the priming read settle so the overlap under test is refresh-vs-refresh.
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)
        let primingReads = await client.requestedMethods.count

        async let first: Void = service.refreshNow()
        async let second: Void = service.refreshNow()
        async let third: Void = service.refreshNow()
        _ = await (first, second, third)

        let methods = await client.requestedMethods
        XCTAssertEqual(
            methods.count - primingReads,
            1,
            "overlapping refreshes coalesce into one read"
        )
    }

    func testEnablingWithoutAnObserverCreatesNoTransport() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, factoryCount) = makeService(client: client)

        // Enabling is an intent, not an activation: the transport starts only once a surface
        // actually observes.
        await service.setEnabled(true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(factoryCount(), 0)
        let startCount = await client.startCount
        XCTAssertEqual(startCount, 0)
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport)
        let status = await service.test_status()
        XCTAssertEqual(status, .idle, "enabled but unobserved reports idle, never a zero")
    }

    // MARK: - Unobserved refresh must stay inert (P1)

    func testRefreshWithoutSubscriberCreatesNoClientReadOrProcess() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, factoryCount) = makeService(client: client)

        await service.setEnabled(true)
        // Enabled, but nothing is observing: a manual refresh must not manufacture a
        // transport that no teardown path will ever reclaim.
        await service.refreshNow()

        XCTAssertEqual(factoryCount(), 0, "no client is constructed for an unobserved refresh")
        let startCount = await client.startCount
        let methods = await client.requestedMethods
        XCTAssertEqual(startCount, 0, "no process is started")
        XCTAssertEqual(methods, [], "no read is issued")
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport, "nothing is retained")
    }

    func testRefreshAfterLastSubscriberLeavesCreatesNoTransport() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        var stream: AsyncStream<CodexQuotaStatus>? = await service.subscribe()
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        // Drop the subscriber, which tears the transport down.
        stream = nil
        _ = stream
        let tornDown = await waitUntil { await service.test_subscriberCount() == 0 }
        XCTAssertTrue(tornDown)
        let readsBefore = await client.requestedMethods.count

        await service.refreshNow()

        let readsAfter = await client.requestedMethods.count
        XCTAssertEqual(readsAfter, readsBefore, "a refresh raced past teardown spends no read")
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport, "and re-installs no client")
    }

    func testRefreshInterleavedWithDeactivationLeavesNoRunningClient() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        // Hold the read open so teardown lands while it is in flight.
        await client.setResponseDelay(nanos: 300_000_000)
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        var stream: AsyncStream<CodexQuotaStatus>? = await service.subscribe()
        _ = await waitUntil { await service.test_hasTransport() }

        async let refresh: Void = service.refreshNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Surface disappears mid-read.
        stream = nil
        _ = stream
        await refresh

        let tornDown = await waitUntil { await service.test_hasTransport() == false }
        XCTAssertTrue(tornDown, "no client survives the interleave")
        let stopped = await waitUntil { await client.stopCount >= 1 }
        XCTAssertTrue(stopped, "the owned process is stopped")
    }

    func testRetiredPrimingReadDoesNotRequestAfterTransportStartResumes() async {
        let retiredClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        await retiredClient.holdTransportStarts()
        let replacementClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 20))
        let clients = ClientSequence([retiredClient, replacementClient])
        let service = CodexProviderQuotaService(
            clientFactory: { clients.next() },
            accountIDProvider: { "acct-123" },
            requestTimeout: 5
        )

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let bothStarted = await waitUntil { await retiredClient.startCount == 2 }
        XCTAssertTrue(bothStarted, "the notification loop and priming read reached transport startup")

        await service.setEnabled(false)
        await service.setEnabled(true)
        await retiredClient.releaseTransportStarts()

        let oldStartsFinished = await waitUntil { await retiredClient.completedStartCount == 2 }
        XCTAssertTrue(oldStartsFinished)
        let replacementLoaded = await waitUntil {
            if case let .loaded(snapshot) = await service.test_status() {
                return snapshot.buckets.first?.window(role: "primary")?.percent?.rawValue == 20
            }
            return false
        }
        XCTAssertTrue(replacementLoaded, "the new generation performs its own priming read")
        let staleRequests = await retiredClient.requestedMethods
        XCTAssertEqual(staleRequests, [], "a cancelled old startup must not spend a read after reactivation")
    }

    // MARK: - In-flight generation fence

    func testStaleReadCompletionDoesNotClearANewerSingleFlightRegistration() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        // Long enough that read B is still registered when read A's frame resumes.
        await client.setResponseDelay(nanos: 400_000_000)
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        var streamA: AsyncStream<CodexQuotaStatus>? = await service.subscribe()
        _ = await waitUntil { await service.test_hasTransport() }

        // Read A is in flight when the feature is switched off, which cancels it and clears
        // the registration.
        async let readA: Void = service.refreshNow()
        try? await Task.sleep(nanoseconds: 60_000_000)
        let generationBefore = await service.test_transportGeneration()
        await service.setEnabled(false)
        streamA = nil
        _ = streamA

        // Restart: read B belongs to the new generation and registers itself.
        await service.setEnabled(true)
        let generationAfter = await service.test_transportGeneration()
        XCTAssertGreaterThan(generationAfter, generationBefore, "teardown fenced the old transport")
        let streamB = await service.subscribe()
        _ = streamB
        let bRegistered = await waitUntil { await service.test_hasInFlightRead() }
        XCTAssertTrue(bRegistered, "the restarted transport has a read in flight")

        // A's frame now resumes. It must not clear B's registration.
        await readA

        let stillRegistered = await service.test_hasInFlightRead()
        XCTAssertTrue(
            stillRegistered,
            "a stale read's completion must not unfence the newer read's single-flight guard"
        )
    }

    func testReadCompletingAfterDisableDoesNotPublish() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 77))
        await client.setResponseDelay(nanos: 250_000_000)
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        var stream: AsyncStream<CodexQuotaStatus>? = await service.subscribe()
        _ = await waitUntil { await service.test_hasTransport() }

        async let read: Void = service.refreshNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await service.setEnabled(false)
        stream = nil
        _ = stream
        await read

        let status = await service.test_status()
        XCTAssertEqual(status, .disabled, "a read that outlived its generation publishes nothing")
    }

    func testForegroundRefreshIsBoundedByAMinimumGap() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        // The injected clock never advances, so the gap has not elapsed.
        await service.refreshOnForeground()
        let methods = await client.requestedMethods
        XCTAssertEqual(methods.count, 1, "a foreground trigger inside the gap spends no read")
    }

    // MARK: - Notifications

    func testAccountNotificationIsDeliveredWithoutAnyThreadAndMergesSparsely() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream

        let subscribed = await client.waitForSubscription()
        XCTAssertTrue(subscribed)
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        // Account-scoped notification: no thread exists, and none is required.
        await client.emit(CodexAppServerClient.Notification(
            method: "account/rateLimits/updated",
            params: [
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "primary": .object(["usedPercent": .number(88)])
                ])
            ]
        ))

        let updated = await waitUntil {
            if case let .loaded(snapshot) = await service.test_status() {
                return snapshot.buckets.first?.window(role: "primary")?.percent?.rawValue == 88
            }
            return false
        }
        XCTAssertTrue(updated, "account notification reached the service without a bound thread")

        guard case let .loaded(snapshot) = await service.test_status() else {
            return XCTFail("expected loaded")
        }
        // The sparse notification carried no label or duration; both must be retained.
        XCTAssertEqual(snapshot.buckets.first?.displayLabel, "Codex")
        XCTAssertEqual(snapshot.buckets.first?.window(role: "primary")?.windowDuration, 300 * 60)
    }

    func testUnrelatedNotificationsAreIgnored() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        _ = await client.waitForSubscription()
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)
        let before = await service.test_status()

        await client.emit(CodexAppServerClient.Notification(
            method: "thread/tokenUsage/updated",
            params: ["threadId": .string("t-1")]
        ))
        try? await Task.sleep(nanoseconds: 150_000_000)

        let after = await service.test_status()
        XCTAssertEqual(before, after, "a thread-scoped notification must not disturb account quota")
    }

    func testEndedNotificationStreamDropsClientAndExplicitRefreshCreatesFreshTransport() async {
        let firstClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let secondClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 20))
        let clients = ClientSequence([firstClient, secondClient])
        let service = CodexProviderQuotaService(
            clientFactory: { clients.next() },
            accountIDProvider: { "acct-123" },
            requestTimeout: 5,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let firstSubscribed = await firstClient.waitForSubscription()
        XCTAssertTrue(firstSubscribed)
        let firstLoaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(firstLoaded)

        await firstClient.finishNotifications()
        let firstStopped = await waitUntil { await firstClient.stopCount >= 1 }
        XCTAssertTrue(firstStopped)
        let hasTransport = await service.test_hasTransport()
        XCTAssertFalse(hasTransport, "ended stream releases the sticky client")

        await service.refreshNow()
        let secondSubscribed = await secondClient.waitForSubscription()
        XCTAssertTrue(secondSubscribed)
        XCTAssertEqual(clients.value, 2, "recovery creates one fresh isolated client")
    }

    func testForegroundRecoveryAfterEndedStreamRestoresPushObservation() async {
        let firstClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 10))
        let secondClient = FakeQuotaClient(response: readResponse(primaryUsedPercent: 20))
        let clients = ClientSequence([firstClient, secondClient])
        let clock = TestClock(observedAt)
        let service = CodexProviderQuotaService(
            clientFactory: { clients.next() },
            accountIDProvider: { "acct-123" },
            requestTimeout: 5,
            now: { clock.now }
        )

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let firstSubscribed = await firstClient.waitForSubscription()
        XCTAssertTrue(firstSubscribed)
        let firstLoaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(firstLoaded)

        await firstClient.finishNotifications()
        let discarded = await waitUntil { await service.test_hasTransport() == false }
        XCTAssertTrue(discarded)

        clock.advance(by: CodexProviderQuotaService.foregroundRefreshMinimumGap + 1)
        await service.refreshOnForeground()

        let secondSubscribed = await secondClient.waitForSubscription()
        XCTAssertTrue(secondSubscribed, "foreground recovery restores the push stream")
        await secondClient.emit(CodexAppServerClient.Notification(
            method: "account/rateLimits/updated",
            params: [
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "primary": .object(["usedPercent": .number(88)])
                ])
            ]
        ))

        let pushApplied = await waitUntil {
            if case let .loaded(snapshot) = await service.test_status() {
                return snapshot.buckets.first?.window(role: "primary")?.percent?.rawValue == 88
            }
            return false
        }
        XCTAssertTrue(pushApplied, "the replacement client's notifications remain live")
        XCTAssertEqual(clients.value, 2)
    }

    // MARK: - Equality gate

    func testIdenticalSnapshotDoesNotRepublish() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()

        let collector = StatusCollector()
        let task = Task {
            for await status in stream {
                await collector.append(status)
            }
        }

        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        // Re-reading identical values must publish nothing new.
        await service.refreshNow()
        await service.refreshNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let loadedCount = await collector.loadedCount()
        XCTAssertEqual(loadedCount, 1, "an unchanged merged snapshot publishes nothing")
    }

    private actor StatusCollector {
        private var statuses: [CodexQuotaStatus] = []
        func append(_ status: CodexQuotaStatus) {
            statuses.append(status)
        }

        func loadedCount() -> Int {
            statuses.count(where: { if case .loaded = $0 { true } else { false } })
        }
    }

    private final class ClientSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var clients: [FakeQuotaClient]
        private var index = 0

        init(_ clients: [FakeQuotaClient]) {
            self.clients = clients
        }

        func next() -> FakeQuotaClient {
            lock.lock()
            defer { lock.unlock() }
            let client = clients[min(index, clients.count - 1)]
            index += 1
            return client
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return index
        }
    }

    // MARK: - Sign-out

    func testSignOutDiscardsSnapshotAndStopsTransport() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let loaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(loaded)

        await service.handleSignOutOrAccountChange()

        let status = await service.test_status()
        XCTAssertEqual(status, .idle, "the prior account's snapshot is discarded, not migrated")
        let stopped = await waitUntil { await client.stopCount >= 1 }
        XCTAssertTrue(stopped)
    }

    func testResumeAfterFailedSignOutRestartsOnlyForLiveSubscriber() async {
        let client = FakeQuotaClient(response: readResponse(primaryUsedPercent: 62))
        let (service, factoryCount) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream
        let firstLoaded = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(firstLoaded)

        await service.handleSignOutOrAccountChange()
        await service.resumeAfterManagedAuthentication()

        let resumed = await waitUntil { if case .loaded = await service.test_status() { true } else { false } }
        XCTAssertTrue(resumed)
        XCTAssertEqual(factoryCount(), 2, "resume recreates the isolated client for the live observer")
    }

    func testTransportFailureWithoutPriorSnapshotReportsUserSafeReason() async {
        struct Boom: Error { let accountEmail = "user@example.com" }
        let client = FakeQuotaClient(response: [:])
        await client.setFailure(Boom())
        let (service, _) = makeService(client: client)

        await service.setEnabled(true)
        let stream = await service.subscribe()
        _ = stream

        let failed = await waitUntil {
            if case .unavailable = await service.test_status() { true } else { false }
        }
        XCTAssertTrue(failed)

        guard case let .unavailable(reason) = await service.test_status() else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.contains("user@example.com"), "failure text never leaks account values")
        XCTAssertEqual(reason, "Usage limits are not available right now.")
    }
}
