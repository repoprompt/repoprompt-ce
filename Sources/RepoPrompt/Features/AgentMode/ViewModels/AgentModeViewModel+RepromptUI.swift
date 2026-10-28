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

    /// Essential informed-consent facts, kept short enough to read before enabling.
    static func summary(modelName: String, routeName: String, includesRecentChat: Bool) -> [String] {
        let history = includesRecentChat ? ", recent chat excerpts" : ""
        return [
            "Sends your message, guidance, root names and selected paths\(history) to \(modelName) via \(routeName). Never file contents, attachments, git or tool output.",
            "\(routeName) billing and retention apply. Avoid secrets.",
            "Model Router or Auto Effort, if on, may judge the draft before you send."
        ]
    }

    /// Describes the current, user-configurable Re-prompt bindings (empty when cleared).
    static func howItWorks(rewriteKey: String, sendOriginalKey: String) -> String {
        let rewrite = rewriteKey.isEmpty ? "" : ", \(rewriteKey) rewrites again"
        let original = sendOriginalKey.isEmpty ? "" : ", \(sendOriginalKey) sends the original immediately"
        return "Send or Return rewrites the message in the composer; press either again to send the visible text. "
            + "You can keep editing at any time; typing stops the rewrite. Esc restores the original for your next Send\(rewrite)\(original). "
            + "Clarification is optional; an answer may trigger one more rewrite. Send automatically mode "
            + "(Re-prompt menu) dispatches completed rewrites unless a question or slash-leading text needs review."
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
        // The configured/runtime-facing list, not every parseable catalog ID.
        let candidates = repromptAvailability == nil ? (promptManager?.availableModels ?? []) : AIModel.allModels()
        return candidates.filter { model in
            AgentRepromptModelPolicy.supportsSideCall(model) && model.canStream
                && (repromptAvailability?(model) ?? (promptManager?.mcpOracleIsProviderConfigured(for: model) == true))
        }
    }

    func repromptModelSelectionRaw() -> String {
        modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID).agentRepromptModelRaw ?? ""
    }

    func resolvedRepromptModel(session: TabSession? = nil) -> AIModel? {
        repromptModelResolution(session: session).model
    }

    /// Automatic defaults are pinned only once Re-prompt is enabled or a preparation begins, so
    /// rendering the pill while availability is still loading never freezes a worse billing route.
    func repromptModelResolution(session: TabSession? = nil, pinningDefault: Bool = false) -> AgentRepromptModelResolution {
        let profile = modelRouterSettingsStore.effectiveAgentModelsProfile(workspaceID: workspaceManager?.activeWorkspaceID)
        let provider = (session ?? activeSession)?.selectedAgent
        let configured = configuredRepromptModels()
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
        let resolution = repromptModelResolution()
        let model = resolution.model
        let recipient = model.map { model in
            let route = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model).map { String(describing: $0.backendID) }
                ?? String(describing: model.providerType)
            return route + (repromptIncludesRecentChat ? ".recent-chat" : ".no-chat")
        }
        return .init(
            isOn: repromptEnabled, isAvailable: model != nil, isPreparing: repromptOperation?.phase.isStreaming == true,
            modelDisplayName: model?.displayName ?? "Choose a model", providerID: recipient,
            requiresDisclosure: !AgentRepromptDisclosure.isAcknowledged(providerID: recipient, defaults: .standard),
            unavailableReason: resolution.unavailableReason
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
        if enabled {
            // Freeze the consented route synchronously, with no await since recipient validation.
            _ = repromptModelResolution(pinningDefault: true)
        } else if repromptOperation == nil {
            repromptDefaultModel = nil
        }
        syncStatusPillsUIState()
    }

    /// Resolve an invalidated edited draft explicitly; keeping it bypasses preparation on the next Return.
    func keepRepromptRewrite(tabID: UUID) {
        guard currentTabID == tabID, var recovery = repromptUIStore.recoveries[tabID],
              recovery.draftAtInvalidation == retrieveDraftText(for: tabID) else { return }
        recovery.requiresDecision = false
        recovery.bypassesPreparation = true
        repromptUIStore.recoveries[tabID] = recovery
    }

    @discardableResult
    func restoreRepromptOriginal(tabID: UUID, confirmedReplacement: Bool = false) -> Bool {
        guard currentTabID == tabID, var recovery = repromptUIStore.recoveries[tabID],
              confirmedReplacement || retrieveDraftText(for: tabID) == recovery.draftAtInvalidation else { return false }
        repromptOperation?.cancel(restoreOriginal: false, recover: false)
        _ = loadDraftSnapshotForComposer(for: tabID)
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
        guard confirmedReplacement || retrieveDraftText(for: tabID) == recovery.draftAtInvalidation else { return false }
        repromptOperation?.cancel(restoreOriginal: false, recover: false)
        _ = loadDraftSnapshotForComposer(for: tabID)
        restoreComposerDraft(tabID: tabID, text: recovery.text, message: "Restored Re-prompt draft.", strategy: .replaceAlways)
        var kept = recovery
        kept.requiresDecision = false
        kept.bypassesPreparation = true
        kept.draftAtInvalidation = recovery.text
        repromptUIStore.recoveries[tabID] = kept
        return true
    }
}
