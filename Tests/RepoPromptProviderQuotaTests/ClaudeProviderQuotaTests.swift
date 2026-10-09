import Foundation
@testable import RepoPromptProviderQuota
import XCTest

final class ClaudeProviderQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func snapshot(_ info: ClaudeProviderQuotaObservation, previous: ProviderQuotaSnapshot? = nil) throws -> ProviderQuotaSnapshot {
        let delta = try XCTUnwrap(ClaudeProviderQuotaMapper.delta(from: info, observedAt: now))
        guard case let .merged(value) = ProviderQuotaMerge.apply(delta, to: previous) else {
            throw NSError(domain: "quota-test", code: 1)
        }
        return value
    }

    func testAllowedWithoutPercentStillReportsResetAndPartialProvenance() throws {
        let value = try snapshot(.init(status: .allowed, resetsAt: now.timeIntervalSince1970 + 300, rateLimitType: "five_hour"))
        XCTAssertEqual(value.source, .claudeSDKEvent)
        XCTAssertEqual(value.coverage, .reportedBucketsOnly)
        XCTAssertFalse(value.accountKey.isIdentified)
        XCTAssertNil(value.buckets.first?.windows.first?.percent)
        guard case let .loaded(sections, footnote, _) = ProviderQuotaPresenter.viewState(for: .loaded(value), now: now) else {
            return XCTFail("Expected loaded telemetry, not fabricated remaining quota")
        }
        let row = try XCTUnwrap(sections.first?.rows.first)
        XCTAssertNil(row.barFraction)
        XCTAssertEqual(row.valueText, ProviderQuotaPresenter.notReportedMessage)
        XCTAssertTrue(row.detailText?.contains("Resets") == true)
        XCTAssertTrue(footnote?.contains("account identity") == true)
    }

    func testFractionScopingAndReplacementNeverReviveMissingPercent() throws {
        let warning = try snapshot(.init(status: .allowedWarning, resetsAt: now.timeIntervalSince1970 + 600, rateLimitType: "seven_day_opus", utilization: 0.82))
        XCTAssertEqual(warning.buckets.first?.nativeModelAlias, "opus")
        XCTAssertEqual(warning.buckets.first?.windows.first?.percent?.rawValue, 82)
        let allowed = try snapshot(.init(status: .allowed, rateLimitType: "seven_day_opus"), previous: warning)
        XCTAssertNil(allowed.buckets.first?.windows.first?.percent)
        XCTAssertNil(allowed.buckets.first?.windows.first?.resetsAt)
        XCTAssertEqual(allowed.buckets.first?.isReached, false)
        let nextBucket = try snapshot(.init(status: .rejected, rateLimitType: "five_hour"), previous: allowed)
        XCTAssertEqual(nextBucket.buckets.count, 2)
        XCTAssertEqual(nextBucket.buckets[0].nativeModelAlias, "opus")
        guard case let .loaded(sections, _, _) = ProviderQuotaPresenter.viewState(for: .loaded(nextBucket), now: now) else { return XCTFail() }
        XCTAssertEqual(sections[1].rows.first?.valueText, "Limit reached — percentage not reported")
        XCTAssertEqual(sections[1].rows.first?.isReached, true)
    }

    func testInvalidUtilizationAndFutureVocabularyAreNotGuessed() throws {
        for invalid in [Double.nan, .infinity, -0.2, 1.2] {
            let value = try snapshot(.init(status: .allowed, rateLimitType: "five_hour", utilization: invalid))
            XCTAssertNil(value.buckets.first?.windows.first?.percent)
        }
        XCTAssertNil(ClaudeProviderQuotaMapper.delta(from: .init(status: .allowed, rateLimitType: "future_model"), observedAt: now))
        XCTAssertNil(ClaudeProviderQuotaMapper.delta(from: .init(status: .allowed), observedAt: now))
    }

    func testPassiveLifecycleRetiresOtherRunsAndDisabledProducers() async throws {
        let service = ClaudeRunRateLimitTelemetryService()
        let disabledLease = await service.beginObservation()
        XCTAssertNil(disabledLease)
        await service.setEnabled(true)
        let firstOptional = await service.beginObservation()
        let first = try XCTUnwrap(firstOptional)
        await service.observe(.init(status: .allowed, rateLimitType: "five_hour", utilization: 0.4), lease: first, observedAt: now)
        let initialStream = await service.subscribe()
        var initial = initialStream.makeAsyncIterator()
        let initialStatus = await initial.next()
        guard case .loaded = initialStatus else { return XCTFail("Expected observation") }

        let secondOptional = await service.beginObservation()
        let second = try XCTUnwrap(secondOptional)
        await service.observe(.init(status: .rejected, rateLimitType: "seven_day"), lease: first, observedAt: now)
        let staleStream = await service.subscribe()
        var stale = staleStream.makeAsyncIterator()
        let retiredStatus = await stale.next()
        XCTAssertEqual(retiredStatus, .idle)
        await service.observe(.init(status: .allowed, rateLimitType: "seven_day"), lease: second, observedAt: now)
        let secondStream = await service.subscribe()
        var secondIterator = secondStream.makeAsyncIterator()
        let secondStatus = await secondIterator.next()
        guard case let .loaded(value) = secondStatus else { return XCTFail() }
        XCTAssertEqual(value.buckets.map(\.bucketID.rawValue), ["seven_day"])

        await service.setEnabled(false)
        await service.setEnabled(true)
        await service.observe(.init(status: .rejected, rateLimitType: "five_hour"), lease: second, observedAt: now)
        let finalStream = await service.subscribe()
        var finalIterator = finalStream.makeAsyncIterator()
        let finalStatus = await finalIterator.next()
        XCTAssertEqual(finalStatus, .idle)
        await service.invalidate()
        await service.shutdown()
    }
}
