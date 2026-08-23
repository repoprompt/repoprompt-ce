enum SchemaV4 {
    static let version = 4
    /// Legacy prototype ledger alias. Never rewrite an existing row.
    static let digest = "repoprompt-service-schema-v4-provider-connections-audit"
    static let transformationID = "provider-connections-audit-v1"
    static let legacyCanonicalDigest = "sha256:39df24eedc3e681edad42e18b05bcfdadf21e243c9599cd3e10f012d72d45f12"
    static let canonicalDigest = "sha256:29bfb3ab7314f382fb7eba0ad49577a730a95563dfda8fb01a0c501c126815fc"
    static var definition: MigrationDefinition {
        MigrationDefinition(version: version, transformationID: transformationID, statements: statements, transformationSteps: ["set-service-metadata-schema-version:4"])
    }

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS provider_connections(provider_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,connection_id TEXT UNIQUE NOT NULL,authentication_method TEXT NOT NULL,state TEXT NOT NULL,account_label TEXT,expires_at REAL,last_tested_at REAL,test_state TEXT NOT NULL,detail TEXT,key_helper_configured INTEGER NOT NULL,workload_identity_configured INTEGER NOT NULL,credential_reference TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_connection_audit(audit_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,provider_id TEXT NOT NULL,connection_id TEXT,operation TEXT NOT NULL,actor_id TEXT NOT NULL,actor_label TEXT NOT NULL,channel TEXT NOT NULL,authentication_method TEXT,result TEXT NOT NULL,created_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS provider_connection_audit_provider_time ON provider_connection_audit(provider_id,created_at)"
    ]
}
