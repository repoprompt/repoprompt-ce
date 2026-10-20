import Foundation
@testable import RepoPromptSettingsCore
import XCTest

final class AgentRepromptGuidanceTests: XCTestCase {
    func testNormalizationAndLimitDoNotTruncate() throws {
        XCTAssertNil(AgentRepromptGuidance.normalizedOverride(" \n\t"))
        XCTAssertEqual(AgentRepromptGuidance.normalizedOverride("  my\n voice \n"), "my\n voice")
        XCTAssertEqual(AgentRepromptGuidance.effectiveText(nil), AgentRepromptGuidance.defaultText)
        XCTAssertTrue(AgentRepromptGuidance.isWithinLimit(String(repeating: "a", count: 16384)))
        let oversized = String(repeating: "é", count: 8193)
        XCTAssertFalse(AgentRepromptGuidance.isWithinLimit(oversized))
        XCTAssertEqual(AgentRepromptGuidance.normalizedOverride(oversized), oversized)
        XCTAssertEqual(try JSONDecoder().decode(AgentRepromptContextPolicy.self, from: Data("\"future\"".utf8)), .never)
        XCTAssertEqual(try JSONDecoder().decode(AgentRepromptContextPolicy.self, from: Data("\"never\"".utf8)), .never)
    }
}
