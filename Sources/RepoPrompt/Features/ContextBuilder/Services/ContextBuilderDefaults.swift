import Foundation
import RepoPromptShared

/// Controls how Context Builder handles the user's original prompt
enum PromptEnhancementMode: String, Codable, CaseIterable {
    case fullRewrite // Agent rewrites prompt from discoveries
    case augment // Preserve original + add context
    case preserve // Don't touch the prompt at all
}

struct ContextBuilderBehaviorSettings: Equatable {
    var contextTokenBudget: Int
    var analysisTokenBudget: Int
    var enhancementMode: PromptEnhancementMode
    var questionTimeoutSeconds: TimeInterval
    var allowUIClarifyingQuestions: Bool
    var allowMCPClarifyingQuestions: Bool
    var followUpAnalysisEnabled: Bool
}

/// Centralized default values for Context Builder.
/// Update these values to change defaults across the entire app.
enum ContextBuilderDefaults {
    // MARK: - Token Budgets

    /// Default selected-context budget for context-only runs
    static let contextTokenBudget: Int = 160_000

    /// Default selected-context budget for plan, review, and question runs
    static let analysisTokenBudget: Int = 120_000

    // MARK: - Enhancement Mode

    /// Default prompt enhancement mode
    static let enhancementMode: PromptEnhancementMode = .fullRewrite

    // MARK: - Clarifying Questions

    /// Whether clarifying questions are allowed by default for UI-triggered discovery
    static let allowUIClarifyingQuestions: Bool = true

    /// Whether clarifying questions are allowed for MCP-triggered discovery
    static let allowMCPClarifyingQuestions: Bool = false

    /// Default timeout (in seconds) for user responses to clarifying questions
    static let questionTimeoutSeconds = MCPTimeoutPolicy.askUserDefaultTimeoutSeconds

    /// Report-only watchdog for a live run that has not yet opened its owned MCP connection.
    static let mcpRoutingWatchdogSeconds: TimeInterval = 30

    /// Maximum buffered text while routing is pending. Control events are always preserved.
    static let mcpPreRouteBufferedTextCharacterLimit = 64000

    /// Maximum early provider events retained while routing is pending. Redundant progress and
    /// retry notifications are coalesced or dropped before ordered terminal/error/tool events.
    static let mcpPreRouteBufferedEventLimit = 256

    /// Diagnostic age recorded on the policy. Context Builder policies are settlement-scoped and
    /// are never revoked because this interval elapsed.
    static let mcpBootstrapConnectionTTL: TimeInterval = 35

    /// Bounded handoff after response-drain failure while orderly peer-EOF teardown publishes final context ownership.
    static let peerEOFDetachmentHandoffTimeoutSeconds: TimeInterval = 10

    // MARK: - Follow-up Analysis

    /// Whether to automatically analyze selected context after a UI run
    static let followUpAnalysisEnabled: Bool = false

    static let behaviorSettings = ContextBuilderBehaviorSettings(
        contextTokenBudget: contextTokenBudget,
        analysisTokenBudget: analysisTokenBudget,
        enhancementMode: enhancementMode,
        questionTimeoutSeconds: questionTimeoutSeconds,
        allowUIClarifyingQuestions: allowUIClarifyingQuestions,
        allowMCPClarifyingQuestions: allowMCPClarifyingQuestions,
        followUpAnalysisEnabled: followUpAnalysisEnabled
    )
}
