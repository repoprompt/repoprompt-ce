import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MessageTimestampFormatterTests: XCTestCase {
    private var calendar: Calendar!
    private let locale = Locale(identifier: "en_US_POSIX")

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = locale
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    func testDisabledPreservesTimeOnlyFormat() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2025, month: 12, day: 31, hour: 3, minute: 4, second: 5),
                includeDateContext: false,
                now: date(year: 2026, month: 6, day: 12, hour: 16, minute: 58, second: 57),
                calendar: calendar,
                locale: locale
            ),
            "03:04:05"
        )
    }

    func testTodayUsesTimeOnly() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2026, month: 6, day: 12, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: locale
            ),
            "16:58:57"
        )
    }

    func testYesterdayAddsYesterdayLabel() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2026, month: 6, day: 11, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: locale
            ),
            "Yesterday 16:58:57"
        )
    }

    func testSameCalendarWeekAddsWeekday() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2026, month: 6, day: 10, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: locale
            ),
            "Wed 16:58:57"
        )
    }

    func testSameYearAddsMonthAndDay() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2026, month: 1, day: 5, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: locale
            ),
            "Jan 5, 16:58:57"
        )
    }

    func testDifferentYearAddsYear() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2025, month: 12, day: 31, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: locale
            ),
            "Dec 31, 2025, 16:58:57"
        )
    }

    func testSameYearDateContextUsesLocaleTemplateOrder() throws {
        XCTAssertEqual(
            try MessageTimestampFormatter.string(
                from: date(year: 2026, month: 1, day: 5, hour: 16, minute: 58, second: 57),
                includeDateContext: true,
                now: date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                calendar: calendar,
                locale: Locale(identifier: "es_ES")
            ),
            "5 ene, 16:58:57"
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
