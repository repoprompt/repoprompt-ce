import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class OracleGroupDeliveryContractTests: XCTestCase {
    func testContractIsSilentForSingleLaneAndDescribesEveryLaneOtherwise() throws {
        let single = [OracleGroupDeliveryContract.Lane(laneIndex: 0, modelID: "m", chatID: "chat-0", status: "Completed", response: "x")]
        XCTAssertNil(OracleGroupDeliveryContract.preamble(lanes: single))
        XCTAssertNil(OracleGroupDeliveryContract.endMarker(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.followUpReminder(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.exportReadingRequirement(laneCount: 1))

        let preamble = OracleGroupDeliveryContract.preamble(lanes: [
            .init(laneIndex: 2, modelID: nil, chatID: "chat-2", status: "Failed", response: nil),
            .init(laneIndex: 1, modelID: "model-b", chatID: "chat-1", status: "Failed", response: " \n", partialResponse: "part\r\nial\n"),
            .init(laneIndex: 0, modelID: "model-a", chatID: "chat-0", status: "Completed", response: "one\ntwo\nthree\n")
        ])
        let text = try XCTUnwrap(preamble)
        XCTAssertTrue(text.contains(
            "3 independent answers to the same request follow. Lane order is not a ranking; "
                + "the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane."
        ), text)
        XCTAssertFalse(text.contains("only the chat that follow-ups continue"), text)
        XCTAssertTrue(text.contains("Read every lane through the end-of-group marker (`End of Oracle group: 3 lanes above.`)"), text)
        XCTAssertTrue(text.contains("read-only `oracle_chat_log` with that lane's chat ID"), text)
        XCTAssertTrue(text.contains("Do not start a follow-up just to retrieve prior text."), text)
        XCTAssertTrue(text.contains(
            "- Make the reconciliation visible to the user: begin your answer with `**Oracle reconciliation**`, "
                + "state how many lanes completed and name any that did not"
        ), text)
        XCTAssertTrue(text.contains("whether you accepted, rejected, or left it unresolved."), text)
        XCTAssertTrue(text.hasSuffix("""
        Lanes (3):
        - Oracle — `model-a` — Completed — chat ID `chat-0`
        - Oracle 2 — `model-b` — Failed (partial) — chat ID `chat-1`
        - Oracle 3 — model unspecified — Failed — chat ID `chat-2`
        """), text)
        XCTAssertFalse(text.contains(" line"), text)
    }

    func testLaneIsPartialOnlyWhenResponseIsBlankAndPartialIsNot() {
        let cases: [(response: String?, partial: String?, expected: Bool)] = [
            ("answer", nil, false),
            ("answer", "partial", false),
            (nil, "partial", true),
            (" \n\t", "partial", true),
            (nil, nil, false),
            (" \n", " \r\n", false)
        ]
        for (response, partial, expected) in cases {
            let lane = OracleGroupDeliveryContract.Lane(
                laneIndex: 0, modelID: nil, chatID: "chat-0", status: "Failed", response: response, partialResponse: partial
            )
            XCTAssertEqual(lane.isPartial, expected, "response: \(String(describing: response)), partial: \(String(describing: partial))")
        }
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
        XCTAssertTrue(text.contains("- Oracle 2 — `model-1` — Completed — chat ID `chat-1`\n"), text)
        XCTAssertTrue(text.hasSuffix("\n\nEnd of Oracle group: 2 lanes above.\n"), text)
        XCTAssertEqual(
            text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
            "End of Oracle group: 2 lanes above."
        )
        XCTAssertFalse(text.localizedCaseInsensitiveContains("synthesis"))
    }

    func testGroupedAskOracleEndMarkerStaysOnItsOwnLineWhenBlocksAreConcatenated() throws {
        var fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer")
        ])
        fields["oracle_export_path"] = .string("/tmp/prompt-exports/oracle.md")
        let blocks = texts(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))
        XCTAssertGreaterThanOrEqual(blocks.count, 2)

        let concatenated = blocks.joined()
        XCTAssertTrue(
            concatenated.contains("\nEnd of Oracle group: 2 lanes above.\n### Oracle export"),
            concatenated
        )
        XCTAssertFalse(concatenated.contains("lanes above.###"), concatenated)
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
        XCTAssertTrue(markdown.contains("- Oracle 2 — `model-1` — failed (partial) — chat ID `chat-1`"), markdown)
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
        XCTAssertTrue(grouped.contains("read through the \"End of Oracle group\" marker"), grouped)
        XCTAssertFalse(grouped.contains("read it to the end"), grouped)
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
