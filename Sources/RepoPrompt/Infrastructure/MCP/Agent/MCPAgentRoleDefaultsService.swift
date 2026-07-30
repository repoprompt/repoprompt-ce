import Foundation

// MARK: - MCP Agent Role Defaults Storage

/// Storage boundary for MCP Agent Mode role defaults.
/// Role defaults resolve from the effective Agent Models profile for a workspace;
/// `nil` workspace IDs resolve and mutate global settings.
@MainActor
protocol MCPAgentRoleDefaultsStoring: AnyObject {
    func mcpAgentRoleOverrides(workspaceID: UUID?) -> [String: String]?
    func mcpAgentRoleOverrides(scope: AgentModelsEditingScope) -> [String: String]?
    func updateMCPAgentRoleOverrides(_ overrides: [String: String]?, scope: AgentModelsEditingScope, commit: Bool)
}

extension GlobalSettingsStore: MCPAgentRoleDefaultsStoring {
    func mcpAgentRoleOverrides(workspaceID: UUID?) -> [String: String]? {
        effectiveAgentModelsProfile(workspaceID: workspaceID).mcpAgentRoleOverrides
    }

    func mcpAgentRoleOverrides(scope: AgentModelsEditingScope) -> [String: String]? {
        switch scope {
        case .global:
            globalAgentModelsProfile().mcpAgentRoleOverrides
        case let .workspace(workspaceID):
            workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides
        }
    }

    func updateMCPAgentRoleOverrides(_ overrides: [String: String]?, scope: AgentModelsEditingScope, commit _: Bool) {
        setAgentModelsMCPAgentRoleOverrides(overrides, scope: scope)
    }
}

@MainActor
final class AgentModelsProfileRoleDefaultsStore: MCPAgentRoleDefaultsStoring {
    private var overrides: [String: String]?

    init(overrides: [String: String]?) {
        self.overrides = overrides
    }

    func mcpAgentRoleOverrides(workspaceID _: UUID?) -> [String: String]? {
        overrides
    }

    func mcpAgentRoleOverrides(scope _: AgentModelsEditingScope) -> [String: String]? {
        overrides
    }

    func updateMCPAgentRoleOverrides(_ overrides: [String: String]?, scope _: AgentModelsEditingScope, commit _: Bool) {
        self.overrides = overrides
    }
}

// MARK: - MCP Agent Role Defaults Service

/// Centralized resolution and persistence for MCP agent role defaults.
/// Used by the recommendation wizard, settings UI, and MCP runtime.
@MainActor
enum MCPAgentRoleDefaultsService {
    // MARK: - Resolution Result

    enum PinState: Equatable {
        case none
        case unavailable
        case custom(recommendedDisplayName: String)
        case pinnedToRecommended

        var message: String? {
            switch self {
            case .none:
                nil
            case .unavailable:
                "Saved pin unavailable; using recommended default."
            case let .custom(recommendedDisplayName):
                "Recommended: \(recommendedDisplayName)"
            case .pinnedToRecommended:
                "Pinned to recommended"
            }
        }

        var actionTitle: String? {
            switch self {
            case .none:
                nil
            case .unavailable, .pinnedToRecommended:
                "Clear Pin"
            case .custom:
                "Apply"
            }
        }

        var usesWarningStyle: Bool {
            switch self {
            case .unavailable, .custom:
                true
            case .none, .pinnedToRecommended:
                false
            }
        }
    }

    struct RoleDefaultResolution: Equatable {
        let role: AgentModelCatalog.TaskLabelKind
        let roleLabel: String
        let roleDescription: String

        /// What the recommendation engine says is best for this role.
        let recommended: AgentModelCatalog.NormalizedAgentSelection
        let recommendedDisplayName: String

        /// What will actually be used at runtime (may differ if user overrode).
        let effective: AgentModelCatalog.NormalizedAgentSelection
        let effectiveDisplayName: String

        /// A persisted override exists for this role, even if it currently matches the recommendation.
        let hasStoredOverride: Bool

        /// The effective selection differs from the current recommendation.
        let hasCustomOverride: Bool
        let overrideUnavailable: Bool

        var selectionID: AgentModelSelectionID {
            AgentModelSelectionID(agentRaw: effective.agent.rawValue, modelRaw: effective.modelRaw)
        }

        var pinState: PinState {
            guard hasStoredOverride else { return .none }
            if overrideUnavailable {
                return .unavailable
            }
            if hasCustomOverride {
                return .custom(recommendedDisplayName: recommendedDisplayName)
            }
            return .pinnedToRecommended
        }
    }

    // MARK: - Resolve All

    static func hasStoredOverrides(
        workspaceID: UUID? = nil,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) -> Bool {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        return settingsStore.mcpAgentRoleOverrides(workspaceID: workspaceID)?.isEmpty == false
    }

    /// Returns resolutions for all task label roles in canonical order.
    static func resolutions(
        availability: AgentModelCatalog.AvailabilityContext = .current,
        recommendedAvailability: AgentModelCatalog.AvailabilityContext? = nil,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        workspaceID: UUID? = nil,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) -> [RoleDefaultResolution] {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let overrides = settingsStore.mcpAgentRoleOverrides(workspaceID: workspaceID)
        let recommendationAvailability = recommendedAvailability ?? defaultRecommendedAvailability(from: availability, settingsStore: settingsStore)
        return AgentModelCatalog.TaskLabelKind.allCases.compactMap { kind in
            resolve(
                kind: kind,
                overrides: overrides,
                availability: availability,
                recommendedAvailability: recommendationAvailability,
                codexDynamicModels: codexDynamicModels
            )
        }
    }

    /// Resolve one role's effective selection.
    static func effectiveSelection(
        for role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        recommendedAvailability: AgentModelCatalog.AvailabilityContext? = nil,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        workspaceID: UUID? = nil,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) -> RoleDefaultResolution? {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let overrides = settingsStore.mcpAgentRoleOverrides(workspaceID: workspaceID)
        return resolve(
            kind: role,
            overrides: overrides,
            availability: availability,
            recommendedAvailability: recommendedAvailability ?? defaultRecommendedAvailability(from: availability, settingsStore: settingsStore),
            codexDynamicModels: codexDynamicModels
        )
    }

    /// Resolve just the effective normalized selection for runtime role-label resolution.
    static func effectiveNormalizedSelection(
        for role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        workspaceID: UUID? = nil,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) -> AgentModelCatalog.NormalizedAgentSelection? {
        effectiveSelection(
            for: role,
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: settingsStore
        )?.effective
    }

    // MARK: - Mutations

    /// Set a user-selected override for a role. An explicit selection is always
    /// persisted; revert a role to the (recommendation-tracking) default via
    /// `clearOverride` / `clearAllOverrides`.
    @discardableResult
    static func setSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind,
        availability _: AgentModelCatalog.AvailabilityContext = .current,
        scope: AgentModelsEditingScope,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) -> Bool {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let selectionID = AgentModelSelectionID(agentRaw: selection.agent.rawValue, modelRaw: selection.modelRaw)
        var overrides = settingsStore.mcpAgentRoleOverrides(scope: scope) ?? [:]
        // An explicit role pick is a durable choice. Do NOT erase it just because it
        // currently equals a transient, availability-dependent recommendation — doing so
        // dropped the override and the role silently drifted to a different model after
        // restart or availability change. Reverting to the recommended default stays an
        // explicit action via clearOverride / clearAllOverrides.
        overrides[role.rawValue] = selectionID.rawValue
        settingsStore.updateMCPAgentRoleOverrides(overrides, scope: scope, commit: true)
        return true
    }

    /// Clear one role's override.
    static func clearOverride(
        for role: AgentModelCatalog.TaskLabelKind,
        scope: AgentModelsEditingScope,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        var overrides = settingsStore.mcpAgentRoleOverrides(scope: scope) ?? [:]
        overrides.removeValue(forKey: role.rawValue)
        settingsStore.updateMCPAgentRoleOverrides(overrides.isEmpty ? nil : overrides, scope: scope, commit: true)
    }

    /// Clear all role overrides (revert to recommended defaults).
    static func clearAllOverrides(
        scope: AgentModelsEditingScope,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        settingsStore.updateMCPAgentRoleOverrides(nil, scope: scope, commit: true)
    }

    // MARK: - Private

    private static func defaultRecommendedAvailability(
        from availability: AgentModelCatalog.AvailabilityContext,
        settingsStore: any MCPAgentRoleDefaultsStoring
    ) -> AgentModelCatalog.AvailabilityContext {
        guard let globalStore = settingsStore as? GlobalSettingsStore else {
            return availability
        }
        return availability.filteredForRecommendationProviders(globalStore.globalRecommendationProviderFilter())
    }

    private static func resolve(
        kind: AgentModelCatalog.TaskLabelKind,
        overrides: [String: String]?,
        availability: AgentModelCatalog.AvailabilityContext,
        recommendedAvailability: AgentModelCatalog.AvailabilityContext,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]?
    ) -> RoleDefaultResolution? {
        guard let taskLabel = AgentModelCatalog.taskLabel(for: kind) else { return nil }
        guard let recommended = resolvedRecommendedSelection(
            for: kind,
            recommendedAvailability: recommendedAvailability,
            fallbackAvailability: availability
        ) else {
            return nil
        }

        let recommendedDisplayName = "\(recommended.agent.displayName) \(AgentModelCatalog.displayName(for: recommended.modelRaw, agentKind: recommended.agent, codexDynamicModels: codexDynamicModels))"

        // Check for stored override
        let hasStoredOverride = overrides?[kind.rawValue] != nil
        let effective: AgentModelCatalog.NormalizedAgentSelection
        var hasCustomOverride = false
        var overrideUnavailable = false

        if let overrideRaw = overrides?[kind.rawValue],
           let parsed = AgentModelSelectionID.parse(overrideRaw),
           let agent = AgentProviderKind(rawValue: parsed.agentRaw)
        {
            // Codex may have dynamic model IDs, so defer its model-level validation. Other
            // providers must still expose the stored model or the stale pin is non-executable.
            let modelIsExecutable = agent == .codexExec
                || AgentModelCatalog.isValid(rawModel: parsed.modelRaw, for: agent, availability: availability)
            if AgentModelCatalog.isAgentAvailable(agent, availability: availability), modelIsExecutable {
                let sel = AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: parsed.modelRaw)
                effective = sel
                hasCustomOverride = (sel != recommended)
            } else {
                effective = recommended
                hasCustomOverride = true
                overrideUnavailable = true
            }
        } else {
            effective = recommended
            if overrides?[kind.rawValue] != nil {
                hasCustomOverride = true
                overrideUnavailable = true
            }
        }

        let effectiveDisplayName = "\(effective.agent.displayName) \(AgentModelCatalog.displayName(for: effective.modelRaw, agentKind: effective.agent, codexDynamicModels: codexDynamicModels))"

        return RoleDefaultResolution(
            role: kind,
            roleLabel: taskLabel.label,
            roleDescription: taskLabel.description,
            recommended: recommended,
            recommendedDisplayName: recommendedDisplayName,
            effective: effective,
            effectiveDisplayName: effectiveDisplayName,
            hasStoredOverride: hasStoredOverride,
            hasCustomOverride: hasCustomOverride,
            overrideUnavailable: overrideUnavailable
        )
    }

    private static func resolvedRecommendedSelection(
        for role: AgentModelCatalog.TaskLabelKind,
        recommendedAvailability: AgentModelCatalog.AvailabilityContext,
        fallbackAvailability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelCatalog.NormalizedAgentSelection? {
        // Recommendation filters pick the preferred default when possible, but they should not hide
        // role rows when the app still has selectable agents outside the filtered recommendation set.
        AgentModelCatalog.resolveTaskLabelKind(role, availability: recommendedAvailability)
            ?? AgentModelCatalog.resolveTaskLabelKind(role, availability: fallbackAvailability)
    }
}
