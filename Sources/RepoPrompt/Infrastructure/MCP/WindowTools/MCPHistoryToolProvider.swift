import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPHistoryToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .history

    private let runtime: MCPWindowToolRuntime
    private let scanner: any HistorySessionScanning

    init(
        runtime: MCPWindowToolRuntime,
        dependencies _: MCPWindowToolDependencies? = nil,
        scannerFactory: @escaping @Sendable () -> any HistorySessionScanning = { HistorySessionScanner() }
    ) {
        self.runtime = runtime
        scanner = scannerFactory()
    }

    func buildTools() -> [Tool] {
        [historyTool()]
    }

    private func historyTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.history,
            freshnessPolicy: .none,
            description: """
            Query past Agent Mode session transcripts across all workspaces. All operations are read-only.

            **Operations**: list_sessions | search | time | get_session

            - `list_sessions`: Session inventory with content-aware filters (workspace, agent kind, model, files touched, date range). Returns session metadata including duration, turn count, and files touched.
            - `search`: Full-text search across session transcripts and summaries. Matches against both live activity text and compacted turn summaries. Returns snippets with ~200 chars of context around each match.
            - `get_session`: Read a bounded, noise-reduced window around a known session turn. Use `search` first, then call `get_session` with `session_id`, `around_turn`, `context_turns: 0`, and a modest `max_chars` for a single search hit; whole-session dumps are intentionally unsupported.
            - `time`: Aggregate time-in-session analytics. Groups by day, week, month, session, or workspace. Active duration uses the settings-backed default idle threshold (currently 10 minutes) unless `idle_threshold_minutes` is provided.

            **Scope**: Window routing does not imply workspace scope; history scans all saved workspaces by default. Use `workspace` to filter by saved name, UUID, or `Workspace-*` storage directory. Stale indexes are skipped and reported in `skipped_workspaces`.

            **Truncation**: `truncated` means `limit` capped returned results; `scan_truncated` means `max_sessions_scanned` or a cooperative workspace/index/byte/turn/elapsed budget capped work. `scan_diagnostics` identifies budget limits with typed counters and `retryable`; narrow `workspace`, `session_id`, or date scope before retrying.
            **Caching**: The cross-workspace session inventory is cached for ~90 seconds for query-loop performance. A session saved within that window may not appear in `list_sessions`/`search`/`time` until the cache expires. `get_session` first resolves the exact session filename without a full inventory scan, then retains one cache-bypassed fresh-scan fallback for just-saved sessions; transcript content is signature-checked and cache-invalidated when the session file changes.
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list_sessions**: workspace?, agent_kind?, model?, touched_file?, date_from?, date_to?, sort?, limit?, idle_threshold_minutes?, max_sessions_scanned?
                **search**: query (required), workspace?, session_id?, source?, date_from?, date_to?, limit?, max_sessions_scanned?, include_turn_request_text?
                **get_session**: session_id (required), around_turn? + context_turns?, or turn_start? + turn_end?, roles?, max_chars?
                **time**: group_by (required), workspace?, session_id?, date_from?, date_to?, limit?, include_details?, idle_threshold_minutes?, max_sessions_scanned?
                """,
                properties: [
                    "op": .string(
                        description: "Operation.",
                        enum: ["list_sessions", "search", "time", "get_session"]
                    ),
                    "workspace": .string(description: "Limit to saved workspace name, UUID, or Workspace-* storage directory."),
                    "agent_kind": .string(description: "[list_sessions] Agent kind filter (e.g. claudeCodeGLM, codexExec, acp)."),
                    "model": .string(description: "[list_sessions] Model substring match."),
                    "touched_file": .string(description: "[list_sessions] Filter sessions that edited or read this file path."),
                    "date_from": .string(description: "ISO 8601 lower date bound (e.g. 2026-01-01T00:00:00Z)."),
                    "date_to": .string(description: "ISO 8601 upper date bound."),
                    "sort": .string(
                        description: "[list_sessions] Sort order: last_activity (default), duration, turn_count.",
                        enum: ["last_activity", "duration", "turn_count"]
                    ),
                    "limit": .integer(description: "Max returned results. list_sessions default 30, search default 20, max 100."),
                    "idle_threshold_minutes": .integer(description: "[list_sessions, time] Idle gap threshold in minutes for active duration. Omitted uses the app setting/default (currently 10). Range 0...1440."),
                    "max_sessions_scanned": .integer(description: "[list_sessions, search, time] Max sessions hydrated/scanned before scan_truncated. Default 200, cap 1000. Independent cooperative inventory/turn/elapsed budgets may also truncate and are reported in scan_diagnostics."),
                    "include_turn_request_text": .boolean(description: "[search] Verbose opt-in: include clipped matched-turn user request text. Default false to keep output compact."),
                    "query": .string(description: "[search] Search term (required for search). Case-insensitive substring match."),
                    "session_id": .string(description: "[search, time, get_session] Limit to a specific session UUID."),
                    "around_turn": .integer(description: "[get_session] Turn index to inspect, usually copied from a search result. Returns a small window around this turn."),
                    "context_turns": .integer(description: "[get_session] Number of turns before/after around_turn. Use 0 for the cheapest target-turn-only follow-up to a search result. Default 1, max 5."),
                    "turn_start": .integer(description: "[get_session] Inclusive start turn for a bounded range. Requires no around_turn. Max returned span is 20 turns."),
                    "turn_end": .integer(description: "[get_session] Inclusive end turn for a bounded range. Max returned span is 20 turns."),
                    "roles": .array(
                        description: "[get_session] Included roles. Default: user, assistant, errors, summaries. Tool calls are summarized per turn; include role `tool` only when individual tool entries are needed.",
                        items: .string(description: "[get_session] Role to include", enum: ["user", "assistant", "tool", "error", "summary", "system", "thinking"])
                    ),
                    "max_chars": .integer(description: "[get_session] Hard cap on returned text. Default 6000, max 20000."),
                    "source": .string(
                        description: "[search] Where to search: activities, summaries, or all (default all).",
                        enum: ["activities", "summaries", "all"]
                    ),
                    "group_by": .string(
                        description: "[time] Grouping dimension (required for time).",
                        enum: ["day", "week", "month", "session", "workspace"]
                    ),
                    "include_details": .boolean(description: "[time] Verbose opt-in: include per-session breakdowns in each group. Default false.")
                ],
                required: ["op"]
            )
        ) { _, args in
            try await self.execute(args: args)
        }
    }

    /// Shared production execution seam used by the registered MCP tool and focused
    /// persistent-connection integration coverage.
    func execute(args: [String: Value]) async throws -> Value {
        let reply = try await HistoryMCPToolService.execute(args: args, scanner: scanner)
        return try Self.encode(reply)
    }

    // MARK: - Reply Encoding

    /// Encode the typed ``HistoryToolReply`` to an MCP `Value` via `Value(dto)`, the
    /// same path every sibling window-tool provider uses. Replaces the former
    /// `[String: Any]` → `JSONSerialization` → `JSONDecoder(Value)` bridge.
    private nonisolated static func encode(_ reply: HistoryToolReply) throws -> Value {
        switch reply {
        case let .listSessions(dto): try Value(dto)
        case let .search(dto): try Value(dto)
        case let .time(dto): try Value(dto)
        case let .getSession(dto): try Value(dto)
        case let .error(dto): try Value(dto)
        }
    }
}
