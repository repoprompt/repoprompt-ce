import CryptoKit
import Darwin
import Foundation
import RepoPromptC

/// Short rollback-journal transactions only. No connection/transaction/lock survives a method call.
/// Bulk saves run off-main; a terminal scope decision may synchronously attempt one bounded write.
/// No UI, provider, filesystem effect or user prompt runs
/// inside a transaction. This store records continuity and cannot authorize live actions.
package final class OverseerContinuityStore: @unchecked Sendable {
    package let databaseURL: URL
    package let profile: String
    /// The three adapters share this process-local ordering, including first schema creation.
    /// Only short database operations run under it; external processes still use SQLite locking.
    private static let accessLock = NSRecursiveLock()

    package init(databaseURL: URL, profile: String) {
        self.databaseURL = databaseURL
        self.profile = profile
    }

    /// Read-only retention projection, never an authorization input. Unknown schemas/profiles
    /// fail rather than silently returning no backing and allowing a snapshot to displace it.
    package struct BackingIdentities {
        package var sessions: Set<String> = []
        package var workspaces: Set<String> = []
        package init() {}
    }

    package func readOnlyBackingIdentities() throws -> BackingIdentities {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        let handle = try FileHandle(forReadingFrom: databaseURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8) else { throw OverseerContinuityError.invalidRecord }
        // A read-only WAL connection may write shared-memory read marks. Never open it here.
        guard header[18] != 2 else { throw OverseerContinuityError.unsupportedEngineSettings }
        let db = try SessionCatalogDatabase(url: databaseURL, readOnly: true)
        try db.execute("PRAGMA busy_timeout = 250")
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        let version = try Int(db.integer("PRAGMA user_version") ?? 0)
        guard version == 1 else { throw OverseerContinuityError.incompatibleSchema(version) }
        guard try db.rows("SELECT profile FROM profile_state WHERE singleton=1", map: { try SessionCatalogDatabase.string($0) }).first == profile else {
            throw OverseerContinuityError.profileMismatch
        }
        var result = BackingIdentities()
        _ = try db.rows("SELECT owner_id,anchor_id,workspace_id FROM continuity_rows WHERE terminal=0") { row in
            for column in [Int32(0), 1] {
                if let text = try? SessionCatalogDatabase.string(row, column: column), let id = UUID(uuidString: text) {
                    result.sessions.insert(id.uuidString)
                }
            }
            if let text = try? SessionCatalogDatabase.string(row, column: 2), let id = UUID(uuidString: text) {
                result.workspaces.insert(id.uuidString)
            }
        }
        return result
    }

    private func acquireAccess() throws {
        guard Self.accessLock.lock(before: Date().addingTimeInterval(0.25)) else { throw OverseerContinuityError.writerBusy }
    }

    private func connection() throws -> SessionCatalogDatabase {
        guard databaseURL.isFileURL, !profile.isEmpty else { throw OverseerContinuityError.unsafeLocation }
        let parent = databaseURL.deletingLastPathComponent()
        var ancestor = parent
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink,
               !["/var", "/tmp"].contains(ancestor.path)
            {
                throw OverseerContinuityError.unsafeLocation
            }
            ancestor.deleteLastPathComponent()
        }
        // A dedicated private directory is required. Resolve OS aliases (/var -> /private/var),
        // never an app-state symlink. Do not chmod someone else's existing directory or file.
        if FileManager.default.fileExists(atPath: parent.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
            else { throw OverseerContinuityError.unsafeLocation }
        } else {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var filesystem = statfs()
        guard statfs(parent.path, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw OverseerContinuityError.unsafeLocation
        }
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1
            else { throw OverseerContinuityError.unsafeLocation }
            // Reject a future format without changing journal mode. Do not use a read-only SQLite
            // preflight here: it cannot recover a hot rollback journal after process death.
            let handle = try FileHandle(forReadingFrom: databaseURL)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 100) ?? Data()
            if !header.isEmpty {
                guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8) else { throw OverseerContinuityError.invalidRecord }
                let version = header[60 ..< 64].reduce(0) { ($0 << 8) | Int($1) }
                guard version <= 1 else { throw OverseerContinuityError.incompatibleSchema(version) }
            }
        }
        let db = try SessionCatalogDatabase(url: databaseURL)
        let version = try Int(db.integer("PRAGMA user_version") ?? 0)
        guard version <= 1 else { throw OverseerContinuityError.incompatibleSchema(version) }
        if version == 1 {
            guard try db.rows("SELECT profile FROM profile_state WHERE singleton=1", map: { try SessionCatalogDatabase.string($0) }).first == profile else {
                throw OverseerContinuityError.profileMismatch
            }
        }
        try db.execute("PRAGMA busy_timeout = 250")
        // Do not inherit WAL from another connection or rely on an Apple version string as proof
        // of the upstream WAL-reset fix. Verify every effective setting, not just PRAGMA submission.
        let journal = try db.rows("PRAGMA journal_mode = DELETE") { try SessionCatalogDatabase.string($0) }.first
        try db.execute("PRAGMA synchronous = EXTRA")
        try db.execute("PRAGMA fullfsync = ON")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA trusted_schema = OFF")
        guard journal == "delete", try db.integer("PRAGMA synchronous") == 3,
              try db.integer("PRAGMA fullfsync") == 1, try db.integer("PRAGMA foreign_keys") == 1,
              try db.rows("PRAGMA locking_mode", map: { try SessionCatalogDatabase.string($0) }).first == "normal"
        else { throw OverseerContinuityError.unsupportedEngineSettings }
        if version == 0 {
            try transaction(db) {
                let current = try db.integer("PRAGMA user_version") ?? 0
                if current == 0 {
                    guard try db.integer("SELECT count(*) FROM sqlite_master WHERE type='table'") == 0 else { throw OverseerContinuityError.invalidRecord }
                    for statement in Self.schema {
                        try db.execute(statement)
                    }
                    try db.execute("INSERT INTO profile_state VALUES (1, ?, ?, 0)", [.text(profile), .text(UUID().uuidString)])
                    try db.execute("PRAGMA user_version = 1")
                }
            }
        }
        guard try db.rows("SELECT profile FROM profile_state WHERE singleton=1", map: { try SessionCatalogDatabase.string($0) }).first == profile else {
            throw OverseerContinuityError.profileMismatch
        }
        return db
    }

    private static let schema = [
        "CREATE TABLE profile_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), profile TEXT NOT NULL, epoch TEXT NOT NULL, revision INTEGER NOT NULL) STRICT",
        "CREATE TABLE continuity_rows (kind TEXT NOT NULL CHECK(kind IN ('scope','link','worktree')), id TEXT NOT NULL, parent_id TEXT, owner_id TEXT, anchor_id TEXT, workspace_id TEXT, capabilities TEXT NOT NULL, expires REAL, payload BLOB NOT NULL, terminal INTEGER NOT NULL CHECK(terminal IN (0,1)), revision INTEGER NOT NULL, PRIMARY KEY(kind,id)) STRICT",
        "CREATE INDEX scope_parent ON continuity_rows(kind,parent_id)",
        "CREATE TABLE deleted_sessions (id TEXT PRIMARY KEY, revision INTEGER NOT NULL) STRICT",
        "CREATE TABLE operations (id TEXT PRIMARY KEY, origin TEXT NOT NULL, digest TEXT NOT NULL, revision INTEGER NOT NULL, receipt BLOB NOT NULL) STRICT",
        "CREATE TABLE migration_imports (id TEXT PRIMARY KEY, path TEXT NOT NULL, digest TEXT NOT NULL, bytes BLOB NOT NULL, reason TEXT NOT NULL, operation_id TEXT NOT NULL REFERENCES operations(id)) STRICT",
        "CREATE TABLE migration_rows (source_id TEXT NOT NULL REFERENCES migration_imports(id), ordinal INTEGER NOT NULL, candidate BLOB, raw BLOB NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY(source_id,ordinal)) STRICT"
    ]

    private func transaction<T>(_ db: SessionCatalogDatabase, _ body: () throws -> T) throws -> T {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    package func engineSettings() throws -> [String: String] {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        let db = try connection()
        return try [
            "journal_mode": db.rows("PRAGMA journal_mode") { try SessionCatalogDatabase.string($0) }.first ?? "",
            "synchronous": String(db.integer("PRAGMA synchronous") ?? -1),
            "fullfsync": String(db.integer("PRAGMA fullfsync") ?? -1),
            "foreign_keys": String(db.integer("PRAGMA foreign_keys") ?? -1)
        ]
    }

    package func rows(kind: OverseerContinuityKind) throws -> [OverseerContinuityRow] {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        return try readRows(connection(), kind: kind)
    }

    private func readRows(_ db: SessionCatalogDatabase, kind: OverseerContinuityKind) throws -> [OverseerContinuityRow] {
        try db.rows("SELECT id,parent_id,owner_id,anchor_id,workspace_id,capabilities,expires,payload,terminal,revision FROM continuity_rows WHERE kind=? ORDER BY id", [.text(kind.rawValue)]) { statement in
            func optional(_ index: Int32) -> String? {
                try? SessionCatalogDatabase.string(statement, column: index)
            }
            let capabilities = try JSONDecoder().decode([String].self, from: Data(SessionCatalogDatabase.string(statement, column: 5).utf8))
            let expiry = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            return try OverseerContinuityRow(
                kind: kind,
                id: SessionCatalogDatabase.string(statement),
                parentID: optional(1),
                ownerID: optional(2),
                anchorID: optional(3),
                workspaceID: optional(4),
                capabilities: capabilities,
                expiresAt: expiry,
                payload: SessionCatalogDatabase.data(statement, column: 7),
                terminal: SessionCatalogDatabase.integerValue(statement, column: 8) != 0,
                revision: SessionCatalogDatabase.integerValue(statement, column: 9)
            )
        }
    }

    package func receipt(operationID: UUID) throws -> OverseerContinuityReceipt? {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        let db = try connection()
        return try db.rows("SELECT receipt FROM operations WHERE id=?", [.text(operationID.uuidString)]) {
            try JSONDecoder().decode(OverseerContinuityReceipt.self, from: SessionCatalogDatabase.data($0))
        }.first
    }

    package func commit(operationID: UUID, origin: String, mutations: [OverseerContinuityMutation]) throws -> OverseerContinuityReceipt {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        guard !mutations.isEmpty else { throw OverseerContinuityError.invalidTransition }
        let db = try connection()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = try Self.digest(encoder.encode(mutations))
        return try transaction(db) {
            if let previous = try db.rows("SELECT origin,digest,receipt FROM operations WHERE id=?", [.text(operationID.uuidString)], map: {
                try (SessionCatalogDatabase.string($0), SessionCatalogDatabase.string($0, column: 1), SessionCatalogDatabase.data($0, column: 2))
            }).first {
                guard previous.0 == origin, previous.1 == digest else { throw OverseerContinuityError.operationConflict }
                var receipt = try JSONDecoder().decode(OverseerContinuityReceipt.self, from: previous.2)
                receipt.replayed = true
                return receipt
            }
            let revision = try nextRevision(db)
            var affected: [String] = []
            for mutation in mutations {
                affected += try apply(mutation, revision: revision, db: db)
            }
            let receipt = OverseerContinuityReceipt(operationID: operationID, revision: revision, affectedIDs: affected, replayed: false)
            try db.execute("INSERT INTO operations VALUES (?,?,?,?,?)", [.text(operationID.uuidString), .text(origin), .text(digest), .integer(revision), .bytes(encoder.encode(receipt))])
            return receipt
        }
    }

    private func nextRevision(_ db: SessionCatalogDatabase) throws -> Int64 {
        try db.execute("UPDATE profile_state SET revision=revision+1 WHERE singleton=1")
        guard let revision = try db.integer("SELECT revision FROM profile_state WHERE singleton=1") else { throw OverseerContinuityError.invalidRecord }
        return revision
    }

    private func apply(_ mutation: OverseerContinuityMutation, revision: Int64, db: SessionCatalogDatabase) throws -> [String] {
        switch mutation {
        case let .grant(row):
            guard row.kind == .scope, !row.terminal else { throw OverseerContinuityError.invalidRecord }
            if let terminal = try db.integer("SELECT terminal FROM continuity_rows WHERE kind='scope' AND id=?", [.text(row.id)]) {
                guard terminal == 0 else { throw OverseerContinuityError.terminalIdentity }
                let previous = try db.rows("SELECT payload FROM continuity_rows WHERE kind='scope' AND id=?", [.text(row.id)]) { try SessionCatalogDatabase.data($0) }.first
                guard previous == row.payload else { throw OverseerContinuityError.operationConflict }
                return []
            }
            for anchor in [row.ownerID, row.anchorID].compactMap(\.self) {
                guard try db.integer("SELECT 1 FROM deleted_sessions WHERE id=?", [.text(anchor)]) == nil else { throw OverseerContinuityError.terminalIdentity }
            }
            if let parent = row.parentID {
                guard try db.integer("SELECT terminal FROM continuity_rows WHERE kind='scope' AND id=?", [.text(parent)]) == 0 else { throw OverseerContinuityError.parentUnavailable }
            }
            try put(row, revision: revision, db: db)
            return [row.id]
        case let .revokeScope(id):
            let ids = try db.rows("WITH RECURSIVE descendants(id) AS (VALUES (?) UNION SELECT r.id FROM continuity_rows r JOIN descendants d ON r.parent_id=d.id WHERE r.kind='scope') SELECT id FROM descendants", [.text(id)]) { try SessionCatalogDatabase.string($0) }
            for id in ids {
                try db.execute("INSERT INTO continuity_rows(kind,id,capabilities,payload,terminal,revision) VALUES ('scope',?,'[]',?,1,?) ON CONFLICT(kind,id) DO UPDATE SET terminal=1,revision=excluded.revision", [.text(id), .bytes(Data()), .integer(revision)])
            }
            return ids
        case let .deletedSession(id):
            try db.execute("INSERT INTO deleted_sessions VALUES (?,?) ON CONFLICT(id) DO NOTHING", [.text(id), .integer(revision)])
            let roots = try db.rows("SELECT id FROM continuity_rows WHERE kind='scope' AND (owner_id=? OR anchor_id=?)", [.text(id), .text(id)]) { try SessionCatalogDatabase.string($0) }
            var affected: [String] = []
            for root in roots {
                affected += try apply(.revokeScope(root), revision: revision, db: db)
            }
            try db.execute("UPDATE continuity_rows SET terminal=1,revision=? WHERE kind='link' AND (owner_id=? OR anchor_id=?)", [.integer(revision), .text(id), .text(id)])
            return affected
        case let .put(row, expected):
            guard row.kind != .scope else { throw OverseerContinuityError.invalidRecord }
            if row.kind == .link, !row.terminal {
                for endpoint in [row.ownerID, row.anchorID].compactMap(\.self) {
                    guard try db.integer("SELECT 1 FROM deleted_sessions WHERE id=?", [.text(endpoint)]) == nil else { throw OverseerContinuityError.terminalIdentity }
                }
            }
            try checkRevision(db, kind: row.kind, id: row.id, expected: expected)
            try put(row, revision: revision, db: db)
            return [row.id]
        case let .remove(kind, id, expected):
            guard kind != .scope else { throw OverseerContinuityError.invalidRecord }
            // Session deletion may already have terminalized this link in its own transaction.
            // A stale remove can acknowledge that terminal state, never erase a newer live link.
            let terminal = try db.integer("SELECT terminal FROM continuity_rows WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id)])
            if kind != .link || terminal != 1 {
                try checkRevision(db, kind: kind, id: id, expected: expected)
            }
            try db.execute("UPDATE continuity_rows SET terminal=1, revision=? WHERE kind=? AND id=?", [.integer(revision), .text(kind.rawValue), .text(id)])
            return [id]
        }
    }

    private func checkRevision(_ db: SessionCatalogDatabase, kind: OverseerContinuityKind, id: String, expected: Int64?) throws {
        guard try db.integer("SELECT revision FROM continuity_rows WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id)]) == expected else { throw OverseerContinuityError.revisionConflict }
    }

    private func put(_ row: OverseerContinuityRow, revision: Int64, db: SessionCatalogDatabase) throws {
        guard !row.id.isEmpty, row.id.utf8.count <= 4096, row.payload.count <= 1024 * 1024 else { throw OverseerContinuityError.invalidTransition }
        let capabilities = try String(decoding: JSONEncoder().encode(row.capabilities.sorted()), as: UTF8.self)
        try db.execute("INSERT INTO continuity_rows VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET parent_id=excluded.parent_id,owner_id=excluded.owner_id,anchor_id=excluded.anchor_id,workspace_id=excluded.workspace_id,capabilities=excluded.capabilities,expires=excluded.expires,payload=excluded.payload,terminal=excluded.terminal,revision=excluded.revision", [
            .text(row.kind.rawValue), .text(row.id), row.parentID.map { .text($0) } ?? .null,
            row.ownerID.map { .text($0) } ?? .null, row.anchorID.map { .text($0) } ?? .null,
            row.workspaceID.map { .text($0) } ?? .null, .text(capabilities), row.expiresAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .bytes(row.payload), .integer(row.terminal ? 1 : 0), .integer(revision)
        ])
    }

    /// Preserve exact source bytes and every parsed/rejected row, without ever changing the source.
    /// Archiving confers no authority. A source digest is imported at most once, even after a crash.
    package func archive(_ source: OverseerLegacySource, rows: [OverseerLegacyRow]) throws {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        let db = try connection()
        try transaction(db) {
            if try db.integer("SELECT 1 FROM migration_imports WHERE id=?", [.text(source.id)]) != nil { return }
            let revision = try nextRevision(db)
            let operation = UUID()
            let receipt = OverseerContinuityReceipt(operationID: operation, revision: revision, affectedIDs: [source.id], replayed: false)
            try db.execute("INSERT INTO operations VALUES (?,?,?,?,?)", [.text(operation.uuidString), .text("legacy-preservation"), .text(source.digest), .integer(revision), .bytes(JSONEncoder().encode(receipt))])
            try db.execute("INSERT INTO migration_imports VALUES (?,?,?,?,?,?)", [.text(source.id), .text(source.path), .text(source.digest), .bytes(source.bytes), .text(source.reason), .text(operation.uuidString)])
            for row in rows {
                try db.execute("INSERT INTO migration_rows VALUES (?,?,?,?,?)", [.text(source.id), .integer(Int64(row.ordinal)), row.mutation.map { try .bytes(JSONEncoder().encode($0)) } ?? .null, .bytes(row.raw), .text(row.outcome)])
            }
        }
    }

    package func legacySources() throws -> [OverseerLegacySource] {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        return try connection().rows("SELECT id,path,digest,bytes,reason FROM migration_imports ORDER BY id") {
            try OverseerLegacySource(id: SessionCatalogDatabase.string($0), path: SessionCatalogDatabase.string($0, column: 1), digest: SessionCatalogDatabase.string($0, column: 2), bytes: SessionCatalogDatabase.data($0, column: 3), reason: SessionCatalogDatabase.string($0, column: 4))
        }
    }

    /// The app calls this only after an actual user recovery choice or a proven same-profile
    /// legacy migration. Existing destination edits and terminal IDs always win.
    package func activateLegacy(sourceID: String, operationID: UUID, origin: String) throws -> OverseerContinuityReceipt {
        try acquireAccess()
        defer { Self.accessLock.unlock() }
        let db = try connection()
        return try transaction(db) {
            if let previous = try db.rows("SELECT receipt FROM operations WHERE id=? AND origin=? AND digest=?", [.text(operationID.uuidString), .text(origin), .text(sourceID)], map: { try SessionCatalogDatabase.data($0) }).first {
                var receipt = try JSONDecoder().decode(OverseerContinuityReceipt.self, from: previous)
                receipt.replayed = true
                return receipt
            }
            guard try db.integer("SELECT 1 FROM operations WHERE id=?", [.text(operationID.uuidString)]) == nil else { throw OverseerContinuityError.operationConflict }
            let candidates = try db.rows("SELECT ordinal,candidate FROM migration_rows WHERE source_id=? AND candidate IS NOT NULL AND outcome='review' ORDER BY ordinal", [.text(sourceID)]) {
                try (SessionCatalogDatabase.integerValue($0, column: 0), JSONDecoder().decode(OverseerContinuityMutation.self, from: SessionCatalogDatabase.data($0, column: 1)))
            }
            let revision = try nextRevision(db)
            var affected: [String] = []
            for (ordinal, mutation) in candidates {
                var outcome = "activated"
                // Import only absent identities, not upserts from old sources over newer facts.
                let kind: OverseerContinuityKind
                let id: String
                switch mutation {
                case let .grant(row), let .put(row, _): kind = row.kind
                    id = row.id
                case let .revokeScope(value): kind = .scope
                    id = value
                case .remove, .deletedSession: throw OverseerContinuityError.invalidRecord
                }
                if try db.integer("SELECT 1 FROM continuity_rows WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id)]) != nil {
                    outcome = "destination_wins"
                } else {
                    do { affected += try apply(mutation, revision: revision, db: db) }
                    catch let error as OverseerContinuityError { outcome = "rejected_\(error)" }
                }
                try db.execute("UPDATE migration_rows SET outcome=? WHERE source_id=? AND ordinal=?", [.text(outcome), .text(sourceID), .integer(ordinal)])
            }
            let receipt = OverseerContinuityReceipt(operationID: operationID, revision: revision, affectedIDs: affected, replayed: false)
            try db.execute("INSERT INTO operations VALUES (?,?,?,?,?)", [.text(operationID.uuidString), .text(origin), .text(sourceID), .integer(revision), .bytes(JSONEncoder().encode(receipt))])
            return receipt
        }
    }

    package static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
