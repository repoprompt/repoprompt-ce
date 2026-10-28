import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Increase font scale: default Cmd+= (commonly used for "Cmd+").
    static let increaseFontScale = Self(
        "increaseFontScale",
        default: .init(.equal, modifiers: [.command])
    )

    /// Reset font scale to Normal: default Cmd-0 (macOS "Actual Size").
    static let resetFontScale = sessionAction("resetFontScale", default: .init(.zero, modifiers: [.command]))

    /// Decrease font scale: default Cmd-minus.
    static let decreaseFontScale = Self(
        "decreaseFontScale",
        default: .init(.minus, modifiers: [.command])
    )
}
