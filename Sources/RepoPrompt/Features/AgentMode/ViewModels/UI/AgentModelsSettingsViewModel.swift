//
//  AgentModelsSettingsViewModel.swift
//  RepoPrompt
//
//  View model for AgentModelsSettingsView — the unified home for every
//  agent-mode model decision (Oracle, Built-in Chat, Context Builder agent,
//  and MCP agent role defaults).
//
//  SEARCH-HELPER: Agent Models, Oracle Model, Built-in Chat Model,
//  Context Builder Agent, Agent Role Defaults, Apply Recommended Setup,
//  Planning Model, sync toggle, workspace overrides
//
//  Related:
//  - Page:          /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
//  - Engine:        /RepoPrompt/Services/Recommendations/AutoRecommendationEngine.swift
//  - Role defaults: /RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift
//  - Sync key:      /RepoPrompt/Models/Settings/GlobalSettingsManager.swift
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentModelsSettingsViewModel: ObservableObject {
    // MARK: - Dependencies

    let apiSettingsVM: APISettingsViewModel
    private let settingsManager: any SettingsManaging
    private let notificationCenter: NotificationCenter
    private let engine: AutoRecommendationEngine

    // MARK: - Published state

    @Published private(set) var workspaceID: UUID?
    @Published private(set) var workspaceName: String?
    @Published private(set) var inheritanceMode: AgentModelsInheritanceMode
    @Published private(set) var profileSnapshot: AgentModelsSettingsProfile
    @Published private(set) var recommendations: RecommendationSet = .init()
    @Published private(set) var isApplyingAll: Bool = false
    @Published var syncChatWithOracle: Bool {
        didSet {
            guard !isReloadingScopedState, oldValue != syncChatWithOracle else { return }
            updateSelectedProfile(reason: "agent_models.sync_toggle") { profile in
                profile.syncChatModelWithOracle = syncChatWithOracle
                if syncChatWithOracle, profile.preferredComposeModelRaw != profile.planningModelRaw {
                    profile.preferredComposeModelRaw = profile.planningModelRaw
                }
            }
        }
    }

    /// When `true`, MCP `agent_manage list_agents` hides the extra per-agent
    /// compound model catalog while keeping the four sub-agent role labels
    /// (`explore`, `engineer`, `pair`, `design`) and their concrete model
    /// mappings visible. Manually supplied compound model IDs remain accepted by
    /// the resolver for backwards compatibility.
    ///
    /// SEARCH-HELPER: restrict MCP discovery catalog, role-label mappings,
    /// MCP list_agents filtering, hide non-role model IDs
    @Published var restrictMCPAgentDiscoveryToRoleLabels: Bool {
        didSet {
            guard !isReloadingScopedState, oldValue != restrictMCPAgentDiscoveryToRoleLabels else { return }
            updateSelectedProfile(reason: "agent_models.hide_non_role_toggle") { profile in
                profile.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
            }
        }
    }

    // MARK: - Bookkeeping

    private var cancellables = Set<AnyCancellable>()
    private var isReloadingScopedState = false

    // MARK: - Init

    init(
        apiSettingsVM: APISettingsViewModel,
        workspaceID: UUID? = nil,
        workspaceName: String? = nil,
        settingsManager: (any SettingsManaging)? = nil,
        settingsStore: GlobalSettingsStore? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let settingsManager = settingsManager ?? settingsStore
        let initialInheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let initialProfile = Self.profile(
            settingsManager: settingsManager,
            workspaceID: workspaceID,
            inheritanceMode: initialInheritanceMode
        )

        self.apiSettingsVM = apiSettingsVM
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        inheritanceMode = initialInheritanceMode
        profileSnapshot = initialProfile
        self.settingsManager = settingsManager
        _ = defaults // Retained for initializer compatibility while storage lives in GlobalSettingsStore.
        self.notificationCenter = notificationCenter
        engine = AutoRecommendationEngine(
            settingsStore: settingsStore,
            profileSettingsManager: settingsManager,
            apiSettingsViewModel: apiSettingsVM
        )
        syncChatWithOracle = initialProfile.syncChatModelWithOracle
        restrictMCPAgentDiscoveryToRoleLabels = initialProfile.restrictMCPAgentDiscoveryToRoleLabels

        observeNotifications()
        refresh()
    }

    // MARK: - Public Derived Values

    var hasWorkspace: Bool {
        workspaceID != nil
    }

    var workspaceDisplayName: String? {
        let trimmed = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var editingScope: AgentModelsEditingScope {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else { return .global }
        return .workspace(workspaceID)
    }

    var isEditingWorkspaceSettings: Bool {
        if case .workspace = editingScope { return true }
        return false
    }

    var isEditingGlobalSettings: Bool {
        !isEditingWorkspaceSettings
    }

    var effectiveScopeDescription: String {
        isEditingWorkspaceSettings ? "Using workspace overrides" : "Using global settings"
    }

    var workspaceAgentModelsTitle: String {
        if let workspaceDisplayName {
            return "Agent Models for Workspace: \(workspaceDisplayName)"
        }
        return "Agent Models"
    }

    var noWorkspaceExplanation: String {
        "No workspace is active, so Agent Models edits apply to global settings. Open a workspace to create workspace-specific overrides."
    }

    var showsRecommendationActions: Bool {
        hasWorkspace
    }

    var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    var hasConnectedCLIProvider: Bool {
        !AgentModelCatalog.selectableAgents(availability: availability).isEmpty
    }

    var currentOracleModelName: String {
        displayName(forChatModelRaw: profileSnapshot.planningModelRaw, fallback: "Select an Oracle model")
    }

    var currentBuiltinChatModelName: String {
        let raw = profileSnapshot.syncChatModelWithOracle
            ? profileSnapshot.planningModelRaw
            : profileSnapshot.preferredComposeModelRaw
        return displayName(
            forChatModelRaw: raw,
            fallback: "Select a Built-in Chat model"
        )
    }

    var selectedContextBuilderSelection: AgentModelCatalog.NormalizedAgentSelection {
        let selectedAgentRaw = profileSnapshot.contextBuilderAgentRaw
        let selectedModelRaw = selectedAgentRaw.flatMap { profileSnapshot.contextBuilderModelsByAgent?[$0] }
        return AgentModelCatalog.normalizeSelection(
            agentRaw: selectedAgentRaw,
            modelRaw: selectedModelRaw,
            availability: availability
        )
    }

    var selectedContextBuilderAgent: AgentProviderKind {
        selectedContextBuilderSelection.agent
    }

    var selectedContextBuilderModelRaw: String {
        selectedContextBuilderSelection.modelRaw
    }

    var selectedContextBuilderDisplayName: String {
        AgentModelCatalog.displayName(
            for: selectedContextBuilderModelRaw,
            agentKind: selectedContextBuilderAgent,
            availability: availability
        )
    }

    var recommendedOracleModelName: String? {
        guard let rec = recommendations.chatModel,
              let option = rec.option(for: rec.defaultBackend) else { return nil }
        let model = option.modelString ?? ""
        if let resolved = AIModel.fromModelName(model) {
            return resolved.displayName
        }
        return option.displayName
    }

    var recommendedContextBuilderDescription: String? {
        guard let rec = recommendations.contextBuilder else { return nil }
        return "\(rec.recommendedAgent.displayName) · \(rec.recommendedModel.displayName)"
    }

    var isOracleRecommendationSatisfied: Bool {
        recommendations.chatModel?.alreadySatisfied ?? true
    }

    var isContextBuilderRecommendationSatisfied: Bool {
        recommendations.contextBuilder?.alreadySatisfied ?? true
    }

    var roleDefaultsResolutions: [MCPAgentRoleDefaultsService.RoleDefaultResolution] {
        let profileStore = AgentModelsProfileRoleDefaultsStore(overrides: profileSnapshot.mcpAgentRoleOverrides)
        return MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            recommendedAvailability: availability.filteredForRecommendationProviders(settingsManager.globalRecommendationProviderFilter()),
            settingsStore: profileStore
        )
    }

    var roleDefaultsHasOverrides: Bool {
        roleDefaultsResolutions.contains(where: \.hasStoredOverride)
    }

    var hasUnsatisfiedRecommendations: Bool {
        recommendations.hasUnsatisfied
    }

    // MARK: - Scope

    func updateWorkspaceContext(workspaceID: UUID?, workspaceName: String?) {
        guard self.workspaceID != workspaceID || self.workspaceName != workspaceName else { return }
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        reloadScopedState()
        refresh()
    }

    func setInheritanceMode(_ mode: AgentModelsInheritanceMode) {
        guard let workspaceID else { return }
        guard inheritanceMode != mode else { return }
        settingsManager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: mode)
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.inheritance_mode")
    }

    // MARK: - Refresh

    /// Recompute the recommendation set.
    func refresh() {
        guard let workspaceID else {
            recommendations = RecommendationSet()
            return
        }
        let identity = AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: editingScope)
        let raw = engine.computeRecommendations(for: identity)
        recommendations = engine.applyMutedFlags(raw, workspaceID: workspaceID)
    }

    // MARK: - Destinations

    /// Destination for the Oracle model. Writes `planningModel` and, when the
    /// sync toggle is on, mirrors to `preferredComposeModel` in the selected
    /// global/workspace Agent Models profile.
    var oracleModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.oracle",
            getter: { [weak self] in
                self?.profileSnapshot.planningModelRaw ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setOracleModel(raw: rawValue)
            }
        )
    }

    /// Destination for the Built-in Chat model. Writes `preferredComposeModel`
    /// and, when the sync toggle is on, mirrors to `planningModel` in the
    /// selected global/workspace Agent Models profile.
    var builtinChatModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.builtinChat",
            getter: { [weak self] in
                self?.profileSnapshot.preferredComposeModelRaw ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setBuiltinChatModel(raw: rawValue)
            }
        )
    }

    // MARK: - Oracle / Built-in Chat setters

    func setOracleModel(raw: String) {
        updateSelectedProfile(reason: "agent_models.oracle_model") { profile in
            profile.planningModelRaw = raw
            if profile.syncChatModelWithOracle {
                profile.preferredComposeModelRaw = raw
            }
        }
    }

    func setBuiltinChatModel(raw: String) {
        updateSelectedProfile(reason: "agent_models.builtin_chat_model") { profile in
            profile.preferredComposeModelRaw = raw
            if profile.syncChatModelWithOracle,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.planningModelRaw = raw
            }
        }
    }

    // MARK: - Copy Actions

    func copyGlobalSettingsToWorkspaceOverrides() {
        guard let workspaceID else { return }
        settingsManager.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.copy_global_to_workspace")
    }

    func copyWorkspaceSettingsToGlobal() {
        guard let workspaceID else { return }
        settingsManager.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.copy_workspace_to_global")
    }

    // MARK: - Row-level Apply

    func applyOracleRecommendation() {
        guard workspaceID != nil,
              let rec = recommendations.chatModel,
              let recommendedModelRaw = engine.recommendedChatModelRaw(rec, backend: rec.defaultBackend)
        else {
            return
        }

        updateSelectedProfile(reason: "agent_models.apply_oracle_recommendation") { profile in
            profile.planningModelRaw = recommendedModelRaw
            profile.preferredComposeModelRaw = recommendedModelRaw
        }
        postRecommendationsDidApply(reason: "agent_models.apply_oracle_recommendation")
    }

    func applyContextBuilderRecommendation() {
        guard let rec = recommendations.contextBuilder,
              workspaceID != nil else { return }
        let recommendedModelRaw = engine.recommendedContextBuilderModelRaw(rec)
        updateSelectedProfile(
            reason: "agent_models.apply_context_builder_recommendation",
            contextBuilderWriteIntent: .userInitiated
        ) { profile in
            profile.contextBuilderAgentRaw = rec.recommendedAgent.rawValue
            profile = profile.replacingContextBuilderModel(recommendedModelRaw, for: rec.recommendedAgent.rawValue)
        }
        postRecommendationsDidApply(reason: "agent_models.apply_context_builder_recommendation")
    }

    func applyRoleDefault(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) {
        var overrides = profileSnapshot.mcpAgentRoleOverrides ?? [:]
        overrides.removeValue(forKey: resolution.role.rawValue)
        persistRoleDefaultOverrides(overrides.isEmpty ? nil : overrides)
    }

    func resetAllRoleDefaults() {
        persistRoleDefaultOverrides(nil)
    }

    func setRoleDefaultSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind
    ) {
        var overrides = profileSnapshot.mcpAgentRoleOverrides ?? [:]
        let selectionID = AgentModelSelectionID(
            agentRaw: selection.agent.rawValue,
            modelRaw: selection.modelRaw
        )
        // Keep explicit role picks durable even when they currently match the recommendation;
        // `applyRoleDefault` / reset actions are the explicit path back to recommendation-tracking.
        overrides[role.rawValue] = selectionID.rawValue
        persistRoleDefaultOverrides(overrides)
    }

    // MARK: - Bulk Apply

    func applyAllRecommendations(includePresetExposure: Bool = false) {
        guard showsRecommendationActions else { return }
        guard workspaceID != nil else { return }
        isApplyingAll = true

        var profile = profileSnapshot
        var didMutateProfile = false
        if let chat = recommendations.chatModel,
           let recommendedModelRaw = engine.recommendedChatModelRaw(chat, backend: chat.defaultBackend)
        {
            profile.planningModelRaw = recommendedModelRaw
            profile.preferredComposeModelRaw = recommendedModelRaw
            didMutateProfile = true
        }
        if let cb = recommendations.contextBuilder {
            let recommendedModelRaw = engine.recommendedContextBuilderModelRaw(cb)
            profile.contextBuilderAgentRaw = cb.recommendedAgent.rawValue
            profile = profile.replacingContextBuilderModel(recommendedModelRaw, for: cb.recommendedAgent.rawValue)
            didMutateProfile = true
        }
        if recommendations.mcpAgentDefaults != nil {
            profile.mcpAgentRoleOverrides = nil
            didMutateProfile = true
        }
        if didMutateProfile {
            persistSelectedProfile(
                profile,
                reason: "agent_models.apply_all_recommendations",
                contextBuilderWriteIntent: recommendations.contextBuilder == nil
                    ? .preserveExistingOwnership
                    : .userInitiated
            )
        }
        if includePresetExposure, let presetExposure = recommendations.mcpPresetExposure {
            engine.applyMCPPresetExposure(presetExposure)
        }
        if !didMutateProfile {
            reloadScopedState()
            refresh()
        }
        postRecommendationsDidApply(reason: "agent_models.apply_all_recommendations")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isApplyingAll = false
        }
    }

    // MARK: - Context Builder Menu

    func contextBuilderAgentModelMenuItems(windowID: Int) -> [StableMenuItem] {
        let selection = selectedContextBuilderSelection
        var items = AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: selection.agent,
                selectedModelRaw: selection.modelRaw
            ) { [weak self] selectedAgent, selectedOption in
                self?.setContextBuilderSelection(agent: selectedAgent, modelRaw: selectedOption.rawValue)
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: AgentModelCatalog.selectableAgents(availability: availability)
        )
        return items
    }

    func roleDefaultMenuItems(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> [StableMenuItem] {
        AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: resolution.effective.agent,
                selectedModelRaw: resolution.effective.modelRaw,
                includePlaceholderDefault: false,
                flattenSingleCodexGroups: true,
                groupOpenCode: false
            ) { [weak self] selectedAgent, selectedOption in
                guard let self else { return }
                let selection = AgentModelCatalog.NormalizedAgentSelection(
                    agent: selectedAgent,
                    modelRaw: selectedOption.rawValue
                )
                setRoleDefaultSelection(selection, for: resolution.role)
            }
        }
    }

    // MARK: - Private helpers

    private static func inheritanceMode(
        settingsManager: any SettingsManaging,
        workspaceID: UUID?
    ) -> AgentModelsInheritanceMode {
        guard let workspaceID else { return .useGlobalSettings }
        return settingsManager.workspaceAgentModelsSettings(for: workspaceID).inheritanceMode
    }

    private static func profile(
        settingsManager: any SettingsManaging,
        workspaceID: UUID?,
        inheritanceMode: AgentModelsInheritanceMode
    ) -> AgentModelsSettingsProfile {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else {
            return settingsManager.globalAgentModelsProfile()
        }
        return settingsManager.workspaceAgentModelsProfile(for: workspaceID)
            ?? settingsManager.effectiveAgentModelsProfile(workspaceID: workspaceID)
    }

    private func observeNotifications() {
        notificationCenter.publisher(for: .recommendationsShouldRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadScopedState()
                self?.refresh()
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .agentModelsSettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAgentModelsSettingsDidChange(notification)
            }
            .store(in: &cancellables)
    }

    private func handleAgentModelsSettingsDidChange(_ notification: Notification) {
        let scopeRaw = notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
        let workspaceID = notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
        if scopeRaw == AgentModelsSettingsNotification.Scope.workspace.rawValue,
           workspaceID != self.workspaceID
        {
            return
        }
        reloadScopedState()
        refresh()
    }

    private func reloadScopedState() {
        let nextInheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let nextProfile = Self.profile(
            settingsManager: settingsManager,
            workspaceID: workspaceID,
            inheritanceMode: nextInheritanceMode
        )
        isReloadingScopedState = true
        inheritanceMode = nextInheritanceMode
        profileSnapshot = nextProfile
        syncChatWithOracle = nextProfile.syncChatModelWithOracle
        restrictMCPAgentDiscoveryToRoleLabels = nextProfile.restrictMCPAgentDiscoveryToRoleLabels
        isReloadingScopedState = false
    }

    private func updateSelectedProfile(
        reason: String,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership,
        _ mutation: (inout AgentModelsSettingsProfile) -> Void
    ) {
        var profile = profileSnapshot
        mutation(&profile)
        persistSelectedProfile(
            profile,
            reason: reason,
            contextBuilderWriteIntent: contextBuilderWriteIntent
        )
    }

    private func persistSelectedProfile(
        _ profile: AgentModelsSettingsProfile,
        reason: String,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership
    ) {
        switch editingScope {
        case .global:
            settingsManager.setGlobalAgentModelsProfile(
                profile,
                contextBuilderWriteIntent: contextBuilderWriteIntent
            )
        case let .workspace(workspaceID):
            settingsManager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
        }
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: reason)
    }

    private func persistRoleDefaultOverrides(_ overrides: [String: String]?) {
        updateSelectedProfile(reason: "agent_models.role_defaults") { profile in
            profile.mcpAgentRoleOverrides = overrides
        }
        postAgentRoleDefaultsChanged()
    }

    private func setContextBuilderSelection(agent: AgentProviderKind, modelRaw: String) {
        updateSelectedProfile(
            reason: "agent_models.context_builder",
            contextBuilderWriteIntent: .userInitiated
        ) { profile in
            profile.contextBuilderAgentRaw = agent.rawValue
            profile = profile.replacingContextBuilderModel(modelRaw, for: agent.rawValue)
        }
    }

    private func postShouldRefresh(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var userInfo: [String: Any] = ["reason": reason]
            if let workspaceID {
                userInfo["workspaceID"] = workspaceID
            }
            notificationCenter.post(
                name: .recommendationsShouldRefresh,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func postRecommendationsDidApply(reason: String) {
        var userInfo: [String: Any] = [
            "reason": reason,
            AgentModelsSettingsNotification.scopeKey: isEditingWorkspaceSettings
                ? AgentModelsSettingsNotification.Scope.workspace.rawValue
                : AgentModelsSettingsNotification.Scope.global.rawValue
        ]
        if case let .workspace(workspaceID) = editingScope {
            userInfo["workspaceID"] = workspaceID
        }
        if let workspaceID {
            userInfo["sourceWorkspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsDidApply,
            object: nil,
            userInfo: userInfo
        )
    }

    private func postAgentRoleDefaultsChanged() {
        var userInfo: [String: Any] = [
            "reason": "agentRoleDefaultsChanged",
            "scope": isEditingWorkspaceSettings ? "workspace" : "global"
        ]
        if let workspaceID {
            userInfo["workspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: userInfo
        )
        refresh()
    }

    private func displayName(forChatModelRaw raw: String?, fallback: String) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return fallback
        }
        return AIModel.fromModelName(raw)?.displayName ?? raw
    }
}
