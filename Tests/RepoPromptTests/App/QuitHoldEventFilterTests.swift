import AppKit
@testable import RepoPrompt
import XCTest

/// Pins the keyboard-event swallowing policy for the hold-⌘Q-to-quit gate at the
/// lowest faithful layer (a pure helper over `NSEvent.ModifierFlags`).
///
/// These tests cover the controller-level concerns of scenarios S-003
/// (toggle off -> not swallowed, default menu fires), S-010 (a repeated ⌘Q
/// keyDown during a hold is still swallowed), and S-011 (⌘W / ⇧⌘W pass through
/// untouched) without mocking `NSEvent`/`NSApp`. See
/// `docs/spec/hold-to-quit.md` for the exact-modifier-match and
/// event-swallowing constraints.
final class QuitHoldEventFilterTests: XCTestCase {
    /// `kVK_ANSI_Q` (Carbon `0x0C`). Hard-coded to avoid a Carbon import.
    private let qKeyCode: UInt16 = 0x0C
    /// `kVK_ANSI_W` (Carbon `0x0D`). Hard-coded to avoid a Carbon import.
    private let wKeyCode: UInt16 = 0x0D

    // MARK: - Toggle state

    /// ⌘Q (Command only) with the toggle on is swallowed.
    func testCmdQCommandOnlyWithToggleOnSwallows() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: .command,
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, true)
    }

    /// S-003: ⌘Q with the toggle off is NOT swallowed, so the default menu key
    /// equivalent fires and the app quits immediately (today's behavior).
    func testCmdQWithToggleOffDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: .command,
            keyCode: qKeyCode,
            toggleOn: false
        )
        XCTAssertEqual(result, false)
    }

    // MARK: - Normalized modifiers (still ⌘Q)

    /// ⌘Q with Caps Lock active is still recognized — Caps Lock is normalized out.
    func testCmdQWithCapsLockSwallows() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .capsLock],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, true)
    }

    /// ⌘Q with the Fn/function flag set is still recognized — it is normalized out
    /// (real hardware ⌘Q keyDowns commonly carry this bit).
    func testCmdQWithFunctionSwallows() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .function],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, true)
    }

    /// ⌘Q with the numeric-pad flag set is still recognized — it is normalized out.
    func testCmdQWithNumericPadSwallows() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .numericPad],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, true)
    }

    // MARK: - Extra modifiers (NOT ⌘Q -> pass through)

    /// ⌘⇧Q is not the quit gesture — it passes through untouched.
    func testCmdShiftQDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .shift],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }

    /// ⌘⌥Q is not the quit gesture — it passes through untouched.
    func testCmdOptionQDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .option],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }

    /// ⌘⌃Q is not the quit gesture — it passes through untouched.
    func testCmdControlQDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .control],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }

    // MARK: - Wrong key (S-011)

    /// ⌘W is never swallowed — window-close behavior is unchanged.
    func testCmdWDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: .command,
            keyCode: wKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }

    /// ⇧⌘W is never swallowed — "Close Window" behavior is unchanged.
    func testShiftCmdWDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [.command, .shift],
            keyCode: wKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }

    // MARK: - No Command

    /// Q with no Command modifier is never swallowed.
    func testQWithoutCommandDoesNotSwallow() {
        let result = QuitHoldEventFilter.shouldSwallowKeyDown(
            modifierFlags: [],
            keyCode: qKeyCode,
            toggleOn: true
        )
        XCTAssertEqual(result, false)
    }
}
