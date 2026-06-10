import Foundation

struct AgentSessionMetadataIndex: Codable, Equatable {
    static let currentSchemaVersion = 3

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
    var keyPaths: Set<String>
    var activeDurationSeconds: Int

    var activityDate: Date {
        AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
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
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0
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
        self.keyPaths = keyPaths
        self.activeDurationSeconds = activeDurationSeconds
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
        case keyPaths
        case activeDurationSeconds
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
        keyPaths = try container.decodeIfPresent(Set<String>.self, forKey: .keyPaths) ?? []
        activeDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .activeDurationSeconds) ?? 0
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
            && keyPaths == other.keyPaths
            && activeDurationSeconds == other.activeDurationSeconds
    }

    static func record(
        from session: AgentSession,
        fileURL: URL,
        observedFileSize: Int64?,
        observedFileModificationDate: Date?,
        lastIndexedAt: Date = Date()
    ) -> AgentSessionMetadataRecord {
        let aggregatedKeyPaths: Set<String> = {
            guard let turns = session.transcript?.turns else { return [] }
            var collected: Set<String> = []
            for turn in turns {
                // Prefer summary keyPaths when available (compacted turns).
                if let summaryPaths = turn.summary?.keyPaths, !summaryPaths.isEmpty {
                    collected.formUnion(summaryPaths)
                    continue
                }
                // Fall back to walking tool executions in response span activities.
                for span in turn.responseSpans {
                    for activity in span.activities {
                        guard let exec = activity.toolExecution else { continue }
                        collected.formUnion(exec.keyPaths)
                    }
                }
            }
            return collected
        }()

        let durationSeconds: Int = {
            guard let turns = session.transcript?.turns else { return 0 }
            return Self.computeActiveDurationSeconds(from: turns)
        }()

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
            keyPaths: aggregatedKeyPaths,
            activeDurationSeconds: durationSeconds
        )
    }

    /// Compute active duration in seconds from transcript turns, excluding idle gaps > 30 minutes.
    /// Uses `completedAt ?? lastActivityAt` as the turn end time. Skips turns without completion timestamps.
    private static func computeActiveDurationSeconds(from turns: [AgentTranscriptTurn]) -> Int {
        let thirtyMinutes: TimeInterval = 30 * 60
        var totalSeconds = 0
        var previousEnd: Date?

        for turn in turns {
            guard let end = turn.completedAt ?? turn.lastActivityAt else { continue }
            let start = turn.startedAt

            if let prev = previousEnd {
                let gap = start.timeIntervalSince(prev)
                if gap > thirtyMinutes {
                    // Gap exceeds idle threshold; don't count the gap as active time.
                    totalSeconds += Int(end.timeIntervalSince(start))
                } else {
                    // Continuous — count from previous end to this turn's end.
                    totalSeconds += Int(end.timeIntervalSince(prev))
                }
            } else {
                // First turn with timestamps.
                totalSeconds += Int(end.timeIntervalSince(start))
            }

            previousEnd = end
        }

        return max(0, totalSeconds)
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
