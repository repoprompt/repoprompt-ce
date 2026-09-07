@testable import RepoPromptApp
import XCTest

final class SwitchboardAutomaticWireTests: XCTestCase {
    func testPolicyDigestMatchesCanonicalPythonAndIgnoresAccountOrdering() throws {
        let actual = try SwitchboardAutomaticOffer.policyDigest(ruleID: "test-rule", accounts: ["b@example.invalid", "a@example.invalid"], trigger: 60, remaining: 50, cooldown: 1, freshness: 60)
        XCTAssertEqual(actual, "32809c1ca718b7ea4ac9c24a91d88444a465fdf0354128a3731b02ed8e57b143")
    }

    func testV2ArraysDoNotWidenManualProtocolParser() throws {
        let frame = Data("{\"values\":[1,true,null]}\n".utf8)
        XCTAssertThrowsError(try SwitchboardBridgeWire.decodeFrame(frame))
        XCTAssertNoThrow(try SwitchboardBridgeWire.decodeFrame(frame, allowsArrays: true))
        XCTAssertThrowsError(try SwitchboardBridgeWire.decodeFrame(Data("{\"a\":[{\"x\":1,\"x\":2}]}\n".utf8), allowsArrays: true))
        let oversized = "{\"a\":[" + Array(repeating: "0", count: 65).joined(separator: ",") + "]}\n"
        XCTAssertThrowsError(try SwitchboardBridgeWire.decodeFrame(Data(oversized.utf8), allowsArrays: true))
    }

    func testPausedCannotAdvertiseOutstandingCancellationIDs() throws {
        let object: SwitchboardJSONValue = .object([
            "control_epoch": .integer(1),
            "desired_paused": .bool(true),
            "effective_state": .string("paused"),
            "cancel_permit_ids": .array([.string(UUID().uuidString.lowercased())])
        ])
        XCTAssertThrowsError(try SwitchboardAutomaticControl(object))
    }

    func testCanceledIssuedPermitCanBePausingWhileGlobalDesiredIsEnabled() throws {
        // Real SB _control: a manual/rule epoch can cancel issued work without
        // globally pausing the unrelated enrolled cohort.
        let object: SwitchboardJSONValue = .object([
            "control_epoch": .integer(2),
            "desired_paused": .bool(false),
            "effective_state": .string("pausing"),
            "cancel_permit_ids": .array([.string(UUID().uuidString.lowercased())])
        ])
        XCTAssertNoThrow(try SwitchboardAutomaticControl(object))
    }

    func testEnabledCannotContradictDesiredPause() throws {
        let object: SwitchboardJSONValue = .object([
            "control_epoch": .integer(2),
            "desired_paused": .bool(true),
            "effective_state": .string("enabled"),
            "cancel_permit_ids": .array([])
        ])
        XCTAssertThrowsError(try SwitchboardAutomaticControl(object))
    }

    func testPrivateSourceFingerprintIsPinnedToTokenAndRedacted() throws {
        let original = CodexAccountAdoptionGrant(adoptionID: UUID(), selectionID: UUID(), revision: 1, expiresAt: Date().addingTimeInterval(60), accountID: "fixture-a", email: "a@example.invalid", plan: "pro", accessToken: "synthetic-a-one")
        let renewed = CodexAccountAdoptionGrant(adoptionID: original.adoptionID, selectionID: original.selectionID, revision: 1, expiresAt: original.expiresAt, accountID: original.accountID, email: original.email, plan: original.plan, accessToken: "synthetic-a-two")
        let source = SwitchboardAutomaticSource(grant: original)
        XCTAssertNotEqual(source, SwitchboardAutomaticSource(grant: renewed))
        XCTAssertFalse(String(reflecting: source).contains(source.fingerprint))
        XCTAssertEqual(Mirror(reflecting: source).children.count, 0)
        let encoded = try SwitchboardBridgeWire.decodeObject(JSONSerialization.data(withJSONObject: source.json))
        XCTAssertEqual(try SwitchboardAutomaticSource(.object(encoded)), source)
    }
}
