import Foundation
import RepoPromptShared

/// Controls how Context Builder handles the user's original prompt
enum PromptEnhancementMode: String, Codable, CaseIterable {
    case fullRewrite // Agent rewrites prompt from discoveries
    case augment // Preserve original + add context
    case preserve // Don't touch the prompt at all
}

/// Centralized default values for Context Builder.
/// Update these values to change defaults across the entire app.
enum ContextBuilderDefaults {
    // MARK: - Token Budgets

    /// Default token budget for discovery runs (UI slider default)
    static let discoveryTokenBudget: Int = 160_000

    /// Default token budget for plan generation
    static let planTokenBudget: Int = 120_000

    // MARK: - Enhancement Mode

    /// Default prompt enhancement mode
    static let enhancementMode: PromptEnhancementMode = .fullRewrite

    // MARK: - Clarifying Questions

    /// Whether clarifying questions are allowed by default (UI-triggered discovery)
    static let allowClarifyingQuestions: Bool = true

    /// Whether clarifying questions are allowed for MCP-triggered discovery
    static let allowClarifyingQuestionsForMCP: Bool = false

    /// Default timeout (in seconds) for user responses to clarifying questions
    static let questionTimeoutSeconds = MCPTimeoutPolicy.askUserDefaultTimeoutSeconds

    /// Deadline for the provider's run-scoped MCP client to route after stream creation.
    static let mcpRoutingTimeoutMilliseconds = 10000

    /// Keeps the one-shot routing policy alive through the routing deadline, with a five-second margin.
    static let mcpBootstrapConnectionTTL = TimeInterval((mcpRoutingTimeoutMilliseconds / 1000) + 5)

    // MARK: - Plan Generation

    /// Whether to auto-generate a plan after Context Builder completes
    static let autoGeneratePlan: Bool = false
}
