@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentRunExecutionContractsTests: XCTestCase {
    func testCancellationIntentReasonStringsAreStable() {
        XCTAssertEqual(DomainAgentRunCancellationIntent.userStop.cancellationReason, "user_stop")
        XCTAssertEqual(
            DomainAgentRunCancellationIntent.executionLocationChange.cancellationReason,
            "execution_location_change"
        )
        XCTAssertEqual(
            DomainAgentRunCancellationIntent.runtimeShutdown.cancellationReason,
            "runtime_shutdown"
        )
    }

    func testExecutionCoreMapsCompletionAndInvokesOperationOnce() async {
        var invocationCount = 0

        let report = await DomainAgentRunExecutionCore.execute {
            invocationCount += 1
            return .completed(assistantText: "done")
        }

        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .terminal(.completed(assistantText: "done")),
                trace: [.executionStarted, .terminalOutcomeProduced(.completed)]
            )
        )
    }

    func testExecutionCoreMapsCancellationWithoutCallingFailureMapper() async {
        var failureMapperCallCount = 0

        let report = await DomainAgentRunExecutionCore.execute(failureText: { _ in
            failureMapperCallCount += 1
            return "unexpected"
        }) {
            throw CancellationError()
        }

        XCTAssertEqual(failureMapperCallCount, 0)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .terminal(.cancelled()),
                trace: [.executionStarted, .terminalOutcomeProduced(.cancelled)]
            )
        )
    }

    func testExecutionCoreKeepsSupersessionNonterminal() async {
        let report = await DomainAgentRunExecutionCore.execute {
            .superseded
        }

        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .superseded,
                trace: [.executionStarted, .executionSuperseded]
            )
        )
    }

    func testTerminalOutcomesMapToSnapshotStatuses() {
        XCTAssertEqual(DomainAgentRunTerminalOutcome.completed(assistantText: "ok").snapshotStatus, .completed)
        XCTAssertEqual(DomainAgentRunTerminalOutcome.cancelled().snapshotStatus, .cancelled)
        XCTAssertEqual(
            DomainAgentRunTerminalOutcome.failed(assistantText: "boom").snapshotStatus,
            .failed
        )
    }
}
