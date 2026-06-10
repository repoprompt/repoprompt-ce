---
title: History Query Tools
issue: 123
status: implemented
---

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
- Single MCP tool named `history` with `op` dispatch: `list_sessions` | `search` | `time`. Follows the established convention used by `prompt`, `git`, `manage_worktree`, `agent_manage`.
- Registered as a window-scoped MCP tool (in `MCPWindowToolGroup.history`) that queries across all workspaces. Follows the `agent_manage.list_sessions` precedent — window tool registration with cross-workspace behavior.
- Parameter naming follows existing RP-CE conventions (descriptive snake_case: `date_from`, `agent_kind`, `touched_file`, `session_id`).
- Duration excludes gaps > 30 minutes between consecutive turns (idle threshold).
- Secret sanitization in search snippets deferred to v2 (`MCPResponseSanitizationPolicy` does not exist). Search snippets may expose tool args containing secrets. The risk is bounded (session data is local, only the machine's user sees MCP responses).
- `file_edits`
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
- **When** `history.time(group_by: "session")`
- **Then** `active_duration_seconds` is 5400 (90 minutes), not 12600 (3.5 hours)

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

**Returns:** `total_sessions`, `truncated`, and array of `sessions` with: `session_id`, `session_name`, `workspace_name`, `agent_kind`, `agent_model`, `first_activity_at`, `last_activity_at`, `active_duration_seconds`, `turn_count`, `tool_call_count`, `files_touched`, `had_errors`, `last_run_state`.

- `first_activity_at`: approximated from `savedAt` in v1.
- `last_run_state`: terminal state of the session's last run — one of `"completed"` | `"cancelled"` | `"failed"` | `"waiting_for_input"`.
- `request_previews` and `tool_call_count` are omitted from v1. `tool_call_count` returns `0`.

---

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

**Returns:** `total_matches`, `truncated`, and array of `results` with: `session_id`, `session_name`, `workspace_name`, `turn_index`, `turn_request_text`, `role`, `timestamp`, `snippet` (~200 chars), `source`.

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

**Returns:** `total_sessions`, `total_active_duration_seconds`, `truncated`, and array of `groups` keyed by the `group_by` value. Each group has `sessions`, `active_duration_seconds`, `turn_count`, `tool_call_count`, and optional `details` array with per-session breakdowns.

**Duration:** Sum of turn durations for completed turns. Falls back to span timing when turn completion is unavailable. Excludes gaps > 30 minutes between consecutive turns (idle threshold).

## Implementation Notes

### Registration

The `history` tool is registered as a window-scoped MCP tool in `MCPWindowToolGroup.history`. Despite being window-scoped at the MCP protocol level, its handler scans all workspace directories to provide cross-workspace results. This follows the same pattern as `agent_manage.list_sessions`.

### Search text fields

The search operation prioritizes `conclusionText` (the full, non-truncated conclusion) when available. For turns at `full` or `condensed` retention tiers, `conclusionText` contains the complete assistant conclusion. For turns at `summary` or `archived` tiers, `conclusionText` is nil and `compactConclusionText` (truncated to ≤220 chars) is used instead. This ensures searches find matches beyond the 220-char truncation boundary for non-compacted turns.

### Metadata index

`AgentSessionMetadataRecord` was extended with `keyPaths: Set<String>` and `activeDurationSeconds: Int` fields. The index schema version was bumped from 2 → 3, triggering automatic rebuild on first access. Key paths are aggregated from `AgentTranscriptTurnSummary.keyPaths` which survives all compaction tiers.

### Known gaps (v1)

- Secret sanitization in search snippets deferred to v2 (`MCPResponseSanitizationPolicy` does not exist). Snippets may expose tool args containing secrets. Risk is bounded (session data is local).
- `file_edits` and `knowledge` ops deferred (see `docs/spec/history-query-tools-extensions.md`).
- `request_previews` omitted from `list_sessions` response.
- `tool_call_count` returns `0` (no metadata field yet).
- `first_activity_at` uses `savedAt` as an approximation.
- `had_errors` maps to `hasUnknownConversationContent` (semantically broader than "had errors").
- Invalid `session_id` filter values (non-UUID strings) are silently ignored rather than throwing an error.
- `time` response `truncated` is always `false` (no limit parameter in v1).

## Open Questions

1. **Pagination:** v1 omits `offset` for simplicity. If result sets are typically small (≤ 100), this is fine. Add `offset` + `next_offset` if real usage shows otherwise.
2. **Content size limits:** Resolved — real usage shows ~380 sessions / ~31 MB total for an upper-average user (median session ~45 KB, P90 ~200 KB, max ~1.1 MB). v1 loads session metadata on demand from `AgentSessions/` directories; no persistent index required. If cold-start latency exceeds 500 ms for 500 sessions, the plan should introduce a lightweight metadata cache.
