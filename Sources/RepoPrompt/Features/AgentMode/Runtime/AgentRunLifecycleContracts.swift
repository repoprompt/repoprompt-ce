import Foundation

/// Runtime-only snapshot of the tab/session binding captured when a run attempt begins.
///
/// `generation` is intentionally an ephemeral attempt activation token. It is not the
/// authoritative persistent binding generation introduced by the later binding-hardening work.
struct AgentRunBindingIdentity: Equatable, Hashable {
    let tabID: UUID
    let persistentSessionID: UUID?
    let persistentBindingGeneration: UUID?
    let bindingTransitionGeneration: UInt64
    let generation: UUID

    init(
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

/// Describes how a newly activated turn relates to the preceding turn in the same session.
enum AgentRunEpochTransitionKind: String, Equatable, Hashable {
    case initial
    case relatedFollowUp
    case steering
    case unrelated
}

struct AgentRunTurnEpoch: Equatable, Hashable {
    let sessionID: UUID
    let activationID: UUID
    let registrationGeneration: UInt64
    let id: UUID
    let ordinal: UInt64
    let continuityGeneration: UInt64
    let transitionKind: AgentRunEpochTransitionKind
}

struct AgentRunTerminalPublicationEnvelope: Equatable {
    let epoch: AgentRunTurnEpoch
    let snapshot: AgentRunMCPSnapshot
}

enum AgentRunTerminalPublicationResult: Equatable {
    case accepted(successorEpoch: AgentRunTurnEpoch?)
    case stale
    case rejected(reason: String)

    var successorEpoch: AgentRunTurnEpoch? {
        guard case let .accepted(successorEpoch) = self else { return nil }
        return successorEpoch
    }

    var isResolved: Bool {
        switch self {
        case .accepted, .stale:
            true
        case .rejected:
            false
        }
    }
}

/// Provider-neutral ownership token for one logical run attempt.
struct AgentRunOwnership: Equatable, Hashable {
    let attemptID: UUID
    let binding: AgentRunBindingIdentity
    let turnEpoch: AgentRunTurnEpoch?

    init(
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
final class AgentRunAttemptTerminalResources {
    typealias Teardown = @MainActor () async -> Void
    typealias Prepare = @MainActor (_ terminalState: AgentSessionRunState) -> Teardown?

    let ownership: AgentRunOwnership
    private let prepare: Prepare
    private(set) var isClaimed = false

    init(ownership: AgentRunOwnership, prepare: @escaping Prepare) {
        self.ownership = ownership
        self.prepare = prepare
    }

    func claim(for ownership: AgentRunOwnership, terminalState: AgentSessionRunState) -> Teardown? {
        guard !isClaimed, self.ownership == ownership else { return nil }
        isClaimed = true
        return prepare(terminalState)
    }
}

enum AgentRunLifecycleStage: String, Equatable, Hashable {
    case starting
    case preparingRuntime
    case running
    case waitingForInteraction
    case retrying
    case cancelling
}

enum AgentRunLivenessSignalKind: String, Equatable, Hashable {
    case stageTransition
    case providerEvent
    case toolActivity
    case interaction
    case heartbeat

    var isRealProgress: Bool {
        self != .heartbeat
    }
}

enum AgentRunRetryIntent: String, Equatable, Hashable {
    case none
    case providerManaged
    case applicationManaged
}

struct AgentRunProgressSignal: Equatable {
    let ownership: AgentRunOwnership
    let sequence: UInt64
    let timestampUptimeNanoseconds: UInt64
    let kind: AgentRunLivenessSignalKind
    let stage: AgentRunLifecycleStage
    let retryIntent: AgentRunRetryIntent
}

struct AgentRunLivenessSnapshot: Equatable {
    let ownership: AgentRunOwnership
    var stage: AgentRunLifecycleStage
    var retryIntent: AgentRunRetryIntent
    var lastAcceptedSequence: UInt64
    var lastSignalUptimeNanoseconds: UInt64
    var lastRealProgressUptimeNanoseconds: UInt64
    var lastHeartbeatUptimeNanoseconds: UInt64?
}

enum AgentRunProgressRejection: String, Equatable {
    case noActiveOwnership
    case staleOwnership
    case duplicateSequence
    case outOfOrderSequence
    case nonMonotonicTimestamp
}

enum AgentRunProgressAcceptance: Equatable {
    case accepted(AgentRunLivenessSnapshot)
    case rejected(AgentRunProgressRejection)
}

/// Provider-neutral, non-rendering lifecycle/liveness reducer.
///
/// This tracker never mutates transcript, persistence, UI bindings, or provider state.
struct AgentRunLifecycleTracker: Equatable {
    private(set) var activeOwnership: AgentRunOwnership?
    private(set) var liveness: AgentRunLivenessSnapshot?
    private var nextSequence: UInt64 = 1

    mutating func begin(
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
    mutating func record(
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
    mutating func accept(_ signal: AgentRunProgressSignal) -> AgentRunProgressAcceptance {
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
    mutating func end(ifCurrent expectedOwnership: AgentRunOwnership? = nil) -> Bool {
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
