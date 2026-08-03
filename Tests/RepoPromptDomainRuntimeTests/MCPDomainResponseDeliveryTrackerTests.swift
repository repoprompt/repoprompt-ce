import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainResponseDeliveryTrackerTests: XCTestCase {
    func testMatchingResponseDrainsAcceptedRequestAfterPhysicalDelivery() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#))
        let before = tracker.snapshot()
        XCTAssertEqual(before.pendingRequestCount, 1)

        let waiter = Task { await tracker.waitUntilDrained() }
        tracker.recordDeliveredServerFrame(Self.frame(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))

        let drained = await waiter.value
        XCTAssertTrue(drained)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
    }

    func testNotificationsAndUnmatchedResponsesDoNotChangePendingRequests() {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","id":"a","method":"tools/call"}"#))
        tracker.recordDeliveredServerFrame(Self.frame(#"{"jsonrpc":"2.0","id":"b","result":{}}"#))
        tracker.recordDeliveredServerFrame(Self.frame(#"{"jsonrpc":"2.0","method":"notifications/progress"}"#))

        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
    }

    func testBatchRequestsAndResponsesDrainByCanonicalIDType() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(Self.frame(#"[{"jsonrpc":"2.0","id":1,"method":"one"},{"jsonrpc":"2.0","id":"1","method":"two"},{"jsonrpc":"2.0","method":"note"}]"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)

        tracker.recordDeliveredServerFrame(Self.frame(#"[{"jsonrpc":"2.0","id":"1","result":{}},{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"x"}}]"#))
        let drained = await tracker.waitUntilDrained()
        XCTAssertTrue(drained)
    }

    func testCloseResumesWaitersFalseAndRejectsLaterAccounting() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
        let waiter = Task { await tracker.waitUntilDrained() }
        await Task.yield()
        tracker.close()

        let drained = await waiter.value
        XCTAssertFalse(drained)
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","id":8,"method":"tools/call"}"#))
        let snapshot = tracker.snapshot()
        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(snapshot.pendingRequestCount, 1)
    }

    func testResetClearsTerminalPendingAndWaiterState() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(Self.frame(#"{"jsonrpc":"2.0","id":9,"method":"tools/call"}"#))
        let waiter = Task { await tracker.waitUntilDrained() }
        for _ in 0 ..< 100 where tracker.snapshot().waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(tracker.snapshot().waiterCount, 1)
        tracker.reset()

        let resetWaiterResult = await waiter.value
        XCTAssertFalse(resetWaiterResult)
        let snapshot = tracker.snapshot()
        XCTAssertFalse(snapshot.isTerminal)
        XCTAssertEqual(snapshot.pendingRequestCount, 0)
        XCTAssertEqual(snapshot.waiterCount, 0)
        let drained = await tracker.waitUntilDrained()
        XCTAssertTrue(drained)
    }

    private static func frame(_ json: String) -> Data {
        Data(json.utf8)
    }
}
