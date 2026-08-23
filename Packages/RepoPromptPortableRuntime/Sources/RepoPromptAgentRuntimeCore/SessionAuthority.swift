import Foundation
import RepoPromptRuntimeModel

public enum ProviderOutputMutation: Sendable, Equatable {
    case appendToActiveEntry
    case replaceActiveEntry
    case appendEntry
}

public struct ProviderOutputProposal: Sendable {
    public let snapshot: SessionSnapshot
    public let activeEntryKey: String?
    public let activeEntryID: UUID?

    public init(snapshot: SessionSnapshot, activeEntryKey: String?, activeEntryID: UUID?) {
        self.snapshot = snapshot
        self.activeEntryKey = activeEntryKey
        self.activeEntryID = activeEntryID
    }
}

public struct StartTransitionProposal: Sendable {
    public let binding: RunBindingIdentity
    public let preparedSnapshot: SessionSnapshot
    public let runningSnapshot: SessionSnapshot

    public init(binding: RunBindingIdentity, preparedSnapshot: SessionSnapshot, runningSnapshot: SessionSnapshot) {
        self.binding = binding
        self.preparedSnapshot = preparedSnapshot
        self.runningSnapshot = runningSnapshot
    }
}

public actor SessionAuthority {
    public struct State: Sendable {
        public var snapshot: SessionSnapshot
        public var activeRunID: UUID?
        public var gate: AgentRunLifecycleGate?
    }

    private var state: State
    private var activeProviderEntryIDs: [String: UUID] = [:]
    private let clock: any RuntimeClock
    private let ids: any RuntimeIDGenerator

    public init(snapshot: SessionSnapshot, clock: any RuntimeClock, ids: any RuntimeIDGenerator) {
        state = State(snapshot: snapshot, activeRunID: nil, gate: nil)
        self.clock = clock
        self.ids = ids
    }

    public func snapshot() -> SessionSnapshot {
        state.snapshot
    }

    public func beginRun(connectionGeneration: Int64, runID: UUID? = nil) throws -> RunBindingIdentity {
        guard state.activeRunID == nil else { throw ServiceAPIError(code: .runAlreadyActive, message: "A run is already active") }
        let runID = runID ?? ids.next()
        let binding = RunBindingIdentity(runID: runID, generation: state.snapshot.runGeneration + 1, turnEpoch: state.snapshot.turnEpoch + 1, connectionGeneration: connectionGeneration)
        state.activeRunID = runID
        state.gate = AgentRunLifecycleGate(binding: binding)
        activeProviderEntryIDs.removeAll(keepingCapacity: true)
        replaceSnapshot(state: .running, generation: binding.generation, epoch: binding.turnEpoch)
        return binding
    }

    public func proposeStart(connectionGeneration: Int64, runID: UUID? = nil) throws -> StartTransitionProposal {
        guard state.activeRunID == nil else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A run is already active")
        }
        let runID = runID ?? ids.next()
        let binding = RunBindingIdentity(
            runID: runID,
            generation: state.snapshot.runGeneration + 1,
            turnEpoch: state.snapshot.turnEpoch + 1,
            connectionGeneration: connectionGeneration
        )
        let prepared = state.snapshot.replacing(
            state: .preparing,
            runGeneration: binding.generation,
            turnEpoch: binding.turnEpoch,
            revision: state.snapshot.revision + 1
        )
        let running = prepared.replacing(state: .running, revision: prepared.revision + 1)
        return StartTransitionProposal(
            binding: binding,
            preparedSnapshot: prepared,
            runningSnapshot: running
        )
    }

    public func proposeLifecycle(
        binding: RunBindingIdentity,
        state lifecycle: SessionLifecycleState
    ) throws -> SessionSnapshot {
        guard state.gate?.binding == binding else {
            throw ServiceAPIError(code: .staleRevision, message: "Run binding is stale")
        }
        return state.snapshot.replacing(
            state: lifecycle,
            revision: state.snapshot.revision + 1
        )
    }

    /// Applies only a snapshot returned by the durable transition transaction.
    /// Callers propose without mutation, commit, then install the exact snapshot.
    public func applyCommitted(
        _ snapshot: SessionSnapshot,
        binding: RunBindingIdentity?,
        terminal: Bool
    ) {
        guard snapshot.revision >= state.snapshot.revision else { return }
        if let binding, let current = state.gate?.binding {
            guard binding.runID == current.runID,
                  binding.generation == current.generation,
                  binding.turnEpoch >= current.turnEpoch,
                  binding.connectionGeneration >= current.connectionGeneration
            else { return }
        }
        state.snapshot = snapshot
        if terminal {
            state.activeRunID = nil
            state.gate = nil
            activeProviderEntryIDs.removeAll(keepingCapacity: true)
        } else if let binding {
            state.activeRunID = binding.runID
            state.gate = AgentRunLifecycleGate(binding: binding)
            activeProviderEntryIDs.removeAll(keepingCapacity: true)
        }
    }

    public func acceptProviderOutput(binding: RunBindingIdentity, kind: TranscriptEntry.Kind, content: String, mutation: ProviderOutputMutation, channel: String? = nil) -> LifecycleAcceptance {
        guard var gate = state.gate else { return .staleGeneration }
        let result = gate.accept(binding: binding)
        state.gate = gate
        guard result == .accepted else { return result }
        var transcript = state.snapshot.transcript
        let bounded = String(content.prefix(262_144))
        let key = "\(kind.rawValue):\(channel ?? "default")"
        if mutation != .appendEntry,
           let entryID = activeProviderEntryIDs[key],
           let index = transcript.firstIndex(where: { $0.entryID == entryID })
        {
            let current = transcript[index]
            let nextContent = switch mutation {
            case .appendToActiveEntry:
                String((current.content + bounded).prefix(262_144))
            case .replaceActiveEntry:
                bounded
            case .appendEntry:
                bounded
            }
            transcript[index] = TranscriptEntry(
                entryID: current.entryID,
                sessionSequence: current.sessionSequence,
                kind: current.kind,
                content: nextContent,
                actor: current.actor,
                timestamp: current.timestamp,
                presentationPayload: current.presentationPayload
            )
        } else {
            let entryID = ids.next()
            transcript.append(TranscriptEntry(
                entryID: entryID,
                sessionSequence: (transcript.map(\.sessionSequence).max() ?? 0) + 1,
                kind: kind,
                content: bounded,
                actor: nil,
                timestamp: clock.now()
            ))
            if mutation != .appendEntry {
                activeProviderEntryIDs[key] = entryID
            }
        }
        replaceSnapshot(transcript: transcript)
        return .accepted
    }

    /// Pure provider-output proposal. The returned snapshot must be committed by
    /// the store before `applyCommittedProviderOutput` installs it in memory.
    public func proposeProviderOutput(binding: RunBindingIdentity, kind: TranscriptEntry.Kind, content: String, mutation: ProviderOutputMutation, channel: String? = nil) throws -> ProviderOutputProposal {
        guard var gate = state.gate else {
            throw ServiceAPIError(code: .staleRevision, message: "Provider output has no active run")
        }
        guard gate.accept(binding: binding) == .accepted else {
            throw ServiceAPIError(code: .staleRevision, message: "Provider output run binding is stale")
        }
        var transcript = state.snapshot.transcript
        let bounded = String(content.prefix(262_144))
        let key = "\(kind.rawValue):\(channel ?? "default")"
        let activeEntryID = activeProviderEntryIDs[key] ?? Self.stableProviderEntryID(runID: binding.runID, key: key)
        var proposedEntryID: UUID?
        if mutation != .appendEntry,
           let index = transcript.firstIndex(where: { $0.entryID == activeEntryID })
        {
            let current = transcript[index]
            let nextContent = switch mutation {
            case .appendToActiveEntry: String((current.content + bounded).prefix(262_144))
            case .replaceActiveEntry, .appendEntry: bounded
            }
            transcript[index] = TranscriptEntry(entryID: current.entryID, sessionSequence: current.sessionSequence, kind: current.kind, content: nextContent, actor: current.actor, timestamp: current.timestamp, presentationPayload: current.presentationPayload)
            proposedEntryID = activeEntryID
        } else {
            let entryID = mutation == .appendEntry ? ids.next() : Self.stableProviderEntryID(runID: binding.runID, key: key)
            transcript.append(TranscriptEntry(entryID: entryID, sessionSequence: (transcript.map(\.sessionSequence).max() ?? 0) + 1, kind: kind, content: bounded, actor: nil, timestamp: clock.now()))
            proposedEntryID = mutation == .appendEntry ? nil : entryID
        }
        return ProviderOutputProposal(
            snapshot: state.snapshot.replacing(revision: state.snapshot.revision + 1, transcript: transcript),
            activeEntryKey: mutation == .appendEntry ? nil : key,
            activeEntryID: proposedEntryID
        )
    }

    public func applyCommittedProviderOutput(_ proposal: ProviderOutputProposal, snapshot: SessionSnapshot) {
        guard snapshot.revision >= state.snapshot.revision else { return }
        state.snapshot = snapshot
        if let key = proposal.activeEntryKey, let entryID = proposal.activeEntryID {
            activeProviderEntryIDs[key] = entryID
        }
    }

    public func applyCommittedProjection(_ snapshot: SessionSnapshot) {
        guard snapshot.revision >= state.snapshot.revision else { return }
        state.snapshot = snapshot
    }

    private static func stableProviderEntryID(runID: UUID, key: String) -> UUID {
        let bytes = Array("\(runID.uuidString.lowercased())\u{0}\(key)".utf8)
        func hash(seed: UInt64) -> UInt64 {
            bytes.reduce(seed) { value, byte in (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        let high = hash(seed: 14_695_981_039_346_656_037)
        let low = hash(seed: 1_099_511_628_211)
        let raw: uuid_t = (
            UInt8(truncatingIfNeeded: high >> 56), UInt8(truncatingIfNeeded: high >> 48), UInt8(truncatingIfNeeded: high >> 40), UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24), UInt8(truncatingIfNeeded: high >> 16), UInt8(truncatingIfNeeded: high >> 8), UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56), UInt8(truncatingIfNeeded: low >> 48), UInt8(truncatingIfNeeded: low >> 40), UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24), UInt8(truncatingIfNeeded: low >> 16), UInt8(truncatingIfNeeded: low >> 8), UInt8(truncatingIfNeeded: low)
        )
        return UUID(uuid: raw)
    }

    public func settle(binding: RunBindingIdentity, terminal: EventType, lifecycle: SessionLifecycleState) -> LifecycleAcceptance {
        guard var gate = state.gate else { return .staleGeneration }
        let result = gate.accept(binding: binding, terminal: terminal)
        state.gate = gate
        guard result == .accepted else { return result }
        state.activeRunID = nil
        activeProviderEntryIDs.removeAll(keepingCapacity: true)
        replaceSnapshot(state: lifecycle)
        return .accepted
    }

    public func appendHumanMessage(
        _ text: String,
        actor: ExternalActor,
        expectedRevision: Int64,
        presentationPayload: Data? = nil
    ) throws {
        guard expectedRevision == state.snapshot.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: state.snapshot.revision) }
        var transcript = state.snapshot.transcript
        transcript.append(TranscriptEntry(
            entryID: ids.next(),
            sessionSequence: Int64(transcript.count + 1),
            kind: .human,
            content: text,
            actor: actor,
            timestamp: clock.now(),
            presentationPayload: presentationPayload
        ))
        replaceSnapshot(transcript: transcript)
    }

    public func appendExternalEntry(kind: TranscriptEntry.Kind, text: String, actor: ExternalActor, expectedRevision: Int64) throws {
        guard expectedRevision == state.snapshot.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: state.snapshot.revision) }
        guard [.human, .progress, .system, .tool].contains(kind) else {
            throw ServiceAPIError(code: .invalidRequest, message: "External transcript entry kind is not publishable")
        }
        var transcript = state.snapshot.transcript
        transcript.append(TranscriptEntry(entryID: ids.next(), sessionSequence: Int64(transcript.count + 1), kind: kind, content: text, actor: actor, timestamp: clock.now()))
        replaceSnapshot(transcript: transcript)
    }

    /// Appends output from another authority-owned runtime (for example Oracle
    /// or Context Builder). This is not an externally publishable operation;
    /// the headless authority serializes it with durable session publication.
    public func appendAuthorityEntry(kind: TranscriptEntry.Kind, text: String, actor: ExternalActor?) {
        var transcript = state.snapshot.transcript
        transcript.append(TranscriptEntry(entryID: ids.next(), sessionSequence: Int64(transcript.count + 1), kind: kind, content: text, actor: actor, timestamp: clock.now()))
        replaceSnapshot(transcript: transcript)
    }

    public func activeBinding() -> RunBindingIdentity? {
        guard state.activeRunID != nil else { return nil }
        return state.gate?.binding
    }

    public func proposeArchive(expectedRevision: Int64) throws -> SessionSnapshot {
        guard state.activeRunID == nil else { throw ServiceAPIError(code: .runAlreadyActive, message: "An active session cannot be archived") }
        guard expectedRevision == state.snapshot.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: state.snapshot.revision) }
        return state.snapshot.replacing(state: .archived, revision: state.snapshot.revision + 1)
    }

    public func proposeInactiveLifecycle(_ lifecycle: SessionLifecycleState) throws -> SessionSnapshot {
        guard lifecycle == .canceled || lifecycle == .interrupted else {
            throw ServiceAPIError(code: .invalidRequest, message: "Inactive sessions can only be canceled or interrupted")
        }
        guard state.activeRunID == nil else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "Session still has an active run")
        }
        guard ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains(state.snapshot.state) else {
            return state.snapshot
        }
        return state.snapshot.replacing(state: lifecycle, revision: state.snapshot.revision + 1)
    }

    public func updateVisibility(_ visibility: Visibility, expectedRevision: Int64) throws {
        guard expectedRevision == state.snapshot.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session policy revision is stale", currentRevision: state.snapshot.revision) }
        replaceSnapshot(visibility: visibility)
    }

    public func steer(_ text: String, actor: ExternalActor, targetTurnEpoch: Int64) throws -> RunBindingIdentity {
        guard var gate = state.gate, gate.binding.turnEpoch == targetTurnEpoch else {
            throw ServiceAPIError(code: .staleRevision, message: "Turn epoch is stale", currentRevision: state.snapshot.turnEpoch)
        }
        var transcript = state.snapshot.transcript
        transcript.append(TranscriptEntry(entryID: ids.next(), sessionSequence: Int64(transcript.count + 1), kind: .human, content: text, actor: actor, timestamp: clock.now()))
        gate.advanceTurn(runID: gate.binding.runID)
        state.gate = gate
        activeProviderEntryIDs.removeAll(keepingCapacity: true)
        replaceSnapshot(epoch: gate.binding.turnEpoch, transcript: transcript)
        return gate.binding
    }

    public func applyContextUsage(_ usage: ContextUsageWireSnapshot) {
        state.snapshot = state.snapshot.replacing(contextUsage: usage.merging(onto: state.snapshot.contextUsage))
    }

    private func replaceSnapshot(state lifecycle: SessionLifecycleState? = nil, generation: Int64? = nil, epoch: Int64? = nil, transcript: [TranscriptEntry]? = nil, visibility: Visibility? = nil) {
        let current = state.snapshot
        state.snapshot = current.replacing(
            visibility: visibility,
            state: lifecycle,
            runGeneration: generation,
            turnEpoch: epoch,
            revision: current.revision + 1,
            transcript: transcript
        )
    }
}
