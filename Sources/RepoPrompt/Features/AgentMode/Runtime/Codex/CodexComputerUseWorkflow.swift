import Foundation
import OSLog
import RepoPromptSettingsCore

extension Notification.Name {
    static let codexGoalSupportDidChange = Notification.Name("RepoPrompt.codexGoalSupportDidChange")
    static let codexComputerUseDidChange = Notification.Name("RepoPrompt.codexComputerUseDidChange")
}

private enum CodexNativeFeatureGate: Hashable {
    case goals
    case computerUse

    private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]

    #if DEBUG
        private static let testingOverrideLock = NSLock()
        private static var testingOverrideEnabledByGate: [CodexNativeFeatureGate: Bool] = [:]
    #endif

    var defaultsKey: String {
        switch self {
        case .goals:
            "enableCodexGoalSupport"
        case .computerUse:
            "enableCodexComputerUse"
        }
    }

    private var environmentKey: String {
        switch self {
        case .goals:
            "RP_CODEX_GOALS"
        case .computerUse:
            "RP_CODEX_COMPUTER_USE"
        }
    }

    private var defaultPersistedValue: Bool {
        switch self {
        case .goals:
            true
        case .computerUse:
            false
        }
    }

    func isEnabled(defaults: UserDefaults) -> Bool {
        isEnabled(persistedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }

    func isEnabled(persistedValue: Bool) -> Bool {
        isEnabled(persistedValue: Optional(persistedValue))
    }

    func isEnabled(persistedValue: Bool?) -> Bool {
        #if DEBUG
            if let override = testingOverride {
                return override
            }
        #endif
        return (persistedValue ?? defaultPersistedValue) || environmentFlagEnabled
    }

    func setEnabled(_ value: Bool, defaults: UserDefaults) {
        defaults.set(value, forKey: defaultsKey)
    }

    #if DEBUG
        func setEnabledForTesting(_ value: Bool?) {
            Self.testingOverrideLock.lock()
            if let value {
                Self.testingOverrideEnabledByGate[self] = value
            } else {
                Self.testingOverrideEnabledByGate[self] = nil
            }
            Self.testingOverrideLock.unlock()
        }

        private var testingOverride: Bool? {
            Self.testingOverrideLock.lock()
            defer { Self.testingOverrideLock.unlock() }
            return Self.testingOverrideEnabledByGate[self]
        }
    #endif

    private var environmentFlagEnabled: Bool {
        let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return rawValue.map { Self.enabledEnvironmentValues.contains($0) } ?? false
    }
}

enum CodexGoalSupport {
    static let disabledMessage = "Codex goal support is turned off. Re-enable Codex Goals in settings or set app_settings key 'agent_mode.codex_goal_support_enabled' to true to use /goal."

    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexGoalSupportEnabled()
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        CodexNativeFeatureGate.goals.isEnabled(defaults: defaults)
    }

    static func isEnabled(persistedValue: Bool) -> Bool {
        CodexNativeFeatureGate.goals.isEnabled(persistedValue: persistedValue)
    }

    static func isEnabled(persistedValue: Bool?) -> Bool {
        CodexNativeFeatureGate.goals.isEnabled(persistedValue: persistedValue)
    }

    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        let oldValue = isEnabled(defaults: defaults)
        CodexNativeFeatureGate.goals.setEnabled(value, defaults: defaults)
        postDidChangeIfNeeded(previousValue: oldValue, currentValue: isEnabled(defaults: defaults))
    }

    static func postDidChangeIfNeeded(previousValue: Bool, currentValue: Bool) {
        guard currentValue != previousValue else { return }
        NotificationCenter.default.post(name: .codexGoalSupportDidChange, object: nil)
    }

    #if DEBUG
        static func setEnabledForTesting(_ value: Bool?) {
            CodexNativeFeatureGate.goals.setEnabledForTesting(value)
        }
    #endif
}

enum CodexComputerUseWorkflow {
    static let commandName = "computer-use"
    static let disabledMessage = "Computer Use is turned off. Enable Computer Use in Codex Direct Agent permissions, then submit /computer-use. macOS permissions must be granted manually."
    static let unavailableMessage = "Computer Use requires the installed SkyComputerUseClient companion from Codex or ChatGPT. No companion is available; this turn cannot use computer-use tools."
    static let collisionMessage = "Computer Use cannot start because the RepoPrompt-owned Codex runtime already contains a reserved 'computer-use' MCP entry. Review and manually remove or rename that entry in the owned runtime configuration, then retry. RepoPrompt will not rewrite it or import personal Codex configuration."
    static let ineligibleMessage = "Computer Use is only available in user-created, top-level native Codex sessions without MCP control or active session links."

    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexComputerUseEnabled()
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        CodexNativeFeatureGate.computerUse.isEnabled(defaults: defaults)
    }

    static func isEnabled(persistedValue: Bool?) -> Bool {
        CodexNativeFeatureGate.computerUse.isEnabled(persistedValue: persistedValue)
    }

    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        let oldValue = isEnabled(defaults: defaults)
        CodexNativeFeatureGate.computerUse.setEnabled(value, defaults: defaults)
        postDidChangeIfNeeded(previousValue: oldValue, currentValue: isEnabled(defaults: defaults))
    }

    static func postDidChangeIfNeeded(previousValue: Bool, currentValue: Bool) {
        guard currentValue != previousValue else { return }
        NotificationCenter.default.post(name: .codexComputerUseDidChange, object: nil)
    }

    #if DEBUG
        static func setEnabledForTesting(_ value: Bool?) {
            CodexNativeFeatureGate.computerUse.setEnabledForTesting(value)
        }
    #endif

    private static let approvalLogger = Logger(subsystem: "com.repoprompt.agents", category: "CodexComputerUse")

    enum ApprovalDecisionPath: String {
        case mcpElicitation
        case permissions
        case approval
        case requestUserInput
        case other
    }

    static func logApprovalDecision(path: ApprovalDecisionPath, server: String?, armed: Bool, approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy, sandboxMode: CodexAgentToolPreferences.SandboxMode, outcome: String) {
        guard armed else { return }
        let server = server ?? "unspecified"
        let mode = approvalPolicy.persistedValue + "/" + sandboxMode.persistedValue
        approvalLogger.notice("Computer Use approval path=\(path.rawValue, privacy: .public) server=\(server, privacy: .private) armed=true mode=\(mode, privacy: .public) outcome=\(outcome, privacy: .public)")
    }

    static func automaticallyApprovesCompanion(
        armed: Bool,
        approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy,
        sandboxMode: CodexAgentToolPreferences.SandboxMode
    ) -> Bool {
        armed && approvalPolicy == .never && sandboxMode == .dangerFullAccess
    }

    static func isOffCommand(argumentsText: String) -> Bool {
        argumentsText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off"
    }

    static func bubbleWorkflowDefinition() -> AgentWorkflowDefinition {
        AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "/\(commandName)",
            iconName: "cursorarrow",
            accentColorHex: "#0EA5E9",
            tooltipText: "Guide Codex through a computer-use workflow",
            descriptionText: "Arms Computer Use for this chat until /computer-use off or the session ends.",
            template: nil
        )
    }

    static func renderProviderPrompt(userInstructions: String) -> String {
        let trimmedInstructions = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionBlock = trimmedInstructions.isEmpty
            ? "Ask the user what app, site, account, and action they want to automate before using computer-use tools."
            : trimmedInstructions

        return """
        <computer_use_workflow>
        The user explicitly armed Computer Use for this chat in RepoPrompt Agent Mode. It remains available for later local-user turns until /computer-use off or the session ends.

        Use the installed computer-use companion's MCP tools only when they are available in this session. Do not install or enable plugins, browser integrations, or app connectors for this workflow. If exact computer-use tool names are not already visible, use tool search first; useful searches include "computer use", "browser", "screen", "click", "type", or app/site-specific terms from the user's request. If no computer-use tools are available, say so plainly and ask the user to enable or install the required Codex computer-use capability instead of hallucinating tool calls.

        Safety requirements:
        - Clarify missing target app/site/account, destination, credentials, or intended action before operating.
        - Ask for explicit confirmation before destructive, purchasing, sending, publishing, account-changing, or otherwise externally visible actions.
        - Do not treat RepoPrompt MCP auto-approval as approval for non-RepoPrompt MCP, plugin, browser, or computer-use tools.
        - Keep RepoPrompt workspace file edits separate from external UI automation; explain which surface you are acting on.
        - Prefer non-destructive inspection and reporting before taking action.

        <user_instructions>
        \(instructionBlock)
        </user_instructions>
        </computer_use_workflow>
        """
    }
}
