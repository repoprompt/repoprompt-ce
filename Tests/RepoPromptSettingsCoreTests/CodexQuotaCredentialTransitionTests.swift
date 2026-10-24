import Foundation
@testable import RepoPromptProviderQuota
@testable import RepoPromptSettingsCore
import XCTest

/// Credential transitions for the Codex usage transport.
///
/// The fake models the upstream property that matters: an app-server process reads managed
/// credentials once when it starts and does not pick up a sign-in or restored access that
/// happens in another process. Recovery must therefore come from replacing the owned
/// transport, never from asking the same process again.
@MainActor
final class CodexQuotaCredentialTransitionTests: XCTestCase {
    // MARK: - Test doubles

    private struct Credential: Equatable {
        let accountID: String
        let token: Int
        let usedPercent: Int
    }

    private struct AuthenticationRequired: Error {}

    /// The shared on-disk credential store all processes read from.
    private final class CredentialStore: @unchecked Sendable {
        private let lock = NSLock()
        private var credential: Credential?
        private var revokedTokens: Set<Int> = []

        var current: Credential? {
            lock.lock()
            defer { lock.unlock() }
            return credential
        }

        func set(_ newValue: Credential?) {
            lock.lock()
            credential = newValue
            lock.unlock()
        }

        func revoke(token: Int) {
            lock.lock()
            revokedTokens.insert(token)
            lock.unlock()
        }

        func isRevoked(_ token: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return revokedTokens.contains(token)
        }
    }

    /// Holds reads so a test can sample state after a transition and before the replacement
    /// transport answers, without depending on task scheduling.
    private actor ReadGate {
        private var isHeld = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func hold() {
            isHeld = true
        }

        func release() {
            isHeld = false
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }

        func pass() async {
            guard isHeld else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// One app-server process: captures the store's credential at start, never reloads.
    private actor CapturingClient: CodexQuotaAppServerClient {
        private let store: CredentialStore
        private let gate: ReadGate
        private var started = false
        private var captured: Credential?
        private var notificationContinuation: AsyncStream<CodexQuotaNotification>.Continuation?

        init(store: CredentialStore, gate: ReadGate) {
            self.store = store
            self.gate = gate
        }

        func startIfNeeded() async throws {
            guard !started else { return }
            started = true
            captured = store.current
        }

        func subscribeNotifications() async -> AsyncStream<CodexQuotaNotification> {
            // Held open: an ended stream would retire the transport and mask a stale process.
            let (stream, continuation) = AsyncStream<CodexQuotaNotification>.makeStream()
            notificationContinuation = continuation
            return stream
        }

        func request(method _: String, params _: [String: CodexJSONValue]?, timeout _: TimeInterval?) async throws -> [String: CodexJSONValue] {
            await gate.pass()
            guard let captured, !store.isRevoked(captured.token) else { throw AuthenticationRequired() }
            return [
                "accountId": .string(captured.accountID),
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "limitName": .string("Codex"),
                    "primary": .object(["usedPercent": .number(Double(captured.usedPercent)), "windowDurationMins": .number(300)])
                ])
            ]
        }

        func stop() async {
            notificationContinuation?.finish()
            notificationContinuation = nil
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_700_000_000)

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

    private struct Harness {
        let credentials: CredentialStore
        let gate: ReadGate
        let transports: Counter
        let clock: MutableClock
        let service: CodexProviderQuotaService
        let store: ProviderQuotaUIStore
    }

    private func makeHarness(initial: Credential?) -> Harness {
        let credentials = CredentialStore()
        credentials.set(initial)
        let gate = ReadGate()
        let transports = Counter()
        let clock = MutableClock()
        let service = CodexProviderQuotaService(
            clientFactory: {
                transports.increment()
                return CapturingClient(store: credentials, gate: gate)
            },
            accountIDProvider: { credentials.current?.accountID },
            requestTimeout: 5,
            now: { clock.now }
        )
        let store = ProviderQuotaUIStore(
            service: service,
            settingsProvider: { true },
            now: { clock.now },
            freshnessInterval: 0
        )
        return Harness(credentials: credentials, gate: gate, transports: transports, clock: clock, service: service, store: store)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// Account and rounded percent of a loaded (or failed-with-previous) status.
    private func reading(_ status: ProviderQuotaStatus, now: Date) -> (account: String?, percent: Int?)? {
        let snapshot: ProviderQuotaSnapshot
        switch status {
        case let .loaded(value): snapshot = value
        case let .failed(_, previous?): snapshot = previous
        default: return nil
        }
        return (snapshot.accountKey.opaqueAccountID, ProviderQuotaIndicatorState.project(snapshot, now: now)?.usedPercent)
    }

    private func waitForLoaded(_ harness: Harness, account: String, percent: Int) async -> Bool {
        await waitUntil {
            let status = await harness.service.test_status()
            guard case .loaded = status, let value = reading(status, now: harness.clock.now) else { return false }
            return value.account == account && value.percent == percent
        }
    }

    // MARK: - Tests

    func testLoggedOutStartShowsUsageAfterAuthoritySignInWithoutRefreshOrSettings() async {
        let harness = makeHarness(initial: nil)
        await harness.service.setEnabled(true)
        harness.store.activate()

        let unavailable = await waitUntil {
            if case .unavailable = await harness.service.test_status() { true } else { false }
        }
        XCTAssertTrue(unavailable)
        XCTAssertNil(harness.store.indicatorState, "nothing was ever observed, so the pill stays hidden")

        harness.credentials.set(Credential(accountID: "acct-123", token: 1, usedPercent: 62))
        // The pre-existing resume hook cannot replace a live process that cached no credentials.
        await harness.service.resumeAfterManagedAuthentication()
        let stillUnavailable = await harness.service.test_status()
        guard case .unavailable = stillUnavailable else {
            return XCTFail("resume alone must not be what recovers: \(stillUnavailable)")
        }
        XCTAssertEqual(harness.transports.value, 1)

        await harness.service.handleManagedAuthenticationEstablished(accountID: "acct-123", authGeneration: 0)

        let loaded = await waitForLoaded(harness, account: "acct-123", percent: 62)
        XCTAssertTrue(loaded, "the authority transition alone restores usage")
        XCTAssertEqual(harness.transports.value, 2, "a fresh transport reads the new credentials")
        let shown = await waitUntil { harness.store.indicatorState?.usedPercent == 62 }
        XCTAssertTrue(shown, "the pill appears without a Settings toggle or relaunch")
        harness.store.deactivate()
        await harness.service.shutdown()
    }

    func testExplicitRefreshAfterFailedReadReplacesTransportButAutomaticRefreshDoesNot() async {
        let harness = makeHarness(initial: Credential(accountID: "acct-123", token: 1, usedPercent: 40))
        await harness.service.setEnabled(true)
        let stream = await harness.service.subscribe()
        let firstLoaded = await waitForLoaded(harness, account: "acct-123", percent: 40)
        XCTAssertTrue(firstLoaded)

        // Access revoked upstream: the denial is expected and keeps the previous value.
        harness.credentials.revoke(token: 1)
        await harness.service.refreshNow()
        let failed = await harness.service.test_status()
        XCTAssertEqual(reading(failed, now: harness.clock.now)?.percent, 40)
        guard case .failed = failed else { return XCTFail("expected a failed refresh with the previous value: \(failed)") }
        XCTAssertEqual(harness.transports.value, 1, "the first failure is reported on the existing transport")

        // Access restored / fresh sign-in written by another process.
        harness.credentials.set(Credential(accountID: "acct-123", token: 2, usedPercent: 55))
        harness.clock.advance(by: CodexProviderQuotaService.foregroundRefreshMinimumGap + 1)
        await harness.service.refreshAutomatically(didStart: nil)
        let afterAutomatic = await harness.service.test_status()
        guard case .failed = afterAutomatic else { return XCTFail("automatic refresh must reuse the transport: \(afterAutomatic)") }
        XCTAssertEqual(harness.transports.value, 1, "automatic refresh never replaces the transport")

        let readsBefore = await harness.service.test_readCount()
        await harness.service.refreshNow()

        let recovered = await waitForLoaded(harness, account: "acct-123", percent: 55)
        XCTAssertTrue(recovered, "explicit Refresh recovers after a failed read")
        XCTAssertEqual(harness.transports.value, 2)
        let readsAfter = await harness.service.test_readCount()
        XCTAssertEqual(readsAfter - readsBefore, 1, "the replacement transport performs one read, not a priming duplicate")
        await harness.service.shutdown()
        withExtendedLifetime(stream) {}
    }

    func testIndicatorStaysVisibleThroughFailedRefreshRecoveryAndSignOut() async {
        let harness = makeHarness(initial: Credential(accountID: "acct-123", token: 1, usedPercent: 40))
        await harness.service.setEnabled(true)
        harness.store.activate()
        let shown = await waitUntil { harness.store.indicatorState?.usedPercent == 40 }
        XCTAssertTrue(shown)

        harness.credentials.revoke(token: 1)
        harness.store.refresh()
        let failedInPlace = await waitUntil {
            !harness.store.isRefreshing && harness.store.indicatorState?.refreshFailed == true
        }
        XCTAssertTrue(failedInPlace)
        XCTAssertEqual(harness.store.indicatorState?.usedPercent, 40, "a denied refresh keeps the last value visible")

        harness.credentials.set(Credential(accountID: "acct-123", token: 2, usedPercent: 55))
        harness.store.refresh()
        let refreshed = await waitUntil {
            !harness.store.isRefreshing && harness.store.indicatorState?.usedPercent == 55
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(harness.store.indicatorState?.refreshFailed, false)

        await harness.service.handleSignOutOrAccountChange(authGeneration: 0)
        let neutral = await waitUntil { harness.store.indicatorState == .unavailable }
        XCTAssertTrue(neutral, "sign-out clears the reading but leaves the neutral pill, not nothing")
        harness.store.deactivate()
        await harness.service.shutdown()
    }

    func testTransitionDiscardsReadingsFromAnotherOrUnknownAccount() async {
        for (label, establishedAccount) in [("different account", Optional("acct-B")), ("unknown account", nil)] {
            let harness = makeHarness(initial: Credential(accountID: "acct-A", token: 1, usedPercent: 30))
            await harness.service.setEnabled(true)
            let stream = await harness.service.subscribe()
            let loaded = await waitForLoaded(harness, account: "acct-A", percent: 30)
            XCTAssertTrue(loaded, label)

            harness.credentials.set(Credential(accountID: "acct-B", token: 2, usedPercent: 70))
            await harness.gate.hold()
            await harness.service.handleManagedAuthenticationEstablished(accountID: establishedAccount, authGeneration: 0)

            let afterTransition = await harness.service.test_status()
            XCTAssertNil(reading(afterTransition, now: harness.clock.now), "\(label): prior reading is not shown for the new identity")
            await harness.gate.release()
            let replaced = await waitForLoaded(harness, account: "acct-B", percent: 70)
            XCTAssertTrue(replaced, label)
            await harness.service.shutdown()
            withExtendedLifetime(stream) {}
        }
    }

    func testTransitionKeepsSameAccountReadingWhileReplacementReads() async {
        let harness = makeHarness(initial: Credential(accountID: "acct-A", token: 1, usedPercent: 30))
        await harness.service.setEnabled(true)
        let stream = await harness.service.subscribe()
        let loaded = await waitForLoaded(harness, account: "acct-A", percent: 30)
        XCTAssertTrue(loaded)

        harness.credentials.set(Credential(accountID: "acct-A", token: 2, usedPercent: 35))
        await harness.gate.hold()
        await harness.service.handleManagedAuthenticationEstablished(accountID: "acct-A", authGeneration: 0)

        let afterTransition = await harness.service.test_status()
        XCTAssertEqual(reading(afterTransition, now: harness.clock.now)?.percent, 30, "the same account's value stays in place")
        await harness.gate.release()
        let refreshed = await waitForLoaded(harness, account: "acct-A", percent: 35)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(harness.transports.value, 2)
        await harness.service.shutdown()
        withExtendedLifetime(stream) {}
    }

    func testLaterSignOutWinsOverSignInReportedFromEarlierGeneration() async {
        let harness = makeHarness(initial: Credential(accountID: "acct-123", token: 1, usedPercent: 40))
        await harness.service.setEnabled(true)
        let stream = await harness.service.subscribe()
        let loaded = await waitForLoaded(harness, account: "acct-123", percent: 40)
        XCTAssertTrue(loaded)

        // The sign-out moved the authority from generation 3 to 4.
        await harness.service.handleSignOutOrAccountChange(authGeneration: 4)
        // A sign-in observed before the sign-out, delivered late.
        await harness.service.handleManagedAuthenticationEstablished(accountID: "acct-123", authGeneration: 3)

        let status = await harness.service.test_status()
        XCTAssertEqual(status, .idle)
        let hasTransport = await harness.service.test_hasTransport()
        XCTAssertFalse(hasTransport, "a stale sign-in must not restart usage after sign-out")
        XCTAssertEqual(harness.transports.value, 1)

        // A sign-in after the sign-out carries the generation the sign-out moved to.
        await harness.service.handleManagedAuthenticationEstablished(accountID: "acct-123", authGeneration: 4)
        let resumed = await waitForLoaded(harness, account: "acct-123", percent: 40)
        XCTAssertTrue(resumed)
        XCTAssertEqual(harness.transports.value, 2)
        await harness.service.shutdown()
        withExtendedLifetime(stream) {}
    }

    func testTransitionStartsNoTransportWhileDisabledOrUnobserved() async {
        let disabled = makeHarness(initial: Credential(accountID: "acct-123", token: 1, usedPercent: 40))
        let observer = await disabled.service.subscribe()
        await disabled.service.handleManagedAuthenticationEstablished(accountID: "acct-123", authGeneration: 0)
        let disabledStatus = await disabled.service.test_status()
        XCTAssertEqual(disabledStatus, .disabled)
        XCTAssertEqual(disabled.transports.value, 0, "a disabled source starts nothing")

        let unobserved = makeHarness(initial: Credential(accountID: "acct-123", token: 1, usedPercent: 40))
        await unobserved.service.setEnabled(true)
        await unobserved.service.handleManagedAuthenticationEstablished(accountID: "acct-123", authGeneration: 0)
        let hasTransport = await unobserved.service.test_hasTransport()
        XCTAssertFalse(hasTransport)
        XCTAssertEqual(unobserved.transports.value, 0, "an unobserved source starts nothing")
        withExtendedLifetime(observer) {}
    }
}
