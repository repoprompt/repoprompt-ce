import Foundation
import RepoPromptDomainRuntime

extension DomainAgentSessionRegistration {
    init(sessionID: UUID, generation: UInt64) {
        let identity = AppDomainRuntimeComposition.shared.runtime.identity
        self.init(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            sessionID: sessionID,
            generation: generation
        )
    }
}

/// App compatibility adapter over the runtime-owned Agent session authority.
///
/// Existing view models keep the established static call surface while the mutable records,
/// epochs, waiters, terminal commits, TTL, persistence, and shutdown lifecycle live in the
/// process's single `MCPDomainRuntime` instance.
enum AgentRunSessionStore {
    typealias Registration = DomainAgentSessionRegistration
    typealias WaitCursor = DomainAgentSessionWaitCursor
    typealias EpochBeginResult = DomainAgentRunSessionStore.EpochBeginResult
    typealias WaitDisposition = DomainAgentRunSessionStore.WaitDisposition
    typealias WakeReason = DomainAgentRunSessionStore.WakeReason
    typealias NoteworthyWake = DomainAgentRunSessionStore.NoteworthyWake

    static var shared: DomainAgentRunSessionStore {
        AppDomainRuntimeComposition.shared.runtime.agentSessionStore
    }

    static func register(sessionID: UUID) async -> Registration {
        await shared.register(sessionID: sessionID)
    }

    static func registerIfMissing(sessionID: UUID) async -> Registration? {
        await shared.registerIfMissing(sessionID: sessionID)
    }

    static func claimResumableSession(
        sessionID: UUID
    ) async -> DomainAgentSessionResumeClaimResult {
        await shared.claimResumableSession(sessionID: sessionID)
    }

    static func beginEpoch(
        registration: Registration,
        activationID: UUID,
        expectedCurrentEpoch: AgentRunTurnEpoch?,
        transitionKind: AgentRunEpochTransitionKind,
        seedSnapshot: AgentRunMCPSnapshot? = nil
    ) async -> EpochBeginResult {
        await shared.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: expectedCurrentEpoch,
            transitionKind: transitionKind,
            seedSnapshot: seedSnapshot
        )
    }

    static func waitUntilInteresting(
        cursor: WaitCursor,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        await shared.waitUntilInteresting(cursor: cursor, timeoutSeconds: timeoutSeconds)
    }

    static func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        await shared.waitUntilInteresting(registration: registration, timeoutSeconds: timeoutSeconds)
    }

    static func snapshot(for cursor: WaitCursor) async -> AgentRunMCPSnapshot? {
        await shared.snapshot(for: cursor)
    }

    static func snapshot(for registration: Registration) async -> AgentRunMCPSnapshot? {
        await shared.snapshot(for: registration)
    }

    static func currentCursor(for registration: Registration) async -> WaitCursor? {
        await shared.currentCursor(for: registration)
    }

    static func currentRegistration(for sessionID: UUID) async -> Registration? {
        await shared.currentRegistration(for: sessionID)
    }

    static func currentEpoch(for registration: Registration) async -> AgentRunTurnEpoch? {
        await shared.currentEpoch(for: registration)
    }

    static func hasActiveRegistration(sessionID: UUID) async -> Bool {
        await shared.hasActiveRegistration(sessionID: sessionID)
    }

    static func cleanup(registration: Registration) async {
        await shared.cleanup(registration: registration)
    }

    @discardableResult
    static func installCancellationHandler(
        registration: Registration,
        handler: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await shared.installCancellationHandler(
            registration: registration,
            handler: handler
        )
    }

    static func removeCancellationHandler(registration: Registration) async {
        await shared.removeCancellationHandler(registration: registration)
    }

    static func signalSnapshot(_ snapshot: AgentRunMCPSnapshot, cursor: WaitCursor) async {
        await shared.noteSnapshot(snapshot, cursor: cursor)
    }

    static func publishTerminal(
        _ envelope: AgentRunTerminalPublicationEnvelope,
        registration: Registration,
        commitID: UUID,
        successorKind: AgentRunEpochTransitionKind?
    ) async -> AgentRunTerminalPublicationResult {
        await shared.publishTerminal(
            envelope,
            registration: registration,
            commitID: commitID,
            successorKind: successorKind
        )
    }

    static func signalSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) async {
        await shared.noteSnapshotAndWakeWaiters(
            snapshot,
            cursor: cursor,
            reason: reason,
            steeringMessage: steeringMessage,
            steeringOriginRunID: steeringOriginRunID
        )
    }

    static func wakeCurrentWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) async {
        await shared.wakeCurrentWaiters(
            snapshot,
            cursor: cursor,
            reason: reason,
            steeringMessage: steeringMessage,
            steeringOriginRunID: steeringOriginRunID
        )
    }
}
