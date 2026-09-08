import MCP
@testable import RepoPromptApp
import XCTest

/// Crash-class guard for model-supplied numeric arguments.
///
/// The MCP `Value` decoder falls back to `.double` for any JSON numeral that does not fit `Int`, and
/// no schema validation runs between the transport and these services, so a literal like `1e300`
/// reaches the argument parsers directly. `Int(someDouble)` traps on those values; every numeric
/// parser must saturate and let the surrounding clamp decide instead.
@MainActor
final class AgentMCPNumericArgumentParsingTests: XCTestCase {
    func testSessionLinkParseIntSaturatesOutOfRangeDoublesInsteadOfTrapping() {
        XCTAssertEqual(AgentSessionLinkMCPToolService.parseInt(.double(1e300)), Int.max)
        XCTAssertEqual(AgentSessionLinkMCPToolService.parseInt(.double(-1e300)), Int.min)
        XCTAssertNil(AgentSessionLinkMCPToolService.parseInt(.double(.nan)))
        XCTAssertNil(AgentSessionLinkMCPToolService.parseInt(.double(.infinity)))
        // In-range doubles keep truncating toward zero, as before.
        XCTAssertEqual(AgentSessionLinkMCPToolService.parseInt(.double(12.7)), 12)

        // End state the caller actually sees: an ordinary clamped budget, not a crash.
        XCTAssertEqual(
            AgentSessionLinkTranscriptBudget.clampedMaxItems(
                AgentSessionLinkMCPToolService.parseInt(.double(1e300))
            ),
            AgentSessionLinkTranscriptBudget.maximumMaxItems
        )
    }

    func testAgentManageClampedIntSaturatesOutOfRangeDoublesInsteadOfTrapping() throws {
        func clamped(_ value: Value) throws -> Int {
            try AgentManageMCPToolService.clampedInt(
                value,
                name: "max_transcript_items",
                defaultValue: 200,
                minValue: 1,
                maxValue: 1000
            )
        }

        XCTAssertEqual(try clamped(.double(1e300)), 1000)
        XCTAssertEqual(try clamped(.double(-1e300)), 1)
        XCTAssertEqual(try clamped(.double(12.7)), 12)
        // Non-finite values remain a validation error rather than a silent clamp.
        XCTAssertThrowsError(try clamped(.double(.nan)))
        XCTAssertThrowsError(try clamped(.double(.infinity)))
    }
}
