enum SchemaV4 {
    static let version = 4
    static let digest = "repoprompt-service-schema-v4-provider-connections-audit"

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS provider_connections(provider_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,connection_id TEXT UNIQUE NOT NULL,authentication_method TEXT NOT NULL,state TEXT NOT NULL,account_label TEXT,expires_at REAL,last_tested_at REAL,test_state TEXT NOT NULL,detail TEXT,key_helper_configured INTEGER NOT NULL,workload_identity_configured INTEGER NOT NULL,credential_reference TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_connection_audit(audit_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,provider_id TEXT NOT NULL,connection_id TEXT,operation TEXT NOT NULL,actor_id TEXT NOT NULL,actor_label TEXT NOT NULL,channel TEXT NOT NULL,authentication_method TEXT,result TEXT NOT NULL,created_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS provider_connection_audit_provider_time ON provider_connection_audit(provider_id,created_at)"
    ]
}
