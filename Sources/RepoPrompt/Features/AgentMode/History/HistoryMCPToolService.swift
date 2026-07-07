import Foundation
import MCP

/// Dispatches the `history` MCP tool operations (`list_sessions`, `search`, `time`,
/// `get_session`)
/// against the cross-workspace session scanner.
///
/// Each operation returns a typed ``HistoryToolReply`` (a `Codable & Sendable` reply
/// DTO, or an error DTO). The provider encodes the reply to an MCP `Value` via
/// `Value(dto)`, matching the sibling window-tool providers — no `[String: Any]`
/// bridge is involved.
enum HistoryMCPToolService {
    /// UserDefaults key shared with GlobalSettingsStore.setHistoryIdleThresholdMinutes.
    static let idleThresholdSettingsKey = "history.idle_threshold_minutes"
    private static let maxFilesTouchedPerListedSession = 20
    private static let maxGetSessionEntriesPerTurn = 20

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

        do {
            switch op {
            case "list_sessions":
                return try await executeListSessions(args: args, scanner: scanner)
            case "search":
                return try await executeSearch(args: args, scanner: scanner)
            case "time":
                return try await executeTime(args: args, scanner: scanner)
            case "get_session":
                return try await executeGetSession(args: args, scanner: scanner)
            default:
                return .error(HistoryErrorReply(error: "Unknown op '\(op)'. Valid ops: list_sessions, search, time, get_session"))
            }
        } catch let error as HistoryValidationError {
            return .error(HistoryErrorReply(error: error.message))
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
        let dateFrom = try parseValidatedDateBound(args["date_from"]?.stringValue, parameterName: "date_from", isUpperBound: false)
        let dateTo = try parseValidatedDateBound(args["date_to"]?.stringValue, parameterName: "date_to", isUpperBound: true)
        let sortRaw = args["sort"]?.stringValue ?? "last_activity"
        guard ["last_activity", "duration", "turn_count"].contains(sortRaw) else {
            return .error(HistoryErrorReply(error: "Invalid 'sort' value '\(sortRaw)'. Valid values: last_activity, duration, turn_count"))
        }
        let limit = clampLimit(args["limit"]?.intValue, default: 30, max: 100)

        let idleThresholdMinutes = try resolveIdleThreshold(args["idle_threshold_minutes"])
        let maxSessionsScanned = try resolveMaxSessionsScanned(args["max_sessions_scanned"])
        let scanResults = try await scanner.scanAllWorkspaces()
        let skippedWorkspaces = scanDiagnostics(from: scanResults)
        let filtered = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: workspaceFilter,
            agentKind: agentKindFilter,
            model: modelFilter,
            filePath: nil,
            from: dateFrom,
            to: dateTo
        )

        // Keep metadata filtering/sorting cheap, then hydrate only bounded candidates.
        // When touched_file is present, stub-rebuilt records may have empty keyPaths, so
        // the file filter is applied after bounded on-demand enrichment.
        var sorted = sortFilteredSessions(filtered, by: sortRaw == "duration" ? "last_activity" : sortRaw, idleThresholdMinutes: idleThresholdMinutes)
        let candidates = Array(sorted.prefix(maxSessionsScanned))
        let sessionsScanned = candidates.count
        let scanTruncated = sorted.count > candidates.count
        // list_sessions uses index-inventory durations (recomputeStale off): cheap, but
        // can lag `time` for sessions whose transcript grew post-save; `time` is the
        // live-transcript-authoritative duration.
        var hydrated = await Self.enrichingStubBuiltSessions(candidates, scanner: scanner)
        if sortRaw == "duration" {
            hydrated = sortFilteredSessions(hydrated, by: sortRaw, idleThresholdMinutes: idleThresholdMinutes)
        }
        let totalSessions: Int
        if let filePathFilter {
            hydrated = hydrated.filter { session in
                session.record.keyPaths.contains { historyPath($0, matches: filePathFilter) }
            }
            totalSessions = hydrated.count
        } else {
            totalSessions = filtered.count
        }
        sorted = hydrated
        let truncated = sorted.count > limit
        let sliced = Array(sorted.prefix(limit))

        let sessions: [HistoryListSessionsReply.SessionDTO] = sliced.map { session in
            let r = session.record
            let filesTouched = Array(r.keyPaths).sorted()
            let cappedFilesTouched = Array(filesTouched.prefix(maxFilesTouchedPerListedSession))
            return HistoryListSessionsReply.SessionDTO(
                sessionID: r.id.uuidString,
                sessionName: r.name,
                workspaceName: session.workspaceName,
                firstActivityAt: iso8601DateTime.string(from: r.firstActivityAt ?? r.activityDate),
                lastActivityAt: iso8601DateTime.string(from: r.lastActivityAt ?? r.savedAt),
                activeDurationSeconds: r.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes),
                // `turn_count` here is the projected visible item/row count (itemCount), not raw
                // transcript turns; `time` calendar groups and `get_session.total_turns` count
                // real turns. Kept as-is for `list_sessions` API stability (see spec).
                turnCount: r.itemCount,
                toolCallCount: r.toolCallCount,
                filesTouched: cappedFilesTouched,
                filesTouchedCount: filesTouched.count,
                hadErrors: r.hasUnknownConversationContent,
                agentKind: r.agentKindRaw,
                agentModel: r.agentModelRaw,
                lastRunState: r.lastRunStateRaw
            )
        }

        return .listSessions(HistoryListSessionsReply(
            totalSessions: totalSessions,
            truncated: truncated,
            sessionsScanned: sessionsScanned,
            scanTruncated: scanTruncated,
            skippedWorkspaces: nonEmptyDiagnostics(skippedWorkspaces),
            sessions: sessions
        ))
    }

    // MARK: - get_session

    private static func executeGetSession(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        guard let sessionIDRaw = args["session_id"]?.stringValue, !sessionIDRaw.isEmpty else {
            return .error(HistoryErrorReply(error: "Missing or empty required parameter 'session_id'"))
        }
        guard let sessionID = UUID(uuidString: sessionIDRaw) else {
            return .error(HistoryErrorReply(error: "Invalid session_id: expected UUID format"))
        }

        let maxChars = clampLimit(args["max_chars"]?.intValue, default: 6000, max: 20000)
        let contextTurns = clampGetSessionContextTurns(args["context_turns"]?.intValue)
        let roles = normalizedGetSessionRoles(args["roles"]?.arrayValue?.compactMap(\.stringValue))

        let scanResults = try await scanner.scanAllWorkspaces()
        func resolveSession(in results: [HistoryWorkspaceScanResult]) -> HistoryFilteredSessionRecord? {
            results.lazy.flatMap { scan in
                scan.records.map { record in
                    HistoryFilteredSessionRecord(
                        record: record,
                        workspaceName: scan.workspaceName,
                        workspaceDir: scan.workspaceDir
                    )
                }
            }.first(where: { $0.record.id == sessionID })
        }
        // F6: if the id isn't in the (possibly cached) inventory, force a fresh scan —
        // the session may have been saved since the TTL cache was populated.
        var session = resolveSession(in: scanResults)
        if session == nil {
            session = try await resolveSession(in: scanner.scanAllWorkspacesRefreshing())
        }
        guard let session else {
            return .error(HistoryErrorReply(error: "No history session found for session_id '\(sessionIDRaw)'"))
        }

        let transcript = try await scanner.loadTranscriptForSearch(
            sessionID: session.record.id,
            workspaceDir: session.workspaceDir
        )
        let totalTurns = transcript.turns.count
        guard totalTurns > 0 else {
            return .getSession(HistoryGetSessionReply(
                sessionID: session.record.id.uuidString,
                sessionName: session.record.name,
                workspaceName: session.workspaceName,
                totalTurns: 0,
                returnedTurnStart: 0,
                returnedTurnEnd: 0,
                truncated: false,
                turns: []
            ))
        }

        let requestedRange = try resolveGetSessionTurnRange(
            args: args,
            totalTurns: totalTurns,
            contextTurns: contextTurns
        )
        let targetTurnIndex = getSessionTargetTurnIndex(args: args, totalTurns: totalTurns)
        let indexedTurns = Array(transcript.turns.enumerated())
        let window = Array(indexedTurns[requestedRange])
        var remainingChars = getSessionContentBudget(maxChars: maxChars)
        var replyTruncated = requestedRange.count < totalTurns
        var renderedTurnsByIndex: [Int: HistoryGetSessionReply.TurnDTO] = [:]

        // Render outward from the target by distance (ties → lower index first) so a
        // budget-exhausted partial render is always contiguous around the target.
        // The prior target-first-then-ascending order could leave a gapped set like
        // {target, target-2}, making returned_turn_start/end bracket an unrendered hole.
        let budgetOrder = window.sorted { lhs, rhs in
            let lhsDist = abs(lhs.offset - targetTurnIndex)
            let rhsDist = abs(rhs.offset - targetTurnIndex)
            if lhsDist != rhsDist { return lhsDist < rhsDist }
            return lhs.offset < rhs.offset
        }

        for (turnIndex, turn) in budgetOrder {
            if remainingChars <= 0 {
                replyTruncated = true
                break
            }
            let rendered = renderGetSessionTurn(
                turn,
                turnIndex: turnIndex,
                roles: roles,
                remainingChars: &remainingChars
            )
            if rendered.truncated { replyTruncated = true }
            renderedTurnsByIndex[turnIndex] = rendered.dto
        }

        let turnDTOs = window.compactMap { renderedTurnsByIndex[$0.offset] }
        if turnDTOs.count < window.count { replyTruncated = true }
        let returnedTurnStart = turnDTOs.map(\.turnIndex).min() ?? requestedRange.lowerBound
        let returnedTurnEnd = turnDTOs.map(\.turnIndex).max() ?? requestedRange.lowerBound

        return .getSession(HistoryGetSessionReply(
            sessionID: session.record.id.uuidString,
            sessionName: session.record.name,
            workspaceName: session.workspaceName,
            totalTurns: totalTurns,
            returnedTurnStart: returnedTurnStart,
            returnedTurnEnd: returnedTurnEnd,
            truncated: replyTruncated,
            turns: turnDTOs
        ))
    }

    // MARK: - search

    /// Hard cap on the number of session transcripts the `search` op will decode and
    /// scan. `limit` caps matches, not work; without this, a broad query forces a full
    /// `AgentSession` decode across every filtered session. When the cap is hit,
    /// `scan_truncated` is surfaced in the reply.
    private static let defaultMaxSessionsScanned = 200
    private static let absoluteMaxSessionsScanned = 1000

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
        let dateFrom = try parseValidatedDateBound(args["date_from"]?.stringValue, parameterName: "date_from", isUpperBound: false)
        let dateTo = try parseValidatedDateBound(args["date_to"]?.stringValue, parameterName: "date_to", isUpperBound: true)
        let limit = clampLimit(args["limit"]?.intValue, default: 20, max: 100)
        let includeTurnRequestText = args["include_turn_request_text"]?.boolValue ?? false
        let maxSessionsScanned = try resolveMaxSessionsScanned(args["max_sessions_scanned"])

        let scanResults = try await scanner.scanAllWorkspaces()
        let skippedWorkspaces = scanDiagnostics(from: scanResults)

        let filtered = try resolveScopedSessions(
            scanResults: scanResults,
            scanner: scanner,
            workspace: workspaceFilter,
            sessionID: sessionIDFilter,
            from: dateFrom,
            to: dateTo
        )

        let queryLower = query.lowercased()
        var retainedMatches: [HistorySearchMatch] = []
        var totalMatches = 0
        var sessionsScanned = 0
        var scanTruncated = false

        let orderedSessions = sortFilteredSessions(filtered, by: "last_activity", idleThresholdMinutes: AgentSessionMetadataRecord.defaultIdleThresholdMinutes)
        for session in orderedSessions {
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

                // Search activity text. `source:"activities"` is the activity subset of
                // `source:"all"`, so both treat compacted turns identically (per spec a
                // compacted turn discards its activities, but any retained activity is
                // searchable under both filters — no carve-out that would make
                // `source:"activities"` narrower than the activity matches in `source:"all"`).
                if sourceFilter != "summaries" {
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
                        retainedMatches.append(activityMatch)
                    } else {
                        retainedMatches.append(turnMatches[0])
                    }
                } else if let only = turnMatches.first {
                    retainedMatches.append(only)
                }
            }
        }

        totalMatches = retainedMatches.count
        retainedMatches.sort { $0.timestamp > $1.timestamp }

        let truncated = totalMatches > limit
        let sliced = Array(retainedMatches.prefix(limit))

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
                turnRequestText: includeTurnRequestText ? clippedTurnRequestText(match.turnRequestText) : nil
            )
        }

        return .search(HistorySearchReply(
            totalMatches: totalMatches,
            truncated: truncated,
            scanTruncated: scanTruncated,
            sessionsScanned: sessionsScanned,
            skippedWorkspaces: nonEmptyDiagnostics(skippedWorkspaces),
            results: results
        ))
    }

    // MARK: - time

    private static func executeTime(
        args: [String: Value],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        guard let groupBy = args["group_by"]?.stringValue, !groupBy.isEmpty else {
            return .error(HistoryErrorReply(error: "Missing or empty required parameter 'group_by'. Valid values: day, week, month, session, workspace"))
        }

        let validGroupBys: Set = ["day", "week", "month", "session", "workspace"]
        guard validGroupBys.contains(groupBy) else {
            return .error(HistoryErrorReply(error: "Invalid 'group_by' value '\(groupBy)'. Valid values: day, week, month, session, workspace"))
        }

        let workspaceFilter = args["workspace"]?.stringValue
        let sessionIDFilter = args["session_id"]?.stringValue
        let dateFrom = try parseValidatedDateBound(args["date_from"]?.stringValue, parameterName: "date_from", isUpperBound: false)
        let dateTo = try parseValidatedDateBound(args["date_to"]?.stringValue, parameterName: "date_to", isUpperBound: true)
        let includeDetails = args["include_details"]?.boolValue ?? false
        let limit = clampLimit(args["limit"]?.intValue, default: 30, max: 100)
        let maxSessionsScanned = try resolveMaxSessionsScanned(args["max_sessions_scanned"])

        let scanResults = try await scanner.scanAllWorkspaces()
        let skippedWorkspaces = scanDiagnostics(from: scanResults)

        let filtered = try resolveScopedSessions(
            scanResults: scanResults,
            scanner: scanner,
            workspace: workspaceFilter,
            sessionID: sessionIDFilter,
            from: dateFrom,
            to: dateTo
        )
        let idleThresholdMinutes = try resolveIdleThreshold(args["idle_threshold_minutes"])

        // Calendar grouping (day/week/month) uses per-day attribution via transcript
        // loading — each turn's duration is attributed to the day it occurred, preventing
        // double counting across day-scoped queries. Session/workspace grouping stays
        // metadata-only (no per-day splitting needed).
        if ["day", "week", "month"].contains(groupBy) {
            return try await executeTimeCalendarGrouped(
                filtered,
                groupBy: groupBy,
                idleThresholdMinutes: idleThresholdMinutes,
                includeDetails: includeDetails,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxSessionsScanned: maxSessionsScanned,
                limit: limit,
                skippedWorkspaces: skippedWorkspaces,
                scanner: scanner
            )
        }

        // Non-calendar grouping reads stored duration; hydrate only a bounded candidate set.
        let candidates = Array(sortFilteredSessions(filtered, by: "last_activity", idleThresholdMinutes: idleThresholdMinutes).prefix(maxSessionsScanned))
        let sessionsScanned = candidates.count
        let scanTruncated = filtered.count > candidates.count
        // `recomputeStale` so group_by:session/workspace totals come from the live
        // transcript (matching the calendar path) instead of stale persisted primitives.
        let enriched = await Self.enrichingStubBuiltSessions(candidates, scanner: scanner, recomputeStale: true)
        // Report the full filtered count, matching the calendar path and list_sessions;
        // `sessionsScanned`/`scanTruncated` convey the bounded-scan semantic separately.
        let totalSessions = filtered.count
        let totalDuration = enriched.reduce(0) { $0 + $1.record.activeDurationSeconds(thresholdMinutes: idleThresholdMinutes) }

        let allGroups = groupSessions(enriched, by: groupBy, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)
        let groups = Array(allGroups.prefix(limit))

        return .time(HistoryTimeReply(
            totalSessions: totalSessions,
            totalActiveDurationSeconds: totalDuration,
            truncated: allGroups.count > groups.count,
            sessionsScanned: sessionsScanned,
            scanTruncated: scanTruncated,
            skippedWorkspaces: nonEmptyDiagnostics(skippedWorkspaces),
            groups: groups
        ))
    }

    // MARK: - On-Demand Transcript Enrichment

    /// Enrich index records that were rebuilt from lightweight stubs with their transcript-derived
    /// v5 fields (duration primitives, keyPaths, toolCount, activity bounds), loaded on demand.
    ///
    /// `rebuildMetadataIndex` loads stubs (transcript=nil) so it does not tax the agent-mode sidebar
    /// and workspace restore; the trade-off is that rebuilt records lack the fields history needs.
    /// Sessions saved or loaded through normal app use already carry these fields, so this only loads
    /// a transcript for genuinely stub-built records — those whose transcript-derived fields are all
    /// absent (`lacksTranscriptDerivedFields`). Any populated v5 field means a real transcript was
    /// already seen and the record is passed through unchanged. The calendar-grouped `time` op already
    /// walks transcripts and does not call this. See `AgentSessionMetadataRecord`
    /// `.enrichingTranscriptDerivedFields(from:)`.
    private static func enrichingStubBuiltSessions(
        _ sessions: [HistoryFilteredSessionRecord],
        scanner: HistorySessionScanning,
        recomputeStale: Bool = false
    ) async -> [HistoryFilteredSessionRecord] {
        var enriched: [HistoryFilteredSessionRecord] = []
        enriched.reserveCapacity(sessions.count)
        for session in sessions {
            // Skip records that already carry transcript-derived fields. With
            // `recomputeStale` (used by `time`), also recompute when the session file
            // changed since the stored observed signature — so `time` totals aren't
            // read from stale persisted primitives and agree with the calendar path.
            // Listings leave `recomputeStale` off: their per-session duration is an
            // index-inventory value (cheap), not the live-transcript-authoritative one.
            let isStub = session.record.lacksTranscriptDerivedFields
            var isStale = false
            if recomputeStale {
                isStale = await scanner.transcriptDerivedFieldsAreStale(
                    for: session.record,
                    sessionID: session.record.id,
                    workspaceDir: session.workspaceDir
                )
            }
            if !isStub, !isStale {
                enriched.append(session)
                continue
            }
            do {
                // Use the live transcript even when it has no turns — an empty
                // transcript means zero duration, matching the calendar path. Fall back
                // to the stored record only on an actual load failure (missing/corrupt
                // file), not on a successfully-loaded empty transcript.
                let transcript = try await scanner.loadTranscriptForSearch(
                    sessionID: session.record.id,
                    workspaceDir: session.workspaceDir
                )
                enriched.append(
                    HistoryFilteredSessionRecord(
                        record: session.record.enrichingTranscriptDerivedFields(from: transcript.turns),
                        workspaceName: session.workspaceName,
                        workspaceDir: session.workspaceDir
                    )
                )
            } catch {
                enriched.append(session)
            }
        }
        return enriched
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

    // MARK: - Time: Calendar Grouping (per-day attribution)

    /// For day/week/month grouping, each turn's active duration is attributed to the
    /// calendar group (day/week/month) in which the turn's `startedAt` falls. This
    /// prevents double counting: a session active on both Monday and Tuesday contributes
    /// Monday's turns to Monday's group and Tuesday's turns to Tuesday's group.
    /// Inter-group gaps (e.g. overnight) are always idle. Transcript loading is required,
    /// so `maxSessionsScanned` bounds the work.
    private static func executeTimeCalendarGrouped(
        _ sessions: [HistoryFilteredSessionRecord],
        groupBy: String,
        idleThresholdMinutes: Int,
        includeDetails: Bool,
        dateFrom: Date?,
        dateTo: Date?,
        maxSessionsScanned: Int,
        limit: Int,
        skippedWorkspaces: [String],
        scanner: HistorySessionScanning
    ) async throws -> HistoryToolReply {
        let calendar = Calendar.current

        /// Group boundary for a date: [start, end) + key. Used to clip each turn's
        /// interval to the group it falls in, so a turn that crosses a group boundary
        /// (e.g. spans midnight) contributes only its in-boundary portion to each group
        /// — preventing an overlap with a turn in the next group from being counted
        /// twice (the all-turns session path merges it once).
        func groupBounds(for date: Date) -> (start: Date, end: Date, key: String)? {
            let dayStart = calendar.startOfDay(for: date)
            switch groupBy {
            case "day":
                let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                return (dayStart, end, iso8601DateOnly.string(from: dayStart))
            case "week":
                guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dayStart)) else { return nil }
                let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
                return (weekStart, end, iso8601DateOnly.string(from: weekStart))
            case "month":
                let comps = calendar.dateComponents([.year, .month], from: dayStart)
                guard let monthStart = calendar.date(from: comps) else { return nil }
                let end = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
                return (monthStart, end, String(format: "%d-%02d", comps.year ?? 0, comps.month ?? 0))
            default:
                return nil
            }
        }

        var sessionsScanned = 0
        var scanTruncated = false

        var groupKeys: Set<String> = []
        var groupSessionIDs: [String: Set<UUID>] = [:]
        var groupDuration: [String: Int] = [:]
        var groupTurns: [String: Int] = [:]
        var groupToolCalls: [String: Int] = [:]
        var sessionNames: [UUID: String] = [:]
        var detailDuration: [String: [UUID: Int]] = [:]
        var detailTurns: [String: [UUID: Int]] = [:]

        let orderedSessions = sortFilteredSessions(sessions, by: "last_activity", idleThresholdMinutes: idleThresholdMinutes)
        for session in orderedSessions {
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
            } catch { continue }

            let sid = session.record.id
            sessionNames[sid] = session.record.name
            // Bucket this session's turn intervals by group key, then compute the merged
            // active duration per group — same sort+merge+`<=threshold` math as
            // `AgentSessionMetadataRecord.activeDurationSeconds(thresholdMinutes:)`, so
            // overlapping/nested/out-of-order turns aren't double-counted and gaps are
            // measured between merged intervals (the raw `prevEnd` approach regressed on
            // nested turns and double-counted overlaps).
            var intervalsByKey: [String: [(start: Date, end: Date)]] = [:]
            var turnsByKey: [String: Int] = [:]
            var toolCallsByKey: [String: Int] = [:]

            for turn in transcript.turns {
                let start = turn.startedAt
                if let dateFrom, start < dateFrom { continue }
                if let dateTo, start > dateTo { continue }
                let end = turn.completedAt ?? turn.lastActivityAt ?? start
                guard end >= start else { continue }

                // The turn (and its tool calls) belong to the group it started in.
                guard let startGroup = groupBounds(for: start) else { continue }
                turnsByKey[startGroup.key, default: 0] += 1
                if let tc = turn.summary?.toolCount, tc > 0 {
                    toolCallsByKey[startGroup.key, default: 0] += tc
                } else {
                    toolCallsByKey[startGroup.key, default: 0] += turn.responseSpans.reduce(0) { $0 + $1.activities.count(where: { $0.toolExecution != nil }) }
                }

                // Clip the interval to each group boundary it spans, so a cross-boundary
                // turn contributes only its in-boundary portion to each group (a point
                // turn — end == start — is attributed as-is). Without clipping, a turn
                // that spans a boundary is fully attributed to its start's group and can
                // overlap a turn in the next group, double-counting the overlap.
                if end == start {
                    intervalsByKey[startGroup.key, default: []].append((start, end))
                } else {
                    var cursor = start
                    while cursor < end {
                        guard let g = groupBounds(for: cursor) else { break }
                        let clippedEnd = min(end, g.end)
                        intervalsByKey[g.key, default: []].append((cursor, clippedEnd))
                        cursor = g.end
                    }
                }
            }

            for (key, intervals) in intervalsByKey {
                let activeSeconds = AgentSessionMetadataRecord.activeDurationSeconds(intervals: intervals, thresholdMinutes: idleThresholdMinutes)
                groupKeys.insert(key)
                groupSessionIDs[key, default: []].insert(sid)
                groupDuration[key, default: 0] += activeSeconds
                groupTurns[key, default: 0] += turnsByKey[key] ?? 0
                groupToolCalls[key, default: 0] += toolCallsByKey[key] ?? 0
                if includeDetails {
                    detailDuration[key, default: [:]][sid, default: 0] += activeSeconds
                    detailTurns[key, default: [:]][sid, default: 0] += turnsByKey[key] ?? 0
                }
            }
        }

        let sortedKeys = groupKeys.sorted().reversed()
        let allGroupDTOs: [HistoryTimeReply.GroupDTO] = sortedKeys.map { key in
            let details: [HistoryTimeReply.GroupDTO.DetailDTO]?
            if includeDetails {
                let dd = detailDuration[key] ?? [:]
                let dt = detailTurns[key] ?? [:]
                details = dd.keys.sorted().map { sid in
                    HistoryTimeReply.GroupDTO.DetailDTO(
                        sessionID: sid.uuidString,
                        sessionName: sessionNames[sid] ?? "",
                        activeDurationSeconds: dd[sid] ?? 0,
                        turnCount: dt[sid] ?? 0
                    )
                }
            } else { details = nil }
            return HistoryTimeReply.GroupDTO(
                key: key,
                sessions: groupSessionIDs[key]?.count ?? 0,
                activeDurationSeconds: groupDuration[key] ?? 0,
                turnCount: groupTurns[key] ?? 0,
                toolCallCount: groupToolCalls[key] ?? 0,
                details: details
            )
        }

        let groupDTOs = Array(allGroupDTOs.prefix(limit))
        let totalDuration = allGroupDTOs.reduce(0) { $0 + $1.activeDurationSeconds }
        return .time(HistoryTimeReply(
            totalSessions: sessions.count,
            totalActiveDurationSeconds: totalDuration,
            truncated: allGroupDTOs.count > groupDTOs.count,
            sessionsScanned: sessionsScanned,
            scanTruncated: scanTruncated,
            skippedWorkspaces: nonEmptyDiagnostics(skippedWorkspaces),
            groups: groupDTOs
        ))
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
            return buildGroups(sessions, keyProvider: { iso8601DateOnly.string(from: $0.record.lastActivityAt ?? $0.record.activityDate) }, sortKeys: { $0.sort(by: >) }, includeDetails: includeDetails, idleThresholdMinutes: idleThresholdMinutes)
        case "week":
            return buildGroups(
                sessions,
                keyProvider: { session in
                    let activityDate = session.record.lastActivityAt ?? session.record.activityDate
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
                    let components = calendar.dateComponents([.year, .month], from: session.record.lastActivityAt ?? session.record.activityDate)
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

    // MARK: - get_session Rendering

    private static func clampGetSessionContextTurns(_ value: Int?) -> Int {
        guard let value else { return 1 }
        return max(0, min(value, 5))
    }

    private static func getSessionTargetTurnIndex(args: [String: Value], totalTurns: Int) -> Int {
        if let aroundTurn = args["around_turn"]?.intValue, (0 ..< totalTurns).contains(aroundTurn) {
            return aroundTurn
        }
        if let turnStart = args["turn_start"]?.intValue, (0 ..< totalTurns).contains(turnStart) {
            return turnStart
        }
        return 0
    }

    private static func getSessionContentBudget(maxChars: Int) -> Int {
        // `max_chars` applies to the user-visible formatted tool output, not just
        // raw transcript text. Reserve ~28% for headings, bullets, and retry hints so
        // the formatter can stay near the caller's requested token budget. The same
        // fraction is used at every budget, so the curve is continuous (no cliff
        // between small and large budgets) and large budgets keep their ~72% share.
        let reserve = max(1, Int(Double(maxChars) * 0.28))
        return max(1, maxChars - reserve)
    }

    private static func resolveGetSessionTurnRange(
        args: [String: Value],
        totalTurns: Int,
        contextTurns: Int
    ) throws -> Range<Int> {
        if let aroundTurn = args["around_turn"]?.intValue {
            guard (0 ..< totalTurns).contains(aroundTurn) else {
                throw HistoryValidationError(message: "around_turn must be between 0 and \(max(0, totalTurns - 1))")
            }
            let start = max(0, aroundTurn - contextTurns)
            let end = min(totalTurns, aroundTurn + contextTurns + 1)
            return start ..< end
        }

        guard let start = args["turn_start"]?.intValue else {
            throw HistoryValidationError(message: "get_session requires around_turn from a search result, or turn_start/turn_end for a bounded range")
        }
        let requestedEnd = args["turn_end"]?.intValue ?? start
        guard start >= 0, start < totalTurns else {
            throw HistoryValidationError(message: "turn_start must be between 0 and \(max(0, totalTurns - 1))")
        }
        guard requestedEnd >= start else {
            throw HistoryValidationError(message: "turn_end must be greater than or equal to turn_start")
        }
        let cappedEndInclusive = min(totalTurns - 1, min(requestedEnd, start + 19))
        return start ..< (cappedEndInclusive + 1)
    }

    private static func normalizedGetSessionRoles(_ rawRoles: [String]?) -> Set<String> {
        let roles = rawRoles?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard let roles, !roles.isEmpty else {
            return ["user", "assistant", "error", "summary"]
        }
        return Set(roles)
    }

    private static func renderGetSessionTurn(
        _ turn: AgentTranscriptTurn,
        turnIndex: Int,
        roles: Set<String>,
        remainingChars: inout Int
    ) -> (dto: HistoryGetSessionReply.TurnDTO, truncated: Bool) {
        var entries: [HistoryGetSessionReply.EntryDTO] = []
        var turnTruncated = false
        var entriesOmitted = 0
        let requestText: String?
        if roles.contains("user"), let request = nonEmptyText(turn.request?.text), remainingChars > 0 {
            let clipped = clipHistoryText(request, maxChars: min(2000, remainingChars))
            requestText = clipped.text
            remainingChars -= clipped.text.count
            turnTruncated = turnTruncated || clipped.truncated
        } else {
            requestText = nil
        }

        if turn.isStructurallyCompacted, roles.contains("summary"), let summaryText = historySummaryText(turn.summary), remainingChars > 0 {
            appendGetSessionEntry(
                role: "summary",
                text: summaryText,
                perEntryMaxChars: 2000,
                entries: &entries,
                remainingChars: &remainingChars,
                turnTruncated: &turnTruncated
            )
        }

        let toolCallSummary = getSessionToolCallSummary(turn.allActivities)

        for activity in turn.allActivities {
            guard remainingChars > 0 else {
                turnTruncated = true
                break
            }
            guard let role = getSessionRole(for: activity.role), roles.contains(role) else {
                continue
            }
            if entries.count >= maxGetSessionEntriesPerTurn {
                entriesOmitted += 1
                turnTruncated = true
                continue
            }
            let text: String?
            let perEntryMaxChars: Int
            if role == "tool" {
                text = getSessionToolSummary(activity)
                perEntryMaxChars = 500
            } else {
                text = nonEmptyText(activity.text)
                perEntryMaxChars = role == "error" ? 500 : 4000
            }
            guard let text else { continue }
            appendGetSessionEntry(
                role: role,
                text: text,
                perEntryMaxChars: perEntryMaxChars,
                entries: &entries,
                remainingChars: &remainingChars,
                turnTruncated: &turnTruncated
            )
        }

        return (
            HistoryGetSessionReply.TurnDTO(
                turnIndex: turnIndex,
                startedAt: iso8601DateTime.string(from: turn.startedAt),
                requestText: requestText,
                toolCallSummary: roles.contains("tool") ? nil : toolCallSummary,
                entries: entries,
                truncated: turnTruncated,
                entriesOmitted: entriesOmitted > 0 ? entriesOmitted : nil
            ),
            turnTruncated
        )
    }

    private static func appendGetSessionEntry(
        role: String,
        text: String,
        perEntryMaxChars: Int,
        entries: inout [HistoryGetSessionReply.EntryDTO],
        remainingChars: inout Int,
        turnTruncated: inout Bool
    ) {
        let clipped = clipHistoryText(text, maxChars: min(perEntryMaxChars, remainingChars))
        entries.append(HistoryGetSessionReply.EntryDTO(
            role: role,
            text: clipped.text,
            truncated: clipped.truncated
        ))
        remainingChars -= clipped.text.count
        turnTruncated = turnTruncated || clipped.truncated
    }

    private static func getSessionRole(for role: AgentTranscriptActivityRole) -> String? {
        switch role {
        case .assistant:
            "assistant"
        case .toolExecution:
            "tool"
        case .error:
            "error"
        case .progress, .note, .system:
            "system"
        case .thinking:
            "thinking"
        }
    }

    private static func getSessionToolSummary(_ activity: AgentTranscriptActivity) -> String? {
        guard let tool = activity.toolExecution else {
            return nonEmptyText(activity.text)
        }
        var parts = ["[tool:", tool.toolName ?? "unknown", tool.status.rawValue + "]"]
        if let summary = nonEmptyText(tool.summaryText) {
            parts.append(summary.replacingOccurrences(of: "\n", with: " "))
        }
        return parts.joined(separator: " ")
    }

    private static func getSessionToolCallSummary(_ activities: [AgentTranscriptActivity]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for activity in activities {
            guard let tool = activity.toolExecution else { continue }
            let key = "\(tool.toolName ?? "unknown") \(tool.status.rawValue)"
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        let shown = order.prefix(5).map { key in
            let count = counts[key] ?? 0
            return count == 1 ? key : "\(key) ×\(count)"
        }.joined(separator: ", ")
        let omittedKinds = max(0, order.count - 5)
        return omittedKinds > 0 ? "\(shown), +\(omittedKinds) more" : shown
    }

    private static func historySummaryText(_ summary: AgentTranscriptTurnSummary?) -> String? {
        guard let summary else { return nil }
        return nonEmptyText(summary.compactConclusionText)
            ?? nonEmptyText(summary.conclusionText)
            ?? nonEmptyText(summary.middleSummaryText)
            ?? nonEmptyText(summary.requestText)
    }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clipHistoryText(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard maxChars > 0 else { return ("", true) }
        guard text.count > maxChars else { return (text, false) }
        if maxChars == 1 { return ("…", true) }
        return (String(text.prefix(maxChars - 1)) + "…", true)
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

    static func parseValidatedDateBound(_ value: String?, parameterName: String, isUpperBound: Bool) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        guard let parsed = parseDateBound(value, isUpperBound: isUpperBound) else {
            throw HistoryValidationError(message: "Invalid '\(parameterName)' value '\(value)': expected ISO 8601 date or datetime")
        }
        return parsed
    }

    private static func clippedTurnRequestText(_ text: String?) -> String? {
        guard let text else { return nil }
        let maxLength = 240
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    static func historyPath(_ keyPath: String, matches query: String) -> Bool {
        let normalizedKey = normalizedHistoryPath(keyPath)
        let normalizedQuery = normalizedHistoryPath(query)
        guard !normalizedKey.isEmpty, !normalizedQuery.isEmpty else { return false }

        return normalizedKey.localizedCaseInsensitiveContains(normalizedQuery)
            || normalizedQuery.hasSuffix("/\(normalizedKey)")
    }

    private static func normalizedHistoryPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
            .lowercased()
    }

    private static func scanDiagnostics(from scanResults: [HistoryWorkspaceScanResult]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for result in scanResults {
            let reason: String? = if result.indexReadFailed {
                "unreadable index"
            } else if let schemaVersion = result.indexSchemaVersion {
                "stale index schema v\(schemaVersion)"
            } else {
                nil
            }
            guard let reason else { continue }
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.prefix(10).map { reason in
            "\(reason): \(counts[reason] ?? 0)"
        }
    }

    private static func nonEmptyDiagnostics(_ diagnostics: [String]) -> [String]? {
        diagnostics.isEmpty ? nil : diagnostics
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
        let rawDefault = (UserDefaults.standard.object(forKey: Self.idleThresholdSettingsKey) as? Int) ?? AgentSessionMetadataRecord.defaultIdleThresholdMinutes
        // Clamp the stored default: explicit args are validated to 0...1440, but a raw
        // `defaults write` (or any future writer) could store an out-of-range value.
        let defaultThreshold = min(max(0, rawDefault), 1440)
        guard let value else { return defaultThreshold }
        guard let intValue = value.intValue else {
            throw HistoryValidationError(message: "idle_threshold_minutes must be an integer")
        }
        guard (0 ... 1440).contains(intValue) else {
            throw HistoryValidationError(message: "idle_threshold_minutes must be between 0 and 1440")
        }
        return intValue
    }

    static func resolveMaxSessionsScanned(_ value: Value?) throws -> Int {
        guard let value else { return defaultMaxSessionsScanned }
        guard let intValue = value.intValue else {
            throw HistoryValidationError(message: "max_sessions_scanned must be an integer")
        }
        guard intValue > 0 else {
            throw HistoryValidationError(message: "max_sessions_scanned must be greater than 0")
        }
        return min(intValue, absoluteMaxSessionsScanned)
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
