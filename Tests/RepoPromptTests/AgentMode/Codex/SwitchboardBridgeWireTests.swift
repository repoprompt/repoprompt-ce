import Darwin
@testable import RepoPromptApp
import XCTest

final class SwitchboardBridgeWireTests: XCTestCase {
    func testAcceptsOneBoundedObjectFrame() throws {
        try SwitchboardBridgeWire.validateFrame(Data("{\"v\":1,\"nested\":{\"ok\":true,\"optional\":null}}\n".utf8))
    }

    func testRejectsDuplicateDecodedKeysAtEveryDepth() {
        for body in [
            #"{"v":1,"v":2}"#,
            #"{"v":1,"\u0076":2}"#,
            #"{"result":{"token":"first","token":"second"}}"#
        ] {
            XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data((body + "\n").utf8)))
        }
    }

    func testRequiresFinalLFAndRejectsTrailingFramesOrWhitespace() {
        for body in ["{}", "{}\n ", "{}\n{}\n", "{}\r\n", "{}\n\n"] {
            XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data(body.utf8)))
        }
    }

    func testRejectsNonIntegerNumbersArraysAndExcessNesting() {
        for body in [
            #"{"n":1.0}"#, #"{"n":1e0}"#, #"{"n":9007199254740992}"#,
            #"{"n":NaN}"#, #"{"n":Infinity}"#, "[]", "{\"a\":[]}",
            String(repeating: "{\"a\":", count: 20) + "null" + String(repeating: "}", count: 20)
        ] {
            XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data((body + "\n").utf8)))
        }
    }

    func testRejectsInvalidUTF8AndOversizedFrames() {
        XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D, 0x0A])))
        let oversized = "{\"x\":\"" + String(repeating: "x", count: 65536) + "\"}\n"
        XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data(oversized.utf8)))
    }

    func testExactFrameSizeBoundary() throws {
        let overhead = Data("{\"x\":\"\"}\n".utf8).count
        let exact = "{\"x\":\"" + String(repeating: "x", count: 65536 - overhead) + "\"}\n"
        try SwitchboardBridgeWire.validateFrame(Data(exact.utf8))
        XCTAssertThrowsError(try SwitchboardBridgeWire.validateFrame(Data((" " + exact).utf8)))
    }

    func testPairingRejectsNoncanonicalBase64BooleanIntegerAndUnknownFields() throws {
        let valid = try SwitchboardBridgeTestData.envelope()
        XCTAssertEqual(valid.peerPID, getpid())
        for mutation: [String: Any] in [
            ["capability": " " + SwitchboardBridgeTestData.capability],
            ["capability": String(SwitchboardBridgeTestData.capability.dropLast())],
            ["peer_pid": true], ["expires_at": 1100.5],
            ["peer_start": ["seconds": 1, "microseconds": 1_000_000]],
            ["socket_path": "/private/tmp/../session.sock"],
            ["socket_path": "/private//tmp/session.sock"],
            ["extra": "not-allowed"]
        ] {
            XCTAssertThrowsError(try SwitchboardBridgeTestData.envelope(overrides: mutation))
        }
        // Non-zero unused pad bits decode to the same bytes but are not canonical.
        let noncanonical = String(SwitchboardBridgeTestData.capability.dropLast(2)) + "F="
        XCTAssertThrowsError(try SwitchboardBridgeTestData.envelope(overrides: ["capability": noncanonical]))
    }

    func testPairingExpiryWindowAndRedaction() throws {
        for expiry in [999, 1000, 1301] {
            XCTAssertThrowsError(try SwitchboardBridgeTestData.envelope(overrides: ["expires_at": expiry]))
        }
        let envelope = try SwitchboardBridgeTestData.envelope()
        XCTAssertFalse(String(describing: envelope).contains(SwitchboardBridgeTestData.capability))
        XCTAssertFalse(String(reflecting: envelope).contains(SwitchboardBridgeTestData.capability))
        XCTAssertTrue(Mirror(reflecting: envelope).children.isEmpty)
    }

    func testResponseIDScopeSchemaAndStableErrorsAreStrict() throws {
        let requestID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let valid: [String: Any] = ["v": 1, "id": requestID.uuidString.lowercased(), "result": ["registered": true]]
        _ = try SwitchboardBridgeWire.response(SwitchboardBridgeWire.encodeFrame(valid), requestID: requestID)
        for change: [String: Any] in [
            ["id": UUID().uuidString.lowercased()],
            ["id": requestID.uuidString.uppercased()],
            ["v": true],
            ["error": ["code": "revoked"]],
            ["consent_id": UUID().uuidString.lowercased()]
        ] {
            let object = valid.merging(change) { _, changed in changed }
            XCTAssertThrowsError(try SwitchboardBridgeWire.response(SwitchboardBridgeWire.encodeFrame(object), requestID: requestID))
        }
        let floating = "{\"v\":1.0,\"id\":\"\(requestID.uuidString.lowercased())\",\"result\":{}}\n"
        XCTAssertThrowsError(try SwitchboardBridgeWire.response(Data(floating.utf8), requestID: requestID))
        let secretError: [String: Any] = ["v": 1, "id": requestID.uuidString.lowercased(), "error": ["code": "unavailable", "message": "synthetic-secret"]]
        XCTAssertThrowsError(try SwitchboardBridgeWire.response(SwitchboardBridgeWire.encodeFrame(secretError), requestID: requestID)) {
            XCTAssertEqual($0 as? SwitchboardBridgeError, .invalidRequest)
            XCTAssertFalse(String(reflecting: $0).contains("synthetic-secret"))
        }
    }
}

enum SwitchboardBridgeTestData {
    static let capability = Data(repeating: 1, count: 32).base64EncodedString()
    static let now = Date(timeIntervalSince1970: 1000)

    static func envelope(overrides: [String: Any] = [:], now: Date = now) throws -> SwitchboardPairingEnvelope {
        let start = try SwitchboardBridgeTransport.processStart(pid: getpid())
        var object: [String: Any] = [
            "v": 1, "socket_path": "/private/tmp/synthetic-private/session.sock",
            "peer_pid": getpid(), "peer_start": ["seconds": start.seconds, "microseconds": start.microseconds],
            "capability": capability, "expires_at": 1100
        ]
        object.merge(overrides) { _, value in value }
        return try SwitchboardPairingEnvelope.parse(JSONSerialization.data(withJSONObject: object), now: now)
    }

    static func scope(threadID: String? = "original-thread") -> SwitchboardBridgeScope {
        .init(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: threadID)
    }

    static func selection(revision: Int64 = 1, token: String = "synthetic-token") -> [String: Any] {
        [
            "selection_id": "55555555-5555-5555-5555-555555555555",
            "adoption_id": "66666666-6666-6666-6666-666666666666",
            "selection_revision": revision, "expires_at": 2000,
            "account_id": "synthetic-account-b", "email": "b@example.invalid",
            "plan": "plus", "access_token": token
        ]
    }
}
