import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPAgentControlToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .agentControl

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            agentExploreTool(),
            agentRunTool(),
            agentManageTool()
        ]
    }

    private func agentExploreTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds)
        return runtime.tool(
            name: MCPWindowToolName.agentExplore,
            freshnessPolicy: .none,
            description: """
            Short-lived, read-only explore child agents for narrow codebase probes. Each child runs in a fresh session with its own context window. Always uses the `explore` role; no custom `model_id`, workflows, session reuse, `steer`, or `respond`.

            Explore children inherit the caller's worktree bindings by default; pass `inherit_worktree=false` to opt out. Start-only worktree controls can bind an existing worktree or create one before provider startup, overriding an inherited primary-root binding. Multi-message creates produce one worktree per child when branch/path are implicit and reject a shared explicit branch or path.

            **Operations**: start | poll | wait | cancel

            - `start`: Launch one or more fresh explore sessions. Provide `message` for one probe or `messages` for multiple probes. Batch starts wait for the first referenced session to finish or need input unless `detach=true`.
            - `poll`: Return current snapshot immediately for `session_id` or `session_ids`.
            - `wait`: Block until the first referenced explore run finishes or needs input. `timeout=0` behaves like poll.
            - `cancel`: Cancel a live explore child session.

            Explore children are read-only — no edits, oracle calls, or further sub-agent spawning.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **start**: message or messages (required, mutually exclusive), detach?, timeout?, inherit_worktree?, worktree|worktree_id|worktree_create? and worktree_* args
                **poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
                **cancel**: session_id (required)
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel"]),
                    "message": .string(description: "[start] Exploration instruction text for one fresh explore child. Mutually exclusive with messages."),
                    "messages": .array(description: "[start] Array of exploration instruction strings. Mutually exclusive with message. Starts one fresh explore child per entry.", items: .string()),
                    "detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
                    "timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default \(defaultWaitSeconds)."),
                    "worktree": .string(description: "[start] Existing worktree selector to bind before provider startup: @current, @main, @branch:<name>, name, branch, path, or @id:<worktree_id>. Mutually exclusive with worktree_id and worktree_create."),
                    "worktree_id": .string(description: "[start] Durable worktree ID to bind before provider startup. Mutually exclusive with worktree and worktree_create."),
                    "worktree_create": .boolean(description: "[start] Create an app-managed Git worktree, bind it to the new session, materialize its hidden root, then start the provider. Mutually exclusive with worktree/worktree_id."),
                    "inherit_worktree": .boolean(description: "[start] When started from an Agent Mode run, inherit the source session's worktree bindings before provider startup. Default true. Set false to keep parent session threading but skip worktree inheritance; explicit worktree/worktree_id/worktree_create args still bind the requested worktree."),
                    "worktree_repo_root": .string(description: "[start] Repo/logical root selector for worktree resolution or creation. Defaults to the first loaded Git repo."),
                    "worktree_branch": .string(description: "[start + worktree_create] Optional branch name for the new worktree. Defaults to an rp/agent/<session>-... branch."),
                    "worktree_base_ref": .string(description: "[start + worktree_create] Optional base ref/commit for the new worktree."),
                    "worktree_path": .string(description: "[start + worktree_create] Optional explicit absolute path (or ~/...). External paths require allow_external_worktree_path=true."),
                    "worktree_label": .string(description: "[start] Optional visual label to persist for the bound worktree."),
                    "worktree_color": .string(description: "[start] Optional visual color to persist for the bound worktree as #RRGGBB."),
                    "allow_external_worktree_path": .boolean(description: "[start + worktree_create] Allow explicit worktree_path outside RepoPrompt's app-managed worktree container."),
                    "session_id": .string(description: "[poll, wait, cancel] Explore child session UUID returned by start."),
                    "session_ids": .array(description: "[wait, poll] Array of explore child session UUIDs. Mutually exclusive with session_id.", items: .string())
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentExplore(args)
        }
    }

    private func agentRunTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds)
        let messageDescription = "[start, steer] Instruction text. Required for start and steer. If sharing an exported plan, include the path/instruction directly in this text."
        return runtime.tool(
            name: MCPWindowToolName.agentRun,
            freshnessPolicy: .none,
            description: """
            Spawn and control Agent Mode sessions. `start` always creates a new session/tab; use `steer` to continue an existing session.

            **Role labels** — pass as `model_id` to select via the global role-default mapping:
            - `explore` — Fast exploration and codebase mapping
            - `engineer` — Balanced engineering work
            - `pair` — Interactive pair programming with highest-tier models
            - `design` — Architecture, design discussions, creative problem solving; writes a markdown review document (saved under `docs/reviews/`, `docs/designs/`, or `docs/analysis/`) as its primary deliverable for review/analysis tasks

            Role labels resolve through the effective global role-default mapping; see the top-level `task_labels` array from `agent_manage.list_agents` for the authoritative label→model mapping. If `model_id` is omitted on `start`, RepoPrompt uses the `pair` role. To pin an exact agent+model+effort target, pass a specific compound `model_id` from `agents[].models[].model_id` in the same response.

            **Operations**: start | poll | wait | cancel | steer | respond

            - `start`: Launch an agent run in a **new** session/tab. Do NOT pass `session_id` — use `steer` to continue an existing session. Omit `model_id` to use the `pair` role, or pass `model_id` with a role label (resolved via the global role-default mapping in `agent_manage.list_agents` `task_labels`) or an explicit compound `model_id` from `agents[].models[].model_id`. When started from an Agent Mode run, the new child session inherits the source session's worktree bindings by default; pass `inherit_worktree=false` to keep parent session threading but skip worktree inheritance. Optional start-only worktree args can bind the new session to an existing worktree (`worktree`/`worktree_id`) or create an app-managed worktree (`worktree_create=true`) before provider startup; explicit worktree args still bind the requested worktree. Returns a `session_id` — save it for all follow-up calls. Waits up to `timeout` seconds (default \(defaultWaitSeconds)). Pass `detach: true` to return immediately.
            - `poll`: Return current snapshot immediately. Accepts `session_id` (single) or `session_ids` (array — returns all current snapshots).
            - `wait`: Block until the run finishes or needs input. Default \(defaultWaitSeconds)s. `timeout: 0` = poll. Accepts `session_id` (single) or `session_ids` (array — returns when first session reaches interesting state). Returns `interaction_id` when input is pending.
            - `cancel`: Stop an active agent run. Only valid when the run is `running` or `waiting_for_input`. Requires `session_id`.
            - `steer`: Continue an existing agent session by sending a follow-up instruction to the `session_id` returned by `start`. If the run is still active, the instruction is steered into that run; if the last run already finished, RepoPrompt starts the next run in the same session. Pass `wait: true` (or `timeout_seconds`) to block until the steered run finishes or needs input. Do NOT use `steer` when status is `waiting_for_input` — use `respond` instead.
            - `respond`: Resolve a pending interaction (question, approval, MCP elicitation, etc). Requires `session_id` and `interaction_id` from the snapshot. The `interaction_id` is returned as a top-level field in poll/wait responses when input is pending. For MCP elicitation, use `response` (`accept`, `decline`, or `cancel`) plus optional object `content` and `meta`.

            **session_id lifecycle**: `start` creates a new session and returns `session_id` in the response. All subsequent operations on that run require passing the same `session_id` back. Do NOT invent session IDs — always use the value returned by `start`.

            **Sub-agent spawning**: MCP-started `orchestrate` runs can dispatch sub-agents. Sub-agents cannot recursively start additional agent runs.

            **Parallel agents**: When launching multiple agents in parallel, always use `detach: true` so each `start` returns immediately without blocking. You can then `wait` or `poll` each `session_id` independently.

            **IMPORTANT — never end your turn with active agents**: Sub-agents may need approval for tool calls or ask questions via `waiting_for_input`. Always `wait`/`poll` on every started session and `respond` to any pending interactions before finishing your turn. An unattended agent will stall indefinitely.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **start**: message (required), model_id? (defaults to pair), session_name?, workflow_id|workflow_name?, detach?, timeout?, inherit_worktree?, worktree|worktree_id|worktree_create? and worktree_* args. Use workflow_name="orchestrate" to plan, decompose, and dispatch sub-agents.
                **poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
                **cancel**: session_id (required)
                **steer**: session_id (required, from a prior `start`/`steer` response), message (required), wait?, timeout_seconds?, workflow_id|workflow_name?
                **respond**: session_id (required), interaction_id (required), response?, answers?, amendment?, content?, meta?
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel", "steer", "respond"]),
                    "message": .string(description: messageDescription),
                    "model_id": .string(description: "[start] Role label from agent_manage.list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from agents[].models[].model_id to pin an exact target. Defaults to pair when omitted."),
                    "session_id": .string(description: "[poll, wait, cancel, steer, respond] Session UUID returned by a prior start/steer response. Do not fabricate it. Not accepted by start — use steer to continue an existing session."),
                    "session_ids": .array(description: "[wait, poll] Array of session UUIDs. For wait: returns when first session reaches interesting state. For poll: returns all current snapshots. Mutually exclusive with session_id.", items: .string()),
                    "session_name": .string(description: "[start] Display name for a new session."),
                    "workflow_id": .string(description: "[start, steer, respond] Workflow ID. Mutually exclusive with workflow_name."),
                    "workflow_name": .string(description: "[start, steer, respond] Workflow name. Mutually exclusive with workflow_id."),
                    "detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
                    "timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default \(defaultWaitSeconds)."),
                    "worktree": .string(description: "[start] Existing worktree selector to bind before provider startup: @current, @main, @branch:<name>, name, branch, path, or @id:<worktree_id>. Mutually exclusive with worktree_id and worktree_create."),
                    "worktree_id": .string(description: "[start] Durable worktree ID to bind before provider startup. Mutually exclusive with worktree and worktree_create."),
                    "worktree_create": .boolean(description: "[start] Create an app-managed Git worktree, bind it to the new session, materialize its hidden root, then start the provider. Mutually exclusive with worktree/worktree_id."),
                    "inherit_worktree": .boolean(description: "[start] When started from an Agent Mode run, inherit the source session's worktree bindings before provider startup. Default true. Set false to keep parent session threading but skip worktree inheritance; explicit worktree/worktree_id/worktree_create args still bind the requested worktree."),
                    "worktree_repo_root": .string(description: "[start] Repo/logical root selector for worktree resolution or creation. Defaults to the first loaded Git repo."),
                    "worktree_branch": .string(description: "[start + worktree_create] Optional branch name for the new worktree. Defaults to an rp/agent/<session>-... branch."),
                    "worktree_base_ref": .string(description: "[start + worktree_create] Optional base ref/commit for the new worktree."),
                    "worktree_path": .string(description: "[start + worktree_create] Optional explicit absolute path (or ~/...). External paths require allow_external_worktree_path=true."),
                    "worktree_label": .string(description: "[start] Optional visual label to persist for the bound worktree."),
                    "worktree_color": .string(description: "[start] Optional visual color to persist for the bound worktree as #RRGGBB."),
                    "allow_external_worktree_path": .boolean(description: "[start + worktree_create] Allow explicit worktree_path outside RepoPrompt's app-managed worktree container."),
                    "wait": .boolean(description: "[steer] Wait for an interesting/terminal state after steering. Implied when timeout_seconds is provided."),
                    "timeout_seconds": .number(description: "[steer] Max wait seconds when wait=true. 0 = immediate post-steer snapshot. Default \(defaultWaitSeconds)."),
                    "interaction_id": .string(description: "[respond] Pending interaction UUID from the snapshot. Returned as a top-level field in poll/wait responses when the run is waiting_for_input."),
                    "response": .string(description: "[respond] Text answer or decision token (accept, decline, cancel, skip, etc). For MCP elicitation use accept, decline, or cancel; a non-action string is sent as content.response."),
                    "answers": .object(description: "[respond] Structured answers keyed by question ID."),
                    "content": .object(description: "[respond] MCP elicitation content object to send with action=accept."),
                    "meta": .object(description: "[respond] Optional MCP elicitation _meta object."),
                    "amendment": .string(description: "[respond] Amendment text for accept_with_amendment decisions.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentRun(args)
        }
    }

    private func agentManageTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.agentManage,
            freshnessPolicy: .providerManaged,
            description: """
            List agents, manage sessions, and browse workflows.

            **Operations**: list_agents | list_sessions | get_log | extract_handoff | handoff | create_session | resume_session | stop_session | cleanup_sessions | list_workflows

            - `list_agents`: Returns top-level `task_labels` as the authoritative role-label→model mapping (explore, engineer, pair, design), plus `agents[].models[]` with explicit compound `model_id` targets for callers that want to pin a specific agent/model/effort. Use `task_labels` entries for role-based routing; use `agents[].models[].model_id` for exact selections. Pass `roles_only=true` to return only `task_labels` and omit the explicit per-agent target catalog.
            - `list_sessions`: Browse sessions. Returns `session_id` for each session. Filter by MCP-facing `state` (e.g. `running`, `waiting_for_input`, `completed`, `failed`). When called from agent mode, automatically scopes to sessions spawned by the current agent session.
            - `get_log`: Read faithful transcript XML for a session, preserving visible assistant/tool order without handoff compaction or narration pruning. Use `offset`/`limit` to page by turns.
            - `extract_handoff` (`handoff` alias): Export the full `<forked_session ...>` handoff XML for a live or persisted session. Persisted sessions export transcript-only payloads; `include_file_contents` is accepted only for a live source tab that is currently active so file selection can be snapshotted reliably. Use `output_path` to write to a file; inline XML is returned by default only when no output path is provided.
            - `create_session` / `resume_session`: Create or resume a session with a specific `model_id`.
            - `stop_session`: Stop a live session.
            - `cleanup_sessions`: Delete specific MCP-originated sessions by ID. Only sessions started via MCP are eligible; user-created sessions are never deleted. Skips active sessions. Use `list_sessions` first to find session IDs, then pass them here.
            - `list_workflows`: Discover workflows usable with `agent_run` operations, including `orchestrate` for planning, decomposition, and sub-agent dispatch.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list_agents**: roles_only?
                **list_workflows**: no additional fields
                **list_sessions**: agent?, state?, limit?
                **get_log**: session_id (required), offset?, limit?
                **extract_handoff / handoff**: session_id (required), up_to_item_id?, include_file_contents?, output_path?, overwrite?, inline?, max_transcript_items?, max_tool_args_characters?
                **create_session**: model_id?, session_name?
                **resume_session**: session_id (required), model_id?
                **stop_session**: session_id (required)
                **cleanup_sessions**: session_ids (required, array of session UUIDs)

                Default extraction behavior: `extract_handoff` (or alias `handoff`) returns `handoff_xml` inline when `output_path` is omitted. When `output_path` is provided, XML is written to disk and omitted from the response unless `inline=true`. `output_path` must be absolute (or `~/...`); CLI shorthand resolves relative paths before calling MCP.
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["list_agents", "list_sessions", "get_log", "extract_handoff", "handoff", "create_session", "resume_session", "stop_session", "cleanup_sessions", "list_workflows"]),
                    "model_id": .string(description: "[create_session, resume_session] Role label from list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from list_agents agents[].models[].model_id."),
                    "session_id": .string(description: "[get_log, extract_handoff, resume_session, stop_session] Session UUID."),
                    "session_name": .string(description: "[create_session] Display name for a new session."),
                    "limit": .integer(description: "[list_sessions, get_log] Max results."),
                    "up_to_item_id": .string(description: "[extract_handoff] Optional transcript row UUID cutoff."),
                    "include_file_contents": .boolean(description: "[extract_handoff] Include file contents only when the source session is live and its tab is active. Default false."),
                    "output_path": .string(description: "[extract_handoff] Absolute output path (or ~/...) for the handoff XML. When set, inline XML is omitted unless inline=true."),
                    "overwrite": .boolean(description: "[extract_handoff] Whether output_path may replace an existing file. Default true."),
                    "inline": .boolean(description: "[extract_handoff] Include handoff_xml in the response. Default true without output_path, false with output_path."),
                    "max_transcript_items": .integer(description: "[extract_handoff] Transcript item budget; clamped to 1...1000. Default 200."),
                    "max_tool_args_characters": .integer(description: "[extract_handoff] Tool argument character budget; clamped to 0...20000. Default 2000."),
                    "state": .string(description: "[list_sessions] Session state filter. Use MCP-facing values such as running, waiting_for_input, completed, failed."),
                    "offset": .integer(description: "[get_log] Turn offset."),
                    "session_ids": .array(description: "[cleanup_sessions] Array of session UUIDs to delete.", items: .string()),
                    "roles_only": .boolean(description: "[list_agents] When true, return only the authoritative role-label mapping (task_labels) and omit the explicit per-agent target catalog. Default false.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentManage(args)
        }
    }
}
