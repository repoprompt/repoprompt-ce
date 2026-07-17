import Foundation

// MARK: - Recommendation Kind

/// Identifies distinct recommendation categories for the auto-recommendation wizard.
enum RecommendationKind: String, Codable, CaseIterable {
    case chatModel
    case contextBuilderAgent
    case mcpPresetExposure
    case mcpAgentDefaults
}

// MARK: - Recommendation Providers

/// Providers the recommendation wizard can consider when choosing models and agents.
enum RecommendationProviderKind: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case openAI

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .cursor: "Cursor CLI"
        case .openAI: "OpenAI API"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .openAI: "OpenAI"
        }
    }
}

// MARK: - Provider Status

/// Snapshot of provider availability without network calls.
struct ProviderStatusSnapshot {
    enum Availability: Equatable {
        case notConfigured // No key/connection present
        case configured // Key present or CLI installed flag set
        case ready // Verified key or successful connection test
    }

    let claudeCodeCLI: Availability
    let codexCLI: Availability
    let cursorCLI: Availability

    let openAI: Availability

    /// Returns true if at least one provider is ready for chat.
    var hasAnyReadyProvider: Bool {
        [claudeCodeCLI, codexCLI, cursorCLI, openAI].contains(.ready)
    }

    /// Returns true if any CLI agent is ready.
    var hasAnyCLIAgentReady: Bool {
        [claudeCodeCLI, codexCLI, cursorCLI].contains(.ready)
    }

    /// Returns a copy with providers outside the enabled set treated as unavailable.
    func filtered(to enabledProviders: Set<RecommendationProviderKind>) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            claudeCodeCLI: enabledProviders.contains(.claudeCode) ? claudeCodeCLI : .notConfigured,
            codexCLI: enabledProviders.contains(.codex) ? codexCLI : .notConfigured,
            cursorCLI: enabledProviders.contains(.cursor) ? cursorCLI : .notConfigured,
            openAI: enabledProviders.contains(.openAI) ? openAI : .notConfigured
        )
    }
}

// MARK: - Chat Backend

/// Identifies the backend type for chat model recommendations.
enum ChatBackendKind: String, Codable {
    case claudeCode
    case codex
    case openAI

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .openAI: "OpenAI API"
        }
    }
}

/// Represents a selectable chat backend option with its recommended model.
struct ChatBackendOption {
    let kind: ChatBackendKind
    let displayName: String
    let modelString: String?
    let description: String

    /// Tradeoff points shown in the UI.
    let tradeoffs: [String]
}

// MARK: - Recommendation DTOs

/// Recommendation for which chat model/backend to use.
struct ChatModelRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// The default backend selection based on priority rules.
    let defaultBackend: ChatBackendKind

    /// Option for Codex CLI, if available.
    let codexOption: ChatBackendOption?

    /// Option for OpenAI API, if available.
    let openAIOption: ChatBackendOption?

    /// Option for Claude Code CLI, if available.
    let claudeCodeOption: ChatBackendOption?

    /// Priority path used to determine the default (e.g., ["OpenAI API", "Codex CLI"]).
    let priorityPath: [String]

    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?

    /// Returns all available options.
    var availableOptions: [ChatBackendOption] {
        [openAIOption, codexOption, claudeCodeOption].compactMap(\.self)
    }

    /// Returns the option for a specific backend kind.
    func option(for kind: ChatBackendKind) -> ChatBackendOption? {
        switch kind {
        case .claudeCode: claudeCodeOption
        case .codex: codexOption
        case .openAI: openAIOption
        }
    }

    init(defaultBackend: ChatBackendKind, codexOption: ChatBackendOption?, openAIOption: ChatBackendOption?, claudeCodeOption: ChatBackendOption?, priorityPath: [String], upgradeHint: String? = nil) {
        self.defaultBackend = defaultBackend
        self.codexOption = codexOption
        self.openAIOption = openAIOption
        self.claudeCodeOption = claudeCodeOption
        self.priorityPath = priorityPath
        self.upgradeHint = upgradeHint
    }
}

/// Recommendation for context builder agent configuration.
struct ContextBuilderRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    let recommendedAgent: AgentProviderKind
    let recommendedModel: AgentModel
    let rationale: String
    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?

    init(recommendedAgent: AgentProviderKind, recommendedModel: AgentModel, rationale: String, upgradeHint: String? = nil) {
        self.recommendedAgent = recommendedAgent
        self.recommendedModel = recommendedModel
        self.rationale = rationale
        self.upgradeHint = upgradeHint
    }
}

/// Resolved default for a single MCP agent role.
struct MCPAgentRoleDefault: Equatable {
    let role: AgentModelCatalog.TaskLabelKind
    let roleLabel: String
    let roleDescription: String
    let agent: AgentProviderKind
    let model: AgentModel
    let modelDisplayName: String
    /// Compound selection ID (e.g. "codexExec:gpt-5.4-mini-high").
    let selectionIDRaw: String
}

/// Recommendation for MCP agent role defaults (explore, engineer, pair, design).
struct MCPAgentDefaultsRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// Current effective defaults per role (may include user overrides).
    let currentRoleDefaults: [MCPAgentRoleDefault]

    /// Recommended defaults per role (no overrides).
    let recommendedRoleDefaults: [MCPAgentRoleDefault]

    /// Upgrade hint when not all CLIs are configured.
    let upgradeHint: String?
}

/// Recommendation for MCP preset exposure.
struct MCPPresetExposureRecommendation {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// If true, presets should be temporarily hidden to use MCP chat model selector.
    let shouldTemporarilyDisablePresets: Bool
    let rationale: String
}

/// Container for all recommendations for a workspace.
struct RecommendationSet {
    var chatModel: ChatModelRecommendation?
    var contextBuilder: ContextBuilderRecommendation?
    var mcpPresetExposure: MCPPresetExposureRecommendation?
    var mcpAgentDefaults: MCPAgentDefaultsRecommendation?

    /// Returns true if any recommendation is present.
    var hasAny: Bool {
        chatModel != nil || contextBuilder != nil || mcpPresetExposure != nil || mcpAgentDefaults != nil
    }

    /// Returns true when applying this set may mutate the targeted Agent Models profile.
    var hasAgentModelsRecommendations: Bool {
        chatModel != nil || contextBuilder != nil || mcpAgentDefaults != nil
    }

    /// Number of recommendations that need action (not already satisfied and not muted).
    var actionableUnsatisfiedCount: Int {
        var count = 0
        if let chat = chatModel, !chat.alreadySatisfied, !chat.isMuted { count += 1 }
        if let cb = contextBuilder, !cb.alreadySatisfied, !cb.isMuted { count += 1 }
        if let mcp = mcpPresetExposure, !mcp.alreadySatisfied, !mcp.isMuted { count += 1 }
        if let agentDefaults = mcpAgentDefaults, !agentDefaults.alreadySatisfied, !agentDefaults.isMuted { count += 1 }
        return count
    }

    /// Returns true if any recommendation needs action (not already satisfied and not muted).
    var hasUnsatisfied: Bool {
        actionableUnsatisfiedCount > 0
    }

    /// Returns true if any recommendation is muted but differs from recommended.
    var hasMutedDifferences: Bool {
        if let chat = chatModel, chat.isMuted, !chat.alreadySatisfied { return true }
        if let cb = contextBuilder, cb.isMuted, !cb.alreadySatisfied { return true }
        if let mcp = mcpPresetExposure, mcp.isMuted, !mcp.alreadySatisfied { return true }
        if let agentDefaults = mcpAgentDefaults, agentDefaults.isMuted, !agentDefaults.alreadySatisfied { return true }
        return false
    }
}

/// Posts one canonical recommendation-apply notification per unique durable scope.
/// Agent Models writes use the captured operation scope, while MCP preset exposure is global.
enum RecommendationApplyNotification {
    static func post(
        sourceWorkspaceID: UUID,
        agentModelsScope: AgentModelsEditingScope?,
        includesPresetExposure: Bool,
        object: Any? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        var affectedScopes: [AgentModelsEditingScope] = []
        if let agentModelsScope {
            affectedScopes.append(agentModelsScope)
        }
        if includesPresetExposure, !affectedScopes.contains(.global) {
            affectedScopes.append(.global)
        }

        for scope in affectedScopes {
            notificationCenter.post(
                name: .recommendationsDidApply,
                object: object,
                userInfo: AgentModelsSettingsNotification.userInfo(
                    scope: scope,
                    sourceWorkspaceID: sourceWorkspaceID
                )
            )
        }
    }
}

// MARK: - Best Practice Profiles (July 2026)

/// Canonical best practice recommendations, versioned by date.
/// Update `versionCode` when recommendations change significantly.
enum BestPracticeProfiles {
    /// Bump when the table changes (used for gating mutes/badge).
    /// Format: YYYYMM
    static let versionCode: Int = 202_608
    static let tableTitle = "Best Models by Use Case (GPT-5.6)"

    struct UseCase {
        let id: String
        let title: String
        let modelLabel: String
        let accessLabel: String
        /// Canonical model identifier for direct API where applicable.
        let modelString: String?
        /// Optional Context Builder agent kind for CLI-style agents.
        let agentKind: AgentProviderKind?
        /// Optional Context Builder agent model.
        let agentModel: AgentModel?
        /// Strengths/reasons for this recommendation.
        let strengths: [String]
    }

    // MARK: Use Cases

    static let bestAgent = UseCase(
        id: "bestAgent",
        title: "Best Agent",
        modelLabel: "GPT-5.6 Sol Low",
        accessLabel: "Codex CLI",
        modelString: "gpt-5.6-sol-low",
        agentKind: .codexExec,
        agentModel: .gpt56SolLow,
        strengths: [
            "Fast default for explore, discovery, and lightweight implementation",
            "Strong reasoning during agentic tool use",
            "Lower usage burn than higher GPT-5.6 Sol efforts",
            "Codex-only GPT-5.6 Sol via Codex CLI"
        ]
    )

    static let bestPlanning = UseCase(
        id: "bestPlanning",
        title: "Best Planning",
        modelLabel: "GPT-5.6 Sol",
        accessLabel: "ChatGPT Pro export",
        modelString: "gpt-5.6-sol",
        agentKind: nil,
        agentModel: nil,
        strengths: [
            "Use ChatGPT Pro's current GPT-5.6 Sol export/planning mode without forcing a RepoPrompt effort suffix",
            "Can reason about entire codebases at once",
            "Produces clear, actionable architectural specifications",
            "Catches edge cases and implications other models miss"
        ]
    )

    static let bestInAppPlanningReview = UseCase(
        id: "bestInAppPlanningReview",
        title: "Best In‑App Planning/Review",
        modelLabel: "GPT-5.6 Sol High",
        accessLabel: "Codex CLI",
        modelString: AIModel.codexCliGpt56SolHigh.rawValue,
        agentKind: .codexExec,
        agentModel: .gpt56SolHigh,
        strengths: [
            "Strong reasoning without extended wait times",
            "Won't exhaust weekly usage limits quickly",
            "Excellent diff generation",
            "Extended efforts are available when explicitly selected for exceptional tasks"
        ]
    )

    static let bestContextBuilder = UseCase(
        id: "bestContextBuilder",
        title: "Best Context Builder",
        modelLabel: "GPT-5.6 Sol Low",
        accessLabel: "Codex CLI",
        modelString: "gpt-5.6-sol-low",
        agentKind: .codexExec,
        agentModel: .gpt56SolLow,
        strengths: [
            "Strong codebase understanding",
            "Efficient file exploration and selection",
            "Lower usage burn than higher GPT-5.6 Sol efforts",
            "Practical default for repeated discovery runs"
        ]
    )

    static let all: [UseCase] = [
        bestAgent,
        bestPlanning,
        bestInAppPlanningReview,
        bestContextBuilder
    ]

    // MARK: Model Strength Summary

    static let claudeStrengths = """
    Claude Opus 4.6 remains great for editing-heavy work and careful file modifications. \
    GPT-5.6 Sol Low via Codex CLI is now our default recommendation for explore, discovery, and lightweight agentic work.
    """

    static let gpt5HighStrengths = """
    GPT-5.6 Sol Low/High via Codex CLI provides strong reasoning without extended wait times. \
    Low is recommended for explore and discovery; Medium is recommended for Engineer/default implementation; High is recommended for Oracle, review, and pair agents. \
    Extended efforts are available for exceptional tasks but can exhaust usage limits quickly; keep them explicit.
    """

    static let geminiStrengths = """
    Gemini 3.1 Pro excels at design and creative discussions. \
    Gemini 3.0 Flash is the preferred Gemini option for fast exploration.
    """

    // MARK: Explanatory Text

    static let codexVsOpenAIExplanation = """
    GPT-5.6 Sol is available to RepoPrompt through Codex CLI; do not configure it as an OpenAI API/OpenRouter model.

    Use GPT‑5.6 Sol Low via Codex CLI for Context Builder discovery and explore, \
    GPT‑5.6 Sol Medium for Engineer/default implementation, and GPT‑5.6 Sol High for Oracle, review, and pair-agent work. Use effort-neutral GPT‑5.6 Sol for ChatGPT Pro export/planning.
    """

    static let contextBuilderRationale = "Codex with GPT-5.6 Sol Low provides the best Context Builder/discovery default – strong codebase exploration with practical usage burn."

    static let contextWindowNote = """
    You can use xhigh for context building, but context windows are finite, \
    and reasoning takes space. Prefer GPT-5.6 Sol Low for prompt and context building, \
    then let GPT-5.6 Sol High reason in full when needed.
    """

    static let codexHarnessNote = """
    This works best with the API, as the model served in the Codex harness \
    has capped reasoning time.
    """
}
