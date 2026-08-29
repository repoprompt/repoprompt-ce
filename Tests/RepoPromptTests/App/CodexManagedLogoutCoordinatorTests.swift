import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexManagedLogoutCoordinatorTests: XCTestCase {
    func testMultiWindowLogoutIsIdempotentAndAwaitsEveryParticipant() async {
        let fence = CodexManagedSessionFence()
        let logoutCalled = expectation(description: "logout operation started")
        let logoutGate = ManagedLogoutTestGate(
            result: .signedOut,
            onCall: ManagedLogoutExpectationSignal(logoutCalled)
        )
        let participantsStopped = expectation(description: "all logout participants stopped")
        participantsStopped.expectedFulfillmentCount = 2
        let firstWindow = ManagedLogoutParticipant {
            participantsStopped.fulfill()
        }
        let secondWindow = ManagedLogoutParticipant {
            participantsStopped.fulfill()
        }
        let coordinator = CodexManagedLogoutCoordinator(
            fence: fence,
            logoutOperation: { await logoutGate.run() }
        )

        let first = Task { @MainActor in
            await coordinator.stopSessionsAndSignOut(participants: [firstWindow, secondWindow])
        }
        await fulfillment(of: [participantsStopped, logoutCalled], timeout: 2)
        XCTAssertTrue(fence.isFenced)
        XCTAssertTrue(fence.isLogoutInProgress)

        let repeatedEntered = expectation(description: "repeated logout entered coordinator")
        let repeated = Task { @MainActor in
            repeatedEntered.fulfill()
            return await coordinator.stopSessionsAndSignOut(participants: [firstWindow, secondWindow])
        }
        await fulfillment(of: [repeatedEntered], timeout: 2)

        XCTAssertEqual(firstWindow.stopCount, 1)
        XCTAssertEqual(secondWindow.stopCount, 1)
        let logoutCallCount = await logoutGate.callCount
        XCTAssertEqual(logoutCallCount, 1)

        await logoutGate.finish()
        let firstResult = await first.value
        let repeatedResult = await repeated.value
        XCTAssertEqual(firstResult, .signedOut)
        XCTAssertEqual(repeatedResult, .signedOut)
        XCTAssertEqual(firstWindow.stopCount, 1)
        XCTAssertEqual(secondWindow.stopCount, 1)
        XCTAssertTrue(fence.isFenced)
        XCTAssertFalse(fence.isLogoutInProgress)
    }

    func testLogoutFailureUnfencesNewWorkWithoutClaimingSuccess() async {
        let fence = CodexManagedSessionFence()
        let participant = ManagedLogoutParticipant()
        let coordinator = CodexManagedLogoutCoordinator(
            fence: fence,
            logoutOperation: { .failed(message: "logout rejected") }
        )

        let result = await coordinator.stopSessionsAndSignOut(participants: [participant])

        XCTAssertEqual(result, .failed(message: "logout rejected"))
        XCTAssertEqual(participant.stopCount, 1)
        XCTAssertFalse(fence.isFenced)
        XCTAssertFalse(fence.isLogoutInProgress)
    }

    func testLogoutFailureRunsRestartableTeardownRecoveryOnce() async {
        let fence = CodexManagedSessionFence()
        let participant = ManagedLogoutParticipant()
        let teardownCounter = ManagedLogoutCounter()
        let recoveryCounter = ManagedLogoutCounter()
        let coordinator = CodexManagedLogoutCoordinator(
            fence: fence,
            logoutOperation: { .failed(message: "logout rejected") }
        )

        let result = await coordinator.stopSessionsAndSignOut(
            participants: [participant],
            additionalTeardown: { teardownCounter.increment() },
            failedLogoutRecovery: { recoveryCounter.increment() }
        )

        XCTAssertEqual(result, .failed(message: "logout rejected"))
        XCTAssertEqual(teardownCounter.value, 1)
        XCTAssertEqual(recoveryCounter.value, 1)
        XCTAssertFalse(fence.isFenced)
        XCTAssertFalse(fence.isLogoutInProgress)
    }

    func testConfirmationDecisionSeamOffersOnlyCancelOrDestructiveStopAndSignOut() {
        XCTAssertFalse(CodexManagedSignOutConfirmation.shouldProceed(with: .cancel))
        XCTAssertTrue(CodexManagedSignOutConfirmation.shouldProceed(with: .stopSessionsAndSignOut))
        XCTAssertEqual(CodexManagedSignOutConfirmation.cancelTitle, "Cancel")
        XCTAssertEqual(CodexManagedSignOutConfirmation.confirmTitle, "Stop Sessions & Sign Out")
    }
}

@MainActor
private final class ManagedLogoutCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@MainActor
private final class ManagedLogoutParticipant: CodexManagedSessionShutdownParticipant {
    private(set) var stopCount = 0
    private let onStop: @MainActor () -> Void

    init(onStop: @escaping @MainActor () -> Void = {}) {
        self.onStop = onStop
    }

    func stopCodexSessionsForManagedLogout() async {
        stopCount += 1
        onStop()
    }
}

private final class ManagedLogoutExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private actor ManagedLogoutTestGate {
    let result: CodexManagedAuthLogoutResult
    private let onCall: ManagedLogoutExpectationSignal?
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(
        result: CodexManagedAuthLogoutResult,
        onCall: ManagedLogoutExpectationSignal? = nil
    ) {
        self.result = result
        self.onCall = onCall
    }

    func run() async -> CodexManagedAuthLogoutResult {
        callCount += 1
        onCall?.fulfill()
        guard !isOpen else { return result }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return result
    }

    func finish() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
