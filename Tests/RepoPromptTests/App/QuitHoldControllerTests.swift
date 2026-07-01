import AppKit
@testable import RepoPrompt
import XCTest

/// Controller lifecycle seam: verifies an external cancellation (owner window
/// closed / app resigned active) resets an in-flight hold so a later ⌘Q can't
/// quit from stale `.armed`/`.holding` state. Drives the real `handle(_:)`
/// with synthetic NSEvents and a deterministic (injected) toggle.
@MainActor
final class QuitHoldControllerTests: XCTestCase {
    private let qKeyCode: UInt16 = 0x0C

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16) -> NSEvent {
        // Force-unwrap is fine in a test for a well-formed key event.
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: keyCode
        )!
    }

    override func setUp() {
        super.setUp()
        // The controller's overlay anchors to NSApp.keyWindow; ensure the app
        // exists so panel creation is well-defined during the test.
        _ = NSApplication.shared
    }

    /// External cancellation while holding resets to idle.
    func testExternalCancellationWhileHoldingResetsToIdle() {
        let controller = QuitHoldController(warnBeforeCmdQ: { true })
        _ = controller.handle(keyEvent(.keyDown, keyCode: qKeyCode))
        XCTAssertEqual(controller.holdState, .holding)
        controller.handleExternalCancellation()
        XCTAssertEqual(controller.holdState, .idle)
    }

    /// Regression: after an external cancel, a later quick ⌘Q tap must NOT quit
    /// (no stale `.armed`). It begins a fresh hold and cancels on release.
    func testTapAfterExternalCancellationDoesNotQuit() {
        let controller = QuitHoldController(warnBeforeCmdQ: { true })
        _ = controller.handle(keyEvent(.keyDown, keyCode: qKeyCode)) // -> holding
        controller.handleExternalCancellation() // -> idle
        // A subsequent quick tap (keyDown then keyUp, no timer/threshold):
        _ = controller.handle(keyEvent(.keyDown, keyCode: qKeyCode))
        XCTAssertEqual(controller.holdState, .holding)
        _ = controller.handle(keyEvent(.keyUp, keyCode: qKeyCode))
        XCTAssertEqual(controller.holdState, .idle) // not .quitting
    }
}
