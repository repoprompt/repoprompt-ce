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
import OSLog
import RepoPromptDomainRuntime
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
                let planningModelRaw = profile.planningModelRaw?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let canEnableSync = planningModelRaw?.isEmpty == false
                profile.syncChatModelWithOracle = syncChatWithOracle && canEnableSync
                if profile.syncChatModelWithOracle,
                   profile.preferredComposeModelRaw != profile.planningModelRaw
                {
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

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "AgentModelsSettings")

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
        let initial = Self.liveScopedState(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let initialProfile = initial.profile

        self.apiSettingsVM = apiSettingsVM
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        inheritanceMode = initial.inheritanceMode
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
        AgentModelsEditingScope.resolve(
            workspaceID: workspaceID,
            inheritanceMode: inheritanceMode
        )
    }

    var isEditingWorkspaceSettings: Bool {
        if case .workspace = editingScope {
            return true
        }
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

    var additionalOracleModelRaws: [String] {
        profileSnapshot.additionalOracleModelRaws
    }

    var oracleCount: Int {
        1 + additionalOracleModelRaws.count
    }

    var canAddOracle: Bool {
        let primary = profileSnapshot.planningModelRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false && oracleCount < OracleRosterContract.maximumCount
    }

    func oracleLabel(at index: Int) -> String {
        OracleRosterContract.displayLabel(laneIndex: index)
    }

    func oracleModelName(at index: Int) -> String {
        let raw = index == 0
            ? profileSnapshot.planningModelRaw
            : additionalOracleModelRaws.indices.contains(index - 1)
            ? additionalOracleModelRaws[index - 1]
            : nil
        return displayName(forChatModelRaw: raw, fallback: "Select an Oracle model")
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
        let profileStore = AgentModelsProfileRoleDefaultsStore(
            overrides: profileSnapshot.mcpAgentRoleOverrides,
            roleModelParameters: profileSnapshot.mcpAgentRoleModelParameters
        )
        return MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            recommendedAvailability: availability.filteredForRecommendationProviders(settingsManager.globalRecommendationProviderFilter()),
            settingsStore: profileStore
        )
    }

    var roleDefaultsHasOverrides: Bool {
        MCPAgentRoleDefaultsService.hasStoredOverrides(
            settingsStore: AgentModelsProfileRoleDefaultsStore(
                overrides: profileSnapshot.mcpAgentRoleOverrides
            )
        )
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

    func additionalOracleModelDestination(at index: Int) -> ModelDestination {
        ModelDestination(
            id: "agentModels.oracle.additional.\(index)",
            getter: { [weak self] in
                guard let self, additionalOracleModelRaws.indices.contains(index) else { return "" }
                return additionalOracleModelRaws[index]
            },
            applier: { [weak self] rawValue in
                self?.setAdditionalOracleModel(raw: rawValue, at: index)
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
            guard profile.syncChatModelWithOracle else { return }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.syncChatModelWithOracle = false
            } else {
                profile.preferredComposeModelRaw = raw
            }
        }
    }

    func addOracle() {
        guard canAddOracle, let primary = profileSnapshot.planningModelRaw else { return }
        updateSelectedProfile(reason: "agent_models.oracle_add") { profile in
            profile.additionalOracleModelRaws.append(primary)
        }
    }

    func removeOracle(at index: Int) {
        guard additionalOracleModelRaws.indices.contains(index) else { return }
        updateSelectedProfile(reason: "agent_models.oracle_remove") { profile in
            profile.additionalOracleModelRaws.remove(at: index)
        }
    }

    func setAdditionalOracleModel(raw: String, at index: Int) {
        guard additionalOracleModelRaws.indices.contains(index) else { return }
        updateSelectedProfile(reason: "agent_models.oracle_model") { profile in
            profile.additionalOracleModelRaws[index] = raw
        }
    }

    func setBuiltinChatModel(raw: String) {
        updateSelectedProfile(reason: "agent_models.builtin_chat_model") { profile in
            profile.preferredComposeModelRaw = raw
            guard profile.syncChatModelWithOracle else { return }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.syncChatModelWithOracle = false
            } else {
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

        let committed = updateSelectedProfile(reason: "agent_models.apply_oracle_recommendation") { profile in
            profile.planningModelRaw = recommendedModelRaw
            profile.preferredComposeModelRaw = recommendedModelRaw
        }
        guard committed else { return }
        postRecommendationsDidApply(reason: "agent_models.apply_oracle_recommendation")
    }

    func applyContextBuilderRecommendation() {
        guard let rec = recommendations.contextBuilder,
              workspaceID != nil else { return }
        let recommendedModelRaw = engine.recommendedContextBuilderModelRaw(rec)
        let committed = updateSelectedProfile(
            reason: "agent_models.apply_context_builder_recommendation",
            contextBuilderWriteIntent: .userInitiated
        ) { profile in
            profile.contextBuilderAgentRaw = rec.recommendedAgent.rawValue
            profile = profile.replacingContextBuilderModel(recommendedModelRaw, for: rec.recommendedAgent.rawValue)
        }
        guard committed else { return }
        postRecommendationsDidApply(reason: "agent_models.apply_context_builder_recommendation")
    }

    func applyRoleDefault(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) {
        updateRoleDefaultOverrides { overrides in
            overrides.removeValue(forKey: resolution.role.rawValue)
        }
    }

    func resetAllRoleDefaults() {
        updateRoleDefaultOverrides { overrides in
            overrides.removeAll()
        }
    }

    /// Set or clear one role's OpenCode effort pin, persisting the displayed role model choice
    /// atomically.
    ///
    /// Guarded write: the captured target (`expectedProviderID`/`expectedModelRaw`/`expectedScope`)
    /// is re-checked against live host state before writing. The discovery key alone is
    /// insufficient — switching Settings global↔workspace leaves the key identical — so a stale
    /// menu click is dropped rather than written to the old scope or a changed model.
    ///
    /// The reload is what makes "live" true. `editingScope` and `profileSnapshot` are refreshed
    /// from a notification delivered asynchronously, so between an external inheritance change
    /// and its delivery this view model's cached view of the scope disagrees with the store that
    /// other surfaces read directly. Writing on that stale scope does not merely land in the
    /// wrong profile: the workspace branch of `updateAgentModelsProfile` sets
    /// `inheritanceMode = .useWorkspaceOverrides`, so a stale click would silently re-enable
    /// workspace overrides and undo the newer inheritance choice.
    func setRoleModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        for role: AgentModelCatalog.TaskLabelKind,
        expectedProviderID: ACPProviderID,
        expectedModelRaw: String,
        expectedScope: AgentModelsEditingScope
    ) {
        reloadScopedState()
        guard editingScope == expectedScope,
              let resolution = roleDefaultsResolutions.first(where: { $0.role == role }),
              resolution.effective.agent.acpProviderID == expectedProviderID,
              ACPModelParameterIdentity.canonicalBaseModelRaw(
                  resolution.effective.modelRaw,
                  providerID: expectedProviderID
              ) == ACPModelParameterIdentity.canonicalBaseModelRaw(
                  expectedModelRaw,
                  providerID: expectedProviderID
              )
        else { return }
        settingsManager.setAgentModelsRoleModelParameter(
            selections,
            roleRawValue: role.rawValue,
            displayedSelectionID: AgentModelSelectionID(
                agentRaw: resolution.effective.agent.rawValue,
                modelRaw: resolution.effective.modelRaw
            ),
            scope: editingScope
        )
        reloadScopedState()
        // `postAgentRoleDefaultsChanged()` already refreshes; calling it here too is dead weight.
        postAgentRoleDefaultsChanged()
    }

    /// Set or clear the Context Builder agent's OpenCode effort pin, persisting the displayed
    /// CB agent+model choice atomically. Guarded like `setRoleModelParameter`: the captured
    /// scope/provider/model must still match live host state.
    func setContextBuilderModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        expectedProviderID: ACPProviderID,
        expectedModelRaw: String,
        expectedScope: AgentModelsEditingScope
    ) {
        // Validate against — and write — the live DISPLAYED selection, which is what the chip is
        // mounted for. The write persists that displayed choice atomically with the pin, so
        // persisted and displayed agree after one click.
        // Same reload-before-guard rule as `setRoleModelParameter`: both the scope and the
        // displayed selection come from cached state that a pending notification has not yet
        // refreshed.
        reloadScopedState()
        let displayed = selectedContextBuilderSelection
        guard editingScope == expectedScope,
              let providerID = displayed.agent.acpProviderID,
              providerID == expectedProviderID,
              ACPModelParameterIdentity.canonicalBaseModelRaw(
                  displayed.modelRaw,
                  providerID: providerID
              ) == ACPModelParameterIdentity.canonicalBaseModelRaw(
                  expectedModelRaw,
                  providerID: providerID
              )
        else { return }
        settingsManager.setAgentModelsContextBuilderModelParameter(
            selections,
            agentRaw: displayed.agent.rawValue,
            modelRaw: displayed.modelRaw,
            scope: editingScope
        )
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.context_builder_model_parameter")
    }

    /// The saved `.thinking` pin value for the current Context Builder selection, if any.
    var contextBuilderThinkingParameterValueRaw: String? {
        contextBuilderModelParameters.last { $0.kind == .thinking }?.valueRaw
    }

    /// The saved Context Builder effort pin for the **displayed** CB selection. Display and probe
    /// must agree with the model the chip is mounted for (availability fallback can make the
    /// displayed choice differ from the persisted one without writing back).
    var contextBuilderModelParameters: [ACPModelParameterSelection] {
        let displayed = selectedContextBuilderSelection
        return profileSnapshot.contextBuilderModelParameterSelections(
            for: displayed.agent,
            modelRaw: displayed.modelRaw
        )
    }

    func setRoleDefaultSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind
    ) {
        let selectionID = AgentModelSelectionID(
            agentRaw: selection.agent.rawValue,
            modelRaw: selection.modelRaw
        )
        // Keep explicit role picks durable even when they currently match the recommendation;
        // `applyRoleDefault` / reset actions are the explicit path back to recommendation-tracking.
        updateRoleDefaultOverrides { overrides in
            overrides[role.rawValue] = selectionID.rawValue
        }
    }

    // MARK: - Bulk Apply

    func applyAllRecommendations(includePresetExposure: Bool = false) {
        guard showsRecommendationActions else { return }
        guard workspaceID != nil else { return }
        isApplyingAll = true

        // Resolve every recommendation up front, then apply them to the live base inside one
        // guarded write. This used to build on `profileSnapshot` and persist directly, which kept
        // the stale-whole-profile bug alive in the one action most likely to be clicked right
        // after another surface wrote a pin.
        let chatModelRaw = recommendations.chatModel.flatMap { chat in
            engine.recommendedChatModelRaw(chat, backend: chat.defaultBackend)
        }
        let contextBuilder = recommendations.contextBuilder
        let contextBuilderModelRaw = contextBuilder.map { engine.recommendedContextBuilderModelRaw($0) }
        let clearsRoleOverrides = recommendations.mcpAgentDefaults != nil
        let mutatesProfile = chatModelRaw != nil || contextBuilder != nil || clearsRoleOverrides

        if mutatesProfile {
            let committed = updateSelectedProfile(
                reason: "agent_models.apply_all_recommendations",
                contextBuilderWriteIntent: contextBuilder == nil
                    ? .preserveExistingOwnership
                    : .userInitiated
            ) { profile in
                if let chatModelRaw {
                    profile.planningModelRaw = chatModelRaw
                    profile.preferredComposeModelRaw = chatModelRaw
                }
                if let contextBuilder, let contextBuilderModelRaw {
                    profile.contextBuilderAgentRaw = contextBuilder.recommendedAgent.rawValue
                    profile = profile.replacingContextBuilderModel(
                        contextBuilderModelRaw,
                        for: contextBuilder.recommendedAgent.rawValue
                    )
                }
                if clearsRoleOverrides {
                    profile.mcpAgentRoleOverrides = nil
                }
            }
            // These recommendations were computed against state that has since moved, so applying
            // part of them would be wrong. The reject path already reloaded and refreshed, which
            // produces a fresh set for the next click.
            guard committed else {
                isApplyingAll = false
                return
            }
        } else {
            reloadScopedState()
            refresh()
        }

        if includePresetExposure, let presetExposure = recommendations.mcpPresetExposure {
            engine.applyMCPPresetExposure(presetExposure)
        }
        postRecommendationsDidApply(reason: "agent_models.apply_all_recommendations")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isApplyingAll = false
        }
    }

    // MARK: - Context Builder Menu

    func contextBuilderAgentModelMenuItems(windowID: Int) -> [StableMenuItem] {
        let selection = selectedContextBuilderSelection
        var items = AgentModelCatalog.selectableAgents(availability: availability, surface: .headless).map { agent in
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
            availableAgents: AgentModelCatalog.selectableAgents(availability: availability, surface: .headless)
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
                flattenSingleCodexGroups: true
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

    /// The store's current scoped state, read as one pair.
    ///
    /// Single owner of the read rule. `init`, `reloadScopedState()` and `updateSelectedProfile`
    /// all go through here, which is what makes the cache-vs-live comparison in
    /// `updateSelectedProfile` meaningful: two different read paths could report a difference
    /// that is not really there and reject every edit.
    private static func liveScopedState(
        settingsManager: any SettingsManaging,
        workspaceID: UUID?
    ) -> (inheritanceMode: AgentModelsInheritanceMode, profile: AgentModelsSettingsProfile) {
        let inheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let profile = Self.profile(
            settingsManager: settingsManager,
            workspaceID: workspaceID,
            inheritanceMode: inheritanceMode
        )
        return (inheritanceMode, profile)
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
        let next = Self.liveScopedState(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let nextProfile = next.profile
        isReloadingScopedState = true
        inheritanceMode = next.inheritanceMode
        profileSnapshot = nextProfile
        syncChatWithOracle = nextProfile.syncChatModelWithOracle
        restrictMCPAgentDiscoveryToRoleLabels = nextProfile.restrictMCPAgentDiscoveryToRoleLabels
        isReloadingScopedState = false
    }

    /// Read-modify-write the selected Agent Models profile — or refuse.
    ///
    /// **Observe live, assign nothing, verify against the cache, then act on one scope — or
    /// reload and refuse.**
    ///
    /// This boundary produced one bug per fix, always the same way: two copies of the same truth
    /// (the notification-fed cache and the store) disagreed, and a write happened anyway.
    /// Mutating the cache lost effort pins written by other surfaces. Mutating the live profile
    /// while writing to the cached `editingScope` copied whole profiles across scopes, because
    /// both setters replace every field. Bounds-checking the cached array while indexing the live
    /// one trapped. Reloading first — the other obvious fix — reassigns the published toggles,
    /// whose `didSet` handlers read the very property they are mutating, so it silently reverts
    /// every toggle edit.
    ///
    /// So divergence is terminal here, not an input to a write. The live scope and profile are
    /// read into locals and compared against the cached pair; only when both agree does the
    /// mutation run, and the write then targets the live-resolved scope. Because the base is
    /// *verified* equal to `profileSnapshot`, every snapshot-derived index, key, count and value
    /// a caller captured is sound by construction — including at call sites not yet written.
    ///
    /// Reading into locals is also what keeps the toggles working: nothing published is assigned
    /// before the closure runs, so a `didSet`-driven mutation still sees the user's new value.
    /// `reloadScopedState()` runs only after the decision — after a write, or instead of one.
    ///
    /// Three ways to restart the bug cycle, all forbidden by this contract:
    /// - retrying a rejected mutation against the refreshed base. "Apply it to whatever is there
    ///   now" is precisely the bug for index- and key-shaped edits;
    /// - introducing an `await` between the live read and the write, reopening the
    ///   time-of-check/time-of-use gap this guard closes;
    /// - adding a whole-profile write path that bypasses this method — which is why the old
    ///   `persistSelectedProfile` was deleted rather than given a scope parameter.
    ///
    /// - Returns: `true` when the profile was written. Callers with follow-up side effects
    ///   (notifications, preset exposure) must gate them on this.
    @discardableResult
    private func updateSelectedProfile(
        reason: String,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership,
        _ mutation: (inout AgentModelsSettingsProfile) -> Void
    ) -> Bool {
        let live = Self.liveScopedState(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let liveScope = AgentModelsEditingScope.resolve(
            workspaceID: workspaceID,
            inheritanceMode: live.inheritanceMode
        )

        let scopeChanged = liveScope != editingScope
        let profileChanged = live.profile != profileSnapshot
        guard !scopeChanged, !profileChanged else {
            // Rejection has to be observable, or "silent wrong write" simply becomes "silent
            // dropped click" and the next person weakens a precondition to fix the symptom.
            Self.logger.notice(
                """
                Rejected stale Agent Models edit \(reason, privacy: .public): \
                scopeChanged=\(scopeChanged, privacy: .public) \
                profileChanged=\(profileChanged, privacy: .public)
                """
            )
            reloadScopedState()
            refresh()
            return false
        }

        var profile = live.profile
        mutation(&profile)

        switch liveScope {
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
        return true
    }

    /// Edit the selected profile's MCP agent role overrides in place.
    ///
    /// The closure receives the *live* dictionary rather than a replacement built from the cache.
    /// A wholesale stale replacement did not merely drop a key: profile coherence discards any
    /// effort pin whose role override disappears, so an unrelated role menu click could silently
    /// erase a pin written by the role-defaults popover.
    @discardableResult
    private func updateRoleDefaultOverrides(_ edit: (inout [String: String]) -> Void) -> Bool {
        let committed = updateSelectedProfile(reason: "agent_models.role_defaults") { profile in
            var overrides = profile.mcpAgentRoleOverrides ?? [:]
            edit(&overrides)
            profile.mcpAgentRoleOverrides = overrides.isEmpty ? nil : overrides
        }
        if committed {
            postAgentRoleDefaultsChanged()
        }
        return committed
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
        var userInfo = AgentModelsSettingsNotification.userInfo(
            scope: editingScope,
            sourceWorkspaceID: workspaceID
        )
        userInfo["reason"] = reason
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
