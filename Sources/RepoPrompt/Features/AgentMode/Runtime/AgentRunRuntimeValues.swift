import Foundation

/// Runtime values deliberately independent of the presentation view-model namespace.
/// These are in-memory contracts, not persisted type names or new lifecycle authorities.
/// The old nested spellings remain aliases while the in-app runtime seam is prepared.
enum AgentRunInteractionTransport: Equatable {
    case ui
    case mcp(sessionID: UUID, originatingConnectionID: UUID?)
}

enum AgentMCPInstructionDispatch: String, Equatable {
    case deliveredIntoWaitingContinuation = "delivered_waiting_continuation"
    case queuedClaudeInterrupt = "queued_claude_interrupt"
    case queuedACPInterrupt = "queued_acp_interrupt"
    case queuedFollowUp = "queued_follow_up"
    case dispatchedCodexTurn = "dispatched_codex_turn"
    case startedRun = "started_run"

    /// Whether this dispatch sent an instruction into an already-running session.
    /// Used to suppress stale assistant previews in the immediate steer response.
    var isActiveRunDispatch: Bool {
        switch self {
        case .queuedClaudeInterrupt, .queuedACPInterrupt, .queuedFollowUp, .dispatchedCodexTurn:
            true
        case .deliveredIntoWaitingContinuation, .startedRun:
            false
        }
    }

    /// Whether MCP waiters should be woken as soon as `mcpDispatchInstruction` returns.
    /// Some runtimes accept the local queue before provider delivery; those signal later
    /// from their provider-specific flush path.
    var signalsMCPDeliveryAfterDispatch: Bool {
        guard isActiveRunDispatch else { return false }
        switch self {
        case .queuedClaudeInterrupt, .queuedACPInterrupt:
            return false
        case .queuedFollowUp, .dispatchedCodexTurn:
            return true
        case .deliveredIntoWaitingContinuation, .startedRun:
            return false
        }
    }
}

struct AgentMCPActiveInstructionDispatchPlan {
    let delivery: AgentMCPInstructionDispatch
    let codexAttemptID: UUID?
    let signalsDeliveryAfterDispatch: Bool
}

struct AgentNonCodexTurnTokenAccumulator {
    var estimatedUserInputTokens: Int = 0
    var estimatedToolInputTokens: Int = 0
    var estimatedToolOutputTokens: Int = 0
    /// Exact stream-derived context snapshot for the current turn (from usage events),
    /// tracked separately from the session-wide display value to prevent billed-turn
    /// aggregates from overwriting it.
    var observedContextUsedTokens: Int?

    var estimatedInputTokens: Int {
        estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
    }
}
