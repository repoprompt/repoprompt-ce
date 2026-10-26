import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainResponseDeliveryTrackerTests: XCTestCase {
    func testAcceptedPublicationTracksExactTypedIDsThroughCompleteDelivery() async throws {
        let tracker = MCPDomainResponseDeliveryTracker()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let requests = frame(#"[{"id":7,"method":"ping"},{"id":"7","method":"ping"}]"#)
        XCTAssertTrue(tracker.publishClientFrame(requests) {
            if case .enqueued = continuation.yield(requests) {
                return true
            }
            return false
        })
        var iterator = stream.makeAsyncIterator()
        let published = try await iterator.next()
        XCTAssertEqual(published, requests)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)
        tracker.recordDeliveredServerFrame(frame(#"{"id":7,"result":{}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordDeliveredServerFrame(frame(#"{"id":"7","result":{}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
        continuation.finish()
    }

    func testRejectedPublicationRollsBackRequestAndCancellationWithoutErasingSiblingDebt() {
        for terminated in [false, true] {
            let tracker = MCPDomainResponseDeliveryTracker()
            tracker.recordAcceptedClientFrame(frame(#"[{"id":7,"method":"ping"},{"id":"7","method":"ping"}]"#))
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
            // A continuation alone does not keep the consumer stream alive.
            withExtendedLifetime(stream) {
                if terminated {
                    continuation.finish()
                } else {
                    guard case .enqueued = continuation.yield(frame(#"{"method":"notifications/progress"}"#)) else {
                        return XCTFail("The real stream must be full before the rejected publication")
                    }
                }
                // The duplicate numeric7 must not be erased by rollback; its attempted cancellation
                // must also be undone. The independent string7 remains outstanding throughout.
                let rejected = frame(#"[{"id":7,"method":"ping"},{"id":8,"method":"ping"},{"method":"notifications/cancelled","params":{"requestId":7}}]"#)
                var rejectionWasObserved = false
                XCTAssertFalse(tracker.publishClientFrame(rejected) {
                    switch continuation.yield(rejected) {
                    case .dropped:
                        rejectionWasObserved = !terminated
                    case .terminated:
                        rejectionWasObserved = terminated
                    case .enqueued:
                        XCTFail("Publication must be rejected")
                    @unknown default:
                        XCTFail("Unexpected stream yield result")
                    }
                    return false
                })
                XCTAssertTrue(rejectionWasObserved)
                XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)
                tracker.recordDeliveredServerFrame(frame(#"{"id":7,"result":{}}"#))
                XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
                tracker.recordDeliveredServerFrame(frame(#"{"id":"7","result":{}}"#))
                XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
                continuation.finish()
            }
        }
    }

    func testAcceptedCancellationPublicationRetiresOnlyItsExactTypedDebt() async throws {
        let tracker = MCPDomainResponseDeliveryTracker()
        tracker.recordAcceptedClientFrame(frame(#"[{"id":7,"method":"ping"},{"id":"7","method":"ping"}]"#))
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let cancellation = frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)
        XCTAssertTrue(tracker.publishClientFrame(cancellation) {
            if case .enqueued = continuation.yield(cancellation) {
                return true
            }
            return false
        })
        var iterator = stream.makeAsyncIterator()
        let published = try await iterator.next()
        XCTAssertEqual(published, cancellation)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordDeliveredServerFrame(frame(#"{"id":7,"result":{}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordDeliveredServerFrame(frame(#"{"id":"7","result":{}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
        continuation.finish()
    }

    func testStaleGenerationAndTerminalPublicationNeverInvokeThePublisher() {
        let tracker = MCPDomainResponseDeliveryTracker()
        let oldGeneration = tracker.currentGeneration
        tracker.reset()
        let request = frame(#"{"id":7,"method":"ping"}"#)
        var publisherCalled = false
        XCTAssertFalse(tracker.publishClientFrame(request, expectedGeneration: oldGeneration) {
            publisherCalled = true
            return true
        })
        XCTAssertFalse(publisherCalled)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
        tracker.recordAcceptedClientFrame(request, expectedGeneration: tracker.currentGeneration)
        tracker.close()
        XCTAssertFalse(tracker.publishClientFrame(request, expectedGeneration: tracker.currentGeneration) {
            publisherCalled = true
            return true
        })
        XCTAssertFalse(publisherCalled)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        XCTAssertTrue(tracker.snapshot().isTerminal)
    }

    private func frame(_ json: String) -> Data {
        Data(json.utf8)
    }
}
