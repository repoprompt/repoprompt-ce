//
//  Shortcuts.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-09.
//

import KeyboardShortcuts

/// Define your shortcut
extension KeyboardShortcuts.Name {
    // static let cmdOptionA = Self("cmdOptionA", default: .init(.a, modifiers: [.command, .option]))

    // Switch to presets with Cmd+Option+1..9
    static let switchToPreset1 = Self("swPreset1", default: .init(.one, modifiers: [.command, .option]))
    static let switchToPreset2 = Self("swPreset21", default: .init(.two, modifiers: [.command, .option]))
    static let switchToPreset3 = Self("swPreset31", default: .init(.three, modifiers: [.command, .option]))
    static let switchToPreset4 = Self("swPreset41", default: .init(.four, modifiers: [.command, .option]))
    static let switchToPreset5 = Self("swPreset51", default: .init(.five, modifiers: [.command, .option]))
    static let switchToPreset6 = Self("swPreset61", default: .init(.six, modifiers: [.command, .option]))
    static let switchToPreset7 = Self("swPreset71", default: .init(.seven, modifiers: [.command, .option]))
    static let switchToPreset8 = Self("swPreset81", default: .init(.eight, modifiers: [.command, .option]))
    static let switchToPreset9 = Self("swPreset91", default: .init(.nine, modifiers: [.command, .option]))

    // New shortcuts for saving workspace and presets
    static let cmdS = Self("cmdS", default: .init(.s, modifiers: [.command]))
    static let cmdShiftS = Self("cmdShiftS3", default: .init(.s, modifiers: [.command, .shift]))
    static let cmdOptionS = Self("cmdOptionS", default: .init(.s, modifiers: [.command, .option]))
    static let cmdOptionP = Self("cmdOptionP", default: .init(.p, modifiers: [.command, .option]))

    // Agent session tab management
    static let newComposeTab = Self("composeTabNew", default: .init(.t, modifiers: [.command]))
    static let closeComposeTab = Self("composeTabClose", default: .init(.w, modifiers: [.command]))
    static let nextComposeTab = Self("composeTabNext", default: .init(.tab, modifiers: [.control]))
    static let previousComposeTab = Self("composeTabPrevious", default: .init(.tab, modifiers: [.control, .shift]))

    /// Agent window chrome
    /// New Agent session tab (same as the titlebar "New Session" control).
    static let agentNewChat = Self("agentNewChat", default: .init(.n, modifiers: [.command, .option]))
    /// Toggle the Agent session sidebar.
    static let toggleNavigationSidebar = Self("toggleNavigationSidebar", default: .init(.b, modifiers: [.command, .option]))
    /// Show the current-window Agent navigation HUD.
    static let showCurrentWindowAgentNavigationHUD = Self("showCurrentWindowAgentNavigationHUD", default: .init(.k, modifiers: [.command]))
    /// Show the all-active/recent Agents navigation HUD.
    static let showAllAgentsNavigationHUD = Self("showAllAgentsNavigationHUD", default: .init(.k, modifiers: [.command, .shift]))
    /// Cycle to the previous root Agent session row.
    static let previousParentAgentSession = Self("previousParentAgentSession", default: .init(.leftBracket, modifiers: [.command, .option]))
    /// Cycle to the next root Agent session row.
    static let nextParentAgentSession = Self("nextParentAgentSession", default: .init(.rightBracket, modifiers: [.command, .option]))

    // Switch to Agent session tabs with Cmd+1..9
    static let switchToComposeTab1 = Self("swComposeTab1", default: .init(.one, modifiers: [.command]))
    static let switchToComposeTab2 = Self("swComposeTab2", default: .init(.two, modifiers: [.command]))
    static let switchToComposeTab3 = Self("swComposeTab3", default: .init(.three, modifiers: [.command]))
    static let switchToComposeTab4 = Self("swComposeTab4", default: .init(.four, modifiers: [.command]))
    static let switchToComposeTab5 = Self("swComposeTab5", default: .init(.five, modifiers: [.command]))
    static let switchToComposeTab6 = Self("swComposeTab6", default: .init(.six, modifiers: [.command]))
    static let switchToComposeTab7 = Self("swComposeTab7", default: .init(.seven, modifiers: [.command]))
    static let switchToComposeTab8 = Self("swComposeTab8", default: .init(.eight, modifiers: [.command]))
    static let switchToComposeTab9 = Self("swComposeTab9", default: .init(.nine, modifiers: [.command]))
}
