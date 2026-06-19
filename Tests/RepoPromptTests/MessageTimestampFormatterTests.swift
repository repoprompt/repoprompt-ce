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

    func testDateContextFormattingMatrix() throws {
        let cases: [(
            name: String,
            date: Date,
            includeDateContext: Bool,
            now: Date,
            locale: Locale,
            expected: String
        )] = try [
            (
                "disabled",
                date(year: 2025, month: 12, day: 31, hour: 3, minute: 4, second: 5),
                false,
                date(year: 2026, month: 6, day: 12, hour: 16, minute: 58, second: 57),
                locale,
                "03:04:05"
            ),
            (
                "today",
                date(year: 2026, month: 6, day: 12, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                locale,
                "16:58:57"
            ),
            (
                "yesterday",
                date(year: 2026, month: 6, day: 11, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                locale,
                "Yesterday 16:58:57"
            ),
            (
                "yesterday across midnight",
                date(year: 2026, month: 6, day: 11, hour: 23, minute: 59, second: 0),
                true,
                date(year: 2026, month: 6, day: 12, hour: 0, minute: 1, second: 0),
                locale,
                "Yesterday 23:59:00"
            ),
            (
                "same calendar week",
                date(year: 2026, month: 6, day: 10, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                locale,
                "Wed 16:58:57"
            ),
            (
                "same year",
                date(year: 2026, month: 1, day: 5, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                locale,
                "Jan 5, 16:58:57"
            ),
            (
                "different year",
                date(year: 2025, month: 12, day: 31, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                locale,
                "Dec 31, 2025, 16:58:57"
            ),
            (
                "localized date order",
                date(year: 2026, month: 1, day: 5, hour: 16, minute: 58, second: 57),
                true,
                date(year: 2026, month: 6, day: 12, hour: 17, minute: 0, second: 0),
                Locale(identifier: "es_ES"),
                "5 ene, 16:58:57"
            )
        ]

        for testCase in cases {
            XCTContext.runActivity(named: testCase.name) { _ in
                XCTAssertEqual(
                    MessageTimestampFormatter.string(
                        from: testCase.date,
                        includeDateContext: testCase.includeDateContext,
                        now: testCase.now,
                        calendar: calendar,
                        locale: testCase.locale
                    ),
                    testCase.expected
                )
            }
        }

        var losAngelesCalendar = try XCTUnwrap(calendar)
        losAngelesCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let timeZoneMessage = try date(year: 2026, month: 6, day: 11, hour: 23, minute: 30, second: 0)
        let timeZoneNow = try date(year: 2026, month: 6, day: 12, hour: 0, minute: 30, second: 0)
        let timeZoneCases = try [
            (name: "UTC yesterday", calendar: XCTUnwrap(calendar), expected: "Yesterday 23:30:00"),
            (name: "Los Angeles today", calendar: losAngelesCalendar, expected: "16:30:00")
        ]

        for testCase in timeZoneCases {
            XCTContext.runActivity(named: testCase.name) { _ in
                XCTAssertEqual(
                    MessageTimestampFormatter.string(
                        from: timeZoneMessage,
                        includeDateContext: true,
                        now: timeZoneNow,
                        calendar: testCase.calendar,
                        locale: locale
                    ),
                    testCase.expected
                )
            }
        }
    }

    func testNextRefreshDateUsesCalendarMidnightAcrossDST() throws {
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try date(
            year: 2026,
            month: 3,
            day: 8,
            hour: 0,
            minute: 30,
            second: 0,
            calendar: newYorkCalendar
        )
        let expected = try date(
            year: 2026,
            month: 3,
            day: 9,
            hour: 0,
            minute: 0,
            second: 0,
            calendar: newYorkCalendar
        )

        let refresh = MessageTimestampBoundaryClock.nextRefreshDate(after: now, calendar: newYorkCalendar)

        XCTAssertEqual(refresh, expected)
        XCTAssertEqual(refresh.timeIntervalSince(now), 22.5 * 60 * 60)
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        calendar explicitCalendar: Calendar? = nil
    ) throws -> Date {
        let calendar = explicitCalendar ?? calendar!
        return try XCTUnwrap(calendar.date(from: DateComponents(
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
