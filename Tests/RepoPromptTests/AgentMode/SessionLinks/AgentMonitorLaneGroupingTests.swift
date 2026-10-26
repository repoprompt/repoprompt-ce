@testable import RepoPromptApp
import XCTest

/// The Overseeing list's rule placement.
///
/// A rule carries exactly one claim — a complete lane block ended and the next begins — so it may
/// never fall after the last lane, where the section's own `Divider()` already ends the list.
final class AgentMonitorLaneGroupingTests: XCTestCase {
    private func separatorFlags(laneCount: Int) -> [Bool] {
        (0 ..< laneCount).map { AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: $0, of: laneCount) }
    }

    func testSeparatorFallsBetweenLanesAndNeverAfterTheLast() {
        XCTAssertEqual(separatorFlags(laneCount: 1), [false])
        XCTAssertEqual(separatorFlags(laneCount: 2), [true, false])
        XCTAssertEqual(separatorFlags(laneCount: 4), [true, true, true, false])
    }

    func testSeparatorCountIsAlwaysOneFewerThanLaneCount() {
        for laneCount in 1 ... 8 {
            XCTAssertEqual(
                separatorFlags(laneCount: laneCount).count(where: { $0 }),
                laneCount - 1,
                "lane count \(laneCount)"
            )
        }
    }

    func testEmptyListDrawsNoSeparator() {
        XCTAssertFalse(AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: 0, of: 0))
    }

    func testOutOfRangeIndicesDrawNoSeparator() {
        XCTAssertFalse(AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: -1, of: 3))
        XCTAssertFalse(AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: 3, of: 3))
        XCTAssertFalse(AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: 9, of: 3))
    }
}
