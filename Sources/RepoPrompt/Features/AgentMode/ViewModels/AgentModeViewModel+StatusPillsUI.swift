import Foundation

extension AgentModeViewModel {
    func makeStatusPillsSnapshot() -> AgentStatusPillsSnapshot {
        AgentStatusPillsSnapshot(
            currentTabID: currentTabID,
            selectedWorkflow: selectedWorkflow,
            stagedSlashCommand: stagedSlashCommandProps(tabID: currentTabID),
            selectedAgent: selectedAgent,
            autoEditPermissionGuidance: autoEditPermissionGuidance,
            runState: runState,
            autoEditEnabled: autoEditEnabled,
            interviewFirst: interviewFirst,
            executionLocation: executionLocationProps(tabID: currentTabID),
            activeAgentSessionID: activeSession?.activeAgentSessionID,
            activeRunID: activeSession?.runID
        )
    }

    func syncStatusPillsUIState() {
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    /// Persistent projection for the primary execution root. The initial intent
    /// remains deferred until first send; committed bindings remain visible afterward.
    func executionLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let tabID,
              workspaceManager?.activeWorkspace?.isSystemWorkspace != true
        else {
            return nil
        }

        if isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID]) {
            let session = sessions[tabID]
            let busy = session?.isPreparingInitialWorktree == true
            return AgentExecutionLocationProps(
                tabID: tabID,
                selection: session?.pendingInitialStartLocation ?? .local,
                indicator: nil,
                isInitialSelection: true,
                isEnabled: !busy,
                isOperationInProgress: busy,
                requiresActiveRunConfirmation: false,
                disabledReason: busy ? "Preparing the selected worktree…" : nil
            )
        }

        guard let session = sessions[tabID],
              hasLinkedAgentSession(for: tabID) || session.hasSentFirstMessage || !session.worktreeBindings.isEmpty
        else {
            return nil
        }
        let indicator = primaryExecutionWorktreeIndicator(forTabID: tabID)
        let selection: InitialStartLocation = indicator.map { indicator in
            .existingWorktree(
                AgentExecutionWorktreeSelection(
                    repositoryID: indicator.repositoryID,
                    repoKey: "",
                    worktreeID: indicator.worktreeID,
                    path: indicator.worktreeRootPath,
                    name: indicator.worktreeName,
                    branch: indicator.branch,
                    label: indicator.label,
                    colorHex: indicator.colorHex,
                    isPrunable: !indicator.isAvailable
                )
            )
        } ?? .local
        let busy = session.isChangingExecutionLocation
        let disabledReason = executionLocationMutationDisabledReason(for: session)
        return AgentExecutionLocationProps(
            tabID: tabID,
            selection: selection,
            indicator: indicator,
            isInitialSelection: false,
            isEnabled: disabledReason == nil && !busy,
            isOperationInProgress: busy,
            requiresActiveRunConfirmation: session.runState.isActive,
            disabledReason: busy ? "Changing execution location…" : disabledReason
        )
    }

    /// Initial-only compatibility shim used by the guarded first-send contract.
    func initialStartLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let props = executionLocationProps(tabID: tabID), props.isInitialSelection else { return nil }
        return props
    }

    func isEligibleForInitialStartLocation(tabID: UUID, session: TabSession?) -> Bool {
        guard workspaceManager?.activeWorkspace?.isSystemWorkspace != true else {
            return false
        }
        guard let session else { return !hasLinkedAgentSession(for: tabID) }
        guard !hasLinkedAgentSession(for: tabID) || session.hasLoadedPersistedState else { return false }
        return session.mcpControlContext == nil
            && !session.isMCPOriginated
            && session.parentSessionID == nil
            && !session.pendingHandoff.hasPayload
            && !session.hasSentFirstMessage
            && session.runState == .idle
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.providerSessionID == nil
            && session.codexConversationID == nil
            && session.worktreeBindings.isEmpty
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
    }

    private func executionLocationMutationDisabledReason(for session: TabSession) -> String? {
        if !session.hasLoadedPersistedState {
            return "Load this thread before changing its execution location."
        }
        if session.mcpControlContext != nil || session.isMCPOriginated || session.parentSessionID != nil {
            return "Execution location is managed by the parent or MCP run."
        }
        if session.pendingHandoff.defersProviderLockUntilSend {
            return "Send or clear the pending handoff before changing location."
        }
        return nil
    }

    func selectInitialStartLocation(_ selection: InitialStartLocation, for tabID: UUID) {
        guard tabID == currentTabID,
              isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID])
        else {
            return
        }
        let session = session(for: tabID)
        guard !session.isPreparingInitialWorktree,
              session.pendingInitialStartLocation != selection
        else {
            return
        }
        session.pendingInitialStartLocation = selection
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    func setInterviewFirst(_ enabled: Bool) {
        guard interviewFirst != enabled else { return }
        interviewFirst = enabled
        syncStatusPillsUIState()
    }

    func toggleInterviewFirst() {
        setInterviewFirst(!interviewFirst)
    }
}
