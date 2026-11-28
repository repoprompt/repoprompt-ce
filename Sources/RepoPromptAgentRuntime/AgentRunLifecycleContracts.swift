import Foundation
import RepoPromptDomainRuntime

/// Runtime-only snapshot of the tab/session binding captured when a run attempt begins.
///
/// `generation` is intentionally an ephemeral attempt activation token. It is not the
/// authoritative persistent binding generation introduced by the later binding-hardening work.
package struct AgentRunBindingIdentity: Equatable, Hashable {
    package let tabID: UUID
    package let persistentSessionID: UUID?
    package let persistentBindingGeneration: UUID?
    package let bindingTransitionGeneration: UInt64
    package let generation: UUID

    package init(
        tabID: UUID,
        persistentSessionID: UUID?,
        persistentBindingGeneration: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0,
        generation: UUID = UUID()
    ) {
        self.tabID = tabID
        self.persistentSessionID = persistentSessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
        self.generation = generation
    }
}

package typealias AgentRunEpochTransitionKind = DomainAgentRunEpochTransitionKind
package typealias AgentRunTurnEpoch = DomainAgentRunTurnEpoch
package typealias AgentRunTerminalPublicationEnvelope = DomainAgentRunTerminalPublicationEnvelope
package typealias AgentRunTerminalPublicationResult = DomainAgentRunTerminalPublicationResult

/// Provider-neutral ownership token for one logical run attempt.
package struct AgentRunOwnership: Equatable, Hashable {
    package let attemptID: UUID
    package let binding: AgentRunBindingIdentity
    package let turnEpoch: AgentRunTurnEpoch?

    package init(
        attemptID: UUID = UUID(),
        binding: AgentRunBindingIdentity,
        turnEpoch: AgentRunTurnEpoch? = nil
    ) {
        self.attemptID = attemptID
        self.binding = binding
        self.turnEpoch = turnEpoch
    }
}

@MainActor
package final class AgentRunAttemptTerminalResources {
    package typealias Teardown = @MainActor () async -> Void
    package typealias Prepare = @MainActor (_ terminalState: AgentSessionRunState) -> Teardown?

    package let ownership: AgentRunOwnership
    private let prepare: Prepare
    package private(set) var isClaimed = false

    init(ownership: AgentRunOwnership, prepare: @escaping Prepare) {
        self.ownership = ownership
        self.prepare = prepare
    }

    package func claim(for ownership: AgentRunOwnership, terminalState: AgentSessionRunState) -> Teardown? {
        guard !isClaimed, self.ownership == ownership else { return nil }
        isClaimed = true
        return prepare(terminalState)
    }
}

package enum AgentRunLifecycleStage: String, Equatable, Hashable {
    case starting
    case preparingRuntime
    case running
    case waitingForInteraction
    case retrying
    case cancelling
}

package enum AgentRunLivenessSignalKind: String, Equatable, Hashable {
    case stageTransition
    case providerEvent
    case toolActivity
    case interaction
    case heartbeat

    package var isRealProgress: Bool {
        self != .heartbeat
    }
}

package enum AgentRunRetryIntent: String, Equatable, Hashable {
    case none
    case providerManaged
    case applicationManaged
}

package struct AgentRunProgressSignal: Equatable {
    package let ownership: AgentRunOwnership
    package let sequence: UInt64
    package let timestampUptimeNanoseconds: UInt64
    package let kind: AgentRunLivenessSignalKind
    package let stage: AgentRunLifecycleStage
    package let retryIntent: AgentRunRetryIntent

    package init(
        ownership: AgentRunOwnership, sequence: UInt64, timestampUptimeNanoseconds: UInt64,
        kind: AgentRunLivenessSignalKind, stage: AgentRunLifecycleStage, retryIntent: AgentRunRetryIntent
    ) {
        self.ownership = ownership
        self.sequence = sequence
        self.timestampUptimeNanoseconds = timestampUptimeNanoseconds
        self.kind = kind
        self.stage = stage
        self.retryIntent = retryIntent
    }
}

package struct AgentRunLivenessSnapshot: Equatable {
    package let ownership: AgentRunOwnership
    package internal(set) var stage: AgentRunLifecycleStage
    package internal(set) var retryIntent: AgentRunRetryIntent
    package internal(set) var lastAcceptedSequence: UInt64
    package internal(set) var lastSignalUptimeNanoseconds: UInt64
    package internal(set) var lastRealProgressUptimeNanoseconds: UInt64
    package internal(set) var lastHeartbeatUptimeNanoseconds: UInt64?
}

package enum AgentRunProgressRejection: String, Equatable {
    case noActiveOwnership
    case staleOwnership
    case duplicateSequence
    case outOfOrderSequence
    case nonMonotonicTimestamp
}

package enum AgentRunProgressAcceptance: Equatable {
    case accepted(AgentRunLivenessSnapshot)
    case rejected(AgentRunProgressRejection)
}

/// Provider-neutral, non-rendering lifecycle/liveness reducer.
///
/// This tracker never mutates transcript, persistence, UI bindings, or provider state.
package struct AgentRunLifecycleTracker: Equatable {
    package private(set) var activeOwnership: AgentRunOwnership?
    package private(set) var liveness: AgentRunLivenessSnapshot?
    private var nextSequence: UInt64 = 1

    package init() {}

    package mutating func begin(
        tabID: UUID,
        persistentSessionID: UUID?,
        persistentBindingGeneration: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0,
        attemptID: UUID = UUID(),
        turnEpoch: AgentRunTurnEpoch? = nil,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AgentRunOwnership {
        let ownership = AgentRunOwnership(
            attemptID: attemptID,
            binding: AgentRunBindingIdentity(
                tabID: tabID,
                persistentSessionID: persistentSessionID,
                persistentBindingGeneration: persistentBindingGeneration,
                bindingTransitionGeneration: bindingTransitionGeneration
            ),
            turnEpoch: turnEpoch
        )
        activeOwnership = ownership
        liveness = AgentRunLivenessSnapshot(
            ownership: ownership,
            stage: .starting,
            retryIntent: .none,
            lastAcceptedSequence: 0,
            lastSignalUptimeNanoseconds: timestampUptimeNanoseconds,
            lastRealProgressUptimeNanoseconds: timestampUptimeNanoseconds,
            lastHeartbeatUptimeNanoseconds: nil
        )
        nextSequence = 1
        return ownership
    }

    @discardableResult
    package mutating func record(
        ownership: AgentRunOwnership,
        kind: AgentRunLivenessSignalKind,
        stage: AgentRunLifecycleStage,
        retryIntent: AgentRunRetryIntent = .none,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AgentRunProgressAcceptance {
        let signal = AgentRunProgressSignal(
            ownership: ownership,
            sequence: nextSequence,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds,
            kind: kind,
            stage: stage,
            retryIntent: retryIntent
        )
        nextSequence &+= 1
        return accept(signal)
    }

    @discardableResult
    package mutating func accept(_ signal: AgentRunProgressSignal) -> AgentRunProgressAcceptance {
        guard let activeOwnership, var snapshot = liveness else {
            return .rejected(.noActiveOwnership)
        }
        guard signal.ownership == activeOwnership else {
            return .rejected(.staleOwnership)
        }
        if signal.sequence == snapshot.lastAcceptedSequence {
            return .rejected(.duplicateSequence)
        }
        guard signal.sequence > snapshot.lastAcceptedSequence else {
            return .rejected(.outOfOrderSequence)
        }
        guard signal.timestampUptimeNanoseconds >= snapshot.lastSignalUptimeNanoseconds else {
            return .rejected(.nonMonotonicTimestamp)
        }

        snapshot.stage = signal.stage
        snapshot.retryIntent = signal.retryIntent
        snapshot.lastAcceptedSequence = signal.sequence
        snapshot.lastSignalUptimeNanoseconds = signal.timestampUptimeNanoseconds
        if signal.kind == .heartbeat {
            snapshot.lastHeartbeatUptimeNanoseconds = signal.timestampUptimeNanoseconds
        } else {
            snapshot.lastRealProgressUptimeNanoseconds = signal.timestampUptimeNanoseconds
        }
        liveness = snapshot
        nextSequence = max(nextSequence, signal.sequence &+ 1)
        return .accepted(snapshot)
    }

    @discardableResult
    package mutating func end(ifCurrent expectedOwnership: AgentRunOwnership? = nil) -> Bool {
        guard let activeOwnership else { return false }
        if let expectedOwnership, expectedOwnership != activeOwnership {
            return false
        }
        self.activeOwnership = nil
        liveness = nil
        nextSequence = 1
        return true
    }
}
