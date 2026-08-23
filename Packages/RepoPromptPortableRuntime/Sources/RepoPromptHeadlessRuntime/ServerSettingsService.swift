import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptShared

public protocol ServerSettingsProviderCatalogProviding: Sendable {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse
}

public protocol ServerSettingsProjectCatalogProviding: Sendable {
    func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID>
}

public actor ServerSettingsService {
    public static let recommendationProfileVersion = "202_608"

    private let store: any RepoPromptAuthorityStore
    private let providerCatalog: any ServerSettingsProviderCatalogProviding
    private let projectCatalog: any ServerSettingsProjectCatalogProviding
    private let now: @Sendable () -> Date

    public init(
        store: any RepoPromptAuthorityStore,
        providerCatalog: any ServerSettingsProviderCatalogProviding,
        projectCatalog: any ServerSettingsProjectCatalogProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.providerCatalog = providerCatalog
        self.projectCatalog = projectCatalog
        self.now = now
    }

    public func agentModels(projectID: UUID? = nil) async throws -> AgentModelsSettingsSnapshot {
        if let projectID { _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID) }
        let global = try await store.agentModelsDocument(scopeID: "global")
        let globalProfile = global?.value.profile ?? .default
        let project: StoredSettingsDocument<AgentModelsScopeDocument>? = if let projectID {
            try await store.agentModelsDocument(scopeID: scopeID(projectID))
        } else {
            nil
        }
        let projectMode = project?.value.mode ?? .inheritGlobal
        let projectProfile = project?.value.profile
        let effective = projectMode == .projectOverride ? (projectProfile ?? globalProfile) : globalProfile
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        return AgentModelsSettingsSnapshot(
            globalProfile: globalProfile,
            globalRevision: global?.revision ?? 0,
            projectID: projectID,
            projectMode: projectMode,
            projectProfile: projectProfile,
            projectRevision: project?.revision ?? 0,
            effectiveProfile: effective,
            recommendationProfileVersion: Self.recommendationProfileVersion,
            recommendations: recommendationRows(catalog: catalog),
            updatedAt: max(global?.updatedAt ?? epoch, project?.updatedAt ?? epoch)
        )
    }

    public func replaceGlobalAgentModels(
        _ request: ReplaceGlobalAgentModelsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let profile = try normalize(request.profile, catalog: catalog)
        let value = AgentModelsScopeDocument(mode: .inheritGlobal, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: "global",
            projectID: nil,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: value)
        )
        return try await agentModels()
    }

    public func replaceProjectAgentModels(
        projectID: UUID,
        request: ReplaceProjectAgentModelsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let current = try await store.agentModelsDocument(scopeID: scopeID(projectID))
        let global = try await store.agentModelsDocument(scopeID: "global")
        let value = try normalizeProjectAgentModels(
            mode: request.mode,
            profile: request.profile,
            storedProfile: current?.value.profile,
            globalProfile: global?.value.profile ?? .default,
            catalog: catalog
        )
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceProject", attribution: attribution, payload: value)
        )
        return try await agentModels(projectID: projectID)
    }

    public func copyGlobalAgentModelsToProject(
        projectID: UUID,
        request: CopyGlobalAgentModelsToProjectRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let global = try await store.agentModelsDocument(scopeID: "global")
        let observedGlobalRevision = global?.revision ?? 0
        guard observedGlobalRevision == request.expectedGlobalRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Agent Models revision is stale", currentRevision: observedGlobalRevision)
        }
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let profile = try normalize(global?.value.profile ?? .default, catalog: catalog)
        let value = AgentModelsScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedProjectRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedProjectRevision,
            expectedGlobalRevision: request.expectedGlobalRevision,
            audit: audit(operation: "copyGlobal", attribution: attribution, payload: value)
        )
        return try await agentModels(projectID: projectID)
    }

    public func copyProjectAgentModelsToGlobal(
        projectID: UUID,
        request: CopyProjectAgentModelsToGlobalRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let project = try await store.agentModelsDocument(scopeID: scopeID(projectID))
        let observedProjectRevision = project?.revision ?? 0
        guard observedProjectRevision == request.expectedProjectRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project Agent Models revision is stale", currentRevision: observedProjectRevision)
        }
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let global = try await store.agentModelsDocument(scopeID: "global")
        let profile = try normalize(project?.value.profile ?? global?.value.profile ?? .default, catalog: catalog)
        let value = AgentModelsScopeDocument(mode: .inheritGlobal, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedGlobalRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: "global",
            projectID: nil,
            expectedRevision: request.expectedGlobalRevision,
            expectedSourceScopeID: scopeID(projectID),
            expectedSourceRevision: request.expectedProjectRevision,
            audit: audit(operation: "copyProject", attribution: attribution, payload: value)
        )
        return try await agentModels(projectID: projectID)
    }

    public func applyGlobalAgentModelRecommendations(
        _ request: ApplyAgentModelRecommendationsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let current = try await agentModels()
        guard current.globalRevision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Agent Models revision is stale", currentRevision: current.globalRevision)
        }
        let profile = applying(current.recommendations, to: current.globalProfile)
        return try await replaceGlobalAgentModels(
            .init(expectedRevision: request.expectedRevision, profile: profile),
            attribution: attribution
        )
    }

    public func applyProjectAgentModelRecommendations(
        projectID: UUID,
        request: ApplyAgentModelRecommendationsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let current = try await agentModels(projectID: projectID)
        guard current.projectRevision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project Agent Models revision is stale", currentRevision: current.projectRevision)
        }
        let profile = applying(current.recommendations, to: current.effectiveProfile)
        return try await replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: request.expectedRevision, mode: .projectOverride, profile: profile),
            attribution: attribution
        )
    }

    public func resolveAgentTarget(
        projectID: UUID,
        target: AgentRoutingTarget
    ) async throws -> ResolvedAgentModelRoute? {
        let snapshot = try await agentModels(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        if target == .oracle {
            return try resolveOracleTarget(assigned: snapshot.effectiveProfile[.oracle], catalog: catalog)
        }
        if target == .contextBuilder {
            return try resolveContextBuilderTarget(profile: snapshot.effectiveProfile, catalog: catalog)
        }
        if target.isSubagentRole {
            return try resolveRoleTarget(target: target, assigned: snapshot.effectiveProfile[target], catalog: catalog)
        }
        guard let assigned = snapshot.effectiveProfile[target] else { return nil }
        if let route = runtimeRoute(assigned, target: target, catalog: catalog, usedRecommendationFallback: false) {
            return route
        }
        if assigned.pinned {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "The pinned \(target.rawValue) Agent Model target is unavailable",
                retryable: true
            )
        }
        guard let recommended = recommendationTarget(target: target, catalog: catalog, requireEffective: true) else {
            return nil
        }
        return runtimeRoute(recommended, target: target, catalog: catalog, usedRecommendationFallback: true)
    }

    func resolveOracleTarget(
        assigned: AgentModelTarget?,
        catalog: ProviderSettingsCatalogResponse
    ) throws -> ResolvedAgentModelRoute {
        guard let assigned else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "MCP Oracle model is not configured. Select an Oracle model in the Models settings before using ask_oracle."
            )
        }
        let trimmedModel = assigned.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedModel.isEmpty else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "MCP Oracle model raw value is invalid. Select a valid Oracle model in the Models settings before using ask_oracle."
            )
        }
        guard let route = runtimeRoute(assigned, target: .oracle, catalog: catalog, usedRecommendationFallback: false) else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "MCP oracle model '\(trimmedModel)' is not available.",
                retryable: true
            )
        }
        return route
    }

    func resolveContextBuilderTarget(
        profile: AgentModelsProfile,
        catalog: ProviderSettingsCatalogResponse
    ) throws -> ResolvedAgentModelRoute {
        guard var assigned = profile.contextBuilder else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Context Builder provider is not configured. Select a Context Builder agent and model in the Models settings before running Context Builder."
            )
        }
        let remembered = profile.contextBuilderModelsByAgent?[assigned.providerID.rawValue]
        let trimmedModel = assigned.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedModel.isEmpty, let remembered, !remembered.isEmpty {
            assigned = AgentModelTarget(
                providerID: assigned.providerID,
                modelID: remembered,
                reasoningEffort: assigned.reasoningEffort,
                pinned: assigned.pinned
            )
        }
        let resolvedModel = assigned.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedModel.isEmpty else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Context Builder model is invalid. Select a valid Context Builder model in the Models settings before running Context Builder."
            )
        }
        guard let route = runtimeRoute(assigned, target: .contextBuilder, catalog: catalog, usedRecommendationFallback: false) else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "The target workspace Context Builder provider is not available. Verify its Models settings and provider credentials.",
                retryable: true
            )
        }
        return route
    }

    func resolveRoleTarget(
        target: AgentRoutingTarget,
        assigned: AgentModelTarget?,
        catalog: ProviderSettingsCatalogResponse
    ) throws -> ResolvedAgentModelRoute {
        if let assigned, let route = runtimeRoute(assigned, target: target, catalog: catalog, usedRecommendationFallback: false) {
            return route
        }
        guard let recommended = recommendationTarget(target: target, catalog: catalog, requireEffective: true),
              let route = runtimeRoute(recommended, target: target, catalog: catalog, usedRecommendationFallback: true)
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "No available agent/model for task label '\(target.rawValue)'."
            )
        }
        return route
    }

    public func createSessionInput(from request: CreateSessionRequest) async throws -> CreateSessionInput {
        if request.hasExplicitProviderRoute {
            return try request.explicitCreateSessionInput()
        }
        let target = request.routingTarget ?? .pair
        guard target.isSubagentRole else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Session start routingTarget must be a role (explore, engineer, pair, or design)"
            )
        }
        guard let route = try await resolveAgentTarget(projectID: request.projectID, target: target) else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "No available agent/model for task label '\(target.rawValue)'."
            )
        }
        var settings = request.initialProviderSettings ?? [:]
        settings["provider.settingsID"] = route.providerID.rawValue
        if let effort = route.reasoningEffort {
            settings["provider.reasoningEffort"] = effort
        }
        return CreateSessionInput(
            projectID: request.projectID,
            parentSessionID: request.parentSessionID,
            provider: route.provider,
            providerSettingsID: route.providerID,
            model: route.modelID,
            visibility: request.visibility,
            initialPrompt: request.initialPrompt,
            selectedMessageContext: request.selectedMessageContext,
            startImmediately: request.startImmediately ?? false,
            initialPermissionMode: route.providerID.hasTypedDirectAgentProfile ? nil : request.initialPermissionMode,
            initialProviderSettings: settings
        )
    }

    public func providerCatalogSnapshot() async throws -> ProviderSettingsCatalogResponse {
        try await providerCatalog.serverSettingsProviderCatalog()
    }

    public func subagentPermissions() async -> SubagentPermissionSettingsSnapshot {
        guard let document = try? await store.subagentPermissionDocument() else {
            return .init(settings: .safeManaged, revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func directAgentPermissions() async -> DirectAgentPermissionsSettingsSnapshot {
        guard let document = try? await store.directAgentPermissionDocument() else {
            return .init(settings: .default, revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func replaceDirectAgentPermissions(
        _ request: ReplaceDirectAgentPermissionsSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> DirectAgentPermissionsSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertDirectAgentPermissionDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func workspaceApprovals() async -> WorkspaceApprovalSettingsSnapshot {
        guard let document = try? await store.workspaceApprovalDocument() else {
            return .init(settings: .init(), revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func replaceWorkspaceApprovals(
        _ request: ReplaceWorkspaceApprovalSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> WorkspaceApprovalSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertWorkspaceApprovalDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func setAutoApproveOperation(
        _ operation: WorkspaceApprovalOperation,
        enabled: Bool,
        expectedRevision: Int64,
        attribution: SettingsMutationAttribution
    ) async throws -> WorkspaceApprovalSettingsSnapshot {
        var settings = await workspaceApprovals().settings
        settings.setAutoApproveOperation(operation, enabled: enabled)
        return try await replaceWorkspaceApprovals(
            .init(expectedRevision: expectedRevision, settings: settings),
            attribution: attribution
        )
    }

    public func addAutoApproval(
        clientID: String,
        operation: WorkspaceApprovalOperation,
        expectedRevision: Int64,
        attribution: SettingsMutationAttribution
    ) async throws -> WorkspaceApprovalSettingsSnapshot {
        var settings = await workspaceApprovals().settings
        settings.addAutoApproval(clientID: clientID, operation: operation)
        return try await replaceWorkspaceApprovals(
            .init(expectedRevision: expectedRevision, settings: settings),
            attribution: attribution
        )
    }

    public func mcpDisabledTools() async -> MCPDisabledToolsSettingsSnapshot {
        guard let document = try? await store.mcpDisabledToolsDocument() else {
            return .init(settings: .init(), revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func replaceMCPDisabledTools(
        _ request: ReplaceMCPDisabledToolsSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPDisabledToolsSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertMCPDisabledToolsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func setMCPToolEnabled(
        _ name: String,
        enabled: Bool,
        expectedRevision: Int64,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPDisabledToolsSettingsSnapshot {
        var settings = await mcpDisabledTools().settings
        settings.setToolEnabled(name, enabled: enabled)
        return try await replaceMCPDisabledTools(
            .init(expectedRevision: expectedRevision, settings: settings),
            attribution: attribution
        )
    }

    public func applyMCPToolDefaultOffDiscoveries(
        _ names: Set<String>,
        expectedRevision: Int64,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPDisabledToolsSettingsSnapshot {
        var settings = await mcpDisabledTools().settings
        guard settings.applyDefaultOffDiscoveries(names) else {
            return await mcpDisabledTools()
        }
        return try await replaceMCPDisabledTools(
            .init(expectedRevision: expectedRevision, settings: settings),
            attribution: attribution
        )
    }

    public func showModelPresets() async -> MCPShowModelPresetsSettingsSnapshot {
        guard let document = try? await store.mcpShowModelPresetsDocument() else {
            return .init(settings: .init(), revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func replaceShowModelPresets(
        _ request: ReplaceMCPShowModelPresetsSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPShowModelPresetsSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertMCPShowModelPresetsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func setShowModelPresets(
        _ enabled: Bool,
        expectedRevision: Int64,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPShowModelPresetsSettingsSnapshot {
        try await replaceShowModelPresets(
            .init(expectedRevision: expectedRevision, settings: .init(showModelPresets: enabled)),
            attribution: attribution
        )
    }

    public func replaceSubagentPermissions(
        _ request: ReplaceSubagentPermissionSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> SubagentPermissionSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertSubagentPermissionDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func contextBuilder(projectID: UUID? = nil) async throws -> ContextBuilderSettingsSnapshot {
        if let projectID { _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID) }
        let global = try await store.contextBuilderDocument(scopeID: "global")
        let globalProfile = global?.value.profile ?? .default
        let project: StoredSettingsDocument<ContextBuilderScopeDocument>? = if let projectID {
            try await store.contextBuilderDocument(scopeID: scopeID(projectID))
        } else {
            nil
        }
        let projectMode = project?.value.mode ?? .inheritGlobal
        let projectProfile = project?.value.profile
        let effective = projectMode == .projectOverride ? (projectProfile ?? globalProfile) : globalProfile
        return .init(
            globalProfile: globalProfile,
            globalRevision: global?.revision ?? 0,
            projectID: projectID,
            projectMode: projectMode,
            projectProfile: projectProfile,
            projectRevision: project?.revision ?? 0,
            effectiveProfile: effective,
            updatedAt: max(global?.updatedAt ?? epoch, project?.updatedAt ?? epoch)
        )
    }

    public func replaceGlobalContextBuilder(
        _ request: ReplaceGlobalContextBuilderSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        let profile = try normalize(request.profile)
        let value = ContextBuilderScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: "global",
            projectID: nil,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: value)
        )
        return try await contextBuilder()
    }

    public func replaceProjectContextBuilder(
        projectID: UUID,
        request: ReplaceProjectContextBuilderSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let value = try normalizeProjectContextBuilder(mode: request.mode, profile: request.profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceProject", attribution: attribution, payload: value)
        )
        return try await contextBuilder(projectID: projectID)
    }

    public func copyGlobalContextBuilderToProject(
        projectID: UUID,
        request: CopyGlobalContextBuilderToProjectRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let global = try await store.contextBuilderDocument(scopeID: "global")
        let observedGlobalRevision = global?.revision ?? 0
        guard observedGlobalRevision == request.expectedGlobalRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Context Builder revision is stale", currentRevision: observedGlobalRevision)
        }
        let profile = try normalize(global?.value.profile ?? .default)
        let value = ContextBuilderScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedProjectRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedProjectRevision,
            expectedGlobalRevision: request.expectedGlobalRevision,
            audit: audit(operation: "copyGlobal", attribution: attribution, payload: value)
        )
        return try await contextBuilder(projectID: projectID)
    }

    public func resolveContextBuilder(
        projectID: UUID,
        origin: ContextBuilderInvocationOrigin,
        overrides: ContextBuilderInvocationOverrides = .init()
    ) async throws -> EffectiveContextBuilderSettings {
        let profile = try await contextBuilder(projectID: projectID).effectiveProfile
        let allowQuestions = overrides.allowClarifyingQuestions ?? {
            switch origin {
            case .portal: profile.portalClarifyingQuestions
            case .mcp: profile.mcpClarifyingQuestions
            case .internal: false
            }
        }()
        let effective = ContextBuilderSettingsProfile(
            budget: overrides.budget ?? profile.budget,
            enhancementMode: overrides.enhancementMode ?? profile.enhancementMode,
            questionTimeoutSeconds: overrides.questionTimeoutSeconds ?? profile.questionTimeoutSeconds,
            portalClarifyingQuestions: allowQuestions,
            mcpClarifyingQuestions: allowQuestions,
            followUpAnalysis: overrides.followUpAnalysis ?? profile.followUpAnalysis,
            followUpBudget: overrides.followUpBudget ?? profile.followUpBudget
        )
        let validated = try normalize(effective)
        return .init(
            budget: validated.budget,
            enhancementMode: validated.enhancementMode,
            allowClarifyingQuestions: allowQuestions,
            questionTimeoutSeconds: validated.questionTimeoutSeconds,
            followUpAnalysis: validated.followUpAnalysis,
            followUpBudget: validated.followUpBudget
        )
    }

    public func renderContextBuilderInstructions(
        _ instructions: String,
        effective: EffectiveContextBuilderSettings
    ) throws -> String {
        guard !instructions.isEmpty, instructions.utf8.count <= 64000 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder instructions are empty or exceed their bound")
        }
        switch effective.enhancementMode {
        case .preserve:
            return instructions
        case .augment:
            return instructions
        case .rewrite:
            return """
            <context-builder-enhancement mode="rewrite">
            Produce a replacement handoff prompt grounded in repository discovery. Preserve every material constraint from the caller.
            </context-builder-enhancement>

            <caller-instructions>
            \(instructions)
            </caller-instructions>
            """
        }
    }

    public func modelPresets() async throws -> MCPModelPresetsSnapshot {
        let document = try await store.mcpModelPresetsDocument()
        return .init(presets: document?.value ?? [], revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func resolveModelPreset(
        presetID: UUID,
        availability: MCPModelPresetAvailability
    ) async throws -> ResolvedAgentModelRoute {
        guard await showModelPresets().settings.showModelPresets else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "MCP model presets are disabled. Enable mcp.show_model_presets to use named presets."
            )
        }
        let snapshot = try await modelPresets()
        guard let preset = snapshot.presets.first(where: { $0.presetID == presetID }), preset.enabled else {
            throw ServiceAPIError(code: .notFound, message: "MCP model preset is missing or disabled")
        }
        guard preset.availability.contains(availability) else {
            throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset is unavailable for this Oracle mode")
        }
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        guard let route = runtimeRoute(preset.target, target: .oracle, catalog: catalog, usedRecommendationFallback: false) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "MCP model preset target is unavailable", retryable: true)
        }
        return route
    }

    public func modelDiscovery(projectID: UUID) async throws -> MCPModelDiscoverySnapshot {
        let profile = try await agentModels(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let presets = try await modelPresets()
        let gate = await showModelPresets()
        let advertisedPresets = gate.settings.showModelPresets ? presets.presets.filter(\.enabled) : []
        return .init(
            providers: catalog.providers,
            presets: advertisedPresets,
            roleModelRestrictionApplied: false,
            settingsRevision: max(max(max(profile.globalRevision, profile.projectRevision), presets.revision), gate.revision)
        )
    }

    public func agentDiscovery(projectID: UUID, rolesOnly: Bool = false) async throws -> MCPAgentDiscoverySnapshot {
        let snapshot = try await agentModels(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let restrict = snapshot.effectiveProfile.restrictDiscoveryToRoleModels
        let omitAgentCatalog = rolesOnly || restrict
        let taskLabels = AgentRoutingTarget.allCases.compactMap { target -> MCPAgentTaskLabel? in
            guard target.isSubagentRole else { return nil }
            return taskLabel(
                target: target,
                assigned: snapshot.effectiveProfile[target],
                catalog: catalog
            )
        }
        let agents: [MCPDiscoveredAgent]? = if omitAgentCatalog {
            nil
        } else {
            catalog.providers.compactMap { discoveredAgent(from: $0) }
        }
        return .init(
            taskLabels: taskLabels,
            agents: agents,
            roleModelRestrictionApplied: restrict
        )
    }

    public func replaceModelPresets(
        _ request: ReplaceMCPModelPresetsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPModelPresetsSnapshot {
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let presets = try normalize(request.presets, catalog: catalog)
        let document = StoredSettingsDocument(value: presets, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertMCPModelPresetsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: presets)
        )
        return .init(presets: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func advanced() async throws -> AdvancedServerSettingsSnapshot {
        let document = try await store.advancedServerSettingsDocument()
        return .init(settings: document?.value ?? .default, revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func replaceAdvanced(
        _ request: ReplaceAdvancedServerSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AdvancedServerSettingsSnapshot {
        guard (0 ... 2).contains(request.settings.modelTemperature) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Model temperature is outside its supported range")
        }
        try validateModelOverrides(request.settings.modelOverrides)
        let document = StoredSettingsDocument(value: request.settings, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertAdvancedServerSettingsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func selectionPresets(projectID: UUID) async throws -> ProjectSelectionPresetsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let document = try await store.projectSelectionPresetsDocument(projectID: projectID)
        return .init(projectID: projectID, presets: document?.value ?? [], revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func replaceSelectionPresets(
        projectID: UUID,
        request: ReplaceProjectSelectionPresetsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ProjectSelectionPresetsSnapshot {
        let roots = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let presets = try normalize(request.presets, projectID: projectID, roots: roots)
        let document = StoredSettingsDocument(value: presets, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertProjectSelectionPresetsDocument(
            document,
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: audit(operation: "replaceProject", attribution: attribution, payload: presets)
        )
        return .init(projectID: projectID, presets: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }
}

extension ProviderSettingsService: ServerSettingsProviderCatalogProviding {
    public func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        try await catalog()
    }
}

public struct AuthorityStoreProjectCatalog: ServerSettingsProjectCatalogProviding {
    private let store: any RepoPromptAuthorityStore

    public init(store: any RepoPromptAuthorityStore) {
        self.store = store
    }

    public func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID> {
        guard let project = try await store.allProjects().first(where: { $0.projectID == projectID }),
              project.state != .archived
        else {
            throw ServiceAPIError(code: .notFound, message: "Project not found")
        }
        return Set(project.roots.map(\.rootID))
    }
}

private extension ServerSettingsService {
    struct RecommendationCandidate {
        let providerID: ProviderSettingsID
        let modelTokens: [String]
        let reasoningEffort: String?
    }

    var epoch: Date {
        Date(timeIntervalSince1970: 0)
    }

    func scopeID(_ projectID: UUID) -> String {
        projectID.uuidString.lowercased()
    }

    func audit(
        operation: String,
        attribution: SettingsMutationAttribution,
        payload: some Encodable
    ) throws -> ServerSettingsAuditMutation {
        let data = try JSONEncoder.serviceEncoder.encode(payload)
        return .init(operation: operation, attribution: attribution, payloadDigest: PortableContentDigest.sha256Hex(data))
    }

    func normalizeProjectAgentModels(
        mode: AgentModelsScopeMode,
        profile: AgentModelsProfile?,
        storedProfile: AgentModelsProfile?,
        globalProfile: AgentModelsProfile,
        catalog: ProviderSettingsCatalogResponse
    ) throws -> AgentModelsScopeDocument {
        switch mode {
        case .inheritGlobal:
            if let leftover = profile ?? storedProfile {
                return try .init(mode: mode, profile: normalize(leftover, catalog: catalog))
            }
            return .init(mode: mode, profile: nil)
        case .projectOverride:
            let override = profile ?? storedProfile ?? globalProfile
            return try .init(mode: mode, profile: normalize(override, catalog: catalog))
        }
    }

    func normalize(_ profile: AgentModelsProfile, catalog: ProviderSettingsCatalogResponse) throws -> AgentModelsProfile {
        func target(_ value: AgentModelTarget?) throws -> AgentModelTarget? {
            guard let value else { return nil }
            guard let provider = catalog.providers.first(where: { $0.providerID == value.providerID }) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent model provider is not in the server catalog")
            }
            let modelID = try normalizedText(value.modelID, maximumBytes: 256)
            let effort = try normalizedText(value.reasoningEffort, maximumBytes: 64)?.lowercased()
            if effort != nil, modelID == nil {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent model reasoning effort requires a model")
            }
            if let modelID {
                guard let model = provider.models.first(where: { $0.id == modelID }) else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Agent model is not in the provider catalog")
                }
                if let effort, !model.reasoningEfforts.contains(effort) {
                    throw ServiceAPIError(code: .invalidRequest, message: "Agent model reasoning effort is not advertised")
                }
            }
            return AgentModelTarget(providerID: value.providerID, modelID: modelID, reasoningEffort: effort, pinned: value.pinned)
        }
        let normalizedContextBuilder = try target(profile.contextBuilder)
        var modelsByAgent = profile.contextBuilderModelsByAgent ?? [:]
        if let normalizedContextBuilder, let modelID = normalizedContextBuilder.modelID {
            modelsByAgent[normalizedContextBuilder.providerID.rawValue] = modelID
        }
        var normalizedMap: [String: String] = [:]
        for (agent, model) in modelsByAgent {
            guard let modelID = try normalizedText(model, maximumBytes: 256) else { continue }
            normalizedMap[agent] = modelID
        }
        return try AgentModelsProfile(
            oracle: target(profile.oracle),
            contextBuilder: normalizedContextBuilder,
            explore: target(profile.explore),
            engineer: target(profile.engineer),
            pair: target(profile.pair),
            design: target(profile.design),
            restrictDiscoveryToRoleModels: profile.restrictDiscoveryToRoleModels,
            contextBuilderModelsByAgent: normalizedMap.isEmpty ? nil : normalizedMap,
            preferredComposeModelRaw: profile.preferredComposeModelRaw,
            syncChatModelWithOracle: profile.syncChatModelWithOracle
        )
    }

    func applying(_ recommendations: [AgentModelRecommendationRow], to profile: AgentModelsProfile) -> AgentModelsProfile {
        var next = profile
        for role in [AgentRoutingTarget.explore, .engineer, .pair, .design] {
            next = next.replacing(role, with: nil)
        }
        for row in recommendations {
            guard row.availability == .exact,
                  let target = row.recommendedTarget,
                  row.target == .oracle || row.target == .contextBuilder
            else { continue }
            next = next.replacing(row.target, with: target)
        }
        if let oracleModel = next.oracle?.modelID {
            next = next.replacingComposeModel(oracleModel)
        }
        return next
    }

    func recommendationRows(catalog: ProviderSettingsCatalogResponse) -> [AgentModelRecommendationRow] {
        recommendationChains().map { target, candidates in
            if let exact = recommendationTarget(
                target: target,
                candidates: candidates,
                catalog: catalog,
                requireEffective: false
            ) {
                return AgentModelRecommendationRow(
                    target: target,
                    recommendedTarget: exact,
                    availability: .exact,
                    detail: "Exact profile \(Self.recommendationProfileVersion) target is advertised"
                )
            }
            let sawAdvertisedProvider = candidates.contains { candidate in
                candidate.providerID != .openCodeACP
                    && catalog.providers.contains { $0.providerID == candidate.providerID && $0.deploymentAllowed }
            }
            return .init(
                target: target,
                recommendedTarget: nil,
                availability: sawAdvertisedProvider ? .informational : .unavailable,
                detail: sawAdvertisedProvider ? "A provider is advertised but the exact profile target is unavailable" : "No recommendation provider is advertised"
            )
        }
    }

    func recommendationChains() -> [(AgentRoutingTarget, [RecommendationCandidate])] {
        let codex: (String) -> RecommendationCandidate = { effort in
            .init(providerID: .codex, modelTokens: ["gpt-5.6", "sol"], reasoningEffort: effort)
        }
        let claude: (String, String?) -> RecommendationCandidate = { family, effort in
            .init(providerID: .claudeCompatible, modelTokens: [family], reasoningEffort: effort)
        }
        let cursor: (Bool) -> RecommendationCandidate = { composer in
            .init(providerID: .cursorACP, modelTokens: composer ? ["composer", "2"] : ["auto"], reasoningEffort: nil)
        }
        return [
            (.oracle, [codex("high"), claude("opus", nil)]),
            (.contextBuilder, [codex("low"), claude("sonnet", nil), cursor(true)]),
            (.explore, [codex("low"), claude("sonnet", "high"), claude("haiku", nil), cursor(false)]),
            (.engineer, [codex("medium"), claude("sonnet", nil), cursor(true)]),
            (.pair, [codex("high"), claude("opus", nil), cursor(true)]),
            (.design, [claude("opus", nil), cursor(true), codex("medium")])
        ]
    }

    func taskLabel(
        target: AgentRoutingTarget,
        assigned: AgentModelTarget?,
        catalog: ProviderSettingsCatalogResponse
    ) -> MCPAgentTaskLabel? {
        let recommended = recommendationTarget(target: target, catalog: catalog, requireEffective: false)
        let assignedRoute = assigned.flatMap { runtimeRoute($0, target: target, catalog: catalog, usedRecommendationFallback: false) }
        let effective: ResolvedAgentModelRoute
        if let assignedRoute {
            effective = assignedRoute
        } else if let recommended,
                  let route = runtimeRoute(recommended, target: target, catalog: catalog, usedRecommendationFallback: true)
        {
            effective = route
        } else {
            return nil
        }
        let recommendedRoute = recommended.flatMap {
            runtimeRoute($0, target: target, catalog: catalog, usedRecommendationFallback: true)
        }
        let recommendedID = recommendedRoute.map(compoundModelID) ?? compoundModelID(effective)
        return MCPAgentTaskLabel(
            label: target.rawValue,
            description: roleDescription(target),
            modelID: compoundModelID(effective),
            name: displayName(for: effective, catalog: catalog),
            recommendedModelID: recommendedID,
            recommendedName: recommendedRoute.map { displayName(for: $0, catalog: catalog) } ?? displayName(for: effective, catalog: catalog),
            hasCustomOverride: assigned != nil && assignedRoute != nil && (assigned?.providerID != recommended?.providerID || assigned?.modelID != recommended?.modelID),
            overrideUnavailable: assigned != nil && assignedRoute == nil
        )
    }

    func discoveredAgent(from provider: ProviderSettingsSnapshot) -> MCPDiscoveredAgent? {
        guard provider.deploymentAllowed,
              provider.effectiveEnabled,
              provider.providerID.runtimeKind != nil,
              !provider.models.isEmpty
        else { return nil }
        let models = provider.models.map { model in
            MCPDiscoveredAgentModel(
                modelID: "\(provider.providerID.rawValue):\(model.id)",
                name: model.displayName,
                reasoningEffort: model.reasoningEfforts.first
            )
        }
        let defaultModel = provider.preference.defaultModel ?? provider.models.first?.id
        return MCPDiscoveredAgent(
            name: provider.displayName,
            available: true,
            capabilities: [],
            models: models,
            defaultModelID: defaultModel.map { "\(provider.providerID.rawValue):\($0)" }
        )
    }

    func compoundModelID(_ route: ResolvedAgentModelRoute) -> String {
        "\(route.providerID.rawValue):\(route.modelID ?? "")"
    }

    func displayName(for route: ResolvedAgentModelRoute, catalog: ProviderSettingsCatalogResponse) -> String {
        let provider = catalog.providers.first(where: { $0.providerID == route.providerID })
        let modelName = provider?.models.first(where: { $0.id == route.modelID })?.displayName ?? route.modelID ?? route.providerID.rawValue
        return "\(provider?.displayName ?? route.providerID.rawValue) \(modelName)"
    }

    func roleDescription(_ target: AgentRoutingTarget) -> String {
        switch target {
        case .explore: "Fast exploration and codebase mapping"
        case .engineer: "Balanced engineering work"
        case .pair: "Interactive pair programming with highest-tier models"
        case .design: "Architecture, design discussions, and creative problem solving"
        case .oracle, .contextBuilder: target.rawValue
        }
    }

    func recommendationTarget(
        target: AgentRoutingTarget,
        catalog: ProviderSettingsCatalogResponse,
        requireEffective: Bool
    ) -> AgentModelTarget? {
        guard let candidates = recommendationChains().first(where: { $0.0 == target })?.1 else { return nil }
        return recommendationTarget(target: target, candidates: candidates, catalog: catalog, requireEffective: requireEffective)
    }

    func recommendationTarget(
        target _: AgentRoutingTarget,
        candidates: [RecommendationCandidate],
        catalog: ProviderSettingsCatalogResponse,
        requireEffective: Bool
    ) -> AgentModelTarget? {
        for candidate in candidates where candidate.providerID != .openCodeACP {
            guard let provider = catalog.providers.first(where: { $0.providerID == candidate.providerID }),
                  provider.deploymentAllowed,
                  !requireEffective || provider.effectiveEnabled
            else { continue }
            guard let model = provider.models.first(where: { model in
                let text = "\(model.id) \(model.displayName)".lowercased()
                return candidate.modelTokens.allSatisfy { text.contains($0.lowercased()) }
            }) else { continue }
            if let effort = candidate.reasoningEffort, !model.reasoningEfforts.contains(effort) { continue }
            return .init(
                providerID: candidate.providerID,
                modelID: model.id,
                reasoningEffort: candidate.reasoningEffort
            )
        }
        return nil
    }

    func runtimeRoute(
        _ target: AgentModelTarget,
        target routingTarget: AgentRoutingTarget,
        catalog: ProviderSettingsCatalogResponse,
        usedRecommendationFallback: Bool
    ) -> ResolvedAgentModelRoute? {
        guard let provider = catalog.providers.first(where: { $0.providerID == target.providerID }),
              provider.deploymentAllowed,
              provider.effectiveEnabled,
              let runtimeKind = provider.providerID.runtimeKind
        else { return nil }
        if let modelID = target.modelID {
            guard let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
            if let effort = target.reasoningEffort, !model.reasoningEfforts.contains(effort) { return nil }
        } else if target.reasoningEffort != nil {
            return nil
        }
        return .init(
            routingTarget: routingTarget,
            providerID: provider.providerID,
            provider: runtimeKind,
            modelID: target.modelID ?? provider.preference.defaultModel,
            reasoningEffort: target.reasoningEffort ?? provider.preference.reasoningEffort,
            usedRecommendationFallback: usedRecommendationFallback
        )
    }

    func normalizeProjectContextBuilder(
        mode: ContextBuilderSettingsScopeMode,
        profile: ContextBuilderSettingsProfile?
    ) throws -> ContextBuilderScopeDocument {
        switch mode {
        case .inheritGlobal:
            guard profile == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Inherited Context Builder settings cannot contain an override") }
            return .init(mode: mode, profile: nil)
        case .projectOverride:
            guard let profile else { throw ServiceAPIError(code: .invalidRequest, message: "Project Context Builder override is missing") }
            return try .init(mode: mode, profile: normalize(profile))
        }
    }

    func normalize(_ profile: ContextBuilderSettingsProfile) throws -> ContextBuilderSettingsProfile {
        guard (10000 ... 200_000).contains(profile.budget), profile.budget.isMultiple(of: 5000) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget is outside its supported range or increment")
        }
        guard [30, 60, 120, 300].contains(profile.questionTimeoutSeconds) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder question timeout is unsupported")
        }
        guard (40000 ... 200_000).contains(profile.followUpBudget), profile.followUpBudget.isMultiple(of: 5000) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder follow-up budget is outside its supported range or increment")
        }
        return .init(
            budget: profile.budget,
            enhancementMode: profile.enhancementMode,
            questionTimeoutSeconds: profile.questionTimeoutSeconds,
            portalClarifyingQuestions: profile.portalClarifyingQuestions,
            mcpClarifyingQuestions: profile.mcpClarifyingQuestions,
            followUpAnalysis: profile.followUpAnalysis,
            followUpBudget: profile.followUpBudget
        )
    }

    func normalize(_ presets: [MCPModelPreset], catalog: ProviderSettingsCatalogResponse) throws -> [MCPModelPreset] {
        guard presets.count <= 100, Set(presets.map(\.presetID)).count == presets.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset collection is invalid")
        }
        var names = Set<String>()
        return try presets.sorted { ($0.order, $0.presetID.uuidString) < ($1.order, $1.presetID.uuidString) }.enumerated().map { index, preset in
            guard let name = try normalizedText(preset.name, maximumBytes: 128), !name.isEmpty,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted,
                  !preset.availability.isEmpty,
                  Set(preset.availability).count == preset.availability.count
            else { throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset name or availability is invalid") }
            let description = try normalizedText(preset.description, maximumBytes: 1024)
            let normalizedTarget = try normalize(
                AgentModelsProfile(oracle: preset.target),
                catalog: catalog
            ).oracle!
            return .init(
                presetID: preset.presetID,
                name: name,
                description: description,
                target: normalizedTarget,
                availability: preset.availability.sorted { $0.rawValue < $1.rawValue },
                enabled: preset.enabled,
                order: index
            )
        }
    }

    func normalize(
        _ presets: [ProjectSelectionPreset],
        projectID: UUID,
        roots: Set<UUID>
    ) throws -> [ProjectSelectionPreset] {
        guard presets.count <= 100, Set(presets.map(\.presetID)).count == presets.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selection preset collection is invalid")
        }
        var names = Set<String>()
        return try presets.sorted { ($0.order, $0.presetID.uuidString) < ($1.order, $1.presetID.uuidString) }.enumerated().map { index, preset in
            guard preset.projectID == projectID,
                  preset.rowRevision >= 1,
                  preset.entries.count <= 20000,
                  let name = try normalizedText(preset.name, maximumBytes: 256),
                  !name.isEmpty,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted
            else { throw ServiceAPIError(code: .invalidRequest, message: "Selection preset metadata is invalid") }
            for entry in preset.entries {
                guard roots.contains(entry.rootID) else {
                    throw ServiceAPIError(code: .rootUnauthorized, message: "Selection preset contains an unauthorized root")
                }
                try validateSelectionEntry(entry)
            }
            return .init(
                presetID: preset.presetID,
                projectID: projectID,
                name: name,
                entries: preset.entries,
                order: index,
                rowRevision: preset.rowRevision
            )
        }
    }

    func validateSelectionEntry(_ entry: LogicalSelectionEntry) throws {
        let path = entry.logicalPath
        guard !path.isEmpty,
              path.utf8.count <= 4096,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw ServiceAPIError(code: .invalidRequest, message: "Selection preset path is invalid") }
        switch entry.mode {
        case .slices:
            guard !entry.ranges.isEmpty, entry.ranges.allSatisfy({ $0.lowerBound >= 1 }) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Selection preset slice range is invalid")
            }
        case .full, .codeMap:
            guard entry.ranges.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Selection preset ranges require slice mode")
            }
        }
    }

    private func validateModelOverrides(_ maps: ModelOverrideMaps) throws {
        let boolMaps = [maps.diffOverrides, maps.streamOverrides, maps.responsesOverrides]
        for map in boolMaps {
            guard map.count <= 256 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Model override map exceeds its bound")
            }
            for key in map.keys {
                guard let normalized = try normalizedText(key, maximumBytes: 256), !normalized.isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Model override key is invalid")
                }
            }
        }
        guard maps.temperatureOverrides.count <= 256 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Model override map exceeds its bound")
        }
        for (key, value) in maps.temperatureOverrides {
            guard let normalized = try normalizedText(key, maximumBytes: 256), !normalized.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Model override key is invalid")
            }
            guard (0 ... 2).contains(value) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Model temperature override is outside its supported range")
            }
        }
    }

    func normalizedText(_ value: String?, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(normalized)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Typed setting text is invalid or resembles credential material") }
        return normalized
    }
}
