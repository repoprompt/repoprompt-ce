@testable import RepoPromptApp
import XCTest

final class SwitchboardBridgeClientTests: XCTestCase {
    func testCancelledPollRevokesExactBindingOnlyOnce() async throws {
        for explicitRevoke in [false, true] {
            let server = StubBridge()
            let scope = SwitchboardBridgeTestData.scope()
            let client = try makeClient(server: server, scope: scope)
            try await client.register(threadID: scope.threadID)
            let gate = ExchangeGate()
            await server.setGate(gate, operation: "poll")
            let polling = Task { try await client.poll(lastSeenRevision: 0) }
            await gate.waitUntilEntered()
            if explicitRevoke { await client.revoke() }
            polling.cancel()
            await gate.release()
            await assertError(explicitRevoke ? .revoked : .unavailable) { _ = try await polling.value }
            let requests = await server.requests
            let revocations = requests.filter { $0["op"] == .string("revoke") }
            XCTAssertEqual(revocations.count, 1)
            XCTAssertEqual(revocations.first?["thread_id"], scope.threadID.map(SwitchboardJSONValue.string))
            XCTAssertEqual(revocations.first?["consent_id"], .string(scope.consentID.uuidString.lowercased()))
            XCTAssertEqual(revocations.first?["session_id"], .string(scope.sessionID.uuidString.lowercased()))
            XCTAssertEqual(revocations.first?["controller_generation"], .string(scope.controllerGeneration.uuidString.lowercased()))
            await client.revoke()
            await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
        }
    }

    func testTerminalOperationFailuresRevokeButRecoverableErrorsKeepConsent() async throws {
        for operation in ["poll", "refresh", "status"] {
            for failure in ["transport", "malformed", "stale", "unavailable_grant"] {
                let server = StubBridge()
                let client = try makeClient(server: server)
                try await client.register(threadID: "original-thread")
                let previous = try SwitchboardBridgeWire.selection(.object(
                    SwitchboardBridgeWire.decodeFrame(SwitchboardBridgeWire.encodeFrame(SwitchboardBridgeTestData.selection()))
                ), now: SwitchboardBridgeTestData.now)
                let expected: SwitchboardBridgeError
                switch failure {
                case "transport": expected = .unavailable
                    await server.setError(SyntheticError.secret("synthetic-secret"))
                case "malformed": expected = .invalidRequest
                    await server.setMalformedOperation(operation)
                case "stale": expected = .staleRevision
                    await server.setError(expected)
                default: expected = .grantUnavailable
                    await server.setError(expected)
                }
                await assertError(expected) {
                    switch operation {
                    case "poll": _ = try await client.poll(lastSeenRevision: 0)
                    case "refresh": _ = try await client.refresh(previousGrant: previous)
                    default: try await client.status(adoptionID: previous.adoptionID, expectedRevision: 1, state: "applying", reason: "none")
                    }
                }
                let requests = await server.requests
                let terminal = failure == "transport" || failure == "malformed"
                XCTAssertEqual(requests.count(where: { $0["op"] == .string("revoke") }), terminal ? 1 : 0)
                await server.setError(nil)
                await server.setMalformedOperation("")
                await server.setSelection(nil)
                if terminal {
                    await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
                } else {
                    let selection = try await client.poll(lastSeenRevision: 0)
                    XCTAssertNil(selection)
                }
            }
        }
    }

    func testCancelledRegistrationRevokesExactAttemptedBinding() async throws {
        for variant in 0 ..< 3 {
            let server = StubBridge()
            let scope = SwitchboardBridgeTestData.scope(threadID: nil)
            let client = try makeClient(server: server, scope: scope)
            if variant == 2 { try await client.register(threadID: nil) }
            let gate = ExchangeGate()
            await server.setGate(gate, operation: "register")
            let nativeID: String? = variant == 0 ? nil : "cancelled-native-thread"
            let registration = Task { try await client.register(threadID: nativeID) }
            await gate.waitUntilEntered()
            registration.cancel()
            await gate.release()
            await assertError(.unavailable) { try await registration.value }
            let requests = await server.requests
            XCTAssertEqual(requests.count, variant == 2 ? 3 : 2)
            XCTAssertEqual(requests.last?["op"], .string("revoke"))
            XCTAssertEqual(requests.last?["thread_id"], nativeID.map(SwitchboardJSONValue.string) ?? .null)
            XCTAssertEqual(requests.last?["controller_generation"], .string(scope.controllerGeneration.uuidString.lowercased()))
            await client.revoke()
            await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
        }
    }

    func testExpiredRegistrationReplyRevokesExactAttemptedBinding() async throws {
        for nativeID: String? in [nil, "expired-native-thread"] {
            let clock = TestClock()
            let server = StubBridge()
            let gate = ExchangeGate()
            await server.setGate(gate, operation: "register")
            let client = try makeClient(server: server, scope: SwitchboardBridgeTestData.scope(threadID: nil), now: { clock.now })
            let registration = Task { try await client.register(threadID: nativeID) }
            await gate.waitUntilEntered()
            clock.advance(to: 1200)
            await gate.release()
            await assertError(.expired) { try await registration.value }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?["op"], .string("revoke"))
            XCTAssertEqual(requests.last?["thread_id"], nativeID.map(SwitchboardJSONValue.string) ?? .null)
            await client.revoke()
            await assertError(.revoked) { try await client.register(threadID: nativeID) }
        }
    }

    func testNativeBindingAfterInitialDeadlinePreservesEstablishedConsent() async throws {
        let clock = TestClock()
        let server = StubBridge()
        let client = try makeClient(server: server, scope: SwitchboardBridgeTestData.scope(threadID: nil), now: { clock.now })
        try await client.register(threadID: nil)
        clock.advance(to: 1500)
        try await client.register(threadID: "bound-after-deadline")
        let grant = try await client.poll(lastSeenRevision: 0)
        XCTAssertEqual(grant?.accountID, "synthetic-account-b")
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0["op"] == .string("revoke") })
    }

    func testMalformedRegistrationAcknowledgmentRevokesAttemptedBinding() async throws {
        for result: [String: Any] in [["registered": false], ["registered": true, "unexpected": true]] {
            let server = StubBridge()
            await server.setRegistrationResult(result)
            let client = try makeClient(server: server)
            await assertError(.invalidRequest) { try await client.register(threadID: "original-thread") }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?["op"], .string("revoke"))
            XCTAssertEqual(requests.last?["thread_id"], .string("original-thread"))
            await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
        }
    }

    func testRevocationDuringRegistrationCleansUpExactLateBinding() async throws {
        for variant in 0 ..< 3 {
            let server = StubBridge()
            let scope = SwitchboardBridgeTestData.scope(threadID: nil)
            let client = try makeClient(server: server, scope: scope)
            if variant == 2 { try await client.register(threadID: nil) }
            let gate = ExchangeGate()
            await server.setGate(gate, operation: "register")
            let nativeID: String? = variant == 0 ? nil : "late-bound-thread"
            let registration = Task { try await client.register(threadID: nativeID) }
            await gate.waitUntilEntered()
            await client.revoke()
            await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
            await gate.release()
            await assertError(.revoked) { try await registration.value }
            let requests = await server.requests
            XCTAssertEqual(requests.count, variant == 2 ? 4 : 2)
            XCTAssertEqual(requests.last?["op"], .string("revoke"))
            XCTAssertEqual(requests.last?["thread_id"], nativeID.map(SwitchboardJSONValue.string) ?? .null)
            XCTAssertEqual(requests.last?["controller_generation"], .string(scope.controllerGeneration.uuidString.lowercased()))
        }
    }

    func testRevokingRegisteredNullThreadNotifiesBridgeWithoutBindingThread() async throws {
        let server = StubBridge()
        let scope = SwitchboardBridgeTestData.scope(threadID: nil)
        let client = try makeClient(server: server, scope: scope)
        try await client.register(threadID: nil)
        await client.revoke()
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?["op"], .string("revoke"))
        XCTAssertEqual(requests.last?["thread_id"], .null)
        XCTAssertEqual(requests.last?["consent_id"], .string(scope.consentID.uuidString.lowercased()))
        await assertError(.revoked) { try await client.register(threadID: "must-not-bind") }
    }

    func testRegisterNullThenExactNativeBindAndEveryRequestPinsScope() async throws {
        let server = StubBridge()
        let scope = SwitchboardBridgeTestData.scope(threadID: nil)
        let client = try makeClient(server: server, scope: scope)
        try await client.register(threadID: nil)
        await assertError(.identityMismatch) { _ = try await client.poll(lastSeenRevision: 0) }
        try await client.register(threadID: "original-thread")
        let grant = try await client.poll(lastSeenRevision: 0)
        XCTAssertEqual(grant?.accountID, "synthetic-account-b")
        await assertError(.identityMismatch) { try await client.register(threadID: "different-thread") }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0]["thread_id"], .null)
        XCTAssertEqual(requests[1]["thread_id"], .string("original-thread"))
        var ids: Set<UUID> = []
        for request in requests {
            XCTAssertEqual(try request.uuid("consent_id"), scope.consentID)
            XCTAssertEqual(try request.uuid("session_id"), scope.sessionID)
            XCTAssertEqual(try request.uuid("controller_generation"), scope.controllerGeneration)
            try ids.insert(request.uuid("id"))
        }
        XCTAssertEqual(ids.count, requests.count)
        XCTAssertTrue(Mirror(reflecting: client).children.isEmpty)
    }

    func testRegistrationExpiryDoesNotExpireEstablishedConsent() async throws {
        let clock = TestClock()
        let server = StubBridge()
        let client = try makeClient(server: server, now: { clock.now })
        try await client.register(threadID: "original-thread")
        clock.advance(to: 1500)
        let grant = try await client.poll(lastSeenRevision: 0)
        XCTAssertEqual(grant?.revision, 1)

        let expired = try makeClient(server: server, now: { clock.now })
        await assertError(.expired) { try await expired.register(threadID: "original-thread") }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLateInitialRegistrationAndRevocationDuringExchangeFailClosed() async throws {
        let clock = TestClock()
        let server = StubBridge()
        let gate = ExchangeGate()
        await server.setGate(gate, operation: "register")
        let client = try makeClient(server: server, now: { clock.now })
        let registration = Task { try await client.register(threadID: "original-thread") }
        await gate.waitUntilEntered()
        clock.advance(to: 1200)
        await gate.release()
        await assertError(.expired) { try await registration.value }

        let secondServer = StubBridge()
        let second = try makeClient(server: secondServer)
        try await second.register(threadID: "original-thread")
        let pollGate = ExchangeGate()
        await secondServer.setGate(pollGate, operation: "poll")
        let polling = Task { try await second.poll(lastSeenRevision: 0) }
        await pollGate.waitUntilEntered()
        await second.revoke()
        await pollGate.release()
        await assertError(.revoked) { _ = try await polling.value }
        await assertError(.revoked) { _ = try await second.poll(lastSeenRevision: 0) }
    }

    func testNoopRevisionReplayAndInvalidSelectionNeverReleaseGrant() async throws {
        let server = StubBridge()
        let client = try makeClient(server: server)
        try await client.register(threadID: "original-thread")
        _ = try await client.poll(lastSeenRevision: 0)
        await assertError(.staleRevision) { _ = try await client.poll(lastSeenRevision: 0) }
        await server.setSelection(nil)
        let noSelection = try await client.poll(lastSeenRevision: 1)
        XCTAssertNil(noSelection)
        for fields: [String: Any] in [
            ["selection_revision": true], ["selection_revision": 0],
            ["expires_at": 999], ["access_token": "bad token"],
            ["account_id": " account-b"], ["selection_id": "INVALID"],
            ["unexpected": "value"]
        ] {
            // Every malformed case reaches decoding even if an earlier one
            // terminally invalidated its own consent.
            let malformedServer = StubBridge()
            let malformedClient = try makeClient(server: malformedServer)
            try await malformedClient.register(threadID: "original-thread")
            await malformedServer.setSelection(SwitchboardBridgeTestData.selection(revision: 2).merging(fields) { _, value in value })
            do {
                _ = try await malformedClient.poll(lastSeenRevision: 1)
                XCTFail("Malformed selection was released")
            } catch {
                XCTAssertNotEqual(error as? SwitchboardBridgeError, .revoked)
            }
        }
    }

    func testRefreshPinsAppliedGrantDespiteNewerPollAndRejectsIdentityChanges() async throws {
        let server = StubBridge()
        let client = try makeClient(server: server)
        try await client.register(threadID: "original-thread")
        let polled = try await client.poll(lastSeenRevision: 0)
        let previous = try XCTUnwrap(polled)
        await server.setSelection(SwitchboardBridgeTestData.selection(revision: 2, token: "synthetic-newer-token"))
        _ = try await client.poll(lastSeenRevision: 1)
        await server.setSelection(SwitchboardBridgeTestData.selection(token: "synthetic-renewed-token"))
        let renewed = try await client.refresh(previousGrant: previous)
        XCTAssertEqual(renewed.revision, 1)
        XCTAssertEqual(renewed.accountID, previous.accountID)
        let refresh = await server.requests.last
        XCTAssertEqual(refresh?["expected_revision"], .integer(1))
        XCTAssertEqual(refresh?["previous_account_id"], .string(previous.accountID))
        for fields: [String: Any] in [
            ["account_id": "other-account"], ["selection_revision": 2],
            ["selection_id": UUID().uuidString.lowercased()],
            ["adoption_id": UUID().uuidString.lowercased()],
            ["email": "different@example.invalid"], ["access_token": previous.accessToken]
        ] {
            await server.setSelection(SwitchboardBridgeTestData.selection(token: "synthetic-renewed-token").merging(fields) { _, value in value })
            await assertError(.identityMismatch) { _ = try await client.refresh(previousGrant: previous) }
        }
    }

    func testPeerLossAndSecretBearingTransportErrorsInvalidateCapability() async throws {
        for error in [SwitchboardBridgeError.unauthorized as Error, SyntheticError.secret("synthetic-secret")] {
            let server = StubBridge()
            let client = try makeClient(server: server)
            try await client.register(threadID: "original-thread")
            await server.setError(error)
            do {
                _ = try await client.poll(lastSeenRevision: 0)
                XCTFail("Transport failure released a grant")
            } catch {
                XCTAssertFalse(String(reflecting: error).contains("synthetic-secret"))
            }
            await server.setError(nil)
            await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 0) }
        }
    }

    func testStatusAllowsOnlyProtocolStatesAndRevisionScopedAcknowledgment() async throws {
        let server = StubBridge()
        let client = try makeClient(server: server)
        try await client.register(threadID: "original-thread")
        let adoptionID = UUID()
        await assertError(.invalidRequest) {
            try await client.status(adoptionID: adoptionID, expectedRevision: 1, state: "runtime_verified", reason: "none")
        }
        try await client.status(adoptionID: adoptionID, expectedRevision: 1, state: "applied_unverified", reason: "none")
        await server.setError(SwitchboardBridgeError.staleRevision)
        await assertError(.staleRevision) {
            try await client.status(adoptionID: adoptionID, expectedRevision: 1, state: "applied_unverified", reason: "none")
        }
    }

    private func makeClient(
        server: StubBridge,
        scope: SwitchboardBridgeScope = SwitchboardBridgeTestData.scope(),
        now: @escaping @Sendable () -> Date = { SwitchboardBridgeTestData.now }
    ) throws -> SwitchboardBridgeClient {
        try SwitchboardBridgeClient(pairing: SwitchboardBridgeTestData.envelope(), scope: scope, now: now) { _, data in
            try await server.exchange(data)
        }
    }

    private func assertError(_ expected: SwitchboardBridgeError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected stable bridge refusal")
        } catch {
            XCTAssertEqual(error as? SwitchboardBridgeError, expected)
        }
    }

    private enum SyntheticError: Error { case secret(String) }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = SwitchboardBridgeTestData.now
        var now: Date {
            lock.withLock { value }
        }

        func advance(to seconds: TimeInterval) {
            lock.withLock { value = Date(timeIntervalSince1970: seconds) }
        }
    }

    private actor ExchangeGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func suspend() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private actor StubBridge {
        var requests: [[String: SwitchboardJSONValue]] = []
        private var registrationResult: [String: Any] = ["registered": true]
        private var selection: [String: Any]? = SwitchboardBridgeTestData.selection()
        private var error: Error?
        private var gate: ExchangeGate?
        private var gatedOperation = ""
        private var malformedOperation = ""

        func setMalformedOperation(_ value: String) {
            malformedOperation = value
        }

        func setSelection(_ value: [String: Any]?) {
            selection = value
        }

        func setRegistrationResult(_ value: [String: Any]) {
            registrationResult = value
        }

        func setError(_ value: Error?) {
            error = value
        }

        func setGate(_ value: ExchangeGate, operation: String) {
            gate = value
            gatedOperation = operation
        }

        func exchange(_ data: Data) async throws -> Data {
            let request = try SwitchboardBridgeWire.decodeFrame(data)
            requests.append(request)
            let op = try request.text("op")
            if op == gatedOperation { await gate?.suspend() }
            if let error { throw error }
            if op == malformedOperation {
                return try SwitchboardBridgeWire.encodeFrame(["v": 1, "id": request.text("id"), "result": ["unexpected": true]])
            }
            let result: [String: Any]
            switch op {
            case "register": result = registrationResult
            case "poll", "refresh": result = ["selection": selection.map { $0 as Any } ?? NSNull()]
            case "status": result = ["accepted": true]
            case "revoke": result = ["revoked": true]
            default: throw SwitchboardBridgeError.invalidRequest
            }
            return try SwitchboardBridgeWire.encodeFrame(["v": 1, "id": request.text("id"), "result": result])
        }
    }
}
