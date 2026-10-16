import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPCodeStructureSettlementRegistryNoticeTests: XCTestCase {
    func testReleasedProviderLimitBlockageClearsWhenBlockingSiblingSettles() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 71
        let firstInvocationID = UUID()
        let secondInvocationID = UUID()

        let firstSlot = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: firstInvocationID,
            now: .zero
        )
        XCTAssertEqual(firstSlot.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(firstSlot.activateDetach(), .activated)

        // The recovery horizon releases the first cancellation-ignoring provider
        // so one new call may run, but preserves that provider's exact lease.
        let secondSlot = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: secondInvocationID,
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon
        )
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        XCTAssertEqual(
            secondSlot.resolveGraceExpiry(now: MCPCodeStructureSettlementRegistry.recoveryHorizon),
            .detach
        )
        XCTAssertEqual(secondSlot.activateDetach(), .activated)
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        // Completing the sibling frees the cap even though the released first
        // provider remains tracked. The UI may clear its released-limit notice.
        XCTAssertEqual(secondSlot.recordCompletion(.success), .settleDetached)
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        // The original lease still owns and records its own eventual completion.
        XCTAssertEqual(firstSlot.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(registry.snapshot(windowID: windowID).activeCount, 0)
    }

    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        invocationID: UUID,
        now: Duration
    ) -> MCPCodeStructureSettlementRegistry.Slot {
        switch registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: invocationID,
            toolName: "get_code_structure",
            now: now,
            handlerPhase: { "provider" }
        ) {
        case let .admitted(slot):
            return slot
        case .busy:
            XCTFail("expected registry admission")
            fatalError("unreachable after XCTFail")
        }
    }
}
