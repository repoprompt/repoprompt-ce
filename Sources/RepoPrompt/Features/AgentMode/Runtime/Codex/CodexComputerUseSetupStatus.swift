import Foundation

/// What RepoPrompt can check about Computer Use prerequisites, and honest guidance for what it
/// cannot. Screen Recording and Accessibility are granted to the Codex Computer Use app that the
/// companion relies on, not to RepoPrompt, and macOS does not let one app read another app's
/// privacy grants, so those two permissions are explained and linked rather than detected.
struct CodexComputerUseSetupStatus: Equatable {
    enum CheckState: Equatable {
        case ready
        case checking
        case needsAction
    }

    struct Check: Equatable {
        let title: String
        let state: CheckState
        let detail: String
    }

    let companion: Check
    let runtime: Check

    static let permissionGuidance = "macOS grants Screen Recording and Accessibility to Codex Computer Use, not to RepoPrompt. RepoPrompt cannot read another app's privacy permissions, so check that Codex Computer Use is listed and turned on in both panes. macOS prompts for them the first time Computer Use runs."

    static func evaluate(companionPath: String?, runtimeMessage: String?) -> CodexComputerUseSetupStatus {
        let companion = if companionPath != nil {
            Check(title: "Computer Use companion", state: .ready, detail: "Installed with Codex or ChatGPT.")
        } else {
            Check(
                title: "Computer Use companion",
                state: .needsAction,
                detail: "Not found. Install the Computer Use plugin from the Codex or ChatGPT app, then re-check."
            )
        }
        let runtime = switch runtimeMessage {
        case nil:
            Check(title: "Codex runtime", state: .ready, detail: "OpenAI-signed Codex executable.")
        case CodexComputerUseWorkflow.checkingRuntimeMessage:
            Check(title: "Codex runtime", state: .checking, detail: "Checking the Codex executable signature…")
        case let message?:
            Check(title: "Codex runtime", state: .needsAction, detail: message)
        }
        return CodexComputerUseSetupStatus(companion: companion, runtime: runtime)
    }
}

/// System Settings → Privacy & Security panes that hold the Computer Use grants.
enum CodexComputerUsePrivacyPane: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: String {
        rawValue
    }

    var buttonTitle: String {
        switch self {
        case .screenRecording: "Open Screen Recording Settings"
        case .accessibility: "Open Accessibility Settings"
        }
    }

    /// Pane-specific link first, then the Privacy & Security root as a fallback.
    var settingsURLs: [URL] {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ].compactMap(URL.init(string:))
    }
}
