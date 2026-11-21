import Foundation
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// Records authorization for intercepting ordinary Send on a specific route and payload.
/// An explicit one-draft Re-prompt action does not consult or change this receipt.
enum AgentRepromptDisclosure {
    static let key = "agentReprompt.rewriteRecipient.v4."
    static func isAcknowledged(providerID: String?, defaults: UserDefaults) -> Bool {
        guard let providerID else { return false }
        return defaults.bool(forKey: key + providerID)
    }

    static func acknowledge(providerID: String, defaults: UserDefaults) {
        defaults.set(true, forKey: key + providerID)
    }

    /// Describes the request alongside the composer controls.
    static func summary(modelName: String, routeName: String, includesRecentChat: Bool) -> [String] {
        let payload = includesRecentChat
            ? "your message, guidance, attachment names, the session title and recent chat excerpts"
            : "your message, guidance and attachment names"
        return [
            "Sends \(payload) to \(modelName) via \(routeName). Never file contents, git or tool output.",
            "\(routeName) billing and retention apply. Avoid secrets.",
            "Model Router or Auto Effort, if on, may judge the draft before you send."
        ]
    }
}

extension AgentModeViewModel {
    var repromptEnabled: Bool {
        get {
            guard let workspaceID = workspaceManager?.activeWorkspaceID else { return unscopedRepromptEnabled }
            return modelRouterSettingsStore.workspaceAgentModelsSettings(for: workspaceID).agentRepromptEnabled ?? false
        }
        set {
            guard let workspaceID = workspaceManager?.activeWorkspaceID else {
                unscopedRepromptEnabled = newValue
                return
            }
            modelRouterSettingsStore.setWorkspaceAgentRepromptEnabled(workspaceID: workspaceID, enabled: newValue)
        }
    }

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
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    func configuredRepromptModels() -> [AIModel] {
        // The configured/runtime-facing list, not every parseable catalog ID.
        let candidates = repromptAvailability == nil ? (promptManager?.availableModels ?? []) : AIModel.allModels()
        return candidates.filter { model in
            AgentOperationEligibility.AIOperation.reprompt.supports(model)
                && (repromptAvailability?(model) ?? (promptManager?.mcpOracleIsProviderConfigured(for: model) == true))
        }
    }

    func repromptModelSelectionRaw() -> String {
        modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID).agentRepromptModelRaw ?? ""
    }

    func resolvedRepromptModel(session: TabSession? = nil) -> AIModel? {
        repromptModelResolution(session: session).model
    }

    /// One fresh menu projection; actions still resolve availability independently.
    func repromptMenuModels() -> (configured: [AIModel], resolved: AIModel?) {
        let configured = configuredRepromptModels()
        return (configured, repromptModelResolution(configured: configured).model)
    }

    /// Automatic defaults are pinned only once Re-prompt is enabled or a preparation begins, so
    /// rendering the pill while availability is still loading never freezes a worse billing route.
    func repromptModelResolution(session: TabSession? = nil, pinningDefault: Bool = false) -> AgentRepromptModelResolution {
        repromptModelResolution(session: session, pinningDefault: pinningDefault, configured: configuredRepromptModels())
    }

    private func repromptModelResolution(
        session: TabSession? = nil,
        pinningDefault: Bool = false,
        configured: [AIModel]
    ) -> AgentRepromptModelResolution {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        let provider = (session ?? activeSession)?.selectedAgent
        if let raw = profile.agentRepromptModelRaw, !raw.isEmpty {
            // An explicit selection is never replaced, even when it is disconnected.
            return AgentRepromptModelPolicy.resolve(selection: raw, currentProvider: provider, configured: configured)
                .map(AgentRepromptModelResolution.resolved) ?? .savedSelectionUnavailable(raw: raw)
        }
        if let cached = repromptDefaultModel, cached.provider == provider {
            // Losing availability after resolution requires a choice, never a silent billing-route switch.
            return configured.contains(cached.model) ? .resolved(cached.model) : .automaticDefaultUnavailable(cached.model)
        }
        guard let resolved = AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: provider, configured: configured) else {
            return .noAutomaticDefault
        }
        if pinningDefault || repromptEnabled { repromptDefaultModel = (provider, resolved) }
        return .resolved(resolved)
    }

    /// Clears an explicit choice so the bounded automatic policy applies again.
    func useAutomaticRepromptModel() {
        repromptDefaultModel = nil
        setRepromptModelRaw("")
    }

    /// Human-readable billing route for the disclosure; compatible backends name their backend.
    func repromptRouteName(for model: AIModel) -> String {
        let provider = AIProviderType.displayName(for: model.providerType)
        guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return provider }
        return "\(String(describing: descriptor.backendID)) through \(provider)"
    }

    func setRepromptModelRaw(_ raw: String) {
        updateRepromptPreferences { $0.agentRepromptModelRaw = raw.isEmpty ? nil : raw }
    }

    func setRepromptIncludesRecentChat(_ enabled: Bool) {
        updateRepromptPreferences { $0.agentRepromptIncludesRecentChat = enabled ? nil : false }
    }

    private func repromptAutomaticRecipient(for model: AIModel) -> String {
        let route = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model).map { String(describing: $0.backendID) }
            ?? String(describing: model.providerType)
        return route + (repromptIncludesRecentChat ? ".recent-chat" : ".no-chat")
    }

    func repromptCanRewriteOnSend(model: AIModel) -> Bool {
        repromptAvailability != nil || AgentRepromptDisclosure.isAcknowledged(
            providerID: repromptAutomaticRecipient(for: model), defaults: .standard
        )
    }

    func repromptPillProps() -> AgentRepromptPillProps {
        let resolution = repromptModelResolution()
        let model = resolution.model
        return .init(
            isOn: repromptEnabled && (model.map { repromptCanRewriteOnSend(model: $0) } ?? true),
            isAvailable: model != nil, isPreparing: repromptOperation?.phase.isStreaming == true,
            modelDisplayName: model?.displayName ?? "Choose a model", unavailableReason: resolution.unavailableReason,
            dataDisclosure: model.map { model in
                AgentRepromptDisclosure.summary(
                    modelName: model.displayName, routeName: repromptRouteName(for: model),
                    includesRecentChat: repromptIncludesRecentChat
                )
            } ?? []
        )
    }

    func setRepromptEnabled(_ enabled: Bool) {
        if enabled {
            guard let model = repromptModelResolution(pinningDefault: true).model else { return }
            AgentRepromptDisclosure.acknowledge(providerID: repromptAutomaticRecipient(for: model), defaults: .standard)
        } else {
            // Turning Re-prompt off stops every rewrite, including those in sessions not on screen.
            for operation in Array(repromptOperations.values) where operation.phase.isBusy {
                operation.cancel()
            }
            if repromptOperations.isEmpty { repromptDefaultModel = nil }
        }
        repromptEnabled = enabled
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    /// Resolve an invalidated edited draft explicitly; keeping it bypasses preparation on the next Return.
    func keepRepromptRewrite(tabID: UUID) {
        guard currentTabID == tabID, var recovery = repromptUIStore.recoveries[tabID],
              recovery.draftAtInvalidation == draftRuntime.text(for: tabID) else { return }
        recovery.requiresDecision = false
        recovery.bypassesPreparation = true
        repromptUIStore.recoveries[tabID] = recovery
    }

    @discardableResult
    func restoreRepromptOriginal(tabID: UUID, confirmedReplacement: Bool = false) -> Bool {
        guard currentTabID == tabID, var recovery = repromptUIStore.recoveries[tabID],
              confirmedReplacement || draftRuntime.text(for: tabID) == recovery.draftAtInvalidation else { return false }
        repromptOperation?.cancel(restoreOriginal: false, recover: false)
        _ = draftRuntime.loadSnapshot(tabID: tabID)
        restoreComposerDraft(tabID: tabID, text: recovery.originalDraft, message: "Restored original draft.", strategy: .replaceAlways)
        recovery.requiresDecision = false
        recovery.bypassesPreparation = false
        recovery.draftAtInvalidation = recovery.originalDraft
        repromptUIStore.recoveries[tabID] = recovery
        return true
    }

    @discardableResult
    func restoreRepromptRecovery(tabID: UUID, confirmedReplacement: Bool = false) -> Bool {
        guard currentTabID == tabID, let recovery = repromptUIStore.recoveries[tabID] else { return false }
        guard confirmedReplacement || draftRuntime.text(for: tabID) == recovery.draftAtInvalidation else { return false }
        repromptOperation?.cancel(restoreOriginal: false, recover: false)
        _ = draftRuntime.loadSnapshot(tabID: tabID)
        restoreComposerDraft(tabID: tabID, text: recovery.text, message: "Restored Re-prompt draft.", strategy: .replaceAlways)
        var kept = recovery
        kept.requiresDecision = false
        kept.bypassesPreparation = true
        kept.draftAtInvalidation = recovery.text
        repromptUIStore.recoveries[tabID] = kept
        return true
    }
}
