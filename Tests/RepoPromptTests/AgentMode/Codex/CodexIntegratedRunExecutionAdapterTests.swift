import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class CodexIntegratedRunExecutionAdapterTests: XCTestCase {
    func testAcceptedDispatchOutcomesPreserveNativeResultAndClassifyAsTransientCompletion() async {
        let queueID = UUID()
        let outcomes: [CodexAgentModeCoordinator.NativeSendOutcome] = [
            .sent,
            .queuedFallback(queueID: queueID, reason: .activeWithoutAuthoritativeIdentity)
        ]

        for outcome in outcomes {
            var invocationCount = 0
            let result = await CodexIntegratedRunExecutionAdapter.execute {
                invocationCount += 1
                return outcome
            }

            XCTAssertEqual(invocationCount, 1)
            XCTAssertEqual(result.nativeOutcome, outcome)
            XCTAssertEqual(
                result.executionReport,
                DomainAgentRunExecutionReport(
                    result: .terminal(.completed(assistantText: nil)),
                    trace: [.executionStarted, .terminalOutcomeProduced(.completed)]
                )
            )
            XCTAssertEqual(result.didStartProviderRun, outcome == .sent)
            XCTAssertFalse(result.shouldReleaseCreatedOwnership)
        }
    }

    func testRejectedDispatchOutcomesPreserveMessageAndClassifyAsTransientFailure() async {
        let fixtures: [(CodexAgentModeCoordinator.NativeSendOutcome, String)] = [
            (.preDispatchRejected(message: "pre-dispatch rejected"), "pre-dispatch rejected"),
            (.failed(message: "provider failed"), "provider failed")
        ]

        for (outcome, message) in fixtures {
            let result = await CodexIntegratedRunExecutionAdapter.execute { outcome }

            XCTAssertEqual(result.nativeOutcome, outcome)
            XCTAssertEqual(
                result.executionReport,
                DomainAgentRunExecutionReport(
                    result: .terminal(.failed(assistantText: message, reason: .agentError)),
                    trace: [.executionStarted, .terminalOutcomeProduced(.failed)]
                )
            )
            XCTAssertFalse(result.didStartProviderRun)
            XCTAssertTrue(result.shouldReleaseCreatedOwnership)
        }
    }

    func testCancelledDispatchClassifiesAsCancellationWithoutLosingNativeResult() async {
        let result = await CodexIntegratedRunExecutionAdapter.execute { .cancelled }

        XCTAssertEqual(result.nativeOutcome, .cancelled)
        XCTAssertEqual(
            result.executionReport,
            DomainAgentRunExecutionReport(
                result: .terminal(.cancelled()),
                trace: [.executionStarted, .terminalOutcomeProduced(.cancelled)]
            )
        )
        XCTAssertFalse(result.didStartProviderRun)
        XCTAssertTrue(result.shouldReleaseCreatedOwnership)
    }

    func testStaleDispatchClassifiesAsNonterminalSupersession() async {
        let outcome = CodexAgentModeCoordinator.NativeSendOutcome.stale(reason: "run changed")
        let result = await CodexIntegratedRunExecutionAdapter.execute { outcome }

        XCTAssertEqual(result.nativeOutcome, outcome)
        XCTAssertEqual(
            result.executionReport,
            DomainAgentRunExecutionReport(
                result: .superseded,
                trace: [.executionStarted, .executionSuperseded]
            )
        )
        XCTAssertFalse(result.didStartProviderRun)
        XCTAssertTrue(result.shouldReleaseCreatedOwnership)
    }
}
