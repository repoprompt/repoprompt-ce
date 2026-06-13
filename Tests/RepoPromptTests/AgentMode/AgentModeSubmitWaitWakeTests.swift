@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSubmitWaitWakeTests: XCTestCase {
    func testNormalActiveCodexSubmitSkipsParentFireAndForgetWake() {
        XCTAssertFalse(AgentModeViewModel.test_shouldWakeParentAgentRunWaitersForActiveSubmit(
            selectedAgent: .codexExec,
            codexCompactionInFlight: false
        ))
    }

    func testCodexCompactionSubmitPreservesParentFireAndForgetWake() {
        XCTAssertTrue(AgentModeViewModel.test_shouldWakeParentAgentRunWaitersForActiveSubmit(
            selectedAgent: .codexExec,
            codexCompactionInFlight: true
        ))
    }

    func testNonCodexActiveSubmitPreservesParentFireAndForgetWake() {
        XCTAssertTrue(AgentModeViewModel.test_shouldWakeParentAgentRunWaitersForActiveSubmit(
            selectedAgent: .claudeCode,
            codexCompactionInFlight: false
        ))
    }

    func testCodexDeliverySignalWaitsForProviderAcceptanceOrDurableQueueInsertion() {
        XCTAssertEqual(
            AgentModeViewModel.test_mcpActiveInstructionDeliverySignalTiming(
                selectedAgent: .codexExec,
                hasNativeSteeringRoute: false
            ),
            .afterProviderSend
        )
    }
}
