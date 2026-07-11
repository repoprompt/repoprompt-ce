//
//  AgentOnboardingWizardViewModel.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2026-02-05.
//

import AppKit
import Combine
import Foundation

// MARK: - Onboarding Step

/// Identifies steps in the Agent Mode onboarding wizard.
/// Identifies steps in the Agent Mode onboarding wizard.
enum AgentOnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case agentModeIntro
    case contextBuilder
    case mcpSetup
    case providers
    case completion

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .welcome: "Welcome to RepoPrompt"
        case .agentModeIntro: "Agent Mode"
        case .contextBuilder: "Context Builder"
        case .mcpSetup: "MCP Server & Tools"
        case .providers: "CLI Providers"
        case .completion: "You're All Set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "Your AI-powered context workspace"
        case .agentModeIntro: "AI agents with full context"
        case .contextBuilder: "Smart context, automatically"
        case .mcpSetup: "Optional — only needed for external MCP clients"
        case .providers: "Connect your tools"
        case .completion: "Let's go!"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "sparkles"
        case .agentModeIntro: "terminal"
        case .contextBuilder: "doc.text.magnifyingglass"
        case .mcpSetup: "server.rack"
        case .providers: "link.circle"
        case .completion: "checkmark.seal.fill"
        }
    }
}

// MARK: - Agent Onboarding Wizard ViewModel

@MainActor
final class AgentOnboardingWizardViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var steps: [AgentOnboardingStep] = []
    @Published var currentStepIndex: Int = 0
    @Published private(set) var providerStatus: ProviderStatusSnapshot?

    // Inline provider testing
    @Published var isLoadingClaudeCode = false
    @Published var isLoadingCodex = false
    @Published var isLoadingOpenCode = false
    @Published var isLoadingCursor = false

    // MCP & CLI installers
    @Published var cliInstallStatus: CLIPathInstaller.InstallationStatus = .notInstalled
    @Published var claudeRPInstallStatus: CLIPathInstaller.ClaudeRPInstallationStatus = .notInstalled
    @Published var installFeedback: String?
    @Published var installFeedbackIsError = false

    // MARK: - Dependencies

    private let engine: AutoRecommendationEngine
    private weak var apiSettingsViewModel: APISettingsViewModel?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var currentStep: AgentOnboardingStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var progressText: String {
        guard !steps.isEmpty else { return "" }
        return "Step \(currentStepIndex + 1) of \(steps.count)"
    }

    var progressFraction: Double {
        guard steps.count > 1 else { return 0 }
        return Double(currentStepIndex) / Double(steps.count - 1)
    }

    var canGoBack: Bool {
        currentStepIndex > 0
    }

    var isLastStep: Bool {
        currentStepIndex == steps.count - 1
    }

    // MARK: - Initialization

    init(
        engine: AutoRecommendationEngine,
        apiSettingsViewModel: APISettingsViewModel?
    ) {
        self.engine = engine
        self.apiSettingsViewModel = apiSettingsViewModel

        refreshProviderStatus()
        rebuildSteps()
        setupSubscriptions()
    }

    // MARK: - Subscriptions

    private func setupSubscriptions() {
        // React to provider connection changes
        if let api = apiSettingsViewModel {
            Publishers.MergeMany(
                api.$isClaudeCodeConnected.map { _ in () },
                api.$isCodexConnected.map { _ in () },
                api.$isOpenCodeConnected.map { _ in () },
                api.$isCursorConnected.map { _ in () },
                api.$isOpenAIKeyValid.map { _ in () }
            )
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshProviderStatus()
            }
            .store(in: &cancellables)
        }
    }

    // MARK: - Refresh

    func refreshProviderStatus() {
        providerStatus = engine.computeProviderStatus()
    }

    /// CE flow: welcome → agent mode → context builder → providers → mcp setup (optional) → completion
    private func rebuildSteps() {
        let previousStep = currentStep

        steps = [
            .welcome,
            .agentModeIntro,
            .contextBuilder,
            .providers,
            .mcpSetup,
            .completion
        ]

        // Preserve position if possible
        if let prev = previousStep, let idx = steps.firstIndex(of: prev) {
            currentStepIndex = idx
        } else if currentStepIndex >= steps.count {
            currentStepIndex = steps.count - 1
        }
    }

    // MARK: - Navigation

    /// Reset wizard to the first step, refreshing provider state.
    func resetToStart() {
        refreshProviderStatus()
        rebuildSteps()
        currentStepIndex = 0
    }

    func nextStep() {
        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
        }
    }

    func previousStep() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }

    func goToStep(_ step: AgentOnboardingStep) {
        if let index = steps.firstIndex(of: step) {
            currentStepIndex = index
        }
    }

    // MARK: - Inline Provider Testing

    var claudeCodeConnected: Bool {
        apiSettingsViewModel?.isClaudeCodeConnected ?? false
    }

    var codexConnected: Bool {
        apiSettingsViewModel?.isCodexConnected ?? false
    }

    var openCodeConnected: Bool {
        apiSettingsViewModel?.isOpenCodeConnected ?? false
    }

    var cursorConnected: Bool {
        apiSettingsViewModel?.isCursorConnected ?? false
    }

    var claudeCodeError: String? {
        apiSettingsViewModel?.claudeCodeError
    }

    var codexError: String? {
        apiSettingsViewModel?.codexError
    }

    var openCodeError: String? {
        apiSettingsViewModel?.openCodeError
    }

    var cursorError: String? {
        apiSettingsViewModel?.cursorError
    }

    func testClaudeCode() {
        isLoadingClaudeCode = true
        Task {
            do {
                _ = try await apiSettingsViewModel?.testClaudeCodeConnection()
            } catch {
                // Error state is set on apiSettingsViewModel
            }
            isLoadingClaudeCode = false
            refreshProviderStatus()
        }
    }

    func testCodex() {
        isLoadingCodex = true
        Task {
            do {
                _ = try await apiSettingsViewModel?.testCodexConnection()
            } catch {
                // Error state is set on apiSettingsViewModel
            }
            isLoadingCodex = false
            refreshProviderStatus()
        }
    }

    func testOpenCode() {
        isLoadingOpenCode = true
        Task {
            do {
                _ = try await apiSettingsViewModel?.testOpenCodeConnection()
            } catch {
                // Error state is set on apiSettingsViewModel
            }
            isLoadingOpenCode = false
            refreshProviderStatus()
        }
    }

    func testCursor() {
        isLoadingCursor = true
        Task {
            do {
                _ = try await apiSettingsViewModel?.testCursorConnection()
            } catch {
                // Error state is set on apiSettingsViewModel
            }
            isLoadingCursor = false
            refreshProviderStatus()
        }
    }

    // MARK: - MCP & CLI Installers

    func refreshInstallStatuses() {
        cliInstallStatus = MCPIntegrationHelper.cliPathInstallStatus()
        claudeRPInstallStatus = CLIPathInstaller.checkClaudeRPStatus()
    }

    func installMCPServer(in client: String) {
        switch client {
        case "Cursor":
            MCPIntegrationHelper.installInCursor()
            showInstallFeedback("Cursor configured")
        case "VS Code":
            MCPIntegrationHelper.installInVSCode()
            showInstallFeedback("VS Code configured")
        case "Codex CLI":
            let result = MCPIntegrationHelper.installInCodex()
            showInstallFeedback(result.success ? (result.wasAlreadyPresent ? "Codex already configured" : "Codex configured") : "Codex config failed", isError: !result.success)
        case "OpenCode":
            let result = MCPIntegrationHelper.installInOpenCode()
            showInstallFeedback(result.success ? (result.wasAlreadyPresent ? "OpenCode already configured" : "OpenCode configured") : "OpenCode config failed", isError: !result.success)
        case "Claude Desktop":
            let success = MCPIntegrationHelper.installInClaude()
            showInstallFeedback(success ? "Claude Desktop configured" : "Claude Desktop not found", isError: !success)
        case "Claude Code":
            Task {
                let result = await MCPIntegrationHelper.installInClaudeCode(workspacePath: nil)
                if result.success {
                    showInstallFeedback("Claude Code configured")
                } else {
                    showInstallFeedback(result.errorMessage ?? "Claude Code install failed", isError: true)
                }
            }
        default:
            return
        }
    }

    func installCLI() {
        Task {
            do {
                try await MCPIntegrationHelper.installCLIToPath()
                refreshInstallStatuses()
                showInstallFeedback("\(MCPIntegrationHelper.cliCommandName) installed")
            } catch {
                showInstallFeedback("Install failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func installClaudeRP() {
        Task {
            do {
                try await CLIPathInstaller.installClaudeRP()
                refreshInstallStatuses()
                showInstallFeedback("\(CLIPathInstaller.claudeRPCommandName) installed")
            } catch {
                showInstallFeedback("Install failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func installGlobalSkills() {
        let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: false)
        showInstallFeedback(count > 0 ? "Skills installed to ~/.agents/skills" : "Install failed", isError: count == 0)
    }

    func installCodexSkills() {
        let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: false)
        showInstallFeedback(count > 0 ? "Codex skills installed" : "Install failed", isError: count == 0)
    }

    func showInstallFeedbackPublic(_ message: String, isError: Bool = false) {
        showInstallFeedback(message, isError: isError)
    }

    private func showInstallFeedback(_ message: String, isError: Bool = false) {
        installFeedback = message
        installFeedbackIsError = isError
        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.installFeedback == message {
                self?.installFeedback = nil
            }
        }
    }

    func openMCPServerPopover(windowID: Int? = nil) {
        var userInfo: [String: Any] = [:]
        if let id = windowID {
            userInfo["windowID"] = id
        }
        NotificationCenter.default.post(name: .showMCPServerPopover, object: nil, userInfo: userInfo)
    }

    // MARK: - Deep-Link Helpers

    func openCLIProviders(windowID: Int? = nil) {
        var userInfo: [String: Any] = [:]
        if let id = windowID {
            userInfo["windowID"] = id
        }
        NotificationCenter.default.post(name: .showCLIProvidersTab, object: nil, userInfo: userInfo)
    }

    func openMCPSettings(windowID: Int? = nil) {
        var userInfo: [String: Any] = [:]
        if let id = windowID {
            userInfo["windowID"] = id
        }
        NotificationCenter.default.post(name: .showMCPSettingsTab, object: nil, userInfo: userInfo)
    }

    func openContextBuilderSettings(windowID: Int? = nil) {
        var userInfo: [String: Any] = [:]
        if let id = windowID {
            userInfo["windowID"] = id
        }
        NotificationCenter.default.post(name: .showContextBuilderSettingsTab, object: nil, userInfo: userInfo)
    }

    func openUpdatesSettings(windowID: Int? = nil) {
        var userInfo: [String: Any] = [:]
        if let id = windowID {
            userInfo["windowID"] = id
        }
        NotificationCenter.default.post(name: .showLicenseUpdatesTab, object: nil, userInfo: userInfo)
    }

    func openDocsPage() {
        if let url = URL(string: "https://repoprompt.com/docs") {
            NSWorkspace.shared.open(url)
        }
    }

    func openWorkflowDocs() {
        if let url = URL(string: "https://repoprompt.com/docs#s=workflows") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Completion

    func markOnboardingSeen() {
        AgentOnboardingGate.markSeen()
    }
}
