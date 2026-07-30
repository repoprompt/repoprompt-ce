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
        XCTAssertEqual(graceWaiting.resolveGraceExpiry(), .detach)
        XCTAssertEqual(graceWaiting.activateDetach(), .activated)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )

        guard case .busy(.detached) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("A detached lease must fence repeated requests")
        }

        XCTAssertEqual(graceWaiting.recordCompletion(.success), .settleDetached)
        await registry.awaitDrained(windowID: windowID)
    }

    func testCancellationFencesAdmissionUntilExactLateSettlement() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 23
        let abandoned = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(abandoned.cancel(), .abandoned(nil))
        XCTAssertEqual(abandoned.cancel(), .abandoned(nil))
        for _ in 0 ..< 3 {
            guard case .busy(.abandoned) = registry.admit(
                windowID: windowID,
                connectionID: UUID(),
                invocationID: UUID()
            ) else {
                return XCTFail("An abandoned lease must keep every retry busy")
            }
        }

        XCTAssertEqual(abandoned.recordCompletion(.cancellation), .settleAbandoned)
        guard case let .admitted(next) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
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

    func testDroppingFinalAbandonedSlotReleasesFenceAndResumesDrainWaiters() async throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 27
        var abandoned: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )

        XCTAssertEqual(abandoned?.cancel(), .abandoned(nil))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )

        let drained = expectation(description: "Drain waiter resumed")
        let waiter = Task {
            await registry.awaitDrained(windowID: windowID)
            drained.fulfill()
        }
        try await AsyncTestWait.waitUntil(
            "settlement drain waiter registered",
            timeout: 1
        ) {
            registry.debugDrainWaiterCount(windowID: windowID) == 1
        }

        abandoned = nil

        await fulfillment(of: [drained], timeout: 1)
        waiter.cancel()
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )
        let replacement = admittedSlot(registry, windowID: windowID)
        XCTAssertEqual(replacement.recordCompletion(.success), .deliver)
    }

    func testDroppingFinalDetachedSlotReleasesFenceAndAllowsReadmission() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 29
        var detached: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )

        XCTAssertEqual(detached?.resolveGraceExpiry(), .detach)
        XCTAssertEqual(detached?.activateDetach(), .activated)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )

        detached = nil
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )

        let replacement = admittedSlot(registry, windowID: windowID)
        XCTAssertEqual(replacement.recordCompletion(.success), .deliver)
    }

    func testDroppingFinalDetachingSlotReleasesFence() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 30
        var detaching: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )

        XCTAssertEqual(detaching?.resolveGraceExpiry(), .detach)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )

        detaching = nil
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )
    }

    func testDroppingFinalReservedSlotReleasesEntry() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 31
        var reserved: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )

        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 0)
        )

        reserved = nil
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )
    }

    func testOrphanCleanupRemovesOnlyItsExactLease() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 32
        var first: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )
        var second: MCPCodeStructureSettlementRegistry.Slot? = admittedSlot(
            registry,
            windowID: windowID
        )

        XCTAssertEqual(first?.cancel(), .abandoned(nil))
        XCTAssertEqual(second?.resolveGraceExpiry(), .forceDisconnect)

        second = nil

        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )
        guard case .busy(.abandoned) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("Orphan cleanup must not clear another lease")
        }

        first = nil
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )
    }

    func testCancellationDuringDetachingBecomesAbandonedWithoutDowngradingDetached() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 31
        let detaching = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(detaching.resolveGraceExpiry(), .detach)
        XCTAssertEqual(detaching.cancel(), .abandoned(nil))
        XCTAssertEqual(detaching.activateDetach(), .notActivated)
        XCTAssertEqual(detaching.recordCompletion(.cancellation), .settleAbandoned)

        let detached = admittedSlot(registry, windowID: windowID)
        XCTAssertEqual(detached.resolveGraceExpiry(), .detach)
        XCTAssertEqual(detached.activateDetach(), .activated)
        XCTAssertEqual(detached.cancel(), .alreadyDetached)
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

        XCTAssertEqual(first.cancel(), .abandoned(nil))
        XCTAssertEqual(second.cancel(), .abandoned(nil))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 2)
        )

        XCTAssertEqual(second.recordCompletion(.cancellation), .settleAbandoned)
        guard case .busy(.abandoned) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("Settling one abandoned call must not clear the other abandoned lease")
        }
        XCTAssertEqual(first.recordCompletion(.success), .settleAbandoned)
        await registry.awaitDrained(windowID: windowID)
    }

    func testGraceExpiryBehindZombieForceDisconnectsWithoutClearingFirstLease() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 53
        let first = admittedSlot(registry, windowID: windowID)
        let second = admittedSlot(registry, windowID: windowID)

        XCTAssertEqual(first.cancel(), .abandoned(nil))
        XCTAssertEqual(second.resolveGraceExpiry(), .forceDisconnect)
        XCTAssertEqual(second.cancel(), .forceDisconnect(nil))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 2, detachedCount: 1)
        )

        XCTAssertEqual(second.recordCompletion(.cancellation), .settleForceDisconnected)
        guard case .busy(.abandoned) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("Settling a force-disconnected call must not clear the abandoned lease")
        }
        XCTAssertEqual(first.recordCompletion(.success), .settleAbandoned)
        await registry.awaitDrained(windowID: windowID)
    }

    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MCPCodeStructureSettlementRegistry.Slot {
        guard case let .admitted(slot) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            XCTFail("Expected admitted settlement lease", file: file, line: line)
            fatalError("Missing settlement lease")
        }
        return slot
    }
}
