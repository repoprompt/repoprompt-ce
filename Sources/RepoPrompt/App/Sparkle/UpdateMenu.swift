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
            if let availableUpdate = sparkleManager.availableUpdate {
                if sparkleManager.canInstallAvailableUpdate {
                    Button(availableUpdate.menuInstallTitle) {
                        sparkleManager.installUpdate()
                    }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                } else if sparkleManager.manualUpdateDownloadURL != nil {
                    Button(availableUpdate.menuManualDownloadTitle) {
                        sparkleManager.performAvailableUpdateAction()
                    }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                }
            } else {
                Button(sparkleManager.updateCheckMenuTitle) {
                    sparkleManager.checkForUpdates()
                }
                .disabled(!sparkleManager.canInitiateUpdateCheck)
                .keyboardShortcut("u", modifiers: [.command, .option])
            }

            if sparkleManager.migrationRecoveryDownloadsURL != nil {
                Button("Stable releases / recovery downloads…") {
                    sparkleManager.openMigrationRecoveryDownloads()
                }
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
