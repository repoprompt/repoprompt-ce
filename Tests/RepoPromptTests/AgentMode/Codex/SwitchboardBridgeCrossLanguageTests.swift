import Darwin
@testable import RepoPromptApp
import XCTest

/// Opt-in companion-repository acceptance. Production Swift client and Python
/// server communicate over a real private socket; only the grant source is fake.
final class SwitchboardBridgeCrossLanguageTests: XCTestCase {
    func testActualServerRevokesCancelledRegistrationAndNativeBind() async throws {
        for variant in 0 ..< 3 {
            let fixture = try PythonFixture(fault: variant == 2 ? "hold_native_bind" : "hold_register")
            defer { fixture.finish() }
            let client = try SwitchboardBridgeClient(pairing: fixture.pairing(), scope: SwitchboardBridgeTestData.scope(threadID: nil))
            if variant == 2 { try await client.register(threadID: nil) }
            let nativeID: String? = variant == 0 ? nil : "cancelled-native-thread"
            let registration = Task { try await client.register(threadID: nativeID) }
            XCTAssertEqual(try fixture.command("wait_registration")["bound"] as? Bool, true)
            registration.cancel()
            XCTAssertEqual(try fixture.command("release_registration")["released"] as? Bool, true)
            await assertError(.unavailable) { try await registration.value }
            let receipt = try fixture.command("status")
            XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "revoked")
            XCTAssertEqual(try fixture.status(receipt)["switchable"] as? Bool, false)
            XCTAssertEqual(receipt["redacted"] as? Bool, true)
            XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 0)
            await client.revoke()
        }
    }

    func testActualServerRevokesRegistrationReplyPastInitialDeadline() async throws {
        for nativeID: String? in [nil, "expired-native-thread"] {
            let fixture = try PythonFixture(fault: "hold_register")
            defer { fixture.finish() }
            let pairing = try fixture.pairing()
            let clock = RegistrationClock()
            let client = SwitchboardBridgeClient(pairing: pairing, scope: SwitchboardBridgeTestData.scope(threadID: nil), now: { clock.now })
            let registration = Task { try await client.register(threadID: nativeID) }
            XCTAssertEqual(try fixture.command("wait_registration")["bound"] as? Bool, true)
            clock.advance(to: pairing.expiresAt)
            XCTAssertEqual(try fixture.command("release_registration")["released"] as? Bool, true)
            await assertError(.expired) { try await registration.value }
            let receipt = try fixture.command("status")
            XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "revoked")
            XCTAssertEqual(try fixture.status(receipt)["switchable"] as? Bool, false)
            XCTAssertEqual(receipt["redacted"] as? Bool, true)
            XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 0)
            await client.revoke()
        }
    }

    func testActualPythonServerPreservesAppliedRefreshWhileNewerAccountWaits() async throws {
        let fixture = try PythonFixture()
        defer { fixture.finish() }
        let pairing = try fixture.pairing()
        let scope = SwitchboardBridgeScope(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: nil)
        let client = SwitchboardBridgeClient(pairing: pairing, scope: scope)
        let thread = "synthetic/native-thread:alpha"
        try await client.register(threadID: nil)
        XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 0)
        var receipt = try fixture.command("status")
        XCTAssertEqual((receipt["provider_calls"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try fixture.status(receipt)["switchable"] as? Bool, false)
        try await client.register(threadID: thread)

        XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 1)
        let firstResult = try await client.poll(lastSeenRevision: 0)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.accountID, "synthetic-cross-account-a")
        XCTAssertEqual(first.revision, 1)
        try await client.status(adoptionID: first.adoptionID, expectedRevision: 1, state: "applying", reason: "none")
        try await client.status(adoptionID: first.adoptionID, expectedRevision: 1, state: "applied_unverified", reason: "none")
        receipt = try fixture.command("status")
        XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "applied_unverified")
        XCTAssertEqual(try fixture.status(receipt)["runtime_verified"] as? Bool, false)
        let replay = try await client.poll(lastSeenRevision: 1)
        XCTAssertNil(replay)

        XCTAssertEqual(try fixture.command("queue_b")["queued"] as? Int, 1)
        let secondResult = try await client.poll(lastSeenRevision: 1)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.accountID, "synthetic-cross-account-b")
        XCTAssertEqual(second.revision, 2)
        try await client.status(adoptionID: second.adoptionID, expectedRevision: 2, state: "waiting_idle", reason: "busy")
        XCTAssertEqual(try fixture.command("renew_a")["renewed"] as? Bool, true)
        let renewed = try await client.refresh(previousGrant: first)
        XCTAssertEqual(renewed.accountID, first.accountID)
        XCTAssertEqual(renewed.revision, first.revision)
        XCTAssertEqual(renewed.selectionID, first.selectionID)
        XCTAssertEqual(renewed.adoptionID, first.adoptionID)
        XCTAssertTrue(renewed.accessToken != first.accessToken)
        XCTAssertFalse(String(reflecting: renewed).contains(renewed.accessToken))
        XCTAssertTrue(Mirror(reflecting: renewed).children.isEmpty)
        receipt = try fixture.command("status")
        let binding = try XCTUnwrap((receipt["bindings"] as? [[String: Any]])?.first)
        XCTAssertEqual(binding["thread"] as? String, thread)
        XCTAssertEqual(binding["controller"] as? String, scope.controllerGeneration.uuidString.lowercased())
        XCTAssertEqual(binding["applied_revision"] as? Int, 1)
        let refreshCalls = (receipt["provider_calls"] as? [[String: Any]])?.filter { $0["refresh"] as? Bool == true }
        XCTAssertEqual(refreshCalls?.last?["account"] as? String, "a@example.invalid")
        XCTAssertEqual(refreshCalls?.last?["previous_account"] as? String, first.accountID)

        await assertError(.staleRevision) {
            try await client.status(adoptionID: first.adoptionID, expectedRevision: 1, state: "failed_unknown", reason: "mutation_unconfirmed")
        }
        receipt = try fixture.command("status")
        XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "waiting_idle")
        XCTAssertEqual(try fixture.status(receipt)["selection_revision"] as? Int, 2)
        await assertError(.grantUnavailable) { _ = try await client.refresh(previousGrant: renewed) }

        // The capability cannot be rebound to another consent/controller.
        let foreign = SwitchboardBridgeClient(pairing: pairing, scope: SwitchboardBridgeTestData.scope(threadID: nil))
        await assertError(.unauthorized) { try await foreign.register(threadID: "different-thread") }
        XCTAssertEqual(try fixture.command("revoke")["revoked"] as? Bool, true)
        await assertError(.revoked) { _ = try await client.poll(lastSeenRevision: 2) }
        await assertError(.revoked) { _ = try await client.refresh(previousGrant: renewed) }
        receipt = try fixture.command("status")
        XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "revoked")
        XCTAssertEqual(receipt["logs_empty"] as? Bool, true)
        XCTAssertEqual(receipt["redacted"] as? Bool, true)
        let denied = try XCTUnwrap(receipt["denied_operations"] as? [String: Int])
        XCTAssertEqual(denied, ["network": 0, "subprocess": 0, "credential_file": 0])
        XCTAssertTrue(Mirror(reflecting: pairing).children.isEmpty)
        XCTAssertFalse(String(reflecting: pairing).contains(pairing.capability))
    }

    func testActualPythonServerRevokesRegisteredNullThread() async throws {
        let fixture = try PythonFixture()
        defer { fixture.finish() }
        let client = try SwitchboardBridgeClient(pairing: fixture.pairing(), scope: SwitchboardBridgeTestData.scope(threadID: nil))
        try await client.register(threadID: nil)
        await client.revoke()
        let receipt = try fixture.command("status")
        XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "revoked")
        XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 0)
        XCTAssertEqual(receipt["redacted"] as? Bool, true)
        await assertError(.revoked) { try await client.register(threadID: "must-not-bind") }
    }

    func testActualServerRevokesBindingCompletedDuringFirstRegistrationAwait() async throws {
        for nativeID: String? in [nil, "late-native-thread"] {
            let fixture = try PythonFixture(fault: "hold_register")
            defer { fixture.finish() }
            let client = try SwitchboardBridgeClient(pairing: fixture.pairing(), scope: SwitchboardBridgeTestData.scope(threadID: nil))
            let registration = Task { try await client.register(threadID: nativeID) }
            XCTAssertEqual(try fixture.command("wait_registration")["bound"] as? Bool, true)
            await client.revoke()
            XCTAssertEqual(try fixture.command("release_registration")["released"] as? Bool, true)
            await assertError(.revoked) { try await registration.value }
            let receipt = try fixture.command("status")
            XCTAssertEqual(try fixture.status(receipt)["state"] as? String, "revoked")
            XCTAssertEqual(receipt["redacted"] as? Bool, true)
            XCTAssertEqual((receipt["provider_calls"] as? [[String: Any]])?.count, 0)
        }
    }

    private func assertError(
        _ expected: SwitchboardBridgeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected stable cross-language refusal", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SwitchboardBridgeError, expected, file: file, line: line)
        }
    }

    private final class RegistrationClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var now: Date {
            lock.withLock { value }
        }

        func advance(to date: Date) {
            lock.withLock { value = date }
        }
    }

    private final class PythonFixture {
        private enum Failure: Error { case fixtureUnavailable }
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let errors = Pipe()
        private let exited = DispatchSemaphore(value: 0)
        private let directory: URL
        private var ready: [String: Any] = [:]
        private var stopped = false

        init(fault: String? = nil) throws {
            let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let repository = testDirectory.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let configuration = repository.appendingPathComponent(".build/validation-artifacts/switchboard-cross-language/config.json")
            guard FileManager.default.fileExists(atPath: configuration.path) else {
                throw XCTSkip("Configure the pinned companion bridge module in .build/validation-artifacts/switchboard-cross-language/config.json for this acceptance lane.")
            }
            guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: String],
                  Set(config.keys) == ["source", "fault"], let source = config["source"], !source.isEmpty
            else { throw Failure.fixtureUnavailable }
            directory = URL(fileURLWithPath: "/private/tmp/sb-cross-" + UUID().uuidString.prefix(12))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = testDirectory.appendingPathComponent("Fixtures/switchboard_cross_language_fixture.py")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-I",
                "-B",
                script.path,
                source,
                String(getpid()),
                directory.path,
                fault ?? config["fault"] ?? "none"
            ]
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
            process.currentDirectoryURL = directory
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { [exited] _ in exited.signal() }
            do {
                try process.run()
                try output.fileHandleForWriting.close()
                try errors.fileHandleForWriting.close()
                try input.fileHandleForReading.close()
                ready = try readReply()
                guard ready["source_pinned"] as? Bool == true else { throw Failure.fixtureUnavailable }
            } catch {
                finish()
                throw Failure.fixtureUnavailable
            }
        }

        func pairing() throws -> SwitchboardPairingEnvelope {
            guard let object = ready["envelope"] as? [String: Any] else { throw Failure.fixtureUnavailable }
            return try SwitchboardPairingEnvelope.parse(JSONSerialization.data(withJSONObject: object))
        }

        func command(_ op: String) throws -> [String: Any] {
            do {
                var data = try JSONSerialization.data(withJSONObject: ["op": op])
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
                return try readReply()
            } catch {
                throw Failure.fixtureUnavailable
            }
        }

        func status(_ receipt: [String: Any]) throws -> [String: Any] {
            guard let rows = receipt["status"] as? [[String: Any]], rows.count == 1 else {
                throw Failure.fixtureUnavailable
            }
            return rows[0]
        }

        private func readReply() throws -> [String: Any] {
            let descriptor = output.fileHandleForReading.fileDescriptor
            let deadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
            var bytes = Data()
            while bytes.count < 65536 {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw Failure.fixtureUnavailable }
                var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let remaining = Int32((deadline - now + 999_999) / 1_000_000)
                guard Darwin.poll(&pollFD, 1, remaining) > 0 else { throw Failure.fixtureUnavailable }
                var byte: UInt8 = 0
                guard Darwin.read(descriptor, &byte, 1) == 1 else { throw Failure.fixtureUnavailable }
                if byte == 0x0A {
                    guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          value["error"] == nil else { throw Failure.fixtureUnavailable }
                    return value
                }
                bytes.append(byte)
            }
            throw Failure.fixtureUnavailable
        }

        func finish() {
            guard !stopped else { return }
            stopped = true
            if process.isRunning { _ = try? command("stop") }
            if process.processIdentifier > 0, exited.wait(timeout: .now() + 2) != .success {
                if process.isRunning { process.terminate() }
                XCTAssertEqual(exited.wait(timeout: .now() + 2), .success, "Owned synthetic fixture did not stop")
            }
            if !process.isRunning, process.processIdentifier > 0 {
                XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty, "Fixture emitted unexpected stderr")
            }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
