import Foundation
import RepoPromptAgentRuntime
import RepoPromptDomainRuntime

/// Terminal outcome an Agent Mode runner commits when `MCPBootstrapLease.acquire()` returns `false`.
///
/// A gate deadline is a retryable failure the user must see; every other acquire failure
/// (cancellation, release, enabler or routing failure) remains an intentional cancel.
struct MCPBootstrapLeaseAcquireFailureOutcome: Equatable {
    let terminalState: AgentSessionRunState
    let errorText: String?

    init(timedOut: Bool) {
        if timedOut {
            terminalState = .failed
            errorText = HeadlessAgentConnectionAcquireTimeoutError().localizedDescription
        } else {
            terminalState = .cancelled
            errorText = nil
        }
    }
}

/// Agent Mode owns terminal presentation policy; MCP infrastructure exposes only the
/// acquisition fact. Keep the mapping in this layer, not in MCPBootstrapLease.swift.
extension MCPBootstrapLease {
    /// How a runner should finalize after `acquire()` returned `false`.
    var acquireFailureOutcome: MCPBootstrapLeaseAcquireFailureOutcome {
        MCPBootstrapLeaseAcquireFailureOutcome(timedOut: lastAcquireWasTimeout)
    }
}

extension AgentSessionRunState {
    var isTerminalForCommit: Bool {
        self == .completed || self == .cancelled || self == .failed
    }

    /// MCP snapshot status equivalent of a committed terminal run state.
    var mcpTerminalSnapshotStatus: DomainAgentRunSnapshot.Status? {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval: nil
        }
    }
}

typealias AgentRunAttemptLifecycle = RepoPromptAgentRuntime.AgentRunAttemptLifecycle
typealias AgentRunAttemptTerminalResources = RepoPromptAgentRuntime.AgentRunAttemptTerminalResources
typealias AgentRunBindingIdentity = RepoPromptAgentRuntime.AgentRunBindingIdentity
typealias AgentRunEpochTransitionKind = RepoPromptAgentRuntime.AgentRunEpochTransitionKind
typealias AgentRunLifecycleStage = RepoPromptAgentRuntime.AgentRunLifecycleStage
typealias AgentRunLifecycleTracker = RepoPromptAgentRuntime.AgentRunLifecycleTracker
typealias AgentRunLivenessSignalKind = RepoPromptAgentRuntime.AgentRunLivenessSignalKind
typealias AgentRunLivenessSnapshot = RepoPromptAgentRuntime.AgentRunLivenessSnapshot
typealias AgentRunOwnership = RepoPromptAgentRuntime.AgentRunOwnership
typealias AgentRunPendingInstruction = RepoPromptAgentRuntime.AgentRunPendingInstruction
typealias AgentRunProgressAcceptance = RepoPromptAgentRuntime.AgentRunProgressAcceptance
typealias AgentRunProgressRejection = RepoPromptAgentRuntime.AgentRunProgressRejection
typealias AgentRunProgressSignal = RepoPromptAgentRuntime.AgentRunProgressSignal
typealias AgentRunRetryIntent = RepoPromptAgentRuntime.AgentRunRetryIntent
typealias AgentRunStartStopFence = RepoPromptAgentRuntime.AgentRunStartStopFence
typealias AgentRunTerminalCommitBarrier = RepoPromptAgentRuntime.AgentRunTerminalCommitBarrier
typealias AgentRunTerminalCommitRevision = RepoPromptAgentRuntime.AgentRunTerminalCommitRevision
typealias AgentRunTerminalPublicationEnvelope = RepoPromptAgentRuntime.AgentRunTerminalPublicationEnvelope
typealias AgentRunTerminalPublicationResult = RepoPromptAgentRuntime.AgentRunTerminalPublicationResult
typealias AgentRunTerminalSessionBinding = RepoPromptAgentRuntime.AgentRunTerminalSessionBinding
typealias AgentRunTurnEpoch = RepoPromptAgentRuntime.AgentRunTurnEpoch
