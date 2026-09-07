import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class SwitchboardPairingInputTests: XCTestCase {
    func testFreshManagedMarkerUsesFirstPairCopyWithoutGrantingAuthority() {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.requiresSwitchboardPairing = true
        let copy = SwitchboardSessionPairingCopy(session: session)
        XCTAssertEqual(copy.action, "Pair Switchboard…")
        XCTAssertEqual(copy.status, "New Codex session requires Switchboard pairing.")
        XCTAssertNotNil(session.switchboardDispatchBlockReason)
        XCTAssertFalse(session.allowsSwitchboardBootstrap)
        XCTAssertNil(session.switchboardAccountControl)
    }

    func testRetainedManagedNativeIdentityOrHistoryUsesRepairCopy() {
        for history in ["thread", "rollout", "transcript"] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.requiresSwitchboardPairing = true
            switch history {
            case "thread": session.codexConversationID = "synthetic-retained"
            case "rollout": session.codexRolloutPath = "/synthetic/not-read.jsonl"
            default: session.items = [AgentChatItem(timestamp: Date(), kind: .user, text: "Synthetic retained history")]
            }
            let copy = SwitchboardSessionPairingCopy(session: session)
            XCTAssertEqual(copy.action, "Re-pair Switchboard…", history)
            XCTAssertEqual(copy.status, "Retained conversation requires Switchboard re-pairing.", history)
            XCTAssertNotNil(session.switchboardDispatchBlockReason)
            session.requiresSwitchboardPairing = false
            let ordinary = SwitchboardSessionPairingCopy(session: session)
            XCTAssertEqual(ordinary.action, "Pair Switchboard…")
            XCTAssertEqual(ordinary.status, "Switchboard account switching is off for this session.")
        }
    }

    func testPrivatePairingUsesNativeMaskedControlWithoutVisibleWindow() throws {
        let host = NSHostingView(rootView: SwitchboardPairingInput(text: .constant("SYNTHETIC_PRIVATE_PAIRING")))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 44)
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        let secure = try XCTUnwrap(views.compactMap { $0 as? NSSecureTextField }.first)
        XCTAssertTrue(secure.cell is NSSecureTextFieldCell)
        XCTAssertFalse(views.contains { ($0 as? NSTextView)?.string.contains("SYNTHETIC_PRIVATE_PAIRING") == true })
        XCTAssertNil(host.window)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
