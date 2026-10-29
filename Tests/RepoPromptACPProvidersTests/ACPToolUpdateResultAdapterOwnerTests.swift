import Foundation
import RepoPromptACPProviders
import XCTest

final class ACPToolUpdateResultAdapterOwnerTests: XCTestCase {
    func testTerminalResultPreservesPayloadsAndRejectsAmbiguousChatIdentity() throws {
        for ambiguous in [false, true] {
            var rawOutput: [String: Any] = ["success": true, "chat_id": "root-id"]
            if ambiguous { rawOutput["nested"] = ["chat_id": "other-id"] }
            let payload: [String: Any] = [
                "status": "completed", "title": " fixture ", "kind": "other",
                "rawOutput": rawOutput, "rawInput": ["path": "File.swift"],
                "content": ["payload"], "unrelated": "preserved"
            ]
            let adapted = ACPToolUpdateResultAdapter.adaptedTerminalToolUpdatePayload(payload, sessionUpdate: "tool_call_update")
            let result = try XCTUnwrap(adapted["rawOutput"] as? [String: Any])
            XCTAssertEqual(adapted["unrelated"] as? String, "preserved")
            XCTAssertEqual(result["status"] as? String, "success")
            XCTAssertEqual(result["acp_status"] as? String, "completed")
            XCTAssertEqual(result["title"] as? String, "fixture")
            XCTAssertEqual(result["rawOutput"] as? NSDictionary, rawOutput as NSDictionary)
            XCTAssertEqual(result["rawInput"] as? NSDictionary, ["path": "File.swift"] as NSDictionary)
            XCTAssertEqual(result["content"] as? [String], ["payload"])
            XCTAssertEqual(result["chat_id"] as? String, ambiguous ? nil : "root-id")
        }
    }
}
