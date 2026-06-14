import Foundation

// Import AIModel for type-safe model references

// MARK: - Provider Flags Helper

/// Helper struct to expose provider status from APISettingsViewModel.
struct ProviderFlags {
    let hasOpenAIKey: Bool
    let openAIValid: Bool
    let claudeCodeConnected: Bool
    let codexConnected: Bool
    let cursorConnected: Bool
}

// MARK: - Auto Recommendation Engine

/// Core logic service that detects provider availability and computes recommendations.
/// Does NOT perform network calls - only consults existing flags and settings.
@MainActor
final class AutoRecommendationEngine {
    // MARK: - Dependencies

    private let settingsStore: GlobalSettingsStore
    private(set) weak var apiSettingsViewModel: APISettingsViewModel?

    // MARK: - Constants

    /// How long before wizard completion expires (3 days).
    private let completionRecencyInterval: TimeInterval = 3 * 24 * 60 * 60

    // MARK: - Initialization

    init(
        settingsStore: GlobalSettingsStore,
        apiSettingsViewModel: APISettingsViewModel
    ) {
        self.settingsStore = settingsStore
        self.apiSettingsViewModel = apiSettingsViewModel

        // Ensure schema version is up to date on init
        settingsStore.ensureLatestRecommendationSchema(currentVersion: BestPracticeProfiles.versionCode)
    }

    // MARK: - Provider Status

    /// Compute provider status snapshot without network calls.
    func computeProviderStatus() -> ProviderStatusSnapshot {
        guard let vm = apiSettingsViewModel else {
            return ProviderStatusSnapshot(
                claudeCodeCLI: .notConfigured,
                codexCLI: .notConfigured,
                cursorCLI: .notConfigured,
                openAI: .notConfigured
            )
        }

        return vm.recommendationProviderStatusSnapshot
    }

    /// Get provider flags from APISettingsViewModel.
    func getProviderFlags() -> ProviderFlags? {
        guard let vm = apiSettingsViewModel else { return nil }
        return ProviderFlags(
            hasOpenAIKey: !vm.openAIApiKey.isEmpty,
            openAIValid: vm.isOpenAIKeyValid,
            claudeCodeConnected: vm.isClaudeCodeConnected,
            codexConnected: vm.isCodexConnected,
            cursorConnected: vm.isCursorConnected
        )
    }

    // MARK: - Compute Recommendations

    /// Compute all recommendations for a workspace.
    /// Only returns recommendations where current settings differ from the recommended configuration.
    func computeRecommendations(
        for workspaceID: UUID,
        enabledProviders: Set<RecommendationProviderKind> = Set(RecommendationProviderKind.allCases)
    ) -> RecommendationSet {
        let actualStatus = computeProviderStatus()
        let status = actualStatus.filtered(to: enabledProviders)
        let settings = settingsStore.chatSettings(for: workspaceID)

        var result = RecommendationSet()

        // Chat Model Recommendation
        if var chatRec = computeChatModelRecommendation(status: status) {
            chatRec.alreadySatisfied = isChatModelAlreadyConfigured(chatRec)
            result.chatModel = chatRec
        }

        // Context Builder Recommendation
        if var cbRec = computeContextBuilderRecommendation(status: status, settings: settings) {
            cbRec.alreadySatisfied = isContextBuilderAlreadyConfigured(cbRec, settings: settings)
            result.contextBuilder = cbRec
        }

        // MCP Preset Exposure Recommendation
        if var mcpRec = computeMCPPresetExposureRecommendation() {
            mcpRec.alreadySatisfied = isMCPPresetExposureAlreadyConfigured(mcpRec)
            result.mcpPresetExposure = mcpRec
        }

        // MCP Agent Defaults Recommendation
        if status.hasAnyCLIAgentReady, let agentRec = computeMCPAgentDefaultsRecommendation(
            workspaceID: workspaceID,
            actualStatus: actualStatus,
            recommendedStatus: status
        ) {
            result.mcpAgentDefaults = agentRec
        }

        return result
    }

    // MARK: - Chat Model Recommendation

    private func computeChatModelRecommendation(status: ProviderStatusSnapshot) -> ChatModelRecommendation? {
        let inAppPlanning = BestPracticeProfiles.bestInAppPlanningReview
        let bestPlanning = BestPracticeProfiles.bestPlanning
        let apiPlanningModelString = AIModel.gpt54Pro.rawValue
        let apiPlanningModelLabel = AIModel.gpt54Pro.displayName

        // Build available options
        var codexOption: ChatBackendOption?
        var openAIOption: ChatBackendOption?
        var claudeCodeOption: ChatBackendOption?

        // Codex CLI option - PREFERRED for chat
        if status.codexCLI == .ready {
            codexOption = ChatBackendOption(
                kind: .codex,
                displayName: "Codex CLI (Recommended)",
                modelString: inAppPlanning.modelString,
                description: "\(inAppPlanning.modelLabel) – strong reasoning with practical limits",
                tradeoffs: [
                    "• Strong reasoning without extended wait times",
                    "• Won't exhaust weekly usage limits quickly",
                    "• XHigh available for complex tasks when needed"
                ]
            )
        }

        // OpenAI API option - shows reasoning but higher cost. GPT-5.5 Pro is a ChatGPT Pro export/planning recommendation,
        // not an OpenAI API model in RepoPrompt's guidance.
        if status.openAI == .ready {
            openAIOption = ChatBackendOption(
                kind: .openAI,
                displayName: "OpenAI API",
                modelString: apiPlanningModelString,
                description: "\(apiPlanningModelLabel) via API – use \(bestPlanning.modelLabel) through ChatGPT Pro export/planning",
                tradeoffs: [
                    "• API-backed planning and review when Codex CLI is unavailable",
                    "• Visible reasoning traces",
                    "• GPT-5.5 is Codex CLI / ChatGPT Pro guidance, not an API availability claim"
                ]
            )
        }

        // Claude Code CLI option - use Opus for chat (great at editing/context)
        if status.claudeCodeCLI == .ready {
            claudeCodeOption = ChatBackendOption(
                kind: .claudeCode,
                displayName: "Claude Code",
                modelString: AIModel.claudeCodeOpus.rawValue, // Opus for chat
                description: "Claude Opus 4.6 – great for editing and context management",
                tradeoffs: [
                    "• Excellent at file editing and code modifications",
                    "• Superior context window management",
                    "• Strong alternative to Codex for agentic tasks"
                ]
            )
        }

        // Determine default backend and upgrade hint
        // Priority for CHAT: Codex CLI > OpenAI API > Claude Code
        let defaultBackend: ChatBackendKind
        var priorityPath: [String] = []
        var upgradeHint: String? = nil

        if codexOption != nil {
            defaultBackend = .codex
            priorityPath = ["Codex CLI (\(inAppPlanning.modelLabel))", "OpenAI API", "Claude Code"]
        } else if openAIOption != nil {
            defaultBackend = .openAI
            priorityPath = ["OpenAI API (\(apiPlanningModelLabel))", "Claude Code"]
            upgradeHint = "Connect Codex CLI for \(inAppPlanning.modelLabel) – strong reasoning with practical usage limits (requires OpenAI Plus/Pro)."
        } else if claudeCodeOption != nil {
            defaultBackend = .claudeCode
            priorityPath = ["Claude Code"]
            upgradeHint = "For best chat experience, connect Codex CLI (requires OpenAI Plus/Pro) for \(inAppPlanning.modelLabel) – balances quality with usage limits."
        } else {
            return nil
        }

        return ChatModelRecommendation(
            defaultBackend: defaultBackend,
            codexOption: codexOption,
            openAIOption: openAIOption,
            claudeCodeOption: claudeCodeOption,
            priorityPath: priorityPath,
            upgradeHint: upgradeHint
        )
    }

    // MARK: - Free Tier Chat Model Recommendation

    /// Compute chat model recommendation for CE users.
    /// Priority: Claude Code > Codex CLI > OpenAI API
    private func computeFreeTierChatModelRecommendation(status: ProviderStatusSnapshot) -> ChatModelRecommendation? {
        var claudeCodeOption: ChatBackendOption?
        var codexOption: ChatBackendOption?
        var openAIOption: ChatBackendOption?

        // Priority 1: Claude Code CLI
        if status.claudeCodeCLI == .ready {
            claudeCodeOption = ChatBackendOption(
                kind: .claudeCode,
                displayName: "Claude Code CLI (Recommended)",
                modelString: AIModel.claudeCodeSonnet.rawValue,
                description: "Claude Sonnet via Claude Code CLI",
                tradeoffs: [
                    "• Excellent chat and editing capabilities",
                    "• Good balance of speed and quality",
                    "• Uses your Claude Code subscription"
                ]
            )
        }

        // Priority 2: Codex CLI
        if status.codexCLI == .ready {
            codexOption = ChatBackendOption(
                kind: .codex,
                displayName: "Codex CLI",
                modelString: AIModel.codexCliGpt55CodexMedium.rawValue,
                description: "GPT-5.5 Medium via Codex CLI",
                tradeoffs: [
                    "• Superior reasoning capabilities",
                    "• Excellent for complex tasks",
                    "• Uses your Codex subscription"
                ]
            )
        }

        // Priority 4: OpenAI API
        if status.openAI == .ready {
            openAIOption = ChatBackendOption(
                kind: .openAI,
                displayName: "OpenAI API",
                modelString: AIModel.gpt54.rawValue,
                description: "GPT-5.4 via OpenAI API",
                tradeoffs: [
                    "• Superior reasoning capabilities",
                    "• Pay-per-use pricing",
                    "• Direct API access"
                ]
            )
        }

        // Determine default backend based on priority
        let defaultBackend: ChatBackendKind
        var priorityPath: [String] = []

        if claudeCodeOption != nil {
            defaultBackend = .claudeCode
            priorityPath.append("Claude Code CLI")
        } else if codexOption != nil {
            defaultBackend = .codex
            priorityPath.append("Codex CLI")
        } else if openAIOption != nil {
            defaultBackend = .openAI
            priorityPath.append("OpenAI API")
        } else {
            // No suitable providers available
            return nil
        }

        return ChatModelRecommendation(
            defaultBackend: defaultBackend,
            codexOption: codexOption,
            openAIOption: openAIOption,
            claudeCodeOption: claudeCodeOption,
            priorityPath: priorityPath,
            upgradeHint: nil
        )
    }

    // MARK: - Context Builder Recommendation

    private func computeContextBuilderRecommendation(
        status: ProviderStatusSnapshot,
        settings _: ChatGlobalSettings
    ) -> ContextBuilderRecommendation? {
        Self.contextBuilderRecommendation(status: status)
    }

    /// Shared Context Builder recommendation ranking used by both the wizard and startup restore.
    /// Keeping this pure prevents startup fallback behavior from drifting from the recommendation UI.
    static func contextBuilderRecommendation(
        status: ProviderStatusSnapshot
    ) -> ContextBuilderRecommendation? {
        // Priority: Codex CLI (requires CLI) > Claude Code > Cursor CLI
        // Cursor is a fallback only; it does not take priority over existing recommended providers.
        // Note: codexExec agent requires Codex CLI specifically, not just OpenAI API key
        if status.codexCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .codexExec,
                recommendedModel: .gpt55CodexLow,
                rationale: BestPracticeProfiles.contextBuilderRationale
            )
        } else if status.claudeCodeCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .claudeCode,
                recommendedModel: .claudeSonnet,
                rationale: "Claude Code with Sonnet provides strong context building with good balance of speed and quality.",
                upgradeHint: "For best context building, connect Codex CLI with GPT-5.5 Low. Requires OpenAI Plus/Pro subscription."
            )
        } else if status.cursorCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .cursor,
                recommendedModel: .cursorComposer2,
                rationale: "Cursor CLI with Composer 2 can handle context building when the preferred Codex or Claude Code providers are not configured.",
                upgradeHint: "For best context building, connect Codex CLI with GPT-5.5 Low or Claude Code with Sonnet."
            )
        }

        return nil
    }

    /// Restores a saved Context Builder selection only when both provider and model are currently usable.
    /// Invalid or unavailable persisted values fall back through the same recommendation ranking as the wizard.
    static func resolveContextBuilderSelection(
        persistedAgentRaw: String?,
        persistedModelRaw: String?,
        availability: AgentModelCatalog.AvailabilityContext,
        enabledRecommendationProviders: Set<RecommendationProviderKind> = Set(RecommendationProviderKind.allCases)
    ) -> AgentModelCatalog.NormalizedAgentSelection? {
        if let agentRaw = persistedAgentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           let modelRaw = persistedModelRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           let agent = AgentProviderKind(rawValue: agentRaw),
           !modelRaw.isEmpty,
           AgentModelCatalog.isAgentAvailable(agent, availability: availability),
           isValidPersistedContextBuilderModel(modelRaw, for: agent, availability: availability)
        {
            return AgentModelCatalog.normalizeSelection(
                agentRaw: agent.rawValue,
                modelRaw: modelRaw,
                availability: availability
            )
        }

        let status = ProviderStatusSnapshot(
            claudeCodeCLI: availability.claudeCodeAvailable ? .ready : .notConfigured,
            codexCLI: availability.codexAvailable ? .ready : .notConfigured,
            cursorCLI: availability.cursorAvailable ? .ready : .notConfigured,
            openAI: .notConfigured
        ).filtered(to: enabledRecommendationProviders)
        if let recommendation = contextBuilderRecommendation(status: status) {
            return AgentModelCatalog.normalizeSelection(
                agentRaw: recommendation.recommendedAgent.rawValue,
                modelRaw: recommendation.recommendedModel.rawValue,
                availability: availability
            )
        }

        guard let availableAgent = AgentModelCatalog.selectableAgents(availability: availability).first(where: {
            switch $0 {
            case .claudeCode:
                enabledRecommendationProviders.contains(.claudeCode)
            case .codexExec:
                enabledRecommendationProviders.contains(.codex)
            case .cursor:
                enabledRecommendationProviders.contains(.cursor)
            case .openCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
                true
            }
        }) else {
            return nil
        }
        return AgentModelCatalog.normalizeSelection(
            agentRaw: availableAgent.rawValue,
            modelRaw: nil,
            availability: availability
        )
    }

    private static func isValidPersistedContextBuilderModel(
        _ rawModel: String,
        for agent: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> Bool {
        if agent == .openCode,
           rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
           .caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        {
            return true
        }
        return AgentModelCatalog.isValid(rawModel: rawModel, for: agent, availability: availability)
    }

    // MARK: - MCP Preset Exposure Recommendation

    private func computeMCPPresetExposureRecommendation() -> MCPPresetExposureRecommendation? {
        let showModelPresets = settingsStore.mcpShowModelPresets()
        let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()

        // If presets toggle is OFF, recommend enabling it (and we'll set temp disable too)
        if !showModelPresets {
            return MCPPresetExposureRecommendation(
                shouldTemporarilyDisablePresets: false, // false = recommend enabling the whole feature
                rationale: "Enable MCP model presets to use the recommended MCP chat model."
            )
        }

        // If presets are ON but temp disable is OFF, recommend enabling temp disable
        // This shows the MCP chat model dropdown directly instead of presets
        if !temporarilyDisabled {
            return MCPPresetExposureRecommendation(
                shouldTemporarilyDisablePresets: true, // true = recommend showing MCP chat model dropdown
                rationale: "Use the MCP chat model dropdown directly for better control over model selection."
            )
        }

        // Both settings are correctly configured - no recommendation needed
        return nil
    }

    // MARK: - MCP Agent Defaults Recommendation

    /// Build a connection-aware availability context from provider status.
    private func mcpAgentAvailabilityContext(from status: ProviderStatusSnapshot) -> AgentModelCatalog.AvailabilityContext {
        let backendStore = ClaudeCodeCompatibleBackendStore.shared
        return AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: status.claudeCodeCLI == .ready,
            codexAvailable: status.codexCLI == .ready,
            openCodeAvailable: false,
            cursorAvailable: status.cursorCLI == .ready,
            zaiConfigured: backendStore.isConfigured(.glmZAI) && backendStore.config(for: .glmZAI).isEnabled && backendStore.config(for: .glmZAI).isValid,
            kimiConfigured: backendStore.isConfigured(.kimi) && backendStore.config(for: .kimi).isEnabled && backendStore.config(for: .kimi).isValid,
            customClaudeCompatibleConfigured: backendStore.isConfigured(.custom) && backendStore.config(for: .custom).isEnabled && backendStore.config(for: .custom).isValid
        )
    }

    private func computeMCPAgentDefaultsRecommendation(
        workspaceID: UUID,
        actualStatus: ProviderStatusSnapshot,
        recommendedStatus: ProviderStatusSnapshot
    ) -> MCPAgentDefaultsRecommendation? {
        let availability = mcpAgentAvailabilityContext(from: actualStatus)
        let recommendedAvailability = mcpAgentAvailabilityContext(from: recommendedStatus)
        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            recommendedAvailability: recommendedAvailability,
            settingsStore: settingsStore
        )
        guard !resolutions.isEmpty else { return nil }

        let currentDefaults = resolutions.map { res -> MCPAgentRoleDefault in
            let model = AgentModel.resolvedModel(forRaw: res.effective.modelRaw, agentKind: res.effective.agent)
                ?? AgentModel(rawValue: res.effective.modelRaw) ?? .defaultModel
            return MCPAgentRoleDefault(
                role: res.role,
                roleLabel: res.roleLabel,
                roleDescription: res.roleDescription,
                agent: res.effective.agent,
                model: model,
                modelDisplayName: res.effectiveDisplayName,
                selectionIDRaw: res.selectionID.rawValue
            )
        }

        let recommendedDefaults = resolutions.map { res -> MCPAgentRoleDefault in
            let model = AgentModel.resolvedModel(forRaw: res.recommended.modelRaw, agentKind: res.recommended.agent)
                ?? AgentModel(rawValue: res.recommended.modelRaw) ?? .defaultModel
            let selID = AgentModelSelectionID(agentRaw: res.recommended.agent.rawValue, modelRaw: res.recommended.modelRaw)
            return MCPAgentRoleDefault(
                role: res.role,
                roleLabel: res.roleLabel,
                roleDescription: res.roleDescription,
                agent: res.recommended.agent,
                model: model,
                modelDisplayName: res.recommendedDisplayName,
                selectionIDRaw: selID.rawValue
            )
        }

        let alreadySatisfied = zip(currentDefaults, recommendedDefaults).allSatisfy {
            $0.selectionIDRaw == $1.selectionIDRaw
        }

        // Suggest upgrade if only some CLIs are available
        let upgradeHint: String? = {
            if recommendedStatus.codexCLI != .ready {
                return "Connect Codex CLI for GPT-5.5 Low (explore/discovery/engineer/default implementation), GPT-5.5 High (pair/Oracle), and GPT-5.5 Medium (design fallback)."
            }
            if recommendedStatus.claudeCodeCLI != .ready {
                return "Connect Claude Code for Claude Opus (design/pair). Best for architecture and creative work."
            }
            return nil
        }()

        var rec = MCPAgentDefaultsRecommendation(
            currentRoleDefaults: currentDefaults,
            recommendedRoleDefaults: recommendedDefaults,
            upgradeHint: upgradeHint
        )
        rec.alreadySatisfied = alreadySatisfied
        return rec
    }

    /// Apply MCP agent defaults by clearing all global overrides (revert to recommended).
    func applyMCPAgentDefaultsRecommendation(_ rec: MCPAgentDefaultsRecommendation, workspaceID: UUID) {
        MCPAgentRoleDefaultsService.clearAllOverrides(settingsStore: settingsStore)
    }

    // MARK: - Apply Recommendations

    /// Returns equivalent Codex model IDs for a recommended model raw string.
    /// Example: gpt-5.2-codex-medium -> gpt-5.2-codex.
    private func codexEquivalentModelCandidates(for rawModel: String) -> [String] {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []
        var seen = Set<String>()
        func appendUnique(_ value: String) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(normalized)
        }

        appendUnique(trimmed)
        let specifier = CodexModelSpecifier(raw: trimmed)
        if let base = specifier.baseModel {
            appendUnique(base)
            if specifier.reasoningEffort == nil {
                for effort in CodexReasoningEffort.displayOrder {
                    appendUnique("\(base)-\(effort.rawValue)")
                }
            }
        }
        return candidates
    }

    /// Keeps recommendations hardcoded while resolving to an equivalent Codex dynamic model
    /// when model/list data is available.
    private func resolveContextBuilderRecommendedModelRaw(_ rec: ContextBuilderRecommendation) -> String {
        let fallback = rec.recommendedModel.rawValue
        guard rec.recommendedAgent == .codexExec else { return fallback }

        let options = CodexDynamicModelStore.modelOptions()
        guard !options.isEmpty else { return fallback }

        var dynamicIDByLower: [String: String] = [:]
        for option in options {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let key = id.lowercased()
            if dynamicIDByLower[key] == nil {
                dynamicIDByLower[key] = id
            }
        }

        let fallbackSpecifier = CodexModelSpecifier(raw: fallback)
        for candidate in codexEquivalentModelCandidates(for: fallback) {
            guard let matched = dynamicIDByLower[candidate.lowercased()] else { continue }
            let matchedSpecifier = CodexModelSpecifier(raw: matched)
            // Preserve the recommended effort if it is explicit. Some app-server lists expose
            // base IDs only (for example `gpt-5.3-codex`), which otherwise degrades UI mapping.
            if fallbackSpecifier.reasoningEffort != nil, matchedSpecifier.reasoningEffort == nil {
                continue
            }
            return matched
        }

        return fallback
    }

    /// Apply chat model recommendation for a workspace.
    /// Configures both built-in chat model and MCP planning model.
    func applyChatModelRecommendation(_ rec: ChatModelRecommendation, backend: ChatBackendKind, workspaceID: UUID) {
        // Determine the model string based on backend choice
        // For CLI-driven backends (Claude Code), we use a reasonable default model
        let modelString: String = switch backend {
        case .claudeCode:
            // Claude Code - Opus for chat
            rec.claudeCodeOption?.modelString ?? AIModel.claudeCodeOpus.rawValue
        case .codex:
            rec.codexOption?.modelString ?? AIModel.codexCliGpt55CodexHigh.rawValue
        case .openAI:
            rec.openAIOption?.modelString ?? AIModel.gpt54Pro.rawValue
        }

        let reasonPrefix = "recommendations.chat_model.\(backend.rawValue)"
        if settingsStore.syncChatModelWithOracle() {
            settingsStore.setPlanningModelRaw(
                modelString,
                reason: "\(reasonPrefix).planning",
                honorSync: true
            )
        } else {
            // Set for built-in UI chat (preferredComposeModel)
            settingsStore.setPreferredComposeModelRaw(
                modelString,
                reason: "\(reasonPrefix).preferred_compose"
            )
            // Set for MCP default model (planningModel) - used when presets are off, hidden, or empty
            settingsStore.setPlanningModelRaw(
                modelString,
                reason: "\(reasonPrefix).planning"
            )
        }

        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }

    /// Apply context builder recommendation.
    /// Configures the Context Builder agent/model globally, and also backfills legacy
    /// workspace-scoped context-builder fields for compatibility with older consumers.
    func applyContextBuilderRecommendation(_ rec: ContextBuilderRecommendation, workspaceID: UUID) {
        let resolvedModelRaw = resolveContextBuilderRecommendedModelRaw(rec)

        // Set GLOBAL Context Builder agent and model (single source of truth)
        settingsStore.setGlobalContextBuilderAgentSelection(
            agentRaw: rec.recommendedAgent.rawValue,
            modelRaw: resolvedModelRaw,
            markUserDefined: true // Recommendations count as user-defined to prevent re-apply
        )
        // Backfill legacy workspace-scoped context-builder settings so PromptViewModel and
        // MCP callers that still read these fields remain in sync with recommendations.
        var workspaceSettings = settingsStore.chatSettings(for: workspaceID)
        workspaceSettings.contextBuilderAgentRaw = rec.recommendedAgent.rawValue
        workspaceSettings.contextBuilderAgentModelRaw = rec.recommendedModel.rawValue
        workspaceSettings.didUserSetContextBuilderDefaults = true
        settingsStore.updateChatSettings(workspaceSettings, commit: true)
        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }

    /// Apply every model-family recommendation in one pass.
    ///
    /// Composes `applyChatModelRecommendation` + `applyContextBuilderRecommendation`
    /// + `applyMCPAgentDefaultsRecommendation` (and optionally `applyMCPPresetExposure`),
    /// then posts `.recommendationsDidApply` so listeners refresh. Intended for the
    /// "Apply Recommended Setup" button on the Agent Models settings page; callers
    /// that want row-level control should keep using the individual apply methods.
    ///
    /// SEARCH-HELPER: Agent Models, Apply Recommended Setup, bulk apply
    func applyModelRecommendations(
        _ rec: RecommendationSet,
        workspaceID: UUID,
        includePresetExposure: Bool = false
    ) {
        if let chat = rec.chatModel {
            applyChatModelRecommendation(chat, backend: chat.defaultBackend, workspaceID: workspaceID)
        }
        if let cb = rec.contextBuilder {
            applyContextBuilderRecommendation(cb, workspaceID: workspaceID)
        }
        if let agentDefaults = rec.mcpAgentDefaults {
            applyMCPAgentDefaultsRecommendation(agentDefaults, workspaceID: workspaceID)
        }
        if includePresetExposure, let presetExposure = rec.mcpPresetExposure {
            applyMCPPresetExposure(presetExposure)
        }

        NotificationCenter.default.post(
            name: .recommendationsDidApply,
            object: nil,
            userInfo: ["workspaceID": workspaceID]
        )
    }

    /// Apply MCP preset exposure recommendation.
    func applyMCPPresetExposure(_ rec: MCPPresetExposureRecommendation) {
        if rec.shouldTemporarilyDisablePresets {
            // Temporarily disable presets
            settingsStore.setMCPTemporarilyDisablePresets(true)
        } else {
            // Enable the preset feature section (turn on the main toggle)
            settingsStore.setMCPShowModelPresets(true)
            // Temporarily disable presets to show the MCP chat model dropdown directly
            // This guides users to use the recommended MCP chat model instead of arbitrary chat models
            settingsStore.setMCPTemporarilyDisablePresets(true)
        }

        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }

    // MARK: - Auto-Apply for New Workspaces

    /// Auto-applies recommended defaults when global settings are not yet configured.
    /// Since Context Builder agent/model are now GLOBAL (not per-workspace), this checks global settings.
    /// Returns true if any mutations were applied.
    @discardableResult
    func autoApplyRecommendationsIfEligible(for workspaceID: UUID) -> Bool {
        // Check GLOBAL settings for whether user has already configured Context Builder agent
        // If global is already configured, don't auto-apply
        if settingsStore.hasUserSetGlobalContextBuilderAgentDefaults {
            return false
        }

        // Compute recommendations
        let recs = computeRecommendations(for: workspaceID)
        var didApply = false

        // Apply Context Builder recommendation if global not already configured
        if let cbRec = recs.contextBuilder,
           !cbRec.alreadySatisfied
        {
            applyContextBuilderRecommendation(cbRec, workspaceID: workspaceID)
            didApply = true
        }

        return didApply
    }

    // MARK: - Mute Management

    /// Check if a recommendation is muted for this workspace.
    func isMuted(_ kind: RecommendationKind, workspaceID: UUID) -> Bool {
        let settings = settingsStore.chatSettings(for: workspaceID)
        return settings.mutedRecommendationIDs?.contains(kind.rawValue) ?? false
    }

    /// Mute a recommendation for this workspace.
    func mute(_ kind: RecommendationKind, workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        var set = settings.mutedRecommendationIDs ?? []
        set.insert(kind.rawValue)
        settings.mutedRecommendationIDs = set
        settingsStore.updateChatSettings(settings, commit: true)
    }

    /// Unmute a recommendation for this workspace.
    func unmute(_ kind: RecommendationKind, workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.mutedRecommendationIDs?.remove(kind.rawValue)
        settingsStore.updateChatSettings(settings, commit: true)
    }

    /// Clear wizard dismissals and recent-completion state for this workspace.
    func resetWizardState(workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.mutedRecommendationIDs = nil
        settings.lastRecommendationWizardCompletedAt = nil
        settingsStore.updateChatSettings(settings, commit: true)
    }

    // MARK: - Completion Tracking

    /// Check if wizard was completed recently for this workspace.
    func hasCompletedRecently(workspaceID: UUID) -> Bool {
        let settings = settingsStore.chatSettings(for: workspaceID)
        guard let last = settings.lastRecommendationWizardCompletedAt else { return false }
        return Date().timeIntervalSince(last) < completionRecencyInterval
    }

    /// Mark wizard as completed for this workspace.
    func markWizardCompleted(workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.lastRecommendationWizardCompletedAt = Date()
        settingsStore.updateChatSettings(settings, commit: true)
    }

    /// Filter out muted recommendations from a set.
    /// Mark muted recommendations with their isMuted flag (instead of filtering them out).
    func applyMutedFlags(_ set: RecommendationSet, workspaceID: UUID) -> RecommendationSet {
        var result = set

        if isMuted(.chatModel, workspaceID: workspaceID) {
            result.chatModel?.isMuted = true
        }
        if isMuted(.contextBuilderAgent, workspaceID: workspaceID) {
            result.contextBuilder?.isMuted = true
        }
        if isMuted(.mcpPresetExposure, workspaceID: workspaceID) {
            result.mcpPresetExposure?.isMuted = true
        }
        if isMuted(.mcpAgentDefaults, workspaceID: workspaceID) {
            result.mcpAgentDefaults?.isMuted = true
        }

        return result
    }

    // MARK: - Satisfaction Checks

    private struct CodexChatModelIdentity {
        let baseModel: String
        let effort: CodexReasoningEffort
    }

    private func codexChatModelIdentity(for rawValue: String) -> CodexChatModelIdentity? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model = AIModel.fromModelName(trimmed), model.providerType == .codex else {
            return nil
        }

        let modelSpecifier = CodexModelSpecifier(raw: model.modelName)
        let rawSpecifier = CodexModelSpecifier(raw: trimmed)
        let unprefixedRawSpecifier: CodexModelSpecifier? = trimmed.hasPrefix("codex_cli_")
            ? CodexModelSpecifier(raw: String(trimmed.dropFirst("codex_cli_".count)))
            : nil
        guard let baseModel = (modelSpecifier.baseModel ?? rawSpecifier.baseModel ?? unprefixedRawSpecifier?.baseModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !baseModel.isEmpty
        else {
            return nil
        }
        guard let effort = CodexReasoningEffort.parse(model.defaultReasoningEffort)
            ?? rawSpecifier.reasoningEffort
            ?? unprefixedRawSpecifier?.reasoningEffort
            ?? modelSpecifier.reasoningEffort
        else {
            return nil
        }
        return CodexChatModelIdentity(baseModel: baseModel.lowercased(), effort: effort)
    }

    private func effortRank(_ effort: CodexReasoningEffort) -> Int {
        CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? 0
    }

    private func chatModelSelection(_ currentRaw: String, satisfiesRecommended recommendedRaw: String) -> Bool {
        let current = currentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommended = recommendedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !recommended.isEmpty else { return false }
        if current.caseInsensitiveCompare(recommended) == .orderedSame { return true }
        guard let currentCodex = codexChatModelIdentity(for: current),
              let recommendedCodex = codexChatModelIdentity(for: recommended),
              currentCodex.baseModel == recommendedCodex.baseModel
        else {
            return false
        }
        return effortRank(currentCodex.effort) >= effortRank(recommendedCodex.effort)
    }

    /// Check if chat model is already configured to match the current default recommendation.
    /// Lower-priority available backends do not satisfy this check, so newly connected
    /// higher-priority providers surface as recommendation upgrades.
    /// Checks both preferredComposeModel (UI chat) and planningModel (MCP default).
    private func isChatModelAlreadyConfigured(_ rec: ChatModelRecommendation) -> Bool {
        guard let recommendedModel = rec.option(for: rec.defaultBackend)?.modelString,
              !recommendedModel.isEmpty
        else {
            return false
        }

        let currentCompose = settingsStore.preferredComposeModelRaw() ?? ""
        let currentPlanning = settingsStore.planningModelRaw() ?? ""

        return chatModelSelection(currentCompose, satisfiesRecommended: recommendedModel)
            && chatModelSelection(currentPlanning, satisfiesRecommended: recommendedModel)
    }

    /// Infer which chat backend is currently configured based on the stored model string.
    /// Returns nil if the current model doesn't match any of the available options.
    /// Prefers planningModel (MCP default) over preferredComposeModel for inference.
    func inferCurrentChatBackend(from rec: ChatModelRecommendation) -> ChatBackendKind? {
        let currentModel = settingsStore.planningModelRaw() ?? settingsStore.preferredComposeModelRaw()

        guard let current = currentModel, !current.isEmpty else { return nil }

        return rec.availableOptions.first(where: { option in
            guard let modelString = option.modelString else { return false }
            return chatModelSelection(current, satisfiesRecommended: modelString)
        })?.kind
    }

    /// Check if context builder is already configured to match the recommendation.
    /// Uses GLOBAL settings (not per-workspace) since Context Builder agent/model are now global.
    private func isContextBuilderAlreadyConfigured(
        _ rec: ContextBuilderRecommendation,
        settings: ChatGlobalSettings // Parameter kept for API compatibility but not used
    ) -> Bool {
        let (globalAgentRaw, globalModelRaw) = settingsStore.globalContextBuilderAgentSelection()
        let agentMatch = globalAgentRaw == rec.recommendedAgent.rawValue
        let modelMatch: Bool = {
            guard let globalModelRaw else { return false }
            if rec.recommendedAgent != .codexExec {
                return globalModelRaw == rec.recommendedModel.rawValue
            }

            let globalNormalized = globalModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !globalNormalized.isEmpty else { return false }

            var accepted = Set(codexEquivalentModelCandidates(for: rec.recommendedModel.rawValue).map { $0.lowercased() })
            accepted.insert(resolveContextBuilderRecommendedModelRaw(rec).lowercased())
            return accepted.contains(globalNormalized)
        }()
        return agentMatch && modelMatch
    }

    /// Check if MCP preset exposure is already configured to match the recommendation.
    private func isMCPPresetExposureAlreadyConfigured(_ rec: MCPPresetExposureRecommendation) -> Bool {
        let showModelPresets = settingsStore.mcpShowModelPresets()
        let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()

        // If recommendation is to enable the whole feature (shouldTemporarilyDisablePresets = false),
        // check if both showModelPresets AND temporarilyDisabled are true
        // (we enable presets but show MCP chat model dropdown directly)
        if !rec.shouldTemporarilyDisablePresets {
            return showModelPresets && temporarilyDisabled
        }

        // If recommendation is to just enable temp disable (shouldTemporarilyDisablePresets = true),
        // presets toggle is already on, just check if temp disable is on
        return temporarilyDisabled
    }
}
