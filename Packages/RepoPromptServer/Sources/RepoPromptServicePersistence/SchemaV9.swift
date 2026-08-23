import Foundation
import RepoPromptRuntimeModel

enum SchemaV9 {
    static let version = 9
    static let transformationID = "private-pilot-operator-security-backup-receipts-v1"
    static let canonicalDigest = "sha256:083e672380e8dd2b65fff9a7036e5b9b6ab635950271427d449ecbaeb0e13d42"

    static let statements: [String] = [
        "CREATE TABLE operator_auth_throttle_buckets(bucket_key TEXT PRIMARY KEY,scope TEXT NOT NULL CHECK(scope IN ('setup','login','offlineReset')),client_identity_digest TEXT NOT NULL,username_digest TEXT NOT NULL,window_started_at REAL NOT NULL,attempt_count INTEGER NOT NULL,consecutive_failures INTEGER NOT NULL,blocked_until REAL,updated_at REAL NOT NULL)",
        "CREATE INDEX operator_auth_throttle_blocked ON operator_auth_throttle_buckets(scope,blocked_until,updated_at)",
        "CREATE TABLE operator_security_audit(audit_id TEXT PRIMARY KEY,operation TEXT NOT NULL,outcome TEXT NOT NULL,actor TEXT NOT NULL,channel TEXT NOT NULL,client_identity_digest TEXT,correlation_id TEXT NOT NULL,detail_code TEXT,created_at REAL NOT NULL)",
        "CREATE INDEX operator_security_audit_time ON operator_security_audit(created_at,audit_id)",
        "CREATE INDEX operator_security_audit_operation_time ON operator_security_audit(operation,created_at)",
        "CREATE TABLE operator_session_metadata(session_id TEXT PRIMARY KEY,username TEXT NOT NULL,issued_at REAL NOT NULL,last_seen_at REAL NOT NULL,revoked_at REAL,revocation_reason TEXT,client_identity_digest TEXT,correlation_id TEXT NOT NULL)",
        "CREATE INDEX operator_session_metadata_username_state ON operator_session_metadata(username,revoked_at,issued_at)",
        "CREATE TABLE maintenance_receipts(receipt_id TEXT PRIMARY KEY,operation TEXT NOT NULL CHECK(operation IN ('backupCreate','backupVerify','restorePrepare','migrationVerify')),outcome TEXT NOT NULL,archive_sha256 TEXT NOT NULL,manifest_sha256 TEXT NOT NULL,source_store_id TEXT NOT NULL,source_schema_version INTEGER NOT NULL,source_global_sequence INTEGER NOT NULL,verifier_fingerprint TEXT,recipient_fingerprints_json TEXT NOT NULL,sidecar_sha256 TEXT NOT NULL,tool_version TEXT NOT NULL,tool_digest TEXT NOT NULL,correlation_id TEXT NOT NULL,created_at REAL NOT NULL)",
        "CREATE INDEX maintenance_receipts_operation_time ON maintenance_receipts(operation,created_at)",
        "CREATE INDEX maintenance_receipts_archive ON maintenance_receipts(archive_sha256,operation,created_at)",
    ]

    static var definition: MigrationDefinition {
        MigrationDefinition(
            version: version,
            transformationID: transformationID,
            statements: statements,
            transformationSteps: [
                "backfill-active-operator-session-metadata",
                "set-service-metadata-schema-version:9",
            ]
        )
    }

    static func validate(using database: SQLiteDatabaseExecutor) async throws {
        let required = Set([
            "operator_auth_throttle_buckets",
            "operator_security_audit",
            "operator_session_metadata",
            "maintenance_receipts",
        ])
        let rows = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('operator_auth_throttle_buckets','operator_security_audit','operator_session_metadata','maintenance_receipts')"
        )
        guard Set(rows.compactMap { $0.column("name")?.string }) == required else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema v9 shape is incomplete", retryable: false)
        }
    }
}
