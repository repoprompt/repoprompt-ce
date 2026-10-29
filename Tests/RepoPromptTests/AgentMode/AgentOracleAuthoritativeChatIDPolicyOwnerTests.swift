import Foundation
import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentOracleAuthoritativeChatIDPolicyOwnerTests: XCTestCase {
    func testAuthoritativeChatIDPolicyPreservesFailClosedRootRulesAcrossEntryPoints() {
        let acceptedPayloads: [([String: Any], String)] = [
            (["chat_id": "  exact-chat  "], "exact-chat"),
            (["chat_id": "exact-with-unrelated-data", "diffs": [["path": 42]]], "exact-with-unrelated-data")
        ]
        for (payload, expected) in acceptedPayloads {
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload),
                expected
            )
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)),
                expected
            )
        }

        let rejectedPayloads: [[String: Any]] = [
            [:],
            ["chatID": "camel-only"],
            ["chat_id": "exact", "chatID": "alias"],
            ["chat_id": 42],
            ["chat_id": "  \n"],
            ["chat_id": "exact", "result": ["chat_id": "nested"]],
            ["chat_id": "exact", "items": [["chatID": "nested"]]]
        ]
        for payload in rejectedPayloads {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload))
            )
        }

        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: nil))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "  \n"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "not-json"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "null"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "42"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "[]"))
    }

    func testAuthoritativeChatIDPolicyRoutesCanonicalGroupsWithoutAdmittingConflictingIDs() {
        let lanes: [[String: Any]] = [
            ["lane_index": 0, "role": "primary", "chat_id": "primary-chat", "model_id": "primary-model", "status": "completed"],
            ["lane_index": 1, "role": "additional", "chat_id": "additional-chat", "model_id": "additional-model", "status": "completed"]
        ]
        let digest: [String: Any] = [
            "chat_id": "primary-chat", "oracle_group_id": UUID().uuidString,
            "oracle_count": 2, "oracle_results": lanes, "status": "success", "summary_only": true
        ]
        var live = digest
        live["oracle_results"] = lanes.map { $0.merging(["response": "answer"]) { current, _ in current } }
        live["status"] = "completed"
        live.removeValue(forKey: "summary_only")
        for payload in [digest, live] {
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload), "primary-chat")
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)), "primary-chat")
        }

        var rejected: [[String: Any]] = []
        for changes: [String: Any] in [
            ["chat_id": "wrong-primary"], ["oracle_count": 3], ["oracle_group_id": "not-a-group-id"],
            ["chatID": "alias"], ["result": ["chat_id": "unrelated"]]
        ] {
            rejected.append(digest.merging(changes) { _, new in new })
        }
        var missingGroup = digest
        missingGroup.removeValue(forKey: "oracle_group_id")
        rejected.append(missingGroup)
        for changes: [String: Any] in [
            ["lane_index": 0], ["lane_index": true], ["role": "primary"], ["chat_id": "primary-chat"],
            ["chat_id": "  "], ["chatID": "alias"], ["result": ["chat_id": "nested"]], ["status": "unknown"]
        ] {
            var malformedLanes = lanes
            malformedLanes[1].merge(changes) { _, new in new }
            var payload = digest
            payload["oracle_results"] = malformedLanes
            rejected.append(payload)
        }
        for payload in rejected {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)))
            XCTAssertFalse(AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: jsonString(payload)))
        }
    }

    private func jsonString(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
