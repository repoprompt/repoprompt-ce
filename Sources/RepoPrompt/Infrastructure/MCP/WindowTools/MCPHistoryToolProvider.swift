import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPHistoryToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .history

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
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

            **Operations**: list_sessions | search | time

            - `list_sessions`: Session inventory with content-aware filters (workspace, agent kind, model, files touched, date range). Returns session metadata including duration, turn count, and files touched.
            - `search`: Full-text search across session transcripts and summaries. Matches against both live activity text and compacted turn summaries. Returns snippets with ~200 chars of context around each match.
            - `time`: Aggregate time-in-session analytics. Groups by day, week, month, session, or workspace. Active duration excludes idle gaps > 30 minutes between consecutive turns.

            **Cross-workspace**: All ops scan every workspace directory by default. Use `workspace` to limit to a single workspace.

            **Truncation**: All ops enforce a `limit` (list_sessions default 30, search default 20) and report `truncated: true` when results exceed it.
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list_sessions**: workspace?, agent_kind?, model?, touched_file?, date_from?, date_to?, sort?, limit?
                **search**: query (required), workspace?, session_id?, source?, date_from?, date_to?, limit?
                **time**: group_by (required), workspace?, session_id?, date_from?, date_to?, include_details?
                """,
                properties: [
                    "op": .string(
                        description: "Operation.",
                        enum: ["list_sessions", "search", "time"]
                    ),
                    "workspace": .string(description: "Limit to workspace name or UUID."),
                    "agent_kind": .string(description: "[list_sessions] Agent kind filter (e.g. claudeCodeGLM, codexExec, acp)."),
                    "model": .string(description: "[list_sessions] Model substring match."),
                    "touched_file": .string(description: "[list_sessions] Filter sessions that edited or read this file path."),
                    "date_from": .string(description: "ISO 8601 lower date bound (e.g. 2026-01-01T00:00:00Z)."),
                    "date_to": .string(description: "ISO 8601 upper date bound."),
                    "sort": .string(
                        description: "[list_sessions] Sort order: last_activity (default), duration, turn_count.",
                        enum: ["last_activity", "duration", "turn_count"]
                    ),
                    "limit": .integer(description: "Max results. list_sessions default 30, search default 20, max 100."),
                    "query": .string(description: "[search] Search term (required for search). Case-insensitive substring match."),
                    "session_id": .string(description: "[search, time] Limit to a specific session UUID."),
                    "source": .string(
                        description: "[search] Where to search: activities, summaries, or all (default all).",
                        enum: ["activities", "summaries", "all"]
                    ),
                    "group_by": .string(
                        description: "[time] Grouping dimension (required for time).",
                        enum: ["day", "week", "month", "session", "workspace"]
                    ),
                    "include_details": .boolean(description: "[time] Include per-session breakdowns in each group. Default false.")
                ],
                required: ["op"]
            )
        ) { _, args in
            let argsDict = Self.anyDictionary(from: args)
            let scanner = HistorySessionScanner()
            let response = try await HistoryMCPToolService.execute(args: argsDict, scanner: scanner)
            return try Self.value(from: response)
        }
    }

    // MARK: - Value ↔ [String: Any] Conversion

    private nonisolated static func anyDictionary(from args: [String: Value]) -> [String: Any] {
        args.mapValues { rawAny(from: $0) }
    }

    private nonisolated static func rawAny(from value: Value) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(b): b
        case let .int(i): i
        case let .double(d): d
        case let .string(s): s
        case .data: NSNull()
        case let .array(a): a.map { rawAny(from: $0) }
        case let .object(o): o.mapValues { rawAny(from: $0) }
        }
    }

    private nonisolated static func value(from dict: [String: Any]) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
