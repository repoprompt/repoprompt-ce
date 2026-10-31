import Foundation

/// Provider-owned stream/result DTO emitted by the Claude-compatible translator.
/// RepoPrompt core adapters map this to app-specific stream models.
public struct ClaudeProviderStreamResult: Sendable, Equatable {
    public static let lifecycleType = "lifecycle"

    public let type: String
    public let text: String?
    public let reasoning: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?
    public let toolName: String?
    public let toolArgs: String?
    public let toolOutput: String?
    public let toolInvocationID: UUID?
    public let claudeToolUseID: String?
    public let toolResultJSON: String?
    public let toolArgsJSON: String?
    public let toolIsError: Bool?
    public let providerSessionID: String?
    public let stopReason: String?
    public let modelContextWindow: Int?
    public let contextUsedTokens: Int?
    public let contentMessageID: String?

    public init(
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
        claudeToolUseID: String? = nil,
        toolResultJSON: String? = nil,
        toolArgsJSON: String? = nil,
        toolIsError: Bool? = nil,
        providerSessionID: String? = nil,
        stopReason: String? = nil,
        modelContextWindow: Int? = nil,
        contextUsedTokens: Int? = nil,
        contentMessageID: String? = nil
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
        self.claudeToolUseID = claudeToolUseID
        self.toolResultJSON = toolResultJSON
        self.toolArgsJSON = toolArgsJSON
        self.toolIsError = toolIsError
        self.providerSessionID = providerSessionID
        self.stopReason = stopReason
        self.modelContextWindow = modelContextWindow
        self.contextUsedTokens = contextUsedTokens
        self.contentMessageID = contentMessageID
    }
}
