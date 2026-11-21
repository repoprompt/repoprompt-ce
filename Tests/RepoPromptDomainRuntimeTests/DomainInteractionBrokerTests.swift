import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainInteractionBrokerTests: XCTestCase {
    func testActivityRenewsCountdownAndAcceptanceByOriginalTimeout() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = DomainInteractionBroker.Deadline(
            deadline: start.addingTimeInterval(301), renewalTimeoutSeconds: 300
        )
        XCTAssertEqual(deadline.countdownAnchor(), start)
        XCTAssertEqual(deadline.renew(at: start.addingTimeInterval(200)), start.addingTimeInterval(501))
        XCTAssertEqual(deadline.countdownAnchor(), start.addingTimeInterval(200))
        XCTAssertFalse(deadline.claimTimeout(at: start.addingTimeInterval(301)))
        let completion = try XCTUnwrap(deadline.claimProviderCompletion(
            at: start.addingTimeInterval(400), result: .response(.string("answer"), provider: .appUI)
        ))
        XCTAssertEqual(completion.result, .response(.string("answer"), provider: .appUI))
        XCTAssertNil(deadline.renew(at: start.addingTimeInterval(401)))
    }

    func testNoActivityRetainsOriginalDeadlineAndLateResponseFence() throws {
        let end = Date(timeIntervalSince1970: 1_000)
        let deadline = DomainInteractionBroker.Deadline(deadline: end, renewalTimeoutSeconds: 300)
        XCTAssertEqual(deadline.acceptanceDeadline(), end)
        XCTAssertFalse(deadline.claimTimeout(at: end.addingTimeInterval(-0.001)))
        let completion = try XCTUnwrap(deadline.claimProviderCompletion(
            at: end, result: .response(.string("late"), provider: .appUI)
        ))
        XCTAssertEqual(completion.result, .timedOut)
        XCTAssertTrue(completion.ignoredLateResponse)
        XCTAssertNil(deadline.countdownAnchor())
    }

    func testFixedRequestsDoNotRenew() {
        let end = Date(timeIntervalSince1970: 20_000)
        let fixed = DomainInteractionBroker.Deadline(deadline: end)
        XCTAssertNil(fixed.renew(at: end.addingTimeInterval(-100)))
        XCTAssertEqual(fixed.acceptanceDeadline(), end)
        fixed.invalidate()
        XCTAssertNil(fixed.acceptanceDeadline())
    }

    func testBrokerAcceptsAnswerAfterOldDeadlineAndCarriesSameAuthorityToPresenter() async throws {
        let broker = DomainInteractionBroker()
        let presented = expectation(description: "presented")
        let request = DomainInteractionRequest(
            toolName: "ask_user", payload: [:], deadline: Date().addingTimeInterval(2),
            renewalTimeoutSeconds: 3
        )
        let provider = DomainInteractionProvider(kind: .appUI, present: { _ in
            let deadline = try XCTUnwrap(DomainInteractionPresentationContext.deadline)
            XCTAssertNotNil(deadline.renew())
            presented.fulfill()
            try await Task.sleep(for: .seconds(2.5))
            return .string("renewed answer")
        })
        let task = Task { await broker.request(request, appUI: provider) }
        await fulfillment(of: [presented], timeout: 2)
        let result = await task.value
        XCTAssertEqual(result, .response(.string("renewed answer"), provider: .appUI))
        await broker.shutdown()
    }

    func testBrokerExpiresWithoutActivity() async {
        let broker = DomainInteractionBroker()
        let request = DomainInteractionRequest(
            toolName: "ask_user", payload: [:], deadline: Date().addingTimeInterval(0.05),
            renewalTimeoutSeconds: 1
        )
        let provider = DomainInteractionProvider(kind: .appUI, present: { _ in
            try await Task.sleep(for: .seconds(10))
            return .null
        })
        let result = await broker.request(request, appUI: provider)
        XCTAssertEqual(result, .timedOut)
        await broker.shutdown()
    }

    func testDisconnectedCallerInvalidatesRenewalAndCancelsPresentation() async {
        let broker = DomainInteractionBroker()
        let clientID = UUID()
        let presented = expectation(description: "presented")
        let cancelled = expectation(description: "cancelled")
        let request = DomainInteractionRequest(
            toolName: "ask_user", clientID: clientID, payload: [:], deadline: Date().addingTimeInterval(31),
            renewalTimeoutSeconds: 30
        )
        let provider = DomainInteractionProvider(kind: .appUI, present: { _ in
            let deadline = try XCTUnwrap(DomainInteractionPresentationContext.deadline)
            XCTAssertNotNil(deadline.renew())
            presented.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                XCTAssertNil(deadline.renew())
                throw error
            }
            return .null
        }, cancel: { _ in cancelled.fulfill() })
        let task = Task { await broker.request(request, appUI: provider) }
        await fulfillment(of: [presented], timeout: 2)
        await broker.cancel(clientID: clientID)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        await fulfillment(of: [cancelled], timeout: 2)
        let snapshot = await broker.snapshot()
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
        await broker.shutdown()
    }
}
