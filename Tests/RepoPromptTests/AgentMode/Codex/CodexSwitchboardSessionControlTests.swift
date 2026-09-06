@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexSwitchboardSessionControlTests: XCTestCase {
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
        var suspendInstall = false
        var installContinuation: CheckedContinuation<Void, Never>?
        var runtime: CodexSwitchboardSessionControl.Runtime {
            .init(admission: { [self] in
                .init(
                    scope: scope,
                    isExplicitRootCodexSession: true,
                    isManagedHTTPBackend: true,
                    isIdle: true,
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

        func poll(lastSeenRevision: Int64) throws -> CodexAccountAdoptionGrant? {
            events.append("poll:\(lastSeenRevision)")
            if failing { throw CodexAccountAdoptionReason.bridgeUnavailable }
            return lastSeenRevision == 0 ? grant : nil
        }

        func refresh(previousGrant: CodexAccountAdoptionGrant) throws -> CodexAccountAdoptionGrant {
            throw CodexAccountAdoptionReason.bridgeUnavailable
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
    }
}
