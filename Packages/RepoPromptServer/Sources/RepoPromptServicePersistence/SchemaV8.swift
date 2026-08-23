import Foundation
import RepoPromptRuntimeModel

enum SchemaV8 {
    static let version = 8
    static let transformationID = "authority-transitions-provider-dedupe-event-outbox-v1"
    static let canonicalDigest = "sha256:f7c197d8aa2342679783be7e217571ce20985328a975b8568c0ee8ca9f5eca2a"

    static let statements: [String] = [
        "CREATE TABLE authority_transitions(transition_id TEXT PRIMARY KEY,actor_id TEXT NOT NULL,operation TEXT NOT NULL,idempotency_key TEXT NOT NULL,request_digest TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('start','cancel','complete','fail','interrupt')),session_id TEXT NOT NULL REFERENCES sessions(session_id),run_id TEXT NOT NULL REFERENCES runs(run_id),expected_session_revision INTEGER NOT NULL,expected_generation INTEGER NOT NULL,expected_turn_epoch INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN ('prepared','effectAcknowledged','finalized','reconciliationRequired')),requested_terminal_state TEXT,side_effect_evidence_json TEXT,diagnostic_code TEXT,response_body TEXT,response_status INTEGER,created_at REAL NOT NULL,updated_at REAL NOT NULL,finalized_at REAL,UNIQUE(actor_id,operation,idempotency_key))",
        "CREATE INDEX authority_transitions_state_updated ON authority_transitions(state,updated_at)",
        "CREATE INDEX authority_transitions_run_updated ON authority_transitions(run_id,updated_at)",
        "CREATE UNIQUE INDEX authority_transitions_one_terminal_per_run ON authority_transitions(run_id) WHERE state='finalized' AND kind IN ('cancel','complete','fail','interrupt')",
        "CREATE TABLE provider_event_receipts(run_id TEXT NOT NULL REFERENCES runs(run_id),provider_event_id TEXT NOT NULL,payload_digest TEXT NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,connection_generation INTEGER NOT NULL,provider_sequence INTEGER NOT NULL,event_kind TEXT NOT NULL,first_global_sequence INTEGER,last_global_sequence INTEGER,processed_at REAL NOT NULL,PRIMARY KEY(run_id,connection_generation,provider_event_id),UNIQUE(run_id,connection_generation,provider_sequence))",
        "CREATE INDEX provider_event_receipts_run_processed ON provider_event_receipts(run_id,processed_at)",
        "CREATE TABLE event_outbox(store_id TEXT NOT NULL,global_sequence INTEGER PRIMARY KEY REFERENCES events(global_sequence) ON DELETE CASCADE,envelope_json TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('pending','dispatched')),dispatch_attempt_count INTEGER NOT NULL DEFAULT 0,last_diagnostic_code TEXT,created_at REAL NOT NULL,dispatched_at REAL,UNIQUE(store_id,global_sequence))",
        "CREATE INDEX event_outbox_state_sequence ON event_outbox(state,global_sequence)",
        "CREATE TABLE idempotency_tombstones(actor_id TEXT NOT NULL,operation TEXT NOT NULL,idempotency_key TEXT NOT NULL,request_digest TEXT NOT NULL,terminal_identity TEXT NOT NULL,response_expires_at REAL,created_at REAL NOT NULL,updated_at REAL NOT NULL,PRIMARY KEY(actor_id,operation,idempotency_key))",
    ]

    static var definition: MigrationDefinition {
        MigrationDefinition(
            version: version,
            transformationID: transformationID,
            statements: statements,
            transformationSteps: [
                "backfill-existing-events-as-dispatched-from-canonical-envelope",
                "set-service-metadata-schema-version:8",
            ]
        )
    }

    static func validate(using database: SQLiteDatabaseExecutor) async throws {
        let required = Set([
            "authority_transitions",
            "provider_event_receipts",
            "event_outbox",
            "idempotency_tombstones",
        ])
        let rows = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('authority_transitions','provider_event_receipts','event_outbox','idempotency_tombstones')"
        )
        guard Set(rows.compactMap { $0.column("name")?.string }) == required else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v8 shape is incomplete", retryable: false)
        }
        let uncovered = try await database.query(
            "SELECT COUNT(*) AS value FROM events e LEFT JOIN event_outbox o ON o.global_sequence=e.global_sequence WHERE o.global_sequence IS NULL"
        ).first?.column("value")?.integer ?? 0
        guard uncovered == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v8 contains events without outbox rows", retryable: false)
        }
    }
}
