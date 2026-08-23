enum SchemaV1 {
    static let version = 1
    /// Legacy prototype ledger alias. Never rewrite an existing row.
    static let digest = "v1"
    static let transformationID = "initial-durable-service-schema-v1"
    /// Compatibility alias written by the earlier PR4 draft before runtime
    /// transformation identities were included. Never rewrite existing rows.
    static let legacyCanonicalDigest = "sha256:09ae653881b5f14fd12c5417e3353b0ac2b5b75f730e088562cc4d107eadb5b1"
    static let canonicalDigest = "sha256:9d62eb8ec385aa7ed4acd6412a8cc1c809363cd5def9b9e4a5334234e2b1e21b"
    static var definition: MigrationDefinition {
        MigrationDefinition(
            version: version,
            transformationID: transformationID,
            statements: statements + operatorStatements,
            transformationSteps: legacyColumns.map(\.identity) + [
                "seed-service-metadata:v1:dynamic-store-id:next-sequence=1:replay-floor=0",
            ]
        )
    }
    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS service_metadata(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),store_id TEXT NOT NULL,schema_version INTEGER NOT NULL,created_at TEXT NOT NULL,last_clean_shutdown INTEGER NOT NULL,current_boot_epoch INTEGER NOT NULL,next_global_sequence INTEGER NOT NULL,replay_floor INTEGER NOT NULL,restored_from_store_id TEXT,restore_backup_sequence INTEGER,restore_digest TEXT)",
        "CREATE TABLE IF NOT EXISTS projects(project_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,name TEXT NOT NULL,creator_json TEXT NOT NULL,lifecycle_state TEXT NOT NULL,revision INTEGER NOT NULL,snapshot_json TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS project_roots(root_id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(project_id),schema_version INTEGER NOT NULL,logical_name TEXT NOT NULL,canonical_path TEXT NOT NULL,filesystem_identity TEXT NOT NULL,writable INTEGER NOT NULL,revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS project_selection_templates(template_id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(project_id),schema_version INTEGER NOT NULL,selection_json TEXT NOT NULL,revision INTEGER NOT NULL,transactional_commit_id TEXT)",
        "CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(project_id),parent_session_id TEXT,root_session_id TEXT NOT NULL,schema_version INTEGER NOT NULL,creator_external_id TEXT NOT NULL,lifecycle_state TEXT NOT NULL,provider_kind TEXT NOT NULL,model TEXT,visibility TEXT NOT NULL,run_generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,revision INTEGER NOT NULL,snapshot_json TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS session_selections(session_id TEXT PRIMARY KEY REFERENCES sessions(session_id),schema_version INTEGER NOT NULL,allowed_roots_json TEXT NOT NULL,selection_json TEXT NOT NULL,selection_revision INTEGER NOT NULL,binding_revision INTEGER NOT NULL,transactional_commit_id TEXT)",
        "CREATE TABLE IF NOT EXISTS worktree_bindings(binding_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,root_id TEXT NOT NULL,session_id TEXT, schema_version INTEGER NOT NULL,base_ref TEXT,branch TEXT,physical_path TEXT NOT NULL,ownership_state TEXT NOT NULL,merge_state TEXT,revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workflows(workflow_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,source TEXT NOT NULL,name TEXT NOT NULL,definition_json TEXT NOT NULL,content_digest TEXT NOT NULL,enabled INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS agents(agent_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,root_session_id TEXT NOT NULL,parent_agent_id TEXT,schema_version INTEGER NOT NULL,provider_native_identity TEXT,role TEXT,label TEXT,lifecycle_state TEXT NOT NULL,revision INTEGER NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,schema_version INTEGER NOT NULL,provider_kind TEXT NOT NULL,provider_session_id TEXT,state TEXT NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,start_reason TEXT,end_reason TEXT,started_at TEXT NOT NULL,ended_at TEXT)",
        "CREATE TABLE IF NOT EXISTS process_families(run_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,leader_pid INTEGER,pgid INTEGER,process_start_time INTEGER,boot_id TEXT,executable_digest TEXT,executable_path TEXT,helper_token_digest TEXT,connection_generation INTEGER NOT NULL,containment_mode TEXT,state TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS process_members(run_id TEXT NOT NULL,pid INTEGER NOT NULL,schema_version INTEGER NOT NULL,parent_pid INTEGER,pgid INTEGER,session_id INTEGER,start_time INTEGER,executable_identity TEXT,first_observed_at TEXT,last_observed_at TEXT,terminal_state TEXT,PRIMARY KEY(run_id,pid,start_time))",
        "CREATE TABLE IF NOT EXISTS interactions(interaction_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,run_id TEXT,agent_id TEXT,schema_version INTEGER NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL,payload_json TEXT NOT NULL,created_at TEXT NOT NULL,expires_at TEXT,settled_at TEXT,settled_actor_json TEXT,revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS execution_permissions(session_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,mode TEXT NOT NULL,provider_settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_actor_json TEXT,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS collaboration_metadata(session_id TEXT PRIMARY KEY REFERENCES sessions(session_id),schema_version INTEGER NOT NULL,visibility TEXT NOT NULL,collaborative_steering_enabled INTEGER NOT NULL,controller_user_id TEXT NOT NULL,policy_revision INTEGER NOT NULL,controller_revision INTEGER NOT NULL,membership_revision INTEGER NOT NULL,collaboration_acknowledgement_json TEXT,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS session_contexts(session_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,prompt_text TEXT NOT NULL,selection_revision INTEGER NOT NULL,context_revision INTEGER NOT NULL,frozen_context_json TEXT NOT NULL,token_summary_json TEXT,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS oracle_chats(chat_id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(session_id),schema_version INTEGER NOT NULL,chat_json TEXT NOT NULL,revision INTEGER NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS transcript_entries(session_id TEXT NOT NULL,entry_id TEXT NOT NULL,schema_version INTEGER NOT NULL,session_sequence INTEGER NOT NULL,entry_json TEXT NOT NULL,content_digest TEXT NOT NULL,PRIMARY KEY(session_id,entry_id),UNIQUE(session_id,session_sequence))",
        "CREATE TABLE IF NOT EXISTS events(global_sequence INTEGER PRIMARY KEY,event_id TEXT UNIQUE NOT NULL,project_id TEXT NOT NULL,session_id TEXT,agent_id TEXT,parent_agent_id TEXT,root_session_id TEXT,run_id TEXT,session_sequence INTEGER,event_type TEXT NOT NULL,payload_version INTEGER NOT NULL,generation INTEGER,turn_epoch INTEGER,actor_json TEXT,payload_json TEXT NOT NULL,digest TEXT NOT NULL,timestamp REAL NOT NULL,envelope_json TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS artifacts(artifact_id TEXT PRIMARY KEY,project_id TEXT NOT NULL,session_id TEXT,agent_id TEXT,schema_version INTEGER NOT NULL,kind TEXT NOT NULL,logical_name TEXT NOT NULL,content_digest TEXT NOT NULL,storage_reference TEXT NOT NULL,size INTEGER NOT NULL,created_sequence INTEGER NOT NULL,created_at TEXT NOT NULL,retention_state TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS owned_resources(resource_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,kind TEXT NOT NULL,project_id TEXT,session_id TEXT,run_id TEXT,internal_path_identity TEXT NOT NULL,lifecycle_state TEXT NOT NULL,observed_bytes INTEGER,retention_deadline TEXT,cleanup_attempts INTEGER NOT NULL DEFAULT 0,cleanup_error TEXT)",
        "CREATE TABLE IF NOT EXISTS snapshot_checkpoints(scope TEXT NOT NULL,sequence INTEGER NOT NULL,schema_version INTEGER NOT NULL,snapshot TEXT NOT NULL,digest TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(scope,sequence))",
        "CREATE TABLE IF NOT EXISTS event_archives(archive_id TEXT PRIMARY KEY,first_sequence INTEGER NOT NULL,last_sequence INTEGER NOT NULL,event_count INTEGER NOT NULL,canonical_events_json TEXT NOT NULL,digest TEXT NOT NULL,created_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS idempotency_records(actor_id TEXT NOT NULL,operation TEXT NOT NULL,idempotency_key TEXT NOT NULL,request_digest TEXT NOT NULL,response_body TEXT NOT NULL,status INTEGER NOT NULL,created_at TEXT NOT NULL,expires_at TEXT NOT NULL,PRIMARY KEY(actor_id,operation,idempotency_key))",
        "CREATE TABLE IF NOT EXISTS request_nonces(direction TEXT NOT NULL,key_id TEXT NOT NULL,nonce TEXT NOT NULL,observed_at REAL NOT NULL,expires_at REAL NOT NULL,PRIMARY KEY(direction,key_id,nonce))",
        "CREATE TABLE IF NOT EXISTS authorization_revision_fences(scope_key TEXT PRIMARY KEY,policy_revision INTEGER NOT NULL,controller_revision INTEGER NOT NULL,membership_revision INTEGER NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS consumed_authorization_decisions(decision_id TEXT PRIMARY KEY,scope_key TEXT NOT NULL,actor_id TEXT NOT NULL,policy_revision INTEGER NOT NULL,controller_revision INTEGER NOT NULL,membership_revision INTEGER NOT NULL,consumed_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS audit_events(event_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,event_type TEXT NOT NULL,payload_json TEXT NOT NULL,created_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS schema_migrations(migration_id TEXT PRIMARY KEY,version INTEGER UNIQUE NOT NULL,description TEXT NOT NULL,digest TEXT NOT NULL,applied_at TEXT NOT NULL)",
        "CREATE INDEX IF NOT EXISTS events_session_sequence ON events(session_id,session_sequence)",
        "CREATE INDEX IF NOT EXISTS events_project_sequence ON events(project_id,global_sequence)",
        "CREATE INDEX IF NOT EXISTS request_nonces_expiry ON request_nonces(expires_at)"
    ]

    static let operatorStatements: [String] = [
        "CREATE TABLE IF NOT EXISTS operator_accounts(username TEXT PRIMARY KEY,password_salt TEXT NOT NULL,password_hash TEXT NOT NULL,iterations INTEGER NOT NULL,created_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS operator_sessions(session_id TEXT PRIMARY KEY,username TEXT NOT NULL,token_hash TEXT NOT NULL,created_at TEXT NOT NULL,expires_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS operator_setup_tokens(token_hash TEXT PRIMARY KEY,created_at TEXT NOT NULL,consumed_at TEXT)",
    ]

    static let legacyColumns: [LegacyColumnDefinition] = [
        .init(table: "events", column: "agent_id", definition: "TEXT"),
        .init(table: "events", column: "parent_agent_id", definition: "TEXT"),
        .init(table: "service_metadata", column: "last_event_timestamp", definition: "REAL NOT NULL DEFAULT 0"),
        .init(table: "service_metadata", column: "activation_state", definition: "TEXT NOT NULL DEFAULT 'active'"),
        .init(table: "service_metadata", column: "activation_generation", definition: "INTEGER NOT NULL DEFAULT 1"),
        .init(table: "service_metadata", column: "activation_token_digest", definition: "TEXT"),
        .init(table: "service_metadata", column: "activation_instance_id", definition: "TEXT"),
        .init(table: "collaboration_metadata", column: "collaboration_acknowledgement_json", definition: "TEXT"),
        .init(table: "owned_resources", column: "external_id", definition: "TEXT"),
        .init(table: "owned_resources", column: "temporary_path_identity", definition: "TEXT"),
        .init(table: "owned_resources", column: "content_digest", definition: "TEXT"),
        .init(table: "owned_resources", column: "metadata_json", definition: "TEXT NOT NULL DEFAULT '{}'"),
        .init(table: "owned_resources", column: "created_at", definition: "REAL NOT NULL DEFAULT 0"),
        .init(table: "owned_resources", column: "updated_at", definition: "REAL NOT NULL DEFAULT 0"),
        .init(table: "snapshot_checkpoints", column: "retention_class", definition: "TEXT NOT NULL DEFAULT 'rolling'"),
        .init(table: "snapshot_checkpoints", column: "archive_id", definition: "TEXT"),
    ]
}
