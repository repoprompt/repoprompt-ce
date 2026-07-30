@testable import RepoPromptApp
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

        let acceptedRunID = UUID()
        XCTAssertEqual(
            AgentModeViewModel.test_validatedSteeringOriginRunID(
                capturedRunID: acceptedRunID,
                currentRunID: acceptedRunID
            ),
            acceptedRunID
        )
        XCTAssertNil(AgentModeViewModel.test_validatedSteeringOriginRunID(
            capturedRunID: acceptedRunID,
            currentRunID: UUID()
        ))
        XCTAssertNil(AgentModeViewModel.test_validatedSteeringOriginRunID(
            capturedRunID: nil,
            currentRunID: acceptedRunID
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
