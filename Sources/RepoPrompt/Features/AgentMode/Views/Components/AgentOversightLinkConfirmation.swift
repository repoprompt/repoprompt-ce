import AppKit
import Foundation
import RepoPromptDomainRuntime

/// The shared UI confirmation gate for user-created oversight links.
///
/// Exactly one gate covers every UI entry point that creates a link — the sidebar Oversee-by and
/// Oversee menus, both Session-ID sheets, and the Oversee pill's submit — because the gate lives
/// in the UI layer, not in `AgentSessionLinkRuntimeBridge.addMonitorLink`, which also serves
/// launch restoration and overseer-created lanes that must not prompt. Undo is a user-approved
/// exception and does not call this gate.
///
/// The gate only explains the delegation. It writes one app-global suppression flag on accepted
/// confirmations, never on Cancel/dismiss, and it never relaxes runtime authorization.
@MainActor
enum AgentOversightLinkConfirmation {
    /// Whether the dialog must be shown for this request right now. `nil` resolves to the shared
    /// store — defaulting at the call site keeps Swift 6's default-arg isolation rules happy.
    static func isSuppressed(settings: GlobalSettingsStore? = nil) -> Bool {
        (settings ?? .shared).suppressOversightLinkConfirmation()
    }

    /// Applies the dialog outcome to persisted state. Only an *accepted* confirmation with the
    /// suppression box checked writes the flag; every other path leaves settings untouched.
    static func recordOutcome(
        accepted: Bool,
        suppressionChecked: Bool,
        settings: GlobalSettingsStore? = nil
    ) {
        guard accepted, suppressionChecked else { return }
        (settings ?? .shared).setSuppressOversightLinkConfirmation(true)
    }

    /// Presents the confirmation unless suppressed. Returns `true` when the link may proceed —
    /// either because the user allowed it or because they previously chose "Don't ask again".
    ///
    /// - Parameter windowID: the logical RepoPrompt window owning the initiating control; the alert
    ///   presents as a sheet there and falls back to an app-modal panel when the window is gone.
    static func confirm(
        observerLabel: String,
        targetLabel: String,
        windowID: Int?,
        settings: GlobalSettingsStore? = nil
    ) async -> Bool {
        let settings = settings ?? .shared
        guard !isSuppressed(settings: settings) else { return true }

        let alert = NSAlert()
        alert.messageText = AgentOversightUICopy.confirmationTitle(
            observer: observerLabel,
            target: targetLabel
        )
        alert.informativeText = AgentOversightUICopy.confirmationBody(
            observer: observerLabel,
            target: targetLabel
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: AgentOversightUICopy.confirmationAllowButton)
        alert.addButton(withTitle: AgentOversightUICopy.confirmationCancelButton)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = AgentOversightUICopy.confirmationSuppressionCheckbox

        let response = await presentAlert(alert, windowID: windowID)
        let accepted = response == .alertFirstButtonReturn
        recordOutcome(
            accepted: accepted,
            suppressionChecked: alert.suppressionButton?.state == .on,
            settings: settings
        )
        return accepted
    }

    /// Sheets onto the owning window when it can host one; falls back to an app-modal panel so the
    /// gate still holds above a Session-ID sheet or after the window went away.
    private static func presentAlert(
        _ alert: NSAlert,
        windowID: Int?
    ) async -> NSApplication.ModalResponse {
        let window = AgentSessionLinkRuntimeBridge.shared
            .agentSessionLinkSheetWindow(windowID: windowID)
        guard let window, !window.isSheet, window.attachedSheet == nil else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { sheetResponse in
                continuation.resume(returning: sheetResponse)
            }
        }
    }
}
