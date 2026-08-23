enum SchemaV6 {
    static let version = 6
    static let digest = "repoprompt-service-schema-v6-typed-mcp-show-model-presets"
    static let compatiblePriorDigests: Set<String> = [
        "repoprompt-service-schema-v6-typed-mcp-disabled-tools",
        "repoprompt-service-schema-v6-typed-workspace-approvals",
        "repoprompt-service-schema-v6-typed-direct-agent-permissions",
        "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit",
        "repoprompt-service-schema-v6-agent-composer-semantic-acceptance",
        "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance"
    ]

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS agent_model_profiles(scope_id TEXT PRIMARY KEY,project_id TEXT,profile_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS subagent_permission_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS direct_agent_permission_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workspace_approval_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS mcp_disabled_tools(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS mcp_show_model_presets(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS context_builder_settings(scope_id TEXT PRIMARY KEY,project_id TEXT,settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS mcp_model_presets(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),presets_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS advanced_server_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS project_selection_presets(project_id TEXT PRIMARY KEY,presets_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL,FOREIGN KEY(project_id) REFERENCES projects(project_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS settings_audit(audit_id TEXT PRIMARY KEY,domain TEXT NOT NULL,scope_id TEXT NOT NULL,prior_revision INTEGER NOT NULL,new_revision INTEGER NOT NULL,operation TEXT NOT NULL,actor_id TEXT NOT NULL,actor_label TEXT NOT NULL,channel TEXT NOT NULL,payload_digest TEXT NOT NULL,created_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workflow_repository_state(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),collection_revision INTEGER NOT NULL,include_session_cleanup_guidance INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workflow_repository_metadata(workflow_id TEXT PRIMARY KEY REFERENCES workflows(workflow_id) ON DELETE CASCADE,visible INTEGER NOT NULL,featured_order INTEGER,row_revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_direct_configurations(provider_id TEXT PRIMARY KEY,configuration_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_model_catalogs(provider_id TEXT PRIMARY KEY,catalog_json TEXT NOT NULL,revision INTEGER NOT NULL,refreshed_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS settings_audit_domain_scope_time ON settings_audit(domain,scope_id,created_at)",
        "CREATE UNIQUE INDEX IF NOT EXISTS workflow_repository_featured_order ON workflow_repository_metadata(featured_order) WHERE featured_order IS NOT NULL",
        "CREATE TABLE IF NOT EXISTS composer_provider_catalog_cache(provider_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,models_json TEXT NOT NULL,observed_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS agent_submissions(submission_id TEXT PRIMARY KEY,actor_id TEXT NOT NULL,target_key TEXT NOT NULL,operation TEXT NOT NULL,public_key TEXT NOT NULL,request_digest TEXT NOT NULL,state TEXT NOT NULL,session_id TEXT,request_anchor_id TEXT NOT NULL,run_id TEXT NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,turn_id TEXT NOT NULL,response_span_id TEXT NOT NULL,prepared_json TEXT,compiled_input_json TEXT,receipt_json TEXT,rejection_code TEXT,dispatch_state TEXT NOT NULL DEFAULT 'pending',created_at REAL NOT NULL,updated_at REAL NOT NULL,UNIQUE(actor_id,target_key,operation,public_key))",
        "CREATE TABLE IF NOT EXISTS effective_turn_configurations(turn_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,request_anchor_id TEXT NOT NULL,schema_version INTEGER NOT NULL,configuration_json TEXT NOT NULL,accepted_at REAL NOT NULL,UNIQUE(session_id,request_anchor_id))",
        "CREATE TABLE IF NOT EXISTS session_next_turn_defaults(session_id TEXT PRIMARY KEY,schema_version INTEGER NOT NULL,revision INTEGER NOT NULL,configuration_json TEXT NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS composer_attachments(attachment_id TEXT PRIMARY KEY,actor_id TEXT NOT NULL,project_id TEXT NOT NULL,session_id TEXT,turn_id TEXT,schema_version INTEGER NOT NULL,lifecycle TEXT NOT NULL,display_name TEXT NOT NULL,media_type TEXT NOT NULL,byte_size INTEGER NOT NULL,digest TEXT NOT NULL,pixel_width INTEGER NOT NULL,pixel_height INTEGER NOT NULL,staged_path TEXT,persistent_path TEXT,expires_at REAL,lease_submission_id TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_composer_attachments_actor_project ON composer_attachments(actor_id,project_id,lifecycle)",
        "CREATE TABLE IF NOT EXISTS accepted_attachment_manifests(turn_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,schema_version INTEGER NOT NULL,manifest_json TEXT NOT NULL,total_bytes INTEGER NOT NULL,created_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS run_presentations(run_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,schema_version INTEGER NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,phase TEXT,phase_revision INTEGER NOT NULL,status_code TEXT,status_text TEXT,run_started_at REAL NOT NULL,prior_active_phase TEXT,terminal_code TEXT,terminal_at REAL,snapshot_json TEXT NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_run_presentations_session_generation ON run_presentations(session_id,generation DESC)",
        "CREATE TABLE IF NOT EXISTS semantic_turns(turn_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,request_anchor_id TEXT NOT NULL,run_id TEXT NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,response_span_id TEXT NOT NULL,provider_turn_id TEXT,first_sequence INTEGER NOT NULL,last_sequence INTEGER NOT NULL,terminal_state TEXT,canonical_user_turn_json TEXT NOT NULL,effective_configuration_json TEXT NOT NULL,attachment_manifest_json TEXT NOT NULL,tagged_files_json TEXT NOT NULL,created_at REAL NOT NULL,accepted_at REAL NOT NULL,settled_at REAL,UNIQUE(session_id,request_anchor_id))",
        "CREATE INDEX IF NOT EXISTS idx_semantic_turns_session_sequence ON semantic_turns(session_id,last_sequence DESC)",
        "CREATE INDEX IF NOT EXISTS idx_semantic_turns_session_first_sequence ON semantic_turns(session_id,first_sequence DESC)",
        "CREATE TABLE IF NOT EXISTS semantic_activities(activity_id TEXT PRIMARY KEY,turn_id TEXT NOT NULL,session_id TEXT NOT NULL,request_anchor_id TEXT NOT NULL,run_id TEXT NOT NULL,generation INTEGER NOT NULL,turn_epoch INTEGER NOT NULL,response_span_id TEXT NOT NULL,canonical_sequence INTEGER NOT NULL,revision INTEGER NOT NULL,kind TEXT NOT NULL,content TEXT,summary TEXT,status TEXT,interaction_anchor_json TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_semantic_activities_turn_sequence ON semantic_activities(turn_id,canonical_sequence,revision)",
        "CREATE TABLE IF NOT EXISTS semantic_tools(execution_id TEXT PRIMARY KEY,activity_id TEXT NOT NULL,turn_id TEXT NOT NULL,session_id TEXT NOT NULL,canonical_sequence INTEGER NOT NULL,revision INTEGER NOT NULL,normalized_name TEXT NOT NULL,status TEXT NOT NULL,display_arguments TEXT,display_result TEXT,summary TEXT,key_paths_json TEXT NOT NULL,process_id INTEGER,exit_code INTEGER,error_code TEXT,argument_digest TEXT,result_digest TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_semantic_tools_turn_sequence ON semantic_tools(turn_id,canonical_sequence,revision)",
        "CREATE TABLE IF NOT EXISTS semantic_ingestion_watermarks(session_id TEXT PRIMARY KEY,last_legacy_sequence INTEGER NOT NULL,last_semantic_sequence INTEGER NOT NULL,presentation_revision INTEGER NOT NULL,gap_detected INTEGER NOT NULL,updated_at REAL NOT NULL)"
    ]
}
