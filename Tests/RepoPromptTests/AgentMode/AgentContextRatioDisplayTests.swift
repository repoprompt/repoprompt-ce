@testable import RepoPromptApp
import XCTest

final class AgentContextRatioDisplayTests: XCTestCase {
    func testDisplayedPercentAndDenominatorTruthTable() {
        XCTAssertNil(AgentContextRatioDisplay.displayedPercent(used: 120_000, window: 400_000, isKnown: false))
        XCTAssertEqual(
            AgentContextRatioDisplay.denominatorText(window: 400_000, isKnown: false),
            AgentContextRatioDisplay.unknownPlaceholder
        )

        XCTAssertEqual(
            AgentContextRatioDisplay.displayedPercent(used: 120_000, window: 400_000, isKnown: true),
            30
        )
        XCTAssertEqual(
            AgentContextRatioDisplay.denominatorText(window: 400_000, isKnown: true),
            AgentContextIndicator.formatTokens(400_000)
        )

        XCTAssertEqual(
            AgentContextRatioDisplay.displayedPercent(used: 500_000, window: 400_000, isKnown: true),
            100
        )
        XCTAssertNil(AgentContextRatioDisplay.displayedPercent(used: nil, window: 400_000, isKnown: true))
    }
}
