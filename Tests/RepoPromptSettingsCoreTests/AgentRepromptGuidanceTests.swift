import Foundation
@testable import RepoPromptSettingsCore
import XCTest

final class AgentRepromptGuidanceTests: XCTestCase {
    func testNormalizationAndLimitDoNotTruncate() {
        XCTAssertNil(AgentRepromptGuidance.normalizedOverride(" \n\t"))
        XCTAssertEqual(AgentRepromptGuidance.normalizedOverride("  my\n voice \n"), "my\n voice")
        XCTAssertEqual(AgentRepromptGuidance.effectiveText(nil), AgentRepromptGuidance.defaultText)
        XCTAssertTrue(AgentRepromptGuidance.isWithinLimit(String(repeating: "a", count: 16384)))
        let oversized = String(repeating: "é", count: 8193)
        XCTAssertFalse(AgentRepromptGuidance.isWithinLimit(oversized))
        XCTAssertEqual(AgentRepromptGuidance.normalizedOverride(oversized), oversized)
        XCTAssertTrue(AgentRepromptGuidance.defaultText.contains("Markdown"))
        XCTAssertTrue(AgentRepromptGuidance.defaultText.contains("near-identically"))
        XCTAssertFalse(AgentRepromptGuidance.defaultText.contains("Context Builder"))
    }
}
