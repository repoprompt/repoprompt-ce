import Foundation

/// Versioned receipts are per recipient configuration, not a single last-provider preference.
/// V1 understated consult exposure and must never authorize the expanded disclosure.
enum AgentRepromptDisclosure {
    static let key = "agentReprompt.acknowledgedProviders.v2."

    static func identity(primaryProvider: String?, oracleProviders: [String], contextBuilderProvider: String?, allowsContext: Bool) -> String? {
        guard let primaryProvider else { return nil }
        let recipients = allowsContext
            ? [primaryProvider, Set(oracleProviders).sorted().joined(separator: ","), contextBuilderProvider ?? "configured", "automatic"]
            : [primaryProvider, "never"]
        return recipients.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    static func isAcknowledged(providerID: String?, defaults: UserDefaults) -> Bool {
        guard let providerID else { return false }
        return defaults.bool(forKey: key + providerID)
    }

    static func acknowledge(providerID: String, defaults: UserDefaults) {
        defaults.set(true, forKey: key + providerID)
    }
}

extension AgentModeViewModel {
    func repromptPillProps() -> AgentRepromptPillProps {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        let model = profile.planningModelRaw.flatMap(AIModel.fromModelName)
        let available = model.map { repromptAvailability?($0) ?? (promptManager?.mcpOracleIsProviderConfigured(for: $0) == true) } ?? false
        let oracleProviders = ([profile.planningModelRaw].compactMap(\.self) + profile.additionalOracleModelRaws)
            .compactMap(AIModel.fromModelName).map { String(describing: $0.providerType) }
        let providerID = AgentRepromptDisclosure.identity(
            primaryProvider: model.map { String(describing: $0.providerType) }, oracleProviders: oracleProviders,
            contextBuilderProvider: profile.contextBuilderAgentRaw ?? repromptContextBuilder?.selectedAgent.rawValue,
            allowsContext: profile.agentRepromptContextPolicy != .never
        )
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
