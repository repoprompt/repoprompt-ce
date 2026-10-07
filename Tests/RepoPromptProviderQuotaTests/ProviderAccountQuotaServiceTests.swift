import Foundation
@testable import RepoPromptProviderQuota
import XCTest

final class ProviderAccountQuotaServiceTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)

    private func reading(percent: Double = 1, accountID: String = "account", profileID: String = "profile") throws -> ProviderQuotaSnapshot {
        try ClaudeAccountUsageMapper.snapshot(
            data: Data("{\"five_hour\":{\"utilization\":\(percent),\"resets_at\":\"2034-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":null,\"resets_at\":null}}".utf8),
            account: .init(lineage: .anthropicFirstParty, opaqueAccountID: accountID, credentialProfileID: profileID),
            observedAt: instant
        )
    }

    func testAPIUnitsAndUnknownAreNotSDKFractionOrZero() throws {
        let snapshot = try reading()
        XCTAssertEqual(snapshot.buckets[0].windows[0].percent?.rawValue, 1)
        XCTAssertNil(snapshot.buckets[0].window(role: "seven_day")?.percent)
        XCTAssertEqual(snapshot.buckets[0].windows.count, 2, "one plan bucket owns both real account windows")
        let sdk = ClaudeProviderQuotaMapper.delta(from: .init(status: .allowed, resetsAt: nil, rateLimitType: "five_hour", utilization: 1), observedAt: instant)
        guard let sdk, case let .merged(telemetry) = ProviderQuotaMerge.apply(sdk, to: nil) else { return XCTFail("Missing SDK telemetry") }
        XCTAssertEqual(telemetry.buckets[0].windows[0].percent?.rawValue, 100)
        XCTAssertTrue(ProviderUsageSignal.readings(from: telemetry, now: instant).isEmpty)
    }

    func testNewClaudeLimitInventoryKeepsNativeModelIDsDistinctFromLabels() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":1,"scope":{"model":{"id":"native-model-id","display_name":"Friendly label"}}},{"kind":"weekly_scoped","percent":null,"scope":{"model":{"display_name":"Unknown identity"}}}]}"#.utf8)
        let snapshot = try ClaudeAccountUsageMapper.snapshot(data: data, account: .init(lineage: .anthropicFirstParty, opaqueAccountID: "account"), observedAt: instant)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets[0].scope, .nativeModelAlias("native-model-id"))
        XCTAssertEqual(snapshot.buckets[0].displayLabel, "Friendly label")
        XCTAssertEqual(snapshot.buckets[0].windows[0].percent?.rawValue, 1)
        XCTAssertEqual(snapshot.buckets[1].scope, .unattributed)
        XCTAssertNil(snapshot.buckets[1].windows[0].windowDuration)
        XCTAssertNil(snapshot.buckets[1].windows[0].percent)
    }

    func testCadenceUsesAdmissionDeadlineWithoutWeakeningFifteenMinuteFloor() {
        let almostDue = ProviderAccountQuotaService.nextAutomaticDelay(lastAttempt: instant, blockedUntil: nil, now: instant.addingTimeInterval(899.9), interval: 900)
        XCTAssertEqual(almostDue, 1, "early tick rechecks shortly, not a whole interval later")
        let retry = ProviderAccountQuotaService.nextAutomaticDelay(lastAttempt: instant, blockedUntil: instant.addingTimeInterval(1800), now: instant.addingTimeInterval(900), interval: 900)
        XCTAssertEqual(retry, 900, "server retry-after wins over the cadence")
    }

    func testFutureProviderRegistersThroughTheSameCachedConsumerPrimitive() async throws {
        let date = instant
        let provider = ProviderUsageProviderID(rawValue: "future-provider")
        let account = ProviderAccountKey(lineage: .provider(id: provider), opaqueAccountID: "fixture-account")
        let windows = try reading().buckets
        let value = ProviderQuotaSnapshot(accountKey: account, buckets: windows, facets: .empty, source: .providerRead(provider), coverage: .accountWide, observedAt: date)
        let fake = ReadCounter(value: value)
        let service = ProviderAccountQuotaService(now: { date }, read: { _ in await fake.read() })
        let hub = ProviderUsageHub(sources: [provider: service])
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        let signals = await hub.signals(for: account, now: date)
        XCTAssertEqual(signals.first?.headroom, .remainingPercent(99))
        XCTAssertFalse(String(reflecting: signals).contains("fixture-account"))
        let count = await fake.count
        XCTAssertEqual(count, 1, "lookup does not acquire another reading")
        withExtendedLifetime(stream) {}
    }

    func testProfileKeysNeverClaimSameAccountAcrossProfiles() throws {
        let a = try reading(profileID: "a").accountKey
        let b = try reading(profileID: "b").accountKey
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.refersToSameAccount(as: b))
        XCTAssertFalse(String(reflecting: a).contains("opaqueAccountID"))
    }

    func testCachedLookupAndUnauthorizedRouterDemandPerformZeroReads() async throws {
        let date = instant
        let fake = try ReadCounter(value: reading())
        let service = ProviderAccountQuotaService(now: { date }, read: { _ in await fake.read() })
        let hub = ProviderUsageHub(sources: [.claude: service])
        await service.setEnabled(true)
        let cached = await hub.latest(.claude)
        let demand = await hub.updates(.claude, consumer: .routerAdvisory)
        let count = await fake.count
        XCTAssertNil(cached)
        XCTAssertNil(demand)
        XCTAssertEqual(count, 0)
    }

    func testTwoSurfacesAndManualRefreshShareSingleReadAndBudget() async throws {
        let date = instant
        let fake = try ReadCounter(value: reading())
        let service = ProviderAccountQuotaService(now: { date }, read: { _ in await fake.read() })
        await service.setEnabled(true)
        let streamA = await service.subscribe()
        let streamB = await service.subscribe()
        var iterator = streamA.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        await service.refreshNow()
        await service.refreshNow()
        let count = await fake.count
        XCTAssertEqual(count, 1)
        withExtendedLifetime((streamA, streamB)) {}
    }

    func testServerRetryAfterWinsOverManualAndForegroundTriggers() async {
        let date = instant
        let fake = FailureCounter(error: .rateLimited(until: date.addingTimeInterval(900)))
        let service = ProviderAccountQuotaService(manualInterval: 0, now: { date }, read: { _ in try await fake.read() })
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .failed = status { break }
        }
        await service.refreshNow()
        await service.refreshOnForeground()
        let count = await fake.count
        XCTAssertEqual(count, 1)
        withExtendedLifetime(stream) {}
    }

    func testChangedAccountFailureClearsCacheAndPreservesServerRetryAfter() async throws {
        let date = instant
        let snapshot = try reading()
        let fake = AccountSwitchCounter(value: snapshot, retryAt: date.addingTimeInterval(900))
        let service = ProviderAccountQuotaService(manualInterval: 0, now: { date }, read: { context in try await fake.read(context) })
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        await service.refreshNow()
        let cached = await service.latestSnapshot()
        XCTAssertNil(cached, "confirmed account switch cannot retain the prior account's usage")
        await service.refreshNow()
        let expected = await fake.expectedAccounts
        XCTAssertEqual(expected.count, 2, "Retry-After prevents a third request")
        XCTAssertNil(expected[0])
        XCTAssertEqual(expected[1], snapshot.accountKey)
        withExtendedLifetime(stream) {}
    }

    private actor AccountSwitchCounter {
        let value: ProviderQuotaSnapshot
        let retryAt: Date
        var expectedAccounts: [ProviderAccountKey?] = []
        init(value: ProviderQuotaSnapshot, retryAt: Date) {
            self.value = value
            self.retryAt = retryAt
        }

        func read(_ context: ProviderQuotaReadContext) throws -> ProviderQuotaSnapshot {
            expectedAccounts.append(context.expectedAccount)
            if expectedAccounts.count == 1 { return value }
            throw ProviderQuotaReadError.accountInvalidated(retryAt: retryAt)
        }
    }

    func testSignalsRequireExactIdentifiedAccountAndDoNotLoseScopeOrFreshness() async throws {
        let date = instant
        let snapshot = try reading()
        let fake = ReadCounter(value: snapshot)
        let service = ProviderAccountQuotaService(now: { date }, read: { _ in await fake.read() })
        let hub = ProviderUsageHub(sources: [.claude: service])
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        let signals = await hub.signals(for: snapshot.accountKey, now: date)
        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals[0].headroom, .remainingPercent(99))
        XCTAssertEqual(signals[1].headroom, .unknown)
        let wrong = await hub.signals(for: .init(lineage: .anthropicFirstParty, opaqueAccountID: "different", credentialProfileID: "profile"), now: date)
        XCTAssertTrue(wrong.isEmpty)
        let old = await hub.signals(for: snapshot.accountKey, now: date.addingTimeInterval(901))
        XCTAssertFalse(old[0].availability.isFresh)
        let count = await fake.count
        XCTAssertEqual(count, 1)
        withExtendedLifetime(stream) {}
    }

    private actor ReadCounter {
        var count = 0
        let value: ProviderQuotaSnapshot
        init(value: ProviderQuotaSnapshot) {
            self.value = value
        }

        func read() -> ProviderQuotaSnapshot {
            count += 1
            return value
        }
    }

    private actor FailureCounter {
        var count = 0
        let error: ProviderQuotaReadError
        init(error: ProviderQuotaReadError) {
            self.error = error
        }

        func read() throws -> ProviderQuotaSnapshot {
            count += 1
            throw error
        }
    }
}
