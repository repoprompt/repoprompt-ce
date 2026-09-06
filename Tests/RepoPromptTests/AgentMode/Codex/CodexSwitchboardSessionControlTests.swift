@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexSwitchboardSessionControlTests: XCTestCase {
    func testRefreshKeepsAppliedAccountUsableWhileNewSelectionWaits() async throws {
        let fixture = Fixture()
        let bridge = Bridge()
        let control = CodexSwitchboardSessionControl()
        fixture.control = control
        try await control.connect(scope: fixture.scope, bridge: bridge, runtime: fixture.runtime)
        await control.pollOnce()
        fixture.isIdle = false
        await bridge.queueSecondSelection()
        await control.pollOnce()
        let renewed = try await control.refresh(previousAccountID: "synthetic-account")
        XCTAssertEqual(renewed.accountID, "synthetic-account")
        XCTAssertEqual(control.state, .waitingIdle(.busy))
        XCTAssertFalse(control.blocksDispatch)
        XCTAssertEqual(fixture.finishes.last, true)
        XCTAssertEqual(control.accountSummary, "Applied: synthetic-account · Pending: synthetic-b")
        fixture.isIdle = true
        await control.pollOnce()
        XCTAssertEqual(control.state, .appliedUnverified(revision: 2))
        XCTAssertEqual(control.accountSummary, "Applied: synthetic-b")
        await control.revokeAndWait()
    }

    func testSuspendedRoutinePollDoesNotReserveRuntimeOrBlockDispatch() async throws {
        let fixture = Fixture()
        let bridge = Bridge()
        let control = CodexSwitchboardSessionControl()
        fixture.control = control
        try await control.connect(scope: fixture.scope, bridge: bridge, runtime: fixture.runtime)
        await control.pollOnce()
        let reservationsBefore = fixture.reservations
        await bridge.suspendNextPoll()
        let polling = Task { await control.pollOnce() }
        while await !bridge.isPollSuspended() {
            await Task.yield()
        }
        XCTAssertFalse(control.blocksDispatch)
        XCTAssertEqual(fixture.reservations, reservationsBefore)
        await bridge.resumePoll()
        await polling.value
        await control.revokeAndWait()
    }

    func testRevocationWhileNativeInstallIsSuspendedNeverReopensDispatch() async throws {
        let fixture = Fixture()
        fixture.suspendInstall = true
        let bridge = Bridge()
        let control = CodexSwitchboardSessionControl()
        fixture.control = control
        try await control.connect(scope: fixture.scope, bridge: bridge, runtime: fixture.runtime)
        let polling = Task { await control.pollOnce() }
        while fixture.installContinuation == nil {
            await Task.yield()
        }
        control.revoke()
        fixture.installContinuation?.resume()
        fixture.installContinuation = nil
        await polling.value
        await control.revokeAndWait()
        XCTAssertEqual(control.state, .revoked)
        XCTAssertTrue(control.blocksDispatch)
        XCTAssertFalse(fixture.finishes.contains(true))
        XCTAssertThrowsError(try control.authorization.withAuthorization {})
    }

    func testBridgeAndRuntimeTransactionKeepSameScopeAndGateDispatch() async throws {
        let fixture = Fixture()
        let bridge = Bridge()
        let control = CodexSwitchboardSessionControl()
        fixture.control = control
        try await control.connect(scope: fixture.scope, bridge: bridge, runtime: fixture.runtime)
        XCTAssertTrue(control.blocksDispatch)
        await control.pollOnce()
        XCTAssertEqual(control.state, .appliedUnverified(revision: 1))
        XCTAssertFalse(control.blocksDispatch)
        XCTAssertEqual(fixture.installed, ["synthetic-account"])
        XCTAssertEqual(fixture.finishes, [false, true])
        let events = await bridge.recorded()
        XCTAssertEqual(events, ["register:retained", "poll:0", "applying:1", "applied_unverified:1"])
        XCTAssertEqual(control.scope?.threadID, "retained")
        XCTAssertEqual(control.statusText, "Account applied; next request unverified.")
        await control.revokeAndWait()
    }

    func testBridgeLossAndRevocationBlockFutureDispatchWithoutReplacingThread() async throws {
        let fixture = Fixture()
        let bridge = Bridge()
        let control = CodexSwitchboardSessionControl()
        fixture.control = control
        try await control.connect(scope: fixture.scope, bridge: bridge, runtime: fixture.runtime)
        await control.pollOnce()
        await bridge.failPoll()
        await control.pollOnce()
        XCTAssertTrue(control.blocksDispatch)
        XCTAssertEqual(control.state, .failedUnknown(.bridgeUnavailable))
        await control.revokeAndWait()
        XCTAssertEqual(control.state, .revoked)
        XCTAssertEqual(control.scope?.threadID, "retained")
        XCTAssertTrue(control.blocksDispatch)
    }

    @MainActor private final class Fixture {
        let scope = CodexAccountAdoptionScope(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: "retained")
        weak var control: CodexSwitchboardSessionControl?
        var installed: [String] = []
        var finishes: [Bool] = []
        var reservations = 0
        var isIdle = true
        var suspendInstall = false
        var installContinuation: CheckedContinuation<Void, Never>?
        var runtime: CodexSwitchboardSessionControl.Runtime {
            .init(admission: { [self] in
                .init(
                    scope: scope,
                    isExplicitRootCodexSession: true,
                    isManagedHTTPBackend: true,
                    isIdle: isIdle,
                    hasPendingInteraction: false,
                    hasActiveTools: false,
                    hasActiveChildren: false,
                    hasQueuedDispatch: false,
                    hasRecoveryOrReconnect: false
                )
            }, inspect: { [self] in
                XCTAssertTrue(control?.blocksDispatch == true)
                return .init(
                    threadID: scope.threadID,
                    loadedThreadIDs: [scope.threadID],
                    isAuthoritativelyIdle: true,
                    hasInProgressTools: false,
                    managedHTTP: true,
                    pinnedRuntime: true
                )
            }, reserve: { [self] in
                XCTAssertTrue(control?.blocksDispatch == true)
                reservations += 1
                return UUID()
            }, finish: { [self] _, allow in finishes.append(allow) }, install: { [self] grant in
                XCTAssertTrue(control?.blocksDispatch == true)
                installed.append(grant.accountID)
                if suspendInstall { await withCheckedContinuation { installContinuation = $0 } }
                return .init(externalTokenLogin: true, isChatGPTAccount: true, email: nil)
            })
        }
    }

    private actor Bridge: CodexSwitchboardBridge {
        var events: [String] = []
        var failing = false
        var shouldSuspendPoll = false
        var pollContinuation: CheckedContinuation<Void, Never>?
        var secondGrant: CodexAccountAdoptionGrant?
        let grant = CodexAccountAdoptionGrant(
            adoptionID: UUID(),
            selectionID: UUID(),
            revision: 1,
            expiresAt: Date().addingTimeInterval(600),
            accountID: "synthetic-account",
            email: nil,
            plan: nil,
            accessToken: "synthetic-only-token"
        )
        func register(threadID: String?) {
            events.append("register:\(threadID ?? "null")")
        }

        func poll(lastSeenRevision: Int64) async throws -> CodexAccountAdoptionGrant? {
            events.append("poll:\(lastSeenRevision)")
            if shouldSuspendPoll { await withCheckedContinuation { pollContinuation = $0 } }
            if failing { throw CodexAccountAdoptionReason.bridgeUnavailable }
            return lastSeenRevision == 0 ? grant : (lastSeenRevision == 1 ? secondGrant : nil)
        }

        func refresh(previousGrant: CodexAccountAdoptionGrant) throws -> CodexAccountAdoptionGrant {
            CodexAccountAdoptionGrant(
                adoptionID: previousGrant.adoptionID, selectionID: previousGrant.selectionID,
                revision: previousGrant.revision, expiresAt: Date().addingTimeInterval(600),
                accountID: previousGrant.accountID, email: previousGrant.email, plan: previousGrant.plan,
                accessToken: "renewed-synthetic-only"
            )
        }

        func status(adoptionID: UUID, expectedRevision: Int64, state: String, reason: String) {
            events.append("\(state):\(expectedRevision)")
        }

        func revoke() {
            events.append("revoke")
        }

        func recorded() -> [String] {
            events
        }

        func failPoll() {
            failing = true
        }

        func queueSecondSelection() {
            secondGrant = CodexAccountAdoptionGrant(
                adoptionID: UUID(), selectionID: UUID(), revision: 2, expiresAt: Date().addingTimeInterval(600),
                accountID: "synthetic-b", email: nil, plan: nil, accessToken: "synthetic-b-only"
            )
        }

        func suspendNextPoll() {
            shouldSuspendPoll = true
        }

        func isPollSuspended() -> Bool {
            pollContinuation != nil
        }

        func resumePoll() {
            shouldSuspendPoll = false
            pollContinuation?.resume()
            pollContinuation = nil
        }
    }
}
