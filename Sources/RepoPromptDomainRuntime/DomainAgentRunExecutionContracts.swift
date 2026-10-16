import Foundation

// MARK: - Neutral Agent run execution contracts

//
// These types define the provider-neutral, presentation-free command and result
// vocabulary shared by every Agent run execution host (the app-hosted Agent Mode
// runtime and the direct/headless composition). They intentionally carry no
// session, tab, transcript, or UI state: canonical durable lifecycle remains
// owned by `DomainAgentRunSessionStore`, and hosts adapt these values into their
// own projection layers.

/// Why an Agent run is being cancelled.
///
/// This is a command-side contract: hosts translate user or lifecycle actions
/// into one of these intents before asking their execution layer to stop a run.
package enum DomainAgentRunCancellationIntent: Equatable, Hashable {
    /// The user explicitly stopped the run.
    case userStop
    /// The run is being stopped because its execution location (worktree/cwd)
    /// is changing; queued undelivered work should be restored, not replayed.
    case executionLocationChange
    /// The hosting runtime is shutting down (window close, app termination).
    case runtimeShutdown

    /// Canonical machine-readable reason string used when cancelling dependent
    /// resources (for example active MCP tool executions) for this intent.
    package var cancellationReason: String {
        switch self {
        case .userStop: "user_stop"
        case .executionLocationChange: "execution_location_change"
        case .runtimeShutdown: "runtime_shutdown"
        }
    }
}

/// How far a cancellation request must settle before returning to the caller.
///
/// Terminal settlement is exactly-once: waiting for `terminalTeardownCompleted`
/// never re-runs teardown, it only awaits the single claimed teardown closure.
package enum DomainAgentRunCancellationCompletion: Equatable, Hashable {
    /// Return after canonical terminal publication and synchronous provider
    /// detachment.
    case terminalPublished
    /// Also wait for the exactly-once attempt/provider teardown to finish.
    case terminalTeardownCompleted
}

/// What terminal settlement should do with attachment files reserved for a turn.
///
/// This is provider-neutral command vocabulary, not attachment lifecycle
/// authority: the execution host applies the disposition through its attachment
/// persistence boundary. It carries no files, session state, or presentation
/// policy, and does not change the canonical run lifecycle authority owned by
/// `DomainAgentRunSessionStore`.
package enum DomainAgentRunAttachmentTurnDisposition: Equatable, Hashable, Sendable {
    /// Return the turn's attachments to the host's pending attachment state.
    case restoreToPending
    /// Delete the turn's attachment files during finalization.
    case deleteFiles
    /// Preserve the turn's attachment files during finalization.
    case keepFiles
}

/// Provider-neutral terminal result of one Agent run execution.
///
/// Exactly one outcome may settle a run. Hosts map an outcome into their
/// canonical settlement surface (`DomainAgentRunSessionStore.publishTerminal`
/// via a `DomainAgentRunTerminalPublicationEnvelope`); the store enforces
/// exactly-once publication per epoch regardless of host.
package struct DomainAgentRunTerminalOutcome: Equatable, Hashable {
    package enum Kind: String, Codable, Equatable, Hashable {
        case completed
        case cancelled
        case failed
    }

    package let kind: Kind
    /// Final assistant-visible text for the run, when the provider produced one.
    package let assistantText: String?
    /// Failure classification carried explicitly so hosts preserve their own
    /// diagnosis instead of re-deriving it from display text.
    package let failureReason: DomainAgentRunSnapshot.FailureReason?

    private init(
        kind: Kind,
        assistantText: String?,
        failureReason: DomainAgentRunSnapshot.FailureReason?
    ) {
        self.kind = kind
        self.assistantText = assistantText
        self.failureReason = failureReason
    }

    package static func completed(assistantText: String?) -> DomainAgentRunTerminalOutcome {
        DomainAgentRunTerminalOutcome(kind: .completed, assistantText: assistantText, failureReason: nil)
    }

    package static func cancelled(
        assistantText: String? = nil
    ) -> DomainAgentRunTerminalOutcome {
        DomainAgentRunTerminalOutcome(kind: .cancelled, assistantText: assistantText, failureReason: .cancelled)
    }

    package static func failed(
        assistantText: String?,
        reason: DomainAgentRunSnapshot.FailureReason = .agentError
    ) -> DomainAgentRunTerminalOutcome {
        DomainAgentRunTerminalOutcome(kind: .failed, assistantText: assistantText, failureReason: reason)
    }

    /// Canonical snapshot status for this outcome.
    package var snapshotStatus: DomainAgentRunSnapshot.Status {
        switch kind {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}
