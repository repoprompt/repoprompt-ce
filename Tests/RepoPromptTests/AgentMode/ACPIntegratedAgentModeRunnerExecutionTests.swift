@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class ACPIntegratedAgentModeRunnerExecutionTests: XCTestCase {
    func testCompletedTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .completed,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.completed(assistantText: nil))
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.completed)]
        )
    }

    func testCancelledTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .cancelled,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.cancelled())
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.cancelled)]
        )
    }

    func testFailedTerminalPreservesProviderErrorText() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: "ACP provider refused the turn."
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.failed(assistantText: "ACP provider refused the turn."))
        )
        XCTAssertEqual(classification.errorText, "ACP provider refused the turn.")
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testFailedTerminalPreservesAbsentProviderErrorTextForSettlement() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: nil
        )

        guard case let .terminal(outcome) = classification.result else {
            return XCTFail("Expected terminal classification")
        }
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testSupersededExecutionRemainsNonterminal() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientSupersession()

        XCTAssertEqual(classification.result, .superseded)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .executionSuperseded]
        )
    }
}
