import Foundation
import RepoPromptDomainRuntime

// Value model for one managed cross-session `steer`: the provider route it was classified onto
// before anything mutated, the one-shot outcome sink the ordinary submission paths resolve, and
// the context those paths receive in place of composer state.
//
// A steer reuses the target's own submission routing (`submitPreparedUserTurn`) so a running Codex,
// Claude, or ACP turn is steered exactly the way a local composer message steers it. What it never
// reuses is composer state: no draft, attachment, tagged file, workflow, or interview mode is read,
// cleared, or restored, and a withdrawn steer is never put back into the target user's composer,
// where an overseer's words would read as the user's own draft.

/// Provider route one managed steer takes, classified before the attributed row exists.
///
/// Deliberately short. An idle target is not a route: it goes through the durable send transaction.
/// The ACP route is a managed-aware serialized queue; only local draft text is recoverable into
/// the target user's composer.
enum AgentSessionLinkManagedSteerRoute: Equatable {
    /// Codex native steer, or its durable fallback queue. The outcome comes from the steer
    /// acknowledgement tracker.
    case codex
    /// The target is waiting for its next instruction; the steer is that instruction.
    case waitingInstruction
    /// The Claude-native interrupt-steering queue.
    case claudeInterrupt
    /// The serialized ACP interrupt, settle, and prompt queue.
    case acpQueued
}

/// Provider-level outcome of one managed steer after its attributed row was appended.
enum AgentSessionLinkManagedSteerOutcome: Equatable {
    /// The provider path accepted it in the given state.
    case delivered(DomainAgentSessionLinkDeliveryState)
    /// RepoPrompt withdrew the row before any provider accepted it. Nothing was delivered.
    case notAccepted(message: String)
    /// RepoPrompt could not learn whether a provider accepted it. The row may still be in flight.
    case unconfirmed(message: String)
}

/// One-shot main-actor sink every managed submission route resolves exactly once.
///
/// Later resolutions are ignored, so a route that resolves on both a fast path and a teardown path
/// reports whichever happened first. `awaitOutcome` is bounded: a route that never resolves reports
/// `unconfirmed` rather than parking the observer's tool call forever.
@MainActor
final class AgentSessionLinkManagedSteerSink {
    private(set) var outcome: AgentSessionLinkManagedSteerOutcome?
    /// The attributed row the submission appended, recorded synchronously at append time.
    private(set) var appendedItemID: UUID?
    private var continuation: CheckedContinuation<AgentSessionLinkManagedSteerOutcome, Never>?

    init() {}

    func noteAppended(itemID: UUID) {
        guard appendedItemID == nil else { return }
        appendedItemID = itemID
    }

    func resolve(_ value: AgentSessionLinkManagedSteerOutcome) {
        guard outcome == nil else { return }
        outcome = value
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }

    func awaitOutcome(timeoutSeconds: TimeInterval) async -> AgentSessionLinkManagedSteerOutcome {
        if let outcome { return outcome }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeoutSeconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(.unconfirmed(
                message: "RepoPrompt did not observe the provider accept the steer in time."
            ))
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
        }
    }
}

/// What a managed steer hands the ordinary submission path in place of composer state.
struct AgentSessionLinkManagedTurn {
    /// The exact endpoint the grant covers. A deferred provider dispatch re-proves it, so an in-place
    /// rebind between submission and dispatch cannot receive direction meant for this incarnation.
    let candidate: AgentSessionLinkEndpointCandidate
    /// The provider-only framed text: the management envelope around the overseer's words.
    let providerText: String
    /// Attribution persisted on the transcript row, identical to a `send` row's badge.
    let attribution: AgentCrossSessionAttribution
    let sink: AgentSessionLinkManagedSteerSink
}

/// Pre-mutation admission for one managed steer, decided from live target facts alone.
enum AgentSessionLinkSteerAdmission: Equatable {
    /// The target is fully idle and send-ready: deliver through the attributed send transaction,
    /// which persists the row durably before starting the run.
    case idleTurn
    /// The target can take the steer on this provider route right now.
    case steer(AgentSessionLinkManagedSteerRoute)
    /// Nothing may be delivered. Every case leaves the target byte-identical.
    case blocked(AgentSessionLinkSendFailure)
}

extension AgentSessionLinkSteerAdmission {
    /// Pure admission over facts read from one exact live target.
    ///
    /// Ordering is the contract: identity and loading first, then an idle target goes to the strict
    /// send path, then a prompt anywhere blocks (a steer never routes around one), then transient
    /// between-state flags, and only then the provider route.
    static func evaluate(
        readiness: AgentSessionLinkDeliveryReadiness.Snapshot,
        runStateIsActive: Bool,
        pendingPromptExists: Bool,
        route: AgentSessionLinkManagedSteerRoute?
    ) -> AgentSessionLinkSteerAdmission {
        switch AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness) {
        case .ready:
            return .idleTurn
        case .blocked(.endpointInvalidated):
            return .blocked(.endpointInvalidated)
        case .blocked(.targetLoading):
            return .blocked(.targetLoading)
        case .blocked(.targetNotIdle):
            break
        }
        if pendingPromptExists {
            return .blocked(.targetAwaitingInteraction)
        }
        guard runStateIsActive else {
            // Idle but not yet send-ready: a last turn still committing, a queued instruction or
            // wake still draining, or a location change in progress. The strict send path is the
            // only idle path, so wait for it rather than racing it.
            return .blocked(.targetBusy)
        }
        if readiness.stopInProgress
            || readiness.terminalCommitInProgress
            || readiness.isComposerSubmissionInFlight
            || readiness.isPreparingInitialWorktree
            || readiness.isChangingExecutionLocation
        {
            return .blocked(.targetBusy)
        }
        guard let route else { return .blocked(.steerUnavailable) }
        return .steer(route)
    }
}

/// Immutable submission data shared by noncomposer callers. The exact endpoint is a dispatch
/// fence, not a grant: each caller proves its own authority before entering submission.
struct AgentNoncomposerTurn {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let providerText: String
    let attribution: AgentCrossSessionAttribution?
    let sink: AgentSessionLinkManagedSteerSink

    init(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        providerText: String,
        attribution: AgentCrossSessionAttribution? = nil,
        sink: AgentSessionLinkManagedSteerSink
    ) {
        self.endpoint = endpoint
        self.providerText = providerText
        self.attribution = attribution
        self.sink = sink
    }

    init(managed turn: AgentSessionLinkManagedTurn) {
        endpoint = turn.candidate.domainEndpoint
        providerText = turn.providerText
        attribution = turn.attribution
        sink = turn.sink
    }
}
