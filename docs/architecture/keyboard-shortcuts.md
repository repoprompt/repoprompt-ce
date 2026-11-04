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

## Coverage audit (2026-10-27)

| Area | Audit finding / coverage |
| --- | --- |
| Stop a run | Only the composer Stop button. Add a binding that uses the same guarded `AgentRunCancelTarget`. |
| Focus composer | No way to return to the composer from the sidebar, search, or transcript without the mouse. |
| Reopen stashed session | ⌘W stashes the session, but restoring it required the Archived sessions list. |
| Sessions needing attention | Unseen completed/failed/waiting badges had no keyboard navigation. |
| Text size | Increase/decrease existed; reset to Normal did not. |
| Re-prompt keys | ⌘↩ (rewrite again) and ⇧⌘O (send original) were fixed in code. Now configurable composer-local bindings. |
| Deferred | Fork-from-message needs a message and destination chosen in its popover; model/effort pickers and the attachment picker are view-local menus; scroll-to-latest needs the transcript's scroll proxy. Each needs a view-owned trigger before it can get a binding. |

### Newly assigned workflow defaults

| Action | Default | Rationale |
| --- | --- | --- |
| Stop current run | Cmd-period | The macOS stop/cancel convention (Xcode, Terminal, sheets). With nothing to stop, the default key is forwarded as `cancelOperation:`. For a focused text view this goes through `doCommand(by:)`, so delegate Escape handling such as Re-prompt cancel/revert still runs. A remapped key gets no fallback. |
| Focus message composer | Cmd-L | Focuses the primary input field, as in browsers. No standard text-system binding. |
| Reopen last stashed session | Shift-Cmd-T | Browser "reopen closed tab"; pairs with Cmd-W, which stashes. |
| Next session needing attention | Shift-Cmd-A | Slack-style "all unreads". Walks unpaged, uncollapsed sidebar order, wrapping. |
| Reset font size | Cmd-0 | macOS "Actual Size". |
| Re-prompt draft again | Cmd-Return | Unchanged former fixed key. |
| Send original (Re-prompt) | Shift-Cmd-O | Unchanged former fixed key. |

The workflow defaults use `sessionAction`, so they yield to saved assignments on upgrade like the 2026-10-26 session defaults. The two Re-prompt keys keep their defaults unconditionally because they are not new behavior.

### Composer-local bindings

`LocalKeyboardShortcut` names are catalog rows like any other, but they are never Carbon hot keys. A hot key consumes its key everywhere in the app and cannot pass it back, which would break Cmd-Return in every other field. The pinned library registers a hot key whenever an assignment is saved, including first-launch defaults, even with no handler. The coordinator therefore drops local names twice. A synchronous, main-thread `UserDefaults` observer runs before AppKit can deliver another key event. `updateRegistrationContext` (before its handler guard) then re-enables any application or window command that shares those keys. The composer matches the current assignment in `AttachmentAwareTextView` (`commandReturnMatcher`, in both `performKeyEquivalent` and `keyDown` for bindings without Command, and gating the `insertNewline:` fallback). The Re-prompt strip applies it with `.localKeyboardShortcut(_:)`. Labels and tooltips read `KeyboardShortcutBindingDisplay`, so a remap or clear takes effect immediately. Local bindings honor the master switch. Their hints disappear when it is off. A global binding on the same key wins, which the Settings blurb states. Send original remains a window-scoped SwiftUI button shortcut while the Re-prompt strip is visible, as the fixed key was.

### Remaining fixed keys

These stay native by design and are not in the catalog:

- Text editing and responder-chain keys.
- Return/Escape and `.defaultAction`/`.cancelAction`.
- Mention picker navigation.
- Accept/reject accelerators on pending review cards. Cmd-Return accepts and Cmd-Delete rejects/cancels, the macOS dialog convention, scoped to the visible card.
- Standard OS menu items: Quit, Hide, Minimize, Full Screen, and the Edit menu.

Users can still rebind OS menu items through System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts.

## Menu display versus dispatch

Managed commands display current assignments as label suffixes rather than native menu key equivalents. This is deliberate: the pinned KeyboardShortcuts library warns that `globalKeyboardShortcut` inside `CommandGroup` can make recorders reject their own menu bindings, including stale native equivalents on macOS 15. A single Carbon dispatcher prevents duplicate invocation and frees old keys after remapping. The transient session options pop-up is the exception: its items keep plain semantic titles and show the current assignment as a native key equivalent, so AppKit renders and announces it as a shortcut. The recorder only scans `NSApp.mainMenu` for conflicts and the pop-up is never attached there, so this reserves no keys; while the pop-up tracks, the library's event-tracking monitor consumes registered shortcuts first, preserving one invocation per press. `ManagedCloseMenuShortcut` removes only the standard `performClose:` Cmd-W equivalent supplied automatically by SwiftUI, including reconstructed items; the configurable close-session/window handler then owns that key. Its menu action remains clickable.

`GlobalKeyboardShortcutsCoordinator` owns the display and automatic-Close adapters; neither adds another app singleton. `KeyboardShortcutBindingDisplay` is a bounded, read-only projection of library assignments. Defaults-change notifications and app activation refresh it; it owns no persistence. Avoid adding fixed `.keyboardShortcut` modifiers to these managed commands.

## Validation

`KeyboardShortcutCoverageTests` (in `AgentChatTitlebarSafetyTests.swift`) covers:

- Catalog identities and coverage.
- Retained and new defaults, and default collisions.
- Remap/clear/reset display.
- Exact session action forwarding.
- Local-binding matching and SwiftUI conversion.
- Next-attention ordering.
- The Cmd-period cancel fallback rule.

`ResizableTextFieldTests` covers a remapped/cleared rewrite key across the key-equivalent, keyDown, and newline paths. Existing `AgentChatTitlebarSafetyTests` cover immutable captures and stale-target safety.

Live UI checks should exercise:

- Recording the original key, clearing, remapping, reset, and restart persistence.
- Menu labels and one invocation per press.
- Sheet/auxiliary-window gating.
- Cmd-N after closing all main windows.
- Cmd-period with and without an active run.
- Cmd-Return in non-composer fields after remapping Re-prompt. Standard OS menu/responder commands remain outside the global catalog; verify those independently when changing window-command composition.
