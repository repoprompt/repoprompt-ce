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
        originRunID: UUID,
        originRunAttemptID: UUID,
        beforeRecord: @MainActor () async throws -> Void = {}
    ) async throws -> AgentSelfWorktreeRelocation? {
        guard let session = try authoritativeLiveSession(for: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        func originTurnIsLive() -> Bool {
            session.runState.isActive
                && session.runID == originRunID
                && session.activeRunAttemptID == originRunAttemptID
                && !session.terminalCommitInProgress
        }
        guard originTurnIsLive() else { return nil }
        try requireNoPendingSelfWorktreeRelocation(in: session, originRunAttemptID: originRunAttemptID)
        let previousBindings = session.worktreeBindings
        guard worktreeBindingsChangeExecutionRoots(from: previousBindings, to: desiredBindings) else { return nil }
        if !desiredBindings.isEmpty {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
        }
        try await beforeRecord()
        guard sessions[session.tabID] === session,
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

    private func requireNoPendingSelfWorktreeRelocation(in session: TabSession, originRunAttemptID: UUID) throws {
        guard let pending = session.pendingSelfWorktreeRelocation,
              pending.originRunAttemptID == originRunAttemptID
        else { return }
        let location = Self.selfWorktreeRelocationLocationSummary(pending.desiredBindings)
        throw MCPError.invalidParams(
            "This turn already scheduled a worktree switch (relocation \(pending.id.uuidString)) to \(location). Only one switch is allowed per turn, and it is unchanged. End this turn now; the switch applies when the turn completes and the session continues automatically, where any further worktree changes can be requested."
        )
    }

    /// Terminal boundary of the origin turn. Called after publication and successor arbitration;
    /// never contacts a provider inline.
    func selfWorktreeRelocationTerminalSettled(
        session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        guard var pending = session.pendingSelfWorktreeRelocation,
              pending.phase == .scheduled,
              pending.originRunAttemptID == revision.ownership.attemptID
        else { return }
        let refusal: String? = if revision.successorKind != nil || revision.providerSuccessorID != nil {
            "queued input started another turn first"
        } else {
            switch (revision.terminalState, publication) {
            case (.completed, .accepted(successorEpoch: nil)): nil
            case (.completed, .accepted): "queued input started another turn first"
            case (.completed, _): "the turn's completion could not be published"
            case (.cancelled, _): "the turn was stopped"
            case (.failed, _): "the turn failed"
            default: "the turn did not complete"
            }
        }
        if let refusal {
            settleSelfWorktreeRelocation(
                pending, session: session,
                row: "The requested worktree switch was not applied because \(refusal). The session remains in its previous location."
            )
            return
        }
        // The terminal barrier awaits publication before this hook; a Stop in that window is caught
        // by the fence captured when the request was recorded.
        guard pending.stopFence.permitsQueuedDelivery(to: session) else {
            settleSelfWorktreeRelocation(
                pending, session: session,
                row: "The requested worktree switch was cancelled by Stop. The session remains in its previous location."
            )
            return
        }
        pending.phase = .applying
        session.pendingSelfWorktreeRelocation = pending
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await applySelfWorktreeRelocation(pending, session: session, teardownSettled: teardownSettled)
        }
    }

    private func applySelfWorktreeRelocation(
        _ pending: AgentSelfWorktreeRelocation,
        session: TabSession,
        teardownSettled: @escaping @MainActor () -> Bool
    ) async {
        let stopFence = pending.stopFence
        guard let sessionID = session.activeAgentSessionID else {
            return settleSelfWorktreeRelocation(pending, session: session, row: nil)
        }
        func isCurrent() -> Bool {
            sessions[session.tabID] === session
                && session.activeAgentSessionID == sessionID
                && session.pendingSelfWorktreeRelocation?.id == pending.id
        }
        var lastRefusal: String?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.selfWorktreeRelocationIdleBudget)
        while true {
            guard isCurrent() else { return }
            guard stopFence.permitsQueuedDelivery(to: session) else {
                return settleSelfWorktreeRelocation(
                    pending, session: session,
                    row: "The requested worktree switch was cancelled by Stop. The session remains in its previous location."
                )
            }
            if session.runState.isActive {
                return settleSelfWorktreeRelocation(
                    pending, session: session,
                    row: "The requested worktree switch was not applied because another turn started first. The session remains in its previous location."
                )
            }
            guard session.worktreeBindings == pending.previousBindings else {
                return settleSelfWorktreeRelocation(
                    pending, session: session,
                    row: "The requested worktree switch was not applied because the session's binding changed in the meantime."
                )
            }
            let drained = teardownSettled()
                && !agentSelfCompactHasActiveMCPTools(runID: pending.originRunID)
                && (try? requireIdleWorktreeBindingTransition(session)) != nil
            if drained {
                // Reserves the next turn for the continuation from the instant the binding is
                // published: the idle gate, deferred session_admin binds, and auto-wake all refuse
                // while this managed follow-up mask is set, so nothing can overtake the gap between
                // the transition releasing its gate and the continuation's run start.
                var reservedContinuation = false
                do {
                    _ = try await transitionWorktreeBindings(
                        pending.desiredBindings,
                        forSessionID: sessionID,
                        intent: .externalManagement,
                        beforeCommit: { [weak self, weak session] in
                            guard let self, let session,
                                  sessions[session.tabID] === session,
                                  session.pendingSelfWorktreeRelocation?.id == pending.id,
                                  stopFence.permitsQueuedDelivery(to: session)
                            else { throw CancellationError() }
                        },
                        afterCommit: { [weak session] in
                            guard let session, !session.mcpFollowUpRunPending else { return }
                            session.mcpFollowUpRunPending = true
                            reservedContinuation = true
                        }
                    )
                    return await continueAfterSelfWorktreeRelocation(
                        pending, session: session, reservedContinuation: reservedContinuation
                    )
                } catch let error as MCPError where session.worktreeBindings == pending.previousBindings {
                    // Pre-mutation refusal (provider still settling, or its idle probe failed).
                    // Retried only within the monotonic budget below.
                    lastRefusal = error.localizedDescription
                } catch is CancellationError where session.worktreeBindings == pending.previousBindings {
                    // The commit fence saw Stop or an already-settled request; the guards above settle it.
                    lastRefusal = nil
                } catch {
                    releaseSelfWorktreeRelocationReservation(session, reserved: reservedContinuation)
                    guard isCurrent() else { return }
                    return settleSelfWorktreeRelocation(
                        pending, session: session,
                        row: "The requested worktree switch did not complete: \(error.localizedDescription)"
                    )
                }
            }
            guard clock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent() else { return }
        settleSelfWorktreeRelocation(
            pending, session: session,
            row: "The requested worktree switch was not applied because the session never reached an idle boundary. The session remains in its previous location."
                + (lastRefusal.map { " Last refusal: \($0)" } ?? "")
        )
    }

    private func continueAfterSelfWorktreeRelocation(
        _ pending: AgentSelfWorktreeRelocation,
        session: TabSession,
        reservedContinuation: Bool
    ) async {
        guard session.pendingSelfWorktreeRelocation?.id == pending.id else {
            return releaseSelfWorktreeRelocationReservation(session, reserved: reservedContinuation)
        }
        session.pendingSelfWorktreeRelocation = nil
        let location = Self.selfWorktreeRelocationLocationSummary(pending.desiredBindings)
        let blocker: String? = if sessions[session.tabID] !== session {
            "the session was closed"
        } else if !pending.stopFence.permitsQueuedDelivery(to: session) {
            "it was cancelled by Stop"
        } else if session.runState.isActive {
            "another turn started first"
        } else if session.worktreeBindings != pending.desiredBindings {
            "the binding changed again"
        } else {
            nil
        }
        if let blocker {
            releaseSelfWorktreeRelocationReservation(session, reserved: reservedContinuation)
            appendSelfWorktreeRelocationRow(
                "Execution worktree switched to \(location). The automatic continuation did not start because \(blocker); send a message to continue in the new location.",
                session: session
            )
            return
        }
        appendSelfWorktreeRelocationRow(
            "Execution worktree switched to \(location). Continuing automatically in the new location.",
            session: session
        )
        let message = Self.selfWorktreeRelocationContinuationMessage(pending.desiredBindings)
        let outcome = AgentRunStartOutcomeRecorder()
        #if DEBUG
            if let starter = test_selfWorktreeRelocationContinuationStarter {
                await starter(session, message)
                outcome.recordAccepted()
            } else {
                await startSelfWorktreeRelocationContinuation(session, message: message, outcome: outcome)
            }
        #else
            await startSelfWorktreeRelocationContinuation(session, message: message, outcome: outcome)
        #endif
        if !session.runState.isActive {
            releaseSelfWorktreeRelocationReservation(session, reserved: reservedContinuation)
        }
        if case let .startFailed(message) = outcome.outcome {
            appendSelfWorktreeRelocationRow(
                "The automatic continuation did not start" + (message.map { ": \($0)" } ?? ".")
                    + " The switch is applied and the conversation handoff is retained; send a message to continue in the new location.",
                session: session
            )
        }
    }

    /// Default options deliberately consume the handoff the transition staged: the continuation is
    /// the first turn of the fresh provider runtime in the new cwd.
    private func startSelfWorktreeRelocationContinuation(
        _ session: TabSession,
        message: String,
        outcome: AgentRunStartOutcomeRecorder
    ) async {
        await startAgentRun(
            tabID: session.tabID,
            initialMessage: message,
            directStartOptions: AgentDirectRunStartOptions(stopFence: AgentRunStartStopFence(session: session)),
            startOutcome: outcome
        )
    }

    private func releaseSelfWorktreeRelocationReservation(_ session: TabSession, reserved: Bool) {
        guard reserved, session.mcpFollowUpRunPending, session.scheduledACPFollowUp == nil else { return }
        session.mcpFollowUpRunPending = false
        handleObservedMCPStateChange(for: session)
    }

    private func appendSelfWorktreeRelocationRow(_ text: String, session: TabSession) {
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex))
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: session)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func settleSelfWorktreeRelocation(
        _ pending: AgentSelfWorktreeRelocation,
        session: TabSession,
        row: String?
    ) {
        guard session.pendingSelfWorktreeRelocation?.id == pending.id else { return }
        session.pendingSelfWorktreeRelocation = nil
        guard let row else { return }
        appendSelfWorktreeRelocationRow(row, session: session)
    }

    static func selfWorktreeRelocationLocationSummary(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        guard !bindings.isEmpty else { return "the logical workspace checkout" }
        return bindings.map { binding in
            var text = "`\(binding.worktreeRootPath)`"
            if let branch = binding.branch { text += " (branch `\(branch)`)" }
            return text
        }.joined(separator: ", ")
    }

    /// Fixed, app-authored continuation input. It names the authoritative new execution roots so the
    /// model does not keep using paths it learned in the previous checkout.
    static func selfWorktreeRelocationContinuationMessage(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        var lines = [
            "[RepoPrompt automatic continuation] The execution worktree switch you requested has been applied, and this session now runs in its new location."
        ]
        if bindings.isEmpty {
            lines.append("- No worktree binding remains: tools and the shell use the logical workspace checkout.")
        } else {
            for binding in bindings {
                var line = "- Logical root `\(binding.logicalRootName ?? binding.logicalRootPath)` now resolves to `\(binding.worktreeRootPath)`"
                if let branch = binding.branch { line += " on branch `\(branch)`" }
                line += " (worktree `\(binding.worktreeID)`)."
                lines.append(line)
            }
        }
        lines.append("RepoPrompt tools and your shell/file access now operate there. Paths from before the switch that point at the previous checkout are stale. Continue the task you were working on.")
        return lines.joined(separator: "\n")
    }
}
