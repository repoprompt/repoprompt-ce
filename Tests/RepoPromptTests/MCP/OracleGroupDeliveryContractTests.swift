import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class OracleGroupDeliveryContractTests: XCTestCase {
    func testContractIsSilentForSingleLaneAndDescribesEveryLaneOtherwise() throws {
        let single = [OracleGroupDeliveryContract.Lane(laneIndex: 0, modelID: "m", status: "Completed", response: "x")]
        XCTAssertNil(OracleGroupDeliveryContract.preamble(lanes: single))
        XCTAssertNil(OracleGroupDeliveryContract.endMarker(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.followUpReminder(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.exportReadingRequirement(laneCount: 1))

        let preamble = OracleGroupDeliveryContract.preamble(lanes: [
            .init(laneIndex: 2, modelID: nil, status: "Failed", response: nil),
            .init(laneIndex: 1, modelID: "model-b", status: "Failed", response: nil, partialResponse: "part\r\nial\n"),
            .init(laneIndex: 0, modelID: "model-a", status: "Completed", response: "one\ntwo\nthree\n")
        ])
        let text = try XCTUnwrap(preamble)
        XCTAssertTrue(text.contains("3 independent answers to the same request follow. Lane order is not a ranking"), text)
        XCTAssertTrue(text.contains("Read every lane through the line `End of Oracle group: 3 lanes above.`"), text)
        XCTAssertTrue(text.hasSuffix("""
        Lanes (3):
        - Oracle — `model-a` — Completed — 3 lines
        - Oracle 2 — `model-b` — Failed — 2 lines (partial)
        - Oracle 3 — model unspecified — Failed — 0 lines
        """), text)
    }

    func testInlineGroupPutsGuidanceBeforeLanesAndEndMarkerLast() throws {
        let fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer\nsecond line")
        ], warnings: [OracleGroupWarning(code: "slow_lane", message: "Lane was slow")])
        let text = joinedText(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))

        let guidance = try XCTUnwrap(text.range(of: "**Reconciling these Oracle lanes**"))
        let firstLane = try XCTUnwrap(text.range(of: "\n### Oracle\n"))
        let warning = try XCTUnwrap(text.range(of: "Warning [slow_lane]"))
        XCTAssertLessThan(guidance.lowerBound, firstLane.lowerBound)
        XCTAssertLessThan(firstLane.lowerBound, warning.lowerBound)
        XCTAssertTrue(text.contains("- Oracle 2 — `model-1` — Completed — 2 lines"), text)
        XCTAssertTrue(text.hasSuffix("\n\nEnd of Oracle group: 2 lanes above."), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("synthesis"))
    }

    func testOracleExportLayoutMovesGroupedResponsesAheadOfPromptAndSelection() throws {
        let raw: Value = try .object([
            "prompt": .string("the final prompt"),
            "selection": .string("the selection"),
            "response_type": .string("review"),
            "review": .object(groupFields(lanes: [lane(index: 0, response: "a"), lane(index: 1, response: "b")]))
        ])
        let inline = joinedText(ToolOutputFormatter.formatDiscoverContext(value: raw))
        let export = joinedText(ToolOutputFormatter.formatDiscoverContext(value: raw, layout: .oracleExport))

        XCTAssertLessThan(
            try XCTUnwrap(inline.range(of: "## Final Prompt")).lowerBound,
            try XCTUnwrap(inline.range(of: "## Code Review")).lowerBound
        )
        XCTAssertTrue(export.hasPrefix("## Code Review"), export)
        XCTAssertLessThan(
            try XCTUnwrap(export.range(of: "End of Oracle group: 2 lanes above.")).lowerBound,
            try XCTUnwrap(export.range(of: "## Final Prompt")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(export.range(of: "## Final Prompt")).lowerBound,
            try XCTUnwrap(export.range(of: "## Selection")).lowerBound
        )
    }

    func testOracleExportLayoutKeepsSingleLaneOutputUnchanged() {
        let raw: Value = .object([
            "prompt": .string("the final prompt"),
            "selection": .string("the selection"),
            "response_type": .string("plan"),
            "plan": .object(["chat_id": .string("chat-0"), "response": .string("only answer")])
        ])
        let inline = texts(ToolOutputFormatter.formatDiscoverContext(value: raw))
        // Pre-change layout: context block first, then the plan heading block prefixed by the section separator.
        XCTAssertEqual(inline.first, "## Final Prompt\nthe final prompt\n\n## Selection\nthe selection")
        XCTAssertEqual(inline.dropFirst().first, "\n\n---\n\n## Generated Plan\n")
        XCTAssertEqual(texts(ToolOutputFormatter.formatDiscoverContext(value: raw, layout: .oracleExport)), inline)
    }

    func testGroupedExportFileFramesLanesWithManifestAndEndMarker() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: .partialFailure,
            oracleResults: [
                lane(index: 0, response: "primary answer"),
                OracleLaneResult(
                    laneIndex: 1,
                    chatID: "chat-1",
                    providerID: "provider-1",
                    modelID: "model-1",
                    status: .failed,
                    error: OracleLaneError(code: "provider_failed", message: "failed", partialResponse: "partial")
                )
            ]
        )
        let markdown = AgentOracleExport.oracleMarkdown(request: OracleExportRequest(
            sourceTool: "ask_oracle",
            mode: "review",
            message: "Review it",
            chatID: "chat-0",
            response: "primary answer",
            groupResult: group
        ))

        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "**Reconciling these Oracle lanes**")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Oracle results")).lowerBound
        )
        XCTAssertTrue(markdown.contains("- Oracle 2 — `model-1` — failed — 1 line (partial)"), markdown)
        XCTAssertTrue(markdown.hasSuffix("\n\nEnd of Oracle group: 2 lanes above."), markdown)
    }

    func testExportInstructionAddsReadingRequirementOnlyForGroups() {
        let path = "/tmp/prompt-exports/oracle \"review\".md"
        let single = AgentOracleExport.instruction(path: path)
        XCTAssertEqual(AgentOracleExport.instruction(path: path, oracleLaneCount: 1), single)
        XCTAssertFalse(single.contains("End of Oracle group"))

        let grouped = AgentOracleExport.instruction(path: path, oracleLaneCount: 3)
        XCTAssertTrue(grouped.hasPrefix(single + " "), grouped)
        XCTAssertTrue(grouped.contains("The file contains 3 independent Oracle lanes"), grouped)
    }

    func testGroupedFollowUpHintIsNeutralAndSingleLaneHintIsUnchanged() {
        let continuation = "Continue this plan conversation with ask_oracle(chat_id: \"chat-0\", new_chat: false)"
        for count in [nil, 1] as [Int?] {
            XCTAssertEqual(
                MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: count),
                continuation
            )
        }

        let grouped = MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: 3)
        XCTAssertTrue(grouped.hasPrefix("The 3 Oracle lanes above are independent answers"), grouped)
        XCTAssertTrue(grouped.hasSuffix("\n\nOptional later follow-up: " + continuation), grouped)
        XCTAssertFalse(grouped.contains("returned ordered"))
    }

    // MARK: - Helpers

    private func lane(index: Int, response: String) throws -> OracleLaneResult {
        try OracleLaneResult(
            laneIndex: index,
            chatID: "chat-\(index)",
            providerID: "provider-\(index)",
            modelID: "model-\(index)",
            status: .completed,
            response: response
        )
    }

    private func groupFields(lanes: [OracleLaneResult], warnings: [OracleGroupWarning] = []) throws -> [String: Value] {
        let result = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: warnings.isEmpty ? .completed : .partialFailure,
            oracleResults: lanes,
            warnings: warnings
        )
        return ContextBuilderOracleGroupReply(result: result).toMCPFields()
    }

    private func texts(_ blocks: [MCP.Tool.Content]) -> [String] {
        blocks.compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }
    }

    private func joinedText(_ blocks: [MCP.Tool.Content]) -> String {
        texts(blocks).joined(separator: "\n")
    }
}
