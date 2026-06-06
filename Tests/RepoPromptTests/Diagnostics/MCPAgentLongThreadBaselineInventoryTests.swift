@testable import RepoPrompt
import XCTest

final class MCPAgentLongThreadBaselineInventoryTests: XCTestCase {
    func testBaselineInventoryIsPayloadFreeAndCoversRequiredItemZeroSeams() throws {
        let snapshot = MCPAgentLongThreadBaselineInventory.debugSnapshot

        XCTAssertEqual(snapshot["payload_logging"] as? Bool, false)
        XCTAssertEqual(snapshot["baseline_revision"] as? String, "862413d32919019dfd96e58115479eae630c1883")
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.baselines.map(\.executedTests), [5, 6, 3])
        XCTAssertEqual(
            MCPAgentLongThreadBaselineInventory.baselines.map(\.command),
            [
                "make dev-test FILTER=AgentModeRunServiceLifecycleTests",
                "make dev-test FILTER=AgentModeViewModelInactiveRefreshTests",
                "make dev-test FILTER=PersistentMCPDistinctConnectionConcurrencyTests"
            ]
        )
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.baselines.map(\.elapsedSeconds), [0.891, 0.061, 4.266])
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.activeAgentSessionIDWriterInventory.count, 17)
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.activeAgentSessionIDConstructionInventory.count, 3)
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.agentRunSessionStorePublisherInventory.count, 9)
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.agentRunSessionStoreRegistrationAndResetInventory.count, 5)
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.agentRunSessionStoreCleanupInventory.count, 6)
        XCTAssertEqual(MCPAgentLongThreadBaselineInventory.receiveStreamTerminalBehavior.count, 3)
        XCTAssertTrue(MCPAgentLongThreadBaselineInventory.mainActorConstraint.contains("no Sendable conformance"))

        let encoded = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let rendered = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbiddenKey in ["prompt_text", "transcript_text", "tool_arguments", "tool_result", "provider_payload"] {
            XCTAssertFalse(rendered.contains(forbiddenKey))
        }
    }
}
