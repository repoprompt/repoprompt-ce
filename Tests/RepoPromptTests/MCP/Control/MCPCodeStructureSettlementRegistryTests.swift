import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPCodeStructureSettlementRegistryTests: XCTestCase {
    func testGraceExpiryPromotesAfterCompetingLeaseSettles() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 17
        let first = admittedSlot(registry, windowID: windowID)
        let graceWaiting = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 0)
        )
        XCTAssertEqual(first.recordCompletion(.success), .deliver)
        XCTAssertEqual(graceWaiting.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(graceWaiting.activateDetach(), .activated)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )

        guard case let .busy(context) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: .zero,
            handlerPhase: { nil }
        ) else {
            return XCTFail("A detached lease must fence repeated requests")
        }
        XCTAssertEqual(context.reason, .detached)

        XCTAssertEqual(graceWaiting.recordCompletion(.success), .settleDetached)
        await registry.awaitDrained(windowID: windowID)
    }

    func testCancellationFencesAdmissionUntilExactLateSettlement() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 23
        let abandoned = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(abandoned.cancel(now: .zero), .abandoned(nil))
        XCTAssertEqual(abandoned.cancel(now: .zero), .abandoned(nil))
        for _ in 0 ..< 3 {
            guard case let .busy(context) = registry.admit(
                windowID: windowID,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: "get_code_structure",
                now: .zero,
                handlerPhase: { nil }
            ) else {
                return XCTFail("An abandoned lease must keep every retry busy")
            }
            XCTAssertEqual(context.reason, .abandoned)
        }

        XCTAssertEqual(abandoned.recordCompletion(.cancellation), .settleAbandoned)
        guard case let .admitted(next) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: .zero,
            handlerPhase: { nil }
        ) else {
            return XCTFail("Late settlement must lift the busy fence")
        }
        XCTAssertEqual(abandoned.recordCompletion(.success), .ignored)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 0),
            "An old invocation must not clear a new lease"
        )
        XCTAssertEqual(next.recordCompletion(.success), .deliver)
        await registry.awaitDrained(windowID: windowID)
    }

    func testCancellationDuringDetachingBecomesAbandonedWithoutDowngradingDetached() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 31
        let detaching = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(detaching.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(detaching.cancel(now: .zero), .abandoned(nil))
        XCTAssertEqual(detaching.activateDetach(), .notActivated)
        XCTAssertEqual(detaching.recordCompletion(.cancellation), .settleAbandoned)

        let detached = admittedSlot(registry, windowID: windowID)
        XCTAssertEqual(detached.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(detached.activateDetach(), .activated)
        XCTAssertEqual(detached.cancel(now: .zero), .alreadyDetached)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )
        XCTAssertEqual(detached.recordCompletion(.success), .settleDetached)
        await registry.awaitDrained(windowID: windowID)
    }

    func testCompetingCancellationIsAbandonedAndSettlesThroughAbandonedPath() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 47
        let first = admittedSlot(registry, windowID: windowID)
        let second = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(first.cancel(now: .zero), .abandoned(nil))
        XCTAssertEqual(second.cancel(now: .zero), .abandoned(nil))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 2)
        )

        XCTAssertEqual(second.recordCompletion(.cancellation), .settleAbandoned)
        guard case let .busy(context) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: .zero,
            handlerPhase: { nil }
        ) else {
            return XCTFail("Settling one abandoned call must not clear the other abandoned lease")
        }
        XCTAssertEqual(context.reason, .abandoned)
        XCTAssertEqual(first.recordCompletion(.success), .settleAbandoned)
        await registry.awaitDrained(windowID: windowID)
    }

    func testGraceExpiryBehindZombieForceDisconnectsWithoutClearingFirstLease() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 53
        let first = admittedSlot(registry, windowID: windowID)
        let second = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(first.cancel(now: .zero), .abandoned(nil))
        XCTAssertEqual(second.resolveGraceExpiry(now: .zero), .forceDisconnect)
        XCTAssertEqual(second.cancel(now: .zero), .forceDisconnect(nil))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 1)
        )
        guard case let .busy(capacityContext) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: .zero,
            handlerPhase: { nil }
        ) else {
            return XCTFail("Two escaped providers must exhaust the per-window recovery budget")
        }
        XCTAssertEqual(capacityContext.reason, .releasedProviderLimitReached)
        XCTAssertNil(capacityContext.recoveryAfter)
        XCTAssertEqual(capacityContext.releasedProviderCount, 0)

        XCTAssertEqual(second.recordCompletion(.cancellation), .settleForceDisconnected)
        guard case let .busy(context) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: .zero,
            handlerPhase: { nil }
        ) else {
            return XCTFail("Settling a force-disconnected call must not clear the abandoned lease")
        }
        XCTAssertEqual(context.reason, .abandoned)
        XCTAssertEqual(first.recordCompletion(.success), .settleAbandoned)
        await registry.awaitDrained(windowID: windowID)
    }

    func testDetachedLeaseRecoversAtBoundWithoutClearingReplacement() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 59
        let connectionID = UUID()
        let invocationID = UUID()
        let detached = admittedSlot(
            registry,
            windowID: windowID,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: "read_file"
        )

        XCTAssertEqual(detached.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(detached.activateDetach(), .activated)
        guard case let .busy(context) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_file_tree",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon - .nanoseconds(1),
            handlerPhase: { nil }
        ) else {
            return XCTFail("The detached lease must fence calls before the recovery bound")
        }
        XCTAssertEqual(context.reason, .detached)
        XCTAssertEqual(context.originToolName, "read_file")
        XCTAssertEqual(context.originConnectionID, connectionID)
        XCTAssertEqual(context.originInvocationID, invocationID)
        XCTAssertEqual(context.recoveryAfter, .nanoseconds(1))

        guard case let .admitted(replacement) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_file_tree",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon,
            handlerPhase: { nil }
        ) else {
            return XCTFail("The window must recover at the bounded horizon")
        }
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 1, releasedCount: 1)
        )

        XCTAssertEqual(detached.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 0, releasedCount: 0),
            "Late completion must remove only the original lease"
        )
        XCTAssertEqual(replacement.recordCompletion(.success), .deliver)
        await registry.awaitDrained(windowID: windowID)
    }

    func testReleasedProviderLimitStopsRepeatedEscapesUntilSettlement() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 61
        let first = admittedSlot(registry, windowID: windowID, toolName: "read_file")

        XCTAssertEqual(first.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(first.activateDetach(), .activated)
        guard case let .admitted(second) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_file_tree",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon,
            handlerPhase: { nil }
        ) else {
            return XCTFail("The first escaped provider must permit bounded recovery")
        }

        XCTAssertEqual(
            second.resolveGraceExpiry(now: MCPCodeStructureSettlementRegistry.recoveryHorizon),
            .detach
        )
        XCTAssertEqual(second.activateDetach(), .activated)
        guard case let .busy(preHorizonContext) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon + .seconds(1),
            handlerPhase: { nil }
        ) else {
            return XCTFail("An exhausted recovery budget must be terminal immediately")
        }
        XCTAssertEqual(preHorizonContext.reason, .releasedProviderLimitReached)
        XCTAssertNil(preHorizonContext.recoveryAfter)
        XCTAssertEqual(preHorizonContext.releasedProviderCount, 1)

        guard case let .busy(context) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon + MCPCodeStructureSettlementRegistry.recoveryHorizon,
            handlerPhase: { nil }
        ) else {
            return XCTFail("A second escaped provider must not exceed the per-window bound")
        }
        XCTAssertEqual(context.reason, .releasedProviderLimitReached)
        XCTAssertNil(context.recoveryAfter)
        XCTAssertEqual(context.releasedProviderCount, 1)

        XCTAssertEqual(first.recordCompletion(.success), .settleDetached)
        guard case let .admitted(replacement) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "get_code_structure",
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon + MCPCodeStructureSettlementRegistry.recoveryHorizon,
            handlerPhase: { nil }
        ) else {
            return XCTFail("Settlement must restore the released-provider budget")
        }
        XCTAssertEqual(second.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(replacement.recordCompletion(.success), .deliver)
        await registry.awaitDrained(windowID: windowID)
    }

    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        connectionID: UUID = UUID(),
        invocationID: UUID = UUID(),
        toolName: String = "get_code_structure",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MCPCodeStructureSettlementRegistry.Slot {
        guard case let .admitted(slot) = registry.admit(
            windowID: windowID,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: toolName,
            now: .zero,
            handlerPhase: { nil }
        ) else {
            XCTFail("Expected admitted settlement lease", file: file, line: line)
            fatalError("Missing settlement lease")
        }
        return slot
    }
}
