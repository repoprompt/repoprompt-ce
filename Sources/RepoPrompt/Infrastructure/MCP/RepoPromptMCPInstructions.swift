//
//  RepoPromptMCPInstructions.swift
//  RepoPrompt
//
//  MCP server initialization instructions for agents.
//

import Foundation

/// Instructions text returned in the MCP Initialize response.
/// Tailored per `MCPRunPurpose` so each connection only sees guidance for its available tools.
enum RepoPromptMCPInstructions {
    /// Returns instructions text appropriate for the given run purpose.
    /// - Parameters:
    ///   - purpose: Connection/run purpose used to tailor guidance.
    ///   - codeMapsDisabled: When true, omit Code Map tools from instructions.
    static func text(for purpose: MCPRunPurpose = .unknown, codeMapsDisabled: Bool = false) -> String {
        switch purpose {
        case .agentModeRun:
            agentModeText(codeMapsDisabled: codeMapsDisabled)
        case .discoverRun:
            discoverText(codeMapsDisabled: codeMapsDisabled)
        case .unknown:
            externalMCPText(codeMapsDisabled: codeMapsDisabled)
        }
    }

    // MARK: - Per-purpose instructions

    /// Full toolset with `ask_oracle`, no bind_context.
    private static func agentModeText(codeMapsDisabled: Bool) -> String {
        let alsoAvailable = codeMapsDisabled
            ? "Also available: file_actions (create/delete/move), git (status/diff/log/blame). Code Maps are globally disabled; use file_search and read_file for structure instead."
            : "Also available: get_code_structure (function/type signatures), file_actions (create/delete/move), git (status/diff/log/blame)."
        return """
        RepoPrompt is a context workspace with battle-tested agent tools optimized for reliability and token efficiency.

        RECOMMENDED over built-in equivalents:
        - file_search instead of Grep/Glob — combines content, path, and regex search in one call across all workspace roots
        - get_file_tree instead of ls/find — returns structured overview with depth/mode control
        - read_file instead of cat/head — supports line-range slicing (start_line + limit)
        - apply_edits instead of Edit — search/replace for targeted changes, rewrite mode for new/full-file rewrites, multi-edit transactions in one call

        \(alsoAvailable)

        SESSION NAMING: Use set_status whenever the user explicitly asks to name, rename, or retitle the current Agent Mode session. Do not claim that the title changed unless set_status returns success.

        CONTEXT BUILDING: context_builder is a heavy sub-agent that autonomously explores the codebase to build deep, curated context for a task. Ideal for going from task description to full implementation plan (response_type="plan"), code review ("review"), or deep Q&A ("question"). Its context is stateful — optionally continue with oracle calls using the returned chat_id.

        CONTEXT WORKFLOW: manage_selection curates the file context used by oracle and workspace_context tools — update it before oracle calls. Use add/remove for incremental changes; use set mode=full only for complete replacement; set mode=slices only replaces slices for specified files. Continue chats by passing the returned chat_id to ask_oracle.

        AGENT DELEGATION: Your system prompt lists the delegation tool available to you and how to use it. Use that tool to spawn or drive separate Agent Mode sessions when the task needs work in a fresh session or read-only exploration probes; do not assume any specific delegation tool is in scope for this connection.

        SHARING AN ORACLE / CONTEXT_BUILDER EXPORT: Pass `export_response: true` on `context_builder`, `ask_oracle`, or `oracle_send` to capture the response as a shareable file. The call returns `oracle_export_path` (the file path) and `oracle_export_instruction` (a ready-made "Read the Oracle export at `<path>` with `read_file` …" sentence). To hand the export to a delegated child agent, include `oracle_export_path` inside the `message` you send on your next delegation call — your system prompt names the specific delegation tool you should use. The child agent already has `read_file` and will open the export itself.
        """
    }

    /// Full toolset with `oracle_send` and bind_context for external MCP clients.
    private static func externalMCPText(codeMapsDisabled: Bool) -> String {
        let alsoAvailable = codeMapsDisabled
            ? "Also available: file_actions (create/delete/move), git (status/diff/log/blame). Code Maps are globally disabled; use file_search and read_file for structure instead."
            : "Also available: get_code_structure (function/type signatures), file_actions (create/delete/move), git (status/diff/log/blame)."
        return """
        RepoPrompt is a context workspace with battle-tested agent tools optimized for reliability and token efficiency.

        RECOMMENDED over built-in equivalents:
        - file_search instead of Grep/Glob — combines content, path, and regex search in one call across all workspace roots
        - get_file_tree instead of ls/find — returns structured overview with depth/mode control
        - read_file instead of cat/head — supports line-range slicing (start_line + limit)
        - apply_edits instead of Edit — search/replace for targeted changes, rewrite mode for new/full-file rewrites, multi-edit transactions in one call

        \(alsoAvailable)

        CONTEXT BUILDING: context_builder is a heavy sub-agent that autonomously explores the codebase to build deep, curated context for a task. Ideal for going from task description to full implementation plan (response_type="plan"), code review ("review"), or deep Q&A ("question"). Its context is stateful — optionally continue with oracle calls using the returned chat_id.

        CONTEXT WORKFLOW: manage_selection curates the file context used by oracle and workspace_context tools — update it before oracle calls. Use add/remove for incremental changes; use set mode=full only for complete replacement; set mode=slices only replaces slices for specified files. Continue chats by passing the returned chat_id to oracle_send.

        AGENT DELEGATION: Use agent_run to spawn separate Agent Mode sessions. Omit model_id to use the pair role, or pass model_id with a role label (explore, engineer, pair, design) or a specific model from agent_manage.list_agents. Explore agents are lightweight — use them proactively when codebase investigation would ground your work. Heavier roles (engineer, pair, design) should be launched when the user requests delegation. Design agents produce a markdown review document (saved under docs/reviews/, docs/designs/, or docs/analysis/) as their primary deliverable for review/analysis tasks — expect a report path in their summary, not just an inline response.

        SHARING AN ORACLE / CONTEXT_BUILDER EXPORT: Pass `export_response: true` on `context_builder` or `oracle_send` to capture the response as a shareable file. The call returns `oracle_export_path` (the file path) and `oracle_export_instruction` (a ready-made "Read the Oracle export at `<path>` with `read_file` …" sentence). To hand the export to a delegated child agent, include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` or `steer` call. You may emit `oracle_export_instruction` verbatim at the head of that `message`; the child already has `read_file` and will open the export itself.

        Workspace tabs isolate tab contexts for parallel tasks. Use bind_context with context_id to bind this connection to the intended tab context for multi-window/tab routing.
        """
    }

    /// Read-only tools — no editing, oracle, context_builder, or delegation.
    private static func discoverText(codeMapsDisabled: Bool) -> String {
        let codeStructureLine = codeMapsDisabled
            ? "- Code Maps are globally disabled; use file_search and read_file for structure instead"
            : "- get_code_structure — function/type signatures without full file content"
        return """
        RepoPrompt is a context workspace with battle-tested agent tools optimized for reliability and token efficiency.

        Available tools:
        - file_search — combines content, path, and regex search in one call across all workspace roots
        - get_file_tree — structured directory overview with depth/mode control
        - read_file — file contents with line-range slicing (start_line + limit)
        \(codeStructureLine)
        - manage_selection — curate file context for the response
        - workspace_context — render the current selection as a snapshot
        - git — read-only git operations (status/diff/log/blame)
        """
    }
}
