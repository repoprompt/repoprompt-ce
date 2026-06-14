import Foundation

/// Dispatches the `history` MCP tool operations (`list_sessions`, `search`, `time`)
/// against the cross-workspace session scanner.
///
/// Each operation is a private method that receives the raw `args` dictionary and the
/// scanner, performs the query, and returns a spec-compliant `[String: Any]` response.
enum HistoryMCPToolService {
    // MARK: - Public Entry Point

    /// Execute a `history` tool operation.
    /// - Parameters:
    ///   - args: The MCP tool arguments dictionary. Must contain `"op"`.
    ///   - scanner: A ``HistorySessionScanning`` conformant object for data access.
    /// - Returns: A `[String: Any]` response dictionary per the history query tools spec.
    static func execute(
        args: [String: Any],
        scanner: HistorySessionScanning
    ) async throws -> [String: Any] {
        guard let op = args["op"] as? String, !op.isEmpty else {
            return errorResponse(message: "Missing or empty required parameter 'op'")
        }

        switch op {
        case "list_sessions":
            return try await executeListSessions(args: args, scanner: scanner)
        case "search":
            return try await executeSearch(args: args, scanner: scanner)
        case "time":
            return try await executeTime(args: args, scanner: scanner)
        default:
            return errorResponse(message: "Unknown op '\(op)'. Valid ops: list_sessions, search, time")
        }
    }

    // MARK: - list_sessions

    private static func executeListSessions(
        args: [String: Any],
        scanner: HistorySessionScanning
    ) async throws -> [String: Any] {
        let workspaceFilter = args["workspace"] as? String
        let agentKindFilter = args["agent_kind"] as? String
        let modelFilter = args["model"] as? String
        let filePathFilter = args["touched_file"] as? String
        let dateFrom = parseDateBound(args["date_from"], isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"], isUpperBound: true)
        let sortRaw = args["sort"] as? String ?? "last_activity"
        guard ["last_activity", "duration", "turn_count"].contains(sortRaw) else {
            return errorResponse(message: "Invalid 'sort' value '\(sortRaw)'. Valid values: last_activity, duration, turn_count")
        }
        let limit = clampLimit(args["limit"], default: 30, max: 100)

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: workspaceFilter,
            agentKind: agentKindFilter,
            model: modelFilter,
            filePath: filePathFilter,
            from: dateFrom,
            to: dateTo
        )

        let sorted = sortFilteredSessions(filtered, by: sortRaw)
        let truncated = sorted.count > limit
        let sliced = Array(sorted.prefix(limit))

        let dateFormatter = ISO8601DateFormatter()
        let sessions: [[String: Any]] = sliced.map { session in
            let r = session.record
            var dict: [String: Any] = [
                "session_id": r.id.uuidString,
                "session_name": r.name,
                "workspace_name": session.workspaceName,
                "first_activity_at": dateFormatter.string(from: r.firstActivityAt ?? r.activityDate),
                "last_activity_at": dateFormatter.string(from: r.lastActivityAt ?? r.savedAt),
                "active_duration_seconds": r.activeDurationSeconds,
                "turn_count": r.itemCount,
                "tool_call_count": r.toolCallCount,
                "files_touched": Array(r.keyPaths).sorted(),
                "had_errors": r.hasUnknownConversationContent
            ]
            if let agentKindRaw = r.agentKindRaw { dict["agent_kind"] = agentKindRaw }
            if let agentModelRaw = r.agentModelRaw { dict["agent_model"] = agentModelRaw }
            if let lastRunStateRaw = r.lastRunStateRaw { dict["last_run_state"] = lastRunStateRaw }
            return dict
        }

        return [
            "total_sessions": sorted.count,
            "truncated": truncated,
            "sessions": sessions
        ]
    }

    // MARK: - search

    private static func executeSearch(
        args: [String: Any],
        scanner: HistorySessionScanning
    ) async throws -> [String: Any] {
        guard let rawQuery = args["query"] as? String,
              !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return errorResponse(message: "Missing or empty required parameter 'query'")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspaceFilter = args["workspace"] as? String
        let sessionIDFilter = args["session_id"] as? String
        let sourceFilter = args["source"] as? String ?? "all"
        guard ["activities", "summaries", "all"].contains(sourceFilter) else {
            return errorResponse(message: "Invalid 'source' value '\(sourceFilter)'. Valid values: activities, summaries, all")
        }
        let dateFrom = parseDateBound(args["date_from"], isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"], isUpperBound: true)
        let limit = clampLimit(args["limit"], default: 20, max: 100)

        let scanResults = try await scanner.scanAllWorkspaces()

        // If session_id filter is provided but invalid, return an error instead of silently broadening scope.
        if let sessionIDFilter, UUID(uuidString: sessionIDFilter) == nil {
            return errorResponse(message: "Invalid session_id: expected UUID format")
        }

        // Scope to that session across all workspaces.
        let filtered: [HistoryFilteredSessionRecord] = if let sessionIDFilter, let uuid = UUID(uuidString: sessionIDFilter) {
            scanner.sessionsMatchingFilters(
                scanResults,
                workspace: workspaceFilter,
                agentKind: nil,
                model: nil,
                filePath: nil,
                from: dateFrom,
                to: dateTo
            ).filter { $0.record.id == uuid }
        } else {
            scanner.sessionsMatchingFilters(
                scanResults,
                workspace: workspaceFilter,
                agentKind: nil,
                model: nil,
                filePath: nil,
                from: dateFrom,
                to: dateTo
            )
        }

        let queryLower = query.lowercased()
        var allMatches: [HistorySearchMatch] = []

        for session in filtered {
            let transcript: AgentTranscript
            do {
                transcript = try await scanner.loadTranscriptForSearch(
                    sessionID: session.record.id,
                    workspaceDir: session.workspaceDir
                )
            } catch {
                // Skip sessions whose transcripts can't be loaded.
                continue
            }

            for (turnIndex, turn) in transcript.turns.enumerated() {
                var turnMatches: [HistorySearchMatch] = []

                // Search activity text (only if turn is not structurally compacted, or source=all/activities).
                if sourceFilter != "summaries" {
                    if !turn.isStructurallyCompacted || sourceFilter == "all" {
                        for activity in turn.allActivities {
                            if activity.text.lowercased().contains(queryLower) {
                                let snippet = extractSnippet(text: activity.text, query: queryLower)
                                let roleString = mapActivityRole(activity.role)
                                let match = HistorySearchMatch(
                                    sessionID: session.record.id,
                                    sessionName: session.record.name,
                                    workspaceName: session.workspaceName,
                                    turnIndex: turnIndex,
                                    role: roleString,
                                    timestamp: activity.timestamp,
                                    snippet: snippet,
                                    source: "activity",
                                    turnRequestText: turn.request?.text
                                )
                                turnMatches.append(match)
                                break // One match per activity is sufficient for dedup base.
                            }
                        }
                    }
                }

                // Search summary text fields. conclusionText is the full (non-truncated)
                // conclusion and is preferred when available (full/condensed tiers).
                // compactConclusionText is the truncated fallback for summary/archived tiers
                // where conclusionText is nilled out during compaction.
                if sourceFilter != "activities", let summary = turn.summary {
                    let conclusionText = summary.conclusionText ?? summary.compactConclusionText
                    let summaryTexts: [(String, String)] = [
                        (conclusionText ?? "", "conclusion"),
                        (summary.middleSummaryText ?? "", "middleSummaryText"),
                        (summary.requestText ?? "", "requestText")
                    ]

                    for (text, field) in summaryTexts where !text.isEmpty {
                        if text.lowercased().contains(queryLower) {
                            let snippet = extractSnippet(text: text, query: queryLower)
                            let roleString = field == "requestText" ? "user" : "assistant"
                            let timestamp = turn.startedAt
                            let match = HistorySearchMatch(
                                sessionID: session.record.id,
                                sessionName: session.record.name,
                                workspaceName: session.workspaceName,
                                turnIndex: turnIndex,
                                role: roleString,
                                timestamp: timestamp,
                                snippet: snippet,
                                source: "summary",
                                turnRequestText: turn.request?.text
                            )
                            turnMatches.append(match)
                            break // One match per summary is sufficient.
                        }
                    }
                }

                // Dedup: if both activity and summary matched for this turn, keep only activity.
                if turnMatches.count > 1 {
                    let activityMatch = turnMatches.first { $0.source == "activity" }
                    if let activityMatch {
                        allMatches.append(activityMatch)
                    } else {
                        allMatches.append(turnMatches[0])
                    }
                } else if let only = turnMatches.first {
                    allMatches.append(only)
                }
            }
        }

        // Sort matches by timestamp descending.
        allMatches.sort { $0.timestamp > $1.timestamp }

        let truncated = allMatches.count > limit
        let sliced = Array(allMatches.prefix(limit))

        let dateformatter = ISO8601DateFormatter()
        let results: [[String: Any]] = sliced.map { match in
            var dict: [String: Any] = [
                "session_id": match.sessionID.uuidString,
                "session_name": match.sessionName,
                "workspace_name": match.workspaceName,
                "turn_index": match.turnIndex,
                "role": match.role,
                "timestamp": dateformatter.string(from: match.timestamp),
                "snippet": match.snippet,
                "source": match.source
            ]
            if let turnRequestText = match.turnRequestText { dict["turn_request_text"] = turnRequestText }
            return dict
        }

        return [
            "total_matches": allMatches.count,
            "truncated": truncated,
            "results": results
        ]
    }

    // MARK: - time

    private static func executeTime(
        args: [String: Any],
        scanner: HistorySessionScanning
    ) async throws -> [String: Any] {
        guard let groupBy = args["group_by"] as? String, !groupBy.isEmpty else {
            return errorResponse(message: "Missing or empty required parameter 'group_by'")
        }

        let validGroupBys: Set = ["day", "week", "month", "session", "workspace"]
        guard validGroupBys.contains(groupBy) else {
            return errorResponse(message: "Invalid 'group_by' value '\(groupBy)'. Valid values: day, week, month, session, workspace")
        }

        let workspaceFilter = args["workspace"] as? String
        let sessionIDFilter = args["session_id"] as? String
        let dateFrom = parseDateBound(args["date_from"], isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"], isUpperBound: true)
        let includeDetails = args["include_details"] as? Bool ?? false

        let scanResults = try await scanner.scanAllWorkspaces()

        // If session_id filter is provided but invalid, return an error instead of silently broadening scope.
        if let sessionIDFilter, UUID(uuidString: sessionIDFilter) == nil {
            return errorResponse(message: "Invalid session_id: expected UUID format")
        }

        // Scope to that session.
        let filtered: [HistoryFilteredSessionRecord] = if let sessionIDFilter, let uuid = UUID(uuidString: sessionIDFilter) {
            scanner.sessionsMatchingFilters(
                scanResults,
                workspace: workspaceFilter,
                agentKind: nil,
                model: nil,
                filePath: nil,
                from: dateFrom,
                to: dateTo
            ).filter { $0.record.id == uuid }
        } else {
            scanner.sessionsMatchingFilters(
                scanResults,
                workspace: workspaceFilter,
                agentKind: nil,
                model: nil,
                filePath: nil,
                from: dateFrom,
                to: dateTo
            )
        }

        let totalSessions = filtered.count
        let totalDuration = filtered.reduce(0) { $0 + $1.record.activeDurationSeconds }

        let groups = groupSessions(filtered, by: groupBy, includeDetails: includeDetails)

        return [
            "total_sessions": totalSessions,
            "total_active_duration_seconds": totalDuration,
            "truncated": false, // time has no limit parameter; no truncation in v1
            "groups": groups
        ]
    }

    // MARK: - Sorting

    private static func sortFilteredSessions(
        _ sessions: [HistoryFilteredSessionRecord],
        by sortRaw: String
    ) -> [HistoryFilteredSessionRecord] {
        switch sortRaw {
        case "duration":
            sessions.sorted { $0.record.activeDurationSeconds > $1.record.activeDurationSeconds }
        case "turn_count":
            sessions.sorted { $0.record.itemCount > $1.record.itemCount }
        case "last_activity":
            fallthrough
        default:
            sessions.sorted {
                ($0.record.lastActivityAt ?? $0.record.activityDate) > ($1.record.lastActivityAt ?? $1.record.activityDate)
            }
        }
    }

    // MARK: - Grouping

    private static func groupSessions(
        _ sessions: [HistoryFilteredSessionRecord],
        by groupBy: String,
        includeDetails: Bool
    ) -> [[String: Any]] {
        let calendar = Calendar.current

        switch groupBy {
        case "day":
            return groupByCalendarComponent(sessions, calendar: calendar, component: .day, includeDetails: includeDetails) { date in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                return formatter.string(from: date)
            }
        case "week":
            return groupByCalendarComponent(sessions, calendar: calendar, component: .weekOfYear, includeDetails: includeDetails) { date in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                // Use the start of the week as the key.
                guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) else {
                    return formatter.string(from: date)
                }
                return formatter.string(from: weekStart)
            }
        case "month":
            return groupByCalendarComponent(sessions, calendar: calendar, component: .month, includeDetails: includeDetails) { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM"
                return formatter.string(from: date)
            }
        case "session":
            return sessions.map { session in
                var group: [String: Any] = [
                    "key": session.record.id.uuidString,
                    "sessions": 1,
                    "active_duration_seconds": session.record.activeDurationSeconds,
                    "turn_count": session.record.itemCount,
                    "tool_call_count": session.record.toolCallCount
                ]
                if includeDetails {
                    group["details"] = [[
                        "session_id": session.record.id.uuidString,
                        "session_name": session.record.name,
                        "active_duration_seconds": session.record.activeDurationSeconds,
                        "turn_count": session.record.itemCount
                    ]]
                }
                return group
            }
        case "workspace":
            return groupByWorkspace(sessions, includeDetails: includeDetails)
        default:
            return []
        }
    }

    private static func groupByCalendarComponent(
        _ sessions: [HistoryFilteredSessionRecord],
        calendar: Calendar,
        component: Calendar.Component,
        includeDetails: Bool,
        keyFormatter: (Date) -> String
    ) -> [[String: Any]] {
        // Group sessions by the calendar component derived from their activityDate.
        var grouped: [String: [HistoryFilteredSessionRecord]] = [:]
        for session in sessions {
            let key = keyFormatter(session.record.activityDate)
            grouped[key, default: []].append(session)
        }

        // Sort groups by key descending.
        let sortedKeys = grouped.keys.sorted().reversed()

        return sortedKeys.map { key in
            let sessionsInGroup = grouped[key]!
            let totalDuration = sessionsInGroup.reduce(0) { $0 + $1.record.activeDurationSeconds }
            let totalTurns = sessionsInGroup.reduce(0) { $0 + $1.record.itemCount }
            let totalToolCalls = sessionsInGroup.reduce(0) { $0 + $1.record.toolCallCount }

            var group: [String: Any] = [
                "key": key,
                "sessions": sessionsInGroup.count,
                "active_duration_seconds": totalDuration,
                "turn_count": totalTurns,
                "tool_call_count": totalToolCalls
            ]
            if includeDetails {
                group["details"] = sessionsInGroup.map { s in
                    [
                        "session_id": s.record.id.uuidString,
                        "session_name": s.record.name,
                        "active_duration_seconds": s.record.activeDurationSeconds,
                        "turn_count": s.record.itemCount
                    ]
                }
            }
            return group
        }
    }

    private static func groupByWorkspace(
        _ sessions: [HistoryFilteredSessionRecord],
        includeDetails: Bool
    ) -> [[String: Any]] {
        var grouped: [String: [HistoryFilteredSessionRecord]] = [:]
        for session in sessions {
            grouped[session.workspaceName, default: []].append(session)
        }

        let sortedKeys = grouped.keys.sorted()

        return sortedKeys.map { key in
            let sessionsInGroup = grouped[key]!
            let totalDuration = sessionsInGroup.reduce(0) { $0 + $1.record.activeDurationSeconds }
            let totalTurns = sessionsInGroup.reduce(0) { $0 + $1.record.itemCount }
            let totalToolCalls = sessionsInGroup.reduce(0) { $0 + $1.record.toolCallCount }

            var group: [String: Any] = [
                "key": key,
                "sessions": sessionsInGroup.count,
                "active_duration_seconds": totalDuration,
                "turn_count": totalTurns,
                "tool_call_count": totalToolCalls
            ]
            if includeDetails {
                group["details"] = sessionsInGroup.map { s in
                    [
                        "session_id": s.record.id.uuidString,
                        "session_name": s.record.name,
                        "active_duration_seconds": s.record.activeDurationSeconds,
                        "turn_count": s.record.itemCount
                    ]
                }
            }
            return group
        }
    }

    // MARK: - Snippet Extraction

    /// Extract a ~200-char snippet centered on the first occurrence of the query in text.
    /// Clamps to string bounds. Returns the full text if the text is short.
    static func extractSnippet(text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive)
        else {
            // Fallback: return prefix of text.
            let end = text.index(text.startIndex, offsetBy: min(200, text.count), limitedBy: text.endIndex) ?? text.endIndex
            return String(text[..<end])
        }

        let matchLower = range.lowerBound
        let matchUpper = range.upperBound

        // Take ±100 chars around the match.
        let contextRadius = 100
        let snippetStart = text.index(matchLower, offsetBy: -contextRadius, limitedBy: text.startIndex) ?? text.startIndex
        let snippetEnd = text.index(matchUpper, offsetBy: contextRadius, limitedBy: text.endIndex) ?? text.endIndex

        return String(text[snippetStart ..< snippetEnd])
    }

    // MARK: - Role Mapping

    /// Map an ``AgentTranscriptActivityRole`` to a user-facing role string for the search response.
    static func mapActivityRole(_ role: AgentTranscriptActivityRole) -> String {
        switch role {
        case .assistant, .thinking:
            "assistant"
        case .toolExecution:
            "tool"
        case .progress, .note, .system, .error:
            "system"
        }
    }

    // MARK: - Helpers

    static func parseDate(_ value: Any?) -> Date? {
        parseDateBound(value, isUpperBound: false)
    }

    /// Parse a date bound. ISO 8601 datetime values use the exact instant. Date-only
    /// values (e.g. `"2026-01-15"`) resolve to **start-of-day** (`00:00:00 UTC`) for
    /// lower bounds and **end-of-day** (`23:59:59 UTC`) for upper bounds, so `date_to`
    /// is inclusive of the named day rather than excluding it.
    static func parseDateBound(_ value: Any?, isUpperBound: Bool) -> Date? {
        guard let stringValue = value as? String, !stringValue.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stringValue) {
            return date
        }
        // Try without fractional seconds.
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: stringValue) {
            return date
        }
        // Date-only format (e.g. "2026-01-15"). Lower bound = start of day; upper bound
        // = end of day so the named day is included.
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let midnight = dateOnlyFormatter.date(from: stringValue) else { return nil }
        return isUpperBound ? midnight.addingTimeInterval(86399) : midnight
    }

    static func clampLimit(_ value: Any?, default defaultValue: Int, max maxValue: Int) -> Int {
        guard let intValue = value as? Int else { return defaultValue }
        return max(1, min(intValue, maxValue))
    }

    private static func errorResponse(message: String) -> [String: Any] {
        ["error": message]
    }

    // MARK: - Search Match

    private struct HistorySearchMatch {
        let sessionID: UUID
        let sessionName: String
        let workspaceName: String
        let turnIndex: Int
        let role: String
        let timestamp: Date
        let snippet: String
        let source: String
        let turnRequestText: String?
    }
}
