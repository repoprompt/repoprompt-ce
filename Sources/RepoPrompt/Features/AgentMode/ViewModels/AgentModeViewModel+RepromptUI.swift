import Foundation
import RepoPromptSettingsCore

/// V3 acknowledges one rewrite billing route plus the optional recent-chat exposure.
/// Receipts from the removed consult flow cannot authorize this disclosure.
enum AgentRepromptDisclosure {
    static let key = "agentReprompt.rewriteRecipient.v3."
    static func isAcknowledged(providerID: String?, defaults: UserDefaults) -> Bool {
        guard let providerID else { return false }
        return defaults.bool(forKey: key + providerID)
    }

    static func acknowledge(providerID: String, defaults: UserDefaults) {
        defaults.set(true, forKey: key + providerID)
    }
}

extension AgentModeViewModel {
    var repromptIncludesRecentChat: Bool {
        modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID).agentRepromptIncludesRecentChat ?? true
    }

    var repromptMode: AgentRepromptMode {
        modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID).agentRepromptMode ?? .review
    }

    func setRepromptMode(_ mode: AgentRepromptMode) {
        updateRepromptPreferences { $0.agentRepromptMode = mode == .review ? nil : mode }
    }

    private func updateRepromptPreferences(_ update: (inout AgentModelsSettingsProfile) -> Void) {
        let workspaceID = workspaceManager?.activeWorkspaceID
        var profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
        update(&profile)
        let mode = workspaceID.map { modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode } ?? .useGlobalSettings
        switch AgentModelsEditingScope.resolve(workspaceID: workspaceID, inheritanceMode: mode) {
        case .global: modelRouterSettingsStore.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        case let .workspace(id): modelRouterSettingsStore.setWorkspaceAgentModelsProfile(workspaceID: id, profile: profile)
        }
        invalidateRepromptIfNeeded()
        syncStatusPillsUIState()
    }

    func configuredRepromptModels() -> [AIModel] {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        var candidates = AIModel.allModels()
        for model in promptManager?.availableModels ?? [] where !candidates.contains(model) {
            candidates.append(model)
        }
        for model in [profile.agentRepromptModelRaw, profile.planningModelRaw].compactMap(\.self).compactMap(AIModel.fromModelName) where !candidates.contains(model) {
            candidates.append(model)
        }
        return candidates.filter { model in
            AgentRepromptModelPolicy.supportsSideCall(model) && model.canStream
                && (repromptAvailability?(model) ?? (promptManager?.mcpOracleIsProviderConfigured(for: model) == true))
        }
    }

    func repromptModelSelectionRaw() -> String {
        modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID).agentRepromptModelRaw ?? ""
    }

    func resolvedRepromptModel(session: TabSession? = nil) -> AIModel? {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        return AgentRepromptModelPolicy.resolve(
            selection: profile.agentRepromptModelRaw, primary: profile.planningModelRaw.flatMap(AIModel.fromModelName),
            currentProvider: (session ?? activeSession)?.selectedAgent, configured: configuredRepromptModels()
        )
    }

    func setRepromptModelRaw(_ raw: String) {
        let workspaceID = workspaceManager?.activeWorkspaceID
        var profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceID)
        profile.agentRepromptModelRaw = raw.isEmpty ? nil : raw
        let mode = workspaceID.map { modelRouterSettingsStore.workspaceAgentModelsSettings(for: $0).inheritanceMode } ?? .useGlobalSettings
        switch AgentModelsEditingScope.resolve(workspaceID: workspaceID, inheritanceMode: mode) {
        case .global: modelRouterSettingsStore.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        case let .workspace(id): modelRouterSettingsStore.setWorkspaceAgentModelsProfile(workspaceID: id, profile: profile)
        }
        invalidateRepromptIfNeeded()
        syncStatusPillsUIState()
    }

    func setRepromptIncludesRecentChat(_ enabled: Bool) {
        updateRepromptPreferences { $0.agentRepromptIncludesRecentChat = enabled ? nil : false }
    }

    func repromptPillProps() -> AgentRepromptPillProps {
        let model = resolvedRepromptModel()
        let recipient = model.map { model in
            let route = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model).map { String(describing: $0.backendID) }
                ?? String(describing: model.providerType)
            return route + (repromptIncludesRecentChat ? ".recent-chat" : ".no-chat")
        }
        return .init(
            isOn: repromptEnabled, isAvailable: model != nil, isPreparing: repromptOperation?.phase.isStreaming == true,
            modelDisplayName: model?.displayName, providerID: recipient,
            requiresDisclosure: !AgentRepromptDisclosure.isAcknowledged(providerID: recipient, defaults: .standard),
            unavailableReason: model == nil ? "Connect or choose a Re-prompt model in Agent Models settings." : nil
        )
    }

    func setRepromptEnabled(_ enabled: Bool, acknowledgingProviderID: String? = nil) {
        if enabled {
            let props = repromptPillProps()
            guard props.isAvailable, let providerID = props.providerID else { return }
            if let acknowledgingProviderID {
                guard acknowledgingProviderID == providerID else { return }
                AgentRepromptDisclosure.acknowledge(providerID: providerID, defaults: .standard)
            }
            guard AgentRepromptDisclosure.isAcknowledged(providerID: providerID, defaults: .standard) else { return }
        } else if repromptOperation?.phase.isBusy == true { cancelReprompt() }
        repromptEnabled = enabled
        syncStatusPillsUIState()
    }

    @discardableResult
    func restoreRepromptRecovery(tabID: UUID, confirmedReplacement: Bool = false) -> Bool {
        guard currentTabID == tabID, let recovery = repromptUIStore.recoveries[tabID] else { return false }
        guard confirmedReplacement || retrieveDraftText(for: tabID) == recovery.draftAtInvalidation else { return false }
        repromptOperation?.cancel(restoreOriginal: false, recover: false)
        _ = loadDraftSnapshotForComposer(for: tabID)
        restoreComposerDraft(tabID: tabID, text: recovery.text, message: "Restored Re-prompt draft.", strategy: .replaceAlways)
        repromptUIStore.recoveries[tabID] = nil
        return true
    }
}
