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

    private actor BaseBridge: CodexSwitchboardBridge {
        let grant = CodexAccountAdoptionGrant(adoptionID: UUID(), selectionID: UUID(), revision: 1, expiresAt: Date().addingTimeInterval(600), accountID: "fixture-a", email: "a@example.invalid", plan: "pro", accessToken: "synthetic-a")
        func register(threadID _: String?) {}
        func poll(lastSeenRevision: Int64) -> CodexAccountAdoptionGrant? {
            lastSeenRevision == 0 ? grant : nil
        }

        func refresh(previousGrant: CodexAccountAdoptionGrant) -> CodexAccountAdoptionGrant {
            .init(
                adoptionID: previousGrant.adoptionID,
                selectionID: previousGrant.selectionID,
                revision: previousGrant.revision,
                expiresAt: previousGrant.expiresAt,
                accountID: previousGrant.accountID,
                email: previousGrant.email,
                plan: previousGrant.plan,
                accessToken: "synthetic-renewed-a"
            )
        }

        func status(adoptionID _: UUID, expectedRevision _: Int64, state _: String, reason _: String) {}
        func revoke() {}
    }

    private actor Wire {
        let server = UUID().uuidString.lowercased()
        let enrollmentID = UUID().uuidString.lowercased()
        let enrollmentEpoch = UUID().uuidString.lowercased()
        let offerID = UUID().uuidString.lowercased()
        let intentID = UUID().uuidString.lowercased()
        let batchID = UUID().uuidString.lowercased()
        let preparedID = UUID().uuidString.lowercased()
        let permitID = UUID().uuidString.lowercased()
        let expires = Int(Date().timeIntervalSince1970) + 60
        var accepted = false
        var paused = false
        var failed = false
        var preparedCount = 0
        var beganCount = 0
        var receiptOutcomes: [String] = []
        var shouldHoldBegin = false
        var losesBegin = false
        var beginContinuation: CheckedContinuation<Void, Never>?
        var source: [String: Any] = [:]
        var manualGeneration = 0
        var enrollment: [String: Any] {
            ["enrollment_id": enrollmentID, "enrollment_epoch": enrollmentEpoch, "rule_id": "test-rule", "rule_digest": try! SwitchboardAutomaticOffer.policyDigest(ruleID: "test-rule", accounts: ["a@example.invalid", "b@example.invalid"], trigger: 60, remaining: 50, cooldown: 1, freshness: 60), "rule_epoch": String(repeating: "b", count: 32), "approval_revision": 1]
        }

        var epoch: Int {
            paused ? 2 : 1
        }

        var control: [String: Any] {
            ["control_epoch": epoch, "desired_paused": paused, "effective_state": paused ? "pausing" : "enabled", "cancel_permit_ids": paused && beganCount > 0 ? [permitID] : []]
        }

        var intent: [String: Any] {
            ["intent_id": intentID, "batch_id": batchID, "enrollment_id": enrollmentID, "rule_revision": 1, "control_epoch": 1, "source_binding": source, "destination": ["account": "b@example.invalid", "account_id": "fixture-b"], "manual_generation": manualGeneration, "expires_at": expires]
        }

        var prepared: [String: Any] {
            ["prepared_id": preparedID, "intent": intent, "expires_at": expires]
        }

        func exchange(_ data: Data) async throws -> Data {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let op = try XCTUnwrap(request["op"] as? String)
            var result: [String: Any]
            switch op {
            case "auto_hello": result = ["automation_protocol": 1, "server_id": server]
            case "auto_sync":
                if failed { throw SwitchboardBridgeError.unavailable }
                source = request["applied_binding"] as? [String: Any] ?? [:]
                manualGeneration = request["manual_generation"] as? Int ?? 0
                let policy: [String: Any] = ["name": "Test rule", "accounts": ["a@example.invalid", "b@example.invalid"], "trigger_used_percent": 60, "destination_remaining_percent": 50, "cooldown_minutes": 1, "freshness_seconds": 60]
                result = ["control": control, "offer": accepted ? NSNull() : ["offer_id": offerID, "enrollment": enrollment, "policy": policy, "expires_at": Int(Date().timeIntervalSince1970) + 60], "enrollment": accepted ? enrollment : NSNull(), "intent": accepted && !paused ? intent : NSNull()]
            case "auto_accept": accepted = true
                result = ["enrollment": enrollment, "control": control]
            case "auto_prepare": preparedCount += 1
                result = ["state": "prepared", "prepared": prepared, "reason": "none"]
            case "auto_begin":
                beganCount += 1
                if losesBegin { throw SwitchboardBridgeError.unavailable }
                let pinnedSource = source
                let generation = manualGeneration
                if shouldHoldBegin { await withCheckedContinuation { beginContinuation = $0 } }
                let permit: [String: Any] = ["permit_id": permitID, "prepared_id": preparedID, "batch_id": batchID, "enrollment_id": enrollmentID, "enrollment_epoch": enrollmentEpoch, "rule_revision": 1, "control_epoch": 1, "source_binding": pinnedSource, "manual_generation": generation, "native_peer": request["native_peer"]!, "ttl_ms": 5000]
                let grant: [String: Any] = ["selection_id": UUID().uuidString.lowercased(), "adoption_id": UUID().uuidString.lowercased(), "selection_revision": 2, "expires_at": Int(Date().timeIntervalSince1970) + 60, "account_id": "fixture-b", "email": "b@example.invalid", "plan": "pro", "access_token": "synthetic-b"]
                result = ["permit": permit, "selection": grant]
            case "auto_finish":
                let receipt = try XCTUnwrap(request["receipt"] as? [String: Any])
                try receiptOutcomes.append(XCTUnwrap(receipt["outcome"] as? String))
                result = ["accepted": true, "control": control]
            case "auto_revoke": accepted = false
                result = ["revoked": true, "control": control]
            default: throw SwitchboardBridgeError.invalidRequest
            }
            return try SwitchboardBridgeWire.encodeFrame(["v": 2, "id": request["id"]!, "result": result])
        }

        func isAccepted() -> Bool {
            accepted
        }

        func prepareCount() -> Int {
            preparedCount
        }

        func beginCount() -> Int {
            beganCount
        }

        func receiptCount() -> Int {
            receiptOutcomes.count
        }

        func outcomes() -> [String] {
            receiptOutcomes
        }

        func holdBegin() {
            shouldHoldBegin = true
        }

        func beginIsHeld() -> Bool {
            beginContinuation != nil
        }

        func releaseBegin() {
            beginContinuation?.resume()
            beginContinuation = nil
            shouldHoldBegin = false
        }

        func pause() {
            paused = true
        }

        func failSync() {
            failed = true
        }

        func loseBeginResponse() {
            losesBegin = true
        }
    }
}
