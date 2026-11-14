import Foundation
import RepoPromptAIContracts

extension AgentSessionRuntimeHost {
    func installWorktreeEffects(
        execution: AgentModeRunService,
        links: AgentSessionLinkExecutionRuntime,
        interactions: AgentSessionInteractionRuntime,
        environment: @escaping @MainActor (AgentTabSession) -> AgentSessionLinkExecutionRuntime.ManagedInputEnvironment,
        sessionTitle: @escaping @MainActor (AgentTabSession) -> String
    ) {
        let codex = codexCoordinator
        let claude = claudeCoordinator
        scope.worktrees.effects = .init(
            drainOracle: { [weak interactions] session in
                guard let interactions else { preconditionFailure("Worktree effects require the installed interaction runtime") }
                return await interactions.awaitOracleBackgroundDrain(for: session)
            },
            cancelRun: { [weak execution] session in
                // An admitted transition retains its scope and installed execution. This backedge
                // is weak only to avoid execution hooks -> worktrees -> execution retention.
                guard let execution else { preconditionFailure("Worktree effects require the installed run execution") }
                AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
                await execution.cancelRun(tabID: session.tabID, session: session, intent: .executionLocationChange, completion: .terminalPublished)
            },
            stageRecovery: { [weak links] command in
                guard let links else { preconditionFailure("Worktree effects require the installed link runtime") }
                let session = command.writer.session
                return await links.prepareResumeRecoveryHandoff(
                    for: session, sourceTitle: sessionTitle(session), environment: environment(session), command: command
                )
            },
            retireProvider: { [weak codex, weak claude] session in
                // Admission retains the scope/execution; retain its exact coordinators for this
                // effect without making terminal hook -> worktree effect backedges own them.
                guard let codex, let claude else { preconditionFailure("Worktree effects require the installed provider coordinators") }
                await Self.invalidateProviderContextForExecutionLocationChange(session, codexCoordinator: codex, claudeCoordinator: claude)
            }
        )
    }

    private static func invalidateProviderContextForExecutionLocationChange(
        _ session: AgentTabSession,
        codexCoordinator: CodexAgentModeCoordinator,
        claudeCoordinator: ClaudeAgentModeCoordinator
    ) async {
        // The worktree runtime admitted its original command immediately before this call.
        // Detach and clear synchronously; awaited cleanup never touches a same-tab successor.
        let provider = session.provider
        session.provider = nil
        let acp = session.acpController
        session.acpController = nil
        let codex: CodexAgentModeCoordinator.DetachedCodexController?
        if session.codexController != nil || session.codexConversationID != nil || session.codexRolloutPath != nil || session.selectedAgent == .codexExec {
            codex = codexCoordinator.detachForWorkspaceSwitchFinalizeSync(session, runIDs: session.runID.map { [$0] } ?? [])
            codexCoordinator.clearCodexSessionState(session)
        } else {
            codex = nil
        }
        let claude = claudeCoordinator.detachForWorkspaceSwitchFinalizeSync(session)
        session.providerSessionID = nil
        session.providerCleanupHandle = nil
        session.contextUsageSnapshot = nil
        session.activeNonCodexTurnTokenAccumulator = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        session.isDirty = true
        await provider?.dispose()
        await acp?.cancelPrompt()
        await acp?.shutdown()
        if let codex { await codexCoordinator.retireDetachedControllerForWorkspaceSwitch(codex) }
        if let claude { await claudeCoordinator.retireDetachedControllerForWorkspaceSwitch(claude, discardedSession: session) }
    }
}
