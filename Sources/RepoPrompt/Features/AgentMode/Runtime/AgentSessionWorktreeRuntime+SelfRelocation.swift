import Foundation
import MCP

/// The originating writer owns relocation through terminal drain, binding publication and launch.
extension AgentSessionWorktreeRuntime {
    static let selfWorktreeRelocationIdleBudget: Duration = .seconds(30)

    private func terminalCommand(for identity: AgentSessionRuntimeStore.WriterIdentity) throws -> AgentSessionRuntimeStore.Command {
        guard let scope,
              case let .unique(writer) = scope.resolveWriter(sessionID: identity.sessionID),
              writer.scope === scope, writer.identity == identity
        else { throw TransitionError.stale }
        return try writer.admitCommand().get()
    }

    /// Terminal boundary of the origin turn. Called after publication and successor arbitration;
    /// never contacts a provider inline.
    func selfWorktreeRelocationTerminalSettled(
        session: AgentTabSession,
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        guard var pending = session.pendingSelfWorktreeRelocation,
              pending.phase == .scheduled,
              pending.originRunAttemptID == revision.ownership.attemptID
        else { return }
        guard let command = try? terminalCommand(for: pending.writer),
              command.identity == pending.writer, command.writer.session === session
        else {
            return settleSelfWorktreeRelocation(pending, session: session, row: nil)
        }
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
        beginPendingOperation()
        Task { @MainActor [self, session] in
            defer {
                endPendingOperation()
                session.noteMonitorObservationInputsChanged()
            }
            await applySelfWorktreeRelocation(pending, session: session, teardownSettled: teardownSettled)
        }
    }

    private func applySelfWorktreeRelocation(
        _ pending: AgentSelfWorktreeRelocation,
        session: AgentTabSession,
        teardownSettled: @escaping @MainActor () -> Bool
    ) async {
        let stopFence = pending.stopFence
        guard let command = try? terminalCommand(for: pending.writer),
              command.identity == pending.writer, command.writer.session === session
        else {
            return settleSelfWorktreeRelocation(pending, session: session, row: nil)
        }
        guard let launcher = terminalContinuationLauncher,
              scope?.linkExecution?.activeMCPToolProbe != nil
        else {
            return settleSelfWorktreeRelocation(
                pending, session: session,
                row: "The requested worktree switch was not applied because the runtime continuation or tool-drain capability was unavailable. The session remains in its previous location."
            )
        }
        guard let admission = try? admit(command) else {
            return settleSelfWorktreeRelocation(
                pending, session: session,
                row: "The requested worktree switch was not applied because the session's execution workspace was unavailable."
            )
        }
        func isCurrent() -> Bool {
            command.isCurrent
                && session.activeAgentSessionID == pending.writer.sessionID
                && session.pendingSelfWorktreeRelocation?.id == pending.id
        }
        var lastRefusal: String?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.selfWorktreeRelocationIdleBudget)
        while true {
            guard isCurrent() else { return settleSelfWorktreeRelocation(pending, session: session, row: nil) }
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
            guard session.worktreeBindings == pending.previousBindings, admission.bindings == pending.previousBindings else {
                return settleSelfWorktreeRelocation(
                    pending, session: session,
                    row: "The requested worktree switch was not applied because the session's binding changed in the meantime."
                )
            }
            guard admission.resources.isCurrent() else {
                return settleSelfWorktreeRelocation(
                    pending, session: session,
                    row: "The requested worktree switch was not applied because the session's execution workspace changed."
                )
            }
            let drained = teardownSettled()
                && scope?.linkExecution?.activeMCPToolProbe?(pending.originRunID) == false
                && (try? Self.requireIdle(session)) != nil
            if drained {
                // Reserves the next turn for the continuation from the instant the binding is
                // published: the idle gate, deferred session_admin binds, and auto-wake all refuse
                // while this managed follow-up mask is set, so nothing can overtake the gap between
                // the transition releasing its gate and the continuation's run start.
                var reservedContinuation = false
                do {
                    _ = try await transition(
                        pending.desiredBindings, admission: admission, intent: .externalManagement,
                        beforeCommit: { [weak session] in
                            guard let session,
                                  admission.isCurrent,
                                  session.pendingSelfWorktreeRelocation?.id == pending.id,
                                  stopFence.permitsQueuedDelivery(to: session)
                            else { throw CancellationError() }
                        },
                        afterCommit: { [weak session] in
                            guard let session, !session.mcpFollowUpRunPending else { return }
                            session.mcpFollowUpRunPending = true
                            session.selfWorktreeRelocationFollowUpOwner = pending.id
                            reservedContinuation = true
                        }
                    )
                    return await continueAfterSelfWorktreeRelocation(
                        pending, session: session, command: command, reservedContinuation: reservedContinuation, launcher: launcher
                    )
                } catch let error as MCPError where session.worktreeBindings == pending.previousBindings {
                    // Pre-mutation refusal (provider still settling, or its idle probe failed).
                    // Retried only within the monotonic budget below.
                    lastRefusal = error.localizedDescription
                } catch is CancellationError where session.worktreeBindings == pending.previousBindings {
                    // The commit fence saw Stop or an already-settled request; the guards above settle it.
                    lastRefusal = nil
                } catch {
                    releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
                    guard isCurrent() else { return settleSelfWorktreeRelocation(pending, session: session, row: nil) }
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
        session: AgentTabSession,
        command: AgentSessionRuntimeStore.Command,
        reservedContinuation: Bool,
        launcher: @MainActor (AgentSessionRuntimeStore.Command, String, AgentDirectRunStartOptions, AgentRunStartOutcomeRecorder) async -> Void
    ) async {
        guard command.writer.isCurrent else {
            releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
            return settleSelfWorktreeRelocation(pending, session: session, row: nil)
        }
        guard session.pendingSelfWorktreeRelocation?.id == pending.id else {
            return releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
        }
        session.pendingSelfWorktreeRelocation = nil
        let location = Self.selfWorktreeRelocationLocationSummary(pending.desiredBindings)
        let blocker: String? = if scope?.sessions[session.tabID] !== session {
            "the session was closed"
        } else if !pending.stopFence.permitsQueuedDelivery(to: session) {
            "it was cancelled by Stop"
        } else if !command.isCurrent {
            "the runtime no longer admits a continuation"
        } else if session.runState.isActive {
            "another turn started first"
        } else if session.worktreeBindings != pending.desiredBindings {
            "the binding changed again"
        } else {
            nil
        }
        if let blocker {
            releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
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
        await launcher(
            command, message,
            AgentDirectRunStartOptions(stopFence: AgentRunStartStopFence(session: session)), outcome
        )
        guard command.writer.isCurrent else {
            releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
            return settleSelfWorktreeRelocation(pending, session: session, row: nil)
        }
        if !session.runState.isActive {
            releaseSelfWorktreeRelocationReservation(session, owner: pending.id, reserved: reservedContinuation)
        }
        if case let .startFailed(message) = outcome.outcome {
            appendSelfWorktreeRelocationRow(
                "The automatic continuation did not start" + (message.map { ": \($0)" } ?? ".")
                    + " The switch is applied and the conversation handoff is retained; send a message to continue in the new location.",
                session: session
            )
        }
    }

    private func releaseSelfWorktreeRelocationReservation(_ session: AgentTabSession, owner: UUID, reserved: Bool) {
        guard reserved, session.selfWorktreeRelocationFollowUpOwner == owner,
              session.mcpFollowUpRunPending, session.scheduledACPFollowUp == nil else { return }
        session.mcpFollowUpRunPending = false
        scope?.mcp.handleObservedMCPStateChange(for: session)
    }

    private func appendSelfWorktreeRelocationRow(_ text: String, session: AgentTabSession) {
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex))
        session.isDirty = true
        scope?.presentation.bindingChanged(session)
        scope?.persistence.scheduleSave(for: session)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
    }

    private func settleSelfWorktreeRelocation(
        _ pending: AgentSelfWorktreeRelocation,
        session: AgentTabSession,
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
            if let branch = binding.branch {
                text += " (branch `\(branch)`)"
            }
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
                if let branch = binding.branch {
                    line += " on branch `\(branch)`"
                }
                line += " (worktree `\(binding.worktreeID)`)."
                lines.append(line)
            }
        }
        lines.append("RepoPrompt tools and your shell/file access now operate there. Paths from before the switch that point at the previous checkout are stale. Continue the task you were working on.")
        return lines.joined(separator: "\n")
    }
}
