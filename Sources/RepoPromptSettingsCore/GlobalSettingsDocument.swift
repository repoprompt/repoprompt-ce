import Foundation
import RepoPromptDomainRuntime
import RepoPromptFoundation

/// Persisted, non-secret record that the user explicitly connected Claude account usage for one
/// Claude config profile. It holds no token, account identifier, or token-derived value. A grant
/// for a different profile than the active one is inert; it is only ever written from the UI.
package struct ClaudeAccountUsageGrant: Codable, Equatable {
    /// Canonical Claude config-directory identity (e.g. resolved `CLAUDE_CONFIG_DIR` path).
    package let credentialProfileID: String
    package let grantedAt: Date

    package init(credentialProfileID: String, grantedAt: Date) {
        self.credentialProfileID = credentialProfileID
        self.grantedAt = grantedAt
    }

    package func applies(toProfileID profileID: String) -> Bool {
        !credentialProfileID.isEmpty && credentialProfileID == profileID
    }
}

/// Explicit consent for the CLI-owned usage collector; legacy OAuth grants never authorize it.
package struct ClaudeCLIUsageGrant: Codable, Equatable {
    package let credentialProfileID: String
    package let grantedAt: Date
    package let consentVersion: Int
    /// Older connected grants remain readable; a new deferred setup explicitly stores false.
    package var setupCompleted: Bool?

    package init(credentialProfileID: String, grantedAt: Date, consentVersion: Int = 1, setupCompleted: Bool = true) {
        self.credentialProfileID = credentialProfileID
        self.grantedAt = grantedAt
        self.consentVersion = consentVersion
        self.setupCompleted = setupCompleted
    }

    package var isReady: Bool {
        setupCompleted != false
    }

    package func applies(toProfileID profileID: String) -> Bool {
        consentVersion == 1 && !credentialProfileID.isEmpty && credentialProfileID == profileID
    }
}

private func sanitizedAdditionalOracleModelRaws(_ raws: [String]) -> [String] {
    OracleRosterContract.sanitizedAdditionalModelIDs(raws)
}

private func strictAdditionalOracleModelRaws(_ raws: [String], codingPath: [CodingKey]) throws -> [String] {
    do {
        return try OracleRosterContract.normalizedAdditionalModelIDs(raws)
    } catch {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Invalid additional Oracle models: \(error.localizedDescription)"
            )
        )
    }
}

/// Versioned JSON document stored at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
///
/// Schema v1 contains copy settings, chat settings, and cross-workspace global
/// defaults. Schema v2 adds optional scalar preference groups. Schema v4 adds
/// workspace-scoped Agent Models profiles. Schema v5 fences the Context Builder
/// behavior group from pre-Context-Builder typed writers. Schema v7 adds the Oracle
/// roster. Schema v8 adds OpenCode-style ACP parameter pins to Agent Models profiles.
/// Schema v9 adds the optional app-global model-router policy group. Schema v10
/// adds global primary/subagent scope policy and custom router guidance.
/// Scalar fields stay optional so missing JSON fields fall back through the
/// typed GlobalSettingsStore accessors without losing current default behavior.
package struct GlobalSettingsDocument: Codable {
    /// Fixed feature-version constants are permanent compatibility boundaries. Add a new
    /// constant for each schema-requiring feature; never infer an existing feature's minimum
    /// version from `currentSchemaVersion`.
    package static let baselineSchemaVersion = 2
    package static let workspaceAgentModelsSchemaVersion = 4
    /// Context Builder behavior was introduced after the released v1.3 typed codec.
    /// Keep it above that codec's supported v4 so older writers reject the document
    /// before their typed save can silently drop the group.
    package static let contextBuilderSchemaVersion = 5
    package static let oracleRosterSchemaVersion = 7
    /// OpenCode-style ACP parameter pins stored on Agent Models profiles.
    package static let agentModelParameterPinsSchemaVersion = 8
    /// Initial optional app-global model-router configuration.
    package static let modelRouterSchemaVersion = 9
    package static let scopedModelRouterSchemaVersion = 10
    package static let rejectedExperimentalSchemaVersions = 6 ... 6
    package static let currentSchemaVersion = 10
    /// Lineage marker for settings files written by this open-source CE schema family.
    ///
    /// CE inherited numeric schema versions from classic/internal builds, so version numbers
    /// alone are not globally meaningful. Unlineaged v1/v2 files are accepted as legacy CE
    /// documents; unlineaged higher versions are treated as foreign/future documents even if
    /// this fork later reaches the same numeric schema version.
    package static let schemaLineage = "repoprompt-ce.global-settings"
    /// FROZEN at 2 forever: this is the last schema version OSS CE wrote without
    /// a lineage marker. It must never track `currentSchemaVersion`.
    package static let legacyUnlineagedSchemaVersionCeiling = 2

    package var schemaVersion: Int
    package var schemaLineage: String?
    package var updatedAt: Date
    package var copySettingsByWorkspaceID: [String: CopyGlobalSettings]
    package var chatSettingsByWorkspaceID: [String: ChatGlobalSettings]
    package var agentModelsSettingsByWorkspaceID: [String: WorkspaceAgentModelsSettings]?
    package var globalDefaults: GlobalDefaults
    package var scalarPreferences: GlobalScalarPreferences?

    package init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        copySettings: [UUID: CopyGlobalSettings] = [:],
        chatSettings: [UUID: ChatGlobalSettings] = [:],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] = [:],
        globalDefaults: GlobalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
        scalarPreferences: GlobalScalarPreferences? = nil
    ) {
        self.schemaVersion = schemaVersion
        schemaLineage = Self.schemaLineage
        self.updatedAt = updatedAt
        copySettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(copySettings)
        chatSettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(chatSettings)
        agentModelsSettingsByWorkspaceID = agentModelsSettings.isEmpty
            ? nil
            : Self.encodeUUIDKeyedDictionary(agentModelsSettings)
        self.globalDefaults = globalDefaults
        self.scalarPreferences = scalarPreferences
    }

    package var copySettings: [UUID: CopyGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(copySettingsByWorkspaceID)
    }

    package var chatSettings: [UUID: ChatGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(chatSettingsByWorkspaceID)
    }

    package var agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] {
        Self.decodeUUIDKeyedDictionary(agentModelsSettingsByWorkspaceID ?? [:])
    }

    /// Lowest CE schema version that can faithfully represent this document's content.
    ///
    /// Each feature contributes its own fixed introduction version. Future schema bumps must
    /// add another feature constant and participate in this maximum; they must not change the
    /// minimum version of content that existing features already know how to represent.
    package var requiredSchemaVersion: Int {
        var requiredVersion = Self.baselineSchemaVersion
        if let agentModelsSettingsByWorkspaceID, !agentModelsSettingsByWorkspaceID.isEmpty {
            requiredVersion = max(requiredVersion, Self.workspaceAgentModelsSchemaVersion)
        }
        if scalarPreferences?.contextBuilder != nil {
            requiredVersion = max(requiredVersion, Self.contextBuilderSchemaVersion)
        }
        let hasGlobalOracleRoster = scalarPreferences?.modelSelection?.additionalOracleModels?.isEmpty == false
        let hasWorkspaceOracleRoster = agentModelsSettings.values.contains { settings in
            settings.profile?.additionalOracleModelRaws.isEmpty == false
        }
        if hasGlobalOracleRoster || hasWorkspaceOracleRoster {
            requiredVersion = max(requiredVersion, Self.oracleRosterSchemaVersion)
        }
        let hasGlobalParameterPins = globalDefaults.mcpAgentRoleModelParameters?.isEmpty == false
            || globalDefaults.contextBuilderModelParametersByAgent?.isEmpty == false
        let hasWorkspaceParameterPins = agentModelsSettings.values.contains { settings in
            settings.profile?.mcpAgentRoleModelParameters?.isEmpty == false
                || settings.profile?.contextBuilderModelParametersByAgent?.isEmpty == false
        }
        if hasGlobalParameterPins || hasWorkspaceParameterPins {
            requiredVersion = max(requiredVersion, Self.agentModelParameterPinsSchemaVersion)
        }
        if let router = scalarPreferences?.modelRouter {
            requiredVersion = max(requiredVersion, Self.modelRouterSchemaVersion)
            if router.primaryProviderRawValue != nil
                || router.subagentProviderRawValue != nil
                || router.customInstructions != nil
            {
                requiredVersion = max(requiredVersion, Self.scopedModelRouterSchemaVersion)
            }
        }
        return requiredVersion
    }

    package func replacing(
        copySettings: [UUID: CopyGlobalSettings],
        chatSettings: [UUID: ChatGlobalSettings],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences? = nil,
        updatedAt: Date = Date()
    ) -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            schemaVersion: Self.currentSchemaVersion,
            updatedAt: updatedAt,
            copySettings: copySettings,
            chatSettings: chatSettings,
            agentModelsSettings: agentModelsSettings,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences ?? self.scalarPreferences
        )
    }

    private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
        values.reduce(into: [String: Value]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
    }

    private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
        var winners: [UUID: (rawKey: String, value: Value)] = [:]
        for rawKey in values.keys.sorted() {
            guard let uuid = UUID(uuidString: rawKey), let value = values[rawKey] else { continue }
            let canonicalKey = uuid.uuidString
            if winners[uuid] == nil || rawKey == canonicalKey {
                winners[uuid] = (rawKey, value)
            }
        }
        return winners.mapValues(\.value)
    }
}

// MARK: - Scoped Agent Models Settings

package enum AgentModelsInheritanceMode: String, Codable, Equatable {
    case useGlobalSettings
    case useWorkspaceOverrides
}

package enum AgentModelsEditingScope: Hashable {
    case global
    case workspace(UUID)

    package static func resolve(
        workspaceID: UUID?,
        inheritanceMode: AgentModelsInheritanceMode
    ) -> AgentModelsEditingScope {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else { return .global }
        return .workspace(workspaceID)
    }
}

/// Stable identity for one Agent Models operation. The source workspace drives
/// workspace-local wizard bookkeeping while `scope` is the exact durable profile
/// the operation may read or mutate.
package struct AgentModelsOperationIdentity: Hashable {
    package let sourceWorkspaceID: UUID
    package let scope: AgentModelsEditingScope

    package init(sourceWorkspaceID: UUID, scope: AgentModelsEditingScope) {
        self.sourceWorkspaceID = sourceWorkspaceID
        self.scope = scope
    }

    package init(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) {
        self.sourceWorkspaceID = sourceWorkspaceID
        scope = AgentModelsEditingScope.resolve(
            workspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }

    package func matches(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) -> Bool {
        self == AgentModelsOperationIdentity(
            sourceWorkspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }
}

package enum ContextBuilderSettingsWriteIntent {
    case preserveExistingOwnership
    case userInitiated
    case automaticSeed
}

package struct AgentModelsSettingsProfile: Codable, Equatable {
    package var planningModelRaw: String?
    package var additionalOracleModelRaws: [String]
    package var preferredComposeModelRaw: String?
    package var syncChatModelWithOracle: Bool
    package var contextBuilderAgentRaw: String?
    package var contextBuilderModelsByAgent: [String: String]?
    package var mcpAgentRoleOverrides: [String: String]?
    package var restrictMCPAgentDiscoveryToRoleLabels: Bool
    /// OpenCode-style ACP parameter pins per Sub-Agent role. Keys are `TaskLabelKind`
    /// rawValues; values are model-scoped selections, so a pin only survives while its role's
    /// stored override still resolves to the same provider and canonical model.
    package var mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]?
    /// OpenCode-style ACP parameter pins per Context Builder agent. Keys are
    /// `SettingsAgentKind` rawValues, mirroring `contextBuilderModelsByAgent`.
    package var contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]?

    package init(
        planningModelRaw: String? = nil,
        additionalOracleModelRaws: [String] = [],
        preferredComposeModelRaw: String? = nil,
        syncChatModelWithOracle: Bool = false,
        contextBuilderAgentRaw: String? = nil,
        contextBuilderModelsByAgent: [String: String]? = nil,
        mcpAgentRoleOverrides: [String: String]? = nil,
        restrictMCPAgentDiscoveryToRoleLabels: Bool = false,
        mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]? = nil,
        contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]? = nil
    ) {
        self.planningModelRaw = Self.normalizedChatModelRaw(planningModelRaw)
        self.additionalOracleModelRaws = sanitizedAdditionalOracleModelRaws(additionalOracleModelRaws)
        self.preferredComposeModelRaw = Self.normalizedChatModelRaw(preferredComposeModelRaw)
        self.syncChatModelWithOracle = syncChatModelWithOracle
        self.contextBuilderAgentRaw = Self.normalizedAgentRaw(contextBuilderAgentRaw)
        let normalizedModelsByAgent = Self.normalizedContextBuilderModelsByAgent(contextBuilderModelsByAgent)
        self.contextBuilderModelsByAgent = normalizedModelsByAgent
        let normalizedRoleOverrides = Self.normalizedStringMap(mcpAgentRoleOverrides)
        self.mcpAgentRoleOverrides = normalizedRoleOverrides
        self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
        self.mcpAgentRoleModelParameters = Self.coherentRoleModelParameters(
            mcpAgentRoleModelParameters,
            roleOverrides: normalizedRoleOverrides
        )
        self.contextBuilderModelParametersByAgent = Self.coherentContextBuilderModelParameters(
            contextBuilderModelParametersByAgent,
            modelsByAgent: normalizedModelsByAgent
        )
    }

    private enum CodingKeys: String, CodingKey {
        case planningModelRaw
        case additionalOracleModelRaws
        case preferredComposeModelRaw
        case syncChatModelWithOracle
        case contextBuilderAgentRaw
        case contextBuilderModelsByAgent
        case mcpAgentRoleOverrides
        case restrictMCPAgentDiscoveryToRoleLabels
        case mcpAgentRoleModelParameters
        case contextBuilderModelParametersByAgent
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let additional = try strictAdditionalOracleModelRaws(
            container.decodeIfPresent([String].self, forKey: .additionalOracleModelRaws) ?? [],
            codingPath: container.codingPath + [CodingKeys.additionalOracleModelRaws]
        )
        planningModelRaw = try Self.normalizedChatModelRaw(
            container.decodeIfPresent(String.self, forKey: .planningModelRaw)
        )
        additionalOracleModelRaws = additional
        preferredComposeModelRaw = try Self.normalizedChatModelRaw(
            container.decodeIfPresent(String.self, forKey: .preferredComposeModelRaw)
        )
        syncChatModelWithOracle = try container.decodeIfPresent(Bool.self, forKey: .syncChatModelWithOracle) ?? false
        contextBuilderAgentRaw = try Self.normalizedAgentRaw(
            container.decodeIfPresent(String.self, forKey: .contextBuilderAgentRaw)
        )
        contextBuilderModelsByAgent = try Self.normalizedContextBuilderModelsByAgent(
            container.decodeIfPresent([String: String].self, forKey: .contextBuilderModelsByAgent)
        )
        let roleOverrides = try Self.normalizedStringMap(
            container.decodeIfPresent([String: String].self, forKey: .mcpAgentRoleOverrides)
        )
        mcpAgentRoleOverrides = roleOverrides
        restrictMCPAgentDiscoveryToRoleLabels = try container.decodeIfPresent(
            Bool.self,
            forKey: .restrictMCPAgentDiscoveryToRoleLabels
        ) ?? false
        mcpAgentRoleModelParameters = try Self.coherentRoleModelParameters(
            container.decodeIfPresent([String: [ACPModelParameterSelection]].self, forKey: .mcpAgentRoleModelParameters),
            roleOverrides: roleOverrides
        )
        contextBuilderModelParametersByAgent = try Self.coherentContextBuilderModelParameters(
            container.decodeIfPresent(
                [String: [ACPModelParameterSelection]].self,
                forKey: .contextBuilderModelParametersByAgent
            ),
            modelsByAgent: contextBuilderModelsByAgent
        )
    }

    /// Single owner of the role-pin↔role-model relationship. A stored pin survives only while
    /// its role still has a stored override resolving to the same provider and canonical model.
    /// This runs on every construction and decode, so every writer — the Settings view model,
    /// the static role service, recommendations, resets and MCP — gets cleanup for free without
    /// any of them enforcing it. Persisted identities only: transient availability never erases
    /// explicit intent.
    private static func coherentRoleModelParameters(
        _ buckets: [String: [ACPModelParameterSelection]]?,
        roleOverrides: [String: String]?
    ) -> [String: [ACPModelParameterSelection]]? {
        guard let buckets else { return nil }
        var coherent: [String: [ACPModelParameterSelection]] = [:]
        for rawKey in buckets.keys.sorted() {
            guard let key = trimmedNonEmpty(rawKey),
                  let selectionID = roleOverrides?[key].flatMap(AgentModelSelectionID.parse),
                  let providerID = SettingsAgentKind(rawValue: selectionID.agentRaw)?.acpProviderID,
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: selectionID.modelRaw,
                from: selections
            )
            guard !matching.isEmpty || (providerID == .cursor && selections.contains { $0.providerID == .cursor }) else { continue }
            // Cursor stores per-model memory; reads and requests still filter to the active model.
            coherent[key] = providerID == .cursor
                ? ACPModelParameterSelection.normalized(selections.filter { $0.providerID == .cursor })
                : matching
        }
        return coherent.isEmpty ? nil : coherent
    }

    /// Single owner of the Context Builder pin↔model relationship. Mirrors
    /// `coherentRoleModelParameters` for the agent-keyed Context Builder bucket.
    private static func coherentContextBuilderModelParameters(
        _ buckets: [String: [ACPModelParameterSelection]]?,
        modelsByAgent: [String: String]?
    ) -> [String: [ACPModelParameterSelection]]? {
        guard let buckets else { return nil }
        var coherent: [String: [ACPModelParameterSelection]] = [:]
        for rawKey in buckets.keys.sorted() {
            guard let key = trimmedNonEmpty(rawKey),
                  let providerID = SettingsAgentKind(rawValue: key)?.acpProviderID,
                  let modelRaw = modelsByAgent?[key],
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: modelRaw,
                from: selections
            )
            guard !matching.isEmpty || (providerID == .cursor && selections.contains { $0.providerID == .cursor }) else { continue }
            // Cursor stores per-model memory; reads and requests still filter to the active model.
            coherent[key] = providerID == .cursor
                ? ACPModelParameterSelection.normalized(selections.filter { $0.providerID == .cursor })
                : matching
        }
        return coherent.isEmpty ? nil : coherent
    }

    /// The Context Builder pin for a resolved agent + model, requiring the persisted explicit
    /// CB agent to match. The single eligibility rule for the CB bucket, shared by the display
    /// getters, the setter, and the run-side filter — so all four agree by construction.
    package func contextBuilderModelParameterSelections(
        forAgentIdentity agent: SettingsAgentKind,
        modelRaw: String
    ) -> [ACPModelParameterSelection] {
        guard let providerID = agent.acpProviderID,
              contextBuilderAgentRaw == agent.rawValue,
              let bucket = contextBuilderModelParametersByAgent?[agent.rawValue]
        else { return [] }
        return ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: modelRaw,
            from: bucket
        )
    }

    /// Whether a stored **role** bucket belongs to the selection currently on screen. Clearing a
    /// role pin uses the same model-scoped rule as reading one, so a displayed availability
    /// fallback can never delete intent retained for a different model. Context Builder has a
    /// stricter rule and clears through `contextBuilderModelParameterSelections` instead.
    private static func bucketBelongsToDisplayedSelection(
        _ bucket: [ACPModelParameterSelection]?,
        agentRaw: String,
        modelRaw: String
    ) -> Bool {
        guard let bucket, !bucket.isEmpty else { return false }
        guard let providerID = SettingsAgentKind(rawValue: agentRaw)?.acpProviderID else { return false }
        return !ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: modelRaw,
            from: bucket
        ).isEmpty
    }

    package func replacingContextBuilderModel(_ modelRaw: String?, for agentRaw: String?) -> AgentModelsSettingsProfile {
        let resolvedAgentRaw = Self.normalizedAgentRaw(agentRaw) ?? contextBuilderAgentRaw
        guard let resolvedAgentRaw else { return self }

        var next = self
        var modelsByAgent = contextBuilderModelsByAgent ?? [:]
        if let normalizedModelRaw = Self.trimmedNonEmpty(modelRaw) {
            modelsByAgent[resolvedAgentRaw] = normalizedModelRaw
        } else {
            modelsByAgent[resolvedAgentRaw] = nil
        }
        next.contextBuilderModelsByAgent = modelsByAgent.isEmpty ? nil : modelsByAgent
        return next
    }

    /// Atomic role-pin write: persist the displayed selection as the role override and
    /// set/clear the pin bucket in one profile mutation. The two must move together — a pin
    /// written against a merely-recommended (not overridden) model would be dropped as
    /// ineligible the instant it is saved. Coherence re-runs at the persistence boundary, so
    /// the displayed override and the bucket cannot disagree once saved.
    package func replacingRoleModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        for roleRawValue: String,
        displayedSelectionID: AgentModelSelectionID
    ) -> AgentModelsSettingsProfile {
        var next = self
        // Only a real pin commits the displayed model choice. Clearing must not: the chip offers
        // "Default" even for a role that is still tracking its recommendation, and writing the
        // override there would silently stop that role tracking because the user opened a menu
        // and re-picked the item already selected.
        if let selections, !selections.isEmpty {
            var overrides = next.mcpAgentRoleOverrides ?? [:]
            overrides[roleRawValue] = displayedSelectionID.rawValue
            next.mcpAgentRoleOverrides = overrides.isEmpty ? nil : overrides
        }
        var pins = next.mcpAgentRoleModelParameters ?? [:]
        if let selections, !selections.isEmpty {
            pins[roleRawValue] = ACPModelParameterSelection.normalized(selections)
        } else if Self.bucketBelongsToDisplayedSelection(
            pins[roleRawValue],
            agentRaw: displayedSelectionID.agentRaw,
            modelRaw: displayedSelectionID.modelRaw
        ) {
            // Clearing is scoped to the displayed model, exactly as reading is. A role whose
            // stored model is currently unavailable displays a recommended fallback, so
            // "Default" is already checked there — selecting it must not delete the pin that is
            // still retained for the model the user actually chose.
            pins[roleRawValue] = nil
        }
        next.mcpAgentRoleModelParameters = pins.isEmpty ? nil : pins
        return next
    }

    /// Atomic Context Builder pin write: persist the displayed agent+model choice and
    /// set/clear that agent's pin bucket in one profile mutation. Mirrors
    /// `replacingRoleModelParameter` for the Context Builder surface.
    package func replacingContextBuilderModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        for agentRaw: String?,
        modelRaw: String
    ) -> AgentModelsSettingsProfile {
        let resolvedAgentRaw = Self.normalizedAgentRaw(agentRaw) ?? contextBuilderAgentRaw
        guard let resolvedAgentRaw else { return self }

        // Same rule as the role bucket: only a real pin commits the displayed agent+model choice,
        // so clearing cannot quietly adopt a runtime fallback as the persisted selection.
        var next = self
        if let selections, !selections.isEmpty {
            next = replacingContextBuilderModel(modelRaw, for: resolvedAgentRaw)
            next.contextBuilderAgentRaw = resolvedAgentRaw
        }
        var pins = next.contextBuilderModelParametersByAgent ?? [:]
        if let selections, !selections.isEmpty {
            pins[resolvedAgentRaw] = ACPModelParameterSelection.normalized(selections)
        } else if let resolvedAgent = SettingsAgentKind(rawValue: resolvedAgentRaw),
                  !contextBuilderModelParameterSelections(
                      forAgentIdentity: resolvedAgent,
                      modelRaw: modelRaw
                  ).isEmpty
        {
            // Clear through the *read* predicate, not a parallel copy of it. Context Builder
            // eligibility is stricter than the role rule: it also requires the bucket's agent to
            // be the persisted Context Builder agent, because buckets for other agents are
            // deliberately retained as per-agent memory. Re-deriving that here would be a second
            // owner of the rule, and the first attempt at it missed exactly this condition — a
            // Default click on a displayed availability fallback deleted a bucket invisible to
            // every read and run.
            pins[resolvedAgentRaw] = nil
        }
        next.contextBuilderModelParametersByAgent = pins.isEmpty ? nil : pins
        return next
    }

    private static func normalizedChatModelRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedAgentRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedContextBuilderModelsByAgent(_ values: [String: String]?) -> [String: String]? {
        normalizedStringMap(values)
    }

    private static func normalizedStringMap(_ values: [String: String]?) -> [String: String]? {
        guard let values else { return nil }
        let normalized = values.keys.sorted().reduce(into: [String: String]()) { result, rawKey in
            guard let key = trimmedNonEmpty(rawKey),
                  let value = trimmedNonEmpty(values[rawKey])
            else {
                return
            }
            result[key] = value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

package struct WorkspaceAgentModelsSettings: Codable, Equatable {
    package var inheritanceMode: AgentModelsInheritanceMode
    package var profile: AgentModelsSettingsProfile?

    package init(
        inheritanceMode: AgentModelsInheritanceMode = .useGlobalSettings,
        profile: AgentModelsSettingsProfile? = nil
    ) {
        self.inheritanceMode = inheritanceMode
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case inheritanceMode, profile
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inheritanceMode = try container.decodeIfPresent(AgentModelsInheritanceMode.self, forKey: .inheritanceMode)
            ?? .useGlobalSettings
        profile = try container.decodeIfPresent(AgentModelsSettingsProfile.self, forKey: .profile)
    }
}

// MARK: - Worktree Visual Identity

package enum WorktreeVisualMarkerStyle: String, Codable, Equatable {
    case dot
    case ring
    case capsule
}

package struct WorktreeVisualIdentity: Codable, Equatable {
    package static let defaultIconName = "circle.fill"
    package static let defaultMarkerStyle = WorktreeVisualMarkerStyle.dot

    package var label: String?
    package var colorHex: String
    package var iconName: String
    package var markerStyle: WorktreeVisualMarkerStyle
    package var updatedAt: Date?

    package init(
        label: String? = nil,
        colorHex: String,
        iconName: String = Self.defaultIconName,
        markerStyle: WorktreeVisualMarkerStyle = Self.defaultMarkerStyle,
        updatedAt: Date? = nil
    ) {
        self.label = label
        self.colorHex = colorHex
        self.iconName = iconName
        self.markerStyle = markerStyle
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case label, colorHex, iconName, markerStyle, updatedAt
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? Self.defaultIconName
        markerStyle = try container.decodeIfPresent(WorktreeVisualMarkerStyle.self, forKey: .markerStyle) ?? Self.defaultMarkerStyle
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

package struct WorktreeVisualIdentityRepositoryBucket: Codable, Equatable {
    package var identitiesByWorktreeID: [String: WorktreeVisualIdentity]

    package init(identitiesByWorktreeID: [String: WorktreeVisualIdentity] = [:]) {
        self.identitiesByWorktreeID = identitiesByWorktreeID
    }
}

// MARK: - Scalar Preferences

/// Optional scalar preferences stored in schema v2.
///
/// Keep groups and fields optional so missing values continue to use the same
/// defaults as the typed settings accessors.
package struct GlobalScalarPreferences: Codable, Equatable {
    package var ui: UISettings?
    package var promptPackaging: PromptPackagingSettings?
    package var modelSelection: ModelSelectionSettings?
    package var contextBuilder: ContextBuilderSettings?
    package var mcp: MCPSettings?
    package var fileSystem: FileSystemSettings?
    package var agentMode: AgentModeSettings?
    package var telemetry: TelemetrySettings?
    package var modelOverrides: ModelOverrideSettingsData?
    package var modelRouter: ModelRouterSettings?
    /// Additive, schema-neutral group: every field is optional and typed readers fall back to
    /// `NotificationPreferences.defaults`. Older typed readers ignore the unknown key, and the
    /// raw-preserving save path keeps it, so it deliberately does not raise `requiredSchemaVersion`.
    package var notifications: NotificationSettings?

    package init(
        ui: UISettings? = nil,
        promptPackaging: PromptPackagingSettings? = nil,
        modelSelection: ModelSelectionSettings? = nil,
        contextBuilder: ContextBuilderSettings? = nil,
        mcp: MCPSettings? = nil,
        fileSystem: FileSystemSettings? = nil,
        agentMode: AgentModeSettings? = nil,
        telemetry: TelemetrySettings? = nil,
        modelOverrides: ModelOverrideSettingsData? = nil,
        modelRouter: ModelRouterSettings? = nil,
        notifications: NotificationSettings? = nil
    ) {
        self.ui = ui
        self.promptPackaging = promptPackaging
        self.modelSelection = modelSelection
        self.contextBuilder = contextBuilder
        self.mcp = mcp
        self.fileSystem = fileSystem
        self.agentMode = agentMode
        self.telemetry = telemetry
        self.modelOverrides = modelOverrides
        self.modelRouter = modelRouter
        self.notifications = notifications
    }

    package struct NotificationSettings: Codable, Equatable {
        package var enabled: Bool?
        package var agentInteractions: Bool?
        package var agentInstructionWaits: Bool?
        package var agentTurnComplete: Bool?
        package var agentTurnFailed: Bool?
        package var chatComplete: Bool?
        package var contextBuilderComplete: Bool?
        package var approveFromNotifications: Bool?
        package var answerFromNotifications: Bool?
        package var replyFromCompletion: Bool?
        package var showDetails: Bool?
        package var notifyWhileActive: Bool?
        package var completionsWhileActive: Bool?
        package var includeAgentDrivenSessions: Bool?
        package var dockBadge: Bool?
        package var mcpAskUserNotifyInsteadOfActivate: Bool?

        package init() {}

        // Resolves stored overrides over the product defaults.
    }

    package struct ModelRouterSettings: Codable, Equatable {
        package var enabled: Bool?
        package var selectedBackendRawValue: String?
        package var candidateRoleRawValues: [String]?
        package var allowedProviderRawValues: [String]?
        package var primaryProviderRawValue: String?
        package var subagentProviderRawValue: String?
        package var customInstructions: String?
        package var usageBalancingEnabled: Bool?
        package var usageBalancingPreset: String?
        package var usageLargerPlan: String? // Legacy value retained for lossless settings round trips; no longer used.
        package var allowPaidFastRouting: Bool?

        package init(
            enabled: Bool? = nil,
            selectedBackendRawValue: String? = nil,
            candidateRoleRawValues: [String]? = nil,
            allowedProviderRawValues: [String]? = nil,
            primaryProviderRawValue: String? = nil,
            subagentProviderRawValue: String? = nil,
            customInstructions: String? = nil
        ) {
            self.enabled = enabled
            self.selectedBackendRawValue = selectedBackendRawValue
            self.candidateRoleRawValues = candidateRoleRawValues
            self.allowedProviderRawValues = allowedProviderRawValues
            self.primaryProviderRawValue = primaryProviderRawValue
            self.subagentProviderRawValue = subagentProviderRawValue
            self.customInstructions = customInstructions
        }
    }

    package struct UISettings: Codable, Equatable {
        package var appearanceMode: String?
        package var useTransparency: Bool?
        package var collapseLatestFileChanges: Bool?
        package var showTooltips: Bool?
        package var experimentalAttributedTextEditor: Bool?
        package var fileMentionPickerStyle: String?
        package var enableKeyboardShortcuts: Bool?
        package var fontScaleBodySize: Double?
        package var showDatesInMessageTimestamps: Bool?

        package init(
            appearanceMode: String? = nil,
            useTransparency: Bool? = nil,
            collapseLatestFileChanges: Bool? = nil,
            showTooltips: Bool? = nil,
            experimentalAttributedTextEditor: Bool? = nil,
            fileMentionPickerStyle: String? = nil,
            enableKeyboardShortcuts: Bool? = nil,
            fontScaleBodySize: Double? = nil,
            showDatesInMessageTimestamps: Bool? = nil
        ) {
            self.appearanceMode = appearanceMode
            self.useTransparency = useTransparency
            self.collapseLatestFileChanges = collapseLatestFileChanges
            self.showTooltips = showTooltips
            self.experimentalAttributedTextEditor = experimentalAttributedTextEditor
            self.fileMentionPickerStyle = fileMentionPickerStyle
            self.enableKeyboardShortcuts = enableKeyboardShortcuts
            self.fontScaleBodySize = fontScaleBodySize
            self.showDatesInMessageTimestamps = showDatesInMessageTimestamps
        }
    }

    package struct PromptPackagingSettings: Codable, Equatable {
        package var promptSectionsOrder: String?
        package var duplicateUserInstructionsAtTop: Bool?
        package var filePathDisplayOption: String?
        package var selectedFilesSortMethod: String?
        package var fileEditFormat: String?
        package var includeDatetimeInUserInstructions: Bool?
        package var customPlanningPrompt: String?
        package var modelTemperature: Double?
        package var setModelTemperature: Bool?
        package var complexEditStrategy: String?

        package init(
            promptSectionsOrder: String? = nil,
            duplicateUserInstructionsAtTop: Bool? = nil,
            filePathDisplayOption: String? = nil,
            selectedFilesSortMethod: String? = nil,
            fileEditFormat: String? = nil,
            includeDatetimeInUserInstructions: Bool? = nil,
            customPlanningPrompt: String? = nil,
            modelTemperature: Double? = nil,
            setModelTemperature: Bool? = nil,
            complexEditStrategy: String? = nil
        ) {
            self.promptSectionsOrder = promptSectionsOrder
            self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
            self.filePathDisplayOption = filePathDisplayOption
            self.selectedFilesSortMethod = selectedFilesSortMethod
            self.fileEditFormat = fileEditFormat
            self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
            self.customPlanningPrompt = customPlanningPrompt
            self.modelTemperature = modelTemperature
            self.setModelTemperature = setModelTemperature
            self.complexEditStrategy = complexEditStrategy
        }
    }

    package struct ModelSelectionSettings: Codable, Equatable {
        package var preferredComposeModel: String?
        package var planningModel: String?
        package var additionalOracleModels: [String]?
        package var syncChatModelWithOracle: Bool?

        package init(
            preferredComposeModel: String? = nil,
            planningModel: String? = nil,
            additionalOracleModels: [String]? = nil,
            syncChatModelWithOracle: Bool? = nil
        ) {
            self.preferredComposeModel = preferredComposeModel
            self.planningModel = planningModel
            self.additionalOracleModels = additionalOracleModels
            self.syncChatModelWithOracle = syncChatModelWithOracle
        }

        private enum CodingKeys: String, CodingKey {
            case preferredComposeModel
            case planningModel
            case additionalOracleModels
            case syncChatModelWithOracle
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preferredComposeModel = try container.decodeIfPresent(String.self, forKey: .preferredComposeModel)
            planningModel = try container.decodeIfPresent(String.self, forKey: .planningModel)
            if let values = try container.decodeIfPresent([String].self, forKey: .additionalOracleModels) {
                additionalOracleModels = try strictAdditionalOracleModelRaws(
                    values,
                    codingPath: container.codingPath + [CodingKeys.additionalOracleModels]
                )
            } else {
                additionalOracleModels = nil
            }
            syncChatModelWithOracle = try container.decodeIfPresent(Bool.self, forKey: .syncChatModelWithOracle)
        }
    }

    package struct ContextBuilderSettings: Codable, Equatable {
        package var contextTokenBudget: Int?
        package var analysisTokenBudget: Int?
        package var enhancementMode: String?
        package var questionTimeoutSeconds: TimeInterval?
        package var allowUIClarifyingQuestions: Bool?
        package var allowMCPClarifyingQuestions: Bool?
        package var followUpAnalysisEnabled: Bool?

        package init(
            contextTokenBudget: Int? = nil,
            analysisTokenBudget: Int? = nil,
            enhancementMode: String? = nil,
            questionTimeoutSeconds: TimeInterval? = nil,
            allowUIClarifyingQuestions: Bool? = nil,
            allowMCPClarifyingQuestions: Bool? = nil,
            followUpAnalysisEnabled: Bool? = nil
        ) {
            self.contextTokenBudget = contextTokenBudget
            self.analysisTokenBudget = analysisTokenBudget
            self.enhancementMode = enhancementMode
            self.questionTimeoutSeconds = questionTimeoutSeconds
            self.allowUIClarifyingQuestions = allowUIClarifyingQuestions
            self.allowMCPClarifyingQuestions = allowMCPClarifyingQuestions
            self.followUpAnalysisEnabled = followUpAnalysisEnabled
        }
    }

    package struct MCPSettings: Codable, Equatable {
        package var autoStart: Bool?
        package var showModelPresets: Bool?
        package var temporarilyDisablePresets: Bool?

        package init(
            autoStart: Bool? = nil,
            showModelPresets: Bool? = nil,
            temporarilyDisablePresets: Bool? = nil
        ) {
            self.autoStart = autoStart
            self.showModelPresets = showModelPresets
            self.temporarilyDisablePresets = temporarilyDisablePresets
        }
    }

    package struct FileSystemSettings: Codable, Equatable {
        package var respectRepoIgnore: Bool?
        package var respectCursorignore: Bool?
        package var globalIgnoreDefaults: String?
        package var enableHierarchicalIgnores: Bool?
        package var skipSymlinks: Bool?
        package var showEmptyFolders: Bool?

        package init(
            respectRepoIgnore: Bool? = nil,
            respectCursorignore: Bool? = nil,
            globalIgnoreDefaults: String? = nil,
            enableHierarchicalIgnores: Bool? = nil,
            skipSymlinks: Bool? = nil,
            showEmptyFolders: Bool? = nil
        ) {
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.globalIgnoreDefaults = globalIgnoreDefaults
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.skipSymlinks = skipSymlinks
            self.showEmptyFolders = showEmptyFolders
        }
    }

    package struct TelemetrySettings: Codable, Equatable {
        package var enabled: Bool?
        package var appHangReportsEnabled: Bool?
        package var performanceTracingEnabled: Bool?

        package init(
            enabled: Bool? = nil,
            appHangReportsEnabled: Bool? = nil,
            performanceTracingEnabled: Bool? = nil
        ) {
            self.enabled = enabled
            self.appHangReportsEnabled = appHangReportsEnabled
            self.performanceTracingEnabled = performanceTracingEnabled
        }
    }

    package struct ModelOverrideSettingsData: Codable, Equatable {
        package var diffOverrides: [String: Bool]?
        package var streamOverrides: [String: Bool]?
        package var temperatureOverrides: [String: Double]?
        package var responsesOverrides: [String: Bool]?

        package init(
            diffOverrides: [String: Bool]? = nil,
            streamOverrides: [String: Bool]? = nil,
            temperatureOverrides: [String: Double]? = nil,
            responsesOverrides: [String: Bool]? = nil
        ) {
            self.diffOverrides = diffOverrides
            self.streamOverrides = streamOverrides
            self.temperatureOverrides = temperatureOverrides
            self.responsesOverrides = responsesOverrides
        }
    }

    package struct AgentModeSettings: Codable, Equatable {
        package var proEditAgentMode: Bool?
        package var proEditAgentKind: String?
        package var proEditAgentModel: String?
        package var proEditAgentModeMigrated: Bool?
        // DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
        // Kept temporarily for decode/rollback compatibility only; do not read from UI/runtime.
        package var agentAutoExpandToolCards: Bool?
        // DEPRECATED: The background Agent compose-tab limit was removed in 2026-08.
        // Kept for decode/rollback compatibility and round-trip preservation only.
        package var maxBackgroundAgentComposeTabs: Int?
        package var showBuiltInWorkflowCleanupGuidance: Bool?
        package var codexGoalSupportEnabled: Bool?
        package var codexReasoningSummariesEnabled: Bool?
        package var autoEffortEnabled: Bool?
        package var codexMemoriesEnabled: Bool?
        package var codexAppsEnabled: Bool?
        package var codexPluginsEnabled: Bool?
        package var codexMCPElicitationEnabled: Bool?
        package var codexToolSuggestionsEnabled: Bool?
        package var codexHookApprovalStrictModeEnabled: Bool?
        package var codexHookApprovalStrictModeWorkspaceOverrides: [String: Bool]?
        /// Default-off opt-in flags only; quota readings themselves are never persisted.
        /// `codexUsageQuotaEnabled` authorizes the Codex app-server quota source.
        package var codexUsageQuotaEnabled: Bool?
        /// Legacy name. Gates passive Claude run rate-limit telemetry only; it never authorizes
        /// an account usage read and is never migrated into `claudeAccountUsageGrant`.
        package var claudeUsageQuotaEnabled: Bool?
        /// Master presentation switch ("Show usage limits when available"). `nil` means
        /// "never chosen"; the store derives it from the legacy per-provider flags.
        /// Presentation only: it never authorizes acquisition by itself.
        package var usageLimitsDisplayEnabled: Bool?
        /// Explicit, UI-only consent to read Claude account usage for one config profile.
        package var claudeAccountUsageGrant: ClaudeAccountUsageGrant?
        package var claudeCLIUsageGrant: ClaudeCLIUsageGrant?
        package var claudeBalancingRefreshGrant: ClaudeCLIUsageGrant?
        package var providerConversationCleanupAction: String?
        package var restrictMCPAgentDiscoveryToRoleLabels: Bool?
        package var agentSessionHandoffInstructions: String?
        package var subagentDefaultWaitSeconds: Int?

        package init(
            proEditAgentMode: Bool? = nil,
            proEditAgentKind: String? = nil,
            proEditAgentModel: String? = nil,
            proEditAgentModeMigrated: Bool? = nil,
            agentAutoExpandToolCards: Bool? = nil,
            maxBackgroundAgentComposeTabs: Int? = nil,
            showBuiltInWorkflowCleanupGuidance: Bool? = nil,
            codexGoalSupportEnabled: Bool? = nil,
            codexReasoningSummariesEnabled: Bool? = nil,
            autoEffortEnabled: Bool? = nil,
            codexMemoriesEnabled: Bool? = nil,
            codexAppsEnabled: Bool? = nil,
            codexPluginsEnabled: Bool? = nil,
            codexMCPElicitationEnabled: Bool? = nil,
            codexToolSuggestionsEnabled: Bool? = nil,
            codexHookApprovalStrictModeEnabled: Bool? = nil,
            codexHookApprovalStrictModeWorkspaceOverrides: [String: Bool]? = nil,
            codexUsageQuotaEnabled: Bool? = nil,
            claudeUsageQuotaEnabled: Bool? = nil,
            usageLimitsDisplayEnabled: Bool? = nil,
            claudeAccountUsageGrant: ClaudeAccountUsageGrant? = nil,
            claudeCLIUsageGrant: ClaudeCLIUsageGrant? = nil,
            providerConversationCleanupAction: String? = nil,
            restrictMCPAgentDiscoveryToRoleLabels: Bool? = nil,
            agentSessionHandoffInstructions: String? = nil,
            subagentDefaultWaitSeconds: Int? = nil
        ) {
            self.proEditAgentMode = proEditAgentMode
            self.proEditAgentKind = proEditAgentKind
            self.proEditAgentModel = proEditAgentModel
            self.proEditAgentModeMigrated = proEditAgentModeMigrated
            self.agentAutoExpandToolCards = agentAutoExpandToolCards
            self.maxBackgroundAgentComposeTabs = maxBackgroundAgentComposeTabs
            self.showBuiltInWorkflowCleanupGuidance = showBuiltInWorkflowCleanupGuidance
            self.codexGoalSupportEnabled = codexGoalSupportEnabled
            self.codexReasoningSummariesEnabled = codexReasoningSummariesEnabled
            self.autoEffortEnabled = autoEffortEnabled
            self.codexMemoriesEnabled = codexMemoriesEnabled
            self.codexAppsEnabled = codexAppsEnabled
            self.codexPluginsEnabled = codexPluginsEnabled
            self.codexMCPElicitationEnabled = codexMCPElicitationEnabled
            self.codexToolSuggestionsEnabled = codexToolSuggestionsEnabled
            self.codexHookApprovalStrictModeEnabled = codexHookApprovalStrictModeEnabled
            self.codexHookApprovalStrictModeWorkspaceOverrides = codexHookApprovalStrictModeWorkspaceOverrides
            self.codexUsageQuotaEnabled = codexUsageQuotaEnabled
            self.claudeUsageQuotaEnabled = claudeUsageQuotaEnabled
            self.usageLimitsDisplayEnabled = usageLimitsDisplayEnabled
            self.claudeAccountUsageGrant = claudeAccountUsageGrant
            self.claudeCLIUsageGrant = claudeCLIUsageGrant
            self.providerConversationCleanupAction = providerConversationCleanupAction
            self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
            self.agentSessionHandoffInstructions = agentSessionHandoffInstructions
            self.subagentDefaultWaitSeconds = subagentDefaultWaitSeconds
        }
    }
}
