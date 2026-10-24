import Foundation
import RepoPromptDomainRuntime

/// Immutable identity and attribution captured from the authorized link before routing.
struct AgentSessionLinkStopRequest: Equatable {
    let requestID: UUID
    let linkID: UUID
    let linkGeneration: UInt64
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let observerDisplayName: String?

    var attribution: AgentCrossSessionAttribution {
        AgentCrossSessionAttribution(
            sourceSessionID: observerEndpoint.sessionID,
            sourceName: observerDisplayName,
            linkID: linkID
        )
    }
}

enum AgentSessionLinkStopTransactionOutcome: Equatable {
    /// Includes a retained no-op or a failure after cancellation admission.
    case settled(DomainAgentSessionLinkStopReceipt)
    /// No cancellation was admitted; the ledger reservation can be abandoned.
    case blocked(AgentSessionLinkSendFailure)
}

/// Pure classification; pending interactions do not block stopping an active run.
enum AgentSessionLinkStopAdmission: Equatable {
    case activeRun
    case pendingStart
    case notRunning
    case blocked(AgentSessionLinkSendFailure)

    static func classify(_ snapshot: AgentSessionLinkDeliveryReadiness.Snapshot) -> Self {
        if !snapshot.endpointMatchesGrant || snapshot.isClosing { return .blocked(.endpointInvalidated) }
        if snapshot.bindingTransitionInProgress {
            return .blocked(.targetLoading)
        }
        if let reason = AgentSessionLinkDeliveryReadiness.restorationBlockReason(snapshot.restorationReadiness) {
            return .blocked(AgentSessionLinkSendFailure(reason))
        }
        if !snapshot.hasLoadedPersistedState {
            return .blocked(.targetLoading)
        }
        if snapshot.terminalCommitInProgress || snapshot.isComposerSubmissionInFlight
            || snapshot.isPreparingInitialWorktree || snapshot.isChangingExecutionLocation
            || snapshot.selfCompactBlocksManagedStop
            || snapshot.stopInProgress
        {
            return .blocked(.targetBusy)
        }
        if snapshot.runStateIsActive { return .activeRun }
        // Queued instructions are cancellable work even if a failed scheduled start has
        // already cleared its own pending flag. Stop must own their withdrawal.
        if snapshot.mcpFollowUpRunPending || snapshot.pendingInstructionCount > 0 { return .pendingStart }
        return .notRunning
    }
}

/// App-owned completion signal. A timed-out MCP waiter never cancels the cleanup task.
@MainActor
final class AgentSessionLinkStopSignal<Value> {
    private var result: Value?
    private var continuations: [CheckedContinuation<Value, Never>] = []

    func finish(_ value: Value) {
        guard result == nil else { return }
        result = value
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume(returning: value)
        }
    }

    func value() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { continuations.append($0) }
    }
}
