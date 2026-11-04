@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeAutoCompactWindowTests: XCTestCase {
    func testAutoCompactWindowParsesOnlyPositiveIntegers() {
        let key = ClaudeAutoCompactWindow.environmentKey
        XCTAssertEqual(key, "CLAUDE_CODE_AUTO_COMPACT_WINDOW")
        XCTAssertEqual(ClaudeAutoCompactWindow.tokens(in: [key: "400000"]), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.tokens(in: [key: " 400000\n"]), 400_000)
        for invalid in ["", "0", "-1", "400k", "4e5"] {
            XCTAssertNil(ClaudeAutoCompactWindow.tokens(in: [key: invalid]), invalid)
        }
        XCTAssertNil(ClaudeAutoCompactWindow.tokens(in: [:]))
    }

    func testEffectiveWindowIsTheSmallerKnownWindow() {
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 1_000_000, autoCompactWindow: 400_000), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 200_000, autoCompactWindow: 400_000), 200_000, "Claude Code caps the setting at the model window")
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: nil, autoCompactWindow: 400_000), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 1_000_000, autoCompactWindow: nil), 1_000_000)
        XCTAssertNil(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: nil, autoCompactWindow: nil))

        XCTAssertNil(ClaudeAutoCompactWindow.cappedReportedWindow(nil, autoCompactWindow: 400_000), "No report invents no window")
        XCTAssertEqual(ClaudeAutoCompactWindow.cappedReportedWindow(0, autoCompactWindow: 400_000), 0, "A withdrawal signal passes through")
        XCTAssertEqual(ClaudeAutoCompactWindow.cappedReportedWindow(1_000_000, autoCompactWindow: 400_000), 400_000)
    }
}
