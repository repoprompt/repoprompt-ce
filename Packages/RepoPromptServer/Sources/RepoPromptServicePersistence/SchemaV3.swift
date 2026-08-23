enum SchemaV3 {
    static let version = 3
    /// Legacy prototype ledger alias. Never rewrite an existing row.
    static let digest = "repoprompt-service-schema-v3-provider-settings"
    static let transformationID = "provider-settings-v1"
    static let legacyCanonicalDigest = "sha256:ec767c913fda0851cb0efc2ba7fec10f7b41419d58a29cb29749d7626a762d7c"
    static let canonicalDigest = "sha256:5e20c45f5c32ecb9ac59316c1fd76cb71362c8c4fae3252ce35fd854bc20cfa1"
    static var definition: MigrationDefinition {
        MigrationDefinition(version: version, transformationID: transformationID, statements: statements, transformationSteps: ["set-service-metadata-schema-version:3"])
    }

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS provider_settings(provider_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,enabled INTEGER NOT NULL,default_model TEXT,reasoning_effort TEXT,speed_mode TEXT,service_tier TEXT,revision INTEGER NOT NULL,updated_at REAL NOT NULL)"
    ]
}
