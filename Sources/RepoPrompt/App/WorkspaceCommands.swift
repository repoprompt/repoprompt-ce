import RepoPromptFileSystem
import SwiftUI

/// Extra File-menu items that operate on the *focused* window’s workspace.
struct WorkspaceCommands: Commands {
    /// Shared window tracker injected from the app. Not observed: `focusedWindow` is resolved when
    /// an action runs, so the menu does not need to rebuild on every window open/close.
    let windowStatesManager: WindowStatesManager

    /// The window currently in focus, or (as a fallback) the most-recently created one.
    private var focusedWindow: WindowState? {
        windowStatesManager.allWindows.first { $0.isCurrentlyFocused }
            ?? windowStatesManager.latestWindowState
    }

    var body: some Commands {
        // Insert immediately after the system "Save" item.
        CommandGroup(after: .saveItem) {
            // MARK: Save Workspace  ⌘S

            Button("Save Workspace") {
                saveActiveWorkspace()
            }
            .keyboardShortcut("s", modifiers: .command)

            // MARK: Save & Exit Workspace  ⇧⌘S

            Button("Save & Exit Workspace") {
                Task { @MainActor in
                    await saveAndExitActiveWorkspace()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    /// Save the currently active workspace (same as toolbar menu)
    private func saveActiveWorkspace() {
        guard let ws = focusedWindow else { return }
        ws.workspaceManager.pollAndSaveState()
    }

    /// Save and exit to fallback workspace (system workspace)
    private func saveAndExitActiveWorkspace() async {
        guard let ws = focusedWindow else { return }
        await ws.workspaceManager.saveAndExitToFallback()
    }
}
