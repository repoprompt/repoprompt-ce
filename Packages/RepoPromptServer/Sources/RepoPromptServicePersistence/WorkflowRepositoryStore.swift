import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

public extension SQLiteServiceStore {
    func authorityStore_bootstrapWorkflowRepository(builtins: [WorkflowSnapshot], now: Date = Date()) async throws {
        let retainedBytes = try retainedInputBytes(builtins)
        try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            _ = try await database.query(
                "INSERT OR IGNORE INTO workflow_repository_state(fixed_id,collection_revision,include_session_cleanup_guidance,updated_at) VALUES(1,0,1,?)",
                [.float(now.timeIntervalSince1970)]
            )
            let builtinIDs = Set(builtins.map(\.workflowID))
            let installedBuiltinIDs = try await database.query("SELECT workflow_id FROM workflows WHERE source='builtin'")
                .compactMap { $0.column("workflow_id")?.string }
            for workflowID in installedBuiltinIDs where !builtinIDs.contains(workflowID) {
                _ = try await database.query("DELETE FROM workflow_repository_metadata WHERE workflow_id=?", [.text(workflowID)])
                _ = try await database.query("DELETE FROM workflows WHERE workflow_id=? AND source='builtin'", [.text(workflowID)])
            }
            for workflow in builtins {
                let defaultVisible = workflow.workflowID == WorkflowRepositoryDefaults.hiddenBuiltInID ? 0 : 1
                _ = try await database.query(
                    "INSERT OR IGNORE INTO workflow_repository_metadata(workflow_id,visible,featured_order,row_revision,updated_at) VALUES(?,?,NULL,1,?)",
                    [.text(workflow.workflowID), .integer(defaultVisible), .float(now.timeIntervalSince1970)]
                )
            }
            return ()
        }
    }

    func authorityStore_workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot {
        let state = try await database.query(
            "SELECT collection_revision,include_session_cleanup_guidance,updated_at FROM workflow_repository_state WHERE fixed_id=1"
        ).first
        let rows = try await database.query(
            "SELECT w.workflow_id,w.source,w.name,w.definition_json,w.content_digest,w.enabled,m.visible,m.featured_order,m.row_revision FROM workflows w JOIN workflow_repository_metadata m ON m.workflow_id=w.workflow_id"
        )
        let workflows = try rows.map { row -> ServerWorkflowDefinition in
            guard let workflowID = row.column("workflow_id")?.string,
                  let sourceText = row.column("source")?.string,
                  let source = ServerWorkflowSource(rawValue: sourceText),
                  let name = row.column("name")?.string,
                  let definition = row.column("definition_json")?.string,
                  let digest = row.column("content_digest")?.string
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Workflow repository row is invalid", retryable: false)
            }
            return ServerWorkflowDefinition(
                workflowID: workflowID,
                source: source,
                name: name,
                definition: definition,
                contentDigest: digest,
                enabled: row.column("enabled")?.bool ?? false,
                visible: row.column("visible")?.bool ?? false,
                featuredOrder: row.column("featured_order")?.integer.map { Int($0) },
                rowRevision: Int64(row.column("row_revision")?.integer ?? 0)
            )
        }.sorted(by: workflowRepositoryOrder)
        return ServerWorkflowRepositorySnapshot(
            workflows: workflows,
            includeSessionCleanupGuidance: state?.column("include_session_cleanup_guidance")?.bool ?? true,
            revision: Int64(state?.column("collection_revision")?.integer ?? 0),
            updatedAt: Date(timeIntervalSince1970: state?.column("updated_at")?.double ?? 0)
        )
    }

    @discardableResult
    func authorityStore_replaceWorkflowRepositorySnapshot(
        _ snapshot: ServerWorkflowRepositorySnapshot,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot {
        try validateWorkflowAudit(audit)
        let auditBytes = try retainedInputBytes([
            audit.operation,
            audit.attribution.actorID,
            audit.attribution.actorLabel,
            audit.attribution.channel,
            audit.payloadDigest,
        ])
        let retainedBytes = try retainedInputBytes(snapshot, additional: auditBytes)
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            let observed = Int64(try await database.query(
                "SELECT collection_revision FROM workflow_repository_state WHERE fixed_id=1"
            ).first?.column("collection_revision")?.integer ?? 0)
            guard observed == expectedRevision, snapshot.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .staleRevision, message: "Workflow repository revision is stale", currentRevision: observed)
            }

            let desiredIDs = Set(snapshot.workflows.map(\.workflowID))
            let customIDs = try await database.query("SELECT workflow_id FROM workflows WHERE source='custom'").compactMap { $0.column("workflow_id")?.string }
            for workflowID in customIDs where !desiredIDs.contains(workflowID) {
                _ = try await database.query("DELETE FROM workflow_repository_metadata WHERE workflow_id=?", [.text(workflowID)])
                _ = try await database.query("DELETE FROM workflows WHERE workflow_id=? AND source='custom'", [.text(workflowID)])
            }

            _ = try await database.query("UPDATE workflow_repository_metadata SET featured_order=NULL")
            for workflow in snapshot.workflows {
                _ = try await database.query(
                    "INSERT INTO workflows(workflow_id,schema_version,source,name,definition_json,content_digest,enabled) VALUES(?,1,?,?,?,?,?) ON CONFLICT(workflow_id) DO UPDATE SET source=excluded.source,name=excluded.name,definition_json=excluded.definition_json,content_digest=excluded.content_digest,enabled=excluded.enabled",
                    [
                        .text(workflow.workflowID),
                        .text(workflow.source.rawValue),
                        .text(workflow.name),
                        .text(workflow.definition),
                        .text(workflow.contentDigest),
                        .integer(workflow.enabled ? 1 : 0)
                    ]
                )
                _ = try await database.query(
                    "INSERT INTO workflow_repository_metadata(workflow_id,visible,featured_order,row_revision,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(workflow_id) DO UPDATE SET visible=excluded.visible,featured_order=excluded.featured_order,row_revision=excluded.row_revision,updated_at=excluded.updated_at",
                    [
                        .text(workflow.workflowID),
                        .integer(workflow.visible ? 1 : 0),
                        workflow.featuredOrder.map { SQLiteData.integer($0) } ?? .null,
                        .integer(Int(workflow.rowRevision)),
                        .float(snapshot.updatedAt.timeIntervalSince1970)
                    ]
                )
            }
            _ = try await database.query(
                "INSERT INTO workflow_repository_state(fixed_id,collection_revision,include_session_cleanup_guidance,updated_at) VALUES(1,?,1,?) ON CONFLICT(fixed_id) DO UPDATE SET collection_revision=excluded.collection_revision,updated_at=excluded.updated_at",
                [.integer(Int(snapshot.revision)), .float(snapshot.updatedAt.timeIntervalSince1970)]
            )
            _ = try await database.query(
                "INSERT INTO settings_audit(audit_id,domain,scope_id,prior_revision,new_revision,operation,actor_id,actor_label,channel,payload_digest,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [
                    .text(UUID().uuidString),
                    .text(ServerSettingsDomain.workflowRepository.rawValue),
                    .text("global"),
                    .integer(Int(observed)),
                    .integer(Int(snapshot.revision)),
                    .text(audit.operation),
                    .text(audit.attribution.actorID),
                    .text(audit.attribution.actorLabel),
                    .text(audit.attribution.channel),
                    .text(audit.payloadDigest),
                    .float(snapshot.updatedAt.timeIntervalSince1970)
                ]
            )
            return try await workflowRepositorySnapshot()
        }
    }

    @discardableResult
    func authorityStore_replaceWorkflowCleanupGuidance(
        _ includeSessionCleanupGuidance: Bool,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot {
        try validateWorkflowAudit(audit)
        let retainedBytes = try retainedInputBytes([
            audit.operation,
            audit.attribution.actorID,
            audit.attribution.actorLabel,
            audit.attribution.channel,
            audit.payloadDigest,
        ])
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            let now = Date()
            let observed = Int64(try await database.query(
                "SELECT collection_revision FROM workflow_repository_state WHERE fixed_id=1"
            ).first?.column("collection_revision")?.integer ?? 0)
            _ = try await database.query(
                "INSERT INTO workflow_repository_state(fixed_id,collection_revision,include_session_cleanup_guidance,updated_at) VALUES(1,0,?,?) ON CONFLICT(fixed_id) DO UPDATE SET include_session_cleanup_guidance=excluded.include_session_cleanup_guidance,updated_at=excluded.updated_at",
                [.integer(includeSessionCleanupGuidance ? 1 : 0), .float(now.timeIntervalSince1970)]
            )
            _ = try await database.query(
                "INSERT INTO settings_audit(audit_id,domain,scope_id,prior_revision,new_revision,operation,actor_id,actor_label,channel,payload_digest,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [
                    .text(UUID().uuidString),
                    .text(ServerSettingsDomain.workflowRepository.rawValue),
                    .text("global"),
                    .integer(Int(observed)),
                    .integer(Int(observed)),
                    .text(audit.operation),
                    .text(audit.attribution.actorID),
                    .text(audit.attribution.actorLabel),
                    .text(audit.attribution.channel),
                    .text(audit.payloadDigest),
                    .float(now.timeIntervalSince1970)
                ]
            )
            return try await workflowRepositorySnapshot()
        }
    }
}

private func workflowRepositoryOrder(_ lhs: ServerWorkflowDefinition, _ rhs: ServerWorkflowDefinition) -> Bool {
    switch (lhs.featuredOrder, rhs.featuredOrder) {
    case let (.some(left), .some(right)) where left != right:
        return left < right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        let left = lhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let right = rhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return (left, lhs.workflowID) < (right, rhs.workflowID)
    }
}

private func validateWorkflowAudit(_ mutation: ServerSettingsAuditMutation) throws {
    let values = [mutation.operation, mutation.attribution.actorID, mutation.attribution.actorLabel, mutation.attribution.channel]
    guard mutation.operation.range(of: "^[a-z][A-Za-z0-9]{0,63}$", options: .regularExpression) != nil,
          (1 ... 256).contains(mutation.attribution.actorID.utf8.count),
          (1 ... 128).contains(mutation.attribution.actorLabel.utf8.count),
          mutation.attribution.channel.range(of: "^[a-z][a-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
          mutation.payloadDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          values.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
          values.allSatisfy({ !ProviderSecretRedaction.containsLikelySecret($0) })
    else {
        throw ServiceAPIError(code: .invalidRequest, message: "Workflow audit metadata is invalid")
    }
}
