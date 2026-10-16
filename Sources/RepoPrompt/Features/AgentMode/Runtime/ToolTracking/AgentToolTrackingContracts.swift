import Foundation
import MCP

// SEARCH-HELPER: AgentToolTracking, ToolStreamEvent, ToolTrackingHooks, ToolTrackingSupport

// MARK: - Tool Stream Event

/// Normalized bridge between `AIStreamResult` tool events and provider handlers.
/// Extracted from raw stream results before routing to the appropriate handler.
enum AgentToolStreamEvent {
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case legacyEvent(LegacyEvent)

    struct ToolCall {
        let toolName: String
        let invocationID: UUID?
        let argsJSON: String?
    }

    struct ToolResult {
        let toolName: String
        let invocationID: UUID?
        let argsJSON: String?
        let resultJSON: String
        let isError: Bool?
    }

    /// Legacy "Using tool: X" event from headless providers.
    struct LegacyEvent {
        let toolName: String
    }

    /// Attempt to parse an `AIStreamResult` into a tool stream event.
    /// Returns `nil` when the result is not a tool-related event type.
    static func from(_ result: AIStreamResult) -> AgentToolStreamEvent? {
        switch result.type {
        case "tool_call":
            guard let toolName = result.toolName else { return nil }
            return .toolCall(.init(
                toolName: toolName,
                invocationID: result.toolInvocationID,
                argsJSON: result.toolArgsJSON ?? result.toolArgs
            ))

        case "tool_result":
            guard let toolName = result.toolName else { return nil }
            return .toolResult(.init(
                toolName: toolName,
                invocationID: result.toolInvocationID,
                argsJSON: result.toolArgsJSON ?? result.toolArgs,
                resultJSON: result.toolResultJSON ?? result.toolOutput ?? "",
                isError: result.toolIsError
            ))

        case "event":
            if let text = result.text, text.hasPrefix("Using tool: ") {
                let toolName = String(text.dropFirst("Using tool: ".count))
                return .legacyEvent(.init(toolName: toolName))
            }
            return nil

        default:
            return nil
        }
    }
}

// MARK: - Tool Tracking Hooks

/// Closures back into `AgentModeViewModel` for generic orchestration behavior
/// that provider tool handlers need but should not own directly.
///
/// This decouples handlers from `AgentModeViewModel` — handlers receive these
/// at construction time instead of holding a weak viewmodel reference for tool plumbing.
struct AgentToolTrackingHooks {
    /// No-op hooks for test / stub contexts where the viewmodel isn't available.
    static let noOp = AgentToolTrackingHooks(
        flushPendingAssistantDelta: { _ in },
        endActiveAssistantSegment: { _ in },
        endActiveReasoningSegment: { _ in },
        sealAssistantBoundary: { _ in },
        requestUIRefresh: { _, _ in },
        scheduleSave: { _ in },
        addToolInputTokens: { _, _ in },
        addToolOutputTokens: { _, _ in }
    )

    // MARK: - Hook Closures

    /// Flush any pending assistant text delta before a tool event.
    let flushPendingAssistantDelta: @MainActor @Sendable (_ session: AgentTabSession) -> Void

    /// End the active streaming assistant segment.
    let endActiveAssistantSegment: @MainActor @Sendable (_ session: AgentTabSession) -> Void

    /// End the active reasoning segment.
    let endActiveReasoningSegment: @MainActor @Sendable (_ session: AgentTabSession) -> Void

    /// Seal the assistant boundary so subsequent content starts a new bubble.
    let sealAssistantBoundary: @MainActor @Sendable (_ session: AgentTabSession) -> Void

    /// Request a UI refresh for the given tab.
    let requestUIRefresh: @MainActor @Sendable (_ tabID: UUID, _ urgent: Bool) -> Void

    /// Schedule a persistence save for the given tab.
    let scheduleSave: @MainActor @Sendable (_ tabID: UUID) -> Void

    /// Account for tool input tokens from args payload.
    let addToolInputTokens: @MainActor @Sendable (_ payload: String?, _ session: AgentTabSession) -> Void

    /// Account for tool output tokens from result payload.
    let addToolOutputTokens: @MainActor @Sendable (_ payload: String?, _ session: AgentTabSession) -> Void
}

// MARK: - Tool Tracking Support Utilities

/// Shared static helpers for tool classification and formatting used across all providers.
/// Consolidates logic that was previously scattered in `AgentModeViewModel` and coordinators.
@MainActor
enum AgentToolTrackingSupport {
    /// Whether the tool name belongs to a RepoPrompt MCP tool (any naming convention).
    static func isRepoPromptTool(_ name: String) -> Bool {
        guard let name = AgentToolNamePolicy.accepted(name) else { return false }
        return MCPIntegrationHelper.isRepoPromptToolName(name)
    }

    /// Whether the tool name uses the explicit server-prefixed RepoPrompt naming.
    static func isExplicitRepoPromptTool(_ name: String) -> Bool {
        guard let name = AgentToolNamePolicy.accepted(name) else { return false }
        return MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(name)
    }

    /// Whether a tool should be hidden from the agent transcript UI.
    static func shouldHideToolFromTranscript(_ name: String?) -> Bool {
        AgentTranscriptIO.shouldHideToolFromTranscript(AgentToolNamePolicy.accepted(name))
    }

    /// Whether a provider tool event should be suppressed in favor of tracker-sourced events.
    static func shouldSuppressProviderToolEvent(
        toolName: String,
        invocationID: UUID?
    ) -> Bool {
        // Prefer tracker-sourced events for explicit RepoPrompt MCP tools.
        if isExplicitRepoPromptTool(toolName) {
            return true
        }
        return false
    }

    /// Whether a provider tool_call should be auto-completed with a synthetic result.
    static func shouldAutoCompleteProviderToolCall(
        for session: AgentTabSession,
        toolName: String,
        invocationID: UUID?
    ) -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
        guard invocationID == nil else { return false }
        guard let toolName = AgentToolNamePolicy.accepted(toolName) else { return false }
        return toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "read"
    }

    /// Generate a synthetic completed tool result JSON for provider events without matching results.
    nonisolated static func syntheticCompletedToolResultJSON(note: String) -> String {
        let payload: [String: Any] = [
            "status": "completed",
            "note": note
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"status":"completed"}"#
    }
}
