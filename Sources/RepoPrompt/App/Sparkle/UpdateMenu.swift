//
//  UpdateMenu.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-28.
//  Updated by <your-name> on 2025-06-29.
//

import SwiftUI

// All update actions now funnel through SparkleUpdaterManager, exactly like the Settings screen.
// No direct references to SPUUpdater or Sparkle remain.

/// Main Commands implementation – now identical in behaviour to the Settings UI
struct UpdateMenu: Commands {
    @ObservedObject var sparkleManager: SparkleUpdaterManager

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // If an update is already known, offer a one-click "Install Update…"
            if sparkleManager.updateAvailable {
                Button("Install Update \(sparkleManager.updateVersion ?? "")…") {
                    sparkleManager.installUpdate() // always installs the latest
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                // Otherwise present a single "Check for Updates…" entry that triggers
                // the same helper the Settings view calls (no incremental chaining).
            } else {
                Button("Check for Updates…") {
                    sparkleManager.checkForUpdates() // jumps straight to latest
                }
                .disabled(!sparkleManager.canCheckForUpdates) // honour Sparkle’s state
                .keyboardShortcut("u", modifiers: [.command, .option])
            }

            Divider()

            Toggle(
                "Automatically Check for Updates",
                isOn: Binding(
                    get: { sparkleManager.automaticallyChecksForUpdates },
                    set: { sparkleManager.automaticallyChecksForUpdates = $0 }
                )
            )
        }
    }
}
