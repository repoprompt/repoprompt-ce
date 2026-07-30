import Foundation

enum AgentSessionRestoreSupport {
    static func normalizedSessionTitle(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Agent Session" : trimmed
    }

    static func shouldPreferSidebarEntry(_ lhs: AgentSessionIndexEntry, over rhs: AgentSessionIndexEntry) -> Bool {
        if lhs.lastUserMessageAt != rhs.lastUserMessageAt {
            return shouldListBefore(
                lhsID: lhs.id,
                lhsDate: lhs.lastUserMessageAt,
                rhsID: rhs.id,
                rhsDate: rhs.lastUserMessageAt
            )
        }
        if lhs.savedAt != rhs.savedAt {
            return lhs.savedAt > rhs.savedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func sidebarSortDates(
        from sessionIndex: [UUID: AgentSessionIndexEntry]
    ) -> [UUID: Date] {
        var sortDates: [UUID: Date] = [:]
        let entriesWithSortDates = sessionIndex.values.lazy.filter { $0.lastUserMessageAt != nil }
        for (tabID, entry) in preferredEntriesByTabID(from: entriesWithSortDates) {
            if let date = entry.lastUserMessageAt {
                sortDates[tabID] = date
            }
        }
        return sortDates
    }

    static func preferredEntriesByTabID(
        from entries: some Sequence<AgentSessionIndexEntry>
    ) -> [UUID: AgentSessionIndexEntry] {
        var preferredEntryByTabID: [UUID: AgentSessionIndexEntry] = [:]
        for entry in entries {
            if let existing = preferredEntryByTabID[entry.tabID] {
                if shouldPreferSidebarEntry(entry, over: existing) {
                    preferredEntryByTabID[entry.tabID] = entry
                }
            } else {
                preferredEntryByTabID[entry.tabID] = entry
            }
        }
        return preferredEntryByTabID
    }

    static func sidebarActivityDate(for entry: AgentSessionIndexEntry) -> Date {
        sidebarActivityDate(lastUserMessageAt: entry.lastUserMessageAt, savedAt: entry.savedAt)
    }

    static func sidebarActivityDate(lastUserMessageAt: Date?, savedAt: Date) -> Date {
        lastUserMessageAt ?? savedAt
    }

    static func normalizeColdRestoredRunState(_ persisted: AgentSessionRunState?) -> AgentSessionRunState {
        guard let persisted else { return .idle }
        switch persisted {
        case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return .idle
        case .idle, .completed, .cancelled, .failed:
            return persisted
        }
    }

    static func coldRestoredLastRunStateRaw(_ raw: String?) -> String? {
        guard let raw,
              let persisted = AgentSessionRunState(rawValue: raw),
              persisted.isActive
        else {
            return raw
        }
        return normalizeColdRestoredRunState(persisted).rawValue
    }

    static func sanitizeColdRestoredTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        var restored = transcript
        for turnIndex in restored.turns.indices {
            sanitizeColdRestoredTurn(&restored.turns[turnIndex])
        }
        return restored
    }

    private static func sanitizeColdRestoredTurn(_ turn: inout AgentTranscriptTurn) {
        let activeToolExecutionIDs = activeToolExecutionIDsNeedingColdRestoreCancellation(in: turn)
        let hadActiveTurnState = turn.terminalState?.isActive == true
        let hasOpenSpan = turn.responseSpans.contains { $0.lifecycle == .open }
        let shouldCancelTurn = hadActiveTurnState
            || (turn.terminalState == nil && (hasOpenSpan || !activeToolExecutionIDs.isEmpty))

        if shouldCancelTurn {
            turn.terminalState = .cancelled
        }
        if shouldCancelTurn || (turn.completedAt == nil && !(turn.terminalState?.isActive ?? false)) {
            turn.completedAt = turn.completedAt
                ?? turn.lastActivityAt
                ?? turn.responseSpans.map { $0.lastActivityAt ?? $0.startedAt }.max()
                ?? turn.request?.timestamp
                ?? turn.startedAt
        }
        if shouldCancelTurn, var summary = turn.summary {
            summary.hadError = true
            turn.summary = summary
        }

        for spanIndex in turn.responseSpans.indices {
            sanitizeColdRestoredSpan(
                &turn.responseSpans[spanIndex],
                terminalState: turn.terminalState,
                activeToolExecutionIDs: activeToolExecutionIDs
            )
        }
    }

    private static func sanitizeColdRestoredSpan(
        _ span: inout AgentTranscriptProviderResponseSpan,
        terminalState: AgentSessionRunState?,
        activeToolExecutionIDs: Set<String>
    ) {
        for activityIndex in span.activities.indices {
            sanitizeColdRestoredActivity(
                &span.activities[activityIndex],
                activeToolExecutionIDs: activeToolExecutionIDs
            )
        }
        if span.lifecycle == .open {
            span.lifecycle = closedSpanLifecycle(for: terminalState)
        }
        if span.completedAt == nil, span.lifecycle != .open {
            span.completedAt = span.lastActivityAt ?? span.activities.last?.timestamp ?? span.startedAt
        }
        span.collapsedSummary = span.collapsedSummary.map(sanitizedColdRestoredGroupedHistorySummary(_:))
        span.fullRenderGroupedHistoryCache = nil
    }

    private static func sanitizeColdRestoredActivity(
        _ activity: inout AgentTranscriptActivity,
        activeToolExecutionIDs: Set<String>
    ) {
        activity.isStreaming = false
        guard var execution = activity.toolExecution,
              activeToolExecutionIDs.contains(execution.stableExecutionID)
        else {
            return
        }
        execution.status = .cancelled
        execution.toolIsError = true
        if activity.itemKind == .toolResult {
            let resultJSON = coldRestoredCancelledToolResultJSON(
                toolName: execution.toolName,
                existingResultJSON: execution.resultJSON
            )
            execution.resultJSON = resultJSON
            activity.text = resultJSON
        }
        activity.toolExecution = execution
    }

    private static func activeToolExecutionIDsNeedingColdRestoreCancellation(in turn: AgentTranscriptTurn) -> Set<String> {
        var latestStatusByID: [String: AgentTranscriptToolStatus] = [:]
        for activity in turn.allActivities {
            guard let execution = activity.toolExecution else { continue }
            if let existing = latestStatusByID[execution.stableExecutionID],
               coldRestoredToolStatusRank(existing) > coldRestoredToolStatusRank(execution.status)
            {
                continue
            }
            latestStatusByID[execution.stableExecutionID] = execution.status
        }
        return Set(latestStatusByID.compactMap { executionID, status in
            switch status {
            case .pending, .running:
                executionID
            case .success, .warning, .failed, .cancelled, .unknown:
                nil
            }
        })
    }

    private static func closedSpanLifecycle(for terminalState: AgentSessionRunState?) -> AgentTranscriptSpanLifecycle {
        switch terminalState {
        case .cancelled:
            .cancelled
        case .failed:
            .failed
        default:
            .completed
        }
    }

    private static func coldRestoredToolStatusRank(_ status: AgentTranscriptToolStatus) -> Int {
        switch status {
        case .pending:
            0
        case .running:
            1
        case .unknown:
            2
        case .success:
            3
        case .warning:
            4
        case .failed:
            5
        case .cancelled:
            6
        }
    }

    private static func coldRestoredCancelledToolResultJSON(
        toolName: String?,
        existingResultJSON: String?
    ) -> String {
        var payload = coldRestoredToolResultObject(from: existingResultJSON) ?? [:]
        payload["status"] = "cancelled"
        payload["reason"] = "restored_without_live_run"
        payload["note"] = "This tool execution was restored from a previous app process and is no longer running."
        if let toolName,
           !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["tool"] = toolName
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"status":"cancelled","reason":"restored_without_live_run"}"#
    }

    private static func coldRestoredToolResultObject(from raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func sanitizedColdRestoredGroupedHistorySummary(
        _ summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentTranscriptGroupedHistorySummary {
        let sanitizedToolSummary = summary.toolSummary.map(sanitizedColdRestoredClusterSummary(_:))
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: summary.hiddenToolCardCount,
            hiddenAssistantCount: summary.hiddenAssistantCount,
            hiddenProgressCount: summary.hiddenProgressCount,
            hiddenNoteCount: summary.hiddenNoteCount,
            toolSummary: sanitizedToolSummary,
            collapsedDisplay: summary.collapsedDisplay.map(sanitizedColdRestoredCollapsedDisplay(_:))
        )
    }

    private static func sanitizedColdRestoredClusterSummary(
        _ summary: AgentTranscriptClusterSummary
    ) -> AgentTranscriptClusterSummary {
        let didCancelRunningWork = summary.containsRunningWork
        return AgentTranscriptClusterSummary(
            toolCount: summary.toolCount,
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            toolGroups: summary.toolGroups,
            keyPaths: summary.keyPaths,
            containsRunningWork: false,
            containsFailure: summary.containsFailure || didCancelRunningWork,
            containsWarning: summary.containsWarning,
            shortNarration: summary.shortNarration,
            collapsedDisplay: summary.collapsedDisplay.map(sanitizedColdRestoredCollapsedDisplay(_:))
        )
    }

    private static func sanitizedColdRestoredCollapsedDisplay(
        _ display: AgentTranscriptCollapsedSummaryDisplay
    ) -> AgentTranscriptCollapsedSummaryDisplay {
        AgentTranscriptCollapsedSummaryDisplay(
            title: display.title,
            count: display.count,
            detailText: display.detailText,
            narrationText: display.narrationText,
            toolGroupText: display.toolGroupText,
            status: display.status == .running ? .failure : display.status
        )
    }

    static func computeLastUserMessageDate(in items: [AgentChatItem]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items)
    }

    static func hasUnknownConversationContent(in session: AgentSession) -> Bool {
        session.transcriptProjectionCounts == nil
            && session.lastUserMessageAt == nil
            && session.itemCount == 0
    }

    static func transcriptProjectionProtection(
        for transcript: AgentTranscript,
        viewportState: AgentTranscriptViewportState
    ) -> AgentTranscriptProjectionProtection {
        guard !transcript.turns.isEmpty else { return .none }
        return AgentTranscriptProjectionBuilder.projectionProtection(
            for: transcript,
            viewportState: viewportState
        )
    }

    static func buildTranscriptPresentation(
        from transcript: AgentTranscript,
        sourceItems: [AgentChatItem],
        selectedAgent: AgentProviderKind,
        previousPerformanceSnapshot: AgentTranscriptPerformanceSnapshot,
        projectionProtection: AgentTranscriptProjectionProtection,
        isCompressedHistoryRevealed: Bool,
        isColdLoad: Bool
    ) -> AgentModeViewModel.BuiltTranscriptPresentation {
        AgentModeViewModel.buildTranscriptPresentation(
            from: transcript,
            sourceItems: sourceItems,
            selectedAgent: selectedAgent,
            previousPerformanceSnapshot: previousPerformanceSnapshot,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: isCompressedHistoryRevealed,
            isColdLoad: isColdLoad
        )
    }

    static func buildSidebarIndexEntry(
        from session: AgentSession,
        tabID: UUID,
        name: String,
        lastUserMessageAt: Date? = nil,
        itemCount: Int? = nil,
        hasUnknownConversationContent: Bool = false
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: session.id,
            tabID: tabID,
            name: normalizedSessionTitle(name),
            lastUserMessageAt: lastUserMessageAt ?? session.lastUserMessageAt,
            savedAt: session.savedAt,
            lastRunStateRaw: session.lastRunState,
            itemCount: itemCount ?? session.effectiveItemCount,
            agentKindRaw: session.agentKind,
            agentModelRaw: session.agentModel,
            agentReasoningEffortRaw: session.agentReasoningEffort,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            hasUnknownConversationContent: hasUnknownConversationContent,
            isMCPOriginated: session.isMCPOriginated,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    private static func shouldListBefore(
        lhsID: UUID,
        lhsDate: Date?,
        rhsID: UUID,
        rhsDate: Date?
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhsID.uuidString < rhsID.uuidString
    }
}
