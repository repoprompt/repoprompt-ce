import Foundation

// Typed, `Codable & Sendable` reply DTOs for the `history` MCP tool operations.
//
// These replace the prior typeless `[String: Any]` bridge. Each DTO encodes to the
// exact JSON shape documented in the history query tools spec; the wrapping
// ``HistoryToolReply`` enum lets `HistoryMCPToolService.execute(args:scanner:)` return
// one typed value across all three ops plus the error case, which the provider then
// encodes via `Value(dto)` like every other window-tool provider.
//
// Optional response fields (`agent_kind`, `agent_model`, `last_run_state` on list;
// `turn_request_text` on search; `details` on time groups) are plain `Optional`
// properties, so they are omitted from the encoded JSON when absent — no per-field
// `if let { dict[…] = }` injection is required.

/// The single typed return value of `HistoryMCPToolService.execute`.
enum HistoryToolReply {
    case listSessions(HistoryListSessionsReply)
    case search(HistorySearchReply)
    case time(HistoryTimeReply)
    case error(HistoryErrorReply)
}

// MARK: - list_sessions

struct HistoryListSessionsReply: Codable, Equatable {
    struct SessionDTO: Codable, Equatable {
        let sessionID: String
        let sessionName: String
        let workspaceName: String
        let firstActivityAt: String
        let lastActivityAt: String
        let activeDurationSeconds: Int
        let turnCount: Int
        let toolCallCount: Int
        let filesTouched: [String]
        let hadErrors: Bool
        let agentKind: String?
        let agentModel: String?
        let lastRunState: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case sessionName = "session_name"
            case workspaceName = "workspace_name"
            case firstActivityAt = "first_activity_at"
            case lastActivityAt = "last_activity_at"
            case activeDurationSeconds = "active_duration_seconds"
            case turnCount = "turn_count"
            case toolCallCount = "tool_call_count"
            case filesTouched = "files_touched"
            case hadErrors = "had_errors"
            case agentKind = "agent_kind"
            case agentModel = "agent_model"
            case lastRunState = "last_run_state"
        }

        init(
            sessionID: String,
            sessionName: String,
            workspaceName: String,
            firstActivityAt: String,
            lastActivityAt: String,
            activeDurationSeconds: Int,
            turnCount: Int,
            toolCallCount: Int,
            filesTouched: [String],
            hadErrors: Bool,
            agentKind: String? = nil,
            agentModel: String? = nil,
            lastRunState: String? = nil
        ) {
            self.sessionID = sessionID
            self.sessionName = sessionName
            self.workspaceName = workspaceName
            self.firstActivityAt = firstActivityAt
            self.lastActivityAt = lastActivityAt
            self.activeDurationSeconds = activeDurationSeconds
            self.turnCount = turnCount
            self.toolCallCount = toolCallCount
            self.filesTouched = filesTouched
            self.hadErrors = hadErrors
            self.agentKind = agentKind
            self.agentModel = agentModel
            self.lastRunState = lastRunState
        }
    }

    let totalSessions: Int
    let truncated: Bool
    let sessions: [SessionDTO]

    private enum CodingKeys: String, CodingKey {
        case totalSessions = "total_sessions"
        case truncated
        case sessions
    }
}

// MARK: - search

struct HistorySearchReply: Codable, Equatable {
    struct MatchDTO: Codable, Equatable {
        let sessionID: String
        let sessionName: String
        let workspaceName: String
        let turnIndex: Int
        let role: String
        let timestamp: String
        let snippet: String
        let source: String
        let turnRequestText: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case sessionName = "session_name"
            case workspaceName = "workspace_name"
            case turnIndex = "turn_index"
            case role
            case timestamp
            case snippet
            case source
            case turnRequestText = "turn_request_text"
        }

        init(
            sessionID: String,
            sessionName: String,
            workspaceName: String,
            turnIndex: Int,
            role: String,
            timestamp: String,
            snippet: String,
            source: String,
            turnRequestText: String? = nil
        ) {
            self.sessionID = sessionID
            self.sessionName = sessionName
            self.workspaceName = workspaceName
            self.turnIndex = turnIndex
            self.role = role
            self.timestamp = timestamp
            self.snippet = snippet
            self.source = source
            self.turnRequestText = turnRequestText
        }
    }

    let totalMatches: Int
    let truncated: Bool
    /// True when the per-session transcript scan hit `maxSessionsScanned` before
    /// exhausting the filtered set (distinct from `truncated`, which reflects the
    /// match `limit`). Surface so callers know the scan — not just the results — was
    /// bounded.
    let scanTruncated: Bool
    let results: [MatchDTO]

    private enum CodingKeys: String, CodingKey {
        case totalMatches = "total_matches"
        case truncated
        case scanTruncated = "scan_truncated"
        case results
    }
}

// MARK: - time

struct HistoryTimeReply: Codable, Equatable {
    struct GroupDTO: Codable, Equatable {
        struct DetailDTO: Codable, Equatable {
            let sessionID: String
            let sessionName: String
            let activeDurationSeconds: Int
            let turnCount: Int

            private enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case sessionName = "session_name"
                case activeDurationSeconds = "active_duration_seconds"
                case turnCount = "turn_count"
            }
        }

        let key: String
        let sessions: Int
        let activeDurationSeconds: Int
        let turnCount: Int
        let toolCallCount: Int
        let details: [DetailDTO]?

        private enum CodingKeys: String, CodingKey {
            case key
            case sessions
            case activeDurationSeconds = "active_duration_seconds"
            case turnCount = "turn_count"
            case toolCallCount = "tool_call_count"
            case details
        }

        init(
            key: String,
            sessions: Int,
            activeDurationSeconds: Int,
            turnCount: Int,
            toolCallCount: Int,
            details: [DetailDTO]? = nil
        ) {
            self.key = key
            self.sessions = sessions
            self.activeDurationSeconds = activeDurationSeconds
            self.turnCount = turnCount
            self.toolCallCount = toolCallCount
            self.details = details
        }
    }

    let totalSessions: Int
    let totalActiveDurationSeconds: Int
    let truncated: Bool
    let groups: [GroupDTO]

    private enum CodingKeys: String, CodingKey {
        case totalSessions = "total_sessions"
        case totalActiveDurationSeconds = "total_active_duration_seconds"
        case truncated
        case groups
    }
}

// MARK: - error

struct HistoryErrorReply: Codable, Equatable {
    let error: String
}
