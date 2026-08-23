import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

public extension SQLiteServiceStore {
    func authorityStore_agentModelsDocument(scopeID: String) async throws -> StoredSettingsDocument<AgentModelsScopeDocument>? {
        try await readSettingsDocument(.agentModels, scopeID: scopeID)
    }

    @discardableResult
    func authorityStore_upsertAgentModelsDocument(
        _ document: StoredSettingsDocument<AgentModelsScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64? = nil,
        expectedSourceScopeID: String? = nil,
        expectedSourceRevision: Int64? = nil,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AgentModelsScopeDocument> {
        let sourceFence: (SettingsRepository, String, Int64)?
        if let expectedGlobalRevision {
            sourceFence = (.agentModels, "global", expectedGlobalRevision)
        } else if let expectedSourceScopeID, let expectedSourceRevision {
            sourceFence = (.agentModels, expectedSourceScopeID, expectedSourceRevision)
        } else {
            sourceFence = nil
        }
        return try await upsertSettingsDocument(
            document,
            repository: .agentModels,
            scopeID: scopeID,
            projectID: projectID,
            expectedRevision: expectedRevision,
            sourceFence: sourceFence,
            audit: audit
        )
    }

    func authorityStore_subagentPermissionDocument() async throws -> StoredSettingsDocument<SubagentPermissionSettings>? {
        try await readSettingsDocument(.subagentPermissions, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertSubagentPermissionDocument(
        _ document: StoredSettingsDocument<SubagentPermissionSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<SubagentPermissionSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .subagentPermissions,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_workspaceApprovalDocument() async throws -> StoredSettingsDocument<WorkspaceApprovalSettings>? {
        try await readSettingsDocument(.workspaceApprovals, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertWorkspaceApprovalDocument(
        _ document: StoredSettingsDocument<WorkspaceApprovalSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<WorkspaceApprovalSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .workspaceApprovals,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_mcpDisabledToolsDocument() async throws -> StoredSettingsDocument<MCPDisabledToolsSettings>? {
        try await readSettingsDocument(.mcpDisabledTools, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertMCPDisabledToolsDocument(
        _ document: StoredSettingsDocument<MCPDisabledToolsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPDisabledToolsSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .mcpDisabledTools,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_mcpShowModelPresetsDocument() async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings>? {
        try await readSettingsDocument(.mcpShowModelPresets, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertMCPShowModelPresetsDocument(
        _ document: StoredSettingsDocument<MCPShowModelPresetsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .mcpShowModelPresets,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_directAgentPermissionDocument() async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings>? {
        try await readSettingsDocument(.directAgentPermissions, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertDirectAgentPermissionDocument(
        _ document: StoredSettingsDocument<DirectAgentPermissionsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .directAgentPermissions,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_contextBuilderDocument(scopeID: String) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument>? {
        try await readSettingsDocument(.contextBuilder, scopeID: scopeID)
    }

    @discardableResult
    func authorityStore_upsertContextBuilderDocument(
        _ document: StoredSettingsDocument<ContextBuilderScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64? = nil,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument> {
        try await upsertSettingsDocument(
            document,
            repository: .contextBuilder,
            scopeID: scopeID,
            projectID: projectID,
            expectedRevision: expectedRevision,
            sourceFence: expectedGlobalRevision.map { (.contextBuilder, "global", $0) },
            audit: audit
        )
    }

    func authorityStore_mcpModelPresetsDocument() async throws -> StoredSettingsDocument<[MCPModelPreset]>? {
        try await readSettingsDocument(.mcpModelPresets, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertMCPModelPresetsDocument(
        _ document: StoredSettingsDocument<[MCPModelPreset]>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[MCPModelPreset]> {
        try await upsertSettingsDocument(
            document,
            repository: .mcpModelPresets,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_advancedServerSettingsDocument() async throws -> StoredSettingsDocument<AdvancedServerSettings>? {
        try await readSettingsDocument(.advanced, scopeID: "global")
    }

    @discardableResult
    func authorityStore_upsertAdvancedServerSettingsDocument(
        _ document: StoredSettingsDocument<AdvancedServerSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AdvancedServerSettings> {
        try await upsertSettingsDocument(
            document,
            repository: .advanced,
            scopeID: "global",
            projectID: nil,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func authorityStore_projectSelectionPresetsDocument(projectID: UUID) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]>? {
        try await readSettingsDocument(.selectionPresets, scopeID: projectID.uuidString)
    }

    @discardableResult
    func authorityStore_upsertProjectSelectionPresetsDocument(
        _ document: StoredSettingsDocument<[ProjectSelectionPreset]>,
        projectID: UUID,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]> {
        try await upsertSettingsDocument(
            document,
            repository: .selectionPresets,
            scopeID: projectID.uuidString,
            projectID: projectID,
            expectedRevision: expectedRevision,
            audit: audit
        )
    }

    func settingsAuditRecords(domain: ServerSettingsDomain? = nil, scopeID: String? = nil) async throws -> [ServerSettingsAuditRecord] {
        var clauses: [String] = []
        var bindings: [SQLiteData] = []
        if let domain {
            clauses.append("domain=?")
            bindings.append(.text(domain.rawValue))
        }
        if let scopeID {
            clauses.append("scope_id=?")
            bindings.append(.text(scopeID))
        }
        let predicate = clauses.isEmpty ? "" : " WHERE \(clauses.joined(separator: " AND "))"
        return try await database.query(
            "SELECT audit_id,domain,scope_id,prior_revision,new_revision,operation,actor_id,actor_label,channel,payload_digest,created_at FROM settings_audit\(predicate) ORDER BY created_at,audit_id",
            bindings
        ).map { row in
            guard let auditID = row.column("audit_id")?.string.flatMap(UUID.init(uuidString:)),
                  let domain = row.column("domain")?.string.flatMap(ServerSettingsDomain.init(rawValue:)),
                  let scopeID = row.column("scope_id")?.string,
                  let operation = row.column("operation")?.string,
                  let actorID = row.column("actor_id")?.string,
                  let actorLabel = row.column("actor_label")?.string,
                  let channel = row.column("channel")?.string,
                  let payloadDigest = row.column("payload_digest")?.string
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Settings audit row is invalid", retryable: false)
            }
            return ServerSettingsAuditRecord(
                auditID: auditID,
                domain: domain,
                scopeID: scopeID,
                priorRevision: Int64(row.column("prior_revision")?.integer ?? 0),
                newRevision: Int64(row.column("new_revision")?.integer ?? 0),
                operation: operation,
                actorID: actorID,
                actorLabel: actorLabel,
                channel: channel,
                payloadDigest: payloadDigest,
                createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0)
            )
        }
    }
}

private enum SettingsRepository {
    case agentModels
    case subagentPermissions
    case directAgentPermissions
    case workspaceApprovals
    case mcpDisabledTools
    case mcpShowModelPresets
    case contextBuilder
    case mcpModelPresets
    case advanced
    case selectionPresets

    var domain: ServerSettingsDomain {
        switch self {
        case .agentModels: .agentModels
        case .subagentPermissions: .subagentPermissions
        case .directAgentPermissions: .directAgentPermissions
        case .workspaceApprovals: .workspaceApprovals
        case .mcpDisabledTools: .mcpDisabledTools
        case .mcpShowModelPresets: .mcpShowModelPresets
        case .contextBuilder: .contextBuilder
        case .mcpModelPresets: .mcpModelPresets
        case .advanced: .advanced
        case .selectionPresets: .selectionPresets
        }
    }
}

private extension SQLiteServiceStore {
    func readSettingsDocument<Value: Codable & Sendable>(
        _ repository: SettingsRepository,
        scopeID: String
    ) async throws -> StoredSettingsDocument<Value>? {
        let row: SQLiteRow? = switch repository {
        case .agentModels:
            try await database.query("SELECT profile_json,revision,updated_at FROM agent_model_profiles WHERE scope_id=?", [.text(scopeID)]).first
        case .subagentPermissions:
            try await database.query("SELECT settings_json,revision,updated_at FROM subagent_permission_settings WHERE fixed_id=1").first
        case .directAgentPermissions:
            try await database.query("SELECT settings_json,revision,updated_at FROM direct_agent_permission_settings WHERE fixed_id=1").first
        case .workspaceApprovals:
            try await database.query("SELECT settings_json,revision,updated_at FROM workspace_approval_settings WHERE fixed_id=1").first
        case .mcpDisabledTools:
            try await database.query("SELECT settings_json,revision,updated_at FROM mcp_disabled_tools WHERE fixed_id=1").first
        case .mcpShowModelPresets:
            try await database.query("SELECT settings_json,revision,updated_at FROM mcp_show_model_presets WHERE fixed_id=1").first
        case .contextBuilder:
            try await database.query("SELECT settings_json,revision,updated_at FROM context_builder_settings WHERE scope_id=?", [.text(scopeID)]).first
        case .mcpModelPresets:
            try await database.query("SELECT presets_json,revision,updated_at FROM mcp_model_presets WHERE fixed_id=1").first
        case .advanced:
            try await database.query("SELECT settings_json,revision,updated_at FROM advanced_server_settings WHERE fixed_id=1").first
        case .selectionPresets:
            try await database.query("SELECT presets_json,revision,updated_at FROM project_selection_presets WHERE project_id=?", [.text(scopeID)]).first
        }
        guard let row else { return nil }
        let jsonColumn: String = switch repository {
        case .agentModels: "profile_json"
        case .subagentPermissions, .directAgentPermissions, .workspaceApprovals, .mcpDisabledTools, .mcpShowModelPresets, .contextBuilder, .advanced: "settings_json"
        case .mcpModelPresets, .selectionPresets: "presets_json"
        }
        guard let json = row.column(jsonColumn)?.string else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Typed settings document is missing", retryable: false)
        }
        return try StoredSettingsDocument(
            value: decoder.decode(Value.self, from: Data(json.utf8)),
            revision: Int64(row.column("revision")?.integer ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0)
        )
    }

    func upsertSettingsDocument<Value: Codable & Sendable>(
        _ document: StoredSettingsDocument<Value>,
        repository: SettingsRepository,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        sourceFence: (SettingsRepository, String, Int64)? = nil,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<Value> {
        try validateSettingsAudit(audit, domain: repository.domain, scopeID: scopeID)
        let retainedBytes = try retainedInputBytes(
            document.value,
            additional: checkedRetainedByteSum(
                scopeID.utf8.count,
                sourceFence?.1.utf8.count ?? 0,
                audit.operation.utf8.count,
                audit.attribution.actorID.utf8.count,
                audit.attribution.actorLabel.utf8.count,
                audit.attribution.channel.utf8.count,
                audit.payloadDigest.utf8.count
            )
        )
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            let observed = try await settingsRevision(repository, scopeID: scopeID)
            guard observed == expectedRevision, document.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .staleRevision, message: "Typed settings revision is stale", currentRevision: observed)
            }
            if let sourceFence {
                let sourceRevision = try await settingsRevision(sourceFence.0, scopeID: sourceFence.1)
                guard sourceRevision == sourceFence.2 else {
                    throw ServiceAPIError(code: .staleRevision, message: "Typed settings copy source revision is stale", currentRevision: sourceRevision)
                }
            }
            let json = try encodeText(document.value)
            let revision = SQLiteData.integer(Int(document.revision))
            let updatedAt = SQLiteData.float(document.updatedAt.timeIntervalSince1970)
            switch repository {
            case .agentModels:
                _ = try await database.query(
                    "INSERT INTO agent_model_profiles(scope_id,project_id,profile_json,revision,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(scope_id) DO UPDATE SET project_id=excluded.project_id,profile_json=excluded.profile_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(scopeID), projectID.map { .text($0.uuidString) } ?? .null, .text(json), revision, updatedAt]
                )
            case .subagentPermissions:
                _ = try await database.query(
                    "INSERT INTO subagent_permission_settings(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .directAgentPermissions:
                _ = try await database.query(
                    "INSERT INTO direct_agent_permission_settings(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .workspaceApprovals:
                _ = try await database.query(
                    "INSERT INTO workspace_approval_settings(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .mcpDisabledTools:
                _ = try await database.query(
                    "INSERT INTO mcp_disabled_tools(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .mcpShowModelPresets:
                _ = try await database.query(
                    "INSERT INTO mcp_show_model_presets(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .contextBuilder:
                _ = try await database.query(
                    "INSERT INTO context_builder_settings(scope_id,project_id,settings_json,revision,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(scope_id) DO UPDATE SET project_id=excluded.project_id,settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(scopeID), projectID.map { .text($0.uuidString) } ?? .null, .text(json), revision, updatedAt]
                )
            case .mcpModelPresets:
                _ = try await database.query(
                    "INSERT INTO mcp_model_presets(fixed_id,presets_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET presets_json=excluded.presets_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .advanced:
                _ = try await database.query(
                    "INSERT INTO advanced_server_settings(fixed_id,settings_json,revision,updated_at) VALUES(1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET settings_json=excluded.settings_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(json), revision, updatedAt]
                )
            case .selectionPresets:
                _ = try await database.query(
                    "INSERT INTO project_selection_presets(project_id,presets_json,revision,updated_at) VALUES(?,?,?,?) ON CONFLICT(project_id) DO UPDATE SET presets_json=excluded.presets_json,revision=excluded.revision,updated_at=excluded.updated_at",
                    [.text(scopeID), .text(json), revision, updatedAt]
                )
            }
            try await appendSettingsAudit(
                domain: repository.domain,
                scopeID: scopeID,
                priorRevision: observed,
                newRevision: document.revision,
                mutation: audit,
                createdAt: document.updatedAt
            )
            return document
        }
    }

    func settingsRevision(_ repository: SettingsRepository, scopeID: String) async throws -> Int64 {
        let row: SQLiteRow? = switch repository {
        case .agentModels:
            try await database.query("SELECT revision FROM agent_model_profiles WHERE scope_id=?", [.text(scopeID)]).first
        case .subagentPermissions:
            try await database.query("SELECT revision FROM subagent_permission_settings WHERE fixed_id=1").first
        case .directAgentPermissions:
            try await database.query("SELECT revision FROM direct_agent_permission_settings WHERE fixed_id=1").first
        case .workspaceApprovals:
            try await database.query("SELECT revision FROM workspace_approval_settings WHERE fixed_id=1").first
        case .mcpDisabledTools:
            try await database.query("SELECT revision FROM mcp_disabled_tools WHERE fixed_id=1").first
        case .mcpShowModelPresets:
            try await database.query("SELECT revision FROM mcp_show_model_presets WHERE fixed_id=1").first
        case .contextBuilder:
            try await database.query("SELECT revision FROM context_builder_settings WHERE scope_id=?", [.text(scopeID)]).first
        case .mcpModelPresets:
            try await database.query("SELECT revision FROM mcp_model_presets WHERE fixed_id=1").first
        case .advanced:
            try await database.query("SELECT revision FROM advanced_server_settings WHERE fixed_id=1").first
        case .selectionPresets:
            try await database.query("SELECT revision FROM project_selection_presets WHERE project_id=?", [.text(scopeID)]).first
        }
        return Int64(row?.column("revision")?.integer ?? 0)
    }

    func appendSettingsAudit(
        domain: ServerSettingsDomain,
        scopeID: String,
        priorRevision: Int64,
        newRevision: Int64,
        mutation: ServerSettingsAuditMutation,
        createdAt: Date
    ) async throws {
        _ = try await database.query(
            "INSERT INTO settings_audit(audit_id,domain,scope_id,prior_revision,new_revision,operation,actor_id,actor_label,channel,payload_digest,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            [
                .text(UUID().uuidString),
                .text(domain.rawValue),
                .text(scopeID),
                .integer(Int(priorRevision)),
                .integer(Int(newRevision)),
                .text(mutation.operation),
                .text(mutation.attribution.actorID),
                .text(mutation.attribution.actorLabel),
                .text(mutation.attribution.channel),
                .text(mutation.payloadDigest),
                .float(createdAt.timeIntervalSince1970)
            ]
        )
    }

    func validateSettingsAudit(_ mutation: ServerSettingsAuditMutation, domain _: ServerSettingsDomain, scopeID: String) throws {
        let metadata = [scopeID, mutation.operation, mutation.attribution.actorID, mutation.attribution.actorLabel, mutation.attribution.channel]
        guard scopeID.utf8.count <= 128,
              mutation.operation.range(of: "^[a-z][A-Za-z0-9]{0,63}$", options: .regularExpression) != nil,
              (1 ... 256).contains(mutation.attribution.actorID.utf8.count),
              (1 ... 128).contains(mutation.attribution.actorLabel.utf8.count),
              mutation.attribution.channel.range(of: "^[a-z][a-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              mutation.payloadDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              metadata.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              metadata.allSatisfy({ !ProviderSecretRedaction.containsLikelySecret($0) })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Settings audit metadata is invalid")
        }
    }
}
