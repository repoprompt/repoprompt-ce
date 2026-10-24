import CryptoKit
import Foundation

/// Mutable connection state owned exclusively by the catalog's writer lock or reader actor.
/// Never escapes its owner; internal calls reuse the held transaction without acquiring a lock.
final class SessionCatalogConnection {
    private static let schemaVersion = 1
    private let database: SessionCatalogDatabase
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(databaseURL: URL, readOnly: Bool = false) throws {
        let parent = databaseURL.deletingLastPathComponent()
        if !readOnly {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let database = try SessionCatalogDatabase(url: databaseURL, readOnly: readOnly)
        self.database = database
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if readOnly {
            let version = try Int(database.integer("PRAGMA user_version") ?? 0)
            guard version <= Self.schemaVersion else { throw SessionCatalogError.futureSchema(version) }
            guard version == Self.schemaVersion,
                  try database.integer("SELECT generation FROM catalog_state WHERE singleton = 1") != nil
            else { throw SessionCatalogError.corruptSchema }
            return
        }
        // First-open initialization is serialized, including the version/table checks.
        try database.execute("BEGIN EXCLUSIVE")
        do {
            let version = try Int(database.integer("PRAGMA user_version") ?? 0)
            guard version <= Self.schemaVersion else { throw SessionCatalogError.futureSchema(version) }
            if version == 0 {
                let tables = try database.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") ?? 0
                guard tables == 0 else { throw SessionCatalogError.corruptSchema }
                for statement in Self.schema {
                    try database.execute(statement)
                }
                try database.execute("PRAGMA user_version = 1")
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = FULL")
        try database.execute("PRAGMA foreign_keys = ON")
        // Verify the mandatory state rather than accepting a corrupt file as an empty catalog.
        guard try database.integer("SELECT generation FROM catalog_state WHERE singleton = 1") != nil else { throw SessionCatalogError.corruptSchema }
    }

    private static let schema = [
        "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), generation INTEGER NOT NULL, coverage TEXT NOT NULL, session_count INTEGER NOT NULL DEFAULT 0)",
        "INSERT INTO catalog_state(singleton, generation, coverage) VALUES (1, 0, 'pending')",
        "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, coverage TEXT NOT NULL, record BLOB NOT NULL, session_count INTEGER NOT NULL DEFAULT 0)",
        "CREATE INDEX workspaces_name ON workspaces(name COLLATE NOCASE, id)",
        "CREATE INDEX workspaces_coverage ON workspaces(coverage)",
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id), parent_id TEXT, tab_id TEXT, activity REAL NOT NULL, revision INTEGER NOT NULL, record BLOB NOT NULL)",
        "CREATE INDEX sessions_workspace_activity ON sessions(workspace_id, activity DESC, id DESC)",
        "CREATE INDEX sessions_activity ON sessions(activity DESC, id DESC)",
        "CREATE INDEX sessions_parent ON sessions(parent_id, id)",
        "CREATE INDEX sessions_tab ON sessions(workspace_id, tab_id, id)",
        "CREATE TRIGGER session_insert_count AFTER INSERT ON sessions BEGIN UPDATE catalog_state SET session_count = session_count + 1 WHERE singleton = 1; UPDATE workspaces SET session_count = session_count + 1 WHERE id = NEW.workspace_id; END",
        "CREATE TRIGGER session_delete_count AFTER DELETE ON sessions BEGIN UPDATE catalog_state SET session_count = session_count - 1 WHERE singleton = 1; UPDATE workspaces SET session_count = session_count - 1 WHERE id = OLD.workspace_id; END",
        "CREATE TRIGGER session_move_count AFTER UPDATE OF workspace_id ON sessions WHEN OLD.workspace_id != NEW.workspace_id BEGIN UPDATE workspaces SET session_count = session_count - 1 WHERE id = OLD.workspace_id; UPDATE workspaces SET session_count = session_count + 1 WHERE id = NEW.workspace_id; END",
        "CREATE TABLE tombstones (kind TEXT NOT NULL, id TEXT NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(kind, id))",
        "CREATE TABLE operations (id TEXT PRIMARY KEY, digest TEXT NOT NULL, generation INTEGER NOT NULL)",
        "CREATE TABLE classifications (path TEXT PRIMARY KEY, signature TEXT NOT NULL, classification TEXT NOT NULL, reconciliation_generation INTEGER NOT NULL)",
        "CREATE TABLE reconciliation (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), generation INTEGER NOT NULL, record BLOB NOT NULL)"
    ]

    private func transaction<T>(readOnly: Bool = false, _ operation: () throws -> T) throws -> T {
        try database.execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try database.execute("COMMIT")
            return result
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// Catalog facts commit atomically. Operation IDs bind the entire ordered transaction.
    /// This API persists owner-accepted facts; it cannot authorize or publish a file mutation.
    func commit(
        operationID: UUID,
        mutations: [SessionCatalogMutation]
    ) throws -> SessionCatalogCommit {
        try Task.checkCancellation()
        let fingerprint = try encoder.encode(TransactionFingerprint(mutations: mutations))
        let digest = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
        return try transaction {
            let previous = try database.rows("SELECT digest, generation FROM operations WHERE id = ?", [.text(operationID.uuidString)]) {
                try (SessionCatalogDatabase.string($0), SessionCatalogDatabase.integerValue($0, column: 1))
            }.first
            if let previous {
                guard previous.0 == digest else { throw SessionCatalogError.operationConflict }
                return SessionCatalogCommit(generation: previous.1, replayed: true)
            }
            guard !mutations.isEmpty else { throw SessionCatalogError.invalidRecord }
            let generation = try currentGeneration() + 1
            for mutation in mutations {
                try Task.checkCancellation()
                try apply(mutation, generation: generation)
            }
            try database.execute("UPDATE catalog_state SET generation = ? WHERE singleton = 1", [.integer(generation)])
            try database.execute("INSERT INTO operations VALUES (?, ?, ?)", [.text(operationID.uuidString), .text(digest), .integer(generation)])
            return SessionCatalogCommit(generation: generation, replayed: false)
        }
    }

    private struct TransactionFingerprint: Encodable {
        let version = 1
        let mutations: [SessionCatalogMutation]
    }

    private func apply(_ mutation: SessionCatalogMutation, generation: Int64) throws {
        switch mutation {
        case let .workspace(input, expected):
            guard input.directory.isFileURL, !input.name.isEmpty else { throw SessionCatalogError.invalidRecord }
            try checkRevision(table: "workspaces", kind: "workspace", id: input.id, expected: expected)
            let previous = try workspace(id: input.id)
            var record = input
            record.coverage = previous?.directory == input.directory ? previous?.coverage ?? .pending : .pending
            record.revision = generation
            if record.coverage != .complete {
                try database.execute("UPDATE catalog_state SET coverage = 'pending' WHERE singleton = 1 AND coverage = 'complete'")
            }
            try database.execute(
                "INSERT INTO workspaces(id, name, revision, coverage, record) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, revision = excluded.revision, coverage = excluded.coverage, record = excluded.record",
                [.text(record.id.uuidString), .text(record.name), .integer(generation), .text(record.coverage.rawValue), .bytes(encoder.encode(record))]
            )
        case let .session(input, expected):
            guard input.filename == "AgentSession-\(input.id.uuidString).json", input.metadata.count <= 64 * 1024,
                  input.effectiveParentID != input.id,
                  input.activityAt.timeIntervalSinceReferenceDate.isFinite else { throw SessionCatalogError.invalidRecord }
            if try database.integer("SELECT generation FROM tombstones WHERE kind = 'workspace' AND id = ?", [.text(input.workspaceID.uuidString)]) != nil { throw SessionCatalogError.deletedIdentity }
            guard try database.integer("SELECT revision FROM workspaces WHERE id = ?", [.text(input.workspaceID.uuidString)]) != nil else { throw SessionCatalogError.unknownWorkspace }
            try checkRevision(table: "sessions", kind: "session", id: input.id, expected: expected)
            var record = input
            record.revision = generation
            try database.execute(
                "INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET workspace_id = excluded.workspace_id, parent_id = excluded.parent_id, tab_id = excluded.tab_id, activity = excluded.activity, revision = excluded.revision, record = excluded.record",
                [
                    .text(record.id.uuidString),
                    .text(record.workspaceID.uuidString),
                    record.effectiveParentID.map { .text($0.uuidString) } ?? .null,
                    record.tabID.map { .text($0.uuidString) } ?? .null,
                    .real(record.activityAt.timeIntervalSinceReferenceDate),
                    .integer(generation),
                    .bytes(encoder.encode(record))
                ]
            )
        case let .deleteSession(id, expected):
            try checkRevision(table: "sessions", kind: "session", id: id, expected: expected)
            try tombstone(kind: "session", id: id, generation: generation)
            try database.execute("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
        case let .deleteWorkspace(id, expected):
            try checkRevision(table: "workspaces", kind: "workspace", id: id, expected: expected)
            try database.execute("INSERT INTO tombstones SELECT 'session', id, ? FROM sessions WHERE workspace_id = ?", [.integer(generation), .text(id.uuidString)])
            try database.execute("DELETE FROM sessions WHERE workspace_id = ?", [.text(id.uuidString)])
            try tombstone(kind: "workspace", id: id, generation: generation)
            try database.execute("DELETE FROM workspaces WHERE id = ?", [.text(id.uuidString)])
        case let .coverage(workspaceID, state):
            if let workspaceID {
                guard var workspace = try workspace(id: workspaceID) else { throw SessionCatalogError.invalidRecord }
                workspace.coverage = state
                try database.execute(
                    "UPDATE workspaces SET coverage = ?, record = ? WHERE id = ?",
                    [.text(state.rawValue), .bytes(encoder.encode(workspace)), .text(workspaceID.uuidString)]
                )
                if state != .complete {
                    try database.execute("UPDATE catalog_state SET coverage = ? WHERE singleton = 1 AND coverage = 'complete'", [.text(state.rawValue)])
                }
            } else {
                if state == .complete {
                    guard try database.integer("SELECT 1 FROM workspaces WHERE coverage != 'complete' LIMIT 1") == nil else { throw SessionCatalogError.invalidRecord }
                }
                try database.execute("UPDATE catalog_state SET coverage = ? WHERE singleton = 1", [.text(state.rawValue)])
            }
        }
    }

    private func checkRevision(table: String, kind: String, id: UUID, expected: SessionCatalogExpectedRevision) throws {
        if try database.integer("SELECT generation FROM tombstones WHERE kind = ? AND id = ?", [.text(kind), .text(id.uuidString)]) != nil { throw SessionCatalogError.deletedIdentity }
        // table/kind are private, constant call-site values, never supplied by a tool argument.
        let actual = try database.integer("SELECT revision FROM \(table) WHERE id = ?", [.text(id.uuidString)])
        switch expected {
        case .absent: guard actual == nil else { throw SessionCatalogError.revisionConflict }
        case let .revision(value): guard actual == value else { throw SessionCatalogError.revisionConflict }
        }
    }

    private func tombstone(kind: String, id: UUID, generation: Int64) throws {
        try database.execute("INSERT INTO tombstones VALUES (?, ?, ?)", [.text(kind), .text(id.uuidString), .integer(generation)])
    }

    func currentGeneration() throws -> Int64 {
        guard let generation = try database.integer("SELECT generation FROM catalog_state WHERE singleton = 1") else { throw SessionCatalogError.corruptSchema }
        return generation
    }

    func workspace(id: UUID) throws -> SessionCatalogWorkspace? {
        try decodedRows("SELECT record FROM workspaces WHERE id = ?", [.text(id.uuidString)]).first
    }

    func workspaces(named name: String) throws -> [SessionCatalogWorkspace] {
        try decodedRows("SELECT record FROM workspaces WHERE name = ? COLLATE NOCASE ORDER BY id", [.text(name)])
    }

    func workspaces() throws -> [SessionCatalogWorkspace] {
        try decodedRows("SELECT record FROM workspaces ORDER BY id")
    }

    func session(id: UUID) throws -> SessionCatalogRecord? {
        try decodedRows("SELECT record FROM sessions WHERE id = ?", [.text(id.uuidString)]).first
    }

    func children(of parentID: UUID) throws -> [SessionCatalogRecord] {
        try decodedRows("SELECT record FROM sessions WHERE parent_id = ? ORDER BY id", [.text(parentID.uuidString)])
    }

    func sessions(workspaceID: UUID? = nil, limit: Int = 100, after cursor: SessionCatalogCursor? = nil) throws -> SessionCatalogPage {
        try transaction(readOnly: true) { try sessionPage(workspaceID: workspaceID, limit: limit, after: cursor) }
    }

    private func sessionPage(workspaceID: UUID?, limit: Int, after cursor: SessionCatalogCursor?) throws -> SessionCatalogPage {
        guard (1 ... 1000).contains(limit) else { throw SessionCatalogError.invalidRecord }
        let generation = try currentGeneration()
        if let cursor {
            guard cursor.workspaceID == workspaceID else { throw SessionCatalogError.invalidRecord }
            guard generation == cursor.generation else { throw SessionCatalogError.staleGeneration }
        }
        var predicates: [String] = []
        var bindings: [SessionCatalogDatabase.Binding] = []
        if let workspaceID {
            predicates.append("workspace_id = ?")
            bindings.append(.text(workspaceID.uuidString))
        }
        let totals = try database.rows(
            workspaceID == nil ? "SELECT session_count, coverage FROM catalog_state WHERE singleton = 1" : "SELECT session_count, coverage FROM workspaces WHERE id = ?",
            bindings
        ) { try (Int(SessionCatalogDatabase.integerValue($0, column: 0)), SessionCatalogDatabase.string($0, column: 1)) }.first
        let total: Int
        let coverage: SessionCatalogCoverage
        if let totals {
            guard let state = SessionCatalogCoverage(rawValue: totals.1) else { throw SessionCatalogError.corruptSchema }
            total = totals.0
            coverage = state
        } else {
            guard workspaceID != nil else { throw SessionCatalogError.corruptSchema }
            total = 0
            coverage = .pending
        }
        if let cursor {
            predicates.append("(activity, id) < (?, ?)")
            bindings += [.real(cursor.activityAt.timeIntervalSinceReferenceDate), .text(cursor.sessionID.uuidString)]
        }
        let scope = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let candidates: [SessionCatalogRecord] = try decodedRows(
            "SELECT record FROM sessions\(scope) ORDER BY activity DESC, id DESC LIMIT ?",
            bindings + [.integer(Int64(limit + 1))]
        )
        let records = Array(candidates.prefix(limit))
        let nextCursor = candidates.count > limit ? records.last.map {
            SessionCatalogCursor(generation: generation, workspaceID: workspaceID, activityAt: $0.activityAt, sessionID: $0.id)
        } : nil
        return SessionCatalogPage(generation: generation, coverage: coverage, totalKnown: total, records: records, nextCursor: nextCursor)
    }

    private func decodedRows<T: Decodable>(_ sql: String, _ bindings: [SessionCatalogDatabase.Binding] = []) throws -> [T] {
        try database.rows(sql, bindings) {
            do { return try decoder.decode(T.self, from: SessionCatalogDatabase.data($0)) }
            catch { throw SessionCatalogError.corruptSchema }
        }
    }

    /// Background classification changes no session facts and cannot invalidate discovery cursors.
    func classify(path: String, signature: String, classification: String, reconciliationGeneration: Int64) throws {
        try database.execute(
            "INSERT INTO classifications VALUES (?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET signature = excluded.signature, classification = excluded.classification, reconciliation_generation = excluded.reconciliation_generation WHERE classifications.reconciliation_generation <= excluded.reconciliation_generation",
            [.text(path), .text(signature), .text(classification), .integer(reconciliationGeneration)]
        )
    }

    func classification(path: String, signature: String) throws -> String? {
        try database.rows("SELECT classification FROM classifications WHERE path = ? AND signature = ?", [.text(path), .text(signature)]) { try SessionCatalogDatabase.string($0) }.first
    }

    func reconciliation() throws -> SessionCatalogReconciliation? {
        try decodedRows("SELECT record FROM reconciliation WHERE singleton = 1").first
    }

    func saveReconciliation(_ progress: SessionCatalogReconciliation, expectedGeneration: Int64?) throws {
        try transaction {
            let previous = try reconciliation()
            guard previous?.generation == expectedGeneration else { throw SessionCatalogError.staleGeneration }
            if let previous {
                guard progress.generation >= previous.generation,
                      progress.generation != previous.generation || (progress.processed >= previous.processed && !(previous.finished && !progress.finished))
                else { throw SessionCatalogError.staleGeneration }
            }
            try database.execute(
                "INSERT INTO reconciliation VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET generation = excluded.generation, record = excluded.record",
                [.integer(progress.generation), .bytes(encoder.encode(progress))]
            )
        }
    }

    /// Beginning/resuming a job is an indexed metadata operation, not storage discovery. A completed
    /// job is returned untouched unless an explicit drift-repair event requests a new generation.
    func beginReconciliation(restart: Bool) throws -> SessionCatalogReconciliation {
        try transaction {
            let previous = try reconciliation()
            if let previous, !restart { return previous }
            let progress = SessionCatalogReconciliation(generation: (previous?.generation ?? 0) + 1, phase: "registry")
            let coverage = try database.rows("SELECT coverage FROM catalog_state WHERE singleton = 1") { try SessionCatalogDatabase.string($0) }.first
            guard let coverage else { throw SessionCatalogError.corruptSchema }
            if coverage != SessionCatalogCoverage.pending.rawValue {
                try database.execute("UPDATE catalog_state SET coverage = 'pending', generation = generation + 1 WHERE singleton = 1")
            }
            try writeReconciliation(progress)
            return progress
        }
    }

    /// Imports and the worker cursor advance in one transaction. Disk-derived migration facts may
    /// only fill absent identities: a concurrent owner write or tombstone always wins. There is no
    /// general 'upsert whatever was on disk' path and no authorization is inferred from an import.
    func applyReconciliationBatch(
        _ batch: SessionCatalogReconciliationBatch,
        expected: SessionCatalogReconciliation
    ) throws -> SessionCatalogReconciliationReceipt {
        guard !expected.finished, batch.next.generation == expected.generation,
              batch.itemCount <= SessionCatalogReconciliationBatch.maximumItems,
              batch.next.processed >= expected.processed,
              batch.next.processed - expected.processed <= Int64(SessionCatalogReconciliationBatch.maximumItems),
              batch.next.failed >= 0, batch.next.failed <= batch.next.processed,
              !batch.next.phase.isEmpty, batch.next.phase.utf8.count <= 128,
              (batch.next.cursor?.utf8.count ?? 0) <= 16 * 1024,
              batch.next != expected
        else { throw SessionCatalogError.invalidRecord }
        try Task.checkCancellation()
        return try transaction {
            guard try reconciliation() == expected else { throw SessionCatalogError.staleGeneration }
            let generation = try currentGeneration() + 1
            var importedWorkspaceIDs: Set<UUID> = []
            var importedSessions = 0
            var skipped = 0
            for workspace in batch.workspaces {
                try Task.checkCancellation()
                if try importIdentityIsAbsent(kind: "workspace", table: "workspaces", id: workspace.id) {
                    try apply(.workspace(workspace, expected: .absent), generation: generation)
                    importedWorkspaceIDs.insert(workspace.id)
                } else { skipped += 1 }
            }
            for candidate in batch.sessions {
                try Task.checkCancellation()
                let session = candidate.record
                guard try importIdentityIsAbsent(kind: "session", table: "sessions", id: session.id) else {
                    skipped += 1
                    continue
                }
                guard try database.integer("SELECT revision FROM workspaces WHERE id = ?", [.text(session.workspaceID.uuidString)]) != nil else {
                    guard try database.integer("SELECT generation FROM tombstones WHERE kind = 'workspace' AND id = ?", [.text(session.workspaceID.uuidString)]) != nil else {
                        throw SessionCatalogError.unknownWorkspace
                    }
                    skipped += 1
                    continue
                }
                let workspaceRevision = try database.integer("SELECT revision FROM workspaces WHERE id = ?", [.text(session.workspaceID.uuidString)])
                let matchesWorkspace: Bool = switch candidate.expectedWorkspaceRevision {
                case .absent: importedWorkspaceIDs.contains(session.workspaceID)
                case let .revision(value): workspaceRevision == value
                }
                guard matchesWorkspace else { skipped += 1
                    continue
                }
                try apply(.session(session, expected: .absent), generation: generation)
                importedSessions += 1
            }
            for directory in batch.directories {
                guard !directory.path.isEmpty, directory.path.utf8.count <= 16 * 1024,
                      directory.signature.utf8.count <= 1024, directory.classification.utf8.count <= 128
                else { throw SessionCatalogError.invalidRecord }
                try classify(path: directory.path, signature: directory.signature, classification: directory.classification, reconciliationGeneration: expected.generation)
            }
            var appliedCoverage = 0
            for claim in batch.coverage {
                let current = try workspace(id: claim.workspaceID)
                let matches: Bool = switch claim.expectedRevision {
                case .absent: importedWorkspaceIDs.contains(claim.workspaceID)
                case let .revision(value): current?.revision == value
                }
                guard matches, current != nil else {
                    skipped += 1
                    continue
                }
                try apply(.coverage(workspaceID: claim.workspaceID, state: claim.state), generation: generation)
                appliedCoverage += 1
            }
            if batch.next.finished {
                let incomplete = try database.integer("SELECT 1 FROM workspaces WHERE coverage != 'complete' LIMIT 1") != nil
                try apply(.coverage(workspaceID: nil, state: batch.next.failed == 0 && !incomplete ? .complete : .degraded), generation: generation)
            }
            let changedFacts = importedWorkspaceIDs.count + importedSessions > 0 || appliedCoverage > 0 || batch.next.finished
            if changedFacts {
                try database.execute("UPDATE catalog_state SET generation = ? WHERE singleton = 1", [.integer(generation)])
            }
            try writeReconciliation(batch.next)
            return SessionCatalogReconciliationReceipt(
                catalogGeneration: changedFacts ? generation : generation - 1,
                importedWorkspaces: importedWorkspaceIDs.count, importedSessions: importedSessions,
                skippedOwnerFacts: skipped, progress: batch.next
            )
        }
    }

    private func importIdentityIsAbsent(kind: String, table: String, id: UUID) throws -> Bool {
        if try database.integer("SELECT generation FROM tombstones WHERE kind = ? AND id = ?", [.text(kind), .text(id.uuidString)]) != nil { return false }
        return try database.integer("SELECT revision FROM \(table) WHERE id = ?", [.text(id.uuidString)]) == nil
    }

    private func writeReconciliation(_ progress: SessionCatalogReconciliation) throws {
        try database.execute(
            "INSERT INTO reconciliation VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET generation = excluded.generation, record = excluded.record",
            [.integer(progress.generation), .bytes(encoder.encode(progress))]
        )
    }

    func readCounters() -> SessionCatalogReadCounters {
        database.counters
    }

    func resetReadCounters() {
        database.resetCounters()
    }
}
