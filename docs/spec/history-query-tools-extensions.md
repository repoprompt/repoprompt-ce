---
title: History Query Tools — Extensions
issue: 123
status: deferred
---

# History Query Tools — Extensions

> Post-v1 extensions for the `history` MCP tool group. The v1 tool (`list_sessions`, `search`, `time`) is now implemented (see `docs/spec/history-query-tools.md`). These are not part of the initial implementation but capture ideas that emerged during spec review.

**Parent spec:** `history-query-tools.md`

---

## `history.find_file_activity`

Richer file edit reconstruction beyond what `history.list(touched_file:)` provides.

**Purpose:** Reconstruct search/replace pairs and edit history for a specific file across all sessions.

**Parameters:**

```
path: string               — file path (required, substring match)
workspace: string?         — limit to workspace
session_id: string?        — limit to a specific session
date_from: string?         — ISO 8601 lower bound
date_to: string?           — ISO 8601 upper bound
include_args: bool?        — include full tool args/result (default: false)
limit: int?                — max results (default: 20, max: 50)
```

**What it adds over `history.list(touched_file:)`:**
- Parses `AgentTranscriptToolExecution.argsJSON` to extract search/replace pairs from `apply_edits` calls.
- Returns `activity_type: "read" | "search" | "edit_attempt" | "edit_applied"` per match.
- When `include_args` is true, returns the parsed args with diff context.

**Why deferred:** Parsing tool call args for edit reconstruction is complex and the reliability depends on tool call success, compaction state, and whether edits were manually changed afterward. The simpler `touched_file` filter on `history.list` covers the common case ("which sessions touched this file?") without overpromising reconstruction accuracy.

---

## `history.find_conclusions`

Semantic knowledge extraction from session summaries.

**Purpose:** Extract decisions, bugs found/fixed, edge cases, and architectural conclusions from session turn summaries.

**Parameters:**

```
query: string?             — semantic filter on conclusions/findings
workspace: string?         — limit to workspace
session_id: string?        — limit to a specific session
date_from: string?         — ISO 8601 lower bound
date_to: string?           — ISO 8601 upper bound
category: string?          — "decisions" | "bugs_found" | "bugs_fixed" | "edge_cases" | "architecture"
limit: int?                — max results (default: 20, max: 50)
```

**Sources:**
- `AgentTranscriptTurnSummary.compactConclusionText` for compacted turns.
- Final assistant message in live turns.

**Why deferred:** Heuristic classification ("bug", "fix", "edge case", "decision") is noisy and hard to explain to users. The `source: "summaries"` filter on `history.search` covers the basic use case without introducing unreliable categorization. Semantic extraction may be worth adding later, potentially backed by embeddings rather than keyword heuristics.

---

## Vector Search

Embedding-based semantic search over session transcripts and conclusions.

**Why deferred:** Substring matching is sufficient for v1. Vector search adds a dependency on an embedding model, an index storage layer, and background indexing — significant complexity before the value is proven. If `history.search` usage shows that users frequently ask natural-language questions that substring matching can't satisfy, this becomes a strong candidate.

**Potential approach:**
- Embed `compactConclusionText` and `middleSummaryText` at index time.
- Store embeddings in a lightweight vector index (in-memory for small corpora, SQLite + vector extension for larger).
- Add a `semantic: bool` parameter to `history.search` to switch between substring and vector matching.

---

## Pagination

`offset` and `next_offset` for large result sets.

**Why deferred:** v1 result limits (20–30) cover most queries. If real usage shows result sets routinely exceeding the limit, add `offset` to `history.list` and `history.search` with a `next_offset` field in responses.

---

## Background Index Watchers

Real-time index updates via file system watchers on `AgentSessions/` directories.

**Why deferred:** The mtime-based freshness check on each query is simple and sufficient. Background watchers add concurrency, cache invalidation, and lifecycle complexity. Add only if query latency from cold-start reindexing becomes a real issue.
