import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class SwitchboardPairingInputTests: XCTestCase {
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
