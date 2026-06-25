import Foundation
import MCP

/// Dispatches the `history` MCP tool operations (`list_sessions`, `search`, `time`)
/// against the cross-workspace session scanner.
///
/// Each operation returns a typed ``HistoryToolReply`` (a `Codable & Sendable` reply
/// DTO, or an error DTO). The provider encodes the reply to an MCP `Value` via
/// `Value(dto)`, matching the sibling window-tool providers — no `[String: Any]`
/// bridge is involved.
enum HistoryMCPToolService {
    // MARK: - Public Entry Point

    /// Execute a `history` tool operation.
    /// - Parameters:
    ///   - args: The MCP tool arguments (`[String: Value]`). Must contain `"op"`.
    ///   - scanner: A ``HistorySessionScanning`` conformant object for data access.
    /// - Returns: A typed ``HistoryToolReply``. Scanner faults propagate via `throws`;
    ///   argument validation failures surface as a `.error` reply (preserving the tool's
    ///   "return a result with an `error` field" contract rather than throwing).
    static func execute(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        guard let op = args["op"]?.stringValue, !op.isEmpty else {
            return .error(HistoryErrorReply(error: "Missing or empty required parameter 'op'"))
        }

        switch op {
        case "list_sessions":
            return try await executeListSessions(args: args, scanner: scanner)
        case "search":
            return try await executeSearch(args: args, scanner: scanner)
        case "time":
            return try await executeTime(args: args, scanner: scanner)
        default:
            return .error(HistoryErrorReply(error: "Unknown op '\(op)'. Valid ops: list_sessions, search, time"))
        }
    }

    // MARK: - list_sessions

    private static func executeListSessions(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        let workspaceFilter = args["workspace"]?.stringValue
        let agentKindFilter = args["agent_kind"]?.stringValue
        let modelFilter = args["model"]?.stringValue
        let filePathFilter = args["touched_file"]?.stringValue
        let dateFrom = parseDateBound(args["date_from"]?.stringValue, isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"]?.stringValue, isUpperBound: true)
        let sortRaw = args["sort"]?.stringValue ?? "last_activity"
        guard ["last_activity", "duration", "turn_count"].contains(sortRaw) else {
            return .error(HistoryErrorReply(error: "Invalid 'sort' value '\(sortRaw)'. Valid values: last_activity, duration, turn_count"))
        }
        let limit = clampLimit(args["limit"]?.intValue, default: 30, max: 100)

        do {
            let idleThresholdMinutes = try resolveIdleThreshold(args["idle_threshold_minutes"])
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

            let sorted = sortFilteredSessions(filtered, by: sortRaw, idleThresholdMinutes: idleThresholdMinutes)
            let truncated = sorted.count > limit
            let sliced = Array(sorted.prefix(limit))

            let sessions: [HistoryListSessionsReply.SessionDTO] = sliced.map { session in
                let r = session.record
                return HistoryListSessionsReply.SessionDTO(
                    sessionID: r.id.uuidString,
                    sessionName: r.name,
                    workspaceName: session.workspaceName,
                    firstActivityAt: iso8601DateTime.string(from: r.firstActivityAt ?? r.activityDate),
                    lastActivityAt: iso8601DateTime.string(from: r.lastActivityAt ?? r.savedAt),
                    activeDurationSeconds: r.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes),
                    turnCount: r.itemCount,
                    toolCallCount: r.toolCallCount,
                    filesTouched: Array(r.keyPaths).sorted(),
                    hadErrors: r.hasUnknownConversationContent,
                    agentKind: r.agentKindRaw,
                    agentModel: r.agentModelRaw,
                    lastRunState: r.lastRunStateRaw
                )
            }

            return .listSessions(HistoryListSessionsReply(
                totalSessions: sorted.count,
                truncated: truncated,
                sessions: sessions
            ))
        } catch let error as HistoryValidationError {
            return .error(HistoryErrorReply(error: error.message))
        }
    }

    // MARK: - search

    /// Hard cap on the number of session transcripts the `search` op will decode and
    /// scan. `limit` caps matches, not work; without this, a broad query forces a full
    /// `AgentSession` decode across every filtered session. When the cap is hit,
    /// `scan_truncated` is surfaced in the reply.
    private static let maxSessionsScanned = 200

    private static func executeSearch(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        guard let rawQuery = args["query"]?.stringValue,
              !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .error(HistoryErrorReply(error: "Missing or empty required parameter 'query'"))
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspaceFilter = args["workspace"]?.stringValue
        let sessionIDFilter = args["session_id"]?.stringValue
        let sourceFilter = args["source"]?.stringValue ?? "all"
        guard ["activities", "summaries", "all"].contains(sourceFilter) else {
            return .error(HistoryErrorReply(error: "Invalid 'source' value '\(sourceFilter)'. Valid values: activities, summaries, all"))
        }
        let dateFrom = parseDateBound(args["date_from"]?.stringValue, isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"]?.stringValue, isUpperBound: true)
        let limit = clampLimit(args["limit"]?.intValue, default: 20, max: 100)

        let scanResults = try await scanner.scanAllWorkspaces()

        let filtered: [HistoryFilteredSessionRecord]
        do {
            filtered = try resolveScopedSessions(
                scanResults: scanResults,
                scanner: scanner,
                workspace: workspaceFilter,
                sessionID: sessionIDFilter,
                from: dateFrom,
                to: dateTo
            )
        } catch let error as HistoryValidationError {
            return .error(HistoryErrorReply(error: error.message))
        }

        let queryLower = query.lowercased()
        var allMatches: [HistorySearchMatch] = []
        var sessionsScanned = 0
        var scanTruncated = false

        for session in filtered {
            if sessionsScanned >= maxSessionsScanned {
                scanTruncated = true
                break
            }
            sessionsScanned += 1

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

        let results: [HistorySearchReply.MatchDTO] = sliced.map { match in
            HistorySearchReply.MatchDTO(
                sessionID: match.sessionID.uuidString,
                sessionName: match.sessionName,
                workspaceName: match.workspaceName,
                turnIndex: match.turnIndex,
                role: match.role,
                timestamp: iso8601DateTime.string(from: match.timestamp),
                snippet: match.snippet,
                source: match.source,
                turnRequestText: match.turnRequestText
            )
        }

        return .search(HistorySearchReply(
            totalMatches: allMatches.count,
            truncated: truncated,
            scanTruncated: scanTruncated,
            results: results
        ))
    }

    // MARK: - time

    private static func executeTime(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        guard let groupBy = args["group_by"]?.stringValue, !groupBy.isEmpty else {
            return .error(HistoryErrorReply(error: "Missing or empty required parameter 'group_by'"))
        }

        let validGroupBys: Set = ["day", "week", "month", "session", "workspace"]
        guard validGroupBys.contains(groupBy) else {
            return .error(HistoryErrorReply(error: "Invalid 'group_by' value '\(groupBy)'. Valid values: day, week, month, session, workspace"))
        }

        let workspaceFilter = args["workspace"]?.stringValue
        let sessionIDFilter = args["session_id"]?.stringValue
        let dateFrom = parseDateBound(args["date_from"]?.stringValue, isUpperBound: false)
        let dateTo = parseDateBound(args["date_to"]?.stringValue, isUpperBound: true)
        let includeDetails = args["include_details"]?.boolValue ?? false

        let scanResults = try await scanner.scanAllWorkspaces()

        do {
            let filtered = try resolveScopedSessions(
                scanResults: scanResults,
                scanner: scanner,
                workspace: workspaceFilter,
                sessionID: sessionIDFilter,
                from: dateFrom,
                to: dateTo
            )
            let idleThresholdMinutes = try resolveIdleThreshold(args["idle_threshold_minutes"])
            let totalSessions = filtered.count
            let totalDuration = filtered.reduce(0) { $0 + $1.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes) }

            let groups = groupSessions(filtered, by: groupBy, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)

            return .time(HistoryTimeReply(
                totalSessions: totalSessions,
                totalActiveDurationSeconds: totalDuration,
                truncated: false, // time has no limit parameter; no truncation in v1
                groups: groups
            ))
        } catch let error as HistoryValidationError {
            return .error(HistoryErrorReply(error: error.message))
        }
    }

    // MARK: - Scoped Session Resolution

    /// Resolve the filtered session set shared by `search` and `time`: apply the
    /// workspace/date scope, and — when `sessionID` is given — validate it is a UUID and
    /// narrow to that one session across all workspaces. Throws a validation error when
    /// `sessionID` is supplied but malformed, so the caller surfaces it instead of
    /// silently broadening the scope.
    private static func resolveScopedSessions(
        scanResults: [HistoryWorkspaceScanResult],
        scanner: HistorySessionScanning,
        workspace: String?,
        sessionID: String?,
        from: Date?,
        to: Date?
    ) throws -> [HistoryFilteredSessionRecord] {
        if let sessionID, UUID(uuidString: sessionID) == nil {
            throw HistoryValidationError(message: "Invalid session_id: expected UUID format")
        }
        let matched = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: workspace,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: from,
            to: to
        )
        if let sessionID, let uuid = UUID(uuidString: sessionID) {
            return matched.filter { $0.record.id == uuid }
        }
        return matched
    }

    // MARK: - Sorting

    private static func sortFilteredSessions(
        _ sessions: [HistoryFilteredSessionRecord],
        by sortRaw: String,
        idleThresholdMinutes: Int
    ) -> [HistoryFilteredSessionRecord] {
        switch sortRaw {
        case "duration":
            sessions.sorted { $0.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes) > $1.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes) }
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
        includeDetails: Bool,
        idleThresholdMinutes: Int
    ) -> [HistoryTimeReply.GroupDTO] {
        let calendar = Calendar.current

        switch groupBy {
        case "day":
            return buildGroups(sessions, keyProvider: { iso8601DateOnly.string(from: $0.record.activityDate) }, sortKeys: { $0.sort(by: >) }, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)
        case "week":
            return buildGroups(
                sessions,
                keyProvider: { session in
                    let activityDate = session.record.activityDate
                    guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: activityDate)) else {
                        return iso8601DateOnly.string(from: activityDate)
                    }
                    return iso8601DateOnly.string(from: weekStart)
                },
                sortKeys: { $0.sort(by: >) },
                includeDetails: includeDetails,
                idleThresholdMinutes: idleThresholdMinutes
            )
        case "month":
            return buildGroups(
                sessions,
                keyProvider: { session in
                    let components = calendar.dateComponents([.year, .month], from: session.record.activityDate)
                    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
                },
                sortKeys: { $0.sort(by: >) },
                includeDetails: includeDetails,
                idleThresholdMinutes: idleThresholdMinutes
            )
        case "session":
            return buildGroups(sessions, keyProvider: { $0.record.id.uuidString }, sortKeys: nil, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)
        case "workspace":
            return buildGroups(sessions, keyProvider: { $0.workspaceName }, sortKeys: { $0.sort() }, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)
        default:
            return []
        }
    }

    /// Build group DTOs from sessions by a derived key. Unifies the three former
    /// `[[String: Any]]` builders (calendar component / session / workspace), which
    /// differed only in key derivation and sort direction. Keys preserve first-
    /// occurrence insertion order unless `sortKeys` reorders them (descending for
    /// calendar groups, ascending for workspace, untouched for per-session).
    private static func buildGroups(
        _ sessions: [HistoryFilteredSessionRecord],
        keyProvider: (HistoryFilteredSessionRecord) -> String,
        sortKeys: ((inout [String]) -> Void)?,
        includeDetails: Bool,
        idleThresholdMinutes: Int
    ) -> [HistoryTimeReply.GroupDTO] {
        var orderedKeys: [String] = []
        var grouped: [String: [HistoryFilteredSessionRecord]] = [:]
        for session in sessions {
            let key = keyProvider(session)
            if grouped[key] == nil { orderedKeys.append(key) }
            grouped[key, default: []].append(session)
        }
        if let sortKeys { sortKeys(&orderedKeys) }

        return orderedKeys.map { key in
            let sessionsInGroup = grouped[key]!
            let totalDuration = sessionsInGroup.reduce(0) { $0 + $1.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes) }
            let totalTurns = sessionsInGroup.reduce(0) { $0 + $1.record.itemCount }
            let totalToolCalls = sessionsInGroup.reduce(0) { $0 + $1.record.toolCallCount }

            return HistoryTimeReply.GroupDTO(
                key: key,
                sessions: sessionsInGroup.count,
                activeDurationSeconds: totalDuration,
                turnCount: totalTurns,
                toolCallCount: totalToolCalls,
                details: includeDetails
                    ? sessionsInGroup.map { s in
                        HistoryTimeReply.GroupDTO.DetailDTO(
                            sessionID: s.record.id.uuidString,
                            sessionName: s.record.name,
                            activeDurationSeconds: s.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes),
                            turnCount: s.record.itemCount
                        )
                    }
                    : nil
            )
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

    /// Parse a date bound. ISO 8601 datetime values use the exact instant. Date-only
    /// values (e.g. `"2026-01-15"`) resolve to **start-of-day** (`00:00:00 UTC`) for
    /// lower bounds and **end-of-day** (`23:59:59 UTC`) for upper bounds, so `date_to`
    /// is inclusive of the named day rather than excluding it.
    static func parseDateBound(_ value: String?, isUpperBound: Bool) -> Date? {
        guard let stringValue = value, !stringValue.isEmpty else { return nil }
        if let date = iso8601WithFractionalSeconds.date(from: stringValue) {
            return date
        }
        if let date = iso8601DateTime.date(from: stringValue) {
            return date
        }
        // Date-only format (e.g. "2026-01-15"). Lower bound = start of day; upper bound
        // = end of day so the named day is included.
        guard let midnight = iso8601DateOnly.date(from: stringValue) else { return nil }
        return isUpperBound ? midnight.addingTimeInterval(86399) : midnight
    }

    static func clampLimit(_ value: Int?, default defaultValue: Int, max maxValue: Int) -> Int {
        guard let intValue = value else { return defaultValue }
        return max(1, min(intValue, maxValue))
    }

    /// Resolve `idle_threshold_minutes` to a validated threshold. Omitted/null uses
    /// `AgentSessionMetadataRecord.defaultIdleThresholdMinutes`; out-of-range or
    /// non-integer values throw a validation error (no clamping). Callers map the thrown
    /// error to an error reply.
    static func resolveIdleThreshold(_ value: Value?) throws -> Int {
        let defaultThreshold = AgentSessionMetadataRecord.defaultIdleThresholdMinutes
        guard let value else { return defaultThreshold }
        guard let intValue = value.intValue else {
            throw HistoryValidationError(message: "idle_threshold_minutes must be an integer")
        }
        guard (0 ... 1440).contains(intValue) else {
            throw HistoryValidationError(message: "idle_threshold_minutes must be between 0 and 1440")
        }
        return intValue
    }

    // MARK: - Shared Formatters

    /// ISO 8601 datetime with fractional seconds (for parsing inputs that include them).
    /// `ISO8601DateFormatter` is thread-safe, so these are safe to share across
    /// concurrent tool invocations (unlike `DateFormatter`).
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ISO 8601 datetime without fractional seconds — used both to parse inputs and to
    /// render response timestamps (`first_activity_at`, `last_activity_at`, `timestamp`).
    private static let iso8601DateTime = ISO8601DateFormatter()

    /// ISO 8601 full date (`yyyy-MM-dd`) — used to parse date-only bounds and to render
    /// day/week group keys.
    private static let iso8601DateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    // MARK: - Validation Error

    private struct HistoryValidationError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    // MARK: - Search Match (intermediate)

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
