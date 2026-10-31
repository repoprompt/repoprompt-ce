import RepoPromptSettingsCore

//
//  KeyboardShortcutsSettingsView.swift
//  RepoPrompt
//

import KeyboardShortcuts
import SwiftUI

// MARK: - Catalog

/// Single source of truth for global `KeyboardShortcuts` bindings shown in Settings
/// (actions are registered in `GlobalKeyboardShortcutsCoordinator`).
enum KeyboardShortcutCatalog {
    static let sections: [KeyboardShortcutCatalogSection] = [
        KeyboardShortcutCatalogSection(
            id: "application",
            title: "Application",
            blurb: "Clear or change New Workspace Window to free ⌘N for New Agent chat or New Agent session tab.",
            bindings: [
                .init(id: "new-window", title: "New workspace window", detail: nil, name: .newWorkspaceWindow),
                .init(id: "settings", title: "Settings", detail: nil, name: .showAppSettings),
                .init(id: "close-window", title: "Close window", detail: nil, name: .closeAppWindow),
                .init(id: "updates", title: "Check for updates / install available update", detail: nil, name: .checkForUpdates)
            ]
        ),
        KeyboardShortcutCatalogSection(
            id: "current-session",
            title: "Current Agent session",
            blurb: "Apply to the current session, just like its titlebar menu. Delete is unassigned by default and always asks for confirmation.",
            bindings: [
                .init(
                    id: "session-stop",
                    title: "Stop current run",
                    detail: "Same as the composer Stop button. With nothing to stop, ⌘. keeps its usual cancel behavior.",
                    name: .stopAgentRun
                ),
                .init(id: "session-focus-composer", title: "Focus message composer", detail: nil, name: .focusAgentComposer),
                .init(id: "session-pin", title: "Pin / unpin session", detail: nil, name: .pinAgentSession),
                .init(id: "session-rename", title: "Rename session", detail: nil, name: .renameAgentSession),
                .init(id: "session-stash", title: "Stash session", detail: nil, name: .stashAgentSession),
                .init(id: "session-handoff", title: "Copy handoff prompt", detail: nil, name: .handoffAgentSession),
                .init(id: "session-copy-id", title: "Copy session ID", detail: nil, name: .copyAgentSessionID),
                .init(id: "session-delete", title: "Delete session…", detail: nil, name: .deleteAgentSession)
            ]
        ),
        KeyboardShortcutCatalogSection(
            id: "agent-layout",
            title: "Agent & layout",
            blurb: "Agent shortcuts apply when a real workspace is open. New chat matches the titlebar New Session button.",
            bindings: [
                .init(id: "agent-new", title: "New Agent chat", detail: nil, name: .agentNewChat),
                .init(id: "toggle-sidebar", title: "Toggle session sidebar", detail: "Show or hide the Agent sessions list.", name: .toggleNavigationSidebar),
                .init(
                    id: "toggle-context-composer",
                    title: "Toggle Context Composer",
                    detail: "Show or hide the Context Composer",
                    name: .toggleContextComposer
                ),
                .init(id: "agent-nav-current", title: "Show Agent Session Switcher", detail: "Jump between Agent sessions in the focused window.", name: .showCurrentWindowAgentNavigationHUD),
                .init(id: "agent-nav-all", title: "Search all Agent sessions", detail: "Jump to active or recent Agent sessions across windows.", name: .showAllAgentsNavigationHUD),
                .init(
                    id: "agent-next-attention",
                    title: "Next session needing attention",
                    detail: "Cycle through sessions with an unseen completed, failed, or waiting badge in this window.",
                    name: .nextAttentionAgentSession
                ),
                .init(
                    id: "agent-reopen-stashed",
                    title: "Reopen last stashed session",
                    detail: "Restore the most recently stashed session, including one closed with ⌘W.",
                    name: .reopenStashedAgentSession
                )
            ]
        ),
        KeyboardShortcutCatalogSection(
            id: "composer",
            title: "Composer",
            blurb: "Not global: Re-prompt works while the message composer has focus, and Send original only while a Re-prompt is shown. A matching shortcut elsewhere in this list wins.",
            bindings: [
                .init(id: "composer-reprompt", title: "Re-prompt draft again", detail: nil, name: .repromptDraft),
                .init(
                    id: "composer-send-original",
                    title: "Send original (during Re-prompt)",
                    detail: "Sends your original text instead of the rewrite.",
                    name: .repromptSendOriginal
                )
            ]
        ),
        KeyboardShortcutCatalogSection(
            id: "workspace-presets",
            title: "Workspace & presets",
            blurb: "Save and navigate the active workspace. Preset shortcuts jump to the numbered preset in the workspace manager.",
            bindings: workspaceAndPresetBindings
        ),
        KeyboardShortcutCatalogSection(
            id: "compose-tabs",
            title: "Agent session tabs",
            blurb: "Navigate Agent session tabs. ⌘1–9 follows the Agent session sidebar order.",
            bindings: composeBindings
        ),
        KeyboardShortcutCatalogSection(
            id: "display",
            title: "Display",
            blurb: "Adjust prompt and transcript text size globally.",
            bindings: [
                .init(id: "font-up", title: "Increase font size", detail: nil, name: .increaseFontScale),
                .init(id: "font-down", title: "Decrease font size", detail: nil, name: .decreaseFontScale),
                .init(id: "font-reset", title: "Reset font size", detail: nil, name: .resetFontScale)
            ]
        )
    ]

    /// Commands that stay registered outside main windows (Settings frontmost, no window open).
    static var applicationNames: [KeyboardShortcuts.Name] {
        sections.first { $0.id == "application" }?.bindings.map(\.name) ?? []
    }

    private static var workspaceAndPresetBindings: [KeyboardShortcutCatalogBinding] {
        var rows: [KeyboardShortcutCatalogBinding] = [
            .init(id: "save-ws", title: "Save workspace", detail: nil, name: .cmdS),
            .init(id: "save-exit", title: "Save workspace and switch to system workspace", detail: nil, name: .cmdShiftS),
            .init(id: "save-preset-or-create", title: "Save current preset (or create preset if none)", detail: nil, name: .cmdOptionS),
            .init(id: "create-preset", title: "Create new preset", detail: nil, name: .cmdOptionP)
        ]
        let presetNames: [KeyboardShortcuts.Name] = [
            .switchToPreset1, .switchToPreset2, .switchToPreset3, .switchToPreset4, .switchToPreset5,
            .switchToPreset6, .switchToPreset7, .switchToPreset8, .switchToPreset9
        ]
        for index in 0 ..< 9 {
            let n = index + 1
            rows.append(
                KeyboardShortcutCatalogBinding(
                    id: "preset-\(n)",
                    title: "Switch to preset \(n)",
                    detail: nil,
                    name: presetNames[index]
                )
            )
        }
        return rows
    }

    private static var composeBindings: [KeyboardShortcutCatalogBinding] {
        var rows: [KeyboardShortcutCatalogBinding] = [
            .init(id: "compose-new", title: "New Agent session tab", detail: nil, name: .newComposeTab),
            .init(id: "compose-close", title: "Close active Agent session tab", detail: nil, name: .closeComposeTab),
            .init(id: "compose-next", title: "Next Agent session tab", detail: nil, name: .nextComposeTab),
            .init(id: "compose-prev", title: "Previous Agent session tab", detail: nil, name: .previousComposeTab),
            .init(id: "compose-parent-next", title: "Next parent Agent session", detail: "Cycle root sidebar rows only; child sessions stay grouped under their parent.", name: .nextParentAgentSession),
            .init(id: "compose-parent-prev", title: "Previous parent Agent session", detail: "Cycle root sidebar rows only; child sessions stay grouped under their parent.", name: .previousParentAgentSession)
        ]
        let tabNames: [KeyboardShortcuts.Name] = [
            .switchToComposeTab1, .switchToComposeTab2, .switchToComposeTab3, .switchToComposeTab4, .switchToComposeTab5,
            .switchToComposeTab6, .switchToComposeTab7, .switchToComposeTab8, .switchToComposeTab9
        ]
        for index in 0 ..< 9 {
            let n = index + 1
            rows.append(
                KeyboardShortcutCatalogBinding(
                    id: "compose-tab-\(n)",
                    title: "Focus Agent session tab \(n)",
                    detail: nil,
                    name: tabNames[index]
                )
            )
        }
        return rows
    }
}

struct KeyboardShortcutCatalogSection: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let bindings: [KeyboardShortcutCatalogBinding]
}

struct KeyboardShortcutCatalogBinding: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let name: KeyboardShortcuts.Name
}

// MARK: - Settings view

struct KeyboardShortcutsSettingsView: View {
    /// Canonical storage lives in GlobalSettingsStore.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    private var enableKeyboardShortcuts: Bool {
        globalSettings.enableKeyboardShortcuts()
    }

    private var enableKeyboardShortcutsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.enableKeyboardShortcuts() },
            set: { globalSettings.setEnableKeyboardShortcuts($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(
                    title: "Keyboard Shortcuts",
                    description: "Customize shortcuts used while RepoPrompt is active. Clear a binding before assigning its keys to another action. Session and workspace actions require a focused main window; standard text editing and dialog keys remain native."
                ) {
                    SettingToggle(
                        title: "Enable keyboard shortcuts",
                        description: "When disabled, none of these shortcuts run (your custom bindings stay saved).",
                        isOn: enableKeyboardShortcutsBinding
                    )
                }

                if !enableKeyboardShortcuts {
                    Text("Turn on “Enable keyboard shortcuts” to use the bindings below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(KeyboardShortcutCatalog.sections) { section in
                    Divider()
                        .padding(.horizontal, -16)

                    SettingSection(title: section.title, description: section.blurb) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(section.bindings) { binding in
                                ShortcutPreferenceRow(
                                    title: binding.title,
                                    subtitle: binding.detail,
                                    shortcut: binding.name
                                )
                                .opacity(enableKeyboardShortcuts ? 1 : 0.45)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Row

struct ShortcutPreferenceRow: View {
    let title: String
    var subtitle: String?
    let shortcut: KeyboardShortcuts.Name

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 12)
                KeyboardShortcuts.Recorder(for: shortcut)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
