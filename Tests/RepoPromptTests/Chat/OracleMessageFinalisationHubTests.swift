import Foundation
@testable import RepoPrompt
import XCTest

final class OracleMessageFinalisationHubTests: XCTestCase {
    func testWaiterCancellationIsLocalAndDoesNotCompleteMessage() async {
        let hub = MessageFinalisationHub()
        let messageID = UUID()
        let cancelledWaiterID = UUID()
        let retainedWaiterID = UUID()
        let futureWaiterID = UUID()
        let cancelledSignal = OracleFinalisationWaiterSignal()
        let retainedSignal = OracleFinalisationWaiterSignal()
        let futureSignal = OracleFinalisationWaiterSignal()

        let cancelledWaiter = makeWaiter(
            hub: hub,
            messageID: messageID,
            waiterID: cancelledWaiterID,
            signal: cancelledSignal
        )
        let retainedWaiter = makeWaiter(
            hub: hub,
            messageID: messageID,
            waiterID: retainedWaiterID,
            signal: retainedSignal
        )

        await Task.yield()
        await hub.cancel(messageID, waiterID: cancelledWaiterID)
        await cancelledWaiter.value

        let completedAfterCancellation = await hub.isCompleted(messageID)
        let retainedResumedAfterCancellation = await retainedSignal.isMarked()
        XCTAssertFalse(completedAfterCancellation)
        XCTAssertFalse(retainedResumedAfterCancellation)

        let futureWaiter = makeWaiter(
            hub: hub,
            messageID: messageID,
            waiterID: futureWaiterID,
            signal: futureSignal
        )
        await Task.yield()
        let futureResumedBeforeFulfilment = await futureSignal.isMarked()
        XCTAssertFalse(futureResumedBeforeFulfilment)

        await hub.fulfil(messageID)
        await retainedWaiter.value
        await futureWaiter.value

        let completedAfterFulfilment = await hub.isCompleted(messageID)
        let retainedResumedAfterFulfilment = await retainedSignal.isMarked()
        let futureResumedAfterFulfilment = await futureSignal.isMarked()
        XCTAssertTrue(completedAfterFulfilment)
        XCTAssertTrue(retainedResumedAfterFulfilment)
        XCTAssertTrue(futureResumedAfterFulfilment)
    }

    func testCancellationBeforeRegistrationResumesOnlyMatchingWaiter() async {
        let hub = MessageFinalisationHub()
        let messageID = UUID()
        let cancelledWaiterID = UUID()
        let retainedWaiterID = UUID()
        let cancelledSignal = OracleFinalisationWaiterSignal()
        let retainedSignal = OracleFinalisationWaiterSignal()

        await hub.cancel(messageID, waiterID: cancelledWaiterID)
        let cancelledWaiter = makeWaiter(
            hub: hub,
            messageID: messageID,
            waiterID: cancelledWaiterID,
            signal: cancelledSignal
        )
        let retainedWaiter = makeWaiter(
            hub: hub,
            messageID: messageID,
            waiterID: retainedWaiterID,
            signal: retainedSignal
        )

        await cancelledWaiter.value
        let cancelledResumed = await cancelledSignal.isMarked()
        let retainedResumedBeforeFulfilment = await retainedSignal.isMarked()
        let completedBeforeFulfilment = await hub.isCompleted(messageID)
        XCTAssertTrue(cancelledResumed)
        XCTAssertFalse(retainedResumedBeforeFulfilment)
        XCTAssertFalse(completedBeforeFulfilment)

        await hub.fulfil(messageID)
        await retainedWaiter.value
        let retainedResumedAfterFulfilment = await retainedSignal.isMarked()
        XCTAssertTrue(retainedResumedAfterFulfilment)
    }

    private func makeWaiter(
        hub: MessageFinalisationHub,
        messageID: UUID,
        waiterID: UUID,
        signal: OracleFinalisationWaiterSignal
    ) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { continuation in
                Task {
                    await hub.register(
                        messageID,
                        waiterID: waiterID,
                        cont: continuation
                    )
                }
            }
            await signal.mark()
        }
    }
}

private actor OracleFinalisationWaiterSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
