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

// MARK: - Approval option labels

/// Covers the approval-card option labelling that `ACPAgentSessionController` applies to
/// agent-authored permission options.
///
/// These strings arrive from the agent and are joined with a newline to build the card's
/// option list, so anything that survives with a newline in it presents one option as two.
/// The suite exists because the surrounding permission tests all exercise option *selection*;
/// none of them reach the presentation path.
final class ACPApprovalOptionLabelTests: XCTestCase {
    private func label(_ raw: String) -> String? {
        ACPAgentSessionController.test_displayableOptionLabel(raw)
    }

    func testCollapsesNewlinesSoOneOptionCannotPresentAsTwo() {
        XCTAssertEqual(label("Allow\nDeny"), "Allow Deny")
        XCTAssertEqual(label("Allow\r\nonce"), "Allow once")
        XCTAssertEqual(label("Allow\u{2028}once"), "Allow once")
        for rendered in [label("Allow\nDeny"), label("Allow\r\nonce")] {
            let carriesSeparator = rendered?.unicodeScalars
                .contains { CharacterSet.newlines.contains($0) } ?? true
            XCTAssertFalse(
                carriesSeparator,
                "A label must never carry the separator used to join options."
            )
        }
    }

    func testTreatsValuesWithNothingVisibleAsAbsent() {
        XCTAssertNil(label(""))
        XCTAssertNil(label("   "))
        XCTAssertNil(label("\n\n"))
        XCTAssertNil(label("\u{200C}\u{200D}\u{2060}\u{202E}"))
    }

    /// Emptiness is tested by looking for a visible scalar rather than by trimming invisible
    /// ones: the subdivision flags end in a run of format characters, and trimming those
    /// truncates the flag to a plain black flag.
    func testPreservesLabelsEndingInFormatCharacters() {
        let england = "Allow \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertEqual(label(england), england)
    }

    func testPreservesOrdinaryAgentWording() {
        XCTAssertEqual(label("Allow for this session"), "Allow for this session")
        XCTAssertEqual(label("  Allow once  "), "Allow once")
        XCTAssertEqual(label("👨‍👩‍👧‍👦 Allow"), "👨‍👩‍👧‍👦 Allow")
        XCTAssertEqual(label("مرحبا"), "مرحبا")
    }

    // MARK: - Composition

    /// The sanitiser is only half the guarantee: the identifier fallback has to run through
    /// it too. Routing the name alone left the identifier able to reintroduce the newline.
    func testIdentifierFallbackIsSanitisedNotPassedThrough() {
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow\nalways"),
            "allow always"
        )
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "   ", optionID: "allow\nonce"),
            "allow once"
        )
        // A non-ASCII separator too, so the identifier path is bound to the shared
        // sanitiser rather than to any handling that only knows about "\n".
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow\u{2028}once"),
            "allow once"
        )
    }

    func testPrefersTheAgentWordingOverTheIdentifier() {
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "Allow once", optionID: "allow_once"),
            "Allow once"
        )
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow_once"),
            "allow_once"
        )
    }

    func testYieldsAnEmptyLineWhenNothingIsDisplayable() {
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "\u{200C}", optionID: "  "),
            ""
        )
    }
}
