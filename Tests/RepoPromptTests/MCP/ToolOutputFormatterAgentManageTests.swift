import MCP
@testable import RepoPromptApp
import XCTest

final class ToolOutputFormatterAgentManageTests: XCTestCase {
    func testListAgentsCollapsesGpt56MaxUltraVariantsWithoutInvalidNestedIDs() throws {
        let value: Value = .object([
            "agents": .array([
                .object([
                    "name": .string("Codex"),
                    "available": .bool(true),
                    "default_model_id": .string("codex:gpt-5.6-sol-low"),
                    "models": .array([
                        model(id: "codex:gpt-5.6-sol-low", name: "GPT-5.6 Sol Low", effort: "low"),
                        model(id: "codex:gpt-5.6-sol-xhigh", name: "GPT-5.6 Sol XHigh", effort: "xhigh"),
                        model(id: "codex:gpt-5.6-sol-max", name: "GPT-5.6 Sol Max", effort: "max"),
                        model(id: "codex:gpt-5.6-sol-ultra", name: "GPT-5.6 Sol Ultra", effort: "ultra"),
                        model(id: "codex:gpt-5.1-codex-max", name: "GPT-5.1 Codex Max", effort: nil)
                    ])
                ])
            ])
        ])

        let text = try onlyText(ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_agents")], value: value))

        XCTAssertTrue(text.contains("`codex:gpt-5.6-sol-{low|xhigh|max|ultra}` — GPT-5.6 Sol"), text)
        XCTAssertEqual(text.components(separatedBy: "gpt-5.6-sol-{").count - 1, 1, text)
        XCTAssertFalse(text.contains("gpt-5.6-sol-ultra-{ultra}"), text)
        XCTAssertFalse(text.contains("gpt-5.6-sol-ultra-ultra"), text)
        XCTAssertFalse(text.contains("GPT-5.6 Sol Ultra"), text)
        XCTAssertTrue(text.contains("`codex:gpt-5.1-codex-max` — GPT-5.1 Codex Max"), text)
    }

    private func model(id: String, name: String, effort: String?) -> Value {
        var object: [String: Value] = [
            "model_id": .string(id),
            "name": .string(name)
        ]
        if let effort {
            object["reasoning_effort"] = .string(effort)
        }
        return .object(object)
    }

    private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
