enum SchemaV2 {
    static let version = 2
    /// Legacy prototype ledger alias. Never rewrite an existing row.
    static let digest = "repoprompt-service-schema-v2-owned-resources-archives-restore-counters"
    static let transformationID = "owned-resources-archives-restore-counters-v1"
    static let canonicalDigest = "sha256:f6a8d2628909e73e95302537ac970ae4bfa090df59a86729eaa4d4552bf6992c"
    static var definition: MigrationDefinition {
        MigrationDefinition(
            version: version,
            transformationID: transformationID,
            statements: statements + dataStatements,
            transformationSteps: []
        )
    }

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS session_event_counters(session_id TEXT PRIMARY KEY,event_count INTEGER NOT NULL,last_sequence INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS worktree_merge_leases(lease_id TEXT PRIMARY KEY,binding_id TEXT NOT NULL,expected_binding_revision INTEGER NOT NULL,strategy TEXT NOT NULL,target_path TEXT NOT NULL,pre_merge_head TEXT NOT NULL,state TEXT NOT NULL,owner_instance_id TEXT NOT NULL,conflict_artifact_path TEXT,error_code TEXT,started_at REAL NOT NULL,updated_at REAL NOT NULL,expires_at REAL NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS worktree_merge_leases_one_live ON worktree_merge_leases(binding_id) WHERE state IN ('preparing','running','prepared','conflicted')",
        "CREATE INDEX IF NOT EXISTS worktree_merge_leases_state_expiry ON worktree_merge_leases(state,expires_at)",
        "CREATE TABLE IF NOT EXISTS event_archive_blobs(archive_id TEXT PRIMARY KEY,store_id TEXT NOT NULL,first_sequence INTEGER NOT NULL,last_sequence INTEGER NOT NULL,event_count INTEGER NOT NULL,compression TEXT NOT NULL,compressed_events_base64 TEXT NOT NULL,uncompressed_digest TEXT NOT NULL,compressed_digest TEXT NOT NULL,created_at REAL NOT NULL,UNIQUE(store_id,first_sequence,last_sequence))",
        "CREATE TRIGGER IF NOT EXISTS event_archive_blobs_immutable_update BEFORE UPDATE ON event_archive_blobs BEGIN SELECT RAISE(ABORT,'event archive segments are immutable'); END",
        "CREATE TRIGGER IF NOT EXISTS event_archive_blobs_immutable_delete BEFORE DELETE ON event_archive_blobs BEGIN SELECT RAISE(ABORT,'event archive segments are immutable'); END",
        "CREATE TRIGGER IF NOT EXISTS legacy_event_archives_immutable_update BEFORE UPDATE ON event_archives BEGIN SELECT RAISE(ABORT,'event archive segments are immutable'); END",
        "CREATE TRIGGER IF NOT EXISTS legacy_event_archives_immutable_delete BEFORE DELETE ON event_archives BEGIN SELECT RAISE(ABORT,'event archive segments are immutable'); END",
        "CREATE TRIGGER IF NOT EXISTS protected_checkpoints_immutable_update BEFORE UPDATE ON snapshot_checkpoints WHEN OLD.retention_class != 'rolling' BEGIN SELECT RAISE(ABORT,'protected checkpoints are immutable'); END",
        "CREATE TRIGGER IF NOT EXISTS protected_checkpoints_immutable_delete BEFORE DELETE ON snapshot_checkpoints WHEN OLD.retention_class != 'rolling' BEGIN SELECT RAISE(ABORT,'protected checkpoints are immutable'); END",
        "CREATE UNIQUE INDEX IF NOT EXISTS owned_resources_external_identity ON owned_resources(kind,external_id) WHERE external_id IS NOT NULL",
        "CREATE UNIQUE INDEX IF NOT EXISTS owned_resources_live_path ON owned_resources(internal_path_identity) WHERE lifecycle_state != 'deleted'",
        "CREATE INDEX IF NOT EXISTS owned_resources_state_deadline ON owned_resources(lifecycle_state,retention_deadline)"
    ]

    static let dataStatements: [String] = [
        "UPDATE owned_resources SET created_at=CASE WHEN created_at=0 THEN unixepoch() ELSE created_at END,updated_at=CASE WHEN updated_at=0 THEN unixepoch() ELSE updated_at END",
        "INSERT OR IGNORE INTO session_event_counters(session_id,event_count,last_sequence) SELECT session_id,COUNT(*),MAX(global_sequence) FROM events WHERE session_id IS NOT NULL GROUP BY session_id",
        "UPDATE service_metadata SET schema_version=2,last_event_timestamp=COALESCE((SELECT MAX(timestamp) FROM events),0) WHERE fixed_id=1",
    ]
}
