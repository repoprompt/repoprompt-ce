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

/// The managed-auth authority reports established credentials so owners of long-lived
/// app-server processes can replace them. Routine reads of an unchanged account and the
/// launch-time check must not report, or every recovery read would restart those processes.
final class CodexManagedAuthTransitionTests: XCTestCase {
    /// Scripted `account/read` answers (an empty ID means signed out); `account/logout`
    /// always succeeds.
    private final class ScriptedAccountClient: CodexManagedAuthRPCClient, @unchecked Sendable {
        private let lock = NSLock()
        private var accountReads: [String]

        init(accountReads: [String]) {
            self.accountReads = accountReads
        }

        func updateDefaultRequestTimeout(_: TimeInterval?) async {}
        func startIfNeeded() async throws {}
        func stop() async {}

        func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
            if method == "account/logout" { return [:] }
            lock.lock()
            let accountID = accountReads.isEmpty ? "" : accountReads.removeFirst()
            lock.unlock()
            guard !accountID.isEmpty else {
                return ["account": NSNull(), "requiresOpenaiAuth": true]
            }
            return ["account": ["type": "chatgpt", "accountId": accountID], "requiresOpenaiAuth": true]
        }

        func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
            AsyncStream { $0.finish() }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CodexManagedAuthTransition] = []

        var values: [CodexManagedAuthTransition] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }

        func append(_ item: CodexManagedAuthTransition) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }
    }

    private func waitForCount(_ collected: Collected, _ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if collected.values.count >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func testReportsRecoveryAndAccountChangeOnlyAndOrdersSignOutInTheSameStream() async {
        // Each read uses a fresh client; the script is shared across them.
        let client = ScriptedAccountClient(accountReads: ["acct-A", "acct-A", "", "acct-A", "acct-B", "acct-B"])
        let service = CodexManagedAuthRecoveryService(clientFactory: { client }, refreshRequestTimeout: 1)
        let collected = Collected()
        let stream = await service.authTransitions()
        let collector = Task {
            for await transition in stream {
                collected.append(transition)
            }
        }

        _ = await service.refreshManagedAccount() // launch-time check: unknown -> acct-A, silent
        _ = await service.refreshManagedAccount() // unchanged account, silent
        _ = await service.refreshManagedAccount() // requires login
        _ = await service.refreshManagedAccount() // recovered after observed sign-out
        let recovered = await waitForCount(collected, 1)
        XCTAssertTrue(recovered)
        _ = await service.refreshManagedAccount() // account change
        let changed = await waitForCount(collected, 2)
        XCTAssertTrue(changed)

        let logout = await service.logoutManagedAccount()
        XCTAssertEqual(logout, .signedOut)
        let signOutReported = await waitForCount(collected, 3)
        XCTAssertTrue(signOutReported)

        _ = await service.refreshManagedAccount() // same account, but after a sign-out
        let afterSignOut = await waitForCount(collected, 4)
        XCTAssertTrue(afterSignOut)

        // Earlier sign-ins carry the pre-sign-out generation; the sign-out and everything
        // after it carry the generation the sign-out moved to.
        XCTAssertEqual(collected.values, [
            .established(accountID: "acct-A", generation: 0),
            .established(accountID: "acct-B", generation: 0),
            .signOutStarted(generation: 1),
            .established(accountID: "acct-B", generation: 1)
        ])
        collector.cancel()
    }
}
