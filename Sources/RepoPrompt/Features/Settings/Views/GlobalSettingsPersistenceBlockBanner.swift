import AppKit
import SwiftUI

/// Surfaces a blocked global-settings file (e.g. an on-disk schema newer than this build
/// supports) so the user understands why settings will not save, with a one-click recovery
/// that backs up the offending file and writes current-schema settings. Shown only
/// while `GlobalSettingsStore.shared.persistenceBlockReason` is non-nil.
///
/// RepoPrompt never auto-recovers from a schema it did not write; this banner is the user
/// action that clears the block.
struct GlobalSettingsPersistenceBlockBanner: View {
    @ObservedObject private var store = GlobalSettingsStore.shared
    @State private var isPresentingImportConfirmation = false
    @State private var isPresentingResetConfirmation = false
    @State private var recoveryActionError: String?

    var body: some View {
        if let reason = store.persistenceBlockReason {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message(for: reason))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let recoveryActionError {
                    Text(recoveryActionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    switch reason {
                    case .saveFailed:
                        Button("Try again") {
                            recoveryActionError = store.retryBlockedPersistenceSave()
                                ? nil
                                : "Save still failed. Check file permissions or available disk space, then try again."
                        }
                        Button("Reset global settings…") { isPresentingResetConfirmation = true }
                            .buttonStyle(.borderless)
                    case .unsupportedFutureSchema:
                        Button("Reset global settings…") { isPresentingResetConfirmation = true }
                            .buttonStyle(.borderless)
                    case .incompatibleSchema:
                        Button("Import compatible settings…") { isPresentingImportConfirmation = true }
                        Button("Reset global settings…") { isPresentingResetConfirmation = true }
                            .buttonStyle(.borderless)
                    case .corruptUnrecoverable:
                        Button("Reset global settings…") { isPresentingResetConfirmation = true }
                    }
                    Button("Show file") { revealGlobalSettingsFile() }
                        .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.orange.opacity(0.12))
            )
            .padding(.horizontal)
            .padding(.top, 6)
            .confirmationDialog(
                "Import compatible settings?",
                isPresented: $isPresentingImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("Back up file and import") {
                    recoveryActionError = store.importBlockedPersistenceAfterBackup()
                        ? nil
                        : "Import failed. The file was left in place; you can show the file, try again, or reset after backing it up."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "RepoPrompt will move the current globalSettings.json to the Backups folder, then import the settings this build understands into a fresh current-schema file. Settings from the other schema that this build does not understand remain in the backup."
                )
            }
            .confirmationDialog(
                "Reset global settings?",
                isPresented: $isPresentingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Back up file and reset", role: .destructive) {
                    recoveryActionError = store.recoverBlockedPersistenceAfterBackup()
                        ? nil
                        : "Recovery failed. Check file permissions or available disk space, then try again."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetConfirmationMessage(for: reason))
            }
        }
    }

    private func resetConfirmationMessage(for reason: GlobalSettingsPersistenceBlockReason) -> String {
        switch reason {
        case .saveFailed:
            "If retrying after fixing permissions or disk space does not work, RepoPrompt can move the current globalSettings.json to the Backups folder and write your current in-memory settings to a fresh current-schema file. This cannot be undone."
        case .unsupportedFutureSchema, .incompatibleSchema, .corruptUnrecoverable:
            "The current globalSettings.json will be moved to the Backups folder and your current in-memory settings will be written to a fresh current-schema file. Your settings will then save normally. This cannot be undone."
        }
    }

    private func message(for reason: GlobalSettingsPersistenceBlockReason) -> String {
        switch reason {
        case let .unsupportedFutureSchema(onDiskVersion, supportedVersion):
            "Global settings can't be saved: this settings file was written by a newer RepoPrompt CE build (schema v\(onDiskVersion); this build supports v\(supportedVersion)). The file is preserved and won't be modified. Use that newer build, or explicitly reset if you want this build to take over the settings file."
        case .incompatibleSchema:
            "Global settings can't be saved: this settings file was written by a different or unrecognized RepoPrompt settings schema. The file is preserved and won't be modified. Changes won't persist until you import or recover."
        case .corruptUnrecoverable:
            "Global settings can't be saved: the settings file is unreadable and couldn't be backed up. Changes won't persist until you recover."
        case .saveFailed:
            "Global settings can't be saved: RepoPrompt couldn't write globalSettings.json. Check file permissions or available disk space, then try again."
        }
    }

    private func revealGlobalSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([GlobalSettingsFileStore.defaultFileURL()])
    }
}
