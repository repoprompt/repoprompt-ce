import Foundation

@MainActor
final class AgentModeProviderBindingService {
    let preferences: AgentProviderPreferenceSnapshotStore

    convenience init() {
        self.init(preferences: AgentProviderPreferenceSnapshotStore())
    }

    init(preferences: AgentProviderPreferenceSnapshotStore) {
        self.preferences = preferences
    }

    func topLevelSettingsControlsBinding(providerID: AgentProviderBindingID) -> AgentProviderControlsBinding {
        preferences.topLevelSettingsControlsBinding(providerID: providerID)
    }

    func controlsBinding(
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String? = nil,
        permissionProfile: AgentProviderPermissionProfile,
        isSubagent: Bool,
        externallyManagedReason: String?
    ) -> AgentProviderControlsBinding {
        preferences.controlsBinding(
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            permissionProfile: permissionProfile,
            isSubagent: isSubagent,
            externallyManagedReason: externallyManagedReason
        )
    }

    func runtimePermission(
        for agent: AgentProviderKind,
        profile: AgentProviderPermissionProfile
    ) -> AgentProviderRuntimePermissionBinding {
        preferences.runtimePermission(for: agent, profile: profile)
    }

    func permissionProfileForMCPActivation(isSubagent: Bool) -> AgentProviderPermissionProfile {
        permissionProfileForMCPActivation(isSubagent: isSubagent, provider: nil)
    }

    /// Provider-aware variant of `permissionProfileForMCPActivation(isSubagent:)`.
    ///
    /// MCP-originated agents use the same permission policy as sub-agents, including
    /// top-level sessions created by `agent_run.start` / `agent_manage.create_session`.
    /// When the global policy is `.custom`, the resolver consults the per-provider
    /// override; with `provider == nil` we fall back to `.mcpSafeDefaults` because we can't
    /// make a safer choice without the provider context.
    ///
    /// SEARCH-HELPER: Sub-agent Permissions, tri-state policy, Safe Managed resolution
    func permissionProfileForMCPActivation(
        isSubagent: Bool,
        provider: AgentProviderBindingID?
    ) -> AgentProviderPermissionProfile {
        _ = isSubagent
        let defaults = preferences.defaults
        let global = AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: preferences.securePermissions)
        switch global {
        case .safeManaged:
            return .mcpSafeDefaults
        case .inheritProviderSettings:
            return .userConfigured
        case .custom:
            guard let provider else { return .mcpSafeDefaults }
            let level = AgentModePermissionPreferences.providerSubagentPermissionLevel(
                for: provider,
                defaults: defaults,
                secureStore: preferences.securePermissions
            )
            return .providerOverride(level)
        }
    }

    /// Active global sub-agent policy. Exposed so UI callers can bind to the tri-state
    /// without reaching into `AgentModePermissionPreferences` directly.
    func subagentPermissionPolicy() -> AgentSubagentPermissionPolicy {
        AgentModePermissionPreferences.subagentPermissionPolicy(defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func setSubagentPermissionPolicy(_ policy: AgentSubagentPermissionPolicy) {
        AgentModePermissionPreferences.setSubagentPermissionPolicy(policy, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func providerSubagentPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        AgentModePermissionPreferences.providerSubagentPermissionLevel(for: providerID, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func setProviderSubagentPermissionLevel(
        _ level: AgentProviderPermissionLevelID,
        for providerID: AgentProviderBindingID
    ) {
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(level, for: providerID, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func externallyManagedPermissionReason(
        isSubagent: Bool,
        isMCPControlled: Bool = true,
        permissionProfile: AgentProviderPermissionProfile
    ) -> String? {
        if isSubagent || isMCPControlled {
            switch permissionProfile {
            case .mcpSafeDefaults:
                return "MCP-started agents use the sub-agent Safe Managed permission defaults."
            case .userConfigured:
                return "MCP-started agents inherit your provider-configured permissions. Change the global sub-agent policy before starting an agent."
            case .providerOverride:
                return "MCP-started agents use the Custom per-provider mode selected in Agent Permissions."
            }
        }
        return nil
    }

    func autoEditGuidance(
        for session: AgentModeViewModel.TabSession
    ) -> AgentModeViewModel.AutoEditPermissionGuidance? {
        autoEditGuidance(
            agent: session.selectedAgent,
            autoEditEnabled: session.autoEditEnabled
        )
    }

    func autoEditGuidance(
        agent: AgentProviderKind,
        autoEditEnabled: Bool
    ) -> AgentModeViewModel.AutoEditPermissionGuidance? {
        guard autoEditEnabled == false else { return nil }

        if agent == .codexExec {
            guard CodexAgentToolPreferences.permissionLevel(defaults: preferences.defaults, secureStore: preferences.securePermissions) != .readOnly else { return nil }
            return AgentModeViewModel.AutoEditPermissionGuidance(
                provider: .codex,
                message: "Codex sandbox allows file edits — set Read Only",
                actionTitle: "Set Read Only",
                action: .setCodexReadOnly
            )
        }

        if agent.usesClaudeTooling {
            guard ClaudeAgentToolPreferences.permissionLevel(defaults: preferences.defaults, secureStore: preferences.securePermissions) != .requireApproval else { return nil }
            return AgentModeViewModel.AutoEditPermissionGuidance(
                provider: .claude,
                message: "Claude sandbox allows file edits — set Require Approval",
                actionTitle: "Set Require Approval",
                action: .setClaudeRequireApproval
            )
        }

        return nil
    }

    @discardableResult
    func applyAutoEditGuidanceAction(
        _ action: AgentModeViewModel.AutoEditPermissionGuidance.Action
    ) -> AgentProviderBindingID {
        switch action {
        case .setCodexReadOnly:
            setPermissionLevel(.codex(.readOnly))
        case .setClaudeRequireApproval:
            setPermissionLevel(.claude(.requireApproval))
        }
    }

    func providerPreferenceChanged(
        providerID: AgentProviderBindingID,
        sessions: [AgentModeViewModel.TabSession],
        currentTabID: UUID?,
        codexCoordinator: CodexAgentModeCoordinator,
        scheduleSave: @escaping (UUID) -> Void,
        updateActiveBindings: @escaping (AgentModeViewModel.TabSession) -> Void,
        refreshGuidance: @escaping () -> Void
    ) {
        var shouldRefreshActiveBindings = false
        var shouldRefreshGuidance = false

        for session in sessions where session.selectedAgent.providerBindingID == providerID {
            scheduleSave(session.tabID)
            if session.tabID == currentTabID {
                shouldRefreshActiveBindings = true
                shouldRefreshGuidance = true
            }

            switch providerID {
            case .codex:
                codexCoordinator.handleToolPreferencesChanged(for: session)
            case .claude:
                // Claude launch settings are revalidated immediately before dispatch.
                // Avoid an eager untracked shutdown that could race a newly started run.
                break
            case .openCode:
                let runtime = runtimePermission(for: session.selectedAgent, profile: session.permissionProfile)
                guard let sessionModeID = runtime.acpSessionModeID,
                      session.runState.isActive,
                      let controller = session.acpController else { continue }
                Task { @MainActor in
                    let providerName = session.selectedAgent.displayName
                    if AgentRuntimeProviderService.enableDebugLogging { print("[ACP-Runner] tab=\(session.tabID) applying \(providerName) session mode=\(sessionModeID)") }
                    do {
                        await controller.setAutoApproveAllToolPermissions(runtime.autoApproveAllACPToolPermissions)
                        try await controller.setSessionMode(sessionModeID)
                        if runtime.acceptsPendingACPApprovalWhenActivated, let pendingApproval = session.pendingApproval {
                            await controller.respondToPermissionRequest(id: pendingApproval.requestID.displayValue, decision: .acceptForSession)
                        }
                    } catch {
                        if AgentRuntimeProviderService.enableDebugLogging { print("[ACP-Runner] tab=\(session.tabID) failed to apply \(providerName) session mode=\(sessionModeID) error=\(error.localizedDescription)") }
                    }
                    if session.tabID == currentTabID {
                        updateActiveBindings(session)
                    }
                }
            case .cursor:
                let runtime = runtimePermission(for: session.selectedAgent, profile: session.permissionProfile)
                guard session.runState.isActive, let controller = session.acpController else { continue }
                Task { @MainActor in
                    await controller.setAutoApproveAllToolPermissions(runtime.autoApproveAllACPToolPermissions)
                    if runtime.autoApproveAllACPToolPermissions, let pendingApproval = session.pendingApproval {
                        await controller.respondToPermissionRequest(id: pendingApproval.requestID.displayValue, decision: .acceptForSession)
                    }
                    if session.tabID == currentTabID {
                        updateActiveBindings(session)
                    }
                }
            }
        }

        if shouldRefreshActiveBindings, let active = sessions.first(where: { $0.tabID == currentTabID }) {
            updateActiveBindings(active)
        } else if shouldRefreshGuidance {
            refreshGuidance()
        }
    }

    @discardableResult
    func setPermissionLevel(_ id: AgentProviderPermissionLevelID) -> AgentProviderBindingID {
        preferences.setPermissionLevel(id)
    }

    func setCodexBashToolEnabled(_ enabled: Bool) {
        preferences.setCodexBashToolEnabled(enabled)
    }

    func setCodexSearchToolEnabled(_ enabled: Bool) {
        preferences.setCodexSearchToolEnabled(enabled)
    }

    func setCodexGoalSupportEnabled(_ enabled: Bool) {
        preferences.setCodexGoalSupportEnabled(enabled)
    }

    func setCodexMCPServerEnabled(normalizedName: String, enabled: Bool) {
        preferences.setCodexMCPServerEnabled(normalizedName: normalizedName, enabled: enabled)
    }

    func setClaudeBashToolEnabled(_ enabled: Bool) {
        preferences.setClaudeBashToolEnabled(enabled)
    }

    func setClaudeMCPStrictModeEnabled(_ enabled: Bool) {
        preferences.setClaudeMCPStrictModeEnabled(enabled)
    }

    func setClaudeToolSearchEnabled(_ enabled: Bool) {
        preferences.setClaudeToolSearchEnabled(enabled)
    }

    func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
        preferences.setClaudeEffortLevel(level)
    }

    func setClaudeEffortLevel(
        _ level: ClaudeCodeEffortLevel,
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind?
    ) {
        preferences.setClaudeEffortLevel(level, forModelRaw: modelRaw, agentKind: agentKind)
    }

    func claudeEffortLevel() -> ClaudeCodeEffortLevel {
        ClaudeAgentToolPreferences.effortLevel(defaults: preferences.defaults)
    }

    func claudeEffortLevel(
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind?
    ) -> ClaudeCodeEffortLevel {
        guard let modelRaw, let agentKind else {
            return claudeEffortLevel()
        }
        return ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: modelRaw,
            agentKind: agentKind,
            defaults: preferences.defaults
        )
    }

    func setClaudeAgentModePromptDelivery(_ delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery) {
        preferences.setClaudeAgentModePromptDelivery(delivery)
    }

    func bumpRevision(for providerID: AgentProviderBindingID) {
        preferences.bumpRevision(for: providerID)
    }
}
