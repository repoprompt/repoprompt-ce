import Foundation

@MainActor
extension AgentModeViewModel {
    func toggleAutoEdit() {
        setAutoEditEnabled(!autoEditEnabled)
    }

    func setAutoEditEnabled(_ enabled: Bool) {
        guard let tabID = currentTabID else {
            ApplyEditsApprovalStore.setGlobalDefaultAutoEditEnabled(enabled)
            autoEditEnabled = enabled
            refreshAutoEditPermissionGuidanceForActiveSession()
            syncAllActiveUIState()
            return
        }
        _ = session(for: tabID)
        let scope = applyEditsScope(for: tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.setAutoEditEnabled(
                enabled,
                for: scope,
                updateGlobalDefault: true
            )
        }
    }

    static func autoEditPermissionGuidance(
        agent: AgentProviderKind,
        autoEditEnabled: Bool,
        codexPermissionLevel: CodexAgentToolPreferences.PermissionLevel,
        claudePermissionLevel: ClaudeAgentToolPreferences.PermissionLevel,
        claudeBashToolEnabled: Bool
    ) -> AutoEditPermissionGuidance? {
        guard autoEditEnabled == false else { return nil }

        if agent == .codexExec {
            guard codexPermissionLevel != .readOnly else { return nil }
            return AutoEditPermissionGuidance(
                provider: .codex,
                message: "Codex sandbox allows file edits — set Read Only",
                actionTitle: "Set Read Only",
                action: .setCodexReadOnly
            )
        }

        if agent.usesClaudeTooling {
            guard claudePermissionLevel != .requireApproval else { return nil }
            return AutoEditPermissionGuidance(
                provider: .claude,
                message: "Claude sandbox allows file edits — set Require Approval",
                actionTitle: "Set Require Approval",
                action: .setClaudeRequireApproval
            )
        }

        return nil
    }

    @discardableResult
    func refreshAutoEditPermissionGuidanceForActiveSession(syncUI: Bool = true) -> Bool {
        guard let activeSession else {
            guard autoEditPermissionGuidance != nil else { return false }
            autoEditPermissionGuidance = nil
            if syncUI {
                syncStatusPillsUIState()
            }
            return true
        }
        let nextGuidance = providerBindingService.autoEditGuidance(for: activeSession)
        if activeSession.runState.isActive,
           activeSession.autoEditEnabled == false,
           autoEditPermissionGuidance != nil,
           nextGuidance == nil
        {
            return false
        }
        guard autoEditPermissionGuidance != nextGuidance else { return false }
        autoEditPermissionGuidance = nextGuidance
        if syncUI {
            syncStatusPillsUIState()
        }
        return true
    }

    func applyAutoEditPermissionGuidanceAction() {
        guard let guidance = autoEditPermissionGuidance else { return }
        let providerID = providerBindingService.applyAutoEditGuidanceAction(guidance.action)
        providerPreferenceDidChange(providerID, bumpProviderBindingRevision: false)
        refreshAutoEditPermissionGuidanceForActiveSession()
    }

    func setProviderPermissionLevel(_ id: AgentProviderPermissionLevelID) {
        let providerID = providerBindingService.setPermissionLevel(id)
        providerPreferenceDidChange(providerID, bumpProviderBindingRevision: false)
    }

    func applyCodexToolSettingMutation(_ mutation: CodexToolSettingMutation) {
        providerBindingService.applyCodexToolSettingMutation(mutation)
        providerPreferenceDidChange(.codex, bumpProviderBindingRevision: false)
    }

    func applyClaudeToolSettingMutation(_ mutation: ClaudeToolSettingMutation) {
        providerBindingService.applyClaudeToolSettingMutation(mutation)
        providerPreferenceDidChange(.claude, bumpProviderBindingRevision: false)
    }

    func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
        if let activeSession, activeSession.selectedAgent.usesClaudeTooling {
            providerBindingService.setClaudeEffortLevel(
                level,
                forModelRaw: activeSession.selectedModelRaw,
                agentKind: activeSession.selectedAgent
            )
        } else {
            providerBindingService.setClaudeEffortLevel(level)
        }
        providerPreferenceDidChange(.claude, bumpProviderBindingRevision: false)
        for session in sessions.values where session.runState.isActive {
            claudeCoordinator.scheduleApplyCurrentClaudeModelAndEffortIfPossible(
                for: session,
                reason: "claude_effort_changed"
            )
        }
    }

    func providerPreferenceDidChange(
        _ providerID: AgentProviderBindingID,
        bumpProviderBindingRevision: Bool = true
    ) {
        if bumpProviderBindingRevision {
            providerBindingService.bumpRevision(for: providerID)
        }
        providerBindingService.providerPreferenceChanged(
            providerID: providerID,
            sessions: Array(sessions.values),
            currentTabID: currentTabID,
            codexCoordinator: codexCoordinator,
            scheduleSave: { [weak self] tabID in
                self?.scheduleSave(for: tabID)
            },
            updateActiveBindings: { [weak self] session in
                self?.updateBindingsFromSession(session)
            },
            refreshGuidance: { [weak self] in
                self?.refreshAutoEditPermissionGuidanceForActiveSession()
            }
        )
        syncAllActiveUIState()
    }
}
