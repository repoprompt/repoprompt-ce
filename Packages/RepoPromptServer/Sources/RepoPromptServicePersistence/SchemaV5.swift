enum SchemaV5 {
    static let version = 5
    /// Legacy prototype ledger alias. Never rewrite an existing row.
    static let digest = "repoprompt-service-schema-v5-portal-desktop-settings"
    static let transformationID = "portal-desktop-settings-v1"
    static let legacyCanonicalDigest = "sha256:41da1d7d779e1dae20a686227c3d691202d710cf2517e5a3b56b48a4ac415c27"
    static let canonicalDigest = "sha256:0980d7c4eb0779b81146641228e89f69e54d91402e0c5a06b66174e51fbd2267"
    static var definition: MigrationDefinition {
        MigrationDefinition(version: version, transformationID: transformationID, statements: statements, transformationSteps: ["set-service-metadata-schema-version:5"])
    }

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS portal_desktop_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),schema_version INTEGER NOT NULL,values_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)"
    ]
}
