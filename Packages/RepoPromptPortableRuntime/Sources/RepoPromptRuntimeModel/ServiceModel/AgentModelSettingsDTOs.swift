import Foundation

public enum AgentRoutingTarget: String, Codable, CaseIterable, Sendable {
    case oracle
    case contextBuilder
    case explore
    case engineer
    case pair
    case design

    public var isSubagentRole: Bool {
        switch self {
        case .explore, .engineer, .pair, .design: true
        case .oracle, .contextBuilder: false
        }
    }
}

public struct ResolvedAgentModelRoute: Codable, Hashable, Sendable {
    public let routingTarget: AgentRoutingTarget
    public let providerID: ProviderSettingsID
    public let provider: ProviderKind
    public let modelID: String?
    public let reasoningEffort: String?
    public let usedRecommendationFallback: Bool

    public init(
        routingTarget: AgentRoutingTarget,
        providerID: ProviderSettingsID,
        provider: ProviderKind,
        modelID: String?,
        reasoningEffort: String?,
        usedRecommendationFallback: Bool
    ) {
        self.routingTarget = routingTarget
        self.providerID = providerID
        self.provider = provider
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.usedRecommendationFallback = usedRecommendationFallback
    }
}

public struct AgentModelTarget: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String?
    public let reasoningEffort: String?
    public let pinned: Bool

    public init(providerID: ProviderSettingsID, modelID: String? = nil, reasoningEffort: String? = nil, pinned: Bool = false) {
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.pinned = pinned
    }
}

public struct AgentModelsProfile: Codable, Hashable, Sendable {
    public let oracle: AgentModelTarget?
    public let contextBuilder: AgentModelTarget?
    public let explore: AgentModelTarget?
    public let engineer: AgentModelTarget?
    public let pair: AgentModelTarget?
    public let design: AgentModelTarget?
    public let restrictDiscoveryToRoleModels: Bool
    public let contextBuilderModelsByAgent: [String: String]?
    public let preferredComposeModelRaw: String?
    public let syncChatModelWithOracle: Bool?

    public init(
        oracle: AgentModelTarget? = nil,
        contextBuilder: AgentModelTarget? = nil,
        explore: AgentModelTarget? = nil,
        engineer: AgentModelTarget? = nil,
        pair: AgentModelTarget? = nil,
        design: AgentModelTarget? = nil,
        restrictDiscoveryToRoleModels: Bool = false,
        contextBuilderModelsByAgent: [String: String]? = nil,
        preferredComposeModelRaw: String? = nil,
        syncChatModelWithOracle: Bool? = nil
    ) {
        self.oracle = oracle
        self.contextBuilder = contextBuilder
        self.explore = explore
        self.engineer = engineer
        self.pair = pair
        self.design = design
        self.restrictDiscoveryToRoleModels = restrictDiscoveryToRoleModels
        self.contextBuilderModelsByAgent = Self.normalizedContextBuilderModelsByAgent(contextBuilderModelsByAgent)
        self.preferredComposeModelRaw = Self.normalizedComposeModelRaw(preferredComposeModelRaw)
        self.syncChatModelWithOracle = syncChatModelWithOracle
    }

    public subscript(target: AgentRoutingTarget) -> AgentModelTarget? {
        switch target {
        case .oracle: oracle
        case .contextBuilder: contextBuilder
        case .explore: explore
        case .engineer: engineer
        case .pair: pair
        case .design: design
        }
    }

    public func replacing(_ target: AgentRoutingTarget, with value: AgentModelTarget?) -> AgentModelsProfile {
        var modelsByAgent = contextBuilderModelsByAgent ?? [:]
        let nextContextBuilder: AgentModelTarget?
        if target == .contextBuilder {
            if let value {
                let remembered = modelsByAgent[value.providerID.rawValue]
                let trimmedModel = value.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedModel = trimmedModel.isEmpty ? remembered : trimmedModel
                if let resolvedModel, !resolvedModel.isEmpty {
                    modelsByAgent[value.providerID.rawValue] = resolvedModel
                }
                nextContextBuilder = AgentModelTarget(
                    providerID: value.providerID,
                    modelID: resolvedModel,
                    reasoningEffort: value.reasoningEffort,
                    pinned: value.pinned
                )
            } else {
                nextContextBuilder = nil
            }
        } else {
            nextContextBuilder = contextBuilder
        }
        return AgentModelsProfile(
            oracle: target == .oracle ? value : oracle,
            contextBuilder: nextContextBuilder,
            explore: target == .explore ? value : explore,
            engineer: target == .engineer ? value : engineer,
            pair: target == .pair ? value : pair,
            design: target == .design ? value : design,
            restrictDiscoveryToRoleModels: restrictDiscoveryToRoleModels,
            contextBuilderModelsByAgent: modelsByAgent.isEmpty ? nil : modelsByAgent,
            preferredComposeModelRaw: preferredComposeModelRaw,
            syncChatModelWithOracle: syncChatModelWithOracle
        ).honoringComposeSync(oracleChanged: target == .oracle)
    }

    public func resolvedSyncChatModelWithOracle() -> Bool {
        if let syncChatModelWithOracle { return syncChatModelWithOracle }
        let planning = normalizedPlanningModelID
        let compose = Self.normalizedComposeModelRaw(preferredComposeModelRaw)
        return planning != nil && planning == compose
    }

    public func resolvedComposeModelRaw() -> String? {
        if resolvedSyncChatModelWithOracle(), let planning = normalizedPlanningModelID {
            return planning
        }
        return Self.normalizedComposeModelRaw(preferredComposeModelRaw)
    }

    public func replacingComposeModel(_ raw: String?) -> AgentModelsProfile {
        let compose = Self.normalizedComposeModelRaw(raw)
        let planning = normalizedPlanningModelID
        let nextSync: Bool? = if resolvedSyncChatModelWithOracle(), compose != planning {
            false
        } else {
            syncChatModelWithOracle
        }
        return AgentModelsProfile(
            oracle: oracle,
            contextBuilder: contextBuilder,
            explore: explore,
            engineer: engineer,
            pair: pair,
            design: design,
            restrictDiscoveryToRoleModels: restrictDiscoveryToRoleModels,
            contextBuilderModelsByAgent: contextBuilderModelsByAgent,
            preferredComposeModelRaw: compose,
            syncChatModelWithOracle: nextSync
        )
    }

    public func replacingSyncChatModelWithOracle(_ enabled: Bool) -> AgentModelsProfile {
        let compose = enabled ? normalizedPlanningModelID : Self.normalizedComposeModelRaw(preferredComposeModelRaw)
        return AgentModelsProfile(
            oracle: oracle,
            contextBuilder: contextBuilder,
            explore: explore,
            engineer: engineer,
            pair: pair,
            design: design,
            restrictDiscoveryToRoleModels: restrictDiscoveryToRoleModels,
            contextBuilderModelsByAgent: contextBuilderModelsByAgent,
            preferredComposeModelRaw: compose,
            syncChatModelWithOracle: enabled
        )
    }

    private var normalizedPlanningModelID: String? {
        Self.normalizedComposeModelRaw(oracle?.modelID)
    }

    private func honoringComposeSync(oracleChanged: Bool) -> AgentModelsProfile {
        guard oracleChanged, resolvedSyncChatModelWithOracle() else { return self }
        return AgentModelsProfile(
            oracle: oracle,
            contextBuilder: contextBuilder,
            explore: explore,
            engineer: engineer,
            pair: pair,
            design: design,
            restrictDiscoveryToRoleModels: restrictDiscoveryToRoleModels,
            contextBuilderModelsByAgent: contextBuilderModelsByAgent,
            preferredComposeModelRaw: normalizedPlanningModelID,
            syncChatModelWithOracle: syncChatModelWithOracle ?? true
        )
    }

    static func normalizedComposeModelRaw(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedContextBuilderModelsByAgent(_ models: [String: String]?) -> [String: String]? {
        guard let models else { return nil }
        var normalized: [String: String] = [:]
        for (rawAgent, rawModel) in models {
            let agent = rawAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agent.isEmpty, !model.isEmpty else { continue }
            normalized[agent] = model
        }
        return normalized.isEmpty ? nil : normalized
    }

    public static let `default` = AgentModelsProfile()
}

public enum AgentModelsScopeMode: String, Codable, Sendable {
    case inheritGlobal
    case projectOverride
}

public struct AgentModelsScopeDocument: Codable, Hashable, Sendable {
    public let mode: AgentModelsScopeMode
    public let profile: AgentModelsProfile?

    public init(mode: AgentModelsScopeMode, profile: AgentModelsProfile?) {
        self.mode = mode
        self.profile = profile
    }
}

public enum AgentModelRecommendationAvailability: String, Codable, Sendable {
    case exact
    case informational
    case unavailable
}

public struct AgentModelRecommendationRow: Codable, Hashable, Sendable {
    public let target: AgentRoutingTarget
    public let recommendedTarget: AgentModelTarget?
    public let availability: AgentModelRecommendationAvailability
    public let detail: String

    public init(target: AgentRoutingTarget, recommendedTarget: AgentModelTarget?, availability: AgentModelRecommendationAvailability, detail: String) {
        self.target = target
        self.recommendedTarget = recommendedTarget
        self.availability = availability
        self.detail = detail
    }
}

public struct AgentModelsSettingsSnapshot: Codable, Hashable, Sendable {
    public let globalProfile: AgentModelsProfile
    public let globalRevision: Int64
    public let projectID: UUID?
    public let projectMode: AgentModelsScopeMode
    public let projectProfile: AgentModelsProfile?
    public let projectRevision: Int64
    public let effectiveProfile: AgentModelsProfile
    public let recommendationProfileVersion: String
    public let recommendations: [AgentModelRecommendationRow]
    public let updatedAt: Date

    public init(
        globalProfile: AgentModelsProfile,
        globalRevision: Int64,
        projectID: UUID?,
        projectMode: AgentModelsScopeMode,
        projectProfile: AgentModelsProfile?,
        projectRevision: Int64,
        effectiveProfile: AgentModelsProfile,
        recommendationProfileVersion: String = "202_608",
        recommendations: [AgentModelRecommendationRow] = [],
        updatedAt: Date
    ) {
        self.globalProfile = globalProfile
        self.globalRevision = globalRevision
        self.projectID = projectID
        self.projectMode = projectMode
        self.projectProfile = projectProfile
        self.projectRevision = projectRevision
        self.effectiveProfile = effectiveProfile
        self.recommendationProfileVersion = recommendationProfileVersion
        self.recommendations = recommendations
        self.updatedAt = updatedAt
    }
}

public struct ReplaceGlobalAgentModelsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let profile: AgentModelsProfile

    public init(expectedRevision: Int64, profile: AgentModelsProfile) {
        self.expectedRevision = expectedRevision
        self.profile = profile
    }
}

public struct ReplaceProjectAgentModelsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let mode: AgentModelsScopeMode
    public let profile: AgentModelsProfile?

    public init(expectedRevision: Int64, mode: AgentModelsScopeMode, profile: AgentModelsProfile?) {
        self.expectedRevision = expectedRevision
        self.mode = mode
        self.profile = profile
    }
}

public struct CopyGlobalAgentModelsToProjectRequest: Codable, Hashable, Sendable {
    public let expectedGlobalRevision: Int64
    public let expectedProjectRevision: Int64

    public init(expectedGlobalRevision: Int64, expectedProjectRevision: Int64) {
        self.expectedGlobalRevision = expectedGlobalRevision
        self.expectedProjectRevision = expectedProjectRevision
    }
}

public struct CopyProjectAgentModelsToGlobalRequest: Codable, Hashable, Sendable {
    public let expectedGlobalRevision: Int64
    public let expectedProjectRevision: Int64

    public init(expectedGlobalRevision: Int64, expectedProjectRevision: Int64) {
        self.expectedGlobalRevision = expectedGlobalRevision
        self.expectedProjectRevision = expectedProjectRevision
    }
}

public struct ApplyAgentModelRecommendationsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64

    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }
}

public struct MCPAgentTaskLabel: Codable, Hashable, Sendable {
    public let label: String
    public let description: String
    public let modelID: String
    public let name: String
    public let recommendedModelID: String
    public let recommendedName: String
    public let hasCustomOverride: Bool
    public let overrideUnavailable: Bool

    public init(
        label: String,
        description: String,
        modelID: String,
        name: String,
        recommendedModelID: String,
        recommendedName: String,
        hasCustomOverride: Bool,
        overrideUnavailable: Bool
    ) {
        self.label = label
        self.description = description
        self.modelID = modelID
        self.name = name
        self.recommendedModelID = recommendedModelID
        self.recommendedName = recommendedName
        self.hasCustomOverride = hasCustomOverride
        self.overrideUnavailable = overrideUnavailable
    }

    enum CodingKeys: String, CodingKey {
        case label, description, name
        case modelID = "model_id"
        case recommendedModelID = "recommended_model_id"
        case recommendedName = "recommended_name"
        case hasCustomOverride = "has_custom_override"
        case overrideUnavailable = "override_unavailable"
    }
}

public struct MCPDiscoveredAgentModel: Codable, Hashable, Sendable {
    public let modelID: String
    public let name: String
    public let reasoningEffort: String?

    public init(modelID: String, name: String, reasoningEffort: String? = nil) {
        self.modelID = modelID
        self.name = name
        self.reasoningEffort = reasoningEffort
    }

    enum CodingKeys: String, CodingKey {
        case name
        case modelID = "model_id"
        case reasoningEffort = "reasoning_effort"
    }
}

public struct MCPDiscoveredAgent: Codable, Hashable, Sendable {
    public let name: String
    public let available: Bool
    public let capabilities: [String]
    public let models: [MCPDiscoveredAgentModel]
    public let defaultModelID: String?

    public init(
        name: String,
        available: Bool,
        capabilities: [String],
        models: [MCPDiscoveredAgentModel],
        defaultModelID: String?
    ) {
        self.name = name
        self.available = available
        self.capabilities = capabilities
        self.models = models
        self.defaultModelID = defaultModelID
    }

    enum CodingKeys: String, CodingKey {
        case name, available, capabilities, models
        case defaultModelID = "default_model_id"
    }
}

public struct MCPAgentDiscoverySnapshot: Codable, Hashable, Sendable {
    public let taskLabels: [MCPAgentTaskLabel]
    public let agents: [MCPDiscoveredAgent]?
    public let roleModelRestrictionApplied: Bool

    public init(
        taskLabels: [MCPAgentTaskLabel],
        agents: [MCPDiscoveredAgent]?,
        roleModelRestrictionApplied: Bool
    ) {
        self.taskLabels = taskLabels
        self.agents = agents
        self.roleModelRestrictionApplied = roleModelRestrictionApplied
    }

    enum CodingKeys: String, CodingKey {
        case agents
        case taskLabels = "task_labels"
        case roleModelRestrictionApplied = "role_model_restriction_applied"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskLabels, forKey: .taskLabels)
        try container.encodeIfPresent(agents, forKey: .agents)
        try container.encode(roleModelRestrictionApplied, forKey: .roleModelRestrictionApplied)
    }
}
