import Foundation

extension Notification.Name {
    static let codexGoalSupportDidChange = Notification.Name("RepoPrompt.codexGoalSupportDidChange")
    static let codexComputerUseAvailabilityDidChange = Notification.Name("RepoPrompt.codexComputerUseAvailabilityDidChange")
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

    @MainActor
    static var disabledMessage: String {
        availability.primaryUnavailableMessage
    }

    @MainActor
    static var availability: CodexComputerUseAvailability {
        CodexComputerUseAvailability(status: currentStatus(includeTimestamp: false))
    }

    @MainActor
    static var isEnabled: Bool {
        availability.isReady
    }

    @MainActor
    static func currentStatus(includeTimestamp: Bool = true) -> CodexComputerUseStatus {
        currentStatus(
            persistedOptIn: GlobalSettingsStore.shared.codexComputerUseEnabled(),
            includeTimestamp: includeTimestamp
        )
    }

    static func currentStatus(
        persistedOptIn: Bool,
        statusService: CodexComputerUseStatusService = .shared,
        includeTimestamp: Bool = true
    ) -> CodexComputerUseStatus {
        let effectiveOptIn = CodexNativeFeatureGate.computerUse.isEnabled(persistedValue: persistedOptIn)
        return statusService.currentStatus(
            optInEnabled: effectiveOptIn,
            includeTimestamp: includeTimestamp
        )
    }

    static func resolvedAvailability(
        persistedOptIn: Bool,
        prerequisites: CodexComputerUsePrerequisiteSnapshot
    ) -> CodexComputerUseAvailability {
        let featureOptIn = CodexNativeFeatureGate.computerUse.isEnabled(persistedValue: persistedOptIn)
        return CodexComputerUseAvailability(
            featureOptIn: featureOptIn,
            prerequisites: prerequisites
        )
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        GlobalSettingsStore.shared.setCodexComputerUseEnabled(enabled)
    }

    static func postAvailabilityDidChangeIfNeeded(previousValue: Bool, currentValue: Bool) {
        guard currentValue != previousValue else { return }
        NotificationCenter.default.post(name: .codexComputerUseAvailabilityDidChange, object: nil)
    }

    static func prerequisiteSnapshot() -> CodexComputerUsePrerequisiteSnapshot {
        CodexComputerUseStatusService.shared.prerequisiteSnapshot()
    }

    #if DEBUG
        static func setEnabledForTesting(_ value: Bool?) {
            CodexNativeFeatureGate.computerUse.setEnabledForTesting(value)
        }

        static func setPrerequisiteSnapshotForTesting(_ snapshot: CodexComputerUsePrerequisiteSnapshot?) {
            CodexComputerUseStatusService.setPrerequisiteSnapshotForTesting(snapshot)
        }
    #endif

    static func bubbleWorkflowDefinition() -> AgentWorkflowDefinition {
        AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "/\(commandName)",
            iconName: "display",
            accentColorHex: "#0EA5E9",
            tooltipText: "Guide Codex through a computer-use workflow",
            descriptionText: "Enables Codex computer-use capabilities for this explicit workflow turn.",
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
        The user explicitly requested a Codex computer-use workflow in RepoPrompt Agent Mode.

        Use Codex's computer-use, tool-search, plugin, and MCP tools only when they are available in this session. If exact computer-use tool names are not already visible, use tool search first; useful searches include "computer use", "browser", "screen", "click", "type", or app/site-specific terms from the user's request. If no computer-use tools are available, say so plainly and ask the user to enable or install the required Codex computer-use capability instead of hallucinating tool calls.

        Safety requirements:
        - Clarify missing target app/site/account, destination, credentials, or intended action before operating.
        - Treat macOS Screen Recording/Accessibility as OS prerequisites only; still ask for app access when Codex prompts for an allowed target app.
        - Do not treat RepoPrompt MCP auto-approval as approval for non-RepoPrompt MCP, plugin, browser, or computer-use tools.
        - Keep RepoPrompt workspace file edits and shell commands under the session's sandbox/approval policy; desktop app actions are a separate surface.
        - Ask for explicit confirmation before destructive, purchasing, sending, publishing, account-changing, or otherwise externally visible actions.
        - Prefer non-destructive inspection and reporting before taking action.

        <user_instructions>
        \(instructionBlock)
        </user_instructions>
        </computer_use_workflow>
        """
    }
}
