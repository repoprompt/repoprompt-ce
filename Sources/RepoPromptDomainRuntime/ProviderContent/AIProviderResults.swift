import Foundation

public enum ProviderConversationCleanupAction: String, Codable, Equatable, CaseIterable, Sendable {
    case archive
    case delete
}

package enum ProviderConversationCleanupOutcome: Equatable {
    case succeeded(message: String? = nil)
    case unsupported(message: String? = nil)
    case failed(message: String)
    case cancelled(message: String? = nil)

    package var isSupported: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .unsupported:
            false
        }
    }

    package var isCancelled: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    package var status: String {
        switch self {
        case .succeeded:
            "succeeded"
        case .unsupported:
            "unsupported"
        case .failed:
            "failed"
        case .cancelled:
            "cancelled"
        }
    }

    package var message: String? {
        switch self {
        case let .succeeded(message), let .unsupported(message), let .cancelled(message):
            message
        case let .failed(message):
            message
        }
    }
}

public struct ProviderConversationCleanupHandle: Codable, Equatable, Sendable {
    public let provider: String
    public let conversationID: String?
    public let sessionID: String?
    public let rolloutPath: String?

    public init(
        provider: String,
        conversationID: String? = nil,
        sessionID: String? = nil,
        rolloutPath: String? = nil
    ) {
        self.provider = provider
        self.conversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.rolloutPath = rolloutPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var hasProviderIdentifier: Bool {
        conversationID != nil || sessionID != nil || rolloutPath != nil
    }

    package static func resolved(
        provider: String,
        explicit: ProviderConversationCleanupHandle?,
        providerSessionID: String?,
        codexConversationID: String?,
        codexRolloutPath: String?
    ) -> ProviderConversationCleanupHandle? {
        if let explicit, explicit.hasProviderIdentifier {
            return explicit
        }
        let handle = ProviderConversationCleanupHandle(
            provider: provider,
            conversationID: codexConversationID,
            sessionID: providerSessionID,
            rolloutPath: codexRolloutPath
        )
        return handle.hasProviderIdentifier ? handle : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

package enum AIProviderCompletionOutcome: Equatable {
    case completed
    case incomplete(reason: String)
}

/// Updated `AIStreamResult` to include optional `reasoning`, token counts, and tool metadata.
package struct AIStreamResult {
    /// Standard type strings for stream results
    package static let lifecycleType = "lifecycle"
    /// Transport-level activity with no semantic assistant payload.
    package static let transportActivityType = "transport_activity"
    /// Provider-reported terminal state that preserves partial output without declaring success.
    package static let incompleteType = "message_incomplete"

    package let type: String // e.g. "content", "message_stop", "tool_call", "tool_result", "final_content", "lifecycle", "transport_activity"
    package let text: String? // normal content (like streaming tokens)
    package let reasoning: String? // optional reasoning content
    package let promptTokens: Int? // token usage
    package let completionTokens: Int? // token usage
    package let cost: Double?

    // Tool-specific metadata (for type: "tool_call" or "tool_result")
    package let toolName: String? // Name of the tool being called/completed
    package let toolArgs: String? // JSON string of tool arguments (for tool_call)
    package let toolOutput: String? // Tool execution result (for tool_result)
    package let toolInvocationID: UUID?
    package let toolResultJSON: String?
    package let toolArgsJSON: String?
    package let toolIsError: Bool?

    /// Provider-specific session ID for resuming conversations (e.g., Claude CLI session_id)
    package let providerSessionID: String?
    package let stopReason: String?
    package let modelContextWindow: Int?
    /// Best-effort estimate of input-side context used for the turn (e.g. Claude input + cache tokens)
    package let contextUsedTokens: Int?
    /// Stable provider message identifier for content chunks when available.
    /// Used by lightweight aggregators to separate whole-message chunks without affecting token deltas.
    package let contentMessageID: String?
    /// Optional provider conversation cleanup handle, used for best-effort Oracle cleanup.
    package let cleanupHandle: ProviderConversationCleanupHandle?

    package init(
        type: String,
        text: String?,
        reasoning: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolOutput: String? = nil,
        toolInvocationID: UUID? = nil,
        toolResultJSON: String? = nil,
        toolArgsJSON: String? = nil,
        toolIsError: Bool? = nil,
        providerSessionID: String? = nil,
        stopReason: String? = nil,
        modelContextWindow: Int? = nil,
        contextUsedTokens: Int? = nil,
        contentMessageID: String? = nil,
        cleanupHandle: ProviderConversationCleanupHandle? = nil
    ) {
        self.type = type
        self.text = text
        self.reasoning = reasoning
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolOutput = toolOutput
        self.toolInvocationID = toolInvocationID
        self.toolResultJSON = toolResultJSON
        self.toolArgsJSON = toolArgsJSON
        self.toolIsError = toolIsError
        self.providerSessionID = providerSessionID
        self.stopReason = stopReason
        self.modelContextWindow = modelContextWindow
        self.contextUsedTokens = contextUsedTokens
        self.contentMessageID = contentMessageID
        self.cleanupHandle = cleanupHandle
    }
}

/// Result type for non-streaming completions, includes token counts
package struct AICompletionResult {
    package let text: String
    package let promptTokens: Int?
    package let completionTokens: Int?
    package let cost: Double?
    package let completionOutcome: AIProviderCompletionOutcome

    package init(
        text: String,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        completionOutcome: AIProviderCompletionOutcome = .completed
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.completionOutcome = completionOutcome
    }
}

/// Groups all token-usage info so we can extend it later.
public struct ChatTokenInfo: Codable, Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }
}

public enum ChatStreamTerminalOutcome: Sendable, Equatable {
    case completed
    case incomplete(reason: String)
}

/// A normalized provider stream event. A terminal outcome exists only when the provider explicitly reports completion or incomplete termination; ordinary stream exhaustion remains non-terminal.
public struct ChatStreamOutput: Sendable {
    public let text: String
    public let reasoning: String?
    public let tokens: ChatTokenInfo
    public let terminalOutcome: ChatStreamTerminalOutcome?
    public let cleanupHandle: ProviderConversationCleanupHandle?
    public let isTransportActivity: Bool

    public var isFinal: Bool {
        terminalOutcome == .completed
    }

    public init(
        text: String,
        reasoning: String?,
        tokens: ChatTokenInfo,
        terminalOutcome: ChatStreamTerminalOutcome? = nil,
        cleanupHandle: ProviderConversationCleanupHandle? = nil,
        isTransportActivity: Bool = false
    ) {
        self.text = text
        self.reasoning = reasoning
        self.tokens = tokens
        self.terminalOutcome = terminalOutcome
        self.cleanupHandle = cleanupHandle
        self.isTransportActivity = isTransportActivity
    }
}
