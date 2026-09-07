@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexSwitchboardAutomaticControlTests: XCTestCase {
    func testOfferNeverAutomaticallyEnrollsOrBlocksBusyBaseSession() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.control.revoke() }
        fixture.idle = false
        let reservations = fixture.reservations
        await fixture.automatic.syncOnce()
        XCTAssertNil(fixture.automatic.enrollment)
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertEqual(fixture.reservations, reservations)
        let accepted = await fixture.wire.isAccepted()
        XCTAssertFalse(accepted)
        try await fixture.approve()
        await fixture.automatic.syncOnce()
        try await eventually { await fixture.wire.prepareCount() > 0 }
        try await eventually { !fixture.automatic.isWorkInFlight }
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertEqual(fixture.reservations, reservations)
        XCTAssertEqual(fixture.installed, ["fixture-a"])
        let began = await fixture.wire.beginCount()
        XCTAssertEqual(began, 0)
    }

    func testIndependentPauseFencesDelayedBeginAndPreservesAppliedAccount() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.control.revoke() }
        try await fixture.approve()
        await fixture.wire.holdBegin()
        await fixture.automatic.syncOnce()
        try await eventually { await fixture.wire.beginIsHeld() }
        await fixture.wire.pause()
        await fixture.automatic.syncOnce()
        await fixture.wire.releaseBegin()
        try await eventually { await fixture.wire.receiptCount() > 0 }
        try await eventually { !fixture.control.isTransactionInFlight }
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertEqual(fixture.control.state, .appliedUnverified(revision: 1))
        XCTAssertEqual(fixture.installed, ["fixture-a"])
        let outcomes = await fixture.wire.outcomes()
        XCTAssertEqual(outcomes, ["fenced_unpublished"])
        XCTAssertNoThrow(try fixture.control.authorization.withAuthorization {})
        let renewed = try await fixture.control.refresh(previousAccountID: "fixture-a")
        XCTAssertEqual(renewed.accountID, "fixture-a")
        XCTAssertFalse(fixture.control.blocksDispatch)
    }

    func testPauseAfterCompletePublicationWaitsForNativeAcknowledgment() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.control.revoke() }
        fixture.holdInstall = true
        try await fixture.approve()
        await fixture.automatic.syncOnce()
        try await eventually { fixture.installContinuation != nil }
        await fixture.wire.pause()
        await fixture.automatic.syncOnce()
        let receiptsBefore = await fixture.wire.receiptCount()
        XCTAssertEqual(receiptsBefore, 0)
        XCTAssertTrue(fixture.automatic.statusText.contains("Pausing"))
        fixture.installContinuation?.resume()
        fixture.installContinuation = nil
        try await eventually { await fixture.wire.receiptCount() > 0 }
        try await eventually { !fixture.control.isTransactionInFlight }
        XCTAssertEqual(fixture.control.state, .appliedUnverified(revision: 2))
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertEqual(fixture.installed, ["fixture-a", "fixture-b"])
        let outcomes = await fixture.wire.outcomes()
        XCTAssertEqual(outcomes, ["applied"])
    }

    func testAutomaticChannelFailureDoesNotRevokeManualPairing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.control.revoke() }
        await fixture.wire.failSync()
        await fixture.automatic.syncOnce()
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertEqual(fixture.control.state, .appliedUnverified(revision: 1))
        XCTAssertNoThrow(try fixture.control.authorization.withAuthorization {})
    }

    func testAllBusyAdmissionReasonsLeaveAutomaticIntentNonblocking() async throws {
        for blocker in 1 ... 5 {
            let fixture = try await Fixture.make()
            defer { fixture.control.revoke() }
            fixture.blocker = blocker
            try await fixture.approve()
            let reservations = fixture.reservations
            await fixture.automatic.syncOnce()
            try await eventually { await fixture.wire.prepareCount() > 0 }
            try await eventually { !fixture.automatic.isWorkInFlight }
            XCTAssertEqual(fixture.reservations, reservations, "Admission blocker \(blocker)")
            XCTAssertFalse(fixture.control.blocksDispatch)
        }
    }

    func testLostBeginAndUnknownCancellationIDNeverInventZeroPublicationReceipt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.control.revoke() }
        try await fixture.approve()
        await fixture.wire.loseBeginResponse()
        await fixture.automatic.syncOnce()
        try await eventually { await fixture.wire.beginCount() == 1 }
        try await eventually { !fixture.automatic.isWorkInFlight }
        await fixture.wire.pause()
        await fixture.automatic.syncOnce()
        let receipts = await fixture.wire.receiptCount()
        XCTAssertEqual(receipts, 0)
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertTrue(fixture.automatic.statusText.contains("Pausing"))
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Bounded fixture transition did not settle")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor private final class Fixture {
        let control = CodexSwitchboardSessionControl()
        let scope = CodexAccountAdoptionScope(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: "retained")
        let base = BaseBridge()
        let wire = Wire()
        var automatic: CodexSwitchboardAutomaticControl {
            control.automatic!
        }

        var idle = true
        var blocker = 0
        var reservations = 0
        var installed: [String] = []
        var holdInstall = false
        var installContinuation: CheckedContinuation<Void, Never>?

        static func make() async throws -> Fixture {
            let f = Fixture()
            let runtime = CodexSwitchboardSessionControl.Runtime(admission: {
                .init(
                    scope: f.scope,
                    isExplicitRootCodexSession: true,
                    isManagedHTTPBackend: true,
                    isIdle: f.idle,
                    hasPendingInteraction: f.blocker == 1,
                    hasActiveTools: f.blocker == 2,
                    hasActiveChildren: f.blocker == 3,
                    hasQueuedDispatch: f.blocker == 4,
                    hasRecoveryOrReconnect: f.blocker == 5
                )
            }, inspect: {
                .init(
                    threadID: "retained",
                    loadedThreadIDs: ["retained"],
                    isAuthoritativelyIdle: f.idle,
                    hasInProgressTools: false,
                    managedHTTP: true,
                    pinnedRuntime: true
                )
            }, reserve: { f.reservations += 1
                return UUID()
            }, finish: { _, _ in }, install: { grant in
                f.installed.append(grant.accountID)
                return .init(externalTokenLogin: true, isChatGPTAccount: true, email: grant.email)
            }, automatic: .init(peer: { .init(pid: 1234, start: .init(seconds: 1, microseconds: 0)) }, hasEnded: { false }, install: { grant, permit in
                try f.control.authorization.withAuthorization {
                    try permit.publishChunk(offset: 0, count: 1, isFinal: true) { f.installed.append(grant.accountID) }
                }
                if f.holdInstall { await withCheckedContinuation { f.installContinuation = $0 } }
                return .init(externalTokenLogin: true, isChatGPTAccount: true, email: grant.email)
            }))
            try await f.control.connect(scope: f.scope, bridge: f.base, runtime: runtime)
            await f.control.pollOnce()
            let client = try SwitchboardAutomaticClient(pairing: SwitchboardBridgeTestData.envelope(), scope: f.scope) { _, data in try await f.wire.exchange(data) }
            try await client.hello()
            f.control.observeAutomaticOffers(client: client, startPolling: false)
            return f
        }

        func approve() async throws {
            await automatic.syncOnce()
            let id = try XCTUnwrap(automatic.offer?.id)
            try await automatic.accept(offerID: id)
        }
    }
}
