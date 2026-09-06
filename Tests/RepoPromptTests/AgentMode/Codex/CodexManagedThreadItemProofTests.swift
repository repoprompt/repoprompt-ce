@testable import RepoPromptApp
import XCTest

final class CodexManagedThreadItemProofTests: XCTestCase {
    func testReviewedTerminalToolShapesAndRequiredFields() throws {
        let items: [[String: Any]] = [
            ["id": "item", "type": "commandExecution", "command": "synthetic", "commandActions": [], "cwd": "/synthetic", "status": "completed"],
            ["id": "item", "type": "fileChange", "changes": [], "status": "declined"],
            ["id": "item", "type": "mcpToolCall", "server": "synthetic", "tool": "read", "arguments": NSNull(), "status": "completed"],
            ["id": "item", "type": "dynamicToolCall", "tool": "read", "arguments": NSNull(), "status": "failed"]
        ]
        for item in items {
            XCTAssertFalse(try CodexManagedThreadItemProof.hasActiveWork(item))
            for key in item.keys {
                var missing = item
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try CodexManagedThreadItemProof.hasActiveWork(missing))
            }
            var active = item
            active["status"] = "inProgress"
            XCTAssertTrue(try CodexManagedThreadItemProof.hasActiveWork(active))
            active["status"] = "unknown"
            XCTAssertThrowsError(try CodexManagedThreadItemProof.hasActiveWork(active))
        }
    }

    func testAmbiguousNativeActivityNeverProducesIdleProof() {
        for item in [
            ["id": "item", "type": "imageGeneration", "result": "", "status": "unknown"],
            ["id": "item", "type": "subAgentActivity", "agentPath": "synthetic", "agentThreadId": "child", "kind": "started"],
            ["id": "item", "type": "unknown"]
        ] {
            XCTAssertThrowsError(try CodexManagedThreadItemProof.hasActiveWork(item))
        }
    }

    func testSummaryHistoryCannotHideToolLiveness() {
        for view in ["notLoaded", "summary", "unknown"] {
            let response: [String: Any] = ["thread": [
                "id": "thread",
                "modelProvider": CodexManagedHTTPPolicy.providerID,
                "status": ["type": "idle"],
                "turns": [["id": "turn", "status": "completed", "itemsView": view, "items": []]]
            ]]
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.threadProof(
                response: response, loaded: ["data": ["thread"]], expectedThreadID: "thread", pendingMutation: false, persistedTools: []
            ))
        }
    }
}
