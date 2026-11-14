import Foundation

extension AgentSessionRuntimeStore.Scope {
    /// Synchronous MainActor half of settlement. Provider actor/domain-registration probes stay
    /// with the prepared owner and must be revalidated across their awaits. This query creates
    /// no admission or save receipt; a clean payload is meaningful only after its owner's save.
    struct Settlement: Equatable {
        enum Blocker: Hashable {
            case notInstalled, run, pendingStart, provider, effects, durability
        }

        let blockers: Set<Blocker>
        // Phase-0 compatibility projections preserve the three predicates being consolidated.
        // Existing callers must not adopt the full drain policy before host-owned retirement and
        // settlement wakeups are installed. Retire these projections with that cutover.
        var legacyPreparedOwnerIsIdle = false
        var legacyPreparedHandoffIsSettled = false
        var legacyDrainCanRelease = false
        var isSettled: Bool {
            blockers.isEmpty
        }

        /// Existing handoff preparation may join effects and flush a dirty payload. Neither is
        /// permission to hand off: the final synchronous check must require `isSettled`.
        var isQuiescent: Bool {
            blockers.subtracting([.effects, .durability]).isEmpty
        }
    }

    func settlement(for session: AgentTabSession) -> Settlement {
        guard sessions[session.tabID] === session else { return .init(blockers: [.notInstalled]) }
        var blockers: Set<Settlement.Blocker> = []
        if session.runState.isActive || session.terminalCommitInProgress || session.activeRunOwnership != nil
            || (session.lastTerminalCommitRevision != nil && execution?.providerSwitchTerminalIsSettled(session) != true)
        {
            blockers.insert(.run)
        }
        if session.isComposerSubmissionInFlight || continuation.hasPendingStarts(for: session)
            || session.mcpFollowUpRunPending || session.scheduledACPFollowUp != nil
            || !session.pendingInstructions.isEmpty || session.selfCompactAdmissionPendingID != nil
        {
            blockers.insert(.pendingStart)
        }
        if session.codexPendingTurnKind != nil || session.codexFallbackDispatchInFlight != nil
            || session.codexFallbackPumpTask != nil || !session.codexFallbackQueue.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty || !session.pendingACPSteeringInstructions.isEmpty
        {
            blockers.insert(.provider)
        }
        let identity = ObjectIdentifier(session)
        if session.activeAgentSessionID.map({ saveQueue.inFlightSessionIDs.contains($0) }) == true
            || attachments.hasPendingRetention(for: session) || installedInteractions?.hasPendingEffects(for: session) == true
            || linkExecution?.pendingSendEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
            || linkExecution?.pendingManagedInputEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
            || linkExecution?.pendingStopEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
        {
            blockers.insert(.effects)
        }
        let deleted = session.activeAgentSessionID.map {
            AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: $0)
        } == true
        if session.isDirty, !deleted { blockers.insert(.durability) }
        return .init(
            blockers: blockers,
            legacyPreparedOwnerIsIdle: !session.runState.isActive,
            legacyPreparedHandoffIsSettled: !session.runState.isActive && !session.isDirty,
            legacyDrainCanRelease: !session.runState.isActive && !session.isComposerSubmissionInFlight
                && !session.terminalCommitInProgress && (!session.isDirty || deleted)
        )
    }
}
