import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRuntimeHost {
    /// Explicit app shutdown fences the host immediately and gives its existing drain owner the
    /// original cancellation producers. The shared shutdown deadline bounds observation, not
    /// producer lifetime. This must never be used for a workspace/presenter switch.
    func beginFinalShutdown() -> AgentSessionHostDrainRuntime {
        beginCancellationRetirement()
    }

    /// An explicitly authorized retirement starts the original cancellation and final-save
    /// producer independently of its waiter. Ordinary presentation close must not call this.
    func beginAuthorizedRetirement() -> AgentSessionHostDrainRuntime {
        let drain = beginCancellationRetirement()
        drain.startIfNeeded()
        return drain
    }

    /// Confirmed deletion must join exact detached owners too. A timeout does not transfer
    /// authority to remove storage while an originating provider or writer is still draining.
    static func drainRetainedHostsForWorkspaceDeletion(
        workspaceID: UUID, until deadline: ContinuousClock.Instant, isAdmitted: @MainActor () -> Bool
    ) async -> Bool {
        func canContinue() -> Bool {
            !Task.isCancelled && ContinuousClock.now < deadline && isAdmitted()
        }
        guard canContinue() else { return false }
        let store = AgentSessionRuntimeStore.shared
        func retainedHosts() -> [AgentSessionRuntimeHost] {
            (store.retainedExecutionHosts + store.retainedDrains.compactMap(\.scope.executableHost)).filter {
                $0.route.identity.kind == .independent && $0.workspaceActivation?.key.owner.workspaceID == workspaceID
            }
        }
        var seen = Set<ObjectIdentifier>()
        let drains = retainedHosts().compactMap { host -> AgentSessionHostDrainRuntime? in
            guard seen.insert(ObjectIdentifier(host)).inserted else { return nil }
            if host.scope.hasReleasedWriterClaims { return host.scope.retainedDrain }
            return host.beginAuthorizedRetirement()
        }
        for drain in drains {
            guard canContinue(), await drain.wait(until: deadline) == .released, canContinue() else { return false }
        }
        return canContinue() && retainedHosts().isEmpty
    }

    /// Invoked only after the process-lifetime deletion fence commits. The caller can time out
    /// waiting; the workspace retains the exact producer until its effects acknowledge release.
    static func beginCommittedDetachedSessionDeletion(_ id: UUID) -> AgentSessionHostDrainRuntime? {
        guard AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id),
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: id),
              let host = writer.scope.executableHost,
              host.route.identity.kind == .independent, let activation = host.workspaceActivation,
              activation.savedCarrierSessionID == nil, !host.scope.presentation.hasPresenter(for: writer.session)
        else { return nil }
        if let retiring = host.scope.retainedDrain {
            retiring.settleAfterDurableDeletion(sessionID: id)
            return retiring
        }
        let drain = AgentSessionHostDrainRuntime.beginDeletion(scope: host.scope, session: writer.session, owner: host, adapters: host.drainAdapters())
        host.scope.persistence.observeRetainedVisibleDrain?(drain)
        host.prepareCancellation(drain: drain, sessions: [writer.session])
        drain.startIfNeeded()
        return drain
    }

    private func beginCancellationRetirement() -> AgentSessionHostDrainRuntime {
        let drain = beginRetirement()
        prepareCancellation(drain: drain, sessions: scope.sessions.values.filter {
            scope.sessionDeletionDrains[ObjectIdentifier($0)] == nil
        })
        return drain
    }

    private func prepareCancellation(drain: AgentSessionHostDrainRuntime, sessions: [AgentTabSession]) {
        let participants = sessions.map { session in
            (
                session: session,
                membership: scope.membership(of: session),
                runID: session.runID,
                attemptID: session.activeRunAttemptID,
                agentTask: session.agentTask,
                context: session.mcpControlContext
            )
        }
        drain.prepareForFinalShutdown(withdrawScheduledStarts: { [self] in
            for participant in participants {
                guard let membership = participant.membership,
                      scope.holds(membership.identity, for: participant.session),
                      participant.session.runID == participant.runID,
                      participant.session.activeRunAttemptID == participant.attemptID else { continue }
                participant.session.stopState.invalidateScheduledStarts()
            }
        }) { [self] in
            await withTaskGroup(of: Void.self) { group in
                for participant in participants {
                    group.addTask { @MainActor [self] in
                        let session = participant.session
                        guard let membership = participant.membership else { return }
                        let current = {
                            self.scope.holds(membership.identity, for: session)
                                && session.runID == participant.runID && session.activeRunAttemptID == participant.attemptID
                        }
                        guard current() else { return }
                        session.cancelEphemeralRuntimeState()
                        let interactions = scope.installedInteractions
                        let oracleDrain = interactions?.closeOracleBackground(for: session)
                        interactions?.cancelPendingQuestion(for: session)
                        interactions?.cancelPendingApproval(for: session)
                        AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
                        if session.runState.isActive {
                            await scope.execution?.cancelRun(
                                tabID: session.tabID, session: session,
                                completion: .terminalTeardownCompleted, origin: .internalLifecycle
                            )
                        }
                        await participant.agentTask?.value
                        await oracleDrain?.value
                        if current() { await interactions?.teardownApprovalSync(for: session, cleanupScope: true) }
                        // Control cleanup consumes the captured registration, not a fresh run
                        // admission: cancellation can clear the original process run ID.
                        if scope.holds(membership.identity, for: session), session.activeRunAttemptID == participant.attemptID,
                           let context = participant.context, let interactions
                        {
                            _ = await scope.mcp.deactivateControlContext(
                                session: session, expectedContext: context,
                                approvalStore: interactions.approvalStore, cleanupRegistration: true
                            )
                        }
                        // Provider/terminal receipts, original effects, required save and explicit
                        // route/root/settings release remain the drain's job after this producer.
                    }
                }
            }
        }
    }

    /// Executable composition for an explicitly authorized retirement. Stop and presentation
    /// detachment do not call this. The retained drain alone releases route/root/settings leases.
    func beginRetirement() -> AgentSessionHostDrainRuntime {
        beginRetirement(adapters: drainAdapters())
    }

    private func drainAdapters() -> AgentSessionHostDrainRuntime.Adapters {
        let links = scope.linkExecution
        let execution = scope.execution
        let coordinator = codexCoordinator
        let claudeCoordinator = claudeCoordinator
        let tools = route.toolExecutionRuntime
        return .init(
            managedInput: links.map { .managedInput($0) },
            selfCompact: links.map { .selfCompact($0) },
            captureProvider: { session in
                guard let execution, let terminal = execution.captureTerminalTeardown(for: session) else {
                    throw AgentHostWorkspaceResources.Failure.authorityUnavailable
                }
                // Snapshot actual producer handles before the first effect join. Neither a
                // disappeared controller nor a failed transport read proves these have finished.
                let agentTask = session.agentTask
                let provider = session.provider
                let claude = session.claudeController
                let acp = session.acpController
                let codex = session.codexController
                let runID = session.runID
                let tabID = session.tabID
                let sessionID = session.activeAgentSessionID
                let computerUse = session.codexControllerFeatureState?.computerUseEnabled == true
                let existingCodexRetirement = codex.flatMap { coordinator.codexControllerRetirementReceipt(for: $0) }
                var completed = false
                return .init(finish: {
                    // Scheduling uses the captured controller, never today's tab/controller.
                    // Capture the returned original task before any suspension; repeated claims
                    // join that controller's existing retirement, not a successor's task.
                    let codexRetirement = existingCodexRetirement ?? codex.map {
                        coordinator.retireCodexController($0, tabID: tabID, source: "host.retirement", includesComputerUse: computerUse)
                    }
                    await terminal.waitForCompletion()
                    await agentTask?.value
                    await provider?.dispose()
                    if let claude { await claudeCoordinator.finishControllerForHostDrain(claude, session: session) }
                    await acp?.shutdown()
                    await codexRetirement?.waitForCompletion()
                    if let runID { try await tools.awaitNoActiveToolExecutions(runID: runID) }
                    completed = true
                }, probe: { current in
                    // These are positive shutdown completions for the original objects. Do not
                    // read a closed transport, detach pointers, or relax the drain's identity fence.
                    guard completed, current() else { return false }
                    if let sessionID {
                        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
                        guard current(), !registered else { return false }
                    }
                    return current()
                })
            }
        )
    }
}
