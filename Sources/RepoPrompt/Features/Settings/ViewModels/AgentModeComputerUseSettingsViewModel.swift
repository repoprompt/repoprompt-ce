import AppKit
import Combine
import Foundation

@MainActor
final class AgentModeComputerUseSettingsViewModel: ObservableObject {
    @Published private(set) var status: CodexComputerUseStatus
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastActionMessage: String?

    private let globalSettings: GlobalSettingsStore
    private let statusService: CodexComputerUseStatusService
    private let openURL: (URL) -> Void
    private let pasteboard: NSPasteboard
    private var refreshGeneration = 0

    init(
        globalSettings: GlobalSettingsStore = .shared,
        statusService: CodexComputerUseStatusService = .shared,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        pasteboard: NSPasteboard = .general
    ) {
        self.globalSettings = globalSettings
        self.statusService = statusService
        self.openURL = openURL
        self.pasteboard = pasteboard
        status = CodexComputerUseWorkflow.currentStatus(
            persistedOptIn: globalSettings.codexComputerUseEnabled(),
            statusService: statusService
        )
    }

    var optInEnabled: Bool {
        globalSettings.codexComputerUseEnabled()
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let refreshed = CodexComputerUseWorkflow.currentStatus(
            persistedOptIn: globalSettings.codexComputerUseEnabled(),
            statusService: statusService
        )
        guard generation == refreshGeneration else { return }
        status = refreshed
        isRefreshing = false
    }

    func setOptInEnabled(_ enabled: Bool) {
        globalSettings.setCodexComputerUseEnabled(enabled)
        refresh()
    }

    func requestScreenRecordingAccess() {
        let result = statusService.requestScreenRecordingAccess()
        lastActionMessage = result.userMessage
        refresh()
    }

    func requestAccessibilityAccess() {
        let result = statusService.requestAccessibilityAccess()
        lastActionMessage = result.userMessage
        refresh()
    }

    func openScreenRecordingSettings() {
        openURL(Self.screenRecordingSettingsURL)
        lastActionMessage = "Opened Screen Recording settings. Grant access, then return to RepoPrompt and refresh status."
    }

    func openAccessibilitySettings() {
        openURL(Self.accessibilitySettingsURL)
        lastActionMessage = "Opened Accessibility settings. Grant access, then return to RepoPrompt and refresh status."
    }

    func openCodexComputerUseGuide() {
        openURL(Self.codexComputerUseDocsURL)
        lastActionMessage = "Opened the Codex Computer Use setup guide."
    }

    func copyManualSetupInstructions(for requirement: CodexComputerUsePrerequisite) {
        let instructions = manualSetupInstructions(for: requirement)
        pasteboard.clearContents()
        pasteboard.setString(instructions, forType: .string)
        lastActionMessage = "Copied setup instructions to the clipboard."
    }

    private func manualSetupInstructions(for requirement: CodexComputerUsePrerequisite) -> String {
        switch requirement {
        case .featureOptIn:
            "Open RepoPrompt Settings → Agent Mode → Computer Use, then enable /computer-use."
        case .plugin, .liveAvailability:
            "Open Codex Settings → Computer Use, install or enable the Computer Use plugin, then return to RepoPrompt Settings → Agent Mode → Computer Use and click Refresh. RepoPrompt detects Codex app-managed Computer Use installs and legacy ~/.codex/config.toml entries; live tool availability may be reported as unknown when Codex does not expose a catalog."
        case .screenRecording:
            "Open System Settings → Privacy & Security → Screen & System Audio Recording (or Screen Recording), grant access to RepoPrompt, Codex, or the helper macOS lists, then restart RepoPrompt/Codex if prompted and click Refresh."
        case .accessibility:
            "Open System Settings → Privacy & Security → Accessibility, grant access to RepoPrompt, Codex, or the helper macOS lists, then click Refresh."
        }
    }

    private static let codexComputerUseDocsURL = URL(string: "https://developers.openai.com/codex/app/computer-use")!
    private static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
