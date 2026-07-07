import AppKit
@testable import RepoPrompt
import XCTest

/// Pins the keyboard-event swallowing policy for the hold-⌘Q-to-quit gate at
/// the lowest faithful layer (a pure helper over `NSEvent.ModifierFlags`).
/// Table-driven to keep the normalization / toggle-off / non-quit-key cases
/// tight. Covers S-003 (toggle off → pass-through) and S-011 (⌘W / ⇧⌘W /
/// extra-modifier ⌘Q untouched) without mocking NSEvent/NSApp.
final class QuitHoldEventFilterTests: XCTestCase {
    /// `kVK_ANSI_Q` (Carbon `0x0C`); hard-coded to avoid importing Carbon.
    private let qKeyCode: UInt16 = 0x0C
    /// `kVK_ANSI_W` (Carbon `0x0D`).
    private let wKeyCode: UInt16 = 0x0D

    /// ⌘Q (command-only) is still recognized with Caps Lock / Fn / numeric pad
    /// active — those flags are normalized out.
    func testCmdQWithIgnorableModifiersIsSwallowedWhenToggleOn() {
        let swallowCases: [NSEvent.ModifierFlags] = [
            .command,
            [.command, .capsLock],
            [.command, .function],
            [.command, .numericPad]
        ]
        for flags in swallowCases {
            XCTAssertTrue(
                QuitHoldEventFilter.shouldSwallowKeyDown(modifierFlags: flags, keyCode: qKeyCode, toggleOn: true),
                "expected swallow for normalized ⌘Q with flags \(flags)"
            )
        }
    }

    /// S-003: with the toggle off, ⌘Q is not swallowed (default menu fires).
    func testCmdQWithToggleOffIsNotSwallowed() {
        XCTAssertFalse(
            QuitHoldEventFilter.shouldSwallowKeyDown(modifierFlags: .command, keyCode: qKeyCode, toggleOn: false)
        )
    }

    /// Extra modifiers (⌘⇧/⌘⌥/⌘⌃), wrong key (⌘W / ⇧⌘W), and Q-without-command
    /// are all passed through untouched (exact-modifier match; S-011).
    func testNonQuitGesturesAreNotSwallowed() {
        let passThrough: [(NSEvent.ModifierFlags, UInt16, String)] = [
            ([.command, .shift], qKeyCode, "⌘⇧Q"),
            ([.command, .option], qKeyCode, "⌘⌥Q"),
            ([.command, .control], qKeyCode, "⌘⌃Q"),
            (.command, wKeyCode, "⌘W"),
            ([.command, .shift], wKeyCode, "⇧⌘W"),
            ([], qKeyCode, "Q alone")
        ]
        for (flags, key, label) in passThrough {
            XCTAssertFalse(
                QuitHoldEventFilter.shouldSwallowKeyDown(modifierFlags: flags, keyCode: key, toggleOn: true),
                "expected pass-through for \(label)"
            )
        }
    }
}
