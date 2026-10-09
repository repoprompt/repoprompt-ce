import Foundation
@testable import RepoPromptProviderQuota
import XCTest

/// Display-only overlay of Claude SDK `rate_limit_event` telemetry onto the CLI usage snapshot.
final class ProviderQuotaDisplayOverlayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    func testNewerSDKReadingUpdatesTheDisplayedWindow() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        let overlay = try sdk([("five_hour", 0.35, t0.addingTimeInterval(7200))], observedAt: t0.addingTimeInterval(600))
        let merged = ProviderQuotaDisplayOverlay.merge(overlay, onto: base)
        let window = try XCTUnwrap(merged.buckets.first?.window(role: "five_hour"))
        XCTAssertEqual(window.percent?.rawValue ?? 0, 35, accuracy: 0.001)
        XCTAssertEqual(window.observedAt, t0.addingTimeInterval(600))
        XCTAssertEqual(window.resetsAt, t0.addingTimeInterval(7200))
        XCTAssertEqual(merged.buckets.first?.window(role: "seven_day")?.percent?.rawValue, 10, "unmentioned windows are untouched")
        XCTAssertEqual(merged.source, .claudeCLIUsage, "provenance and identity stay the CLI snapshot's")
        XCTAssertEqual(merged.accountKey, base.accountKey)
    }

    func testOlderSDKReadingNeverRegressesAFresherCLIReading() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        for observedAt in [t0, t0.addingTimeInterval(-60)] {
            let overlay = try sdk([("five_hour", 0.9, nil)], observedAt: observedAt)
            XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(overlay, onto: base), base)
        }
    }

    func testMissingPercentNeverErasesOrFreshensAValue() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        let resetOnly = try sdk([("five_hour", nil, t0.addingTimeInterval(9000))], observedAt: t0.addingTimeInterval(600))
        XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(resetOnly, onto: base), base, "a reset without a figure contributes nothing")

        let rejected = try sdk([("five_hour", nil, nil)], observedAt: t0.addingTimeInterval(600), status: .rejected)
        let merged = ProviderQuotaDisplayOverlay.merge(rejected, onto: base)
        let window = try XCTUnwrap(merged.buckets.first?.window(role: "five_hour"))
        XCTAssertEqual(window.isReached, true, "an explicit limit-reached signal still shows")
        XCTAssertEqual(window.percent?.rawValue, 20, "the previous figure is kept")
        XCTAssertEqual(window.observedAt, t0, "and does not look newly observed")
    }

    func testProfileMismatchOrUnattributedRunDoesNotMerge() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        let other = try sdk([("five_hour", 0.5, nil)], observedAt: t0.addingTimeInterval(600), profile: "/other/.claude")
        XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(other, onto: base), base)
        let unattributed = try sdk([("five_hour", 0.5, nil)], observedAt: t0.addingTimeInterval(600), profile: .some(nil))
        XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(unattributed, onto: base), base)
        let compatibleBase = ProviderQuotaSnapshot(
            accountKey: .init(lineage: .claudeCompatible(backendID: "glm"), opaqueAccountID: nil, credentialProfileID: profile),
            buckets: base.buckets, facets: .empty, source: .claudeCLIUsage, coverage: base.coverage, observedAt: t0
        )
        let same = try sdk([("five_hour", 0.5, nil)], observedAt: t0.addingTimeInterval(600))
        XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(same, onto: compatibleBase), compatibleBase)
    }

    func testModelScopedAndOverageBucketsAreIgnored() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        let overlay = try sdk(
            [("seven_day_opus", 0.99, nil), ("seven_day_overage_included", 0.99, nil), ("overage", 0.99, nil)],
            observedAt: t0.addingTimeInterval(600)
        )
        XCTAssertEqual(ProviderQuotaDisplayOverlay.merge(overlay, onto: base), base)
    }

    func testBalancingNeverSeesSDKDataAndStaleCLIStaysUnknown() throws {
        let base = cli(fiveHour: 20, weekly: 10, observedAt: t0)
        let later = t0.addingTimeInterval(2 * 3600)
        let overlay = try sdk([("five_hour", 0.3, nil), ("seven_day", 0.12, nil)], observedAt: later)
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(overlay, now: later).known, "SDK telemetry is not routing evidence")
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(base, now: later).known, "the service snapshot stays unknown when stale")
        // The overlay is display-only; nothing in this module writes it back to a service.
        let displayed = ProviderQuotaDisplayOverlay.merge(overlay, onto: base)
        XCTAssertNotEqual(displayed, base)
        XCTAssertEqual(base.buckets.first?.window(role: "five_hour")?.percent?.rawValue, 20)
    }

    func testTelemetryPublishesTheRunProfileAndStillMergesSparseEvents() async throws {
        let service = ClaudeRunRateLimitTelemetryService()
        await service.setEnabled(true)
        let leaseOptional = await service.beginObservation(credentialProfileID: profile)
        let lease = try XCTUnwrap(leaseOptional)
        await service.observe(.init(status: .allowed, rateLimitType: "five_hour", utilization: 0.4), lease: lease, observedAt: t0)
        await service.observe(.init(status: .allowed, rateLimitType: "seven_day", utilization: 0.1), lease: lease, observedAt: t0)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        let status = await iterator.next()
        guard case let .loaded(snapshot) = status else { return XCTFail("expected telemetry") }
        XCTAssertEqual(snapshot.accountKey.credentialProfileID, profile)
        XCTAssertFalse(snapshot.accountKey.isIdentified)
        XCTAssertEqual(snapshot.buckets.map(\.bucketID.rawValue), ["five_hour", "seven_day"])
        await service.shutdown()
    }

    // MARK: - Fixtures

    private let profile = "/Users/fixture/.claude"

    private func cli(fiveHour: Double, weekly: Double, observedAt: Date) -> ProviderQuotaSnapshot {
        let id = ProviderQuotaBucketID.synthesizedDefault
        let windows = [("five_hour", fiveHour, 5 * 3600.0), ("seven_day", weekly, 7 * 86400.0)].map { role, used, duration in
            ProviderQuotaWindow(
                key: .init(bucketID: id, nativeRole: role),
                percent: ProviderQuotaPercent(rawValue: used, sense: .used, declaredUpperBound: 100),
                windowDuration: duration,
                resetsAt: observedAt.addingTimeInterval(duration / 2),
                observedAt: observedAt
            )
        }
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profile),
            buckets: [ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: nil, scope: .accountWide, reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: windows)],
            facets: .empty,
            source: .claudeCLIUsage,
            coverage: .accountWideAggregateOnly,
            observedAt: observedAt
        )
    }

    private func sdk(
        _ events: [(role: String, utilization: Double?, resetsAt: Date?)],
        observedAt: Date,
        status: ClaudeProviderQuotaObservation.Status = .allowed,
        profile: String?? = .none
    ) throws -> ProviderQuotaSnapshot {
        var snapshot: ProviderQuotaSnapshot?
        for event in events {
            let info = ClaudeProviderQuotaObservation(status: status, resetsAt: event.resetsAt?.timeIntervalSince1970, rateLimitType: event.role, utilization: event.utilization)
            let delta = try XCTUnwrap(ClaudeProviderQuotaMapper.delta(from: info, observedAt: observedAt))
            guard case let .merged(merged) = ProviderQuotaMerge.apply(delta, to: snapshot) else { throw NSError(domain: "overlay-test", code: 1) }
            snapshot = merged
        }
        let value = try XCTUnwrap(snapshot)
        let profileID: String? = switch profile {
        case .none: self.profile
        case let .some(explicit): explicit
        }
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profileID),
            buckets: value.buckets, facets: value.facets, source: value.source, coverage: value.coverage, observedAt: value.observedAt
        )
    }
}
