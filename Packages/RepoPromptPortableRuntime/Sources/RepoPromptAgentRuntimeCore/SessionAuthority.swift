import Foundation
import RepoPromptRuntimeModel

public enum ProviderOutputMutation: Sendable, Equatable {
    case appendToActiveEntry
    case replaceActiveEntry
    case appendEntry
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

    public func archive(expectedRevision: Int64) throws {
        guard state.activeRunID == nil else { throw ServiceAPIError(code: .runAlreadyActive, message: "An active session cannot be archived") }
        guard expectedRevision == state.snapshot.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: state.snapshot.revision) }
        replaceSnapshot(state: .archived)
    }

    public func cancelWithoutActiveRun() throws {
        guard state.activeRunID == nil else { throw ServiceAPIError(code: .runAlreadyActive, message: "Session still has an active run") }
        guard ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains(state.snapshot.state) else { return }
        replaceSnapshot(state: .canceled)
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
