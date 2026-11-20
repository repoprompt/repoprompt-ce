import Foundation
import MCP

/// One execution-worktree change a session requested for itself, owned by the exact run attempt
/// whose `manage_worktree` call asked for it.
///
/// A session's own `manage_worktree` mutation always arrives while that session's turn is active,
/// and that turn's native provider process cannot move to another cwd. Rerouting MCP tools beneath
/// it would split provider execution and tool authority across two checkouts, so the request is
/// recorded here instead. At the origin turn's completed terminal boundary the ordinary idle
/// `transitionWorktreeBindings(.externalManagement)` path applies it (provider retirement, staged
/// handoff, root ownership, durable save), and the session then starts one automatic continuation
/// turn in the new location. Nobody has to stop, rebind, or resume the session by hand.
///
/// Runtime-only: a relaunch drops it, exactly as it drops the origin turn it belongs to.
struct AgentSelfWorktreeRelocation: Equatable {
    enum Phase: Equatable {
        /// Recorded during the origin turn; nothing about execution has changed yet.
        case scheduled
        /// The origin turn completed; the idle transition and continuation are in progress.
        case applying
    }

    let id: UUID
    let writer: AgentSessionRuntimeStore.WriterIdentity
    let originRunID: UUID
    let originRunAttemptID: UUID
    let previousBindings: [AgentSessionWorktreeBinding]
    let desiredBindings: [AgentSessionWorktreeBinding]
    /// Captured when the request is recorded. Only an explicit Stop (or a rebind) withdraws it
    /// (`permitsQueuedDelivery`); the switch's own provider retirement is an internal lifecycle
    /// cancellation and must not withdraw the continuation.
    let stopFence: AgentRunStartStopFence
    var phase: Phase = .scheduled
}

extension AgentModeViewModel {
    /// Monotonic budget for reaching an idle boundary after the origin turn's terminal commit,
    /// including provider idle probes, before the switch is settled as not applied.
    static let selfWorktreeRelocationIdleBudget: Duration = .seconds(30)

    /// Records a self-requested destination change for the caller's own live turn.
    ///
    /// Returns nil when this is not a deferred self relocation (the origin turn is no longer the live
    /// attempt, or the change is presentation-only); the caller then applies the ordinary transition,
    /// which keeps its existing admission rules. `beforeRecord` is the protected mutation fence: it
    /// runs after eligibility is proven and before the pending request becomes visible.
    func scheduleSelfWorktreeRelocation(
        _ desiredBindings: [AgentSessionWorktreeBinding],
        forSessionID sessionID: UUID,
        admission capturedAdmission: AgentSessionWorktreeRuntime.Admission? = nil,
        originRunID: UUID,
        originRunAttemptID: UUID,
        beforeRecord: @MainActor () async throws -> Void = {}
    ) async throws -> AgentSelfWorktreeRelocation? {
        guard let admission = capturedAdmission ?? admitWorktreeTransition(forSessionID: sessionID),
              admission.command.identity.sessionID == sessionID
        else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        try admission.requireCurrent()
        let session = admission.session
        func originTurnIsLive() -> Bool {
            session.runState.isActive
                && session.runID == originRunID
                && session.activeRunAttemptID == originRunAttemptID
                && !session.terminalCommitInProgress
        }
        guard originTurnIsLive() else { return nil }
        try requireNoPendingSelfWorktreeRelocation(in: session, originRunAttemptID: originRunAttemptID)
        let previousBindings = admission.bindings
        guard AgentSessionWorktreeRuntime.changesExecutionRoots(
            from: previousBindings, to: desiredBindings, fallbackWorkspacePath: admission.resources.fallbackWorkspacePath
        ) else { return nil }
        if !desiredBindings.isEmpty {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
        }
        try await beforeRecord()
        guard admission.isCurrent,
              session.activeAgentSessionID == sessionID,
              session.worktreeBindings == previousBindings,
              originTurnIsLive()
        else {
            throw MCPError.invalidParams(
                "The turn that requested this worktree switch ended before the switch could be scheduled. Nothing was changed; inspect the session's current binding before retrying."
            )
        }
        // A concurrent request from the same turn may have recorded first while the fence awaited.
        try requireNoPendingSelfWorktreeRelocation(in: session, originRunAttemptID: originRunAttemptID)
        let relocation = AgentSelfWorktreeRelocation(
            id: UUID(),
            writer: admission.command.identity,
            originRunID: originRunID,
            originRunAttemptID: originRunAttemptID,
            previousBindings: previousBindings,
            desiredBindings: desiredBindings,
            stopFence: AgentRunStartStopFence(session: session)
        )
        session.pendingSelfWorktreeRelocation = relocation
        return relocation
    }

    /// One execution-root relocation per turn. Once a turn has scheduled a switch, every later
    /// self-targeted binding mutation from that same turn (bind, select, unbind, create with bind,
    /// including no-op and presentation-only requests) is refused before it can mutate anything, so
    /// the scheduled switch is never silently replaced or cancelled. Desired bindings are computed
    /// from the current, pre-switch bindings, so composing a second request would discard the
    /// first's roots; further changes belong in the continuation turn, which runs after the switch.
    func requireNoPendingSelfWorktreeRelocation(forSessionID sessionID: UUID, originRunAttemptID: UUID) throws {
        guard let session = try authoritativeLiveSession(for: sessionID) else { return }
        try requireNoPendingSelfWorktreeRelocation(in: session, originRunAttemptID: originRunAttemptID)
    }

    func requireNoPendingSelfWorktreeRelocation(in session: TabSession, originRunAttemptID: UUID) throws {
        guard let pending = session.pendingSelfWorktreeRelocation,
              pending.originRunAttemptID == originRunAttemptID
        else { return }
        let location = Self.selfWorktreeRelocationLocationSummary(pending.desiredBindings)
        throw MCPError.invalidParams(
            "This turn already scheduled a worktree switch (relocation \(pending.id.uuidString)) to \(location). Only one switch is allowed per turn, and it is unchanged. End this turn now; the switch applies when the turn completes and the session continues automatically, where any further worktree changes can be requested."
        )
    }

    /// Legacy ingress adapts to the same scope-owned implementation used by the host.
    func selfWorktreeRelocationTerminalSettled(
        session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        _ = linkExecutionRuntime
        runtimeSessionStore.worktrees.selfWorktreeRelocationTerminalSettled(
            session: session, revision: revision, publication: publication, teardownSettled: teardownSettled
        )
    }

    static func selfWorktreeRelocationLocationSummary(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        AgentSessionWorktreeRuntime.selfWorktreeRelocationLocationSummary(bindings)
    }

    static func selfWorktreeRelocationContinuationMessage(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        AgentSessionWorktreeRuntime.selfWorktreeRelocationContinuationMessage(bindings)
    }
}
