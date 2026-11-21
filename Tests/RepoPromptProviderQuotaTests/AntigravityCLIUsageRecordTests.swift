import Foundation
@testable import RepoPromptProviderQuota
import XCTest

final class AntigravityCLIUsageRecordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroupsKeepIndependentWeeklyAndFiveHourWindows() throws {
        let data = Data("""
        {"product":"antigravity","email":"private@example.invalid","cwd":"/private/workspace","quota":{
            "gemini-weekly":{"remaining_fraction":0.25,"reset_time":"2027-02-01T12:30:00.125Z","reset_in_seconds":7},
            "gemini-5h":{"remaining_fraction":0,"reset_in_seconds":42},
            "3p-weekly":{"remaining_fraction":0.75,"reset_in_seconds":15000},
            "3p-5h":{"remaining_fraction":1,"disabled":true},
            "gemini-argon-wtu-weekly":{"remaining_fraction":0.5},
            "unrecognized-weekly":{"remaining_fraction":0.99}
        }}
        """.utf8)
        let record = try XCTUnwrap(AntigravityCLIUsageRecord.extract(data, at: now))
        let encoded = try JSONEncoder().encode(record)
        let serialized = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(serialized.contains("private"))
        XCTAssertFalse(serialized.contains("unrecognized"))
        let snapshot = try XCTUnwrap(JSONDecoder().decode(AntigravityCLIUsageRecord.self, from: encoded).snapshot())
        XCTAssertEqual(snapshot.coverage, .reportedBucketsOnly)
        XCTAssertEqual(snapshot.source, .providerRead(.antigravity))
        XCTAssertNil(snapshot.accountKey.opaqueAccountID)
        XCTAssertEqual(snapshot.buckets.map(\.scope), [.unattributed, .unattributed, .unattributed])
        let gemini = try XCTUnwrap(snapshot.buckets.first)
        let fiveHours = try XCTUnwrap(gemini.window(role: "gemini-5h"))
        let weekly = try XCTUnwrap(gemini.window(role: "gemini-weekly"))
        XCTAssertEqual(fiveHours.windowDuration, 18000)
        XCTAssertEqual(fiveHours.percent?.rawValue, 0)
        XCTAssertNil(fiveHours.isReached, "a numeric zero is not an explicit exhaustion flag")
        XCTAssertEqual(fiveHours.resetsAt, now.addingTimeInterval(42))
        XCTAssertEqual(weekly.windowDuration, 604_800)
        XCTAssertEqual(weekly.percent?.rawValue, 25)
        XCTAssertEqual(weekly.percent?.sense, .remaining)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(weekly.resetsAt, formatter.date(from: "2027-02-01T12:30:00.125Z"))
        XCTAssertEqual(snapshot.buckets[1].windows.map(\.nativeRole), ["3p-weekly"])
        XCTAssertEqual(snapshot.buckets[2].windows.map(\.nativeRole), ["gemini-argon-wtu-weekly"])
        guard case let .loaded(sections, _, _) = ProviderQuotaPresenter.viewState(for: .loaded(snapshot), now: now) else {
            return XCTFail("Expected visible quota rows")
        }
        XCTAssertEqual(sections[0].rows.map(\.valueText), ["0% remaining", "25% remaining"])
    }

    func testSparseOrMalformedPayloadDoesNotInventPercentages() throws {
        let data = Data(#"{"product":"antigravity","email":"fixture","quota":{"gemini-weekly":{"remaining_fraction":7,"reset_in_seconds":90},"gemini-5h":"bad","3p-weekly":{"remaining_amount":3},"3p-5h":{"remaining_fraction":1,"disabled":"bad"}}}"#.utf8)
        let snapshot = try XCTUnwrap(AntigravityCLIUsageRecord.extract(data, at: now)?.snapshot())
        let windows = snapshot.buckets.flatMap(\.windows)
        XCTAssertEqual(windows.map(\.nativeRole), ["gemini-weekly"])
        XCTAssertNil(windows.first?.percent)
        XCTAssertEqual(windows.first?.resetsAt, now.addingTimeInterval(90))
        XCTAssertNil(AntigravityCLIUsageRecord.extract(Data(#"{"product":"antigravity","quota":{"gemini-weekly":{"remaining_fraction":1}}}"#.utf8)))
        XCTAssertNil(AntigravityCLIUsageRecord.extract(Data(#"{"product":"other","email":"fixture","quota":{"gemini-weekly":{"remaining_fraction":1}}}"#.utf8)))
    }
}
