import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Protocol for headless CLI-based agents that operate via MCP tools only.
package protocol HeadlessAgentProvider {
    /// Stream agent execution results.
    /// - Parameters:
    ///   - message: The agent message to process (system prompt + user message)
    ///   - runID: Optional runID for this execution (if nil, provider generates one)
    func streamAgentMessage(_ message: RepoPromptDomainRuntime.AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>

    /// Best-effort provider-side cleanup for a persisted/resumable conversation.
    func cleanupConversation(_ handle: RepoPromptDomainRuntime.ProviderConversationCleanupHandle, action: RepoPromptDomainRuntime.ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome

    /// Dispose of the provider and cancel any running operations.
    func dispose() async
}

package extension HeadlessAgentProvider {
    func cleanupConversation(_ handle: RepoPromptDomainRuntime.ProviderConversationCleanupHandle, action: RepoPromptDomainRuntime.ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome {
        .unsupported(message: "Provider has no local API for \(action.rawValue) cleanup of conversations.")
    }
}

/// Lifecycle events for agent session state (not user-facing chat content).
package enum AgentLifecycleEvent: Equatable {
    case initialized
    case completed
    case cancelled
}

/// Standardized events emitted from a headless agent.
package enum AgentStreamEvent {
    case message(content: String, reasoning: String?)
    /// Final authoritative message content (replaces streaming content when present)
    case finalMessage(content: String)
    case toolCall(name: String, args: [String: Any])
    case toolResult(name: String, result: String)
    case system(message: String)
    /// Lifecycle events (session init/complete/cancel) - not rendered in chat
    case lifecycle(AgentLifecycleEvent)
    /// Completion event with optional provider session ID for resuming conversations
    case completion(usage: TokenUsage?, cost: Double?, providerSessionID: String?)
}

/// Token usage reported by the agent.
package struct TokenUsage {
    package let inputTokens: Int
    package let outputTokens: Int
    package let contextUsedTokens: Int?

    package init(inputTokens: Int, outputTokens: Int, contextUsedTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.contextUsedTokens = contextUsedTokens
    }
}

package final class UnsupportedHeadlessAgentProvider: HeadlessAgentProvider {
    private let reason: String

    package init(reason: String) {
        self.reason = reason
    }

    package func streamAgentMessage(_ message: RepoPromptDomainRuntime.AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        throw AIProviderError.invalidConfiguration(detail: reason)
    }

    package func dispose() async {}
}
