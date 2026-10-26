# Keyboard shortcuts

## Ownership

`App/Shortcuts.swift` defines stable persisted `KeyboardShortcuts.Name` identities and defaults. `KeyboardShortcutCatalog` exposes the assignments in Settings → Keyboard Shortcuts. `GlobalKeyboardShortcutsCoordinator` owns keyboard dispatch; feature managers retain ownership of behavior.

The master switch enables shortcuts only while the app is active. Workspace/session bindings are unregistered outside a key main window with no attached sheet or modal dialog, rather than merely ignored after intercepting a native key. The close-session binding also closes Settings/auxiliary windows to preserve native Close behavior. Application commands work with Settings frontmost and after closing the last main window. Menu clicks do not depend on the master switch.

## Coverage audit (2026-10-26)

| Area | Audit finding / coverage |
| --- | --- |
| New workspace window | Automatic SwiftUI Cmd-N was not customizable. Replace `.newItem` with an explicit command and a registry binding, retaining Cmd-N. |
| Settings, close window, updates | Hardcoded Cmd-comma, Shift-Cmd-W, Option-Cmd-U become configurable without changing defaults. Updates retain the existing check/install/manual-download eligibility. |
| Save workspace / Save & Exit | Already configurable through Carbon, but native menu equivalents reserved the original keys independently. Remove the duplicate dispatch path. |
| Current session | Pin, rename, stash, handoff, copy ID, and delete lacked bindings. Reuse titlebar snapshots/actions, including incarnation validation, feedback, and confirmations. |
| New sessions and tab navigation | Already configurable: Cmd-T, Option-Cmd-N, Cmd-W, Control-Tab / Shift-Control-Tab, Cmd-1…9, and Option-Cmd-brackets. Preserve names and defaults. |
| Navigation and layout | Already configurable: session switcher, all-session search, session sidebar, Context Composer. |
| Workspace presets / text size | Already configurable: save/create/switch presets and font increase/decrease. |
| Text editing and local dialogs | Keep native responder-chain conventions: copy/paste, undo/redo, Return/Escape, sheet confirmations, contextual approval/merge-card buttons, and mention/editor navigation. These are local controls, not global commands. |

### Newly assigned session defaults

| Action | Default | Rationale |
| --- | --- | --- |
| Pin / unpin | Shift-Cmd-P | Mnemonic P; Cmd-P already toggles Context Composer. |
| Rename | Shift-Cmd-R | Mnemonic R; does not steal Return from editing or submission. |
| Stash | Shift-Cmd-E | Mnemonic E for exiting the session without deleting it; leaves Save & Exit Workspace unchanged. |
| Copy handoff prompt | Shift-Cmd-H | Mnemonic H; leaves macOS Cmd-H and Option-Cmd-H intact. |
| Copy session ID | Option-Cmd-C | Copy-special convention; leaves ordinary Cmd-C intact. |
| Delete | Unassigned | Destructive action is opt-in and still confirms. |

Existing defaults and raw persisted names are unchanged. New defaults do not collide with the existing catalog defaults; new session defaults yield to saved assignments on upgrade (the new action stays unassigned when occupied). Deliberately clearing a new action is preserved across launches. Other-app assignments may still conflict and can be cleared/reassigned in the recorder.

### Remapping Cmd-N to a session

Clear or reassign **Application → New workspace window**, then record Cmd-N for **New Agent chat** or **New Agent session tab**. Both session commands use the same session-creation path. Clearing a shortcut remains distinct from resetting to its default, and assignments persist through the existing library storage.

## Menu display versus dispatch

Managed commands display current assignments as label suffixes rather than native menu key equivalents. This is deliberate: the pinned KeyboardShortcuts library warns that `globalKeyboardShortcut` inside `CommandGroup` can make recorders reject their own menu bindings, including stale native equivalents on macOS 15. A single Carbon dispatcher prevents duplicate invocation and frees old keys after remapping. The transient session options pop-up is the exception: its items keep plain semantic titles and show the current assignment as a native key equivalent, so AppKit renders and announces it as a shortcut. The recorder only scans `NSApp.mainMenu` for conflicts and the pop-up is never attached there, so this reserves no keys; while the pop-up tracks, the library's event-tracking monitor consumes registered shortcuts first, preserving one invocation per press. `ManagedCloseMenuShortcut` removes only the standard `performClose:` Cmd-W equivalent supplied automatically by SwiftUI, including reconstructed items; the configurable close-session/window handler then owns that key. Its menu action remains clickable.

`GlobalKeyboardShortcutsCoordinator` owns the display and automatic-Close adapters; neither adds another app singleton. `KeyboardShortcutBindingDisplay` is a bounded, read-only projection of library assignments. Defaults-change notifications and app activation refresh it; it owns no persistence. Avoid adding fixed `.keyboardShortcut` modifiers to these managed commands.

## Validation

`KeyboardShortcutCoverageTests` covers catalog identities and coverage, retained defaults, default collisions, remap/clear/reset display, and exact session action forwarding. Existing `AgentChatTitlebarSafetyTests` cover immutable captures and stale-target safety.

Live UI checks should exercise recording the original key, clearing, remapping, reset, restart persistence, menu labels, one invocation per press, sheet/auxiliary-window gating, and Cmd-N after closing all main windows. Standard OS menu/responder commands remain outside the global catalog; verify those independently when changing window-command composition.
