import Crypto
import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO

enum SchemaV7 {
    struct NormalizationPlan: Sendable, Equatable {
        let id: String
        let appliesFinalV6DDL: Bool
        let rewritesLegacyJSONKeys: Bool
    }

    static let version = 7
    /// Legacy PR4 ledger alias accepted for exact-head compatibility.
    static let digest = "repoprompt-service-schema-v7-compatibility-audit-namespace-identity-v1"
    static let transformationID = "prototype-v6-ledger-normalization-v2"
    static let legacyCanonicalDigest = "sha256:d0bef377110aa4d336cbe11493a2bb9e3b0b24c64de828bcbf75decc166f9f3a"
    static let preHistoricalProgramCanonicalDigest = "sha256:6d2aaea9c3017685d7e2a7016c59811da7b7920d160d047da6ad0f4b54e726a6"
    static let preCollaborationRebuildCanonicalDigest = "sha256:8c70e39d6d6c3027cedf56f5ab93515d3456830194cd06db48922d5357e411e5"
    static let canonicalDigest = "sha256:fccefb0613a49662654d45c26a518303fa519497b5a862eb9f62e5316bc3742c"
    static var definition: MigrationDefinition {
        let planEvidence = prototypeNormalizationPlans.keys.sorted().compactMap { observed -> String? in
            guard let plan = prototypeNormalizationPlans[observed] else { return nil }
            return "prototype-v6:\(observed):\(plan.id):ddl=\(plan.appliesFinalV6DDL):legacy-json=\(plan.rewritesLegacyJSONKeys)"
        }
        let historicalFinalV6Program =
            SchemaV1.operatorStatements.map { "historical-final-v6-ddl:\($0)" }
                + SchemaV6.statements.map { "historical-final-v6-ddl:\($0)" }
                + SchemaV1.legacyColumns.map { "historical-final-v6-\($0.identity)" }
                + collaborationRebuildProgramEvidence
        return MigrationDefinition(
            version: version,
            transformationID: transformationID,
            statements: statements,
            transformationSteps: planEvidence + historicalFinalV6Program + [
                "current-v6-canonical:\(SchemaV6.canonicalDigest):prototype-v6-current-audit-only",
                "final-v6-shape:\(finalV6ShapeDigest)",
                "legacy-json:goblinUserId->userId",
                "legacy-json:goblin-explicit-selection->explicit-selection",
                "legacy-column:goblin_acknowledgement_json->collaboration_acknowledgement_json:copy-if-target-null:drop-source",
                "validate-final-v6-shape-before-v7-ddl",
                "insert-schema-compatibility-audit:source-v6:target-v7:dynamic-observed-digest-normalization-and-time",
                "insert-authority-namespace-identity:fixed-id-1:dynamic-kind-identity-and-time",
                "set-service-metadata-schema-version:7",
            ]
        )
    }

    static let statements: [String] = [
        "CREATE TABLE schema_compatibility_audit(source_version INTEGER NOT NULL CHECK(source_version = 6),observed_digest TEXT NOT NULL,normalization_id TEXT NOT NULL,target_version INTEGER NOT NULL CHECK(target_version = 7),schema_shape_digest TEXT NOT NULL,applied_at REAL NOT NULL,PRIMARY KEY(source_version,observed_digest,normalization_id))",
        "CREATE TABLE authority_namespace_identity(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id = 1),namespace_kind TEXT NOT NULL CHECK(namespace_kind IN ('server', 'directHeadless')),database_identity_digest TEXT NOT NULL,created_at REAL NOT NULL)",
    ]

    static let collaborationRebuildCreateStatement = "CREATE TABLE collaboration_metadata_v7_rebuild(session_id TEXT PRIMARY KEY REFERENCES sessions(session_id),schema_version INTEGER NOT NULL,visibility TEXT NOT NULL,collaborative_steering_enabled INTEGER NOT NULL,controller_user_id TEXT NOT NULL,policy_revision INTEGER NOT NULL,controller_revision INTEGER NOT NULL,membership_revision INTEGER NOT NULL,collaboration_acknowledgement_json TEXT,updated_at TEXT NOT NULL)"
    static let collaborationRebuildDropStatement = "DROP TABLE collaboration_metadata"
    static let collaborationRebuildRenameStatement = "ALTER TABLE collaboration_metadata_v7_rebuild RENAME TO collaboration_metadata"
    static let collaborationRebuildProgramEvidence = [
        collaborationRebuildCreateStatement,
        "INSERT collaboration_metadata_v7_rebuild SELECT acknowledgement=COALESCE(current,legacy)|current|legacy|NULL",
        collaborationRebuildDropStatement,
        collaborationRebuildRenameStatement,
    ]

    static func collaborationRebuildCopyStatement(acknowledgementExpression: String) -> String {
        "INSERT INTO collaboration_metadata_v7_rebuild(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,updated_at) SELECT session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,\(acknowledgementExpression),updated_at FROM collaboration_metadata"
    }

    static let knownPrototypeV6Digests: Set<String> = [
        "repoprompt-service-schema-v6-typed-mcp-show-model-presets",
        "repoprompt-service-schema-v6-typed-mcp-disabled-tools",
        "repoprompt-service-schema-v6-typed-workspace-approvals",
        "repoprompt-service-schema-v6-typed-direct-agent-permissions",
        "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit",
        "repoprompt-service-schema-v6-agent-composer-semantic-acceptance",
        "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance",
    ]

    private static let prototypeNormalizationPlans: [String: NormalizationPlan] = [
        "repoprompt-service-schema-v6-typed-mcp-show-model-presets": .init(
            id: "prototype-v6-current-audit-only",
            appliesFinalV6DDL: false,
            rewritesLegacyJSONKeys: false
        ),
        "repoprompt-service-schema-v6-typed-mcp-disabled-tools": .init(
            id: "prototype-v6-history-typed-mcp-disabled-tools",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
        "repoprompt-service-schema-v6-typed-workspace-approvals": .init(
            id: "prototype-v6-history-typed-workspace-approvals",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
        "repoprompt-service-schema-v6-typed-direct-agent-permissions": .init(
            id: "prototype-v6-history-typed-direct-agent-permissions",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
        "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit": .init(
            id: "prototype-v6-history-typed-settings-workflows-direct-providers-cas-audit",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
        "repoprompt-service-schema-v6-agent-composer-semantic-acceptance": .init(
            id: "prototype-v6-history-agent-composer-semantic-acceptance",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
        "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance": .init(
            id: "prototype-v6-history-typed-settings-agent-composer-semantic-acceptance",
            appliesFinalV6DDL: true,
            rewritesLegacyJSONKeys: true
        ),
    ]

    static var normalizationPlans: [String: NormalizationPlan] {
        var plans = prototypeNormalizationPlans
        let currentPlan = NormalizationPlan(
            id: "prototype-v6-current-audit-only",
            appliesFinalV6DDL: false,
            rewritesLegacyJSONKeys: false
        )
        plans[SchemaV6.legacyCanonicalDigest] = currentPlan
        plans[SchemaV6.canonicalDigest] = currentPlan
        return plans
    }

    static let finalV6ShapeManifest: [String] = [
        "index:events_project_sequence",
        "index:events_session_sequence",
        "index:idx_composer_attachments_actor_project",
        "index:idx_run_presentations_session_generation",
        "index:idx_semantic_activities_turn_sequence",
        "index:idx_semantic_tools_turn_sequence",
        "index:idx_semantic_turns_session_first_sequence",
        "index:idx_semantic_turns_session_sequence",
        "index:owned_resources_external_identity",
        "index:owned_resources_live_path",
        "index:owned_resources_state_deadline",
        "index:provider_connection_audit_provider_time",
        "index:request_nonces_expiry",
        "index:settings_audit_domain_scope_time",
        "index:workflow_repository_featured_order",
        "index:worktree_merge_leases_one_live",
        "index:worktree_merge_leases_state_expiry",
        "table:accepted_attachment_manifests:turn_id,session_id,schema_version,manifest_json,total_bytes,created_at",
        "table:advanced_server_settings:fixed_id,settings_json,revision,updated_at",
        "table:agent_model_profiles:scope_id,project_id,profile_json,revision,updated_at",
        "table:agent_submissions:submission_id,actor_id,target_key,operation,public_key,request_digest,state,session_id,request_anchor_id,run_id,generation,turn_epoch,turn_id,response_span_id,prepared_json,compiled_input_json,receipt_json,rejection_code,dispatch_state,created_at,updated_at",
        "table:agents:agent_id,session_id,root_session_id,parent_agent_id,schema_version,provider_native_identity,role,label,lifecycle_state,revision,created_at,updated_at",
        "table:artifacts:artifact_id,project_id,session_id,agent_id,schema_version,kind,logical_name,content_digest,storage_reference,size,created_sequence,created_at,retention_state",
        "table:audit_events:event_id,schema_version,event_type,payload_json,created_at",
        "table:authorization_revision_fences:scope_key,policy_revision,controller_revision,membership_revision,updated_at",
        "table:collaboration_metadata:session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,updated_at",
        "table:composer_attachments:attachment_id,actor_id,project_id,session_id,turn_id,schema_version,lifecycle,display_name,media_type,byte_size,digest,pixel_width,pixel_height,staged_path,persistent_path,expires_at,lease_submission_id,created_at,updated_at",
        "table:composer_provider_catalog_cache:provider_id,schema_version,models_json,observed_at",
        "table:consumed_authorization_decisions:decision_id,scope_key,actor_id,policy_revision,controller_revision,membership_revision,consumed_at",
        "table:context_builder_settings:scope_id,project_id,settings_json,revision,updated_at",
        "table:direct_agent_permission_settings:fixed_id,settings_json,revision,updated_at",
        "table:effective_turn_configurations:turn_id,session_id,request_anchor_id,schema_version,configuration_json,accepted_at",
        "table:event_archive_blobs:archive_id,store_id,first_sequence,last_sequence,event_count,compression,compressed_events_base64,uncompressed_digest,compressed_digest,created_at",
        "table:event_archives:archive_id,first_sequence,last_sequence,event_count,canonical_events_json,digest,created_at",
        "table:events:global_sequence,event_id,project_id,session_id,agent_id,parent_agent_id,root_session_id,run_id,session_sequence,event_type,payload_version,generation,turn_epoch,actor_json,payload_json,digest,timestamp,envelope_json",
        "table:execution_permissions:session_id,schema_version,mode,provider_settings_json,revision,updated_actor_json,updated_at",
        "table:idempotency_records:actor_id,operation,idempotency_key,request_digest,response_body,status,created_at,expires_at",
        "table:interactions:interaction_id,session_id,run_id,agent_id,schema_version,kind,state,payload_json,created_at,expires_at,settled_at,settled_actor_json,revision",
        "table:mcp_disabled_tools:fixed_id,settings_json,revision,updated_at",
        "table:mcp_model_presets:fixed_id,presets_json,revision,updated_at",
        "table:mcp_show_model_presets:fixed_id,settings_json,revision,updated_at",
        "table:operator_accounts:username,password_salt,password_hash,iterations,created_at",
        "table:operator_sessions:session_id,username,token_hash,created_at,expires_at",
        "table:operator_setup_tokens:token_hash,created_at,consumed_at",
        "table:oracle_chats:chat_id,session_id,schema_version,chat_json,revision,created_at,updated_at",
        "table:owned_resources:resource_id,schema_version,kind,project_id,session_id,run_id,internal_path_identity,lifecycle_state,observed_bytes,retention_deadline,cleanup_attempts,cleanup_error,external_id,temporary_path_identity,content_digest,metadata_json,created_at,updated_at",
        "table:portal_desktop_settings:fixed_id,schema_version,values_json,revision,updated_at",
        "table:process_families:run_id,schema_version,leader_pid,pgid,process_start_time,boot_id,executable_digest,executable_path,helper_token_digest,connection_generation,containment_mode,state",
        "table:process_members:run_id,pid,schema_version,parent_pid,pgid,session_id,start_time,executable_identity,first_observed_at,last_observed_at,terminal_state",
        "table:project_roots:root_id,project_id,schema_version,logical_name,canonical_path,filesystem_identity,writable,revision",
        "table:project_selection_presets:project_id,presets_json,revision,updated_at",
        "table:project_selection_templates:template_id,project_id,schema_version,selection_json,revision,transactional_commit_id",
        "table:projects:project_id,schema_version,name,creator_json,lifecycle_state,revision,snapshot_json,created_at,updated_at",
        "table:provider_connection_audit:audit_id,schema_version,provider_id,connection_id,operation,actor_id,actor_label,channel,authentication_method,result,created_at",
        "table:provider_connections:provider_id,schema_version,connection_id,authentication_method,state,account_label,expires_at,last_tested_at,test_state,detail,key_helper_configured,workload_identity_configured,credential_reference,created_at,updated_at,revision",
        "table:provider_direct_configurations:provider_id,configuration_json,revision,updated_at",
        "table:provider_model_catalogs:provider_id,catalog_json,revision,refreshed_at",
        "table:provider_settings:provider_id,schema_version,enabled,default_model,reasoning_effort,speed_mode,service_tier,revision,updated_at",
        "table:request_nonces:direction,key_id,nonce,observed_at,expires_at",
        "table:run_presentations:run_id,session_id,schema_version,generation,turn_epoch,phase,phase_revision,status_code,status_text,run_started_at,prior_active_phase,terminal_code,terminal_at,snapshot_json",
        "table:runs:run_id,session_id,schema_version,provider_kind,provider_session_id,state,generation,turn_epoch,start_reason,end_reason,started_at,ended_at",
        "table:schema_migrations:migration_id,version,description,digest,applied_at",
        "table:semantic_activities:activity_id,turn_id,session_id,request_anchor_id,run_id,generation,turn_epoch,response_span_id,canonical_sequence,revision,kind,content,summary,status,interaction_anchor_json,created_at,updated_at",
        "table:semantic_ingestion_watermarks:session_id,last_legacy_sequence,last_semantic_sequence,presentation_revision,gap_detected,updated_at",
        "table:semantic_tools:execution_id,activity_id,turn_id,session_id,canonical_sequence,revision,normalized_name,status,display_arguments,display_result,summary,key_paths_json,process_id,exit_code,error_code,argument_digest,result_digest,created_at,updated_at",
        "table:semantic_turns:turn_id,session_id,request_anchor_id,run_id,generation,turn_epoch,response_span_id,provider_turn_id,first_sequence,last_sequence,terminal_state,canonical_user_turn_json,effective_configuration_json,attachment_manifest_json,tagged_files_json,created_at,accepted_at,settled_at",
        "table:service_metadata:fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor,restored_from_store_id,restore_backup_sequence,restore_digest,last_event_timestamp,activation_state,activation_generation,activation_token_digest,activation_instance_id",
        "table:session_contexts:session_id,schema_version,prompt_text,selection_revision,context_revision,frozen_context_json,token_summary_json,updated_at",
        "table:session_event_counters:session_id,event_count,last_sequence",
        "table:session_next_turn_defaults:session_id,schema_version,revision,configuration_json,updated_at",
        "table:session_selections:session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id",
        "table:sessions:session_id,project_id,parent_session_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,model,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at",
        "table:settings_audit:audit_id,domain,scope_id,prior_revision,new_revision,operation,actor_id,actor_label,channel,payload_digest,created_at",
        "table:snapshot_checkpoints:scope,sequence,schema_version,snapshot,digest,created_at,retention_class,archive_id",
        "table:subagent_permission_settings:fixed_id,settings_json,revision,updated_at",
        "table:transcript_entries:session_id,entry_id,schema_version,session_sequence,entry_json,content_digest",
        "table:workflow_repository_metadata:workflow_id,visible,featured_order,row_revision,updated_at",
        "table:workflow_repository_state:fixed_id,collection_revision,include_session_cleanup_guidance,updated_at",
        "table:workflows:workflow_id,schema_version,source,name,definition_json,content_digest,enabled",
        "table:workspace_approval_settings:fixed_id,settings_json,revision,updated_at",
        "table:worktree_bindings:binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision",
        "table:worktree_merge_leases:lease_id,binding_id,expected_binding_revision,strategy,target_path,pre_merge_head,state,owner_instance_id,conflict_artifact_path,error_code,started_at,updated_at,expires_at",
    ]
    static let finalV6ShapeDigest = "5051a392a30ff6e26a69d75c2a91c1fab9f4f3360320697a9b9207709f0450ac"

    static func normalizationID(for observedDigest: String) -> String? {
        normalizationPlans[observedDigest]?.id
    }

    static func validateFinalV6Shape(using database: SQLiteDatabaseExecutor) async throws {
        let rows = try await database.query(
            "SELECT type,name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' AND name NOT IN ('schema_compatibility_audit','authority_namespace_identity') ORDER BY type,name",
            operationClass: .bulk
        )
        var observed: [String] = []
        for row in rows {
            guard let type = row.column("type")?.string, let name = row.column("name")?.string else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Schema shape contains an invalid object")
            }
            if type == "table" {
                let columns = try await database.query("PRAGMA table_info(\(name))", operationClass: .bulk)
                    .compactMap { $0.column("name")?.string }
                    .joined(separator: ",")
                observed.append("table:\(name):\(columns)")
            } else {
                observed.append("index:\(name)")
            }
        }
        let material = observed.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        guard observed == finalV6ShapeManifest, digest == finalV6ShapeDigest else {
            let mismatchIndex = zip(observed, finalV6ShapeManifest).enumerated()
                .first(where: { $0.element.0 != $0.element.1 })?.offset
                ?? min(observed.count, finalV6ShapeManifest.count)
            let actual = mismatchIndex < observed.count ? observed[mismatchIndex] : "<missing>"
            let expected = mismatchIndex < finalV6ShapeManifest.count
                ? finalV6ShapeManifest[mismatchIndex]
                : "<none>"
            throw ServiceAPIError(
                code: .persistenceUnavailable,
                message: "Schema v6 shape does not match the frozen migration manifest at \(mismatchIndex): expected \(expected), observed \(actual)",
                retryable: false
            )
        }
    }
}
