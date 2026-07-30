import Foundation

struct AgentSessionMetadataIndex: Codable, Equatable {
    static let currentSchemaVersion = 5

    var schemaVersion: Int
    var generatedAt: Date
    var lastReconciledAt: Date?
    var entries: [AgentSessionMetadataRecord]
    var quarantinedFiles: [AgentSessionMetadataQuarantineRecord]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date = Date(),
        lastReconciledAt: Date? = nil,
        entries: [AgentSessionMetadataRecord] = [],
        quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastReconciledAt = lastReconciledAt
        self.entries = entries
        self.quarantinedFiles = quarantinedFiles
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case lastReconciledAt
        case entries
        case quarantinedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? -1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        lastReconciledAt = try container.decodeIfPresent(Date.self, forKey: .lastReconciledAt)
        entries = try container.decodeIfPresent([AgentSessionMetadataRecord].self, forKey: .entries) ?? []
        quarantinedFiles = try container.decodeIfPresent([AgentSessionMetadataQuarantineRecord].self, forKey: .quarantinedFiles) ?? []
    }
}

struct AgentSessionMetadataRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var workspaceID: UUID?
    var composeTabID: UUID?
    var name: String
    var savedAt: Date
    var lastUserMessageAt: Date?
    var itemCount: Int
    var transcriptProjectionCounts: AgentTranscriptProjectionCounts?
    var hasUnknownConversationContent: Bool
    var agentKindRaw: String?
    var agentModelRaw: String?
    var agentReasoningEffortRaw: String?
    var lastRunStateRaw: String?
    var autoEditEnabled: Bool
    var parentSessionID: UUID?
    var isMCPOriginated: Bool
    var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
    var serializationVersion: Int?
    var observedFileSize: Int64?
    var observedFileModificationDate: Date?
    var lastIndexedAt: Date
    var firstActivityAt: Date?
    var lastActivityAt: Date?
    var keyPaths: Set<String>
    var coveredTurnDurationSeconds: Int
    var interActiveIntervalGapSeconds: [Int]
    var toolCallCount: Int

    /// Default idle threshold in minutes. Gaps between merged active intervals longer than this are idle.
    static let defaultIdleThresholdMinutes = 10

    var activityDate: Date {
        AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
    }

    /// Active duration at the default idle threshold, derived from the stored primitives.
    var activeDurationSeconds: Int {
        activeDurationSeconds(thresholdMinutes: Self.defaultIdleThresholdMinutes)
    }

    /// Active duration at a custom idle threshold (minutes). Gaps greater than the threshold are idle;
    /// gaps less than or equal are active and merged in.
    func activeDurationSeconds(thresholdMinutes: Int) -> Int {
        let thresholdSeconds = thresholdMinutes * 60
        let activeGaps = interActiveIntervalGapSeconds.reduce(0) { $0 + ($1 <= thresholdSeconds ? $1 : 0) }
        return coveredTurnDurationSeconds + activeGaps
    }

    /// True when this record carries no transcript-derived fields, i.e. it was built from a
    /// transcript-less stub during a cheap `rebuildMetadataIndex` pass. The history tool uses this to
    /// decide which records need on-demand enrichment: any populated v5 field implies a real
    /// transcript was already seen (the save/load path), so the record is passed through unchanged.
    ///
    /// Maintenance: any new transcript-derived field must be added to this check, or a stub-built
    /// record carrying it would be misclassified as indexed and silently skip on-demand enrichment.
    var lacksTranscriptDerivedFields: Bool {
        firstActivityAt == nil
            && lastActivityAt == nil
            && coveredTurnDurationSeconds == 0
            && interActiveIntervalGapSeconds.isEmpty
            && keyPaths.isEmpty
            && toolCallCount == 0
    }

    init(
        id: UUID,
        filename: String,
        workspaceID: UUID?,
        composeTabID: UUID?,
        name: String,
        savedAt: Date,
        lastUserMessageAt: Date?,
        itemCount: Int,
        transcriptProjectionCounts: AgentTranscriptProjectionCounts?,
        hasUnknownConversationContent: Bool,
        agentKindRaw: String?,
        agentModelRaw: String?,
        agentReasoningEffortRaw: String?,
        lastRunStateRaw: String?,
        autoEditEnabled: Bool,
        parentSessionID: UUID?,
        isMCPOriginated: Bool,
        worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] = [],
        activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = [],
        serializationVersion: Int?,
        observedFileSize: Int64?,
        observedFileModificationDate: Date?,
        lastIndexedAt: Date,
        firstActivityAt: Date? = nil,
        lastActivityAt: Date? = nil,
        keyPaths: Set<String> = [],
        coveredTurnDurationSeconds: Int = 0,
        interActiveIntervalGapSeconds: [Int] = [],
        toolCallCount: Int = 0
    ) {
        self.id = id
        self.filename = filename
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.name = name
        self.savedAt = savedAt
        self.lastUserMessageAt = lastUserMessageAt
        self.itemCount = itemCount
        self.transcriptProjectionCounts = transcriptProjectionCounts
        self.hasUnknownConversationContent = hasUnknownConversationContent
        self.agentKindRaw = agentKindRaw
        self.agentModelRaw = agentModelRaw
        self.agentReasoningEffortRaw = agentReasoningEffortRaw
        self.lastRunStateRaw = lastRunStateRaw
        self.autoEditEnabled = autoEditEnabled
        self.parentSessionID = parentSessionID
        self.isMCPOriginated = isMCPOriginated
        self.worktreeBindingSummaries = worktreeBindingSummaries
        self.activeWorktreeMergeSummaries = activeWorktreeMergeSummaries
        self.serializationVersion = serializationVersion
        self.observedFileSize = observedFileSize
        self.observedFileModificationDate = observedFileModificationDate
        self.lastIndexedAt = lastIndexedAt
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.keyPaths = keyPaths
        self.coveredTurnDurationSeconds = coveredTurnDurationSeconds
        self.interActiveIntervalGapSeconds = interActiveIntervalGapSeconds
        self.toolCallCount = toolCallCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case workspaceID
        case composeTabID
        case name
        case savedAt
        case lastUserMessageAt
        case itemCount
        case transcriptProjectionCounts
        case hasUnknownConversationContent
        case agentKindRaw
        case agentModelRaw
        case agentReasoningEffortRaw
        case lastRunStateRaw
        case autoEditEnabled
        case parentSessionID
        case isMCPOriginated
        case worktreeBindingSummaries
        case activeWorktreeMergeSummaries
        case serializationVersion
        case observedFileSize
        case observedFileModificationDate
        case lastIndexedAt
        case firstActivityAt
        case lastActivityAt
        case keyPaths
        case coveredTurnDurationSeconds
        case interActiveIntervalGapSeconds
        case toolCallCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        transcriptProjectionCounts = try container.decodeIfPresent(AgentTranscriptProjectionCounts.self, forKey: .transcriptProjectionCounts)
        hasUnknownConversationContent = try container.decodeIfPresent(Bool.self, forKey: .hasUnknownConversationContent) ?? false
        agentKindRaw = try container.decodeIfPresent(String.self, forKey: .agentKindRaw)
        agentModelRaw = try container.decodeIfPresent(String.self, forKey: .agentModelRaw)
        agentReasoningEffortRaw = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffortRaw)
        lastRunStateRaw = try container.decodeIfPresent(String.self, forKey: .lastRunStateRaw)
        autoEditEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoEditEnabled) ?? true
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated) ?? false
        worktreeBindingSummaries = try container.decodeIfPresent([AgentSessionWorktreeBindingSummary].self, forKey: .worktreeBindingSummaries) ?? []
        activeWorktreeMergeSummaries = try container.decodeIfPresent([AgentSessionWorktreeMergeSummary].self, forKey: .activeWorktreeMergeSummaries) ?? []
        serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
        observedFileSize = try container.decodeIfPresent(Int64.self, forKey: .observedFileSize)
        observedFileModificationDate = try container.decodeIfPresent(Date.self, forKey: .observedFileModificationDate)
        lastIndexedAt = try container.decodeIfPresent(Date.self, forKey: .lastIndexedAt) ?? savedAt
        firstActivityAt = try container.decodeIfPresent(Date.self, forKey: .firstActivityAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        keyPaths = try container.decodeIfPresent(Set<String>.self, forKey: .keyPaths) ?? []
        coveredTurnDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .coveredTurnDurationSeconds) ?? 0
        interActiveIntervalGapSeconds = try container.decodeIfPresent([Int].self, forKey: .interActiveIntervalGapSeconds) ?? []
        toolCallCount = try container.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
    }

    func sidebarEntry(tabID overrideTabID: UUID? = nil, displayName: String? = nil) -> AgentSessionIndexEntry? {
        guard let tabID = overrideTabID ?? composeTabID else { return nil }
        return AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(displayName ?? name),
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt,
            lastRunStateRaw: lastRunStateRaw,
            itemCount: itemCount,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: agentReasoningEffortRaw,
            autoEditEnabled: autoEditEnabled,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: hasUnknownConversationContent,
            isMCPOriginated: isMCPOriginated,
            worktreeBindingSummaries: worktreeBindingSummaries,
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries
        )
    }

    func agentSessionMeta(lastModifiedOverride: Date? = nil) -> AgentSessionMeta {
        AgentSessionMeta(
            id: id,
            composeTabID: composeTabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(name),
            lastModified: lastModifiedOverride ?? observedFileModificationDate ?? savedAt,
            itemCount: itemCount,
            agentKind: agentKindRaw,
            agentModel: agentModelRaw,
            lastRunState: lastRunStateRaw,
            parentSessionID: parentSessionID,
            isMCPOriginated: isMCPOriginated,
            worktreeBindingSummaries: worktreeBindingSummaries,
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries
        )
    }

    func matchesIndexedSessionMetadata(_ other: AgentSessionMetadataRecord) -> Bool {
        id == other.id
            && filename == other.filename
            && workspaceID == other.workspaceID
            && composeTabID == other.composeTabID
            && name == other.name
            && savedAt == other.savedAt
            && lastUserMessageAt == other.lastUserMessageAt
            && itemCount == other.itemCount
            && transcriptProjectionCounts == other.transcriptProjectionCounts
            && hasUnknownConversationContent == other.hasUnknownConversationContent
            && agentKindRaw == other.agentKindRaw
            && agentModelRaw == other.agentModelRaw
            && agentReasoningEffortRaw == other.agentReasoningEffortRaw
            && lastRunStateRaw == other.lastRunStateRaw
            && autoEditEnabled == other.autoEditEnabled
            && parentSessionID == other.parentSessionID
            && isMCPOriginated == other.isMCPOriginated
            && worktreeBindingSummaries == other.worktreeBindingSummaries
            && activeWorktreeMergeSummaries == other.activeWorktreeMergeSummaries
            && serializationVersion == other.serializationVersion
            && observedFileSize == other.observedFileSize
            && observedFileModificationDate == other.observedFileModificationDate
            && firstActivityAt == other.firstActivityAt
            && lastActivityAt == other.lastActivityAt
            && keyPaths == other.keyPaths
            && coveredTurnDurationSeconds == other.coveredTurnDurationSeconds
            && interActiveIntervalGapSeconds == other.interActiveIntervalGapSeconds
            && toolCallCount == other.toolCallCount
    }

    static func record(
        from session: AgentSession,
        fileURL: URL,
        observedFileSize: Int64?,
        observedFileModificationDate: Date?,
        lastIndexedAt: Date = Date()
    ) -> AgentSessionMetadataRecord {
        let turns = session.transcript?.turns ?? []
        let aggregatedKeyPaths = Self.computeKeyPaths(from: turns)
        let activityBounds = Self.computeActivityBounds(from: turns)
        let durationPrimitives = Self.computeDurationPrimitives(from: turns)
        let computedToolCallCount = Self.computeToolCallCount(from: turns)

        return AgentSessionMetadataRecord(
            id: session.id,
            filename: fileURL.lastPathComponent,
            workspaceID: session.workspaceID,
            composeTabID: session.composeTabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(session.name),
            savedAt: session.savedAt,
            lastUserMessageAt: session.lastUserMessageAt,
            itemCount: session.effectiveItemCount,
            transcriptProjectionCounts: session.transcriptProjectionCounts,
            hasUnknownConversationContent: AgentSessionRestoreSupport.hasUnknownConversationContent(in: session),
            agentKindRaw: session.agentKind,
            agentModelRaw: session.agentModel,
            agentReasoningEffortRaw: session.agentReasoningEffort,
            lastRunStateRaw: session.lastRunState,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
            serializationVersion: session.serializationVersion,
            observedFileSize: observedFileSize,
            observedFileModificationDate: observedFileModificationDate,
            lastIndexedAt: lastIndexedAt,
            firstActivityAt: activityBounds.first,
            lastActivityAt: activityBounds.last,
            keyPaths: aggregatedKeyPaths,
            coveredTurnDurationSeconds: durationPrimitives.coveredSeconds,
            interActiveIntervalGapSeconds: durationPrimitives.gapSeconds,
            toolCallCount: computedToolCallCount
        )
    }

    /// Aggregate file key paths across turns: prefers compacted summary `keyPaths`, falling back to
    /// walking tool executions in response-span activities. Shared by the index factory and the
    /// history tool's on-demand enrichment so key-path extraction has one definition.
    private static func computeKeyPaths(from turns: [AgentTranscriptTurn]) -> Set<String> {
        var collected: Set<String> = []
        for turn in turns {
            if let summaryPaths = turn.summary?.keyPaths, !summaryPaths.isEmpty {
                collected.formUnion(summaryPaths)
                continue
            }
            for span in turn.responseSpans {
                for activity in span.activities {
                    guard let exec = activity.toolExecution else { continue }
                    collected.formUnion(exec.keyPaths)
                }
            }
        }
        return collected
    }

    /// Return a copy with the transcript-derived v5 fields (activity bounds, keyPaths, toolCount,
    /// duration primitives) recomputed from `turns`. The `history` tool calls this to enrich index
    /// records that were rebuilt from lightweight stubs (`firstActivityAt == nil`) on demand, so the
    /// shared `rebuildMetadataIndex` path — which feeds the agent-mode sidebar and workspace restore —
    /// never decodes full session transcripts just to precompute fields only history consumes. Records
    /// already fully indexed (via the save/load path) need not call this.
    func enrichingTranscriptDerivedFields(from turns: [AgentTranscriptTurn]) -> AgentSessionMetadataRecord {
        var copy = self
        let bounds = Self.computeActivityBounds(from: turns)
        let primitives = Self.computeDurationPrimitives(from: turns)
        copy.firstActivityAt = bounds.first
        copy.lastActivityAt = bounds.last
        copy.keyPaths = Self.computeKeyPaths(from: turns)
        copy.coveredTurnDurationSeconds = primitives.coveredSeconds
        copy.interActiveIntervalGapSeconds = primitives.gapSeconds
        copy.toolCallCount = Self.computeToolCallCount(from: turns)
        return copy
    }

    /// Compute first and last activity timestamps from transcript turns.
    private static func computeActivityBounds(from turns: [AgentTranscriptTurn]) -> (first: Date?, last: Date?) {
        var first: Date?
        var last: Date?

        func include(_ date: Date?) {
            guard let date else { return }
            if first.map({ date < $0 }) ?? true {
                first = date
            }
            if last.map({ date > $0 }) ?? true {
                last = date
            }
        }

        for turn in turns {
            include(turn.startedAt)
            include(turn.lastActivityAt)
            include(turn.completedAt)
            for activity in turn.allActivities {
                include(activity.timestamp)
            }
        }

        return (first, last)
    }

    /// Compute tool call count from transcript turns.
    /// Compacted turns retain only `summary.toolCount`; active turns retain tool execution activities.
    private static func computeToolCallCount(from turns: [AgentTranscriptTurn]) -> Int {
        turns.reduce(0) { total, turn in
            if let summaryToolCount = turn.summary?.toolCount, summaryToolCount > 0 {
                return total + summaryToolCount
            }
            return total + turn.responseSpans.reduce(0) { spanTotal, span in
                spanTotal + span.activities.count(where: { $0.toolExecution != nil })
            }
        }
    }

    /// Sorts and merges overlapping/contiguous intervals (sorted by start, then end) so nested
    /// or overlapping turns are never double-counted. Zero-duration (point) intervals are retained.
    /// Shared between persisted duration-primitive computation and per-group history attribution.
    static func mergedIntervals(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { lhs, rhs in
            lhs.start < rhs.start || (lhs.start == rhs.start && lhs.end < rhs.end)
        }
        var merged: [(start: Date, end: Date)] = [sorted[0]]
        for interval in sorted.dropFirst() {
            let lastIndex = merged.count - 1
            if interval.start > merged[lastIndex].end {
                merged.append(interval)
            } else {
                merged[lastIndex].end = max(merged[lastIndex].end, interval.end)
            }
        }
        return merged
    }

    /// Active duration for an arbitrary interval set: merged covered time plus inter-interval gaps
    /// `<= thresholdMinutes`. Mirrors per-record ``activeDurationSeconds(thresholdMinutes:)`` so
    /// calendar `history.time` attribution agrees with session/workspace grouping.
    static func activeDurationSeconds(intervals: [(start: Date, end: Date)], thresholdMinutes: Int) -> Int {
        let merged = mergedIntervals(intervals)
        guard !merged.isEmpty else { return 0 }
        let thresholdSeconds = thresholdMinutes * 60
        var covered = 0
        var activeGaps = 0
        for (index, interval) in merged.enumerated() {
            covered += Int(interval.end.timeIntervalSince(interval.start))
            if index > 0 {
                let gap = Int(interval.start.timeIntervalSince(merged[index - 1].end))
                if gap > 0, gap <= thresholdSeconds { activeGaps += gap }
            }
        }
        return max(0, covered + activeGaps)
    }

    /// Compute threshold-independent duration primitives from transcript turns:
    /// the union of merged per-turn active intervals (`coveredSeconds`) and the positive gaps
    /// between those merged intervals (`gapSeconds`). Each interval is
    /// `[startedAt, completedAt ?? lastActivityAt ?? startedAt]`; intervals with end earlier than
    /// start are dropped. Intervals are sorted and merged (overlaps collapsed) before measuring,
    /// so overlapping or nested turns are never double-counted. Zero-duration (point) intervals are
    /// retained so sessions whose turns carry only `startedAt` still yield gap-based estimates.
    private static func computeDurationPrimitives(from turns: [AgentTranscriptTurn]) -> (coveredSeconds: Int, gapSeconds: [Int]) {
        var intervals: [(start: Date, end: Date)] = []
        intervals.reserveCapacity(turns.count)
        for turn in turns {
            let start = turn.startedAt
            let end = turn.completedAt ?? turn.lastActivityAt ?? start
            if end >= start { intervals.append((start, end)) }
        }
        let merged = mergedIntervals(intervals)
        guard !merged.isEmpty else { return (0, []) }

        var coveredSeconds = 0
        var gapSeconds: [Int] = []
        for (index, interval) in merged.enumerated() {
            coveredSeconds += Int(interval.end.timeIntervalSince(interval.start))
            if index > 0 {
                let gap = Int(interval.start.timeIntervalSince(merged[index - 1].end))
                if gap > 0 { gapSeconds.append(gap) }
            }
        }
        return (max(0, coveredSeconds), gapSeconds)
    }
}

struct AgentSessionMetadataQuarantineRecord: Codable, Equatable {
    var filename: String
    var observedFileSize: Int64?
    var observedFileModificationDate: Date?
    var errorDescription: String
    var lastAttemptedAt: Date
}

extension [AgentSessionMetadataRecord] {
    func sortedForAgentSessionMetadataIndex() -> [AgentSessionMetadataRecord] {
        sorted { lhs, rhs in
            if lhs.activityDate != rhs.activityDate {
                return lhs.activityDate > rhs.activityDate
            }
            if lhs.savedAt != rhs.savedAt {
                return lhs.savedAt > rhs.savedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
