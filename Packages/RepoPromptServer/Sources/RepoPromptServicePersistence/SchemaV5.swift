enum SchemaV5 {
    static let version = 5
    static let digest = "repoprompt-service-schema-v5-portal-desktop-settings"

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS portal_desktop_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),schema_version INTEGER NOT NULL,values_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)"
    ]
}
