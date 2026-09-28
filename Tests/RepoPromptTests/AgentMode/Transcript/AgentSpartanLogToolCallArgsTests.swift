import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSpartanLogToolCallArgsTests: XCTestCase {
    /// ACP sessions can persist an extra result-only row for an invocation that carries no
    /// arguments. `get_log` must never render that row's result summary as call arguments.
    func testArgumentlessResultRowDoesNotRenderResultSummaryAsToolCallArguments() throws {
        let invocationID = try XCTUnwrap(UUID(uuidString: "5FEFEE94-C090-6110-3C8E-446954A46B9D"))
        let argsJSON = #"{"count":10,"op":"log","repo_root":"/repo"}"#
        let summaryOnlyResult = #"{"status":"success","summary_only":true,"summary_text":"git • success"}"#
        var resultWithArgs = AgentChatItem.toolResult(
            name: "git",
            invocationID: invocationID,
            resultJSON: #"{"status":"success","summary_only":true,"summary_text":"log • 10 commits"}"#,
            isError: false,
            sequenceIndex: 2
        )
        resultWithArgs.toolArgsJSON = argsJSON
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("review", sequenceIndex: 0),
            .assistant("Surveying the branch.", sequenceIndex: 1),
            resultWithArgs,
            .toolResult(
                name: "git",
                invocationID: invocationID,
                resultJSON: summaryOnlyResult,
                isError: false,
                sequenceIndex: 3
            ),
            .assistant("Done.", sequenceIndex: 4)
        ])

        let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript)
        let toolCallLines = xml.split(separator: "\n").filter { $0.contains("<tool_call") }

        XCTAssertTrue(xml.contains(#"<tool_call name="git">{"count":10,"op":"log","repo_root":"\/repo"}</tool_call>"#), xml)
        XCTAssertFalse(toolCallLines.isEmpty, xml)
        for line in toolCallLines {
            XCTAssertFalse(line.contains("summary_only"), "tool result leaked into call arguments: \(line)")
            XCTAssertFalse(line.contains(#""status":"success""#), "tool result leaked into call arguments: \(line)")
        }
    }

    func testResultRowWithoutArgumentsRendersSelfClosingToolCall() throws {
        let invocationID = try XCTUnwrap(UUID(uuidString: "2666DF4C-7171-F7D7-A704-10EEAA560EF2"))
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("review", sequenceIndex: 0),
            .assistant("Checking status.", sequenceIndex: 1),
            .toolResult(
                name: "ask_oracle",
                invocationID: invocationID,
                resultJSON: #"{"status":"success","summary_only":true}"#,
                isError: false,
                sequenceIndex: 2
            ),
            .assistant("Done.", sequenceIndex: 3)
        ])

        let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript)

        XCTAssertTrue(xml.contains(#"<tool_call name="ask_oracle"/>"#), xml)
        XCTAssertFalse(xml.contains("summary_only"), xml)
    }
}
