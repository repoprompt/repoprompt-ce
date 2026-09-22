import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexManagedLogoutCoordinatorTests: XCTestCase {
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

    func stopCodexSessionsForManagedLogout() async {
        stopCount += 1
    }
}
