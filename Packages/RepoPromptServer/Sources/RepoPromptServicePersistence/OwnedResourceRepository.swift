import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

extension SQLiteServiceStore: OwnedResourceRepository {
    public func reserveOwnedResource(_ record: OwnedResourceRecord) async throws {
        try await transaction {
            if let externalID = record.externalID,
               let existing = try await ownedResource(externalID: externalID, kind: record.kind)
            {
                guard existing.internalPathIdentity == record.internalPathIdentity,
                      existing.temporaryPathIdentity == record.temporaryPathIdentity,
                      existing.metadata == record.metadata
                else {
                    throw ServiceAPIError(code: .worktreeConflict, message: "Owned resource identity is already reserved with different metadata")
                }
                return
            }
            do {
                _ = try await connection.query(
                    "INSERT INTO owned_resources(resource_id,schema_version,kind,project_id,session_id,run_id,external_id,internal_path_identity,temporary_path_identity,lifecycle_state,observed_bytes,content_digest,metadata_json,retention_deadline,cleanup_attempts,cleanup_error,created_at,updated_at) VALUES(?,2,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    [
                        .text(record.resourceID.uuidString), .text(record.kind.rawValue),
                        record.projectID.map { .text($0.uuidString) } ?? .null,
                        record.sessionID.map { .text($0.uuidString) } ?? .null,
                        record.runID.map { .text($0.uuidString) } ?? .null,
                        record.externalID.map { .text($0.uuidString) } ?? .null,
                        .text(record.internalPathIdentity),
                        record.temporaryPathIdentity.map(SQLiteData.text) ?? .null,
                        .text(record.lifecycleState.rawValue),
                        record.observedBytes.map { .integer(Int($0)) } ?? .null,
                        record.contentDigest.map(SQLiteData.text) ?? .null,
                        .text(encodeText(record.metadata)),
                        record.retentionDeadline.map { .float($0.timeIntervalSince1970) } ?? .null,
                        .integer(record.cleanupAttempts),
                        record.cleanupError.map(SQLiteData.text) ?? .null,
                        .float(record.createdAt.timeIntervalSince1970),
                        .float(record.updatedAt.timeIntervalSince1970)
                    ]
                )
            } catch let error as ServiceAPIError {
                throw error
            } catch {
                throw ServiceAPIError(code: .worktreeConflict, message: "Owned resource path is already reserved")
            }
        }
    }

    public func ownedResource(externalID: UUID, kind: OwnedResourceKind) async throws -> OwnedResourceRecord? {
        try await connection.query(
            "SELECT * FROM owned_resources WHERE external_id=? AND kind=? ORDER BY created_at DESC LIMIT 1",
            [.text(externalID.uuidString), .text(kind.rawValue)]
        ).first.map(decodeOwnedResource)
    }

    public func ownedResources(states: Set<OwnedResourceLifecycleState>? = nil) async throws -> [OwnedResourceRecord] {
        let records = try await connection.query("SELECT * FROM owned_resources ORDER BY created_at,resource_id").map(decodeOwnedResource)
        guard let states else { return records }
        return records.filter { states.contains($0.lifecycleState) }
    }

    public func activeOwnedWorktree(bindingID: UUID) async throws -> ActiveOwnedWorktreeSnapshot? {
        let row = try await connection.query(
            "SELECT w.binding_id,w.project_id,w.root_id,w.session_id,w.physical_path,w.branch,r.canonical_path AS source_root FROM worktree_bindings w JOIN project_roots r ON r.root_id=w.root_id AND r.project_id=w.project_id WHERE w.binding_id=? AND w.ownership_state='active' AND w.session_id IS NOT NULL AND r.writable=1",
            [.text(bindingID.uuidString)]
        ).first
        guard let row else { return nil }
        guard let bindingID = UUID(uuidString: row.column("binding_id")?.string ?? ""),
              let projectID = UUID(uuidString: row.column("project_id")?.string ?? ""),
              let rootID = UUID(uuidString: row.column("root_id")?.string ?? ""),
              let sessionID = UUID(uuidString: row.column("session_id")?.string ?? ""),
              let physicalPath = row.column("physical_path")?.string,
              let sourceRoot = row.column("source_root")?.string,
              let branch = row.column("branch")?.string
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted active worktree ownership is invalid")
        }
        return ActiveOwnedWorktreeSnapshot(
            bindingID: bindingID,
            projectID: projectID,
            rootID: rootID,
            sessionID: sessionID,
            physicalPath: physicalPath,
            sourceRoot: sourceRoot,
            branch: branch
        )
    }

    public func backfillActiveWorktreeContentDigest(
        resourceID: UUID,
        authority: ActiveOwnedWorktreeSnapshot,
        contentDigest: String
    ) async throws -> OwnedResourceRecord {
        try await transaction {
            guard let current = try await connection.query(
                "SELECT * FROM owned_resources WHERE resource_id=?",
                [.text(resourceID.uuidString)]
            ).first.map(decodeOwnedResource) else {
                throw ServiceAPIError(code: .notFound, message: "Owned worktree resource was not found")
            }
            if let existing = current.contentDigest {
                guard existing == contentDigest else {
                    throw ServiceAPIError(code: .worktreeConflict, message: "Owned worktree identity digest already differs")
                }
                return current
            }
            guard current.kind == .worktree,
                  current.lifecycleState == .active,
                  current.externalID == authority.bindingID,
                  current.projectID == authority.projectID,
                  current.sessionID == authority.sessionID,
                  current.internalPathIdentity == authority.physicalPath,
                  current.metadata["sourceRoot"] == authority.sourceRoot,
                  current.metadata["branch"] == authority.branch,
                  try await activeOwnedWorktree(bindingID: authority.bindingID) == authority
            else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Legacy worktree ownership no longer matches its durable binding")
            }
            let duplicates = try await connection.query(
                "SELECT binding_id FROM worktree_bindings WHERE project_id=? AND root_id=? AND session_id=? AND ownership_state='active' AND binding_id<>? LIMIT 1",
                [
                    .text(authority.projectID.uuidString),
                    .text(authority.rootID.uuidString),
                    .text(authority.sessionID.uuidString),
                    .text(authority.bindingID.uuidString)
                ]
            )
            guard duplicates.isEmpty else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Legacy worktree ownership is not unique")
            }
            _ = try await connection.query(
                "UPDATE owned_resources SET content_digest=?,updated_at=? WHERE resource_id=? AND content_digest IS NULL AND lifecycle_state='active'",
                [.text(contentDigest), .float(Date().timeIntervalSince1970), .text(resourceID.uuidString)]
            )
            guard let updated = try await connection.query(
                "SELECT * FROM owned_resources WHERE resource_id=?",
                [.text(resourceID.uuidString)]
            ).first.map(decodeOwnedResource), updated.contentDigest == contentDigest else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Legacy worktree identity backfill lost its compare-and-set")
            }
            return updated
        }
    }

    public func transitionOwnedResource(
        resourceID: UUID,
        expectedStates: Set<OwnedResourceLifecycleState>,
        to state: OwnedResourceLifecycleState,
        observedBytes: Int64?,
        contentDigest: String?,
        cleanupError: String?
    ) async throws -> OwnedResourceRecord {
        try await transaction {
            guard let current = try await connection.query(
                "SELECT * FROM owned_resources WHERE resource_id=?",
                [.text(resourceID.uuidString)]
            ).first.map(decodeOwnedResource) else {
                throw ServiceAPIError(code: .notFound, message: "Owned resource reservation was not found")
            }
            if current.lifecycleState == state { return current }
            guard expectedStates.contains(current.lifecycleState) else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Owned resource lifecycle transition is stale")
            }
            let updated = current.replacing(
                lifecycleState: state,
                observedBytes: observedBytes,
                contentDigest: contentDigest,
                cleanupError: cleanupError
            )
            _ = try await connection.query(
                "UPDATE owned_resources SET lifecycle_state=?,observed_bytes=?,content_digest=?,cleanup_attempts=?,cleanup_error=?,updated_at=? WHERE resource_id=? AND lifecycle_state=?",
                [
                    .text(updated.lifecycleState.rawValue),
                    updated.observedBytes.map { .integer(Int($0)) } ?? .null,
                    updated.contentDigest.map(SQLiteData.text) ?? .null,
                    .integer(updated.cleanupAttempts),
                    updated.cleanupError.map(SQLiteData.text) ?? .null,
                    .float(updated.updatedAt.timeIntervalSince1970),
                    .text(resourceID.uuidString),
                    .text(current.lifecycleState.rawValue)
                ]
            )
            return updated
        }
    }

    public func acquireWorktreeMergeLease(_ lease: WorktreeMergeLeaseRecord) async throws {
        do {
            _ = try await connection.query(
                "INSERT INTO worktree_merge_leases(lease_id,binding_id,expected_binding_revision,strategy,target_path,pre_merge_head,state,owner_instance_id,conflict_artifact_path,error_code,started_at,updated_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [
                    .text(lease.leaseID.uuidString), .text(lease.bindingID.uuidString), .integer(Int(lease.expectedBindingRevision)),
                    .text(lease.strategy), .text(lease.targetPath), .text(lease.preMergeHead), .text(lease.state.rawValue),
                    .text(lease.ownerInstanceID.uuidString), lease.conflictArtifactPath.map(SQLiteData.text) ?? .null,
                    lease.errorCode.map(SQLiteData.text) ?? .null, .float(lease.startedAt.timeIntervalSince1970),
                    .float(lease.updatedAt.timeIntervalSince1970), .float(lease.expiresAt.timeIntervalSince1970)
                ]
            )
        } catch {
            throw ServiceAPIError(code: .worktreeConflict, message: "A merge lease already owns this worktree binding")
        }
    }

    public func renewWorktreeMergeLease(leaseID: UUID, ownerInstanceID: UUID, expiresAt: Date) async throws {
        let current = try await connection.query(
            "SELECT state,owner_instance_id FROM worktree_merge_leases WHERE lease_id=?",
            [.text(leaseID.uuidString)]
        ).first
        guard current?.column("state")?.string == WorktreeMergeLeaseState.running.rawValue,
              current?.column("owner_instance_id")?.string == ownerInstanceID.uuidString
        else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Merge lease renewal is stale")
        }
        _ = try await connection.query(
            "UPDATE worktree_merge_leases SET expires_at=?,updated_at=? WHERE lease_id=? AND state='running' AND owner_instance_id=?",
            [.float(expiresAt.timeIntervalSince1970), .float(Date().timeIntervalSince1970), .text(leaseID.uuidString), .text(ownerInstanceID.uuidString)]
        )
    }

    public func transitionWorktreeMergeLease(
        leaseID: UUID,
        expectedStates: Set<WorktreeMergeLeaseState>,
        to state: WorktreeMergeLeaseState,
        conflictArtifactPath: String?,
        errorCode: String?
    ) async throws -> WorktreeMergeLeaseRecord {
        try await transaction {
            guard let row = try await connection.query("SELECT * FROM worktree_merge_leases WHERE lease_id=?", [.text(leaseID.uuidString)]).first else {
                throw ServiceAPIError(code: .notFound, message: "Merge lease was not found")
            }
            let current = try decodeMergeLease(row)
            if current.state == state { return current }
            guard expectedStates.contains(current.state) else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Merge lease transition is stale")
            }
            let now = Date()
            _ = try await connection.query(
                "UPDATE worktree_merge_leases SET state=?,conflict_artifact_path=?,error_code=?,updated_at=? WHERE lease_id=? AND state=?",
                [
                    .text(state.rawValue), conflictArtifactPath.map(SQLiteData.text) ?? .null,
                    errorCode.map(SQLiteData.text) ?? .null, .float(now.timeIntervalSince1970),
                    .text(leaseID.uuidString), .text(current.state.rawValue)
                ]
            )
            return WorktreeMergeLeaseRecord(
                leaseID: current.leaseID,
                bindingID: current.bindingID,
                expectedBindingRevision: current.expectedBindingRevision,
                strategy: current.strategy,
                targetPath: current.targetPath,
                preMergeHead: current.preMergeHead,
                state: state,
                ownerInstanceID: current.ownerInstanceID,
                conflictArtifactPath: conflictArtifactPath,
                errorCode: errorCode,
                startedAt: current.startedAt,
                updatedAt: now,
                expiresAt: current.expiresAt
            )
        }
    }

    public func worktreeMergeLeases(nonterminalOnly: Bool = false) async throws -> [WorktreeMergeLeaseRecord] {
        let rows = try await connection.query("SELECT * FROM worktree_merge_leases ORDER BY started_at,lease_id")
        let leases = try rows.map(decodeMergeLease)
        return nonterminalOnly ? leases.filter { !$0.state.isTerminal } : leases
    }

    public func ownedResourceHealth(now: Date = Date()) async throws -> OwnedResourceHealthSnapshot {
        // Readiness is polled continuously and provider probes retain bounded
        // lifecycle history. Aggregate in SQLite so health does not materialize
        // and decode every historical provider row on each poll.
        let aggregateRows = try await connection.query(
            "SELECT kind,lifecycle_state,COUNT(*) AS resource_count,COALESCE(SUM(observed_bytes),0) AS resource_bytes,MIN(updated_at) AS oldest_updated_at FROM owned_resources GROUP BY kind,lifecycle_state ORDER BY kind,lifecycle_state"
        )
        let aggregates = try aggregateRows.map { row -> OwnedResourceAggregate in
            guard let kind = row.column("kind")?.string.flatMap(OwnedResourceKind.init(rawValue:)),
                  let state = row.column("lifecycle_state")?.string.flatMap(OwnedResourceLifecycleState.init(rawValue:))
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted owned resource aggregate is invalid")
            }
            let oldest = row.column("oldest_updated_at")?.double.map(Date.init(timeIntervalSince1970:)) ?? now
            return .init(
                kind: kind,
                state: state,
                count: row.column("resource_count")?.integer ?? 0,
                bytes: Int64(row.column("resource_bytes")?.integer ?? 0),
                oldestAgeSeconds: max(0, now.timeIntervalSince(oldest))
            )
        }
        let core = try await connection.query(
            "SELECT COALESCE(SUM(CASE WHEN cleanup_error IS NOT NULL AND lifecycle_state<>'deleted' THEN 1 ELSE 0 END),0) AS cleanup_failures,COALESCE(SUM(CASE WHEN kind='artifact' AND lifecycle_state='missing' THEN 1 ELSE 0 END),0) AS missing_artifacts,COALESCE(SUM(CASE WHEN lifecycle_state IN ('missing','corrupt') THEN 1 ELSE 0 END),0) AS unhealthy_resources,COALESCE(SUM(CASE WHEN lifecycle_state IN ('preparing','prepared','cleanup_pending','quarantined') AND retention_deadline IS NOT NULL AND retention_deadline<=? THEN 1 ELSE 0 END),0) AS abandoned_reservations FROM owned_resources WHERE kind NOT IN ('provider_home','provider_credential_copy','provider_output')",
            [.float(now.timeIntervalSince1970)]
        ).first
        let lease = try await connection.query(
            "SELECT COALESCE(SUM(CASE WHEN state='conflicted' THEN 1 ELSE 0 END),0) AS conflicted_leases,COALESCE(SUM(CASE WHEN expires_at<=? AND state<>'conflicted' THEN 1 ELSE 0 END),0) AS expired_leases FROM worktree_merge_leases WHERE state NOT IN ('aborted','committed','failed')",
            [.float(now.timeIntervalSince1970)]
        ).first
        return OwnedResourceHealthSnapshot(
            aggregates: aggregates,
            cleanupFailures: core?.column("cleanup_failures")?.integer ?? 0,
            missingCommittedArtifacts: core?.column("missing_artifacts")?.integer ?? 0,
            unhealthyCommittedResources: core?.column("unhealthy_resources")?.integer ?? 0,
            abandonedReservations: core?.column("abandoned_reservations")?.integer ?? 0,
            conflictedMergeLeases: lease?.column("conflicted_leases")?.integer ?? 0,
            expiredMergeLeases: lease?.column("expired_leases")?.integer ?? 0
        )
    }

    func activatePreparedOwnedResourceIfPresent(externalID: UUID, kind: OwnedResourceKind, path: String, size: Int64? = nil, digest: String? = nil) async throws {
        guard let current = try await ownedResource(externalID: externalID, kind: kind) else { return }
        guard current.internalPathIdentity == URL(fileURLWithPath: path).standardizedFileURL.path,
              [.prepared, .active].contains(current.lifecycleState),
              size == nil || current.observedBytes == size,
              digest == nil || current.contentDigest == digest
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Prepared owned resource does not match durable publication")
        }
        guard current.lifecycleState != .active else { return }
        _ = try await connection.query(
            "UPDATE owned_resources SET lifecycle_state='active',updated_at=? WHERE resource_id=? AND lifecycle_state='prepared'",
            [.float(Date().timeIntervalSince1970), .text(current.resourceID.uuidString)]
        )
    }

    func commitPreparedMergeLeaseIfPresent(bindingID: UUID, expectedRevision: Int64) async throws {
        guard let row = try await connection.query(
            "SELECT lease_id FROM worktree_merge_leases WHERE binding_id=? AND expected_binding_revision=? AND state='prepared' ORDER BY started_at DESC LIMIT 1",
            [.text(bindingID.uuidString), .integer(Int(expectedRevision))]
        ).first, let leaseID = row.column("lease_id")?.string else { return }
        _ = try await connection.query(
            "UPDATE worktree_merge_leases SET state='committed',updated_at=? WHERE lease_id=? AND state='prepared'",
            [.float(Date().timeIntervalSince1970), .text(leaseID)]
        )
    }

    private func decodeOwnedResource(_ row: SQLiteRow) throws -> OwnedResourceRecord {
        guard let resourceID = UUID(uuidString: row.column("resource_id")?.string ?? ""),
              let kind = OwnedResourceKind(rawValue: row.column("kind")?.string ?? ""),
              let state = OwnedResourceLifecycleState(rawValue: row.column("lifecycle_state")?.string ?? "")
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted owned resource is invalid")
        }
        let metadataText = row.column("metadata_json")?.string ?? "{}"
        return try OwnedResourceRecord(
            resourceID: resourceID,
            kind: kind,
            projectID: row.column("project_id")?.string.flatMap(UUID.init(uuidString:)),
            sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)),
            runID: row.column("run_id")?.string.flatMap(UUID.init(uuidString:)),
            externalID: row.column("external_id")?.string.flatMap(UUID.init(uuidString:)),
            internalPathIdentity: row.column("internal_path_identity")?.string ?? "",
            temporaryPathIdentity: row.column("temporary_path_identity")?.string,
            lifecycleState: state,
            observedBytes: row.column("observed_bytes")?.integer.map(Int64.init),
            contentDigest: row.column("content_digest")?.string,
            metadata: decoder.decode([String: String].self, from: Data(metadataText.utf8)),
            retentionDeadline: row.column("retention_deadline")?.double.map(Date.init(timeIntervalSince1970:)),
            cleanupAttempts: row.column("cleanup_attempts")?.integer ?? 0,
            cleanupError: row.column("cleanup_error")?.string,
            createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0)
        )
    }

    private func decodeMergeLease(_ row: SQLiteRow) throws -> WorktreeMergeLeaseRecord {
        guard let leaseID = UUID(uuidString: row.column("lease_id")?.string ?? ""),
              let bindingID = UUID(uuidString: row.column("binding_id")?.string ?? ""),
              let state = WorktreeMergeLeaseState(rawValue: row.column("state")?.string ?? ""),
              let owner = UUID(uuidString: row.column("owner_instance_id")?.string ?? "")
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted merge lease is invalid")
        }
        return WorktreeMergeLeaseRecord(
            leaseID: leaseID,
            bindingID: bindingID,
            expectedBindingRevision: Int64(row.column("expected_binding_revision")?.integer ?? 0),
            strategy: row.column("strategy")?.string ?? "",
            targetPath: row.column("target_path")?.string ?? "",
            preMergeHead: row.column("pre_merge_head")?.string ?? "",
            state: state,
            ownerInstanceID: owner,
            conflictArtifactPath: row.column("conflict_artifact_path")?.string,
            errorCode: row.column("error_code")?.string,
            startedAt: Date(timeIntervalSince1970: row.column("started_at")?.double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0),
            expiresAt: Date(timeIntervalSince1970: row.column("expires_at")?.double ?? 0)
        )
    }
}
