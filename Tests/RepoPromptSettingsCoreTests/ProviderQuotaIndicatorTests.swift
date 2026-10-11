import Foundation
import RepoPromptProviderQuota
@testable import RepoPromptSettingsCore
import XCTest

final class ProviderQuotaIndicatorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)
    private func snapshot(_ percent: Double?) throws -> ProviderQuotaSnapshot {
        try ClaudeAccountUsageMapper.snapshot(
            data: Data("{\"five_hour\":{\"utilization\":\(percent.map(String.init(describing:)) ?? "null"),\"resets_at\":null}}".utf8),
            account: .init(lineage: .anthropicFirstParty, opaqueAccountID: "fixture"),
            observedAt: date
        )
    }

    func testIndicatorRoundsBeforeEqualityAndSeparatesUnknownZeroAndStale() throws {
        XCTAssertNil(try ProviderQuotaIndicatorState.project(snapshot(nil), now: date))
        XCTAssertEqual(try ProviderQuotaIndicatorState.project(snapshot(0), now: date)?.usedPercent, 0)
        XCTAssertEqual(
            try ProviderQuotaIndicatorState.project(snapshot(41.6), now: date),
            try ProviderQuotaIndicatorState.project(snapshot(41.7), now: date)
        )
        XCTAssertNotNil(try ProviderQuotaIndicatorState.project(snapshot(42), now: date.addingTimeInterval(901)), "normal refresh latency must not hide available usage")
        XCTAssertEqual(try ProviderQuotaIndicatorState.project(snapshot(42), now: date.addingTimeInterval(901))?.freshness, .fresh)
        let aged = try ProviderQuotaIndicatorState.project(snapshot(42), now: date.addingTimeInterval(4501))
        XCTAssertEqual(aged?.usedPercent, 42, "an aged reading keeps its figure instead of disappearing")
        XCTAssertEqual(aged?.freshness, .stale)
        XCTAssertEqual(aged?.observedAt?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 60, "observation time is minute-rounded")
    }

    func testCodexReportedPercentageAppearsInTheSameIndicator() throws {
        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(["rateLimits": ["secondary": ["usedPercent": 4, "windowDurationMins": 10080]]], fallbackAccountID: "fixture", observedAt: date))
        guard case let .merged(snapshot) = ProviderQuotaMerge.apply(delta, to: nil) else { return XCTFail("missing account snapshot") }
        XCTAssertEqual(ProviderQuotaIndicatorState.project(snapshot, now: date)?.usedPercent, 4)
    }

    func testModelScopedAndAnonymousReadingsDoNotBecomeAccountWidePills() throws {
        let scoped = try ClaudeAccountUsageMapper.snapshot(
            data: Data(#"{"seven_day_sonnet":{"utilization":80}}"#.utf8),
            account: .init(lineage: .anthropicFirstParty, opaqueAccountID: "fixture"),
            observedAt: date
        )
        XCTAssertNil(ProviderQuotaIndicatorState.project(scoped, now: date))
        let sdk = ClaudeProviderQuotaMapper.delta(from: .init(status: .allowed, resetsAt: nil, rateLimitType: "five_hour", utilization: 0.8), observedAt: date)
        guard let sdk, case let .merged(anonymous) = ProviderQuotaMerge.apply(sdk, to: nil) else { return XCTFail("missing SDK telemetry") }
        XCTAssertNil(ProviderQuotaIndicatorState.project(anonymous, now: date))
    }

    @MainActor
    func testMasterOffDoesNotSubscribeEvenWithAcquisitionEnabledAndVisibleSurface() async {
        let source = CountedSource()
        let store = ProviderQuotaUIStore(service: source, settingsProvider: { true }, presentationProvider: { false })
        store.activate()
        store.refresh()
        store.refreshOnForeground()
        await Task.yield()
        let subscriptions = await source.subscriptions
        let reads = await source.reads
        XCTAssertEqual(subscriptions, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(store.state, .hidden)
        XCTAssertNil(store.indicatorState)
        store.deactivate()
    }

    private actor CountedSource: ProviderQuotaObserving {
        var subscriptions = 0
        var reads = 0
        func setEnabled(_ enabled: Bool) {}
        func subscribe() -> AsyncStream<ProviderQuotaStatus> {
            subscriptions += 1
            return AsyncStream { $0.finish() }
        }

        func refreshNow() {
            reads += 1
        }

        func refreshOnForeground() {
            reads += 1
        }
    }
}
