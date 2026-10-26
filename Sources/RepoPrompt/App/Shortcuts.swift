//
//  Shortcuts.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-09.
//

import Foundation
import KeyboardShortcuts

/// Define your shortcut
extension KeyboardShortcuts.Name {
    // static let cmdOptionA = Self("cmdOptionA", default: .init(.a, modifiers: [.command, .option]))

    // Application commands: preserve the defaults formerly owned by native menus.
    static let newWorkspaceWindow = Self("newWorkspaceWindow", default: .init(.n, modifiers: [.command]))
    static let showAppSettings = Self("showAppSettings", default: .init(.comma, modifiers: [.command]))
    static let closeAppWindow = Self("closeAppWindow", default: .init(.w, modifiers: [.command, .shift]))
    static let checkForUpdates = Self("checkForUpdates", default: .init(.u, modifiers: [.command, .option]))

    // Current-session actions. Destructive deletion intentionally requires an opt-in binding.
    static let pinAgentSession = sessionAction("pinAgentSession", default: .init(.p, modifiers: [.command, .shift]))
    static let renameAgentSession = sessionAction("renameAgentSession", default: .init(.r, modifiers: [.command, .shift]))
    static let stashAgentSession = sessionAction("stashAgentSession", default: .init(.e, modifiers: [.command, .shift]))
    static let handoffAgentSession = sessionAction("handoffAgentSession", default: .init(.h, modifiers: [.command, .shift]))
    static let copyAgentSessionID = sessionAction("copyAgentSessionID", default: .init(.c, modifiers: [.command, .option]))
    static let deleteAgentSession = Self("deleteAgentSession")

    /// Preserve upgrade-time custom assignments, including explicitly cleared new actions.
    /// The pinned library has no public name/existence enumeration API. Its documented-in-source
    /// UserDefaults prefix is used only for discovery; decoding and writes stay in the library.
    static func sessionAction(_ rawValue: String, default shortcut: KeyboardShortcuts.Shortcut) -> Self {
        let prefix = "KeyboardShortcuts_"
        let stored = UserDefaults.standard.dictionaryRepresentation()
        let isNew = stored[prefix + rawValue] == nil
        let occupied = isNew && stored.keys.contains { key in
            guard key.hasPrefix(prefix),
                  let name = Self(rawValue: String(key.dropFirst(prefix.count)))
            else { return false }
            return name.rawValue != rawValue && KeyboardShortcuts.getShortcut(for: name) == shortcut
        }
        let name = Self(rawValue, default: shortcut)
        if occupied { KeyboardShortcuts.setShortcut(nil, for: name) }
        return name
    }

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
    /// Toggle Context Composer.
    /// The raw key remains stable so existing custom bindings continue to resolve.
    static let toggleContextComposer = Self("toggleComposeInspector", default: .init(.p, modifiers: [.command]))
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
