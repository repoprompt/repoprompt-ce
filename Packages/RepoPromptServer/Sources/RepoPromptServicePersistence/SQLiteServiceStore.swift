import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptServerOperations
import SQLiteNIO

public struct PersistedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let sessionID: Int32
    public let startTimeTicks: UInt64
    public let bootID: String
    public let executablePath: String
    public let helperTokenDigest: String

    public init(pid: Int32, parentPID: Int32, processGroupID: Int32, sessionID: Int32, startTimeTicks: UInt64, bootID: String, executablePath: String, helperTokenDigest: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.startTimeTicks = startTimeTicks
        self.bootID = bootID
        self.executablePath = executablePath
        self.helperTokenDigest = helperTokenDigest
    }
}

public struct PersistedProcessFamily: Codable, Hashable, Sendable {
    public let runID: UUID
    public let leader: PersistedProcessIdentity
    public let connectionGeneration: Int64
    public let containmentMode: String
    public let state: String
}

public actor SQLiteServiceStore: RepoPromptAuthorityStore {
    public typealias Metadata = AuthorityStoreMetadata

    public enum Storage: Sendable { case memory, file(String) }

    let connection: SQLiteConnection
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    private let eventSigningKey: PersistenceEventSigningKey?
    private let faultInjector: PersistenceFaultInjector
    let storagePath: String?
    private var closed = false
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private init(connection: SQLiteConnection, eventSigningKey: PersistenceEventSigningKey?, faultInjector: PersistenceFaultInjector, storagePath: String?) {
        self.connection = connection
        self.eventSigningKey = eventSigningKey
        self.faultInjector = faultInjector
        self.storagePath = storagePath
        encoder = JSONEncoder.serviceEncoder
        decoder = JSONDecoder.serviceDecoder
    }

    deinit {
        guard !closed else { return }
        // Explicit close remains authoritative because it records clean
        // shutdown and checkpoints WAL. This safety net prevents SQLiteNIO's
        // deinit assertion from masking the original error when construction
        // or an async caller unwinds before reaching that close boundary.
        let connection = connection
        Task { try? await connection.close() }
    }

    public static func open(storage: Storage, eventSigningKey: PersistenceEventSigningKey? = nil, faultInjector: PersistenceFaultInjector = .none) async throws -> SQLiteServiceStore {
        let location: SQLiteConnection.Storage = switch storage { case .memory: .memory
        case let .file(path): .file(path: path) }
        let connection = try await SQLiteConnection.open(storage: location)
        let store = SQLiteServiceStore(
            connection: connection,
            eventSigningKey: eventSigningKey,
            faultInjector: faultInjector,
            storagePath: {
                if case let .file(path) = storage { return path }
                return nil
            }()
        )
        try await store.migrate()
        try await store.integrityCheck()
        return store
    }

    /// Named offline seam used only after `AuthorityMaintenanceSession` owns the
    /// namespace lease. PR3 preserves the frozen V1-V6 opening behavior here;
    /// PR4 owns any new migration command, schema, backup, or verification work.
    public static func openForMaintenance(
        storage: Storage,
        eventSigningKey: PersistenceEventSigningKey? = nil,
        faultInjector: PersistenceFaultInjector = .none
    ) async throws -> SQLiteServiceStore {
        try await open(
            storage: storage,
            eventSigningKey: eventSigningKey,
            faultInjector: faultInjector
        )
    }

    /// Serving never advances a nonempty store. A brand-new empty database may
    /// be initialized to the frozen current schema; every other pending schema
    /// is refused without DDL or migration-ledger mutation.
    public static func openForServing(
        storage: Storage,
        eventSigningKey: PersistenceEventSigningKey? = nil,
        faultInjector: PersistenceFaultInjector = .none
    ) async throws -> SQLiteServiceStore {
        let fileState = try servingFileState(storage)
        let location: SQLiteConnection.Storage = switch storage {
        case .memory: .memory
        case let .file(path): .file(path: path)
        }
        let connection = try await SQLiteConnection.open(storage: location)
        let store = SQLiteServiceStore(
            connection: connection,
            eventSigningKey: eventSigningKey,
            faultInjector: faultInjector,
            storagePath: {
                if case let .file(path) = storage { return path }
                return nil
            }()
        )
        do {
            switch fileState {
            case .newStore:
                try await store.migrate()
            case .existingSQLite:
                let identityRows = try await connection.query(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('service_metadata','schema_migrations') ORDER BY name"
                )
                let identityTables = Set(identityRows.compactMap { $0.column("name")?.string })
                guard identityTables == Set(["schema_migrations", "service_metadata"]) else {
                    throw ServiceAPIError(
                        code: .authorityPurposeMismatch,
                        message: "SQLite file is foreign or has an ambiguous RepoPrompt authority identity"
                    )
                }
                try await store.validateCurrentServingSchema()
            }
            try await store.integrityCheck()
            return store
        } catch {
            try? await store.close(clean: false)
            throw error
        }
    }

    private func validateCurrentServingSchema() async throws {
        let metadataRows = try await connection.query(
            "SELECT schema_version FROM service_metadata WHERE fixed_id=1"
        )
        guard metadataRows.count == 1,
              let metadataVersion = metadataRows.first?.column("schema_version")?.integer
        else {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Authority store metadata is missing or ambiguous"
            )
        }
        let expectedMigrations = [
            1: "v1",
            SchemaV2.version: SchemaV2.digest,
            SchemaV3.version: SchemaV3.digest,
            SchemaV4.version: SchemaV4.digest,
            SchemaV5.version: SchemaV5.digest,
            SchemaV6.version: SchemaV6.digest
        ]
        let rows = try await connection.query("SELECT version,digest FROM schema_migrations ORDER BY version")
        var migrations: [Int: String] = [:]
        for row in rows {
            guard let version = row.column("version")?.integer,
                  let digest = row.column("digest")?.string,
                  migrations[version] == nil,
                  expectedMigrations[version] == digest
            else {
                throw ServiceAPIError(
                    code: .authorityPurposeMismatch,
                    message: "Authority migration ledger is malformed or unrecognized"
                )
            }
            migrations[version] = digest
        }
        guard (1 ... SchemaV6.version).contains(metadataVersion),
              migrations[1] == expectedMigrations[1],
              migrations[metadataVersion] == expectedMigrations[metadataVersion]
        else {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Authority migration ledger does not identify a recognized store"
            )
        }
        guard metadataVersion == SchemaV6.version,
              migrations == expectedMigrations
        else {
            throw ServiceAPIError(
                code: .migrationRequired,
                message: "Authority store requires offline migration before serving",
                retryable: false
            )
        }
    }

    private enum ServingFileState {
        case newStore
        case existingSQLite
    }

    private static func servingFileState(_ storage: Storage) throws -> ServingFileState {
        guard case let .file(path) = storage else { return .newStore }
        guard FileManager.default.fileExists(atPath: path) else { return .newStore }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Unable to inspect authority store before serving"
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Authority store path is not a regular file"
            )
        }
        guard size.int64Value > 0 else { return .newStore }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            header = try handle.read(upToCount: 16) ?? Data()
        } catch {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Unable to read authority store header before serving"
            )
        }
        guard header == Data("SQLite format 3\0".utf8) else {
            throw ServiceAPIError(
                code: .authorityPurposeMismatch,
                message: "Nonempty authority store is not SQLite"
            )
        }
        return .existingSQLite
    }

    public func close(clean: Bool = true) async throws {
        guard !closed else { return }
        if clean {
            _ = try await connection.query("UPDATE service_metadata SET last_clean_shutdown = 1 WHERE fixed_id = 1")
            _ = try await connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try await connection.close()
        closed = true
    }

    public func authorityStore_metadata() async throws -> Metadata {
        let row = try await requireRow(connection.query("SELECT store_id, schema_version, next_global_sequence, replay_floor, last_clean_shutdown, activation_state, activation_generation, activation_instance_id FROM service_metadata WHERE fixed_id = 1"))
        return try Metadata(
            storeID: requireUUID(row.column("store_id")?.string),
            schemaVersion: row.column("schema_version")?.integer ?? 1,
            nextGlobalSequence: Int64(row.column("next_global_sequence")?.integer ?? 1),
            replayFloor: Int64(row.column("replay_floor")?.integer ?? 0),
            lastCleanShutdown: row.column("last_clean_shutdown")?.bool ?? false,
            activationState: row.column("activation_state")?.string ?? "active",
            activationGeneration: Int64(row.column("activation_generation")?.integer ?? 1),
            activationInstanceID: row.column("activation_instance_id")?.string.flatMap(UUID.init(uuidString:))
        )
    }

    public func authorityStore_nextCursor() async throws -> ServiceCursor {
        let value = try await metadata()
        return ServiceCursor(storeID: value.storeID, globalSequence: value.nextGlobalSequence)
    }

    public func authorityStore_persistServiceDiagnostic(
        projectID: UUID,
        actor: ExternalActor?,
        correlationID: UUID,
        payload: Data
    ) async throws -> EventEnvelope {
        try await transaction {
            try await appendEvent(
                projectID: projectID,
                sessionID: nil,
                rootSessionID: nil,
                runID: nil,
                sessionSequence: nil,
                type: .serviceDiagnostic,
                generation: nil,
                turnEpoch: nil,
                actor: actor,
                correlationID: correlationID,
                payload: payload
            )
        }
    }

    public func authorityStore_persistProject(
        _ snapshot: ProjectSnapshot,
        rootIdentities: [UUID: String] = [:],
        eventType: EventType,
        actor: ExternalActor,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        expectedRevision: Int64? = nil,
        idempotencyResponse: Data? = nil,
        idempotencyStatus: Int? = nil
    ) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            if let expectedRevision {
                let observed = try await Int64(connection.query(
                    "SELECT revision FROM projects WHERE project_id=?",
                    [.text(snapshot.projectID.uuidString)]
                ).first?.column("revision")?.integer ?? 0)
                guard observed == expectedRevision, snapshot.revision == expectedRevision + 1 else {
                    throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: observed)
                }
            }
            try await validateExpectedCursor(snapshot.cursor)
            let snapshotJSON = try encodeText(snapshot)
            _ = try await connection.query(
                "INSERT INTO projects(project_id, schema_version, name, creator_json, lifecycle_state, revision, snapshot_json, created_at, updated_at) VALUES(?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(project_id) DO UPDATE SET name=excluded.name,lifecycle_state=excluded.lifecycle_state,revision=excluded.revision,snapshot_json=excluded.snapshot_json,updated_at=CURRENT_TIMESTAMP",
                [.text(snapshot.projectID.uuidString), .text(snapshot.name), .text(encodeText(actor)), .text(snapshot.state.rawValue), .integer(Int(snapshot.revision)), .text(snapshotJSON)]
            )
            let existingRootIdentities = try await projectRootIdentities(projectID: snapshot.projectID)
            _ = try await connection.query("DELETE FROM project_roots WHERE project_id=?", [.text(snapshot.projectID.uuidString)])
            for root in snapshot.roots {
                let identity = rootIdentities[root.rootID] ?? existingRootIdentities[root.rootID] ?? "pending"
                _ = try await connection.query("INSERT INTO project_roots(root_id,project_id,schema_version,logical_name,canonical_path,filesystem_identity,writable,revision) VALUES(?,?,1,?,?,?,?,?) ON CONFLICT(root_id) DO UPDATE SET logical_name=excluded.logical_name,canonical_path=excluded.canonical_path,filesystem_identity=excluded.filesystem_identity,writable=excluded.writable,revision=excluded.revision", [.text(root.rootID.uuidString), .text(snapshot.projectID.uuidString), .text(root.logicalName), .text(root.canonicalPath), .text(identity), .integer(root.writable ? 1 : 0), .integer(Int(root.revision))])
                try await activatePreparedOwnedResourceIfPresent(
                    externalID: root.rootID,
                    kind: .cloneStaging,
                    path: root.canonicalPath
                )
            }
            if let legacySourceRoot = snapshot.roots.first {
                try await activatePreparedOwnedResourceIfPresent(
                    externalID: snapshot.projectID,
                    kind: .cloneStaging,
                    path: legacySourceRoot.canonicalPath
                )
            }
            let eventPayload = try encoder.encode(ProjectEventWirePayload(snapshot))
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: eventType, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: eventPayload)
            if let idempotency {
                let status = idempotencyStatus ?? (eventType == .projectCreated ? 201 : 200)
                try await saveIdempotency(idempotency, status: status, response: idempotencyResponse ?? encoder.encode(snapshot))
            }
            return event
        }
    }

    public func authorityStore_persistSession(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data? = nil,
        initialSelection: SelectionSnapshot? = nil
    ) async throws -> EventEnvelope {
        try await transaction {
            try await persistSessionInTransaction(snapshot, eventType: eventType, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: idempotencyResponse, initialSelection: initialSelection)
        }
    }

    public func authorityStore_persistNewSession(
        _ snapshot: SessionSnapshot,
        agent: AgentSnapshot,
        actor: ExternalActor,
        correlationID: UUID,
        agentCorrelationID: UUID,
        idempotency: IdempotencyInput,
        initialSelection: SelectionSnapshot,
        initialPermissions: ExecutionPermissionSnapshot,
        initialCollaboration: CollaborationMetadataSnapshot,
        initialWorktrees: [WorktreeBindingSnapshot] = []
    ) async throws -> (session: EventEnvelope, agent: EventEnvelope, worktrees: [EventEnvelope]) {
        try await transaction {
            try await persistNewSessionInTransaction(snapshot, agent: agent, actor: actor, correlationID: correlationID, agentCorrelationID: agentCorrelationID, idempotency: idempotency, initialSelection: initialSelection, initialPermissions: initialPermissions, initialCollaboration: initialCollaboration, initialWorktrees: initialWorktrees)
        }
    }

    func persistNewSessionInTransaction(
        _ snapshot: SessionSnapshot,
        agent: AgentSnapshot,
        actor: ExternalActor,
        correlationID: UUID,
        agentCorrelationID: UUID,
        idempotency: IdempotencyInput?,
        initialSelection: SelectionSnapshot,
        initialPermissions: ExecutionPermissionSnapshot,
        initialCollaboration: CollaborationMetadataSnapshot,
        initialWorktrees: [WorktreeBindingSnapshot]
    ) async throws -> (session: EventEnvelope, agent: EventEnvelope, worktrees: [EventEnvelope]) {
        let sessionEvent = try await persistSessionInTransaction(snapshot, eventType: .sessionCreated, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: nil, initialSelection: initialSelection)
        try await upsertPermissions(initialPermissions)
        try await upsertCollaboration(initialCollaboration)
        let agentEvent = try await persistAgentInTransaction(agent, projectID: snapshot.projectID, actor: snapshot.parentSessionID == nil ? actor : nil, correlationID: agentCorrelationID, eventType: .agentStarted)
        var worktreeEvents: [EventEnvelope] = []
        for worktree in initialWorktrees {
            guard worktree.projectID == snapshot.projectID, worktree.sessionID == snapshot.sessionID else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Initial worktree does not belong to the new session")
            }
            try await ensureUniqueActiveWorktree(worktree)
            _ = try await connection.query(
                "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?)",
                [.text(worktree.bindingID.uuidString), .text(worktree.projectID.uuidString), .text(worktree.rootID.uuidString), .text(snapshot.sessionID.uuidString), .text(worktree.baseRef), .text(worktree.branch), .text(worktree.physicalPath), .text(worktree.ownershipState.rawValue), .text(worktree.mergeState.rawValue), .integer(Int(worktree.revision))]
            )
            try await activatePreparedOwnedResourceIfPresent(externalID: worktree.bindingID, kind: .worktree, path: worktree.physicalPath)
            try await worktreeEvents.append(appendEvent(
                projectID: snapshot.projectID,
                sessionID: snapshot.sessionID,
                rootSessionID: snapshot.rootSessionID,
                runID: nil,
                sessionSequence: nil,
                type: .worktreeCreated,
                generation: snapshot.runGeneration,
                turnEpoch: snapshot.turnEpoch,
                actor: actor,
                correlationID: correlationID,
                payload: encoder.encode(worktree)
            ))
        }
        return (sessionEvent, agentEvent, worktreeEvents)
    }

    public func persistImportedProject(_ snapshot: ProjectSnapshot, sourceDigest: String, actor: ExternalActor) async throws -> Bool {
        try await transaction {
            if try await importAuditExists(kind: "legacy.project", digest: sourceDigest) { return false }
            if try await project(id: snapshot.projectID) != nil {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Legacy import project ID already exists with different provenance")
            }
            try await validateExpectedCursor(snapshot.cursor)
            let snapshotJSON = try encodeText(snapshot)
            _ = try await connection.query(
                "INSERT INTO projects(project_id,schema_version,name,creator_json,lifecycle_state,revision,snapshot_json,created_at,updated_at) VALUES(?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                [.text(snapshot.projectID.uuidString), .text(snapshot.name), .text(encodeText(actor)), .text(snapshot.state.rawValue), .integer(Int(snapshot.revision)), .text(snapshotJSON)]
            )
            for root in snapshot.roots {
                _ = try await connection.query("INSERT INTO project_roots(root_id,project_id,schema_version,logical_name,canonical_path,filesystem_identity,writable,revision) VALUES(?,?,1,?,?,?,?,?)", [.text(root.rootID.uuidString), .text(snapshot.projectID.uuidString), .text(root.logicalName), .text(root.canonicalPath), .text("legacy-import"), .integer(root.writable ? 1 : 0), .integer(Int(root.revision))])
            }
            let eventPayload = try encoder.encode(ProjectEventWirePayload(snapshot))
            _ = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: .projectCreated, generation: nil, turnEpoch: nil, actor: actor, correlationID: UUID(), payload: eventPayload)
            try await recordImportAudit(kind: "legacy.project", digest: sourceDigest)
            return true
        }
    }

    public func persistImportedSession(_ snapshot: SessionSnapshot, sourceDigest: String, actor: ExternalActor) async throws -> Bool {
        try await transaction {
            if try await importAuditExists(kind: "legacy.session", digest: sourceDigest) { return false }
            if try await session(id: snapshot.sessionID) != nil {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Legacy import session ID already exists with different provenance")
            }
            try await validateExpectedCursor(snapshot.cursor)
            let snapshotJSON = try encodeText(snapshot)
            let bindings: [SQLiteData] = [
                .text(snapshot.sessionID.uuidString), .text(snapshot.projectID.uuidString), snapshot.parentSessionID.map { .text($0.uuidString) } ?? .null,
                .text(snapshot.rootSessionID.uuidString), .text(snapshot.creator.userID), .text(snapshot.state.rawValue), .text(snapshot.provider.rawValue),
                snapshot.model.map(SQLiteData.text) ?? .null, .text(snapshot.visibility.rawValue), .integer(Int(snapshot.runGeneration)), .integer(Int(snapshot.turnEpoch)),
                .integer(Int(snapshot.revision)), .text(snapshotJSON)
            ]
            _ = try await connection.query("INSERT INTO sessions(session_id,project_id,parent_session_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,model,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)", bindings)
            for entry in snapshot.transcript {
                _ = try await connection.query("INSERT INTO transcript_entries(session_id,entry_id,schema_version,session_sequence,entry_json,content_digest) VALUES(?,?,1,?,?,?)", [.text(snapshot.sessionID.uuidString), .text(entry.entryID.uuidString), .integer(Int(entry.sessionSequence)), .text(encodeText(entry)), .text(PersistenceCryptography.bodyDigest(encoder.encode(entry)))])
            }
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: nil, type: .sessionCreated, generation: snapshot.runGeneration, turnEpoch: snapshot.turnEpoch, actor: actor, correlationID: UUID(), payload: Data(snapshotJSON.utf8))
            if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) {
                try await saveCheckpoint(scope: "session:\(snapshot.sessionID.uuidString)", sequence: event.globalSequence, snapshot: Data(snapshotJSON.utf8), retentionClass: "terminal")
            }
            try await recordImportAudit(kind: "legacy.session", digest: sourceDigest)
            return true
        }
    }

    public func beginLegacyImport(sourceDigest: String) async throws {
        let meta = try await metadata()
        let started = try await importAuditExists(kind: "legacy.import.started", digest: sourceDigest)
        let completed = try await importAuditExists(kind: "legacy.import.completed", digest: sourceDigest)
        let resumable = started && !completed
        guard meta.lastCleanShutdown || meta.nextGlobalSequence == 1 || resumable else {
            throw ServiceAPIError(code: .quiescing, message: "JSON import requires a new, cleanly stopped, or resumable import store")
        }
        if !resumable, !completed {
            try await transaction { try await recordImportAudit(kind: "legacy.import.started", digest: sourceDigest) }
        }
    }

    public func completeLegacyImport(sourceDigest: String) async throws {
        guard try await !importAuditExists(kind: "legacy.import.completed", digest: sourceDigest) else { return }
        try await transaction { try await recordImportAudit(kind: "legacy.import.completed", digest: sourceDigest) }
    }

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        guard let row = try await connection.query("SELECT snapshot_json FROM projects WHERE project_id = ?", [.text(id.uuidString)]).first, let text = row.column("snapshot_json")?.string else { return nil }
        return try decoder.decode(ProjectSnapshot.self, from: Data(text.utf8))
    }

    public func authorityStore_projectRootIdentities(projectID: UUID) async throws -> [UUID: String] {
        let rows = try await connection.query(
            "SELECT root_id, filesystem_identity FROM project_roots WHERE project_id = ?",
            [.text(projectID.uuidString)]
        )
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            try (requireUUID(row.column("root_id")?.string), row.column("filesystem_identity")?.string ?? "pending")
        })
    }

    public func session(id: UUID) async throws -> SessionSnapshot? {
        guard let row = try await connection.query("SELECT snapshot_json FROM sessions WHERE session_id = ?", [.text(id.uuidString)]).first, let text = row.column("snapshot_json")?.string else { return nil }
        return try decoder.decode(SessionSnapshot.self, from: Data(text.utf8))
    }

    /// Reads the base session and its interaction authority in one SQLite read
    /// transaction so adapters never observe an impossible lifecycle/interaction
    /// combination assembled across two revisions.
    public func authorityStore_sessionWithInteractions(id: UUID) async throws -> SessionSnapshot? {
        try await transaction {
            guard let base = try await session(id: id) else { return nil }
            let currentInteractions = try await interactions(sessionID: id)
            return base.replacing(interactions: currentInteractions)
        }
    }

    public func authorityStore_allProjects() async throws -> [ProjectSnapshot] {
        try await decodeRows("SELECT snapshot_json FROM projects WHERE lifecycle_state != 'archived' ORDER BY created_at", as: ProjectSnapshot.self)
    }

    public func authorityStore_allSessions() async throws -> [SessionSnapshot] {
        try await decodeRows("SELECT snapshot_json FROM sessions ORDER BY created_at", as: SessionSnapshot.self)
    }

    public func authorityStore_allSessionsWithInteractions() async throws -> [SessionSnapshot] {
        try await transaction {
            let sessions = try await allSessions()
            var result: [SessionSnapshot] = []
            for base in sessions {
                let currentInteractions = try await interactions(sessionID: base.sessionID)
                result.append(base.replacing(interactions: currentInteractions))
            }
            return result
        }
    }

    public func authorityStore_persistAgent(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope {
        try await transaction {
            try await persistAgentInTransaction(snapshot, projectID: projectID, actor: actor, correlationID: correlationID, eventType: eventType)
        }
    }

    public func authorityStore_persistToolInvocation(
        _ snapshot: ToolInvocationSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor?,
        correlationID: UUID,
        eventType: EventType
    ) async throws -> EventEnvelope {
        guard [.toolStarted, .toolUpdated, .toolCompleted, .toolFailed].contains(eventType) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Tool invocation requires a tool event type")
        }
        let run = try await latestRun(sessionID: session.sessionID)
        return try await transaction {
            try await appendEvent(
                projectID: session.projectID,
                sessionID: session.sessionID,
                agentID: session.sessionID,
                parentAgentID: session.parentSessionID,
                rootSessionID: session.rootSessionID,
                runID: run?.runID,
                sessionSequence: nil,
                type: eventType,
                generation: session.runGeneration,
                turnEpoch: session.turnEpoch,
                actor: actor,
                correlationID: correlationID,
                payload: encoder.encode(snapshot)
            )
        }
    }

    public func authorityStore_agents(rootSessionID: UUID? = nil) async throws -> [AgentSnapshot] {
        let rows = if let rootSessionID {
            try await connection.query("SELECT * FROM agents WHERE root_session_id=? ORDER BY created_at", [.text(rootSessionID.uuidString)])
        } else {
            try await connection.query("SELECT * FROM agents ORDER BY created_at")
        }
        return try rows.map { row in
            guard let agentID = UUID(uuidString: row.column("agent_id")?.string ?? ""),
                  let sessionID = UUID(uuidString: row.column("session_id")?.string ?? ""),
                  let rootID = UUID(uuidString: row.column("root_session_id")?.string ?? ""),
                  let state = SessionLifecycleState(rawValue: row.column("lifecycle_state")?.string ?? "")
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted agent is invalid") }
            return AgentSnapshot(agentID: agentID, sessionID: sessionID, rootSessionID: rootID, parentAgentID: row.column("parent_agent_id")?.string.flatMap(UUID.init(uuidString:)), providerNativeIdentity: row.column("provider_native_identity")?.string, role: row.column("role")?.string ?? "agent", label: row.column("label")?.string, state: state, revision: Int64(row.column("revision")?.integer ?? 1))
        }
    }

    public func authorityStore_persistRun(_ snapshot: ProviderRunSnapshot) async throws {
        _ = try await connection.query(
            "INSERT INTO runs(run_id,session_id,schema_version,provider_kind,provider_session_id,state,generation,turn_epoch,start_reason,end_reason,started_at,ended_at) VALUES(?,?,1,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET provider_session_id=excluded.provider_session_id,state=excluded.state,turn_epoch=excluded.turn_epoch,end_reason=excluded.end_reason,ended_at=excluded.ended_at",
            [.text(snapshot.runID.uuidString), .text(snapshot.sessionID.uuidString), .text(snapshot.provider.rawValue), snapshot.providerSessionID.map(SQLiteData.text) ?? .null, .text(snapshot.state), .integer(Int(snapshot.generation)), .integer(Int(snapshot.turnEpoch)), .text(snapshot.startReason), snapshot.endReason.map(SQLiteData.text) ?? .null, .float(snapshot.startedAt.timeIntervalSince1970), snapshot.endedAt.map { .float($0.timeIntervalSince1970) } ?? .null]
        )
    }

    public func authorityStore_latestRun(sessionID: UUID) async throws -> ProviderRunSnapshot? {
        guard let row = try await connection.query("SELECT * FROM runs WHERE session_id=? ORDER BY generation DESC LIMIT 1", [.text(sessionID.uuidString)]).first,
              let runID = UUID(uuidString: row.column("run_id")?.string ?? ""),
              let provider = ProviderKind(rawValue: row.column("provider_kind")?.string ?? ""),
              let state = row.column("state")?.string,
              let startReason = row.column("start_reason")?.string
        else { return nil }
        return ProviderRunSnapshot(runID: runID, sessionID: sessionID, provider: provider, providerSessionID: row.column("provider_session_id")?.string, state: state, generation: Int64(row.column("generation")?.integer ?? 0), turnEpoch: Int64(row.column("turn_epoch")?.integer ?? 0), startReason: startReason, endReason: row.column("end_reason")?.string, startedAt: Date(timeIntervalSince1970: row.column("started_at")?.double ?? 0), endedAt: row.column("ended_at")?.double.map(Date.init(timeIntervalSince1970:)))
    }

    public func authorityStore_events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        let meta = try await metadata()
        if let cursor {
            guard cursor.storeID == meta.storeID else { throw ServiceAPIError(code: .cursorExpired, message: "Store namespace changed", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.replayFloor)) }
            guard cursor.globalSequence >= meta.replayFloor else { throw ServiceAPIError(code: .cursorExpired, message: "Cursor is below replay floor", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.replayFloor)) }
        }
        let after = cursor?.globalSequence ?? meta.replayFloor
        let bounded = max(1, min(limit, 1000))
        let rows = try await connection.query("SELECT envelope_json FROM events WHERE global_sequence > ? ORDER BY global_sequence LIMIT ?", [.integer(Int(after)), .integer(bounded)])
        let events: [EventEnvelope] = try rows.compactMap { row in guard let text = row.column("envelope_json")?.string else { return nil }
            let decoded = try decoder.decode(EventEnvelope.self, from: Data(text.utf8))
            return try canonicalEventForPublication(decoded)
        }
        return EventPage(storeID: meta.storeID, events: events, nextCursor: events.last?.cursor ?? ServiceCursor(storeID: meta.storeID, globalSequence: after), replayFloor: meta.replayFloor)
    }

    public func authorityStore_idempotencyResult(_ input: IdempotencyInput) async throws -> (response: Data, status: Int)? {
        guard let value = try await existingIdempotency(input) else {
            try await faultInjector.hit(.afterIdempotencyPreflightMiss)
            return nil
        }
        return (response: value.0, status: value.1)
    }

    public func authorityStore_persistSelection(_ snapshot: SelectionSnapshot, projectID: UUID, rootSessionID: UUID, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET selection_json=excluded.selection_json,selection_revision=excluded.selection_revision,binding_revision=excluded.binding_revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(snapshot.sessionID.uuidString), .text(encodeText(Array(Set(snapshot.entries.map(\.rootID))))), .text(encodeText(snapshot)), .integer(Int(snapshot.revision)), .integer(Int(snapshot.bindingRevision)), .text(UUID().uuidString)]
            )
            let event = try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, rootSessionID: rootSessionID, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func authorityStore_selection(sessionID: UUID) async throws -> SelectionSnapshot? {
        guard let text = try await connection.query("SELECT selection_json FROM session_selections WHERE session_id=?", [.text(sessionID.uuidString)]).first?.column("selection_json")?.string else { return nil }
        return try decoder.decode(SelectionSnapshot.self, from: Data(text.utf8))
    }

    public func authorityStore_sessionContext(sessionID: UUID) async throws -> SessionContextSnapshot? {
        guard let row = try await connection.query(
            "SELECT prompt_text,selection_revision,context_revision FROM session_contexts WHERE session_id=?",
            [.text(sessionID.uuidString)]
        ).first else { return nil }
        return SessionContextSnapshot(
            sessionID: sessionID,
            prompt: row.column("prompt_text")?.string ?? "",
            selectionRevision: Int64(row.column("selection_revision")?.integer ?? 1),
            contextRevision: Int64(row.column("context_revision")?.integer ?? 1)
        )
    }

    public func authorityStore_persistSessionContext(
        _ snapshot: SessionContextSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> EventEnvelope {
        try await transaction {
            _ = try await connection.query(
                "INSERT INTO session_contexts(session_id,schema_version,prompt_text,selection_revision,context_revision,frozen_context_json,updated_at) VALUES(?,1,?,?,?,'{}',CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET prompt_text=excluded.prompt_text,selection_revision=excluded.selection_revision,context_revision=excluded.context_revision,updated_at=CURRENT_TIMESTAMP",
                [
                    .text(snapshot.sessionID.uuidString),
                    .text(snapshot.prompt),
                    .integer(Int(snapshot.selectionRevision)),
                    .integer(Int(snapshot.contextRevision))
                ]
            )
            return try await appendEvent(
                projectID: session.projectID,
                sessionID: session.sessionID,
                rootSessionID: session.rootSessionID,
                runID: nil,
                sessionSequence: nil,
                type: .contextUpdated,
                generation: session.runGeneration,
                turnEpoch: session.turnEpoch,
                actor: actor,
                correlationID: correlationID,
                payload: encoder.encode(snapshot)
            )
        }
    }

    /// Writes the composer context-window meter without bumping session revision
    /// or emitting a transcript event. Desktop updates this in memory on every
    /// usage frame; Linux persists the same fields so the portal ring can poll.
    public func authorityStore_upsertContextUsage(_ usage: ContextUsageWireSnapshot, sessionID: UUID) async throws {
        try await transaction {
            guard let base = try await session(id: sessionID) else { return }
            let next = base.replacing(contextUsage: usage.merging(onto: base.contextUsage))
            _ = try await connection.query(
                "UPDATE sessions SET snapshot_json=?, updated_at=CURRENT_TIMESTAMP WHERE session_id=?",
                [.text(try encodeText(next)), .text(sessionID.uuidString)]
            )
        }
    }

    public func authorityStore_selectionTemplate(projectID: UUID) async throws -> ProjectSelectionTemplateSnapshot? {
        guard let text = try await connection.query("SELECT selection_json FROM project_selection_templates WHERE project_id=?", [.text(projectID.uuidString)]).first?.column("selection_json")?.string else { return nil }
        return try decoder.decode(ProjectSelectionTemplateSnapshot.self, from: Data(text.utf8))
    }

    public func authorityStore_persistSelectionTemplate(_ snapshot: ProjectSelectionTemplateSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> EventEnvelope {
        try await transaction {
            if let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO project_selection_templates(template_id,project_id,schema_version,selection_json,revision,transactional_commit_id) VALUES(?,?,1,?,?,?) ON CONFLICT(template_id) DO UPDATE SET selection_json=excluded.selection_json,revision=excluded.revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(snapshot.projectID.uuidString), .text(snapshot.projectID.uuidString), .text(encodeText(snapshot)), .integer(Int(snapshot.revision)), .text(UUID().uuidString)]
            )
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot))
            return event
        }
    }

    public func authorityStore_persistPermissions(_ snapshot: ExecutionPermissionSnapshot, projectID: UUID, rootSessionID: UUID, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            try await upsertPermissions(snapshot)
            let event = try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, rootSessionID: rootSessionID, runID: nil, sessionSequence: nil, type: .permissionUpdated, generation: nil, turnEpoch: nil, actor: snapshot.updatedActor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func authorityStore_permissions(sessionID: UUID) async throws -> ExecutionPermissionSnapshot? {
        guard let row = try await connection.query("SELECT mode,provider_settings_json,revision,updated_actor_json FROM execution_permissions WHERE session_id=?", [.text(sessionID.uuidString)]).first,
              let mode = row.column("mode")?.string,
              let settings = row.column("provider_settings_json")?.string,
              let actor = row.column("updated_actor_json")?.string
        else { return nil }
        return try ExecutionPermissionSnapshot(sessionID: sessionID, mode: mode, providerSettings: decoder.decode([String: String].self, from: Data(settings.utf8)), revision: Int64(row.column("revision")?.integer ?? 1), updatedActor: decoder.decode(ExternalActor.self, from: Data(actor.utf8)))
    }

    public func authorityStore_collaboration(sessionID: UUID) async throws -> CollaborationMetadataSnapshot? {
        guard let row = try await connection.query("SELECT visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json FROM collaboration_metadata WHERE session_id=?", [.text(sessionID.uuidString)]).first,
              let visibility = Visibility(rawValue: row.column("visibility")?.string ?? ""),
              let controllerUserID = row.column("controller_user_id")?.string
        else { return nil }
        let acknowledgement = try row.column("collaboration_acknowledgement_json")?.string.map {
            try decoder.decode(CollaborationAcknowledgement.self, from: Data($0.utf8))
        }
        return CollaborationMetadataSnapshot(sessionID: sessionID, visibility: visibility, collaborativeSteeringEnabled: row.column("collaborative_steering_enabled")?.integer == 1, controllerUserID: controllerUserID, policyRevision: Int64(row.column("policy_revision")?.integer ?? 1), controllerRevision: Int64(row.column("controller_revision")?.integer ?? 1), membershipRevision: Int64(row.column("membership_revision")?.integer ?? 1), collaborationAcknowledgement: acknowledgement)
    }

    public func authorityStore_installInitialPolicies(permissions: ExecutionPermissionSnapshot, collaboration: CollaborationMetadataSnapshot) async throws {
        try await transaction {
            if try await self.permissions(sessionID: permissions.sessionID) == nil { try await upsertPermissions(permissions) }
            if try await self.collaboration(sessionID: collaboration.sessionID) == nil { try await upsertCollaboration(collaboration) }
        }
    }

    public func authorityStore_persistCollaboration(_ metadata: CollaborationMetadataSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput, idempotencyResponse: Data? = nil) async throws -> [EventEnvelope] {
        try await transaction {
            if let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            try await upsertCollaboration(metadata)
            let payload = try encoder.encode(metadata)
            let visibility = try await persistSessionInTransaction(session, eventType: .visibilityUpdated, actor: actor, correlationID: correlationID, idempotency: nil, idempotencyResponse: nil, initialSelection: nil, eventPayload: payload)
            let controller = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: .controllerUpdated, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: payload)
            try await saveIdempotency(idempotency, status: 202, response: idempotencyResponse ?? payload)
            return [visibility, controller]
        }
    }

    public func authorityStore_persistInteraction(_ snapshot: InteractionSnapshot, session: SessionSnapshot, actor: ExternalActor?, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            let actorJSON = try actor.map(encodeText)
            _ = try await connection.query(
                "INSERT INTO interactions(interaction_id,session_id,run_id,agent_id,schema_version,kind,state,payload_json,created_at,expires_at,settled_at,settled_actor_json,revision) VALUES(?,?,?,?,1,?,?,?,CURRENT_TIMESTAMP,?,?,?,?) ON CONFLICT(interaction_id) DO UPDATE SET state=excluded.state,payload_json=excluded.payload_json,settled_at=excluded.settled_at,settled_actor_json=excluded.settled_actor_json,revision=excluded.revision",
                [.text(snapshot.interactionID.uuidString), .text(session.sessionID.uuidString), snapshot.runID.map { .text($0.uuidString) } ?? .null, snapshot.agentID.map { .text($0.uuidString) } ?? .null, .text(snapshot.kind.rawValue), .text(snapshot.state.rawValue), .text(snapshot.payload.base64EncodedString()), snapshot.expiresAt.map { .float($0.timeIntervalSince1970) } ?? .null, snapshot.state == .resolved ? .float(Date().timeIntervalSince1970) : .null, actorJSON.map(SQLiteData.text) ?? .null, .integer(Int(snapshot.revision))]
            )
            let eventType: EventType = snapshot.state == .resolved ? .interactionResolved : .interactionRequested
            let event = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: eventType, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func authorityStore_persistInteractionDeliveryState(_ snapshot: InteractionSnapshot, sessionID: UUID, actor: ExternalActor?) async throws {
        try await transaction {
            let actorJSON = try actor.map(encodeText)
            _ = try await connection.query(
                "UPDATE interactions SET state=?,payload_json=?,settled_at=?,settled_actor_json=?,revision=? WHERE interaction_id=? AND session_id=?",
                [.text(snapshot.state.rawValue), .text(snapshot.payload.base64EncodedString()), snapshot.state == .resolved ? .float(Date().timeIntervalSince1970) : .null, actorJSON.map(SQLiteData.text) ?? .null, .integer(Int(snapshot.revision)), .text(snapshot.interactionID.uuidString), .text(sessionID.uuidString)]
            )
        }
    }

    public func authorityStore_interactions(sessionID: UUID) async throws -> [InteractionSnapshot] {
        try await connection.query("SELECT interaction_id,run_id,agent_id,kind,state,payload_json,revision,expires_at FROM interactions WHERE session_id=? ORDER BY created_at", [.text(sessionID.uuidString)]).map { row in
            guard let id = UUID(uuidString: row.column("interaction_id")?.string ?? ""),
                  let kind = InteractionSnapshot.Kind(rawValue: row.column("kind")?.string ?? ""),
                  let state = InteractionSnapshot.State(rawValue: row.column("state")?.string ?? "")
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted interaction is invalid") }
            let expiresAt = row.column("expires_at")?.double.map { Date(timeIntervalSince1970: $0) }
            return InteractionSnapshot(interactionID: id, runID: row.column("run_id")?.string.flatMap(UUID.init(uuidString:)), agentID: row.column("agent_id")?.string.flatMap(UUID.init(uuidString:)), kind: kind, state: state, payload: Data(base64Encoded: row.column("payload_json")?.string ?? "") ?? Data(), revision: Int64(row.column("revision")?.integer ?? 1), expiresAt: expiresAt)
        }
    }

    public func authorityStore_oracleChat(chatID: UUID) async throws -> OracleChatState? {
        guard let text = try await connection.query("SELECT chat_json FROM oracle_chats WHERE chat_id=?", [.text(chatID.uuidString)]).first?.column("chat_json")?.string else { return nil }
        return try decoder.decode(OracleChatState.self, from: Data(text.utf8))
    }

    public func authorityStore_persistOracleChat(_ chat: OracleChatState) async throws {
        try await transaction {
            _ = try await connection.query(
                "INSERT INTO oracle_chats(chat_id,session_id,schema_version,chat_json,revision,created_at,updated_at) VALUES(?,?,1,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(chat_id) DO UPDATE SET chat_json=excluded.chat_json,revision=excluded.revision,updated_at=CURRENT_TIMESTAMP",
                [.text(chat.chatID.uuidString), .text(chat.sessionID.uuidString), .text(encodeText(chat)), .integer(Int(chat.revision))]
            )
        }
    }

    public func authorityStore_persistWorktree(_ snapshot: WorktreeBindingSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            try await ensureUniqueActiveWorktree(snapshot)
            _ = try await connection.query(
                "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?) ON CONFLICT(binding_id) DO UPDATE SET session_id=excluded.session_id,ownership_state=excluded.ownership_state,merge_state=excluded.merge_state,revision=excluded.revision",
                [.text(snapshot.bindingID.uuidString), .text(snapshot.projectID.uuidString), .text(snapshot.rootID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.baseRef), .text(snapshot.branch), .text(snapshot.physicalPath), .text(snapshot.ownershipState.rawValue), .text(snapshot.mergeState.rawValue), .integer(Int(snapshot.revision))]
            )
            try await activatePreparedOwnedResourceIfPresent(externalID: snapshot.bindingID, kind: .worktree, path: snapshot.physicalPath)
            if snapshot.mergeState == .merged {
                try await commitPreparedMergeLeaseIfPresent(bindingID: snapshot.bindingID, expectedRevision: snapshot.revision - 1)
            }
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.sessionID, runID: nil, sessionSequence: nil, type: snapshot.revision == 1 ? .worktreeCreated : .worktreeUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: snapshot.revision == 1 ? 201 : 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func authorityStore_persistWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope] {
        try await transaction {
            var events: [EventEnvelope] = []
            for snapshot in snapshots {
                try await ensureUniqueActiveWorktree(snapshot)
                _ = try await connection.query(
                    "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?)",
                    [.text(snapshot.bindingID.uuidString), .text(snapshot.projectID.uuidString), .text(snapshot.rootID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.baseRef), .text(snapshot.branch), .text(snapshot.physicalPath), .text(snapshot.ownershipState.rawValue), .text(snapshot.mergeState.rawValue), .integer(Int(snapshot.revision))]
                )
                try await activatePreparedOwnedResourceIfPresent(externalID: snapshot.bindingID, kind: .worktree, path: snapshot.physicalPath)
                try await events.append(appendEvent(
                    projectID: snapshot.projectID,
                    sessionID: snapshot.sessionID,
                    rootSessionID: snapshot.sessionID,
                    runID: nil,
                    sessionSequence: nil,
                    type: .worktreeCreated,
                    generation: nil,
                    turnEpoch: nil,
                    actor: actor,
                    correlationID: correlationID,
                    payload: encoder.encode(snapshot)
                ))
            }
            return events
        }
    }

    /// Atomically replaces an embedded host's authority-owned worktree set.
    /// The caller supplies already validated active/released snapshots; either
    /// every ownership transition and event commits or none does.
    public func authorityStore_replaceEmbeddedWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope] {
        try await transaction {
            var events: [EventEnvelope] = []
            let activeKeys = snapshots.compactMap { snapshot -> String? in
                guard snapshot.ownershipState == .active, let sessionID = snapshot.sessionID else { return nil }
                return "\(sessionID.uuidString):\(snapshot.rootID.uuidString)"
            }
            guard Set(activeKeys).count == activeKeys.count else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Embedded worktree roots must be unique per session")
            }
            let ordered = snapshots.sorted { left, right in
                left.ownershipState == .released && right.ownershipState != .released
            }
            for snapshot in ordered {
                try await ensureUniqueActiveWorktree(snapshot)
                _ = try await connection.query(
                    "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?) ON CONFLICT(binding_id) DO UPDATE SET session_id=excluded.session_id,base_ref=excluded.base_ref,branch=excluded.branch,physical_path=excluded.physical_path,ownership_state=excluded.ownership_state,merge_state=excluded.merge_state,revision=excluded.revision",
                    [.text(snapshot.bindingID.uuidString), .text(snapshot.projectID.uuidString), .text(snapshot.rootID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.baseRef), .text(snapshot.branch), .text(snapshot.physicalPath), .text(snapshot.ownershipState.rawValue), .text(snapshot.mergeState.rawValue), .integer(Int(snapshot.revision))]
                )
                try await events.append(appendEvent(
                    projectID: session.projectID,
                    sessionID: session.sessionID,
                    rootSessionID: session.rootSessionID,
                    runID: nil,
                    sessionSequence: nil,
                    type: snapshot.revision == 1 ? .worktreeCreated : .worktreeUpdated,
                    generation: session.runGeneration,
                    turnEpoch: session.turnEpoch,
                    actor: actor,
                    correlationID: correlationID,
                    payload: encoder.encode(snapshot)
                ))
            }
            return events
        }
    }

    public func authorityStore_persistWorktreeBinding(_ worktree: WorktreeBindingSnapshot, selection: SelectionSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> (worktree: EventEnvelope, selection: EventEnvelope) {
        try await transaction {
            if let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            try await ensureUniqueActiveWorktree(worktree)
            _ = try await connection.query(
                "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?) ON CONFLICT(binding_id) DO UPDATE SET session_id=excluded.session_id,ownership_state=excluded.ownership_state,merge_state=excluded.merge_state,revision=excluded.revision",
                [.text(worktree.bindingID.uuidString), .text(worktree.projectID.uuidString), .text(worktree.rootID.uuidString), worktree.sessionID.map { .text($0.uuidString) } ?? .null, .text(worktree.baseRef), .text(worktree.branch), .text(worktree.physicalPath), .text(worktree.ownershipState.rawValue), .text(worktree.mergeState.rawValue), .integer(Int(worktree.revision))]
            )
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET selection_json=excluded.selection_json,selection_revision=excluded.selection_revision,binding_revision=excluded.binding_revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(selection.sessionID.uuidString), .text(encodeText(Array(Set(selection.entries.map(\.rootID))))), .text(encodeText(selection)), .integer(Int(selection.revision)), .integer(Int(selection.bindingRevision)), .text(UUID().uuidString)]
            )
            let worktreeEvent = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: .worktreeUpdated, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(worktree))
            let selectionEvent = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(selection))
            try await saveIdempotency(idempotency, status: 200, response: encoder.encode(worktree))
            return (worktreeEvent, selectionEvent)
        }
    }

    public func authorityStore_worktrees(projectID: UUID) async throws -> [WorktreeBindingSnapshot] {
        try await connection.query("SELECT * FROM worktree_bindings WHERE project_id=? ORDER BY binding_id", [.text(projectID.uuidString)]).map(decodeWorktree)
    }

    public func authorityStore_worktree(bindingID: UUID) async throws -> WorktreeBindingSnapshot? {
        try await connection.query("SELECT * FROM worktree_bindings WHERE binding_id=?", [.text(bindingID.uuidString)]).first.map(decodeWorktree)
    }

    public func authorityStore_persistArtifact(_ snapshot: ArtifactSnapshot, storageReference: String, actor: ExternalActor?, correlationID: UUID) async throws -> EventEnvelope {
        try await transaction {
            _ = try await connection.query(
                "INSERT INTO artifacts(artifact_id,project_id,session_id,schema_version,kind,logical_name,content_digest,storage_reference,size,created_sequence,created_at,retention_state) VALUES(?,?,?,1,?,?,?,?,?,?,CURRENT_TIMESTAMP,?)",
                [.text(snapshot.artifactID.uuidString), .text(snapshot.projectID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.kind), .text(snapshot.logicalName), .text(snapshot.contentDigest), .text(storageReference), .integer(Int(snapshot.size)), .integer(Int(snapshot.createdCursor.globalSequence)), .text(snapshot.retentionState)]
            )
            try await activatePreparedOwnedResourceIfPresent(externalID: snapshot.artifactID, kind: .artifact, path: storageReference, size: snapshot.size, digest: snapshot.contentDigest)
            return try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.sessionID, runID: nil, sessionSequence: nil, type: .artifactCreated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
        }
    }

    public func authorityStore_artifacts(sessionID: UUID) async throws -> [(snapshot: ArtifactSnapshot, storageReference: String)] {
        let meta = try await metadata()
        return try await connection.query("SELECT * FROM artifacts WHERE session_id=? AND retention_state!='deleted' ORDER BY created_sequence", [.text(sessionID.uuidString)]).map { try decodeArtifact($0, storeID: meta.storeID) }
    }

    public func authorityStore_artifact(id: UUID) async throws -> (snapshot: ArtifactSnapshot, storageReference: String)? {
        let meta = try await metadata()
        return try await connection.query("SELECT * FROM artifacts WHERE artifact_id=? AND retention_state!='deleted'", [.text(id.uuidString)]).first.map { try decodeArtifact($0, storeID: meta.storeID) }
    }

    public func authorityStore_installWorkflows(_ workflows: [WorkflowSnapshot]) async throws {
        try await transaction {
            for workflow in workflows {
                _ = try await connection.query("INSERT INTO workflows(workflow_id,schema_version,source,name,definition_json,content_digest,enabled) VALUES(?,1,?,?,?,?,?) ON CONFLICT(workflow_id) DO UPDATE SET source=excluded.source,name=excluded.name,definition_json=excluded.definition_json,content_digest=excluded.content_digest,enabled=excluded.enabled", [.text(workflow.workflowID), .text(workflow.source), .text(workflow.name), .text(workflow.definition), .text(workflow.contentDigest), .integer(workflow.enabled ? 1 : 0)])
            }
            return ()
        }
    }

    public func workflows() async throws -> [WorkflowSnapshot] {
        try await connection.query("SELECT * FROM workflows WHERE enabled=1 ORDER BY name").map { row in
            WorkflowSnapshot(workflowID: row.column("workflow_id")?.string ?? "", source: row.column("source")?.string ?? "", name: row.column("name")?.string ?? "", definition: row.column("definition_json")?.string ?? "", contentDigest: row.column("content_digest")?.string ?? "", enabled: row.column("enabled")?.bool ?? false)
        }
    }

    public func persistProcessFamily(runID: UUID, leader: PersistedProcessIdentity, connectionGeneration: Int64 = 1, containmentMode: String = "process-group", state: String = "running") async throws {
        try await transaction {
            let executableDigest = PersistenceCryptography.bodyDigest(Data(leader.executablePath.utf8))
            _ = try await connection.query(
                "INSERT INTO process_families(run_id,schema_version,leader_pid,pgid,process_start_time,boot_id,executable_digest,executable_path,helper_token_digest,connection_generation,containment_mode,state) VALUES(?,1,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET leader_pid=excluded.leader_pid,pgid=excluded.pgid,process_start_time=excluded.process_start_time,boot_id=excluded.boot_id,executable_digest=excluded.executable_digest,executable_path=excluded.executable_path,helper_token_digest=excluded.helper_token_digest,connection_generation=excluded.connection_generation,containment_mode=excluded.containment_mode,state=excluded.state",
                [.text(runID.uuidString), .integer(Int(leader.pid)), .integer(Int(leader.processGroupID)), .integer(Int(leader.startTimeTicks)), .text(leader.bootID), .text(executableDigest), .text(leader.executablePath), .text(leader.helperTokenDigest), .integer(Int(connectionGeneration)), .text(containmentMode), .text(state)]
            )
            try await persistProcessMembersWithoutTransaction(runID: runID, members: [leader], terminalState: nil)
        }
    }

    public func persistProcessMembers(runID: UUID, members: [PersistedProcessIdentity], terminalState: String? = nil) async throws {
        try await transaction {
            try await persistProcessMembersWithoutTransaction(runID: runID, members: members, terminalState: terminalState)
        }
    }

    public func activeProcessFamilies() async throws -> [PersistedProcessFamily] {
        try await connection.query("SELECT f.*,m.parent_pid AS leader_parent_pid,m.session_id AS leader_session_id FROM process_families f LEFT JOIN process_members m ON m.run_id=f.run_id AND m.pid=f.leader_pid AND m.start_time=f.process_start_time WHERE f.state IN ('running','terminating') ORDER BY f.run_id").map { row in
            guard let runID = UUID(uuidString: row.column("run_id")?.string ?? "") else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted process family run ID is invalid")
            }
            let leader = PersistedProcessIdentity(
                pid: Int32(row.column("leader_pid")?.integer ?? 0),
                parentPID: Int32(row.column("leader_parent_pid")?.integer ?? 0),
                processGroupID: Int32(row.column("pgid")?.integer ?? 0),
                sessionID: Int32(row.column("leader_session_id")?.integer ?? 0),
                startTimeTicks: UInt64(row.column("process_start_time")?.integer ?? 0),
                bootID: row.column("boot_id")?.string ?? "",
                executablePath: row.column("executable_path")?.string ?? "",
                helperTokenDigest: row.column("helper_token_digest")?.string ?? ""
            )
            return PersistedProcessFamily(runID: runID, leader: leader, connectionGeneration: Int64(row.column("connection_generation")?.integer ?? 1), containmentMode: row.column("containment_mode")?.string ?? "process-group", state: row.column("state")?.string ?? "running")
        }
    }

    public func updateProcessFamilyState(runID: UUID, state: String, members: [PersistedProcessIdentity] = []) async throws {
        try await transaction {
            _ = try await connection.query("UPDATE process_families SET state=? WHERE run_id=?", [.text(state), .text(runID.uuidString)])
            if !members.isEmpty {
                try await persistProcessMembersWithoutTransaction(runID: runID, members: members, terminalState: state)
            }
        }
    }

    public func processFamilyState(runID: UUID) async throws -> String? {
        try await connection.query("SELECT state FROM process_families WHERE run_id=?", [.text(runID.uuidString)]).first?.column("state")?.string
    }

    public func consumeNonce(direction: String, keyID: String, nonce: String, observedAt: Date, expiresAt: Date) async throws {
        do {
            _ = try await connection.query("INSERT INTO request_nonces(direction,key_id,nonce,observed_at,expires_at) VALUES(?,?,?,?,?)", [.text(direction), .text(keyID), .text(nonce), .float(observedAt.timeIntervalSince1970), .float(expiresAt.timeIntervalSince1970)])
        } catch { throw ServiceAPIError(code: .internalAuthFailed, message: "Nonce has already been used") }
    }

    public func consumeAuthorizationDecision(_ decision: AuthorizationDecision) async throws {
        try await transaction {
            let scope = decision.sessionID.map { "session:\($0.uuidString)" }
                ?? decision.projectID.map { "project:\($0.uuidString)" }
                ?? "global"
            if try await connection.query("SELECT 1 FROM consumed_authorization_decisions WHERE decision_id=?", [.text(decision.decisionID.uuidString)]).first != nil {
                throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision was already consumed")
            }
            if let sessionID = decision.sessionID, let collaboration = try await collaboration(sessionID: sessionID) {
                if decision.operation == "setSessionVisibility" {
                    guard (collaboration.policyRevision ... collaboration.policyRevision + 1).contains(decision.policyRevision),
                          (collaboration.controllerRevision ... collaboration.controllerRevision + 1).contains(decision.controllerRevision),
                          (collaboration.membershipRevision ... collaboration.membershipRevision + 1).contains(decision.membershipRevision)
                    else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Collaboration acknowledgement revisions are not current or exactly next") }
                } else {
                    guard decision.policyRevision == collaboration.policyRevision,
                          decision.controllerRevision == collaboration.controllerRevision,
                          decision.membershipRevision == collaboration.membershipRevision
                    else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision revisions do not match durable session policy") }
                }
            }
            if let row = try await connection.query("SELECT policy_revision,controller_revision,membership_revision FROM authorization_revision_fences WHERE scope_key=?", [.text(scope)]).first {
                guard decision.policyRevision >= Int64(row.column("policy_revision")?.integer ?? 0),
                      decision.controllerRevision >= Int64(row.column("controller_revision")?.integer ?? 0),
                      decision.membershipRevision >= Int64(row.column("membership_revision")?.integer ?? 0)
                else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision revision regressed") }
            }
            _ = try await connection.query("INSERT INTO consumed_authorization_decisions(decision_id,scope_key,actor_id,policy_revision,controller_revision,membership_revision,consumed_at) VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)", [.text(decision.decisionID.uuidString), .text(scope), .text(decision.actor.userID), .integer(Int(decision.policyRevision)), .integer(Int(decision.controllerRevision)), .integer(Int(decision.membershipRevision))])
            _ = try await connection.query("INSERT INTO authorization_revision_fences(scope_key,policy_revision,controller_revision,membership_revision,updated_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(scope_key) DO UPDATE SET policy_revision=MAX(policy_revision,excluded.policy_revision),controller_revision=MAX(controller_revision,excluded.controller_revision),membership_revision=MAX(membership_revision,excluded.membership_revision),updated_at=CURRENT_TIMESTAMP", [.text(scope), .integer(Int(decision.policyRevision)), .integer(Int(decision.controllerRevision)), .integer(Int(decision.membershipRevision))])
        }
    }

    public func authorityStore_checkpoint() async throws {
        _ = try await connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func enforceEventRetention(policy: EventRetentionPolicy = .init(), now: Date = Date()) async throws -> UUID? {
        let meta = try await metadata()
        let latest = meta.nextGlobalSequence - 1
        let ageBoundary = now.addingTimeInterval(-policy.minimumLiveAge).timeIntervalSince1970
        let rows = try await connection.query(
            "SELECT global_sequence,timestamp FROM events WHERE global_sequence>? ORDER BY global_sequence",
            [.integer(Int(meta.replayFloor))]
        )
        var ageEligibleThrough = meta.replayFloor
        for row in rows {
            guard (row.column("timestamp")?.double ?? .greatestFiniteMagnitude) < ageBoundary else { break }
            ageEligibleThrough = Int64(row.column("global_sequence")?.integer ?? Int(ageEligibleThrough))
        }
        guard let through = policy.eligibleThrough(latestSequence: latest, ageEligibleThrough: ageEligibleThrough, replayFloor: meta.replayFloor) else { return nil }
        return try await archiveEvents(through: through)
    }

    func archiveEvents(through sequence: Int64) async throws -> UUID? {
        try await transaction {
            let meta = try await metadata()
            let bounded = min(sequence, meta.nextGlobalSequence - 1)
            guard bounded > meta.replayFloor else { return nil }
            let rows = try await connection.query(
                "SELECT envelope_json FROM events WHERE global_sequence>? AND global_sequence<=? ORDER BY global_sequence",
                [.integer(Int(meta.replayFloor)), .integer(Int(bounded))]
            )
            let events = try rows.compactMap { row -> EventEnvelope? in
                guard let text = row.column("envelope_json")?.string else { return nil }
                return try decoder.decode(EventEnvelope.self, from: Data(text.utf8))
            }
            guard let first = events.first, let last = events.last,
                  first.globalSequence == meta.replayFloor + 1,
                  last.globalSequence == bounded,
                  events.enumerated().allSatisfy({ $0.element.globalSequence == first.globalSequence + Int64($0.offset) })
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Event archive prefix is not contiguous") }
            let archiveID = UUID()
            let bytes = try encoder.encode(events)
            let compressed = EventArchiveCompression.compress(bytes)
            let digest = PersistenceCryptography.bodyDigest(bytes)
            let compressedDigest = PersistenceCryptography.bodyDigest(compressed)
            try await saveCheckpoint(
                scope: "events:\(meta.storeID.uuidString):pre-compaction",
                sequence: last.globalSequence,
                snapshot: bytes,
                retentionClass: "pre_compaction",
                archiveID: archiveID
            )
            _ = try await connection.query(
                "INSERT INTO event_archive_blobs(archive_id,store_id,first_sequence,last_sequence,event_count,compression,compressed_events_base64,uncompressed_digest,compressed_digest,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [
                    .text(archiveID.uuidString), .text(meta.storeID.uuidString), .integer(Int(first.globalSequence)),
                    .integer(Int(last.globalSequence)), .integer(events.count), .text(EventArchiveCompression.algorithm),
                    .text(compressed.base64EncodedString()), .text(digest), .text(compressedDigest),
                    .float(Date().timeIntervalSince1970)
                ]
            )
            _ = try await connection.query(
                "DELETE FROM events WHERE global_sequence>=? AND global_sequence<=?",
                [.integer(Int(first.globalSequence)), .integer(Int(last.globalSequence))]
            )
            _ = try await connection.query("UPDATE service_metadata SET replay_floor=? WHERE fixed_id=1", [.integer(Int(last.globalSequence))])
            return archiveID
        }
    }

    public func archivedEvents(archiveID: UUID) async throws -> [EventEnvelope] {
        if let row = try await connection.query("SELECT * FROM event_archive_blobs WHERE archive_id=?", [.text(archiveID.uuidString)]).first {
            guard row.column("compression")?.string == EventArchiveCompression.algorithm,
                  let encoded = row.column("compressed_events_base64")?.string,
                  let compressed = Data(base64Encoded: encoded),
                  PersistenceCryptography.bodyDigest(compressed) == row.column("compressed_digest")?.string
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Compressed event archive digest is invalid", retryable: false) }
            let bytes = try EventArchiveCompression.decompress(compressed)
            guard PersistenceCryptography.bodyDigest(bytes) == row.column("uncompressed_digest")?.string else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Event archive payload digest is invalid", retryable: false)
            }
            let events = try decoder.decode([EventEnvelope].self, from: bytes)
            guard events.count == row.column("event_count")?.integer,
                  events.first?.globalSequence == Int64(row.column("first_sequence")?.integer ?? -1),
                  events.last?.globalSequence == Int64(row.column("last_sequence")?.integer ?? -1)
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Event archive sequence metadata is invalid", retryable: false) }
            return events
        }
        guard let text = try await connection.query("SELECT canonical_events_json FROM event_archives WHERE archive_id=?", [.text(archiveID.uuidString)]).first?.column("canonical_events_json")?.string else { throw ServiceAPIError(code: .notFound, message: "Event archive not found") }
        return try decoder.decode([EventEnvelope].self, from: Data(text.utf8))
    }

    public func snapshotCheckpoints(scope: String) async throws -> [(sequence: Int64, digest: String)] {
        try await connection.query("SELECT sequence,digest FROM snapshot_checkpoints WHERE scope=? ORDER BY sequence", [.text(scope)]).map { (Int64($0.column("sequence")?.integer ?? 0), $0.column("digest")?.string ?? "") }
    }

    public func prepareRestoredStore(
        from priorStoreID: UUID,
        backupSequence: Int64,
        digest: String,
        activationToken: Data
    ) async throws -> UUID {
        guard !activationToken.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Restore activation token is required")
        }
        let current = try await metadata()
        guard current.storeID == priorStoreID, current.activationState == "active" else {
            throw ServiceAPIError(code: .invalidRequest, message: "Restore provenance does not match the active store namespace")
        }
        let fresh = UUID()
        let restoredFloor = max(backupSequence, current.nextGlobalSequence - 1)
        let restoredCursor = ServiceCursor(storeID: fresh, globalSequence: restoredFloor)
        let projects = try await allProjects().map { replacingCursor($0, cursor: restoredCursor) }
        let sessions = try await allSessions().map { replacingCursor($0, cursor: restoredCursor) }
        let tokenDigest = PersistenceCryptography.bodyDigest(activationToken)
        try await transaction {
            _ = try await connection.query(
                "UPDATE service_metadata SET restored_from_store_id=store_id,store_id=?,restore_backup_sequence=?,restore_digest=?,replay_floor=?,next_global_sequence=?,last_clean_shutdown=0,activation_state='restore_prepared',activation_generation=activation_generation+1,activation_token_digest=?,activation_instance_id=NULL WHERE fixed_id=1",
                [.text(fresh.uuidString), .integer(Int(backupSequence)), .text(digest), .integer(Int(restoredFloor)), .integer(Int(restoredFloor + 1)), .text(tokenDigest)]
            )
            // Preserve prior records for expiry/audit while making their cached
            // responses unreachable in the fresh store namespace.
            _ = try await connection.query(
                "UPDATE idempotency_records SET idempotency_key=? || idempotency_key",
                [.text("restored:\(fresh.uuidString):")]
            )
            for project in projects {
                _ = try await connection.query("UPDATE projects SET snapshot_json=?,updated_at=CURRENT_TIMESTAMP WHERE project_id=?", [.text(encodeText(project)), .text(project.projectID.uuidString)])
            }
            for session in sessions {
                _ = try await connection.query("UPDATE sessions SET snapshot_json=?,updated_at=CURRENT_TIMESTAMP WHERE session_id=?", [.text(encodeText(session)), .text(session.sessionID.uuidString)])
            }
            let provenance = try encodeText(["priorStoreId": priorStoreID.uuidString, "freshStoreId": fresh.uuidString, "digest": digest])
            try await saveCheckpoint(scope: "store:\(fresh.uuidString):restore", sequence: restoredFloor, snapshot: Data(provenance.utf8), retentionClass: "restore")
            _ = try await connection.query("INSERT INTO audit_events(event_id,schema_version,event_type,payload_json,created_at) VALUES(?,2,'store.restore_prepared',?,CURRENT_TIMESTAMP)", [.text(UUID().uuidString), .text(provenance)])
            return ()
        }
        return fresh
    }

    public func activateRestoredStore(activationToken: Data, instanceID: UUID) async throws -> UUID {
        try await transaction {
            let row = try await requireRow(connection.query("SELECT store_id,activation_state,activation_token_digest FROM service_metadata WHERE fixed_id=1"))
            guard row.column("activation_state")?.string == "restore_prepared",
                  row.column("activation_token_digest")?.string == PersistenceCryptography.bodyDigest(activationToken)
            else {
                throw ServiceAPIError(code: .quiescing, message: "Restored store activation is fenced")
            }
            let storeID = try requireUUID(row.column("store_id")?.string)
            _ = try await connection.query(
                "UPDATE service_metadata SET activation_state='active',activation_token_digest=NULL,activation_instance_id=?,last_clean_shutdown=0 WHERE fixed_id=1 AND activation_state='restore_prepared'",
                [.text(instanceID.uuidString)]
            )
            let payload = try encodeText(["storeId": storeID.uuidString, "instanceId": instanceID.uuidString])
            _ = try await connection.query("INSERT INTO audit_events(event_id,schema_version,event_type,payload_json,created_at) VALUES(?,2,'store.restore_activated',?,CURRENT_TIMESTAMP)", [.text(UUID().uuidString), .text(payload)])
            return storeID
        }
    }

    @available(*, deprecated, message: "Use prepareRestoredStore and activateRestoredStore for operator-acknowledged activation")
    public func markRestored(from priorStoreID: UUID, backupSequence: Int64, digest: String) async throws -> UUID {
        let token = Data(UUID().uuidString.utf8)
        let fresh = try await prepareRestoredStore(from: priorStoreID, backupSequence: backupSequence, digest: digest, activationToken: token)
        _ = try await activateRestoredStore(activationToken: token, instanceID: UUID())
        return fresh
    }

    private func canonicalEventForPublication(_ event: EventEnvelope) throws -> EventEnvelope {
        let keyID = eventSigningKey?.keyID ?? "unsigned-local"
        let unsigned = event.replacingIntegrity(keyID: keyID, digest: "", signature: "")
        let digest = try PersistenceCryptography.bodyDigest(unsigned.persistenceSigningData())
        let signature = eventSigningKey.map { PersistenceCryptography.hmacSHA256(message: digest, key: $0.secret) } ?? ""
        return unsigned.replacingIntegrity(keyID: keyID, digest: digest, signature: signature)
    }

    private func appendEvent(projectID: UUID, sessionID: UUID?, agentID: UUID? = nil, parentAgentID: UUID? = nil, rootSessionID: UUID?, runID: UUID?, sessionSequence: Int64?, type: EventType, generation: Int64?, turnEpoch: Int64?, actor: ExternalActor?, correlationID: UUID, payload: Data) async throws -> EventEnvelope {
        let meta = try await metadata()
        let sequence = meta.nextGlobalSequence
        let keyID = eventSigningKey?.keyID ?? "unsigned-local"
        let lastTimestamp = try await connection.query("SELECT last_event_timestamp FROM service_metadata WHERE fixed_id=1").first?.column("last_event_timestamp")?.double ?? 0
        let eventTimestamp = Date(timeIntervalSince1970: max(Date().timeIntervalSince1970, lastTimestamp))
        let objectPayload = try EventPayload(jsonData: payload)
        let eventID = UUID()
        let unsigned = EventEnvelope(protocolVersion: 1, eventID: eventID, storeID: meta.storeID, globalSequence: sequence, timestamp: eventTimestamp, projectID: projectID, sessionID: sessionID, agentID: agentID, parentAgentID: parentAgentID, rootSessionID: rootSessionID, runID: runID, sessionSequence: sessionSequence, eventType: type, payloadVersion: 1, generation: generation, turnEpoch: turnEpoch, actor: actor, correlationID: correlationID, causationID: nil, payload: objectPayload, digest: "", keyID: keyID, signature: "")
        let digest = try PersistenceCryptography.bodyDigest(unsigned.persistenceSigningData())
        let signature = eventSigningKey.map { PersistenceCryptography.hmacSHA256(message: digest, key: $0.secret) } ?? ""
        let envelope = EventEnvelope(protocolVersion: 1, eventID: eventID, storeID: meta.storeID, globalSequence: sequence, timestamp: eventTimestamp, projectID: projectID, sessionID: sessionID, agentID: agentID, parentAgentID: parentAgentID, rootSessionID: rootSessionID, runID: runID, sessionSequence: sessionSequence, eventType: type, payloadVersion: 1, generation: generation, turnEpoch: turnEpoch, actor: actor, correlationID: correlationID, causationID: nil, payload: objectPayload, digest: digest, keyID: keyID, signature: signature)
        let actorJSON = try actor.map(encodeText)
        let bindings: [SQLiteData] = try [
            .integer(Int(sequence)), .text(envelope.eventID.uuidString), .text(projectID.uuidString), sessionID.map { .text($0.uuidString) } ?? .null,
            agentID.map { .text($0.uuidString) } ?? .null, parentAgentID.map { .text($0.uuidString) } ?? .null, rootSessionID.map { .text($0.uuidString) } ?? .null, runID.map { .text($0.uuidString) } ?? .null,
            sessionSequence.map { .integer(Int($0)) } ?? .null, .text(type.rawValue), .integer(1), generation.map { .integer(Int($0)) } ?? .null,
            turnEpoch.map { .integer(Int($0)) } ?? .null, actorJSON.map(SQLiteData.text) ?? .null, .text(encodeText(objectPayload)),
            .text(digest), .float(envelope.timestamp.timeIntervalSince1970), .text(encodeText(envelope))
        ]
        _ = try await connection.query("INSERT INTO events(global_sequence,event_id,project_id,session_id,agent_id,parent_agent_id,root_session_id,run_id,session_sequence,event_type,payload_version,generation,turn_epoch,actor_json,payload_json,digest,timestamp,envelope_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", bindings)
        try await faultInjector.hit(.afterEventInsertBeforeSequenceAdvance)
        _ = try await connection.query(
            "UPDATE service_metadata SET next_global_sequence=next_global_sequence+1,last_clean_shutdown=0,last_event_timestamp=? WHERE fixed_id=1",
            [.float(eventTimestamp.timeIntervalSince1970)]
        )
        if let sessionID {
            _ = try await connection.query(
                "INSERT INTO session_event_counters(session_id,event_count,last_sequence) VALUES(?,1,?) ON CONFLICT(session_id) DO UPDATE SET event_count=event_count+1,last_sequence=excluded.last_sequence",
                [.text(sessionID.uuidString), .integer(Int(sequence))]
            )
            let count = try await connection.query("SELECT event_count FROM session_event_counters WHERE session_id=?", [.text(sessionID.uuidString)]).first?.column("event_count")?.integer ?? 0
            if count > 0, count.isMultiple(of: 1000),
               let snapshot = try await connection.query("SELECT snapshot_json FROM sessions WHERE session_id=?", [.text(sessionID.uuidString)]).first?.column("snapshot_json")?.string
            {
                try await saveCheckpoint(scope: "session:\(sessionID.uuidString)", sequence: sequence, snapshot: Data(snapshot.utf8), retentionClass: "rolling")
            }
        }
        return envelope
    }

    private func persistProcessMembersWithoutTransaction(runID: UUID, members: [PersistedProcessIdentity], terminalState: String?) async throws {
        for member in members {
            let executableIdentity = PersistenceCryptography.bodyDigest(Data(member.executablePath.utf8))
            _ = try await connection.query(
                "INSERT INTO process_members(run_id,pid,schema_version,parent_pid,pgid,session_id,start_time,executable_identity,first_observed_at,last_observed_at,terminal_state) VALUES(?,?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,?) ON CONFLICT(run_id,pid,start_time) DO UPDATE SET parent_pid=excluded.parent_pid,pgid=excluded.pgid,session_id=excluded.session_id,executable_identity=excluded.executable_identity,last_observed_at=CURRENT_TIMESTAMP,terminal_state=excluded.terminal_state",
                [.text(runID.uuidString), .integer(Int(member.pid)), .integer(Int(member.parentPID)), .integer(Int(member.processGroupID)), .integer(Int(member.sessionID)), .integer(Int(member.startTimeTicks)), .text(executableIdentity), terminalState.map(SQLiteData.text) ?? .null]
            )
        }
    }

    private func importAuditExists(kind: String, digest: String) async throws -> Bool {
        try await connection.query("SELECT 1 FROM audit_events WHERE event_type=? AND payload_json=? LIMIT 1", [.text(kind), .text(digest)]).first != nil
    }

    private func recordImportAudit(kind: String, digest: String) async throws {
        _ = try await connection.query("INSERT INTO audit_events(event_id,schema_version,event_type,payload_json,created_at) VALUES(?,1,?,?,CURRENT_TIMESTAMP)", [.text(UUID().uuidString), .text(kind), .text(digest)])
    }

    func persistSessionInTransaction(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data?,
        initialSelection: SelectionSnapshot?,
        eventPayload: Data? = nil
    ) async throws -> EventEnvelope {
        try await validateExpectedCursor(snapshot.cursor)
        if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
        let snapshotJSON = try encodeText(snapshot)
        let sessionBindings: [SQLiteData] = [
            .text(snapshot.sessionID.uuidString), .text(snapshot.projectID.uuidString), snapshot.parentSessionID.map { .text($0.uuidString) } ?? .null,
            .text(snapshot.rootSessionID.uuidString), .text(snapshot.creator.userID), .text(snapshot.state.rawValue), .text(snapshot.provider.rawValue),
            snapshot.model.map(SQLiteData.text) ?? .null, .text(snapshot.visibility.rawValue), .integer(Int(snapshot.runGeneration)), .integer(Int(snapshot.turnEpoch)),
            .integer(Int(snapshot.revision)), .text(snapshotJSON)
        ]
        _ = try await connection.query("INSERT INTO sessions(session_id,project_id,parent_session_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,model,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET lifecycle_state=excluded.lifecycle_state,run_generation=excluded.run_generation,turn_epoch=excluded.turn_epoch,revision=excluded.revision,snapshot_json=excluded.snapshot_json,updated_at=CURRENT_TIMESTAMP", sessionBindings)
        for entry in snapshot.transcript {
            _ = try await connection.query("INSERT OR IGNORE INTO transcript_entries(session_id,entry_id,schema_version,session_sequence,entry_json,content_digest) VALUES(?,?,1,?,?,?)", [.text(snapshot.sessionID.uuidString), .text(entry.entryID.uuidString), .integer(Int(entry.sessionSequence)), .text(encodeText(entry)), .text(PersistenceCryptography.bodyDigest(encoder.encode(entry)))])
        }
        if let initialSelection {
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO NOTHING",
                [.text(initialSelection.sessionID.uuidString), .text(encodeText(Array(Set(initialSelection.entries.map(\.rootID))))), .text(encodeText(initialSelection)), .integer(Int(initialSelection.revision)), .integer(Int(initialSelection.bindingRevision)), .text(UUID().uuidString)]
            )
        }
        let sessionSequence = [EventType.transcriptMessage, .transcriptProgress].contains(eventType)
            ? snapshot.transcript.last?.sessionSequence
            : nil
        let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: sessionSequence, type: eventType, generation: snapshot.runGeneration, turnEpoch: snapshot.turnEpoch, actor: actor, correlationID: correlationID, payload: eventPayload ?? Data(snapshotJSON.utf8))
        if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) {
            try await saveCheckpoint(scope: "session:\(snapshot.sessionID.uuidString)", sequence: event.globalSequence, snapshot: Data(snapshotJSON.utf8), retentionClass: "terminal")
        }
        if let idempotency {
            let status = eventType == .sessionCreated ? 201 : 202
            try await saveIdempotency(idempotency, status: status, response: idempotencyResponse ?? encoder.encode(snapshot))
        }
        return event
    }

    private func persistAgentInTransaction(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope {
        _ = try await connection.query(
            "INSERT INTO agents(agent_id,session_id,root_session_id,parent_agent_id,schema_version,provider_native_identity,role,label,lifecycle_state,revision,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(agent_id) DO UPDATE SET provider_native_identity=excluded.provider_native_identity,role=excluded.role,label=excluded.label,lifecycle_state=excluded.lifecycle_state,revision=excluded.revision,updated_at=CURRENT_TIMESTAMP",
            [.text(snapshot.agentID.uuidString), .text(snapshot.sessionID.uuidString), .text(snapshot.rootSessionID.uuidString), snapshot.parentAgentID.map { .text($0.uuidString) } ?? .null, snapshot.providerNativeIdentity.map(SQLiteData.text) ?? .null, .text(snapshot.role), snapshot.label.map(SQLiteData.text) ?? .null, .text(snapshot.state.rawValue), .integer(Int(snapshot.revision))]
        )
        return try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, agentID: snapshot.agentID, parentAgentID: snapshot.parentAgentID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: nil, type: eventType, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
    }

    private func upsertPermissions(_ snapshot: ExecutionPermissionSnapshot) async throws {
        _ = try await connection.query(
            "INSERT INTO execution_permissions(session_id,schema_version,mode,provider_settings_json,revision,updated_actor_json,updated_at) VALUES(?,1,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET mode=excluded.mode,provider_settings_json=excluded.provider_settings_json,revision=excluded.revision,updated_actor_json=excluded.updated_actor_json,updated_at=CURRENT_TIMESTAMP",
            [.text(snapshot.sessionID.uuidString), .text(snapshot.mode), .text(encodeText(snapshot.providerSettings)), .integer(Int(snapshot.revision)), .text(encodeText(snapshot.updatedActor))]
        )
    }

    private func upsertCollaboration(_ metadata: CollaborationMetadataSnapshot) async throws {
        let acknowledgement: SQLiteData = try metadata.collaborationAcknowledgement.map { try .text(encodeText($0)) } ?? .null
        _ = try await connection.query(
            "INSERT INTO collaboration_metadata(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,updated_at) VALUES(?,1,?,?,?,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET visibility=excluded.visibility,collaborative_steering_enabled=excluded.collaborative_steering_enabled,controller_user_id=excluded.controller_user_id,policy_revision=excluded.policy_revision,controller_revision=excluded.controller_revision,membership_revision=excluded.membership_revision,collaboration_acknowledgement_json=excluded.collaboration_acknowledgement_json,updated_at=CURRENT_TIMESTAMP",
            [.text(metadata.sessionID.uuidString), .text(metadata.visibility.rawValue), .integer(metadata.collaborativeSteeringEnabled ? 1 : 0), .text(metadata.controllerUserID), .integer(Int(metadata.policyRevision)), .integer(Int(metadata.controllerRevision)), .integer(Int(metadata.membershipRevision)), acknowledgement]
        )
    }

    public struct ProviderConnectionAuditRecord: Codable, Hashable, Sendable {
        public let auditID: UUID
        public let providerID: ProviderSettingsID
        public let connectionID: UUID?
        public let operation: String
        public let attribution: ProviderMutationAttribution
        public let authenticationMethod: ProviderAuthenticationMethod?
        public let result: String
        public let createdAt: Date
    }

    public func authorityStore_providerConnections() async throws -> [StoredProviderConnection] {
        try await connection.query("SELECT provider_id,connection_id,authentication_method,state,account_label,expires_at,last_tested_at,test_state,detail,key_helper_configured,workload_identity_configured,credential_reference,created_at,updated_at,revision FROM provider_connections ORDER BY provider_id").map { row in
            guard let rawProvider = row.column("provider_id")?.string,
                  let providerID = ProviderSettingsID(rawValue: rawProvider),
                  let rawConnection = row.column("connection_id")?.string,
                  let connectionID = UUID(uuidString: rawConnection),
                  let rawMethod = row.column("authentication_method")?.string,
                  let method = ProviderAuthenticationMethod(rawValue: rawMethod),
                  let rawState = row.column("state")?.string,
                  let state = ProviderConnectionState(rawValue: rawState),
                  let rawTestState = row.column("test_state")?.string,
                  let testState = ProviderCredentialTestState(rawValue: rawTestState)
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connection metadata is invalid", retryable: false) }
            let credentialReference: UUID?
            if let rawReference = row.column("credential_reference")?.string {
                guard let parsed = UUID(uuidString: rawReference) else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider credential reference is invalid", retryable: false)
                }
                credentialReference = parsed
            } else {
                credentialReference = nil
            }
            guard let createdTimestamp = row.column("created_at")?.double,
                  let updatedTimestamp = row.column("updated_at")?.double,
                  createdTimestamp.isFinite,
                  updatedTimestamp.isFinite,
                  let rawRevision = row.column("revision")?.integer,
                  rawRevision > 0
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connection timestamps or revision are invalid", retryable: false)
            }
            let stored = StoredProviderConnection(
                record: ProviderConnectionRecord(
                    connectionID: connectionID,
                    providerID: providerID,
                    authenticationMethod: method,
                    state: state,
                    accountLabel: row.column("account_label")?.string,
                    expiresAt: row.column("expires_at")?.double.map(Date.init(timeIntervalSince1970:)),
                    lastTestedAt: row.column("last_tested_at")?.double.map(Date.init(timeIntervalSince1970:)),
                    testState: testState,
                    detail: row.column("detail")?.string,
                    keyHelperConfigured: row.column("key_helper_configured")?.bool ?? false,
                    workloadIdentityConfigured: row.column("workload_identity_configured")?.bool ?? false,
                    createdAt: Date(timeIntervalSince1970: createdTimestamp),
                    updatedAt: Date(timeIntervalSince1970: updatedTimestamp),
                    revision: Int64(rawRevision)
                ),
                credentialReference: credentialReference
            )
            try Self.validateProviderConnection(stored)
            return stored
        }
    }

    public func providerConnection(providerID: ProviderSettingsID) async throws -> StoredProviderConnection? {
        try await providerConnections().first { $0.record.providerID == providerID }
    }

    @discardableResult
    public func authorityStore_upsertProviderConnection(
        _ value: StoredProviderConnection,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws -> StoredProviderConnection {
        try await transaction {
            try Self.validateProviderConnection(value)
            let observed = try await Int64(connection.query("SELECT revision FROM provider_connections WHERE provider_id=?", [.text(value.record.providerID.rawValue)]).first?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision, value.record.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider connection revision is stale", currentRevision: observed)
            }
            let record = value.record
            _ = try await connection.query(
                "INSERT INTO provider_connections(provider_id,schema_version,connection_id,authentication_method,state,account_label,expires_at,last_tested_at,test_state,detail,key_helper_configured,workload_identity_configured,credential_reference,created_at,updated_at,revision) VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET connection_id=excluded.connection_id,authentication_method=excluded.authentication_method,state=excluded.state,account_label=excluded.account_label,expires_at=excluded.expires_at,last_tested_at=excluded.last_tested_at,test_state=excluded.test_state,detail=excluded.detail,key_helper_configured=excluded.key_helper_configured,workload_identity_configured=excluded.workload_identity_configured,credential_reference=excluded.credential_reference,updated_at=excluded.updated_at,revision=excluded.revision",
                [
                    .text(record.providerID.rawValue), .text(record.connectionID.uuidString), .text(record.authenticationMethod.rawValue), .text(record.state.rawValue),
                    record.accountLabel.map(SQLiteData.text) ?? .null, record.expiresAt.map { .float($0.timeIntervalSince1970) } ?? .null,
                    record.lastTestedAt.map { .float($0.timeIntervalSince1970) } ?? .null, .text(record.testState.rawValue), record.detail.map(SQLiteData.text) ?? .null,
                    .integer(record.keyHelperConfigured ? 1 : 0), .integer(record.workloadIdentityConfigured ? 1 : 0),
                    value.credentialReference.map { .text($0.uuidString) } ?? .null,
                    .float(record.createdAt.timeIntervalSince1970), .float(record.updatedAt.timeIntervalSince1970), .integer(Int(record.revision))
                ]
            )
            if let audit {
                try await appendProviderConnectionAuditInTransaction(
                    providerID: record.providerID,
                    connectionID: record.connectionID,
                    mutation: audit
                )
            }
            return value
        }
    }

    public func authorityStore_deleteProviderConnection(
        providerID: ProviderSettingsID,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws {
        try await transaction {
            let current = try await connection.query("SELECT connection_id,revision FROM provider_connections WHERE provider_id=?", [.text(providerID.rawValue)]).first
            let observed = Int64(current?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider connection revision is stale", currentRevision: observed)
            }
            guard let rawConnectionID = current?.column("connection_id")?.string,
                  let connectionID = UUID(uuidString: rawConnectionID)
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connection identifier is invalid", retryable: false)
            }
            _ = try await connection.query("DELETE FROM provider_connections WHERE provider_id=?", [.text(providerID.rawValue)])
            if let audit {
                try await appendProviderConnectionAuditInTransaction(
                    providerID: providerID,
                    connectionID: connectionID,
                    mutation: audit
                )
            }
        }
    }

    public func authorityStore_appendProviderConnectionAudit(providerID: ProviderSettingsID, connectionID: UUID?, operation: String, attribution: ProviderMutationAttribution, authenticationMethod: ProviderAuthenticationMethod?, result: String) async throws {
        try await transaction {
            try await appendProviderConnectionAuditInTransaction(
                providerID: providerID,
                connectionID: connectionID,
                mutation: .init(operation: operation, attribution: attribution, authenticationMethod: authenticationMethod, result: result)
            )
        }
    }

    public func providerConnectionAudit() async throws -> [ProviderConnectionAuditRecord] {
        try await connection.query("SELECT audit_id,provider_id,connection_id,operation,actor_id,actor_label,channel,authentication_method,result,created_at FROM provider_connection_audit ORDER BY created_at").map { row in
            guard let auditID = row.column("audit_id")?.string.flatMap(UUID.init(uuidString:)),
                  let providerID = row.column("provider_id")?.string.flatMap(ProviderSettingsID.init(rawValue:)),
                  let operation = row.column("operation")?.string,
                  let actorID = row.column("actor_id")?.string,
                  let actorLabel = row.column("actor_label")?.string,
                  let channel = row.column("channel")?.string,
                  let result = row.column("result")?.string,
                  let createdTimestamp = row.column("created_at")?.double,
                  createdTimestamp.isFinite
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider audit metadata is invalid", retryable: false)
            }
            let rawConnectionID = row.column("connection_id")?.string
            let connectionID = try rawConnectionID.map { value -> UUID in
                guard let parsed = UUID(uuidString: value) else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider audit connection identifier is invalid", retryable: false)
                }
                return parsed
            }
            let rawMethod = row.column("authentication_method")?.string
            let authenticationMethod = try rawMethod.map { value -> ProviderAuthenticationMethod in
                guard let parsed = ProviderAuthenticationMethod(rawValue: value) else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider audit authentication method is invalid", retryable: false)
                }
                return parsed
            }
            let attribution = ProviderMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: channel)
            try Self.validateProviderAudit(.init(operation: operation, attribution: attribution, authenticationMethod: authenticationMethod, result: result))
            return ProviderConnectionAuditRecord(
                auditID: auditID,
                providerID: providerID,
                connectionID: connectionID,
                operation: operation,
                attribution: attribution,
                authenticationMethod: authenticationMethod,
                result: result,
                createdAt: Date(timeIntervalSince1970: createdTimestamp)
            )
        }
    }

    func appendProviderConnectionAuditInTransaction(
        providerID: ProviderSettingsID,
        connectionID: UUID?,
        mutation: ProviderConnectionAuditMutation
    ) async throws {
        try Self.validateProviderAudit(mutation)
        _ = try await connection.query(
            "INSERT INTO provider_connection_audit(audit_id,schema_version,provider_id,connection_id,operation,actor_id,actor_label,channel,authentication_method,result,created_at) VALUES(?,1,?,?,?,?,?,?,?,?,?)",
            [
                .text(UUID().uuidString),
                .text(providerID.rawValue),
                connectionID.map { .text($0.uuidString) } ?? .null,
                .text(mutation.operation),
                .text(mutation.attribution.actorID),
                .text(mutation.attribution.actorLabel),
                .text(mutation.attribution.channel),
                mutation.authenticationMethod.map { .text($0.rawValue) } ?? .null,
                .text(mutation.result),
                .float(Date().timeIntervalSince1970)
            ]
        )
    }

    private nonisolated static func validateProviderAudit(_ value: ProviderConnectionAuditMutation) throws {
        guard value.operation.range(of: "^[a-z][A-Za-z0-9]{0,63}$", options: .regularExpression) != nil,
              value.result.range(of: "^[a-z][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              (1 ... 256).contains(value.attribution.actorID.utf8.count),
              (1 ... 128).contains(value.attribution.actorLabel.utf8.count),
              value.attribution.channel.range(of: "^[a-z][a-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              isSafeProviderMetadata(value.attribution.actorID),
              isSafeProviderMetadata(value.attribution.actorLabel)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider audit metadata is invalid")
        }
    }

    private nonisolated static func validateProviderConnection(_ value: StoredProviderConnection) throws {
        let record = value.record
        let allowedMethods: Set<ProviderAuthenticationMethod> = switch record.providerID {
        case .codex: [.deviceCodeBeta, .apiKey, .enterpriseAccessToken]
        case .claudeCompatible: [.apiKey, .authToken, .providerSpecific]
        case .claudeGLM, .claudeKimi: [.apiKey, .authToken]
        case .claudeCustom: [.apiKey, .authToken]
        case .cursorACP: [.apiKey, .browserLogin]
        case .openCodeACP: [.providerSpecific]
        case .grokBuildACP: [.apiKey, .providerSpecific]
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI:
            [.apiKey]
        case .ollama:
            []
        }
        let vaultMethods: Set<ProviderAuthenticationMethod> = [.apiKey, .enterpriseAccessToken, .authToken]
        guard allowedMethods.contains(record.authenticationMethod),
              vaultMethods.contains(record.authenticationMethod) ? value.credentialReference != nil : value.credentialReference == nil,
              record.revision > 0,
              record.createdAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite,
              record.updatedAt >= record.createdAt,
              record.expiresAt?.timeIntervalSince1970.isFinite ?? true,
              record.lastTestedAt?.timeIntervalSince1970.isFinite ?? true,
              (record.state == .connected) == (record.testState == .valid),
              record.keyHelperConfigured == false,
              record.workloadIdentityConfigured == false,
              record.accountLabel.map({ $0.utf8.count <= 256 && Self.isSafeProviderMetadata($0) }) ?? true,
              record.detail.map({ $0.utf8.count <= 512 && Self.isSafeProviderMetadata($0) }) ?? true
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connection metadata is invalid", retryable: false)
        }
    }

    private nonisolated static func isSafeProviderMetadata(_ value: String) -> Bool {
        !value.isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !ProviderSecretRedaction.containsLikelySecret(value)
    }

    public func portalDesktopSettings() async throws -> OperatorDesktopSettingsRecord? {
        guard let row = try await connection.query(
            "SELECT schema_version,values_json,revision,updated_at FROM portal_desktop_settings WHERE fixed_id=1"
        ).first,
            let valuesJSON = row.column("values_json")?.string
        else { return nil }
        return try OperatorDesktopSettingsRecord(
            schemaVersion: row.column("schema_version")?.integer ?? 1,
            revision: Int64(row.column("revision")?.integer ?? 0),
            values: decoder.decode([String: String].self, from: Data(valuesJSON.utf8)),
            updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0)
        )
    }

    @discardableResult
    public func upsertPortalDesktopSettings(
        _ snapshot: OperatorDesktopSettingsRecord,
        expectedRevision: Int64
    ) async throws -> OperatorDesktopSettingsRecord {
        try await transaction {
            let observed = Int64(try await connection.query(
                "SELECT revision FROM portal_desktop_settings WHERE fixed_id=1"
            ).first?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision, snapshot.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .staleRevision, message: "Settings revision is stale", currentRevision: observed)
            }
            _ = try await connection.query(
                "INSERT INTO portal_desktop_settings(fixed_id,schema_version,values_json,revision,updated_at) VALUES(1,1,?,?,?) ON CONFLICT(fixed_id) DO UPDATE SET values_json=excluded.values_json,revision=excluded.revision,updated_at=excluded.updated_at",
                [.text(encodeText(snapshot.values)), .integer(Int(snapshot.revision)), .float(snapshot.updatedAt.timeIntervalSince1970)]
            )
            return snapshot
        }
    }

    public func authorityStore_providerSettings() async throws -> [ProviderSettingsPreference] {
        try await connection.query(
            "SELECT provider_id,enabled,default_model,reasoning_effort,speed_mode,service_tier,revision FROM provider_settings ORDER BY provider_id"
        ).map { row in
            guard let rawID = row.column("provider_id")?.string,
                  let providerID = ProviderSettingsID(rawValue: rawID)
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider settings contain an unknown provider identifier", retryable: false)
            }
            return ProviderSettingsPreference(
                providerID: providerID,
                enabled: row.column("enabled")?.bool ?? false,
                defaultModel: row.column("default_model")?.string,
                reasoningEffort: row.column("reasoning_effort")?.string,
                speedMode: row.column("speed_mode")?.string,
                serviceTier: row.column("service_tier")?.string,
                revision: Int64(row.column("revision")?.integer ?? 1)
            )
        }
    }

    @discardableResult
    public func authorityStore_upsertProviderSettings(
        _ value: ProviderSettingsPreference,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws -> ProviderSettingsPreference {
        try await transaction {
            let observed = try await Int64(connection.query(
                "SELECT revision FROM provider_settings WHERE provider_id=?",
                [.text(value.providerID.rawValue)]
            ).first?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision, value.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider settings revision is stale", currentRevision: observed)
            }
            let defaultModel: SQLiteData = value.defaultModel.map(SQLiteData.text) ?? .null
            let reasoningEffort: SQLiteData = value.reasoningEffort.map(SQLiteData.text) ?? .null
            let speedMode: SQLiteData = value.speedMode.map(SQLiteData.text) ?? .null
            let serviceTier: SQLiteData = value.serviceTier.map(SQLiteData.text) ?? .null
            _ = try await connection.query(
                "INSERT INTO provider_settings(provider_id,schema_version,enabled,default_model,reasoning_effort,speed_mode,service_tier,revision,updated_at) VALUES(?,1,?,?,?,?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET enabled=excluded.enabled,default_model=excluded.default_model,reasoning_effort=excluded.reasoning_effort,speed_mode=excluded.speed_mode,service_tier=excluded.service_tier,revision=excluded.revision,updated_at=excluded.updated_at",
                [.text(value.providerID.rawValue), .integer(value.enabled ? 1 : 0), defaultModel, reasoningEffort, speedMode, serviceTier, .integer(Int(value.revision)), .float(Date().timeIntervalSince1970)]
            )
            if let audit {
                try await appendProviderConnectionAuditInTransaction(
                    providerID: value.providerID,
                    connectionID: nil,
                    mutation: audit
                )
            }
            return value
        }
    }

    private func migrate() async throws {
        _ = try await connection.query("PRAGMA foreign_keys=ON")
        _ = try await connection.query("PRAGMA journal_mode=WAL")
        _ = try await connection.query("PRAGMA synchronous=FULL")
        _ = try await connection.query("PRAGMA busy_timeout=5000")
        for statement in SchemaV1.statements {
            _ = try await connection.query(statement)
        }
        try await addColumnIfMissing(table: "events", column: "agent_id", definition: "TEXT")
        try await addColumnIfMissing(table: "events", column: "parent_agent_id", definition: "TEXT")
        try await addColumnIfMissing(table: "service_metadata", column: "last_event_timestamp", definition: "REAL NOT NULL DEFAULT 0")
        try await addColumnIfMissing(table: "service_metadata", column: "activation_state", definition: "TEXT NOT NULL DEFAULT 'active'")
        try await addColumnIfMissing(table: "service_metadata", column: "activation_generation", definition: "INTEGER NOT NULL DEFAULT 1")
        try await addColumnIfMissing(table: "service_metadata", column: "activation_token_digest", definition: "TEXT")
        try await addColumnIfMissing(table: "service_metadata", column: "activation_instance_id", definition: "TEXT")
        try await addColumnIfMissing(table: "collaboration_metadata", column: "collaboration_acknowledgement_json", definition: "TEXT")
        try await rewriteLegacyPersistedJSONKeys()
        try await addColumnIfMissing(table: "owned_resources", column: "external_id", definition: "TEXT")
        try await addColumnIfMissing(table: "owned_resources", column: "temporary_path_identity", definition: "TEXT")
        try await addColumnIfMissing(table: "owned_resources", column: "content_digest", definition: "TEXT")
        try await addColumnIfMissing(table: "owned_resources", column: "metadata_json", definition: "TEXT NOT NULL DEFAULT '{}'")
        try await addColumnIfMissing(table: "owned_resources", column: "created_at", definition: "REAL NOT NULL DEFAULT 0")
        try await addColumnIfMissing(table: "owned_resources", column: "updated_at", definition: "REAL NOT NULL DEFAULT 0")
        try await addColumnIfMissing(table: "snapshot_checkpoints", column: "retention_class", definition: "TEXT NOT NULL DEFAULT 'rolling'")
        try await addColumnIfMissing(table: "snapshot_checkpoints", column: "archive_id", definition: "TEXT")
        _ = try await connection.query(
            "CREATE TABLE IF NOT EXISTS operator_accounts(username TEXT PRIMARY KEY,password_salt TEXT NOT NULL,password_hash TEXT NOT NULL,iterations INTEGER NOT NULL,created_at TEXT NOT NULL)"
        )
        _ = try await connection.query(
            "CREATE TABLE IF NOT EXISTS operator_sessions(session_id TEXT PRIMARY KEY,username TEXT NOT NULL,token_hash TEXT NOT NULL,created_at TEXT NOT NULL,expires_at REAL NOT NULL)"
        )
        _ = try await connection.query(
            "CREATE TABLE IF NOT EXISTS operator_setup_tokens(token_hash TEXT PRIMARY KEY,created_at TEXT NOT NULL,consumed_at TEXT)"
        )
        for statement in SchemaV2.statements {
            _ = try await connection.query(statement)
        }
        for statement in SchemaV3.statements {
            _ = try await connection.query(statement)
        }
        for statement in SchemaV4.statements {
            _ = try await connection.query(statement)
        }
        for statement in SchemaV5.statements {
            _ = try await connection.query(statement)
        }
        for statement in SchemaV6.statements {
            _ = try await connection.query(statement)
        }
        let count = try await connection.query("SELECT COUNT(*) AS count FROM service_metadata").first?.column("count")?.integer ?? 0
        if count == 0 {
            _ = try await connection.query("INSERT INTO service_metadata(fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor) VALUES(1,?,1,CURRENT_TIMESTAMP,0,1,1,0)", [.text(UUID().uuidString)])
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v1',1,'initial durable service schema','v1',CURRENT_TIMESTAMP)")
        }
        let v2 = try await connection.query("SELECT digest FROM schema_migrations WHERE version=2").first
        if let v2 {
            guard v2.column("digest")?.string == SchemaV2.digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v2 migration digest mismatch", retryable: false)
            }
        } else {
            _ = try await connection.query("UPDATE owned_resources SET created_at=CASE WHEN created_at=0 THEN unixepoch() ELSE created_at END,updated_at=CASE WHEN updated_at=0 THEN unixepoch() ELSE updated_at END")
            _ = try await connection.query("INSERT OR IGNORE INTO session_event_counters(session_id,event_count,last_sequence) SELECT session_id,COUNT(*),MAX(global_sequence) FROM events WHERE session_id IS NOT NULL GROUP BY session_id")
            _ = try await connection.query("UPDATE service_metadata SET schema_version=2,last_event_timestamp=COALESCE((SELECT MAX(timestamp) FROM events),0) WHERE fixed_id=1")
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v2',2,'owned resources, immutable archives, protected checkpoints, and restore activation',?,CURRENT_TIMESTAMP)", [.text(SchemaV2.digest)])
        }
        let v3 = try await connection.query("SELECT digest FROM schema_migrations WHERE version=3").first
        if let v3 {
            guard v3.column("digest")?.string == SchemaV3.digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v3 migration digest mismatch", retryable: false)
            }
        } else {
            _ = try await connection.query("UPDATE service_metadata SET schema_version=3 WHERE fixed_id=1")
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v3',3,'provider settings and browser-safe portal preferences',?,CURRENT_TIMESTAMP)", [.text(SchemaV3.digest)])
        }
        let v4 = try await connection.query("SELECT digest FROM schema_migrations WHERE version=4").first
        if let v4 {
            guard v4.column("digest")?.string == SchemaV4.digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v4 migration digest mismatch", retryable: false)
            }
        } else {
            _ = try await connection.query("UPDATE service_metadata SET schema_version=4 WHERE fixed_id=1")
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v4',4,'provider connection metadata and secret-free audit attribution',?,CURRENT_TIMESTAMP)", [.text(SchemaV4.digest)])
        }
        let v5 = try await connection.query("SELECT digest FROM schema_migrations WHERE version=5").first
        if let v5 {
            guard v5.column("digest")?.string == SchemaV5.digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v5 migration digest mismatch", retryable: false)
            }
        } else {
            _ = try await connection.query("UPDATE service_metadata SET schema_version=5 WHERE fixed_id=1")
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v5',5,'server-authoritative Desktop settings projection',?,CURRENT_TIMESTAMP)", [.text(SchemaV5.digest)])
        }
        let v6 = try await connection.query("SELECT digest FROM schema_migrations WHERE version=6").first
        if let v6 {
            let observedDigest = v6.column("digest")?.string
            if observedDigest != SchemaV6.digest {
                guard let observedDigest, SchemaV6.compatiblePriorDigests.contains(observedDigest) else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v6 migration digest mismatch", retryable: false)
                }
                _ = try await connection.query(
                    "UPDATE schema_migrations SET description='typed revisioned server settings plus agent composer transactional acceptance and semantic presentation',digest=?,applied_at=CURRENT_TIMESTAMP WHERE version=6",
                    [.text(SchemaV6.digest)]
                )
            }
        } else {
            _ = try await connection.query("UPDATE service_metadata SET schema_version=6 WHERE fixed_id=1")
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v6',6,'typed revisioned server settings plus agent composer transactional acceptance and semantic presentation',?,CURRENT_TIMESTAMP)", [.text(SchemaV6.digest)])
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) async throws {
        let columns = try await connection.query("PRAGMA table_info(\(table))")
        guard !columns.contains(where: { $0.column("name")?.string == column }) else { return }
        _ = try await connection.query("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func rewriteLegacyPersistedJSONKeys() async throws {
        let replacements = [
            (#""goblinUserId""#, #""userId""#),
            (#""goblin-explicit-selection""#, #""explicit-selection""#),
        ]
        let columns = [
            ("projects", ["creator_json", "snapshot_json"]),
            ("sessions", ["snapshot_json"]),
            ("events", ["actor_json", "payload_json", "envelope_json"]),
            ("interactions", ["payload_json", "settled_actor_json"]),
            ("execution_permissions", ["updated_actor_json"]),
            ("collaboration_metadata", ["collaboration_acknowledgement_json"]),
        ]
        for (table, names) in columns {
            let existing = Set((try await connection.query("PRAGMA table_info(\(table))")).compactMap { $0.column("name")?.string })
            for name in names where existing.contains(name) {
                for (from, to) in replacements {
                    _ = try await connection.query("UPDATE \(table) SET \(name) = REPLACE(\(name), ?, ?) WHERE \(name) LIKE '%' || ? || '%'", [.text(from), .text(to), .text(from)])
                }
            }
        }
        let collaborationColumns = Set((try await connection.query("PRAGMA table_info(collaboration_metadata)")).compactMap { $0.column("name")?.string })
        if collaborationColumns.contains("goblin_acknowledgement_json") {
            if collaborationColumns.contains("collaboration_acknowledgement_json") {
                _ = try await connection.query(
                    "UPDATE collaboration_metadata SET collaboration_acknowledgement_json = goblin_acknowledgement_json WHERE collaboration_acknowledgement_json IS NULL AND goblin_acknowledgement_json IS NOT NULL"
                )
            }
            _ = try await connection.query("ALTER TABLE collaboration_metadata DROP COLUMN goblin_acknowledgement_json")
        }
    }

    private func integrityCheck() async throws {
        let result = try await connection.query("PRAGMA quick_check").first?.columns.first?.data.string
        guard result == "ok" else { throw ServiceAPIError(code: .persistenceUnavailable, message: "SQLite integrity check failed", retryable: false) }
    }

    func transaction<T>(_ body: () async throws -> T) async throws -> T {
        await acquireTransactionSlot()
        do {
            _ = try await connection.query("BEGIN IMMEDIATE")
            try await faultInjector.hit(.afterTransactionBegin)
            let result = try await body()
            try await faultInjector.hit(.beforeTransactionCommit)
            _ = try await connection.query("COMMIT")
            releaseTransactionSlot()
            return result
        } catch let existing as ExistingIdempotency {
            await rollbackIgnoringTaskCancellation()
            releaseTransactionSlot()
            throw existing
        } catch {
            await rollbackIgnoringTaskCancellation()
            releaseTransactionSlot()
            throw error
        }
    }

    /// A provider cancellation may enter this catch path with the current task
    /// already canceled. Running ROLLBACK on that task can itself be canceled
    /// before SQLite observes it, leaving the connection inside BEGIN while the
    /// transaction gate is released. Finalize on an uncanceled task and wait for
    /// it before handing the slot to the next mutation.
    private func rollbackIgnoringTaskCancellation() async {
        let connection = connection
        _ = try? await Task.detached {
            try await connection.query("ROLLBACK")
        }.value
    }

    private func acquireTransactionSlot() async {
        guard transactionActive else {
            transactionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transactionWaiters.append(continuation)
        }
    }

    private func releaseTransactionSlot() {
        guard !transactionWaiters.isEmpty else {
            transactionActive = false
            return
        }
        transactionWaiters.removeFirst().resume()
    }

    private func validateExpectedCursor(_ cursor: ServiceCursor) async throws {
        let meta = try await metadata()
        guard cursor.storeID == meta.storeID, cursor.globalSequence == meta.nextGlobalSequence else { throw ServiceAPIError(code: .staleRevision, message: "Publication cursor is stale", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.nextGlobalSequence)) }
    }

    private func decodeRows<T: Decodable>(_ sql: String, as: T.Type) async throws -> [T] {
        try await connection.query(sql).compactMap { row in guard let text = row.column("snapshot_json")?.string else { return nil }
            return try decoder.decode(T.self, from: Data(text.utf8))
        }
    }

    func encodeText(_ value: some Encodable) throws -> String {
        try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    private func requireRow(_ rows: [SQLiteRow]) throws -> SQLiteRow {
        guard let row = rows.first else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Service metadata is missing") }
        return row
    }

    func requireUUID(_ value: String?) throws -> UUID {
        guard let value, let id = UUID(uuidString: value) else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted UUID is invalid") }
        return id
    }

    private func ensureUniqueActiveWorktree(_ snapshot: WorktreeBindingSnapshot) async throws {
        guard snapshot.ownershipState == .active, let sessionID = snapshot.sessionID else { return }
        let collision = try await connection.query(
            "SELECT binding_id FROM worktree_bindings WHERE project_id=? AND root_id=? AND session_id=? AND ownership_state=? AND binding_id<>? LIMIT 1",
            [.text(snapshot.projectID.uuidString), .text(snapshot.rootID.uuidString), .text(sessionID.uuidString), .text(WorktreeBindingSnapshot.OwnershipState.active.rawValue), .text(snapshot.bindingID.uuidString)]
        ).first
        guard collision == nil else {
            throw ServiceAPIError(code: .worktreeConflict, message: "A project root already has an active session worktree")
        }
    }

    private func decodeWorktree(_ row: SQLiteRow) throws -> WorktreeBindingSnapshot {
        guard let ownership = WorktreeBindingSnapshot.OwnershipState(rawValue: row.column("ownership_state")?.string ?? ""),
              let merge = WorktreeBindingSnapshot.MergeState(rawValue: row.column("merge_state")?.string ?? "")
        else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted worktree state is invalid") }
        return try WorktreeBindingSnapshot(
            bindingID: requireUUID(row.column("binding_id")?.string),
            projectID: requireUUID(row.column("project_id")?.string),
            rootID: requireUUID(row.column("root_id")?.string),
            sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)),
            baseRef: row.column("base_ref")?.string ?? "",
            branch: row.column("branch")?.string ?? "",
            physicalPath: row.column("physical_path")?.string ?? "",
            ownershipState: ownership,
            mergeState: merge,
            revision: Int64(row.column("revision")?.integer ?? 1)
        )
    }

    private func decodeArtifact(_ row: SQLiteRow, storeID: UUID) throws -> (snapshot: ArtifactSnapshot, storageReference: String) {
        let snapshot = try ArtifactSnapshot(
            artifactID: requireUUID(row.column("artifact_id")?.string),
            projectID: requireUUID(row.column("project_id")?.string),
            sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)),
            kind: row.column("kind")?.string ?? "",
            logicalName: row.column("logical_name")?.string ?? "",
            contentDigest: row.column("content_digest")?.string ?? "",
            size: Int64(row.column("size")?.integer ?? 0),
            createdCursor: ServiceCursor(storeID: storeID, globalSequence: Int64(row.column("created_sequence")?.integer ?? 0)),
            retentionState: row.column("retention_state")?.string ?? "active"
        )
        guard let reference = row.column("storage_reference")?.string else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted artifact reference is missing")
        }
        return (snapshot, reference)
    }

    private func replacingCursor(_ value: ProjectSnapshot, cursor: ServiceCursor) -> ProjectSnapshot {
        ProjectSnapshot(projectID: value.projectID, name: value.name, creator: value.creator, state: value.state, roots: value.roots, revision: value.revision, cursor: cursor)
    }

    private func saveCheckpoint(
        scope: String,
        sequence: Int64,
        snapshot: Data,
        retentionClass: String = "rolling",
        archiveID: UUID? = nil
    ) async throws {
        let digest = PersistenceCryptography.bodyDigest(snapshot)
        if let existing = try await connection.query(
            "SELECT digest,retention_class FROM snapshot_checkpoints WHERE scope=? AND sequence=?",
            [.text(scope), .integer(Int(sequence))]
        ).first {
            guard existing.column("digest")?.string == digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Checkpoint identity collides with different content", retryable: false)
            }
            if existing.column("retention_class")?.string == "rolling", retentionClass != "rolling" {
                _ = try await connection.query(
                    "UPDATE snapshot_checkpoints SET retention_class=?,archive_id=? WHERE scope=? AND sequence=?",
                    [.text(retentionClass), archiveID.map { .text($0.uuidString) } ?? .null, .text(scope), .integer(Int(sequence))]
                )
            }
        } else {
            _ = try await connection.query(
                "INSERT INTO snapshot_checkpoints(scope,sequence,schema_version,snapshot,digest,created_at,retention_class,archive_id) VALUES(?,?,2,?,?,CURRENT_TIMESTAMP,?,?)",
                [.text(scope), .integer(Int(sequence)), .text(snapshot.base64EncodedString()), .text(digest), .text(retentionClass), archiveID.map { .text($0.uuidString) } ?? .null]
            )
        }
        _ = try await connection.query(
            "DELETE FROM snapshot_checkpoints WHERE scope=? AND retention_class='rolling' AND sequence NOT IN (SELECT sequence FROM snapshot_checkpoints WHERE scope=? AND retention_class='rolling' ORDER BY sequence DESC LIMIT 3)",
            [.text(scope), .text(scope)]
        )
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        value.replacing(cursor: cursor)
    }
}

private extension SQLiteServiceStore {
    func existingIdempotency(_ input: IdempotencyInput) async throws -> (Data, Int)? {
        guard let row = try await connection.query("SELECT request_digest,response_body,status FROM idempotency_records WHERE actor_id=? AND operation=? AND idempotency_key=?", [.text(input.actorID), .text(input.operation), .text(input.key)]).first else { return nil }
        guard row.column("request_digest")?.string == input.requestDigest else { throw ServiceAPIError(code: .idempotencyConflict, message: "Idempotency key was used with a different request") }
        let response = Data(base64Encoded: row.column("response_body")?.string ?? "") ?? Data()
        return (response, row.column("status")?.integer ?? 200)
    }

    func saveIdempotency(_ input: IdempotencyInput, status: Int, response: Data) async throws {
        _ = try await connection.query("INSERT INTO idempotency_records(actor_id,operation,idempotency_key,request_digest,response_body,status,created_at,expires_at) VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP,datetime('now','+30 days'))", [.text(input.actorID), .text(input.operation), .text(input.key), .text(input.requestDigest), .text(response.base64EncodedString()), .integer(status)])
    }
}
