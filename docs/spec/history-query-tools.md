# History Query Tools

## Problem

RepoPrompt CE stores rich Agent Mode session transcripts on disk but exposes almost none of that history through MCP tools. The existing surface is limited to:

| Tool | What it does | Gap |
|------|-------------|-----|
| `agent_manage.list_sessions` | List sessions by state filter | No content search, no time analytics |
| `agent_manage.get_log` | Read one session's transcript (paginated turns) | Single-session only, no cross-session queries |
| `agent_manage.extract_handoff` | Export a session as XML | Single-session, export-only |

Users and agents cannot answer questions like:

- *"How much time did I spend working on feature X?"*
- *"Which sessions touched `APISettingsViewModel.swift`?"*
- *"What edge cases did we identify when fixing the ZAI model picker bug?"*
- *"Find where we discussed rate limiting"*

This spec proposes a new MCP tool group — **`history`** — that queries past session transcripts across all workspaces.

## Goals

1. **Time analytics** — aggregate time-in-session by date range, workspace, or session.
2. **Content search** — full-text search across all session transcripts and summaries.
3. **Session inventory** — list and filter sessions by workspace, date, agent, files touched.

## Non-Goals

- Replacing `agent_manage.get_log` for single-session transcript reading.
- Real-time streaming of session content as it arrives.
- Modifying past session data (read-only surface).
- Searching Claude Code (CLI) session logs — only Agent Mode sessions managed by the app.
- Reconstructing previous code states — tool call logs are partial and unreliable for that. File *activity* (touched/read/edited) is tracked, not full before/after snapshots.

## Constraints

- Session data lives on disk as JSON files — no database, no external index service.
- Compacted turns retain summary text but discard individual activities. Tools must work with both live and compacted data.
- MCP response size is capped; all tools must truncate and report.
- Tool group is named `history` (not `session_history`).
- Single MCP tool named `history` with `op` dispatch: `list_sessions` | `search` | `time` | `get_session`. Follows the established convention used by `prompt`, `git`, `manage_worktree`, `agent_manage`.
- Registered as a window-scoped MCP tool (in `MCPWindowToolGroup.history`) that queries across all workspaces. Follows the `agent_manage.list_sessions` precedent — window tool registration with cross-workspace behavior.
- Parameter naming follows existing RP-CE conventions (descriptive snake_case: `date_from`, `agent_kind`, `touched_file`, `session_id`).
- Active duration is derived at query time from stored, threshold-independent interval primitives (the union of merged turn-active intervals and the positive gaps between those intervals). The idle threshold is an integer in the inclusive range 0–1440 minutes. An omitted or null value uses the settings-backed app default (`history.idle_threshold_minutes`, currently 10 minutes when unset), while an out-of-range or non-integer value is a validation error (not clamped). An out-of-range stored default (for example, written out-of-band via `defaults`) is clamped to 0–1440. A gap strictly greater than the threshold is idle and excluded; a gap less than or equal is active. A threshold of 0 means every positive gap is idle, so `active_duration_seconds` equals the merged-interval duration. The same threshold applies to every active-duration field an operation returns (`total_active_duration_seconds`, per-group, and per-detail). The gap between merged active intervals is an approximation of idle time — it conflates user think-time, agent pauses, and time away from the app; it is not strictly "time waiting for user input."
- **Date bounds**: `date_from`/`date_to` accept ISO 8601 datetimes (exact instant) or date-only values (`YYYY-MM-DD`). For date-only values, `date_from` resolves to start-of-day (`00:00:00 UTC`) and `date_to` resolves to end-of-day (`23:59:59 UTC`), so both bounds are inclusive of the named day. An unparseable date string returns the history tool's normal `{"error": ...}` DTO. Calendar `time` grouping (`day`/`week`/`month`) applies bounds per turn after transcript loading, not only at session selection.
- **Validation**: enum parameters are strict — invalid `sort` (`list_sessions`) and invalid `source` (`search`) return a validation error rather than silently falling back. `group_by` (`time`) and `op` are likewise validated. `search` `query` is trimmed; a whitespace-only query is rejected as empty.
- **Cooperative work budgets**: cross-workspace inventory is bounded by workspace count, decoded-index count/bytes, and elapsed time; transcript operations are additionally bounded by cumulative turns and total elapsed time. Cancellation is checked and the task yields throughout enumeration, stat/decode, hydration, and transcript search loops. Budget exhaustion returns retryable partial results before the outer MCP watchdog: `scan_truncated` is true and `scan_diagnostics` contains typed `kind`, `limit`, `consumed`, `unit`, and `retryable` fields. The existing `max_sessions_scanned` default/cap and its `sessions_scanned`/`scan_truncated` behavior remain unchanged.
- Secret sanitization in search snippets deferred to v2 (`MCPResponseSanitizationPolicy` does not exist). Search snippets may expose tool args containing secrets. The risk is bounded (session data is local, only the machine's user sees MCP responses).
## Scenarios

### Scenario: List sessions that touched a specific file
- **Given** 3 sessions exist, 2 of which contain tool calls referencing `APISettingsViewModel.swift`
- **When** `history.list_sessions(touched_file: "APISettingsViewModel")`
- **Then** returns exactly 2 sessions with `files_touched` containing the path

### Scenario: Search across compacted and live turns
- **Given** a session has compacted turns with conclusion text containing "regression test" and a live turn with activity text containing "regression test"
- **When** `history.search(query: "regression test", source: "all")` (searches `conclusionText` when available, falling back to `compactConclusionText` for compacted turns)
- **Then** returns matches from both the compacted summary and the live activity, with `source` field indicating "summary" or "activity"

### Scenario: Search summaries only
- **Given** the same session as above
- **When** `history.search(query: "regression test", source: "summaries")`
- **Then** returns only the compacted turn match, not the live activity

### Scenario: Time aggregation with idle gap exclusion
- **Given** a session with turns spanning 10:00–11:00, then a 2-hour gap, then turns from 13:00–13:30
- **When** `history.time(group_by: "session")` at the settings-backed default idle threshold (currently 10 minutes)
- **Then** `active_duration_seconds` is 5400 (90 minutes), not 12600 (3.5 hours)

### Scenario: Custom idle threshold changes what counts as active
- **Given** a session with turns spanning 10:00–11:00, then a 15-minute gap, then turns from 11:15–11:45
- **When** `history.time(group_by: "session", idle_threshold_minutes: 10)`
- **Then** the 15-minute gap counts as idle, so `active_duration_seconds` is 5400 (the 60- and 30-minute blocks only); at the settings-backed default idle threshold (currently 10 minutes) the same session reports 6300 (the gap merged in as active)

### Scenario: Gap equal to the idle threshold counts as active
- **Given** a session with merged active intervals 10:00–11:00 and 11:10–11:30 (a 10-minute gap)
- **When** `history.time(group_by: "session", idle_threshold_minutes: 10)`
- **Then** the 10-minute gap is counted as active because it equals the threshold, so `active_duration_seconds` is 5400

### Scenario: list_sessions applies the custom idle threshold
- **Given** a session with merged active intervals 10:00–11:00 and 11:15–11:45 (a 15-minute gap)
- **When** `history.list_sessions(idle_threshold_minutes: 10)`
- **Then** that session's `active_duration_seconds` is 5400; at the settings-backed default idle threshold (currently 10 minutes) it would be 6300

### Scenario: Zero-turn session contributes zero duration
- **Given** a session with no turn-active intervals that otherwise matches the query filters
- **When** `history.list_sessions` or `history.time` runs
- **Then** the session's `active_duration_seconds` is 0, it has no idle gaps, and it is included per the non-duration filters

### Scenario: Cross-workspace query
- **Given** sessions exist in workspaces "repoprompt-ce" and "lyric-vibe"
- **When** `history.list_sessions()`
- **Then** returns sessions from both workspaces, each with `workspace_name` populated

### Scenario: Workspace-scoped query
- **Given** the same sessions
- **When** `history.list_sessions(workspace: "repoprompt-ce")`
- **Then** returns only sessions from that workspace

### Scenario: Truncation on large result sets
- **Given** 50 sessions match a query with `limit: 20`
- **When** `history.list_sessions(date_from: "2026-01-01", limit: 20)`
- **Then** returns 20 sessions with `"truncated": true` and `"total_sessions": 50`

### Scenario: Empty result set
- **Given** no sessions match the filter
- **When** `history.search(query: "quantum computing")`
- **Then** returns `"total_matches": 0`, `"results": []`, `"truncated": false`

### Scenario: Time grouped by day
- **Given** 5 sessions across 3 days with known turn durations
- **When** `history.time(group_by: "day")`
- **Then** returns 3 groups keyed by date, each with correct session count and total duration

### Scenario: Filter sessions by agent kind
- **Given** sessions using codexExec and claudeCodeGLM agents
- **When** `history.list_sessions(agent_kind: "codexExec")`
- **Then** returns only Codex sessions

## Proposed Surface

### `history.list_sessions`

Session inventory with content-aware filters.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `workspace` | `string?` | Limit to workspace name/UUID |
| `agent_kind` | `string?` | `"claudeCodeGLM"` \| `"codexExec"` \| `"acp"` |
| `model` | `string?` | Model substring match |
| `touched_file` | `string?` | Sessions that edited/read this file path |
| `date_from` | `string?` | ISO 8601 lower bound |
| `date_to` | `string?` | ISO 8601 upper bound |
| `sort` | `string?` | `"last_activity"` (default) \| `"duration"` \| `"turn_count"` |
| `limit` | `int?` | Max results (default: 30, max: 100) |
| `idle_threshold_minutes` | `int?` | Gaps longer than this count as idle when computing `active_duration_seconds` (settings-backed default, currently 10; range: 0–1440) |
| `max_sessions_scanned` | `int?` | Bound on sessions hydrated for stub-derived fields / touched-file matching (default: 200, hard cap: 1000) |

**Returns:** `total_sessions`, `truncated`, `sessions_scanned`, `scan_truncated`, optional typed `scan_diagnostics`, `skipped_workspaces`, and array of `sessions` with: `session_id`, `session_name`, `workspace_name`, `agent_kind`*, `agent_model`*, `first_activity_at`, `last_activity_at`, `active_duration_seconds`, `turn_count`, `tool_call_count`, `files_touched`, `had_errors`, `last_run_state`*.

- `first_activity_at`: earliest indexed transcript turn/activity timestamp, with session activity date as a fallback for legacy indexes.
- `last_activity_at`: latest indexed transcript turn/activity timestamp, with `savedAt` as a fallback for legacy indexes.
- `last_run_state`* (`agent_kind`* / `agent_model`*): emitted only when the source value is present. Legacy or sanitized sessions may omit `agent_kind`, `agent_model`, and `last_run_state` entirely. `last_run_state` is the raw persisted `AgentSessionRunState` string — one of `"idle"` | `"running"` | `"waitingForUser"` | `"waitingForQuestion"` | `"waitingForApproval"` | `"completed"` | `"cancelled"` | `"failed"` (camelCase, not normalized). It is the state at last save, not strictly terminal.
- `request_previews` is omitted from v1.


### `history.search`

Full-text search across session transcripts and summaries.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | `string` | Search term (required) |
| `workspace` | `string?` | Limit to workspace name/UUID |
| `session_id` | `string?` | Limit to a specific session |
| `source` | `string?` | `"activities"` \| `"summaries"` \| `"all"` (default: `"all"`) |
| `date_from` | `string?` | ISO 8601 lower bound |
| `date_to` | `string?` | ISO 8601 upper bound |
| `limit` | `int?` | Max results (default: 20, max: 100) |
| `max_sessions_scanned` | `int?` | Bound on transcript sessions scanned (default: 200, hard cap: 1000) |
| `include_turn_request_text` | `bool?` | Include clipped matched-turn user request text (default: false) |

**Returns:** `total_matches`, `truncated`, `scan_truncated`, optional typed `scan_diagnostics`, `sessions_scanned`, `skipped_workspaces`, and array of `results` with: `session_id`, `session_name`, `workspace_name`, `turn_index`, `turn_request_text`*, `role`, `timestamp`, `snippet` (~200 chars), `source`.

- `turn_request_text`*: emitted only when `include_turn_request_text: true` and the matched turn has a user request; clipped for compactness.

**Matching:** Case-insensitive substring match against activity `text` fields and summary text fields. For summary search: `conclusionText` (full, non-truncated) is preferred when available (full/condensed retention tiers); `compactConclusionText` (≤220 chars) serves as the fallback for summary/archived tiers where `conclusionText` is nil. Also searches `middleSummaryText` and `requestText`. Multi-word queries match the literal string, not individual words. Snippets include ~200 characters of context around the match.

---

### `history.time`

Aggregate time-in-session analytics.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `group_by` | `string` | `"day"` \| `"week"` \| `"month"` \| `"session"` \| `"workspace"` (required) |
| `workspace` | `string?` | Limit to workspace name/UUID |
| `session_id` | `string?` | Limit to a specific session |
| `date_from` | `string?` | ISO 8601 lower bound |
| `date_to` | `string?` | ISO 8601 upper bound |
| `include_details` | `bool?` | Include per-session breakdowns (default: false) |
| `limit` | `int?` | Max groups (default: 30, max: 100) |
| `idle_threshold_minutes` | `int?` | Gaps longer than this count as idle (settings-backed default, currently 10; range: 0–1440) |
| `max_sessions_scanned` | `int?` | Bound on transcript/hydration sessions scanned (default: 200, hard cap: 1000) |

**Returns:** `total_sessions`, `total_active_duration_seconds`, `truncated`, `sessions_scanned`, `scan_truncated`, optional typed `scan_diagnostics`, `skipped_workspaces`, and array of `groups` keyed by the `group_by` value. Each group has `sessions`, `active_duration_seconds`, `turn_count`, `tool_call_count`, and optional `details` array with per-session breakdowns.

**Duration:** Computed at query time from stored interval primitives: turn-active intervals (`completedAt ?? lastActivityAt ?? startedAt` per turn, merged to remove overlap) plus the positive gaps between them. `idle_threshold_minutes` (settings-backed default, currently 10) splits gaps — gaps greater than the threshold are idle and excluded; gaps less than or equal are active and included. `active_duration_seconds` / `total_active_duration_seconds` reflect the requested threshold.

---

### `history.get_session`

Read a bounded, noise-reduced transcript window for one session. Intended follow-up flow: run `history.search`, then call `history.get_session` with the returned `session_id` and `turn_index`.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `session_id` | `string` | Required session UUID |
| `around_turn` | `int?` | Turn index to inspect, usually copied from a search result |
| `context_turns` | `int?` | Turns before/after `around_turn` (default: 1, max: 5; use 0 for cheapest target-turn-only follow-up) |
| `turn_start` | `int?` | Inclusive start turn for a bounded range; used when `around_turn` is omitted |
| `turn_end` | `int?` | Inclusive end turn for a bounded range; max returned span is 20 turns |
| `roles` | `[string]?` | Included roles. Default: user, assistant, errors, summaries. Tool calls are summarized per turn unless role `tool` is included |
| `max_chars` | `int?` | Hard cap on returned text (default: 6000, max: 20000) |

**Returns:** `session_id`, `session_name`, `workspace_name`, `total_turns`, `returned_turn_start`, `returned_turn_end`, `truncated`, and `turns`. Each returned turn includes `turn_index`, `started_at`, optional `request_text`, optional `tool_call_summary`, `entries`, `truncated`, and optional `entries_omitted`.

**Bounds:** Whole-session dumps are intentionally unsupported. Callers must provide either `around_turn` (with optional `context_turns`) or a bounded `turn_start`/`turn_end` range. When the char budget exhausts mid-window, rendered turns form a contiguous block around the target — `returned_turn_start`/`returned_turn_end` bound exactly the returned `turns` and never span an unrendered hole.

## Implementation Notes

### Registration

The `history` tool is registered as a window-scoped MCP tool in `MCPWindowToolGroup.history`. Despite being window-scoped at the MCP protocol level, its handler scans all workspace directories to provide cross-workspace results. This follows the same pattern as `agent_manage.list_sessions`.

### Search text fields

The search operation prioritizes `conclusionText` (the full, non-truncated conclusion) when available. For turns at `full` or `condensed` retention tiers, `conclusionText` contains the complete assistant conclusion. For turns at `summary` or `archived` tiers, `conclusionText` is nil and `compactConclusionText` (truncated to ≤220 chars) is used instead. This ensures searches find matches beyond the 220-char truncation boundary for non-compacted turns.

### Metadata index

`AgentSessionMetadataRecord` stores `keyPaths: Set<String>`, `toolCallCount: Int`, `firstActivityAt: Date?`, `lastActivityAt: Date?`, and threshold-independent duration primitives: `coveredTurnDurationSeconds: Int` (the union of merged per-turn active intervals, overlap removed) and `interActiveIntervalGapSeconds: [Int]` (the positive gaps between those merged intervals). Each turn-active interval is `[startedAt, completedAt ?? lastActivityAt ?? startedAt]`; intervals with end earlier than start contribute zero. Intervals are sorted and merged before the primitives are computed. The index schema version is 5; older indexes are not read for results until rebuilt — their sessions are absent (no stale-duration fallback). `activeDurationSeconds` is no longer stored — it is derived at query time from the primitives at the requested `idle_threshold_minutes` (`coveredTurnDurationSeconds` plus gaps less than or equal to the threshold). Key paths are aggregated from `AgentTranscriptTurnSummary.keyPaths` for compacted turns and from persisted `toolExecution.keyPaths` for active turns. Tool counts are aggregated from summary `toolCount` when present, otherwise from tool execution activities. The index rebuild loads lightweight stubs (transcript=nil) so it does not tax the agent-mode sidebar/restore; the `history` tool computes these transcript-derived fields on demand for any record lacking them (all transcript-derived fields absent — see `lacksTranscriptDerivedFields`), while the save/load path populates them for free for sessions touched through normal use.

### Scan caching

`HistorySessionScanner` caches a completed cross-workspace session inventory for ~90 seconds (`scanCacheTTL`, default 90) so iterative `list_sessions`/`search`/`time` queries in one reasoning loop do not repeatedly reopen per-workspace indexes. Budget-truncated inventories are never installed in the TTL cache, though signature-validated index work completed before truncation remains reusable by a retry. Exact workspace UUID and `Workspace-*` storage-directory filters pre-narrow cold index work; canonical-name substring filters retain the full inventory path because their authoritative name may live only in `workspace.json`. Within the TTL a newly-saved session may not appear in cached inventory queries until the cache expires. `get_session` first checks the warm inventory and then stats the exact `AgentSession-{UUID}.json` filename across workspaces without decoding every index; only a miss performs one cache-bypassed budget-aware rescan, preserving the just-saved fallback. A per-index file-signature cache (size + mtime) invalidates a workspace's entry as soon as its `AgentSessionIndex.json` changes, independent of the TTL; decoded transcript content is likewise signature-checked and invalidated when the session file changes.

### Known gaps (v1)

- Secret sanitization in search snippets deferred to v2 (`MCPResponseSanitizationPolicy` does not exist). Snippets may expose tool args containing secrets. Risk is bounded (session data is local).
- `file_edits` and `knowledge` ops deferred to a future spec (kept as a local backlog doc, not shipped).
- `request_previews` omitted from `list_sessions` response.
- `files_touched` depends on persisted summary key paths or persisted `toolExecution.keyPaths`; older sanitized sessions whose tool args were stripped before key path extraction may still have empty file lists.
- `had_errors` maps to `hasUnknownConversationContent` (semantically broader than "had errors").
- **Duration precision**: gaps and coverage are stored as whole seconds (truncated), so a gap within ~1 second of the threshold may be classified by the truncated value. This matches the prior algorithm's precision and is immaterial at minute granularity.
- **Point turns split gaps**: a zero-duration turn (e.g. a `startedAt`-only turn from a provider that omits completion timestamps) is retained as a point interval and can split one idle gap into two, which can change classification at a given threshold. Providers that emit completion timestamps (the common case) are unaffected.

## Open Questions

1. **Pagination:** v1 omits `offset` for simplicity. If result sets are typically small (≤ 100), this is fine. Add `offset` + `next_offset` if real usage shows otherwise.
2. **Content size limits:** Resolved — real usage shows ~380 sessions / ~31 MB total for an upper-average user (median session ~45 KB, P90 ~200 KB, max ~1.1 MB). v1 loads session metadata on demand from `AgentSessions/` directories; no persistent index required. Resolved: a ~90-second in-memory scan cache was added (`HistorySessionScanner.scanCacheTTL`); see "Scan caching" above.
