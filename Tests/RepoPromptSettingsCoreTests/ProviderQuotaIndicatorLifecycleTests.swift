import Combine
import Foundation
@testable import RepoPromptProviderQuota
@testable import RepoPromptSettingsCore
import XCTest

/// Sticky usage indicator and stale-triggered refresh, end to end through the MainActor store.
///
/// Contract: once the pill has a value it stays visible; aging, refreshing, failed reads and
/// account changes change its *state*, never its presence. Only display-off / source-off hide it.
@MainActor
final class ProviderQuotaIndicatorLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Sticky display

    func testIndicatorStaysVisibleAndStaleMarkedPastTheStaleHorizon() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        await source.emit(.loaded(fiveHourSnapshot(used: 42, observedAt: start, resetsAt: start.addingTimeInterval(4 * 3600))))
        let shown = await waitUntil { store.indicatorState != nil }
        XCTAssertTrue(shown)

        // A 5-hour window's horizon is 75 minutes; two hours later the reading is aged.
        clock.advance(by: 2 * 3600)
        store.revalidateFreshness()

        let state = store.indicatorState
        XCTAssertNotNil(state, "an aged reading must stay visible rather than vanish")
        XCTAssertEqual(state?.usedPercent, 42)
        XCTAssertEqual(state?.freshness, .stale)
        XCTAssertEqual(state?.observedAt?.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 60)
        store.deactivate()
    }

    func testResetPassedReadingStaysVisibleWithResetPassedState() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        await source.emit(.loaded(fiveHourSnapshot(used: 80, observedAt: start, resetsAt: start.addingTimeInterval(3600))))
        _ = await waitUntil { store.indicatorState != nil }

        clock.advance(by: 90 * 60)
        store.revalidateFreshness()

        XCTAssertNotNil(store.indicatorState, "a passed reset keeps the last value visible")
        XCTAssertEqual(store.indicatorState?.usedPercent, 80)
        XCTAssertEqual(store.indicatorState?.freshness, .resetPassed)
        store.deactivate()
    }

    func testFailedReadKeepsLastValueWithFailedState() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        let snapshot = fiveHourSnapshot(used: 42, observedAt: start, resetsAt: start.addingTimeInterval(4 * 3600))
        await source.emit(.loaded(snapshot))
        _ = await waitUntil { store.indicatorState != nil }

        await source.emit(.failed(reason: "Usage limits are not available right now.", previous: snapshot))
        let failed = await waitUntil { store.indicatorState?.refreshFailed == true }

        XCTAssertTrue(failed)
        XCTAssertEqual(store.indicatorState?.usedPercent, 42, "a failed refresh keeps the previous figure")
        store.deactivate()
    }

    func testAccountChangeShowsNeutralUnavailableInsteadOfRemovingThePill() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        await source.emit(.loaded(fiveHourSnapshot(used: 42, observedAt: start, resetsAt: nil)))
        _ = await waitUntil { store.indicatorState != nil }

        // Account switch / sign-out: the service discards the snapshot and republishes idle.
        await source.emit(.idle)
        let neutral = await waitUntil { store.indicatorState?.freshness == .unavailable }

        XCTAssertTrue(neutral)
        XCTAssertNotNil(store.indicatorState, "the pill stays in place")
        XCTAssertNil(store.indicatorState?.usedPercent, "the prior account's figure is not shown")

        // A failed read without a previous snapshot (sign-in required) is also neutral.
        await source.emit(.failed(reason: "Sign in", previous: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.indicatorState?.freshness, .unavailable)
        store.deactivate()
    }

    func testNothingRendersBeforeTheFirstValue() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        await source.emit(.loading)
        await source.emit(.idle)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(store.indicatorState, "with no value ever observed there is nothing to keep")
        store.deactivate()
    }

    func testTurningTheDisplayOffHidesTheIndicator() async {
        let clock = MutableClock(start)
        let source = ScriptedSource()
        let store = makeStore(source: source, clock: clock)
        store.activate()
        await source.emit(.loaded(fiveHourSnapshot(used: 42, observedAt: start, resetsAt: nil)))
        _ = await waitUntil { store.indicatorState != nil }

        store.setPresentationEnabled(false)
        XCTAssertNil(store.indicatorState, "display off is a hide reason")

        store.setPresentationEnabled(true)
        await source.emit(.loaded(fiveHourSnapshot(used: 43, observedAt: start, resetsAt: nil)))
        _ = await waitUntil { store.indicatorState != nil }
        store.setEnabled(false)
        XCTAssertNil(store.indicatorState, "source off is a hide reason")
        store.deactivate()
    }

    // MARK: - Stale-triggered automatic refresh

    func testStalenessTriggersExactlyOneAutomaticReadPerFifteenMinuteGap() async {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 3 * 3600)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock)
        store.activate()
        let primed = await waitUntil { await reader.count == 1 }
        XCTAssertTrue(primed, "the startup read happens once")
        _ = await waitUntil { store.indicatorState != nil }

        // Stale immediately, but the last attempt was just now.
        store.revalidateFreshness()
        await settle()
        var count = await reader.count
        XCTAssertEqual(count, 1, "a tick within the automatic gap issues no read")

        clock.advance(by: 16 * 60)
        store.revalidateFreshness()
        let refreshed = await waitUntil { await reader.count == 2 }
        XCTAssertTrue(refreshed, "a stale reading past the gap triggers one automatic read")

        store.revalidateFreshness()
        store.revalidateFreshness()
        store.revalidateFreshness()
        clock.advance(by: 10 * 60)
        store.revalidateFreshness()
        await settle()
        count = await reader.count
        XCTAssertEqual(count, 2, "repeated ticks inside fifteen minutes issue nothing")

        clock.advance(by: 6 * 60)
        store.revalidateFreshness()
        let again = await waitUntil { await reader.count == 3 }
        XCTAssertTrue(again)
        store.deactivate()
        await service.shutdown()
    }

    func testFailureBackoffAndInFlightReadSuppressAutomaticRefresh() async {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 3 * 3600)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock, automaticInterval: 30)
        store.activate()
        _ = await waitUntil { await reader.count == 1 }
        _ = await waitUntil { store.indicatorState != nil }

        await reader.setMode(.fail)
        clock.advance(by: 31)
        store.revalidateFreshness()
        let failedRead = await waitUntil { await reader.count == 2 }
        XCTAssertTrue(failedRead)
        let failedState = await waitUntil { store.indicatorState?.refreshFailed == true }
        XCTAssertTrue(failedState)
        XCTAssertEqual(store.indicatorState?.usedPercent, 42, "a failed refresh keeps the figure")

        // First failure backs off 60s; the 30s gap alone would admit a read.
        clock.advance(by: 45)
        store.revalidateFreshness()
        await settle()
        var count = await reader.count
        XCTAssertEqual(count, 2, "failure backoff suppresses the automatic read")

        await reader.setMode(.succeed)
        clock.advance(by: 20)
        store.revalidateFreshness()
        let recovered = await waitUntil { await reader.count == 3 }
        XCTAssertTrue(recovered, "after backoff the automatic read resumes")

        await reader.setMode(.hold)
        clock.advance(by: 31)
        store.revalidateFreshness()
        _ = await waitUntil { await reader.count == 4 }
        let updating = await waitUntil { store.indicatorState?.isUpdating == true }
        XCTAssertTrue(updating, "an admitted read shows updating in place")
        for _ in 0 ..< 3 {
            clock.advance(by: 31)
            store.revalidateFreshness()
            store.refreshOnForeground()
        }
        await settle()
        count = await reader.count
        XCTAssertEqual(count, 4, "an in-flight read is never duplicated")
        await reader.release()
        let done = await waitUntil { store.indicatorState?.isUpdating == false }
        XCTAssertTrue(done)
        store.deactivate()
        await service.shutdown()
    }

    func testForegroundRoutesThroughTheStaleGate() async {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 0)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock)
        store.activate()
        _ = await waitUntil { await reader.count == 1 }
        _ = await waitUntil { store.indicatorState != nil }

        clock.advance(by: 20 * 60)
        store.refreshOnForeground()
        await settle()
        var count = await reader.count
        XCTAssertEqual(count, 1, "a fresh reading spends no read on foreground")

        clock.advance(by: 2 * 3600)
        store.refreshOnForeground()
        let refreshed = await waitUntil { await reader.count == 2 }
        XCTAssertTrue(refreshed, "a stale reading refreshes on foreground instead of being a no-op")
        count = await reader.count
        XCTAssertEqual(count, 2)
        store.deactivate()
        await service.shutdown()
    }

    func testAutomaticRefreshUpdatesInPlaceWithoutHidingThePill() async {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 0)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock)
        store.activate()
        _ = await waitUntil { store.indicatorState != nil }

        var publications: [ProviderQuotaIndicatorState?] = []
        let recorder = store.$indicatorState.dropFirst().sink { publications.append($0) }
        defer { recorder.cancel() }

        await reader.setPercent(55)
        clock.advance(by: 2 * 3600)
        store.revalidateFreshness()
        let refreshed = await waitUntil {
            store.indicatorState?.usedPercent == 55 && store.indicatorState?.isUpdating == false
        }

        XCTAssertTrue(refreshed, "the stale reading is replaced in place")
        XCTAssertEqual(store.indicatorState?.freshness, .fresh, "a successful refresh clears stale")
        XCTAssertFalse(publications.contains { $0 == nil }, "the pill never disappears during a refresh cycle")
        store.deactivate()
        await service.shutdown()
    }

    // MARK: - Manual refresh (Settings button / pill context menu)

    func testManualRefreshBypassesAutomaticThrottleAndCoalesces() async {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 3 * 3600)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock)
        store.activate()
        _ = await waitUntil { await reader.count == 1 }
        _ = await waitUntil { store.indicatorState != nil }

        clock.advance(by: 5 * 60)
        store.revalidateFreshness()
        await settle()
        var count = await reader.count
        XCTAssertEqual(count, 1, "the automatic gap still holds")

        store.refresh()
        let manual = await waitUntil { await reader.count == 2 }
        XCTAssertTrue(manual, "a user refresh is not subject to the automatic gap")
        _ = await waitUntil { !store.isRefreshing }

        await reader.setMode(.hold)
        clock.advance(by: 2 * 60)
        store.refresh()
        XCTAssertEqual(store.indicatorState?.isUpdating, true, "manual refresh shows updating in place")
        store.refresh()
        store.revalidateFreshness()
        let direct = Task { await service.refreshNow() }
        await settle()
        count = await reader.count
        XCTAssertEqual(count, 3, "one read at a time")
        XCTAssertNotNil(store.indicatorState)
        await reader.release()
        await direct.value
        _ = await waitUntil { !store.isRefreshing }
        count = await reader.count
        XCTAssertEqual(count, 3)
        store.deactivate()
        await service.shutdown()
    }

    // MARK: - Claude SDK display overlay

    func testSDKOverlayRefreshesTheDisplayOnlyAndSavesACLIRead() async throws {
        let clock = MutableClock(start)
        let reader = Reader(clock: clock, age: 0)
        let (store, service) = await makeLiveStore(reader: reader, clock: clock)
        store.activate()
        _ = await waitUntil { store.indicatorState != nil }

        clock.advance(by: 2 * 3600)
        try store.applyDisplayOverlay(sdkSnapshot(utilization: 0.61, observedAt: clock.now, profile: "profile"))
        XCTAssertEqual(store.indicatorState?.usedPercent, 61, "a newer same-profile SDK reading updates the pill")
        XCTAssertEqual(store.indicatorState?.freshness, .fresh)

        store.revalidateFreshness()
        await settle()
        let count = await reader.count
        XCTAssertEqual(count, 1, "telemetry kept the display current, so no CLI read is spent")

        let latest = await service.latestSnapshot()
        XCTAssertEqual(latest?.buckets.first?.window(role: "five_hour")?.percent?.rawValue, 42, "the service snapshot is untouched")
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(latest, now: clock.now).known, "balancing still sees a stale, unknown reading")

        try store.applyDisplayOverlay(sdkSnapshot(utilization: 0.99, observedAt: clock.now.addingTimeInterval(60), profile: "/other/.claude"))
        XCTAssertNotEqual(store.indicatorState?.usedPercent, 99, "another profile's run never reaches the pill")
        XCTAssertNotNil(store.indicatorState)
        store.deactivate()
        await service.shutdown()
    }

    // MARK: - Helpers

    private func sdkSnapshot(utilization: Double, observedAt: Date, profile: String) throws -> ProviderQuotaSnapshot {
        let delta = try XCTUnwrap(ClaudeProviderQuotaMapper.delta(
            from: .init(status: .allowed, rateLimitType: "five_hour", utilization: utilization),
            observedAt: observedAt
        ))
        guard case let .merged(value) = ProviderQuotaMerge.apply(delta, to: nil) else { throw NSError(domain: "overlay", code: 1) }
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profile),
            buckets: value.buckets, facets: value.facets, source: value.source, coverage: value.coverage, observedAt: value.observedAt
        )
    }

    private func fiveHourSnapshot(used: Double, observedAt: Date, resetsAt: Date?, profile: String = "profile") -> ProviderQuotaSnapshot {
        Self.snapshot(used: used, observedAt: observedAt, resetsAt: resetsAt, profile: profile)
    }

    fileprivate nonisolated static func snapshot(used: Double, observedAt: Date, resetsAt: Date?, profile: String = "profile") -> ProviderQuotaSnapshot {
        let bucketID = ProviderQuotaBucketID.synthesizedDefault
        let window = ProviderQuotaWindow(
            key: .init(bucketID: bucketID, nativeRole: "five_hour"),
            percent: ProviderQuotaPercent(rawValue: used, sense: .used, declaredUpperBound: 100),
            windowDuration: 5 * 3600,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
        let bucket = ProviderQuotaBucket(
            bucketID: bucketID,
            displayLabel: nil,
            nativeModelAlias: nil,
            scope: .accountWide,
            reachedType: nil,
            isReached: nil,
            planType: nil,
            credits: nil,
            spendControl: nil,
            windows: [window]
        )
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profile),
            buckets: [bucket],
            facets: .empty,
            source: .claudeCLIUsage,
            coverage: .accountWideAggregateOnly,
            observedAt: observedAt
        )
    }

    private func makeStore(source: ScriptedSource, clock: MutableClock) -> ProviderQuotaUIStore {
        ProviderQuotaUIStore(service: source, settingsProvider: { true }, now: { clock.now }, freshnessInterval: 0)
    }

    private func makeLiveStore(
        reader: Reader,
        clock: MutableClock,
        automaticInterval: TimeInterval = 900
    ) async -> (ProviderQuotaUIStore, ProviderAccountQuotaService) {
        let service = ProviderAccountQuotaService(
            automaticInterval: automaticInterval,
            periodicReads: false,
            now: { clock.now },
            read: { _ in try await reader.read() }
        )
        await service.setEnabled(true)
        let store = ProviderQuotaUIStore(service: service, settingsProvider: { true }, now: { clock.now }, freshnessInterval: 0)
        return (store, service)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    final class MutableClock: @unchecked Sendable {
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

    private actor ScriptedSource: ProviderQuotaObserving {
        private var continuation: AsyncStream<ProviderQuotaStatus>.Continuation?
        private var current: ProviderQuotaStatus = .idle
        private(set) var manualReads = 0

        func subscribe() -> AsyncStream<ProviderQuotaStatus> {
            let (stream, continuation) = AsyncStream<ProviderQuotaStatus>.makeStream()
            self.continuation = continuation
            continuation.yield(current)
            return stream
        }

        func emit(_ status: ProviderQuotaStatus) {
            current = status
            continuation?.yield(status)
        }

        func setEnabled(_: Bool) {}
        func refreshNow() {
            manualReads += 1
        }

        func refreshOnForeground() {}
    }

    actor Reader {
        enum Mode { case succeed, fail, hold }
        private(set) var count = 0
        private var mode: Mode = .succeed
        private var percent: Double = 42
        private var held: [CheckedContinuation<Void, Never>] = []
        private let clock: MutableClock
        private let age: TimeInterval

        init(clock: MutableClock, age: TimeInterval) {
            self.clock = clock
            self.age = age
        }

        func setMode(_ mode: Mode) {
            self.mode = mode
        }

        func setPercent(_ percent: Double) {
            self.percent = percent
        }

        func release() {
            let pending = held
            held = []
            pending.forEach { $0.resume() }
        }

        func read() async throws -> ProviderQuotaSnapshot {
            count += 1
            switch mode {
            case .fail:
                throw ProviderQuotaReadError.transport
            case .hold:
                await withCheckedContinuation { held.append($0) }
            case .succeed:
                break
            }
            let observedAt = clock.now.addingTimeInterval(-age)
            return ProviderQuotaIndicatorLifecycleTests.snapshot(used: percent, observedAt: observedAt, resetsAt: observedAt.addingTimeInterval(4.9 * 3600))
        }
    }
}
