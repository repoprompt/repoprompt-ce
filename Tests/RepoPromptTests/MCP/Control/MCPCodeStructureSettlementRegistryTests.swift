import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPCodeStructureSettlementRegistryTests: XCTestCase {
    func testAdmissionPreservesSecondCallAndUsesGenerationSafeDetachedBusySlot() async {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 17

        guard case let .detachEligible(firstSlot) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("The first call should own detach eligibility")
        }
        guard case .forceDisconnect = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("The legal competing call should enter with force-disconnect cleanup")
        }
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 0)
        )

        XCTAssertTrue(firstSlot.markDetached())
        guard case .busy = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("Only a call arriving after actual detachment should receive busy")
        }
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 1)
        )
        XCTAssertEqual(firstSlot.complete(), .detached)

        guard case let .detachEligible(nextGenerationSlot) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID()
        ) else {
            return XCTFail("A drained window should grant a fresh generation")
        }
        XCTAssertNotEqual(firstSlot.generation, nextGenerationSlot.generation)
        XCTAssertFalse(firstSlot.markDetached())
        XCTAssertEqual(firstSlot.complete(), .ignored)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 1, detachedCount: 0)
        )
        XCTAssertEqual(nextGenerationSlot.complete(), .reserved)
        await registry.awaitDrained(windowID: windowID)
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0)
        )
    }
}
