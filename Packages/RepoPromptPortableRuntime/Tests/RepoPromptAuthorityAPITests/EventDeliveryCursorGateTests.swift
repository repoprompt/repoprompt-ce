@testable import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import XCTest

final class EventDeliveryCursorGateTests: XCTestCase {
    func testDeduplicatesWithinStoreAndRequiresExplicitResetAcrossStoreChange() {
        let firstStore = UUID()
        let secondStore = UUID()
        var gate = EventDeliveryCursorGate()

        XCTAssertTrue(gate.shouldDeliver(ServiceCursor(storeID: firstStore, globalSequence: 1)))
        XCTAssertFalse(gate.shouldDeliver(ServiceCursor(storeID: firstStore, globalSequence: 1)))
        XCTAssertFalse(gate.shouldDeliver(ServiceCursor(storeID: firstStore, globalSequence: 0)))
        XCTAssertTrue(gate.shouldDeliver(ServiceCursor(storeID: firstStore, globalSequence: 2)))
        XCTAssertFalse(gate.shouldDeliver(ServiceCursor(storeID: secondStore, globalSequence: 1)))
        gate.resetForNewStore(ServiceCursor(storeID: secondStore, globalSequence: 0))
        XCTAssertTrue(gate.shouldDeliver(ServiceCursor(storeID: secondStore, globalSequence: 1)))
    }
}
