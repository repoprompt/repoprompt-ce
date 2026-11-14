import Foundation

extension AgentModeViewModel {
    func makeStatusPillsSnapshot(subject: AgentComposerSubject = .currentTab) -> AgentStatusPillsSnapshot {
        let currentTabID: UUID? = if case let .tab(id) = subject { id } else { self.currentTabID }
        let session = currentTabID.flatMap { sessions[$0] }
        let current = subject.isCurrent
        #if DEBUG
            test_statusPillsSnapshotBuildCount += 1
        #endif
        return AgentStatusPillsSnapshot(
            currentTabID: currentTabID,
            selectedWorkflow: current ? selectedWorkflow : (session?.selectedWorkflow),
            stagedSlashCommand: stagedSlashCommandProps(tabID: currentTabID),
            selectedAgent: current ? selectedAgent : (session?.selectedAgent ?? .claudeCode),
            autoEditPermissionGuidance: current ? autoEditPermissionGuidance : nil,
            runState: current ? runState : (session?.runState ?? .idle),
            autoEditEnabled: current ? autoEditEnabled : (session?.autoEditEnabled ?? false),
            interviewFirst: current ? interviewFirst : false,
            modelRouter: modelRouterPillProps(tabID: currentTabID),
            autoEffort: autoEffortPillProps(tabID: currentTabID),
            executionLocation: executionLocationProps(tabID: currentTabID),
            activeAgentSessionID: session?.activeAgentSessionID,
            activeRunID: session?.runID,
            monitor: currentMonitorPillProps(tabID: currentTabID),
            reprompt: current ? repromptPillProps() : .init(unavailableReason: "Open this session in its workspace to configure reprompt.")
        )
    }

    /// Preserve notify-time monitor freshness without rebuilding for unrelated endpoint updates.
    /// The link-projection publisher calls this on every mutation, and most mutations leave the
    /// pills untouched.
    func syncStatusPillsUIStateIfMonitorStale() {
        let published = ui.statusPills.snapshot
        if published.currentTabID != currentTabID || published.monitor != currentMonitorPillProps() {
            ui.statusPills.update(makeStatusPillsSnapshot())
        }
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
                disabledReason: session?.pendingHandoff.executionLocationFailure ?? (busy ? "Preparing the selected worktree…" : nil)
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
                    head: nil,
                    isDetached: indicator.branch == nil,
                    label: indicator.label,
                    colorHex: indicator.colorHex,
                    isLocked: false,
                    lockReason: nil,
                    isPrunable: !indicator.isAvailable,
                    prunableReason: indicator.isAvailable ? nil : indicator.tooltipText
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
            && session.hasEmptyIdleExecutionLocation
    }

    private func executionLocationMutationDisabledReason(for session: TabSession) -> String? {
        if let failure = session.pendingHandoff.executionLocationFailure {
            return failure
        }
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
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    func setInterviewFirst(_ enabled: Bool) {
        guard interviewFirst != enabled else { return }
        interviewFirst = enabled
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    func toggleInterviewFirst() {
        setInterviewFirst(!interviewFirst)
    }
}
