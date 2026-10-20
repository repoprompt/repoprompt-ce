import Foundation

/// Only the most recently acknowledged provider is remembered. Changing it requires consent again.
enum AgentRepromptDisclosure {
    static let key = "agentReprompt.acknowledgedProvider.v1"
    static func isAcknowledged(providerID: String?, defaults: UserDefaults) -> Bool {
        guard let providerID else { return false }
        return defaults.string(forKey: key) == providerID
    }

    static func acknowledge(providerID: String, defaults: UserDefaults) {
        defaults.set(providerID, forKey: key)
    }
}

extension AgentModeViewModel {
    func repromptPillProps() -> AgentRepromptPillProps {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        let model = profile.planningModelRaw.flatMap(AIModel.fromModelName)
        let available = model.map { repromptAvailability?($0) ?? (promptManager?.mcpOracleIsProviderConfigured(for: $0) == true) } ?? false
        let providerID = model.map { String(describing: $0.providerType) }
        return .init(
            isOn: repromptEnabled, isAvailable: available, isPreparing: repromptOperation != nil,
            modelDisplayName: model?.displayName, providerID: providerID,
            requiresDisclosure: !AgentRepromptDisclosure.isAcknowledged(providerID: providerID, defaults: .standard),
            unavailableReason: available ? nil : "Configure the primary Oracle in Agent Models settings."
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
        }
        repromptEnabled = enabled
        syncStatusPillsUIState()
    }

    @discardableResult
    func restoreRepromptRecovery(tabID: UUID, confirmedReplacement: Bool = false) -> Bool {
        guard let recovery = repromptUIStore.recoveries[tabID] else { return false }
        guard confirmedReplacement || retrieveDraftText(for: tabID) == recovery.draftAtInvalidation else { return false }
        // Explicit replacement consumes restoration fragments already present in this draft.
        // Otherwise the next editor store could prepend the rejected original again.
        _ = loadDraftSnapshotForComposer(for: tabID)
        restoreComposerDraft(tabID: tabID, text: recovery.text, message: "Restored Re-prompt brief.", strategy: .replaceAlways)
        repromptUIStore.recoveries[tabID] = nil
        return true
    }
}
