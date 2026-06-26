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
//  Planning Model, sync toggle, Context Builder drift
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
    // MARK: - Types

    /// Drift between the Context Builder configuration persisted globally
    /// (used by MCP runs) and the legacy workspace-scoped fields (used by UI
    /// runs today for backwards compatibility).
    ///
    /// The Agent Models page surfaces this as a small resolver when the two
    /// disagree so a user doesn't have one value silently winning. Extension
    /// B Phase 3 is expected to collapse Context Builder to a single picker;
    /// until then, the resolver keeps the storage in sync.
    struct ContextBuilderDrift: Equatable {
        let globalAgentRaw: String?
        let globalModelRaw: String?
        let workspaceAgentRaw: String?
        let workspaceModelRaw: String?
        let globalDescription: String
        let workspaceDescription: String
    }

    // MARK: - Dependencies

    let promptVM: PromptViewModel
    let contextBuilderVM: ContextBuilderAgentViewModel
    let apiSettingsVM: APISettingsViewModel
    let settingsStore: GlobalSettingsStore
    private let notificationCenter: NotificationCenter
    private let engine: AutoRecommendationEngine

    // MARK: - Published state

    @Published private(set) var recommendations: RecommendationSet = .init()
    @Published private(set) var contextBuilderDrift: ContextBuilderDrift? = nil
    @Published private(set) var isApplyingAll: Bool = false
    @Published var syncChatWithOracle: Bool {
        didSet {
            guard oldValue != syncChatWithOracle else { return }
            settingsStore.setSyncChatModelWithOracle(syncChatWithOracle, reason: "agent_models.sync_toggle")
            // If turning sync on, mirror Oracle → Built-in Chat so the two agree going forward.
            if syncChatWithOracle {
                let planningRaw = promptVM.planningModelName
                if !planningRaw.isEmpty, planningRaw != promptVM.preferredModel {
                    promptVM.preferredModel = planningRaw
                }
            }
            refresh()
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
            guard oldValue != restrictMCPAgentDiscoveryToRoleLabels else { return }
            settingsStore.setRestrictMCPAgentDiscoveryToRoleLabels(restrictMCPAgentDiscoveryToRoleLabels)
        }
    }

    // MARK: - Bookkeeping

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        promptVM: PromptViewModel,
        contextBuilderVM: ContextBuilderAgentViewModel,
        apiSettingsVM: APISettingsViewModel,
        settingsStore: GlobalSettingsStore? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        self.promptVM = promptVM
        self.contextBuilderVM = contextBuilderVM
        self.apiSettingsVM = apiSettingsVM
        self.settingsStore = settingsStore
        _ = defaults // Retained for initializer compatibility while storage lives in GlobalSettingsStore.
        self.notificationCenter = notificationCenter
        engine = AutoRecommendationEngine(
            settingsStore: settingsStore,
            apiSettingsViewModel: apiSettingsVM
        )
        syncChatWithOracle = settingsStore.syncChatModelWithOracle()
        restrictMCPAgentDiscoveryToRoleLabels = settingsStore.restrictMCPAgentDiscoveryToRoleLabels()

        observeNotifications()
        refresh()
    }

    // MARK: - Public Derived Values

    var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    var hasConnectedCLIProvider: Bool {
        !AgentModelCatalog.selectableAgents(availability: availability).isEmpty
    }

    var currentOracleModelName: String {
        promptVM.planningModel.displayName
    }

    var currentBuiltinChatModelName: String {
        promptVM.preferredAIModel.displayName
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
        MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            settingsStore: settingsStore
        )
    }

    var roleDefaultsHasOverrides: Bool {
        roleDefaultsResolutions.contains(where: \.hasCustomOverride)
    }

    var hasUnsatisfiedRecommendations: Bool {
        recommendations.hasUnsatisfied || contextBuilderDrift != nil
    }

    // MARK: - Refresh

    /// Recompute the recommendation set and drift state.
    func refresh() {
        guard let workspaceID = promptVM.currentWorkspaceID else {
            recommendations = RecommendationSet()
            contextBuilderDrift = nil
            return
        }
        let raw = engine.computeRecommendations(for: workspaceID)
        recommendations = engine.applyMutedFlags(raw, workspaceID: workspaceID)
        contextBuilderDrift = computeContextBuilderDrift(workspaceID: workspaceID)
    }

    // MARK: - Destinations

    /// Destination for the Oracle model. Writes `planningModel` and, when the
    /// sync toggle is on, mirrors to `preferredComposeModel`.
    var oracleModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.oracle",
            getter: { [weak self] in
                self?.promptVM.planningModelName ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setOracleModel(raw: rawValue)
            }
        )
    }

    /// Destination for the Built-in Chat model. Writes `preferredComposeModel`
    /// and, when the sync toggle is on, mirrors to `planningModel`.
    var builtinChatModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.builtinChat",
            getter: { [weak self] in
                self?.promptVM.preferredModel ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setBuiltinChatModel(raw: rawValue)
            }
        )
    }

    // MARK: - Oracle / Built-in Chat setters

    func setOracleModel(raw: String) {
        promptVM.planningModelName = raw
        postShouldRefresh()
    }

    func setBuiltinChatModel(raw: String) {
        promptVM.preferredModel = raw
        postShouldRefresh()
    }

    // MARK: - Row-level Apply

    func applyOracleRecommendation() {
        guard let rec = recommendations.chatModel else { return }
        let backend = rec.defaultBackend
        guard let option = rec.option(for: backend), let model = option.modelString, !model.isEmpty else {
            return
        }
        setOracleModel(raw: model)
    }

    func applyContextBuilderRecommendation() {
        guard let rec = recommendations.contextBuilder,
              let workspaceID = promptVM.currentWorkspaceID else { return }
        engine.applyContextBuilderRecommendation(rec, workspaceID: workspaceID)
        // Drift is automatically resolved by applyContextBuilderRecommendation
        // because it writes both the global selection and the legacy workspace fields.
        notificationCenter.post(
            name: .recommendationsDidApply,
            object: nil,
            userInfo: ["workspaceID": workspaceID]
        )
    }

    func applyRoleDefault(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) {
        MCPAgentRoleDefaultsService.clearOverride(
            for: resolution.role,
            settingsStore: settingsStore
        )
        postAgentRoleDefaultsChanged()
    }

    func resetAllRoleDefaults() {
        MCPAgentRoleDefaultsService.clearAllOverrides(settingsStore: settingsStore)
        postAgentRoleDefaultsChanged()
    }

    func setRoleDefaultSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind
    ) {
        _ = MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: role,
            settingsStore: settingsStore
        )
        postAgentRoleDefaultsChanged()
    }

    // MARK: - Bulk Apply

    func applyAllRecommendations(includePresetExposure: Bool = false) {
        guard let workspaceID = promptVM.currentWorkspaceID else { return }
        isApplyingAll = true
        engine.applyModelRecommendations(
            recommendations,
            workspaceID: workspaceID,
            includePresetExposure: includePresetExposure
        )
        // Resolve any CB drift by snapping the workspace legacy fields to the
        // freshly applied global selection.
        snapWorkspaceLegacyContextBuilderToGlobal(workspaceID: workspaceID)
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isApplyingAll = false
        }
    }

    // MARK: - Context Builder Drift

    /// Resolve drift by snapping the workspace legacy fields to match the global
    /// Context Builder selection. MCP already uses global; UI runs will, too.
    func resolveContextBuilderDriftUsingGlobal() {
        guard let drift = contextBuilderDrift,
              let workspaceID = promptVM.currentWorkspaceID else { return }
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.contextBuilderAgentRaw = drift.globalAgentRaw
        settings.contextBuilderAgentModelRaw = drift.globalModelRaw
        settings.didUserSetContextBuilderDefaults = true
        settingsStore.updateChatSettings(settings, commit: true)
        promptVM.commitContextBuilderSettings()
        refresh()
    }

    /// Resolve drift by promoting the workspace legacy Context Builder selection
    /// to the global selection so MCP and UI runs agree.
    func resolveContextBuilderDriftUsingWorkspace() {
        guard let drift = contextBuilderDrift,
              let agentRaw = drift.workspaceAgentRaw,
              let workspaceID = promptVM.currentWorkspaceID else { return }
        let modelRaw = drift.workspaceModelRaw ?? drift.globalModelRaw ?? ""
        settingsStore.setGlobalContextBuilderAgentSelection(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            markUserDefined: true
        )
        // Also mirror workspace-scoped fields so they're marked as user-defined.
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.contextBuilderAgentRaw = agentRaw
        settings.contextBuilderAgentModelRaw = modelRaw
        settings.didUserSetContextBuilderDefaults = true
        settingsStore.updateChatSettings(settings, commit: true)
        promptVM.commitContextBuilderSettings()
        refresh()
    }

    // MARK: - Context Builder Menu

    func contextBuilderAgentModelMenuItems(windowID: Int) -> [StableMenuItem] {
        var items = promptVM.availableAgentKinds.map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: promptVM.contextBuilderModelOptions(for: agent),
                selectedAgent: promptVM.contextBuilderAgent,
                selectedModelRaw: promptVM.contextBuilderAgentModelRaw
            ) { [weak self] selectedAgent, selectedOption in
                guard let self else { return }
                promptVM.contextBuilderAgent = selectedAgent
                promptVM.selectContextBuilderAgentModel(rawModel: selectedOption.rawValue)
                promptVM.commitContextBuilderSettings()
                refresh()
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: promptVM.availableAgentKinds
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

    private func observeNotifications() {
        notificationCenter.publisher(for: .recommendationsShouldRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func postShouldRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.notificationCenter.post(name: .recommendationsShouldRefresh, object: nil)
        }
    }

    private func postAgentRoleDefaultsChanged() {
        var userInfo: [String: Any] = [
            "reason": "agentRoleDefaultsChanged",
            "scope": "global"
        ]
        if let workspaceID = promptVM.currentWorkspaceID {
            userInfo["workspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: userInfo
        )
        refresh()
    }

    private func computeContextBuilderDrift(workspaceID: UUID) -> ContextBuilderDrift? {
        let (globalAgentRaw, globalModelRaw) = settingsStore.globalContextBuilderAgentSelection()
        let settings = settingsStore.chatSettings(for: workspaceID)
        let workspaceAgentRaw = settings.contextBuilderAgentRaw
        let workspaceModelRaw = settings.contextBuilderAgentModelRaw

        // Drift is only meaningful when both scopes hold a value — otherwise
        // the workspace is simply delegating to the global default.
        guard let workspaceAgentRaw,
              let globalAgentRaw
        else {
            return nil
        }
        let modelsDiffer: Bool = {
            let g = globalModelRaw ?? ""
            let w = workspaceModelRaw ?? ""
            return g.caseInsensitiveCompare(w) != .orderedSame
        }()
        let agentsDiffer = workspaceAgentRaw.caseInsensitiveCompare(globalAgentRaw) != .orderedSame
        guard agentsDiffer || modelsDiffer else { return nil }

        return ContextBuilderDrift(
            globalAgentRaw: globalAgentRaw,
            globalModelRaw: globalModelRaw,
            workspaceAgentRaw: workspaceAgentRaw,
            workspaceModelRaw: workspaceModelRaw,
            globalDescription: describeSelection(agentRaw: globalAgentRaw, modelRaw: globalModelRaw),
            workspaceDescription: describeSelection(agentRaw: workspaceAgentRaw, modelRaw: workspaceModelRaw)
        )
    }

    private func snapWorkspaceLegacyContextBuilderToGlobal(workspaceID: UUID) {
        let (globalAgentRaw, globalModelRaw) = settingsStore.globalContextBuilderAgentSelection()
        guard let globalAgentRaw else { return }
        var settings = settingsStore.chatSettings(for: workspaceID)
        let needsUpdate =
            settings.contextBuilderAgentRaw != globalAgentRaw ||
            settings.contextBuilderAgentModelRaw != globalModelRaw
        guard needsUpdate else { return }
        settings.contextBuilderAgentRaw = globalAgentRaw
        settings.contextBuilderAgentModelRaw = globalModelRaw
        settings.didUserSetContextBuilderDefaults = true
        settingsStore.updateChatSettings(settings, commit: true)
    }

    private func describeSelection(agentRaw: String?, modelRaw: String?) -> String {
        guard let agentRaw, let agent = AgentProviderKind(rawValue: agentRaw) else {
            return "Not configured"
        }
        let modelDisplay: String = {
            guard let raw = modelRaw, !raw.isEmpty else {
                return AgentModel.defaultModel.displayName
            }
            return AgentModelCatalog.displayName(
                for: raw,
                agentKind: agent,
                availability: availability
            )
        }()
        return "\(agent.displayName) · \(modelDisplay)"
    }
}
