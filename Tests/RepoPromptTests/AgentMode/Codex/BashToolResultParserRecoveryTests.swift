import Foundation
@testable import RepoPromptApp
import XCTest

final class BashToolResultParserRecoveryTests: XCTestCase {
    func testParserKeepsCommandLivenessAndMetadataContractsInSync() {
        let runningPayload = #"{"type":"commandExecution","status":"inProgress","processId":"12345","commandLine":"/bin/zsh -lc 'cd /tmp && npm run dev'","delta":"booting\n"}"#

        let running = BashToolResultParser.parse(raw: runningPayload, argsJSON: nil)
        let runningMetadata = BashToolResultParser.parseMetadata(raw: runningPayload)

        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.command, "npm run dev")
        XCTAssertEqual(running.output, "booting\n")
        XCTAssertEqual(running.statusWord, "inprogress")
        XCTAssertEqual(running.processID, "12345")
        XCTAssertEqual(runningMetadata.isRunning, running.isRunning)
        XCTAssertEqual(runningMetadata.statusWord, running.statusWord)
        XCTAssertEqual(runningMetadata.processID, running.processID)

        let terminalPayload = #"{"type":"commandExecution","status":"failed","processId":"12345","durationMs":1200,"aggregatedOutput":"done\n","summary_only":true}"#
        let fallbackArgsJSON = #"{"invocation":{"arguments":"{\"cmd\":\"pnpm lint\"}"}}"#

        let terminal = BashToolResultParser.parse(raw: terminalPayload, argsJSON: fallbackArgsJSON)
        let terminalMetadata = BashToolResultParser.parseMetadata(raw: terminalPayload)

        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(terminal.command, "pnpm lint")
        XCTAssertEqual(terminal.output, "done\n")
        XCTAssertEqual(terminal.statusWord, "failed")
        XCTAssertTrue(terminal.isSummaryOnly)
        XCTAssertEqual(terminalMetadata.isRunning, terminal.isRunning)
        XCTAssertEqual(terminalMetadata.statusWord, terminal.statusWord)
        XCTAssertEqual(terminalMetadata.isSummaryOnly, terminal.isSummaryOnly)
    }
}

final class CodexCommandExecutionTranscriptProjectionTests: XCTestCase {
    func testRunningUpdateTargetsExactInvocationWithoutChangingSibling() {
        let invocationID = UUID()
        let sibling = AgentChatItem(
            kind: .toolResult,
            text: "",
            toolName: "bash",
            toolInvocationID: UUID(),
            toolResultJSON: #"{"type":"commandExecution","status":"inProgress","processId":"sibling","aggregatedOutput":"keep"}"#,
            toolIsError: false
        )
        var items = [
            AgentChatItem(kind: .toolCall, text: "", toolName: "bash", toolInvocationID: invocationID),
            sibling
        ]
        let originalID = items[0].id
        let update = CodexNativeSessionController.CommandExecutionRunningUpdate(
            invocationID: invocationID,
            processID: "target",
            appendedOutput: "booting\n"
        )

        XCTAssertTrue(CodexNativeSessionController.applyCommandExecutionRunningUpdate(update, to: &items))

        XCTAssertEqual(items[0].id, originalID)
        XCTAssertEqual(items[0].kind, .toolResult)
        XCTAssertEqual(items[0].toolIsError, false)
        let result = BashToolResultParser.parse(raw: items[0].toolResultJSON, argsJSON: nil)
        XCTAssertTrue(result.isRunning)
        XCTAssertEqual(result.processID, "target")
        XCTAssertEqual(result.output, "booting\n")
        XCTAssertEqual(items[1], sibling)
    }

    func testLateRunningUpdateCannotReviveCompletedResult() {
        let invocationID = UUID()
        let completed = AgentChatItem(
            kind: .toolResult,
            text: "",
            toolName: "bash",
            toolInvocationID: invocationID,
            toolResultJSON: #"{"type":"commandExecution","status":"completed","exitCode":0,"aggregatedOutput":"done"}"#,
            toolIsError: false
        )
        var items = [completed]
        let update = CodexNativeSessionController.CommandExecutionRunningUpdate(
            invocationID: invocationID,
            processID: "target",
            appendedOutput: "late"
        )

        XCTAssertFalse(CodexNativeSessionController.applyCommandExecutionRunningUpdate(update, to: &items))
        XCTAssertEqual(items, [completed])
    }

    func testUncorrelatedRunningUpdateDoesNotChooseBetweenTwoCommands() {
        let items = ["one", "two"].map { processID in
            AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: "bash",
                toolResultJSON: "{\"type\":\"commandExecution\",\"status\":\"inProgress\",\"processId\":\"\(processID)\"}",
                toolIsError: false
            )
        }
        var updated = items
        let update = CodexNativeSessionController.CommandExecutionRunningUpdate(
            invocationID: nil,
            processID: nil,
            appendedOutput: "unscoped"
        )

        XCTAssertFalse(CodexNativeSessionController.applyCommandExecutionRunningUpdate(update, to: &updated))
        XCTAssertEqual(updated, items)
    }
}
