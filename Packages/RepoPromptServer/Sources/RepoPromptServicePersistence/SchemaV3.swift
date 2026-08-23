enum SchemaV3 {
    static let version = 3
    static let digest = "repoprompt-service-schema-v3-provider-settings"

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS provider_settings(provider_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,enabled INTEGER NOT NULL,default_model TEXT,reasoning_effort TEXT,speed_mode TEXT,service_tier TEXT,revision INTEGER NOT NULL,updated_at REAL NOT NULL)"
    ]
}
