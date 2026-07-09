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
