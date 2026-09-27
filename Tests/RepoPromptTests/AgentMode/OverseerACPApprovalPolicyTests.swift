import Foundation
@testable import RepoPromptApp
import XCTest

final class OverseerACPApprovalPolicyTests: XCTestCase {
    func testSelectsOnlyOneTimeAllowWhenBroaderOptionsComeFirst() {
        let options = [
            (optionID: "allow_always", kind: "allow_always"),
            (optionID: "allow-edits-session", kind: "allow_once"),
            (optionID: "allow-once", kind: "allow_once")
        ]
        XCTAssertEqual(
            ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(options: options, providerID: .grokBuild),
            "allow-once"
        )
    }

    func testMislabelledOrAbsentOneTimeAllowLeavesPromptManual() {
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [
                (optionID: "enable-always-approve", kind: "allow_once"),
                (optionID: "allow-edits-session", kind: "allow_once")
            ],
            providerID: .grokBuild
        ))
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "always", kind: "allow_always")],
            providerID: .cursor
        ))
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "reject-once", kind: "reject_once")],
            providerID: .openCode
        ))
    }

    /// An observer's explicit decline must never become a persistent reject.
    func testObserverDeclineSelectsOnlyAOneTimeRejectAndOtherwiseFallsBackToCancelled() {
        XCTAssertEqual(ACPPermissionOptionPolicy.overseerOneTimeRejectOptionID(options: [
            (optionID: "reject_always", kind: "reject_always"),
            (optionID: "reject-once", kind: "reject_once")
        ]), "reject-once")
        XCTAssertEqual(ACPPermissionOptionPolicy.overseerOneTimeRejectOptionID(options: [
            (optionID: "deny", kind: "")
        ]), "deny")
        // Only persistent or mislabelled rejects: nil, so the caller reports `cancelled` instead.
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeRejectOptionID(options: [
            (optionID: "reject_always", kind: "reject_always"),
            (optionID: "reject-always", kind: "reject_once"),
            (optionID: "reject-session", kind: "reject")
        ]))
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeRejectOptionID(options: [
            (optionID: "allow-once", kind: "allow_once")
        ]))
    }

    func testProviderSpecificOptionCanUseAllowOnceKindWithoutBroadeningID() {
        XCTAssertEqual(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "approve", kind: "allow_once")],
            providerID: .openCode
        ), "approve")
    }
}
