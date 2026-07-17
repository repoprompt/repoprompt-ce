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

    /// A missing run-owned MCP connection remains a fast failure.
    static let mcpNoConnectionTimeoutSeconds: TimeInterval = 10

    /// Once the exact connection is observed, route materialization gets bounded handshake grace.
    static let mcpObservedConnectionGraceSeconds: TimeInterval = 20

    static let mcpRoutingWaitPolicy = MCPRoutingWaitPolicy(
        noConnectionTimeoutSeconds: mcpNoConnectionTimeoutSeconds,
        observedConnectionGraceSeconds: mcpObservedConnectionGraceSeconds
    )

    /// Leak bound for the pending policy, derived once from both phases plus a safety margin.
    /// Observation/reconnect never refreshes it.
    static let mcpBootstrapConnectionTTL =
        mcpNoConnectionTimeoutSeconds + mcpObservedConnectionGraceSeconds + 5

    /// Bounded handoff after response-drain failure while orderly peer-EOF teardown publishes final context ownership.
    static let peerEOFDetachmentHandoffTimeoutSeconds: TimeInterval = 10

    // MARK: - Plan Generation

    /// Whether to auto-generate a plan after Context Builder completes
    static let autoGeneratePlan: Bool = false
}
