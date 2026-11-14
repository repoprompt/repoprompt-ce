import Foundation

extension AgentSessionRuntimeStore.Scope {
    /// Subscribe before checking settlement. Buffered invalidations cannot be lost between a
    /// producer finalizer and the next await. This is scope-local, not link candidate readiness.
    func observeSettlement() -> (UUID, AsyncStream<Void>) {
        let id = UUID()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            settlementObservers[id] = continuation
        }
        return (id, stream)
    }

    func removeSettlementObserver(_ id: UUID) {
        settlementObservers.removeValue(forKey: id)?.finish()
    }

    func noteSettlementChanged() {
        for observer in settlementObservers.values {
            observer.yield(())
        }
    }

    /// Synchronous MainActor half of settlement. Provider actor/domain-registration probes stay
    /// with the prepared owner and must be revalidated across their awaits. This query creates
    /// no admission or save receipt; a clean payload is meaningful only after its owner's save.
    struct Settlement: Equatable {
        enum Blocker: Hashable {
            case notInstalled, run, pendingStart, provider, effects, durability, worktree, terminalTeardown, drainCapability
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

        /// Teardown has its own existing join, not a readiness signal. A host may join it
        /// once run/attempt publication is complete, but must still require full settlement.
        var canJoinHostDrain: Bool {
            blockers.subtracting([.effects, .durability, .terminalTeardown]).isEmpty
        }
    }

    func settlement(for session: AgentTabSession) -> Settlement {
        guard sessions[session.tabID] === session else { return .init(blockers: [.notInstalled]) }
        var blockers: Set<Settlement.Blocker> = []
        if session.runState.isActive || session.terminalCommitInProgress || session.activeRunOwnership != nil
            || session.activeRunLiveness != nil || session.pendingSupersedingTurnCompletions != 0
        {
            blockers.insert(.run)
        }
        if session.lastTerminalCommitRevision != nil, execution?.providerSwitchTerminalIsSettled(session) != true {
            blockers.insert(.terminalTeardown)
        }
        if session.isComposerSubmissionInFlight || continuation.hasPendingStarts(for: session)
            || session.mcpFollowUpRunPending || session.scheduledACPFollowUp != nil
            || !session.pendingInstructions.isEmpty || session.selfCompactAdmissionPendingID != nil
            || session.bindingTransitionInProgress || session.isPreparingInitialWorktree || session.isChangingExecutionLocation
            || session.oversight.pendingAutoWake != nil
        {
            blockers.insert(.pendingStart)
        }
        if session.codexPendingTurnKind != nil || session.codexFallbackDispatchInFlight != nil
            || session.codexFallbackPumpTask != nil || !session.codexFallbackQueue.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty || !session.pendingACPSteeringInstructions.isEmpty
            || session.claudeSteeringFlushTask != nil || session.acpSteeringFlushTask != nil
            || !session.codexNativeToolLiveness.inFlight.isEmpty || session.isSettlingACPBackgroundCompaction
            || session.hasBindingBlockingInteraction
        {
            blockers.insert(.provider)
        }
        if worktrees.pendingTransitions != 0 { blockers.insert(.worktree) }
        let identity = ObjectIdentifier(session)
        if session.activeAgentSessionID.map({ saveQueue.inFlightSessionIDs.contains($0) }) == true
            || attachments.hasPendingRetention(for: session) || installedInteractions?.hasPendingEffects(for: session) == true
            || linkExecution?.pendingSendEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
            || linkExecution?.pendingManagedInputEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
            || linkExecution?.pendingStopEffects.values.contains(where: { $0.sessionIdentity == identity }) == true
        {
            blockers.insert(.effects)
        }
        if let retainedDrain { blockers.formUnion(retainedDrain.effectBlockers(for: session)) }
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
