import Foundation
@testable import RepoPromptApp
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

        await hub.fulfil(messageID, outcome: .completed)
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

        await hub.fulfil(messageID, outcome: .completed)
        await retainedWaiter.value
        let retainedResumedAfterFulfilment = await retainedSignal.isMarked()
        XCTAssertTrue(retainedResumedAfterFulfilment)
    }

    func testConcurrentWaitersReceiveTheSameTerminalOutcome() async throws {
        let hub = MessageFinalisationHub()
        let messageID = UUID()
        let expected = ChatSendTerminalOutcome.failed(
            message: "provider failed",
            partialResponse: "partial"
        )

        async let first = hub.waitForOutcome(messageID, timeout: .seconds(1))
        async let second = hub.waitForOutcome(messageID, timeout: .seconds(1))
        await Task.yield()
        await hub.fulfil(messageID, outcome: expected)

        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes, [expected, expected])
    }

    func testTimeoutDoesNotPoisonLaterGenuineOutcome() async throws {
        let hub = MessageFinalisationHub()
        let messageID = UUID()

        let timedOut = try await hub.waitForOutcome(messageID, timeout: .zero)
        XCTAssertNil(timedOut)
        let completedAfterTimeout = await hub.isCompleted(messageID)
        XCTAssertFalse(completedAfterTimeout)

        await hub.fulfil(messageID, outcome: .completed)
        let later = try await hub.waitForOutcome(messageID, timeout: .seconds(1))
        XCTAssertEqual(later, .completed)
    }

    func testTerminalOutcomeIsFirstWriterWinsAndDiscardAllowsRetry() async throws {
        let hub = MessageFinalisationHub()
        let messageID = UUID()

        await hub.fulfil(
            messageID,
            outcome: .failed(message: "provider failed", partialResponse: "partial")
        )
        await hub.fulfil(messageID, outcome: .completed)
        let outcome = await hub.outcome(for: messageID)
        XCTAssertEqual(
            outcome,
            .failed(message: "provider failed", partialResponse: "partial")
        )

        await hub.discard(messageID)
        let completedAfterDiscard = await hub.isCompleted(messageID)
        let outcomeAfterDiscard = try await hub.waitForOutcome(messageID, timeout: .zero)
        XCTAssertFalse(completedAfterDiscard)
        XCTAssertNil(outcomeAfterDiscard)

        await hub.fulfil(messageID, outcome: .completed)
        let retryOutcome = try await hub.waitForOutcome(messageID, timeout: .seconds(1))
        XCTAssertEqual(retryOutcome, .completed)
    }

    private func makeWaiter(
        hub: MessageFinalisationHub,
        messageID: UUID,
        waiterID: UUID,
        signal: OracleFinalisationWaiterSignal
    ) -> Task<Void, Never> {
        Task {
            _ = await withCheckedContinuation { continuation in
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
