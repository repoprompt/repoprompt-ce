@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexAccountAdoptionTests: XCTestCase {
    func testIdleAdoptionPreservesExactThreadAndDoesNotClaimOutgoingVerification() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        await adoption.submit(fixture.grant())
        XCTAssertEqual(adoption.state, .appliedUnverified(revision: 1))
        XCTAssertFalse(adoption.blocksDispatch)
        XCTAssertEqual(fixture.installs, ["account-b"])
        XCTAssertEqual(fixture.inspections, 2)
    }

    func testBusyToolsChildrenAndQueuedWorkWaitWithoutInstalling() async {
        for reason in [CodexAccountAdoptionReason.busy, .pendingInteraction, .activeTools, .activeChildren, .queuedDispatch] {
            let fixture = Fixture()
            fixture.blocker = reason
            let adoption = fixture.makeAdoption()
            await adoption.submit(fixture.grant())
            XCTAssertEqual(adoption.state, .waitingIdle(reason))
            XCTAssertTrue(fixture.installs.isEmpty)
            XCTAssertEqual(fixture.inspections, 0)
            fixture.blocker = nil
            await adoption.retryAtIdleBoundary()
            XCTAssertEqual(adoption.state, .appliedUnverified(revision: 1))
        }
    }

    func testLegacyChildUnknownAndNonIdleRuntimeRefuseBeforeMutation() async {
        for variant in 0 ..< 5 {
            let fixture = Fixture()
            switch variant {
            case 0: fixture.isRoot = false
            case 1: fixture.isManaged = false
            case 2: fixture.runtimeIdle = false
            case 3: fixture.httpVerified = false
            default: fixture.loadedIDs.append("another-thread")
            }
            let adoption = fixture.makeAdoption()
            await adoption.submit(fixture.grant())
            XCTAssertTrue(fixture.installs.isEmpty)
            XCTAssertTrue(adoption.blocksDispatch)
            XCTAssertNotEqual(adoption.state, .appliedUnverified(revision: 1))
        }
    }

    func testControllerChangeDuringInspectionNeverInstalls() async {
        let fixture = Fixture()
        fixture.onInspect = { fixture.scope = Fixture.scope() }
        let adoption = fixture.makeAdoption()
        await adoption.submit(fixture.grant())
        XCTAssertEqual(adoption.state, .failedUnknown(.identityChanged))
        XCTAssertTrue(fixture.installs.isEmpty)
    }

    func testRevocationDuringLoginDoesNotPublishSuccessOrReleaseDispatch() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        fixture.onInstall = { adoption.revoke() }
        await adoption.submit(fixture.grant())
        XCTAssertEqual(adoption.state, .revoked)
        XCTAssertTrue(adoption.blocksDispatch)
        XCTAssertEqual(fixture.installs.count, 1)
    }

    func testPostLoginThreadMismatchAndErrorStayBlockedWithoutRetry() async {
        for throwError in [false, true] {
            let fixture = Fixture()
            fixture.onInstall = {
                if throwError { throw TestError.secretBearingError("DO-NOT-EMIT-SECRET") }
                fixture.runtimeThread = "wrong-thread"
            }
            let adoption = fixture.makeAdoption()
            await adoption.submit(fixture.grant())
            XCTAssertEqual(adoption.state, .failedUnknown(.mutationUnconfirmed))
            XCTAssertTrue(adoption.blocksDispatch)
            await adoption.retryAtIdleBoundary()
            XCTAssertEqual(fixture.installs.count, 1)
            XCTAssertFalse(String(describing: adoption.state).contains("DO-NOT-EMIT-SECRET"))
        }
    }

    func testReplayDoesNotReinstallAndExpiredGrantCannotMutate() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        await adoption.submit(fixture.grant())
        await adoption.submit(fixture.grant())
        XCTAssertEqual(fixture.installs.count, 1)
        let expiredFixture = Fixture()
        let expired = expiredFixture.makeAdoption()
        await expired.submit(expiredFixture.grant(expired: true))
        XCTAssertEqual(expired.state, .failedUnknown(.grantExpired))
        XCTAssertTrue(expiredFixture.installs.isEmpty)
    }

    func testRefreshRemainsPinnedAndRejectsWrongPreviousAccount() async throws {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        await adoption.submit(fixture.grant())
        fixture.onRenew = {
            XCTAssertTrue(adoption.reservesController)
            XCTAssertTrue(adoption.blocksDispatch)
        }
        let refreshed = try await adoption.refresh(previousAccountID: "account-b")
        XCTAssertEqual(refreshed.accountID, "account-b")
        XCTAssertEqual(fixture.renewals, ["account-b"])
        do {
            _ = try await adoption.refresh(previousAccountID: "account-c")
            XCTFail("Wrong account was accepted")
        } catch {}
        XCTAssertEqual(fixture.renewals.count, 1)
    }

    func testRefreshRejectsBridgeIdentityChangeAndRevocation() async {
        for revoke in [false, true] {
            let fixture = Fixture()
            let adoption = fixture.makeAdoption()
            await adoption.submit(fixture.grant())
            XCTAssertEqual(adoption.state, .appliedUnverified(revision: 1))
            XCTAssertEqual(fixture.installs.count, 1)
            fixture.onRenew = { if revoke { adoption.revoke() } }
            fixture.renewAccount = revoke ? "account-b" : "account-c"
            do {
                _ = try await adoption.refresh(previousAccountID: "account-b")
                XCTFail("Stale refresh was accepted")
            } catch {}
            XCTAssertTrue(adoption.blocksDispatch)
        }
    }

    func testReservationSurvivesAwaitAndNewerSelectionSupersedesBeforeMutation() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        fixture.onInspect = {
            XCTAssertTrue(adoption.blocksDispatch)
            XCTAssertTrue(adoption.reservesController)
            await adoption.submit(fixture.grant(account: "account-c", revision: 2))
            fixture.onInspect = nil
        }
        await adoption.submit(fixture.grant())
        XCTAssertTrue(fixture.installs.isEmpty)
        XCTAssertTrue(adoption.blocksDispatch)
        await adoption.retryAtIdleBoundary()
        XCTAssertEqual(fixture.installs, ["account-c"])
        XCTAssertEqual(adoption.state, .appliedUnverified(revision: 2))
    }

    func testSecretDescriptionAndReflectionAreRedacted() {
        let grant = Fixture().grant(token: "DO-NOT-EMIT-SECRET")
        XCTAssertFalse(String(describing: grant).contains(grant.accessToken))
        XCTAssertFalse(String(reflecting: grant).contains(grant.accessToken))
        XCTAssertTrue(Mirror(reflecting: grant).children.isEmpty)
        let response = CodexNativeSessionController.ChatgptAuthTokensRefreshResponse(
            accessToken: grant.accessToken, chatgptAccountID: grant.accountID, chatgptPlanType: nil
        )
        XCTAssertFalse(String(describing: response).contains(grant.accessToken))
        XCTAssertFalse(String(reflecting: response).contains(grant.accessToken))
        XCTAssertTrue(Mirror(reflecting: response).children.isEmpty)
    }

    func testNewSelectionDuringRefreshReportsWaitingAndLetsExistingQueueDrain() async throws {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        await adoption.submit(fixture.grant())
        fixture.blocker = .queuedDispatch
        fixture.onRenew = { await adoption.submit(fixture.grant(account: "account-c", revision: 2)) }
        _ = try await adoption.refresh(previousAccountID: "account-b")
        XCTAssertEqual(adoption.state, .waitingIdle(.busy))
        await adoption.retryAtIdleBoundary()
        XCTAssertEqual(adoption.state, .waitingIdle(.queuedDispatch))
        XCTAssertFalse(adoption.blocksDispatch, "Previously accepted queued work must be able to reach an idle boundary")
        fixture.blocker = nil
        await adoption.retryAtIdleBoundary()
        XCTAssertEqual(adoption.state, .appliedUnverified(revision: 2))
    }

    func testBridgeTransactionAcknowledgementsPrecedeDispatchRelease() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        fixture.onAcknowledge = {
            XCTAssertTrue(adoption.blocksDispatch)
            XCTAssertTrue(adoption.reservesController)
            XCTAssertEqual(adoption.state, .applying)
        }
        await adoption.submit(fixture.grant())
        XCTAssertEqual(fixture.transactionCalls, ["begin", "install", "acknowledge"])
        XCTAssertEqual(adoption.state, .appliedUnverified(revision: 1))
    }

    func testLostBridgeAcknowledgementAfterMutationCannotReleaseDispatch() async {
        let fixture = Fixture()
        let adoption = fixture.makeAdoption()
        fixture.onAcknowledge = { throw TestError.secretBearingError("DO-NOT-EMIT-SECRET") }
        await adoption.submit(fixture.grant())
        XCTAssertEqual(fixture.installs.count, 1)
        XCTAssertEqual(adoption.state, .failedUnknown(.mutationUnconfirmed))
        XCTAssertTrue(adoption.blocksDispatch)
    }

    private enum TestError: Error { case secretBearingError(String) }

    @MainActor
    private final class Fixture {
        static func scope() -> CodexAccountAdoptionScope {
            .init(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: "original-thread")
        }

        var scope = Fixture.scope()
        var blocker: CodexAccountAdoptionReason?
        var isRoot = true
        var isManaged = true
        var runtimeIdle = true
        var httpVerified = true
        var runtimeThread = "original-thread"
        var loadedIDs = ["original-thread"]
        var installs: [String] = []
        var inspections = 0
        var renewals: [String] = []
        var renewAccount = "account-b"
        var onInspect: (() async -> Void)?
        var onInstall: (() throws -> Void)?
        var onRenew: (() async -> Void)?
        var onAcknowledge: (() throws -> Void)?
        var transactionCalls: [String] = []
        let adoptionID = UUID()
        let selectionID = UUID()
        let now = Date(timeIntervalSince1970: 1000)

        func grant(expired: Bool = false, account: String = "account-b", token: String = "synthetic-token", revision: Int64 = 1) -> CodexAccountAdoptionGrant {
            .init(
                adoptionID: adoptionID,
                selectionID: selectionID,
                revision: revision,
                expiresAt: now.addingTimeInterval(expired ? -1 : 60),
                accountID: account,
                email: "b@example.invalid",
                plan: "plus",
                accessToken: token
            )
        }

        func makeAdoption() -> CodexAccountAdoption {
            CodexAccountAdoption(scope: scope, dependencies: .init(
                admission: {
                    .init(
                        scope: self.scope,
                        isExplicitRootCodexSession: self.isRoot,
                        isManagedHTTPBackend: self.isManaged,
                        isIdle: self.blocker != .busy,
                        hasPendingInteraction: self.blocker == .pendingInteraction,
                        hasActiveTools: self.blocker == .activeTools,
                        hasActiveChildren: self.blocker == .activeChildren,
                        hasQueuedDispatch: self.blocker == .queuedDispatch,
                        hasRecoveryOrReconnect: false
                    )
                },
                inspectRuntime: {
                    self.inspections += 1
                    await self.onInspect?()
                    return .init(
                        threadID: self.runtimeThread,
                        loadedThreadIDs: self.loadedIDs,
                        isAuthoritativelyIdle: self.runtimeIdle,
                        hasInProgressTools: false,
                        managedHTTP: self.httpVerified,
                        pinnedRuntime: true
                    )
                },
                install: { grant in
                    self.transactionCalls.append("install")
                    self.installs.append(grant.accountID)
                    try self.onInstall?()
                    return .init(externalTokenLogin: true, isChatGPTAccount: true, email: grant.email)
                },
                renew: { _, previous in
                    self.renewals.append(previous)
                    await self.onRenew?()
                    return self.grant(account: self.renewAccount, token: "synthetic-renewed-token")
                },
                now: { self.now },
                beginApplication: { _ in self.transactionCalls.append("begin") },
                acknowledgeApplication: { _ in
                    self.transactionCalls.append("acknowledge")
                    try self.onAcknowledge?()
                }
            ))
        }
    }
}
