@testable import RepoPromptApp
import XCTest

final class ClaudeContextUsedTokensBoundTests: XCTestCase {
    func testAcceptsReadingBelowKnownOneMillionCanonicalWindow() {
        XCTAssertEqual(
            ClaudeContextUsedTokensBound.normalizedReading(350_000, canonicalWindow: 1_000_000),
            350_000
        )
    }

    func testRejectsReadingAboveKnownTwoHundredKCanonicalWindow() {
        XCTAssertNil(
            ClaudeContextUsedTokensBound.normalizedReading(350_000, canonicalWindow: 200_000)
        )
    }

    func testAcceptsReadingBelowUnknownWindowGarbageCeiling() {
        XCTAssertEqual(
            ClaudeContextUsedTokensBound.normalizedReading(350_000, canonicalWindow: nil),
            350_000
        )
    }

    func testRejectsReadingAboveUnknownWindowGarbageCeiling() {
        XCTAssertNil(
            ClaudeContextUsedTokensBound.normalizedReading(15_000_000, canonicalWindow: nil)
        )
    }

    func testRejectsZeroOrNegativeReadings() {
        XCTAssertNil(ClaudeContextUsedTokensBound.normalizedReading(0, canonicalWindow: 1_000_000))
        XCTAssertNil(ClaudeContextUsedTokensBound.normalizedReading(-1, canonicalWindow: nil))
    }
}
