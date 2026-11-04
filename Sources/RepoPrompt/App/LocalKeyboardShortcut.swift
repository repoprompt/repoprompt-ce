import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import RepoPromptSettingsCore
import SwiftUI

/// User-assignable bindings that are dispatched by the focused view instead of Carbon.
///
/// Carbon hot keys swallow their key everywhere in the app, so contextual commands (Re-prompt in the
/// composer, Send original while a rewrite is shown) would break ordinary typing if registered there.
/// These names live in the Settings catalog like every other binding, but the coordinator keeps them
/// unregistered and the owning view matches the current assignment itself.
enum LocalKeyboardShortcut {
    static let names: [KeyboardShortcuts.Name] = [.repromptDraft, .repromptSendOriginal]

    /// Local bindings honor the Settings master switch like every other catalog row.
    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.enableKeyboardShortcuts()
    }

    /// Whether `event` is the current, enabled assignment for `name`. Keypad Enter matches Return.
    @MainActor
    static func matches(_ event: NSEvent, _ name: KeyboardShortcuts.Name) -> Bool {
        guard isEnabled, let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        return matches(event, shortcut)
    }

    static func matches(_ event: NSEvent, _ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        guard event.type == .keyDown else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return normalizedKeyCode(Int(event.keyCode)) == normalizedKeyCode(shortcut.carbonKeyCode)
            && event.modifierFlags.intersection(relevant) == shortcut.modifiers.intersection(relevant)
    }

    /// Return and keypad Enter are one key for these commands, whichever was recorded.
    private static func normalizedKeyCode(_ keyCode: Int) -> Int {
        keyCode == kVK_ANSI_KeypadEnter ? kVK_Return : keyCode
    }

    /// SwiftUI equivalent of the current, enabled assignment, for `.keyboardShortcut(_:)` on local buttons.
    @MainActor
    static func swiftUIShortcut(for name: KeyboardShortcuts.Name) -> SwiftUI.KeyboardShortcut? {
        guard isEnabled, let shortcut = KeyboardShortcuts.getShortcut(for: name),
              let character = shortcut.nsMenuItemKeyEquivalent?.first
        else { return nil }
        var modifiers: SwiftUI.EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return SwiftUI.KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

extension View {
    /// Applies the current assignment of a local binding; no shortcut when cleared.
    /// Callers re-render on `KeyboardShortcutBindingDisplay` changes so remaps take effect live.
    @ViewBuilder
    func localKeyboardShortcut(_ name: KeyboardShortcuts.Name) -> some View {
        if let shortcut = LocalKeyboardShortcut.swiftUIShortcut(for: name) {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
