import Foundation
import RepoPromptDomainRuntime

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
/// roster. Schema v8 adds OpenCode-style ACP parameter pins and app-wide external MCP
/// registrations. Schema v9 adds the model-router policy group and external MCP cleanup
/// tombstones. Schema v10 adds global primary/subagent scope policy and custom router guidance.
/// Scalar fields stay optional so missing JSON fields fall back through the typed
/// GlobalSettingsStore accessors without losing current default behavior.
struct GlobalSettingsDocument: Codable {
    /// Fixed feature-version constants are permanent compatibility boundaries. Add a new
    /// constant for each schema-requiring feature; never infer an existing feature's minimum
    /// version from `currentSchemaVersion`.
    static let baselineSchemaVersion = 2
    static let workspaceAgentModelsSchemaVersion = 4
    /// Context Builder behavior was introduced after the released v1.3 typed codec.
    /// Keep it above that codec's supported v4 so older writers reject the document
    /// before their typed save can silently drop the group.
    static let contextBuilderSchemaVersion = 5
    static let oracleRosterSchemaVersion = 7
    /// OpenCode-style ACP parameter pins stored on Agent Models profiles.
    static let agentModelParameterPinsSchemaVersion = 8
    /// Initial optional app-global model-router configuration.
    static let modelRouterSchemaVersion = 9
    static let scopedModelRouterSchemaVersion = 10
    static let rejectedExperimentalSchemaVersions = 6 ... 6
    /// Schema v8 adds optional, nonsecret app-wide external MCP connection registrations.
    /// Empty documents retain their earlier content-derived schema version for rollback compatibility.
    static let externalMCPConnectionsSchemaVersion = 8
    /// Schema v9 adds a disabled Settings-managed cleanup tombstone. Enabled registrations
    /// remain schema-v8 content so older builds retain rollback compatibility for active connections.
    static let externalMCPConnectionActivationSchemaVersion = 9
    static let currentSchemaVersion = 10
    /// Lineage marker for settings files written by this open-source CE schema family.
    ///
    /// CE inherited numeric schema versions from classic/internal builds, so version numbers
    /// alone are not globally meaningful. Unlineaged v1/v2 files are accepted as legacy CE
    /// documents; unlineaged higher versions are treated as foreign/future documents even if
    /// this fork later reaches the same numeric schema version.
    static let schemaLineage = "repoprompt-ce.global-settings"
    /// FROZEN at 2 forever: this is the last schema version OSS CE wrote without
    /// a lineage marker. It must never track `currentSchemaVersion`.
    static let legacyUnlineagedSchemaVersionCeiling = 2

    var schemaVersion: Int
    var schemaLineage: String?
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: CopyGlobalSettings]
    var chatSettingsByWorkspaceID: [String: ChatGlobalSettings]
    var agentModelsSettingsByWorkspaceID: [String: WorkspaceAgentModelsSettings]?
    /// App-scoped, nonsecret external MCP connection definitions. OAuth and other
    /// credential material deliberately never belongs in this document.
    var externalMCPConnections: [ExternalMCPIntegrationDefinition]?
    /// Decode-only compatibility storage for the retired workspace access policy. New documents
    /// always leave this nil, and decoded legacy content is discarded before it can affect runtime.
    var externalMCPAccessByWorkspaceID: [String: ExternalMCPWorkspaceAccessOverrides]?
    var globalDefaults: GlobalDefaults
    var scalarPreferences: GlobalScalarPreferences?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        copySettings: [UUID: CopyGlobalSettings] = [:],
        chatSettings: [UUID: ChatGlobalSettings] = [:],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] = [:],
        externalMCPConnections: [ExternalMCPIntegrationDefinition] = [],
        externalMCPAccessByWorkspaceID: [UUID: ExternalMCPWorkspaceAccessOverrides] = [:],
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
        let retainedConnections = externalMCPConnections.filter(\.isPersistableAppWideState)
        self.externalMCPConnections = retainedConnections.isEmpty ? nil : retainedConnections
        // Retired Figma workspace policy is intentionally never persisted.
        self.externalMCPAccessByWorkspaceID = nil
        self.globalDefaults = globalDefaults
        self.scalarPreferences = scalarPreferences
    }

    var copySettings: [UUID: CopyGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(copySettingsByWorkspaceID)
    }

    var chatSettings: [UUID: ChatGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(chatSettingsByWorkspaceID)
    }

    var agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] {
        Self.decodeUUIDKeyedDictionary(agentModelsSettingsByWorkspaceID ?? [:])
    }

    var externalMCPWorkspaceAccess: [UUID: ExternalMCPWorkspaceAccessOverrides] {
        [:]
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case schemaLineage
        case updatedAt
        case copySettingsByWorkspaceID
        case chatSettingsByWorkspaceID
        case agentModelsSettingsByWorkspaceID
        case externalMCPConnections
        case externalMCPAccessByWorkspaceID
        case globalDefaults
        case scalarPreferences
    }

    /// Top-level keys owned by this schema. File-store preservation may retain only keys outside
    /// this set when the newly encoded document omits an optional known field.
    static let knownTopLevelPersistenceKeys = Set(CodingKeys.allCases.map(\.stringValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        schemaLineage = try container.decodeIfPresent(String.self, forKey: .schemaLineage)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        copySettingsByWorkspaceID = try container.decodeIfPresent([String: CopyGlobalSettings].self, forKey: .copySettingsByWorkspaceID) ?? [:]
        chatSettingsByWorkspaceID = try container.decodeIfPresent([String: ChatGlobalSettings].self, forKey: .chatSettingsByWorkspaceID) ?? [:]
        agentModelsSettingsByWorkspaceID = try container.decodeIfPresent([String: WorkspaceAgentModelsSettings].self, forKey: .agentModelsSettingsByWorkspaceID)
        let decodedConnections = try container.decodeIfPresent([ExternalMCPIntegrationDefinition].self, forKey: .externalMCPConnections) ?? []
        guard Set(decodedConnections.map(\.provider)).count == decodedConnections.count else {
            throw ExternalMCPIntegrationSettingsDecodingError.duplicateProvider
        }
        let retainedConnections = decodedConnections.filter(\.isPersistableAppWideState)
        externalMCPConnections = retainedConnections.isEmpty ? nil : retainedConnections
        // Decode compatibility is provided by accepting this known key without interpreting its
        // value. Workspace policy can no longer block loading or influence Figma availability.
        externalMCPAccessByWorkspaceID = nil
        globalDefaults = try container.decodeIfPresent(GlobalDefaults.self, forKey: .globalDefaults) ?? GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
        scalarPreferences = try container.decodeIfPresent(GlobalScalarPreferences.self, forKey: .scalarPreferences)
    }

    /// Lowest CE schema version that can faithfully represent this document's content.
    ///
    /// Each feature contributes its own fixed introduction version. Future schema bumps must
    /// add another feature constant and participate in this maximum; they must not change the
    /// minimum version of content that existing features already know how to represent.
    var requiredSchemaVersion: Int {
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
        if externalMCPConnections?.isEmpty == false {
            requiredVersion = max(requiredVersion, Self.externalMCPConnectionsSchemaVersion)
        }
        if externalMCPConnections?.contains(where: \.isCleanupTombstone) == true {
            requiredVersion = max(requiredVersion, Self.externalMCPConnectionActivationSchemaVersion)
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

    func replacing(
        copySettings: [UUID: CopyGlobalSettings],
        chatSettings: [UUID: ChatGlobalSettings],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings],
        externalMCPConnections: [ExternalMCPIntegrationDefinition] = [],
        externalMCPAccessByWorkspaceID: [UUID: ExternalMCPWorkspaceAccessOverrides] = [:],
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
            externalMCPConnections: externalMCPConnections,
            externalMCPAccessByWorkspaceID: [:],
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

// MARK: - External MCP Connection Settings

/// Typed decode failures for external MCP settings must preserve the current document and
/// surface the existing Settings recovery UI instead of silently repairing connection policy.
enum ExternalMCPIntegrationSettingsDecodingError: Error, Equatable {
    case wrongContainerType
    case wrongDefinitionType
    case unknownDefinitionField
    case invalidActivation
    case unsupportedDefinition
    case duplicateProvider
    case unsupportedWorkspaceOverride
    case schemaVersionTooOld(declaredVersion: Int, requiredVersion: Int)

    var category: GlobalSettingsExternalMCPInvalidCategory {
        switch self {
        case .wrongContainerType: .wrongContainerType
        case .wrongDefinitionType: .wrongDefinitionType
        case .unknownDefinitionField: .unknownDefinitionField
        case .invalidActivation: .invalidActivation
        case .unsupportedDefinition: .unsupportedDefinition
        case .duplicateProvider: .duplicateProvider
        case .unsupportedWorkspaceOverride: .unsupportedWorkspaceOverride
        case .schemaVersionTooOld: .schemaVersionTooOld
        }
    }
}

enum GlobalSettingsExternalMCPInvalidCategory: String, Equatable {
    case wrongContainerType
    case wrongDefinitionType
    case unknownDefinitionField
    case invalidActivation
    case unsupportedDefinition
    case unsupportedWorkspaceOverride
    case duplicateProvider
    case schemaVersionTooOld
}

/// Providers which RepoPrompt can configure as Codex-managed external MCP connections.
/// The initial schema intentionally supports only Figma; adding a provider requires an
/// explicit model and validation review rather than accepting arbitrary remote endpoints.
enum ExternalMCPIntegrationProvider: String, Codable, CaseIterable, Equatable, Hashable {
    case figma
}

/// Durable origin of an external MCP definition.
///
/// Settings-managed registrations are created and owned by RepoPrompt. An adopted import
/// records a user-confirmed, pre-existing Figma server identity without claiming ownership
/// of the external Codex configuration that supplied it. Both origins remain nonsecret.
enum ExternalMCPIntegrationOrigin: String, Codable, Equatable {
    case settingsManaged
    case adoptedImport
}

/// Whether RepoPrompt may operate a retained external MCP connection. `.disabled` is reserved
/// for a Settings-managed cleanup tombstone after explicit sign-out has already revoked access.
enum ExternalMCPIntegrationActivation: String, Codable, CaseIterable, Equatable {
    case enabled
    case disabled
}

/// Legacy decode/UI compatibility for the retired Figma access policy. These values no longer
/// participate in runtime resolution and are never written into a Figma registration.
enum ExternalMCPAgentAccessPolicy: String, Codable, CaseIterable, Equatable {
    case inherit
    case allow
    case deny
}

/// Nonsecret, app-scoped definition for a supported external MCP connection. The fixed
/// endpoint, OAuth session, headers, arguments, token material, and runtime fingerprint
/// remain in the Codex integration layer and are deliberately absent from JSON settings.
struct ExternalMCPIntegrationDefinition: Codable, Equatable, Identifiable {
    let provider: ExternalMCPIntegrationProvider
    let serverName: String
    let origin: ExternalMCPIntegrationOrigin
    var repoPromptActivation: ExternalMCPIntegrationActivation

    /// Compatibility projections for UI code compiled during the migration. An enabled app-wide
    /// registration always reconnects and is always available to Agent Mode; assignments are ignored.
    var autoConnect: Bool {
        get { repoPromptActivation == .enabled }
        set {}
    }

    var agentModeAccessDefault: ExternalMCPAgentAccessPolicy {
        get { repoPromptActivation == .enabled ? .allow : .deny }
        set {}
    }

    var id: ExternalMCPIntegrationProvider {
        provider
    }

    /// Whether this definition has the fixed supported Figma identity.
    var isSupportedDefinition: Bool {
        Self.isSupported(provider: provider, serverName: serverName, origin: origin)
    }

    /// Enabled supported Figma registrations and Settings-managed cleanup tombstones are
    /// persisted. A disabled adopted import is not a valid dormant policy.
    var isPersistableAppWideState: Bool {
        isSupportedDefinition && (repoPromptActivation == .enabled || isCleanupTombstone)
    }

    /// Identifies a legacy disabled marker so callers can clear stale in-memory values too.
    var isCleanupTombstone: Bool {
        origin == .settingsManaged && repoPromptActivation == .disabled
    }

    /// Retained for callers that need to decide whether RepoPrompt may manage its own
    /// registration. Adopted imports must not be treated as Settings-owned configuration.
    var isSupportedSettingsManagedDefinition: Bool {
        origin == .settingsManaged && isSupportedDefinition
    }

    init(
        provider: ExternalMCPIntegrationProvider,
        serverName: String,
        origin: ExternalMCPIntegrationOrigin = .settingsManaged,
        autoConnect: Bool = false,
        agentModeAccessDefault: ExternalMCPAgentAccessPolicy = .deny,
        repoPromptActivation: ExternalMCPIntegrationActivation = .enabled
    ) {
        precondition(
            Self.isSupported(provider: provider, serverName: serverName, origin: origin),
            "External MCP connection definitions must use a supported Figma identity and origin"
        )
        self.provider = provider
        self.serverName = serverName
        self.origin = origin
        self.repoPromptActivation = repoPromptActivation
    }

    static func figma(
        autoConnect: Bool = false,
        agentModeAccessDefault: ExternalMCPAgentAccessPolicy = .deny,
        repoPromptActivation: ExternalMCPIntegrationActivation = .enabled
    ) -> ExternalMCPIntegrationDefinition {
        ExternalMCPIntegrationDefinition(
            provider: .figma,
            serverName: "figma",
            origin: .settingsManaged,
            autoConnect: autoConnect,
            agentModeAccessDefault: agentModeAccessDefault,
            repoPromptActivation: repoPromptActivation
        )
    }

    /// User-initiated adoption of the existing canonical Figma import. `serverName` is
    /// deliberately persisted as the stable runtime identity; endpoints, OAuth state, and
    /// configuration provenance remain outside Settings JSON.
    static func adoptedFigmaImport(
        autoConnect: Bool = false,
        agentModeAccessDefault: ExternalMCPAgentAccessPolicy = .deny,
        repoPromptActivation: ExternalMCPIntegrationActivation = .enabled
    ) -> ExternalMCPIntegrationDefinition {
        ExternalMCPIntegrationDefinition(
            provider: .figma,
            serverName: "figma",
            origin: .adoptedImport,
            autoConnect: autoConnect,
            agentModeAccessDefault: agentModeAccessDefault,
            repoPromptActivation: repoPromptActivation
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case serverName
        case origin
        case autoConnect
        case agentModeAccessDefault
        case repoPromptActivation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(ExternalMCPIntegrationProvider.self, forKey: .provider)
        let serverName = try container.decode(String.self, forKey: .serverName)
        let origin = try container.decode(ExternalMCPIntegrationOrigin.self, forKey: .origin)
        // Retired auto-connect and access-policy keys are deliberately not decoded. This makes
        // legacy values harmless even when they contain types or enum cases current code does not know.
        let repoPromptActivation: ExternalMCPIntegrationActivation
        do {
            repoPromptActivation = try container.decodeIfPresent(
                ExternalMCPIntegrationActivation.self,
                forKey: .repoPromptActivation
            ) ?? .enabled
        } catch {
            throw ExternalMCPIntegrationSettingsDecodingError.unsupportedDefinition
        }

        guard Self.isSupported(provider: provider, serverName: serverName, origin: origin) else {
            throw ExternalMCPIntegrationSettingsDecodingError.unsupportedDefinition
        }
        guard origin == .settingsManaged || repoPromptActivation == .enabled else {
            throw ExternalMCPIntegrationSettingsDecodingError.unsupportedDefinition
        }
        self.init(
            provider: provider,
            serverName: serverName,
            origin: origin,
            repoPromptActivation: repoPromptActivation
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(origin, forKey: .origin)
        if repoPromptActivation != .enabled {
            try container.encode(repoPromptActivation, forKey: .repoPromptActivation)
        }
    }

    private static func isSupported(
        provider: ExternalMCPIntegrationProvider,
        serverName: String,
        origin: ExternalMCPIntegrationOrigin
    ) -> Bool {
        provider == .figma
            && serverName == "figma"
            && (origin == .settingsManaged || origin == .adoptedImport)
    }
}

/// Decode-only compatibility model for the retired workspace policy. Global settings discard
/// these values on load and never encode them again.
struct ExternalMCPWorkspaceAccessOverrides: Codable, Equatable {
    private var accessByServerName: [String: ExternalMCPAgentAccessPolicy]

    init(accessByServerName: [String: ExternalMCPAgentAccessPolicy] = [:]) {
        self.accessByServerName = Self.validated(accessByServerName)
    }

    func policy(for provider: ExternalMCPIntegrationProvider) -> ExternalMCPAgentAccessPolicy {
        accessByServerName[Self.serverName(for: provider)] ?? .inherit
    }

    mutating func setPolicy(
        _ policy: ExternalMCPAgentAccessPolicy,
        for provider: ExternalMCPIntegrationProvider
    ) {
        accessByServerName[Self.serverName(for: provider)] = policy
    }

    var isEmpty: Bool {
        accessByServerName.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case accessByServerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decodeIfPresent([String: ExternalMCPAgentAccessPolicy].self, forKey: .accessByServerName) ?? [:]
        guard values.keys.allSatisfy({ $0 == "figma" }) else {
            throw ExternalMCPIntegrationSettingsDecodingError.unsupportedWorkspaceOverride
        }
        accessByServerName = values
    }

    private static func validated(
        _ values: [String: ExternalMCPAgentAccessPolicy]
    ) -> [String: ExternalMCPAgentAccessPolicy] {
        values.reduce(into: [:]) { result, entry in
            guard entry.key == "figma" else { return }
            result[entry.key] = entry.value
        }
    }

    private static func serverName(for provider: ExternalMCPIntegrationProvider) -> String {
        switch provider {
        case .figma:
            "figma"
        }
    }
}

/// Inputs supplied by the runtime before settings policy can grant Agent Mode access.
enum ExternalMCPRuntimeAvailability: Equatable {
    case available
    case unavailable
    case disabled
    case externallyExplicitlyDisabled
}

/// Legacy call-site compatibility. Figma availability no longer varies by session hierarchy.
enum ExternalMCPAgentSessionPolicy: Equatable {
    case normal
    case safeManagedChild
    case headless
}

enum ExternalMCPAgentAccessSource: Equatable {
    case unavailable
    case runtimeDisabled
    case externalExplicitDisable
    case connectionDisabled
    case safeManagedChild
    case headless
    case windowOverride
    case workspaceOverride
    case appDefault
}

struct ExternalMCPAgentAccessResolution: Equatable {
    let isAllowed: Bool
    let source: ExternalMCPAgentAccessSource
}

/// Resolves only the fixed, read-only Figma integration. Generic third-party MCP policy remains
/// in the Codex runtime and is deliberately not represented by this Figma-specific model.
func resolveExternalMCPAgentAccess(
    definition: ExternalMCPIntegrationDefinition?,
    runtimeAvailability: ExternalMCPRuntimeAvailability,
    sessionPolicy _: ExternalMCPAgentSessionPolicy = .normal,
    windowOverride _: ExternalMCPAgentAccessPolicy? = nil,
    workspaceOverride _: ExternalMCPAgentAccessPolicy = .inherit
) -> ExternalMCPAgentAccessResolution {
    guard let definition,
          definition.provider == .figma
    else {
        return .init(isAllowed: false, source: .unavailable)
    }
    switch runtimeAvailability {
    case .available:
        break
    case .unavailable:
        return .init(isAllowed: false, source: .unavailable)
    case .disabled:
        return .init(isAllowed: false, source: .runtimeDisabled)
    case .externallyExplicitlyDisabled:
        return .init(isAllowed: false, source: .externalExplicitDisable)
    }
    guard definition.repoPromptActivation == .enabled else {
        return .init(isAllowed: false, source: .connectionDisabled)
    }
    return .init(isAllowed: true, source: .appDefault)
}

// MARK: - Scoped Agent Models Settings

enum AgentModelsInheritanceMode: String, Codable, Equatable {
    case useGlobalSettings
    case useWorkspaceOverrides
}

enum AgentModelsEditingScope: Hashable {
    case global
    case workspace(UUID)

    static func resolve(
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
struct AgentModelsOperationIdentity: Hashable {
    let sourceWorkspaceID: UUID
    let scope: AgentModelsEditingScope

    init(sourceWorkspaceID: UUID, scope: AgentModelsEditingScope) {
        self.sourceWorkspaceID = sourceWorkspaceID
        self.scope = scope
    }

    init(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) {
        self.sourceWorkspaceID = sourceWorkspaceID
        scope = AgentModelsEditingScope.resolve(
            workspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }

    func matches(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) -> Bool {
        self == AgentModelsOperationIdentity(
            sourceWorkspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }
}

enum ContextBuilderSettingsWriteIntent {
    case preserveExistingOwnership
    case userInitiated
    case automaticSeed
}

struct AgentModelsSettingsProfile: Codable, Equatable {
    var planningModelRaw: String?
    var additionalOracleModelRaws: [String]
    var preferredComposeModelRaw: String?
    var syncChatModelWithOracle: Bool
    var contextBuilderAgentRaw: String?
    var contextBuilderModelsByAgent: [String: String]?
    var mcpAgentRoleOverrides: [String: String]?
    var restrictMCPAgentDiscoveryToRoleLabels: Bool
    /// OpenCode-style ACP parameter pins per Sub-Agent role. Keys are `TaskLabelKind`
    /// rawValues; values are model-scoped selections, so a pin only survives while its role's
    /// stored override still resolves to the same provider and canonical model.
    var mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]?
    /// OpenCode-style ACP parameter pins per Context Builder agent. Keys are
    /// `AgentProviderKind` rawValues, mirroring `contextBuilderModelsByAgent`.
    var contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]?

    init(
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

    init(from decoder: Decoder) throws {
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
                  let providerID = AgentProviderKind(rawValue: selectionID.agentRaw)?.acpProviderID,
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: selectionID.modelRaw,
                from: selections
            )
            guard !matching.isEmpty else { continue }
            coherent[key] = matching
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
                  let providerID = AgentProviderKind(rawValue: key)?.acpProviderID,
                  let modelRaw = modelsByAgent?[key],
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: modelRaw,
                from: selections
            )
            guard !matching.isEmpty else { continue }
            coherent[key] = matching
        }
        return coherent.isEmpty ? nil : coherent
    }

    /// The Context Builder pin for a resolved agent + model, requiring the persisted explicit
    /// CB agent to match. The single eligibility rule for the CB bucket, shared by the display
    /// getters, the setter, and the run-side filter — so all four agree by construction.
    func contextBuilderModelParameterSelections(
        for agent: AgentProviderKind,
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
        guard let providerID = AgentProviderKind(rawValue: agentRaw)?.acpProviderID else { return false }
        return !ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: modelRaw,
            from: bucket
        ).isEmpty
    }

    func replacingContextBuilderModel(_ modelRaw: String?, for agentRaw: String?) -> AgentModelsSettingsProfile {
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
    func replacingRoleModelParameter(
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
    func replacingContextBuilderModelParameter(
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
        } else if let resolvedAgent = AgentProviderKind(rawValue: resolvedAgentRaw),
                  !contextBuilderModelParameterSelections(
                      for: resolvedAgent,
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

struct WorkspaceAgentModelsSettings: Codable, Equatable {
    var inheritanceMode: AgentModelsInheritanceMode
    var profile: AgentModelsSettingsProfile?

    init(
        inheritanceMode: AgentModelsInheritanceMode = .useGlobalSettings,
        profile: AgentModelsSettingsProfile? = nil
    ) {
        self.inheritanceMode = inheritanceMode
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case inheritanceMode, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inheritanceMode = try container.decodeIfPresent(AgentModelsInheritanceMode.self, forKey: .inheritanceMode)
            ?? .useGlobalSettings
        profile = try container.decodeIfPresent(AgentModelsSettingsProfile.self, forKey: .profile)
    }
}

// MARK: - Worktree Visual Identity

enum WorktreeVisualMarkerStyle: String, Codable, Equatable {
    case dot
    case ring
    case capsule
}

struct WorktreeVisualIdentity: Codable, Equatable {
    static let defaultIconName = "circle.fill"
    static let defaultMarkerStyle = WorktreeVisualMarkerStyle.dot

    var label: String?
    var colorHex: String
    var iconName: String
    var markerStyle: WorktreeVisualMarkerStyle
    var updatedAt: Date?

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? Self.defaultIconName
        markerStyle = try container.decodeIfPresent(WorktreeVisualMarkerStyle.self, forKey: .markerStyle) ?? Self.defaultMarkerStyle
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct WorktreeVisualIdentityRepositoryBucket: Codable, Equatable {
    var identitiesByWorktreeID: [String: WorktreeVisualIdentity]

    init(identitiesByWorktreeID: [String: WorktreeVisualIdentity] = [:]) {
        self.identitiesByWorktreeID = identitiesByWorktreeID
    }
}

// MARK: - Scalar Preferences

/// Optional scalar preferences stored in schema v2.
///
/// Keep groups and fields optional so missing values continue to use the same
/// defaults as the typed settings accessors.
struct GlobalScalarPreferences: Codable, Equatable {
    var ui: UISettings?
    var promptPackaging: PromptPackagingSettings?
    var modelSelection: ModelSelectionSettings?
    var contextBuilder: ContextBuilderSettings?
    var mcp: MCPSettings?
    var fileSystem: FileSystemSettings?
    var agentMode: AgentModeSettings?
    var telemetry: TelemetrySettings?
    var modelOverrides: ModelOverrideSettingsData?
    var modelRouter: ModelRouterSettings?
    /// Additive, schema-neutral group: every field is optional and typed readers fall back to
    /// `NotificationPreferences.defaults`. Older typed readers ignore the unknown key, and the
    /// raw-preserving save path keeps it, so it deliberately does not raise `requiredSchemaVersion`.
    var notifications: NotificationSettings?

    init(
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

    struct NotificationSettings: Codable, Equatable {
        var enabled: Bool?
        var agentInteractions: Bool?
        var agentInstructionWaits: Bool?
        var agentTurnComplete: Bool?
        var agentTurnFailed: Bool?
        var chatComplete: Bool?
        var contextBuilderComplete: Bool?
        var approveFromNotifications: Bool?
        var answerFromNotifications: Bool?
        var replyFromCompletion: Bool?
        var showDetails: Bool?
        var notifyWhileActive: Bool?
        var completionsWhileActive: Bool?
        var includeAgentDrivenSessions: Bool?
        var dockBadge: Bool?
        var mcpAskUserNotifyInsteadOfActivate: Bool?

        init() {}

        /// Resolves stored overrides over the product defaults.
        func resolved(over defaults: NotificationPreferences = .defaults) -> NotificationPreferences {
            var preferences = defaults
            preferences.enabled = enabled ?? defaults.enabled
            preferences.agentInteractions = agentInteractions ?? defaults.agentInteractions
            preferences.agentInstructionWaits = agentInstructionWaits ?? defaults.agentInstructionWaits
            preferences.agentTurnComplete = agentTurnComplete ?? defaults.agentTurnComplete
            preferences.agentTurnFailed = agentTurnFailed ?? defaults.agentTurnFailed
            preferences.chatComplete = chatComplete ?? defaults.chatComplete
            preferences.contextBuilderComplete = contextBuilderComplete ?? defaults.contextBuilderComplete
            preferences.approveFromNotifications = approveFromNotifications ?? defaults.approveFromNotifications
            preferences.answerFromNotifications = answerFromNotifications ?? defaults.answerFromNotifications
            preferences.replyFromCompletion = replyFromCompletion ?? defaults.replyFromCompletion
            preferences.showDetails = showDetails ?? defaults.showDetails
            preferences.notifyWhileActive = notifyWhileActive ?? defaults.notifyWhileActive
            preferences.completionsWhileActive = completionsWhileActive ?? defaults.completionsWhileActive
            preferences.includeAgentDrivenSessions = includeAgentDrivenSessions ?? defaults.includeAgentDrivenSessions
            preferences.dockBadge = dockBadge ?? defaults.dockBadge
            preferences.mcpAskUserNotifyInsteadOfActivate = mcpAskUserNotifyInsteadOfActivate
                ?? defaults.mcpAskUserNotifyInsteadOfActivate
            return preferences
        }
    }

    struct ModelRouterSettings: Codable, Equatable {
        var enabled: Bool?
        var selectedBackendRawValue: String?
        var candidateRoleRawValues: [String]?
        var allowedProviderRawValues: [String]?
        var primaryProviderRawValue: String?
        var subagentProviderRawValue: String?
        var customInstructions: String?

        init(
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

    struct UISettings: Codable, Equatable {
        var appearanceMode: String?
        var useTransparency: Bool?
        var collapseLatestFileChanges: Bool?
        var showTooltips: Bool?
        var experimentalAttributedTextEditor: Bool?
        var fileMentionPickerStyle: String?
        var enableKeyboardShortcuts: Bool?
        var fontScaleBodySize: Double?
        var showDatesInMessageTimestamps: Bool?

        init(
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

    struct PromptPackagingSettings: Codable, Equatable {
        var promptSectionsOrder: String?
        var duplicateUserInstructionsAtTop: Bool?
        var filePathDisplayOption: String?
        var selectedFilesSortMethod: String?
        var fileEditFormat: String?
        var includeDatetimeInUserInstructions: Bool?
        var customPlanningPrompt: String?
        var modelTemperature: Double?
        var setModelTemperature: Bool?
        var complexEditStrategy: String?

        init(
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

    struct ModelSelectionSettings: Codable, Equatable {
        var preferredComposeModel: String?
        var planningModel: String?
        var additionalOracleModels: [String]?
        var syncChatModelWithOracle: Bool?

        init(
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

        init(from decoder: Decoder) throws {
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

    struct ContextBuilderSettings: Codable, Equatable {
        var contextTokenBudget: Int?
        var analysisTokenBudget: Int?
        var enhancementMode: String?
        var questionTimeoutSeconds: TimeInterval?
        var allowUIClarifyingQuestions: Bool?
        var allowMCPClarifyingQuestions: Bool?
        var followUpAnalysisEnabled: Bool?

        init(
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

    struct MCPSettings: Codable, Equatable {
        var autoStart: Bool?
        var showModelPresets: Bool?
        var temporarilyDisablePresets: Bool?

        init(
            autoStart: Bool? = nil,
            showModelPresets: Bool? = nil,
            temporarilyDisablePresets: Bool? = nil
        ) {
            self.autoStart = autoStart
            self.showModelPresets = showModelPresets
            self.temporarilyDisablePresets = temporarilyDisablePresets
        }
    }

    struct FileSystemSettings: Codable, Equatable {
        var respectRepoIgnore: Bool?
        var respectCursorignore: Bool?
        var globalIgnoreDefaults: String?
        var enableHierarchicalIgnores: Bool?
        var skipSymlinks: Bool?
        var showEmptyFolders: Bool?

        init(
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

    struct TelemetrySettings: Codable, Equatable {
        var enabled: Bool?
        var appHangReportsEnabled: Bool?
        var performanceTracingEnabled: Bool?

        init(
            enabled: Bool? = nil,
            appHangReportsEnabled: Bool? = nil,
            performanceTracingEnabled: Bool? = nil
        ) {
            self.enabled = enabled
            self.appHangReportsEnabled = appHangReportsEnabled
            self.performanceTracingEnabled = performanceTracingEnabled
        }
    }

    struct ModelOverrideSettingsData: Codable, Equatable {
        var diffOverrides: [String: Bool]?
        var streamOverrides: [String: Bool]?
        var temperatureOverrides: [String: Double]?
        var responsesOverrides: [String: Bool]?

        init(
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

    struct AgentModeSettings: Codable, Equatable {
        var proEditAgentMode: Bool?
        var proEditAgentKind: String?
        var proEditAgentModel: String?
        var proEditAgentModeMigrated: Bool?
        // DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
        // Kept temporarily for decode/rollback compatibility only; do not read from UI/runtime.
        var agentAutoExpandToolCards: Bool?
        // DEPRECATED: The background Agent compose-tab limit was removed in 2026-08.
        // Kept for decode/rollback compatibility and round-trip preservation only.
        var maxBackgroundAgentComposeTabs: Int?
        var showBuiltInWorkflowCleanupGuidance: Bool?
        var codexGoalSupportEnabled: Bool?
        var codexReasoningSummariesEnabled: Bool?
        var autoEffortEnabled: Bool?
        var codexMemoriesEnabled: Bool?
        var codexAppsEnabled: Bool?
        var codexPluginsEnabled: Bool?
        var codexMCPElicitationEnabled: Bool?
        var codexToolSuggestionsEnabled: Bool?
        var codexHookApprovalStrictModeEnabled: Bool?
        var codexHookApprovalStrictModeWorkspaceOverrides: [String: Bool]?
        var providerConversationCleanupAction: String?
        var restrictMCPAgentDiscoveryToRoleLabels: Bool?
        var agentSessionHandoffInstructions: String?
        var subagentDefaultWaitSeconds: Int?

        init(
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
            self.providerConversationCleanupAction = providerConversationCleanupAction
            self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
            self.agentSessionHandoffInstructions = agentSessionHandoffInstructions
            self.subagentDefaultWaitSeconds = subagentDefaultWaitSeconds
        }
    }
}
