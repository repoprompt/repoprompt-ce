import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexManagedLogoutCoordinatorTests: XCTestCase {
    func testAllManagedAuthoritiesAreInvalidBeforeFencePublicationAndAsyncTeardown() async {
        let fence = CodexManagedSessionFence()
        let authorities = (0 ..< 3).map { _ in CodexAccountAdoptionAuthorization() }
        let first = GatedLogoutParticipant(authorities: Array(authorities.prefix(2)))
        let second = GatedLogoutParticipant(authorities: Array(authorities.suffix(1)))
        let stopsEntered = expectation(description: "Both asynchronous stops entered")
        stopsEntered.expectedFulfillmentCount = 2
        first.didEnterStop = { stopsEntered.fulfill() }
        second.didEnterStop = { stopsEntered.fulfill() }
        var observedPublication = false
        let observation = fence.$isLogoutInProgress.sink { inProgress in
            guard inProgress else { return }
            observedPublication = true
            for authorization in authorities {
                XCTAssertNil(try? authorization.withAuthorization { true })
            }
        }
        let coordinator = CodexManagedLogoutCoordinator(fence: fence, logoutOperation: { .signedOut })
        let logout = Task { await coordinator.stopSessionsAndSignOut(participants: [first, second]) }
        await fulfillment(of: [stopsEntered], timeout: 2)
        XCTAssertTrue(observedPublication)
        XCTAssertTrue(fence.isLogoutInProgress)
        // The same synchronous permit used at final native publication must
        // reject another actor even though asynchronous shutdown is suspended.
        let accepted = await Task.detached {
            authorities.count(where: { (try? $0.withAuthorization { true }) == true })
        }.value
        XCTAssertEqual(accepted, 0)
        first.resumeStop()
        second.resumeStop()
        let result = await logout.value
        XCTAssertEqual(result, .signedOut)
        XCTAssertTrue(fence.isFenced)
        withExtendedLifetime(observation) {}
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
private final class GatedLogoutParticipant: CodexManagedSessionShutdownParticipant {
    let authorities: [CodexAccountAdoptionAuthorization]
    var didEnterStop: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    init(authorities: [CodexAccountAdoptionAuthorization]) {
        self.authorities = authorities
    }

    func invalidateSwitchboardAuthoritiesForManagedLogout() {
        authorities.forEach { $0.invalidate() }
    }

    func stopCodexSessionsForManagedLogout() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didEnterStop?()
        }
    }

    func resumeStop() {
        continuation?.resume()
        continuation = nil
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

    func invalidateSwitchboardAuthoritiesForManagedLogout() {}

    func stopCodexSessionsForManagedLogout() async {
        stopCount += 1
    }
}
