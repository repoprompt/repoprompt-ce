import Foundation

extension AgentSessionRuntimeHost: CodexManagedSessionShutdownParticipant {
    /// The app's existing managed-auth coordinator fences credential publication before calling
    /// this participant. Presentation attachment is irrelevant; cleanup retains original objects.
    func stopCodexSessionsForManagedLogout() async {
        codexCoordinator.stopRuntimeTasksForManagedLogout()
        let tasks = scope.sessions.values.compactMap { session -> Task<Void, Never>? in
            guard session.selectedAgent == .codexExec || session.codexController != nil
                || session.codexConversationID?.isEmpty == false || session.codexRolloutPath?.isEmpty == false,
                let membership = scope.membership(of: session) else { return nil }
            let runID = session.runID
            let attemptID = session.activeRunAttemptID
            let selectedAgent = session.selectedAgent
            let controller = session.codexController
            let computerUse = session.codexControllerFeatureState?.computerUseEnabled == true
            let provider = selectedAgent == .codexExec ? session.provider : nil
            let agentTask = selectedAgent == .codexExec ? session.agentTask : nil
            let context = selectedAgent == .codexExec ? session.mcpControlContext : nil
            return Task { @MainActor [self, session] in
                let current = {
                    self.scope.holds(membership.identity, for: session) && session.runID == runID
                        && session.activeRunAttemptID == attemptID && session.selectedAgent == selectedAgent
                }
                if current(), selectedAgent == .codexExec {
                    session.stopState.invalidateScheduledStarts()
                    session.cancelEphemeralRuntimeState()
                    scope.installedInteractions?.cancelPendingQuestion(for: session)
                    scope.installedInteractions?.cancelPendingApproval(for: session)
                    AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
                    if session.runState.isActive {
                        await scope.execution?.cancelRun(
                            tabID: session.tabID, session: session,
                            completion: .terminalTeardownCompleted, origin: .internalLifecycle
                        )
                    }
                    if current() {
                        await scope.installedInteractions?.teardownApprovalSync(for: session, cleanupScope: true)
                    }
                    // Terminal cancellation may legitimately clear its process run ID. Exact
                    // control-receipt cleanup is not fresh run admission, but must not follow a
                    // new membership/attempt/provider or a replaced control registration.
                    if scope.holds(membership.identity, for: session), session.activeRunAttemptID == attemptID,
                       session.selectedAgent == selectedAgent, let context, let interactions = scope.installedInteractions
                    {
                        _ = await scope.mcp.deactivateControlContext(
                            session: session, expectedContext: context,
                            approvalStore: interactions.approvalStore, cleanupRegistration: true
                        )
                    }
                }
                // A successor must not be detached or have its tab-scoped observers cleared.
                // If cancellation already detached the original controller, join its exact
                // retirement below instead of resolving the tab's current retirement task.
                var detachedOriginalController = false
                if current(), session.codexController === controller {
                    let detached = codexCoordinator.detachForWorkspaceSwitchFinalizeSync(
                        session, runIDs: runID.map { [$0] } ?? [],
                        preserveNonCodexRunState: selectedAgent != .codexExec
                    )
                    if let detached {
                        await codexCoordinator.retireDetachedControllerForWorkspaceSwitch(detached)
                        detachedOriginalController = controller != nil
                    }
                }
                await agentTask?.value
                await provider?.dispose()
                if let controller, !detachedOriginalController {
                    let retirement = codexCoordinator.codexControllerRetirementReceipt(for: controller)
                        ?? codexCoordinator.retireCodexController(
                            controller, tabID: session.tabID, source: "host.managed-logout", includesComputerUse: computerUse
                        )
                    await retirement.waitForCompletion()
                }
                if current() { scope.persistence.scheduleSave(for: session.tabID) }
            }
        }
        for task in tasks {
            await task.value
        }
    }
}
