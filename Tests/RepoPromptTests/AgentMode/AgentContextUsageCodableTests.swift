import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentContextUsageCodableTests: XCTestCase {
    func testDecodesLegacyPayloadWithoutConfiguredContextWindow() throws {
        let json = #"{"modelContextWindow":1000000,"lastTotalTokens":1234,"totalTotalTokens":5678}"#
        let usage = try JSONDecoder().decode(AgentContextUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.modelContextWindow, 1_000_000)
        XCTAssertNil(usage.configuredContextWindow)
        XCTAssertEqual(usage.lastTotalTokens, 1234)
        XCTAssertEqual(usage.totalTotalTokens, 5678)
    }

    func testEncodesAndDecodesConfiguredContextWindow() throws {
        let usage = AgentContextUsage(
            modelContextWindow: 1_000_000,
            configuredContextWindow: 400_000,
            lastTotalTokens: 1234,
            totalTotalTokens: 5678
        )

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(AgentContextUsage.self, from: data)

        XCTAssertEqual(decoded.modelContextWindow, 1_000_000)
        XCTAssertEqual(decoded.configuredContextWindow, 400_000)
        XCTAssertEqual(decoded.lastTotalTokens, 1234)
        XCTAssertEqual(decoded.totalTotalTokens, 5678)
    }
}
