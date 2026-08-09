import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexManagedLogoutCoordinatorTests: XCTestCase {
    func testMultiWindowLogoutIsIdempotentAndAwaitsEveryParticipant() async throws {
        let fence = CodexManagedSessionFence()
        let logoutGate = ManagedLogoutTestGate(result: .signedOut)
        let coordinator = CodexManagedLogoutCoordinator(
            fence: fence,
            logoutOperation: { await logoutGate.run() }
        )
        let firstWindow = ManagedLogoutParticipant()
        let secondWindow = ManagedLogoutParticipant()

        let first = Task {
            await coordinator.stopSessionsAndSignOut(participants: [firstWindow, secondWindow])
        }
        try await waitUntil { firstWindow.stopCount == 1 && secondWindow.stopCount == 1 }
        XCTAssertTrue(fence.isFenced)
        XCTAssertTrue(fence.isLogoutInProgress)

        let repeated = Task {
            await coordinator.stopSessionsAndSignOut(participants: [firstWindow, secondWindow])
        }
        await Task.yield()
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

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Condition was not satisfied before timeout")
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

    func stopCodexSessionsForManagedLogout() async {
        stopCount += 1
    }
}

private actor ManagedLogoutTestGate {
    let result: CodexManagedAuthLogoutResult
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: CodexManagedAuthLogoutResult) {
        self.result = result
    }

    func run() async -> CodexManagedAuthLogoutResult {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
