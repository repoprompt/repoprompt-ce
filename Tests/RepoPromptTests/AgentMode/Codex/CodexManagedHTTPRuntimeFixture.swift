import Foundation

/// Captured from bundled Codex 0.149.0 on 2026-09-06 using the parent-owned
/// smoke-repoprompt-effective-config.py probe: empty private home, HTTP policy,
/// ephemeral auth, goals disabled, all IP networking denied, no login or turn.
/// Only config is retained; origins (temporary paths/hashes) are omitted.
enum CodexManagedHTTPRuntimeFixture {
    static func configuration() throws -> [String: Any] {
        let json = #"""
        {
          "config": {
            "model": null,
            "review_model": null,
            "model_context_window": null,
            "model_auto_compact_token_limit": null,
            "model_auto_compact_token_limit_scope": null,
            "model_provider": "switchboard-managed-http",
            "approval_policy": null,
            "approvals_reviewer": null,
            "sandbox_mode": null,
            "sandbox_workspace_write": null,
            "forced_chatgpt_workspace_id": null,
            "forced_login_method": null,
            "web_search": null,
            "tools": null,
            "instructions": null,
            "developer_instructions": null,
            "compact_prompt": null,
            "model_reasoning_effort": null,
            "model_reasoning_summary": null,
            "model_verbosity": null,
            "service_tier": null,
            "analytics": {
              "enabled": false
            },
            "apps": null,
            "desktop": null,
            "experimental_realtime_ws_base_url": null,
            "tool_output_token_limit": null,
            "project_doc_fallback_filenames": [],
            "notify": null,
            "mcp_oauth_credentials_store": "auto",
            "shell_environment_policy": {
              "inherit": null,
              "ignore_default_excludes": null,
              "exclude": null,
              "set": null,
              "include_only": null,
              "filters": null,
              "experimental_use_profile": null
            },
            "profiles": {},
            "model_catalog_json": null,
            "audio": null,
            "experimental_realtime_start_instructions": null,
            "log_dir": null,
            "experimental_realtime_ws_backend_prompt": null,
            "project_doc_max_bytes": 32768,
            "projects": null,
            "features": {
              "network_proxy": null,
              "goals": false,
              "auth_elicitation": true,
              "mcp_2026_07_28": false,
              "memories": false,
              "mentions_v2": true,
              "remote_control": false,
              "remote_plugin": true,
              "tool_suggest": true
            },
            "chatgpt_base_url": "https://chatgpt.com/backend-api/",
            "orchestrator": null,
            "cli_auth_credentials_store": "ephemeral",
            "mcp_servers": {},
            "mcp_oauth_callback_port": null,
            "model_instructions_file": null,
            "apps_mcp_product_sku": null,
            "experimental_thread_store_endpoint": null,
            "plan_mode_reasoning_effort": null,
            "hooks": null,
            "plugins": {},
            "agents": null,
            "suppress_unstable_features_warning": null,
            "project_root_markers": [
              ".git"
            ],
            "file_opener": "vscode",
            "include_apps_instructions": true,
            "show_raw_agent_reasoning": null,
            "realtime": null,
            "include_permissions_instructions": true,
            "tool_suggest": null,
            "profile": null,
            "auto_review": null,
            "allow_login_shell": true,
            "background_terminal_max_timeout": 300000,
            "personality": null,
            "responses_api_metadata": null,
            "sqlite_home": null,
            "default_permissions": null,
            "include_environment_context": true,
            "experimental_realtime_ws_model": null,
            "experimental_realtime_ws_startup_context": null,
            "hide_agent_reasoning": false,
            "openai_base_url": null,
            "disable_paste_burst": null,
            "model_providers": {
              "switchboard-managed-http": {
                "name": "Switchboard managed HTTP",
                "base_url": "https://chatgpt.com/backend-api/codex",
                "env_key": null,
                "env_key_instructions": null,
                "experimental_bearer_token": null,
                "auth": null,
                "aws": null,
                "wire_api": "responses",
                "query_params": null,
                "http_headers": null,
                "env_http_headers": null,
                "request_max_retries": null,
                "stream_max_retries": null,
                "stream_idle_timeout_ms": null,
                "websocket_connect_timeout_ms": null,
                "requires_openai_auth": true,
                "supports_websockets": false,
                "supports_standalone_web_search": false
              }
            },
            "skills": null,
            "tui": null,
            "goals": null,
            "check_for_update_on_startup": false,
            "feedback": null,
            "experimental_use_unified_exec_tool": null,
            "notice": null,
            "experimental_realtime_webrtc_call_base_url": null,
            "ghost_snapshot": null,
            "include_collaboration_mode_instructions": true,
            "experimental_thread_store": null,
            "history": {
              "persistence": "save-all",
              "max_bytes": null
            },
            "windows": null,
            "js_repl_node_module_dirs": null,
            "mcp_oauth_callback_url": null,
            "experimental_compact_prompt_file": null,
            "otel": null,
            "permissions": null,
            "js_repl_node_path": null,
            "memories": null,
            "marketplaces": {},
            "oss_provider": null
          }
        }
        """#
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }
}
