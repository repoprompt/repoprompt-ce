import CoreGraphics
import Foundation

public enum AgentTranscriptRetentionTier: String, Codable, Sendable, CaseIterable {
    case full
    case condensed
    case summary
    case archived
}

public enum AgentTranscriptSpanLifecycle: String, Codable, Sendable, Equatable {
    case open
    case completed
    case failed
    case cancelled
}

public enum AgentTranscriptActivityRole: String, Codable, Sendable, Equatable {
    case assistant
    case progress
    case toolExecution
    case note
    case system
    case error
    case thinking
}

public enum AgentTranscriptToolStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case success
    case warning
    case failed
    case cancelled
    case unknown
}

public struct AgentTranscriptToolExecution: Codable, Sendable, Equatable {
    public var stableExecutionID: String
    public var toolName: String?
    public var invocationID: UUID?
    public var argsJSON: String?
    public var resultJSON: String?
    public var toolIsError: Bool?
    public var status: AgentTranscriptToolStatus
    public var summaryOnly: Bool
    public var processID: String?
    public var exitCode: Int?
    public var summaryText: String?
    public var keyPaths: [String]

    public init(
        stableExecutionID: String,
        toolName: String?,
        invocationID: UUID?,
        argsJSON: String?,
        resultJSON: String?,
        toolIsError: Bool?,
        status: AgentTranscriptToolStatus,
        summaryOnly: Bool = false,
        processID: String? = nil,
        exitCode: Int? = nil,
        summaryText: String? = nil,
        keyPaths: [String] = []
    ) {
        self.stableExecutionID = stableExecutionID
        self.toolName = toolName
        self.invocationID = invocationID
        self.argsJSON = argsJSON
        self.resultJSON = resultJSON
        self.toolIsError = toolIsError
        self.status = status
        self.summaryOnly = summaryOnly
        self.processID = processID
        self.exitCode = exitCode
        self.summaryText = summaryText
        self.keyPaths = keyPaths
    }
}

public struct AgentTranscriptActivity: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var timestamp: Date
    public var sequenceIndex: Int
    public var role: AgentTranscriptActivityRole
    public var itemKind: AgentChatItemKind
    public var text: String
    public var attachments: [AgentImageAttachment]
    public var taggedFileAttachments: [AgentTaggedFileAttachment]
    public var workflow: AgentWorkflowDefinition?
    public var codexGoalMode: AgentCodexGoalModeMetadata?
    public var isLocalControlPlaneEcho: Bool?
    public var isStreaming: Bool
    public var toolExecution: AgentTranscriptToolExecution?
    public var reasoning: String?
    public var isSubstantiveAssistant: Bool
    public var sealsAssistantBoundary: Bool

    public init(
        id: UUID,
        timestamp: Date,
        sequenceIndex: Int,
        role: AgentTranscriptActivityRole,
        itemKind: AgentChatItemKind,
        text: String,
        attachments: [AgentImageAttachment] = [],
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        workflow: AgentWorkflowDefinition? = nil,
        codexGoalMode: AgentCodexGoalModeMetadata? = nil,
        isLocalControlPlaneEcho: Bool? = nil,
        isStreaming: Bool = false,
        toolExecution: AgentTranscriptToolExecution? = nil,
        reasoning: String? = nil,
        isSubstantiveAssistant: Bool = false,
        sealsAssistantBoundary: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sequenceIndex = sequenceIndex
        self.role = role
        self.itemKind = itemKind
        self.text = text
        self.attachments = attachments
        self.taggedFileAttachments = taggedFileAttachments
        self.workflow = workflow
        self.codexGoalMode = codexGoalMode
        self.isLocalControlPlaneEcho = isLocalControlPlaneEcho
        self.isStreaming = isStreaming
        self.toolExecution = toolExecution
        self.reasoning = reasoning
        self.isSubstantiveAssistant = isSubstantiveAssistant
        self.sealsAssistantBoundary = sealsAssistantBoundary
    }

    public init(from item: AgentChatItem, toolExecution: AgentTranscriptToolExecution? = nil, role: AgentTranscriptActivityRole? = nil, sealsAssistantBoundary: Bool = false) {
        id = item.id
        timestamp = item.timestamp
        sequenceIndex = item.sequenceIndex
        self.role = role ?? Self.defaultRole(for: item)
        itemKind = item.kind
        text = item.text
        attachments = item.attachments
        taggedFileAttachments = item.taggedFileAttachments
        workflow = item.workflow
        codexGoalMode = item.codexGoalMode
        isLocalControlPlaneEcho = item.isLocalControlPlaneEcho ? true : nil
        isStreaming = item.isStreaming
        self.toolExecution = toolExecution
        reasoning = item.reasoning
        isSubstantiveAssistant = Self.defaultIsSubstantiveAssistant(for: item)
        self.sealsAssistantBoundary = sealsAssistantBoundary
    }

    public func toItem(text overrideText: String? = nil, isStreaming overrideStreaming: Bool? = nil) -> AgentChatItem {
        AgentChatItem(
            id: id,
            timestamp: timestamp,
            kind: itemKind,
            text: overrideText ?? text,
            attachments: attachments,
            taggedFileAttachments: taggedFileAttachments,
            toolName: toolExecution?.toolName,
            toolInvocationID: toolExecution?.invocationID,
            toolArgsJSON: toolExecution?.argsJSON,
            toolResultJSON: toolExecution?.resultJSON,
            toolIsError: toolExecution?.toolIsError,
            reasoning: reasoning,
            sequenceIndex: sequenceIndex,
            isStreaming: overrideStreaming ?? isStreaming,
            workflow: workflow,
            codexGoalMode: codexGoalMode,
            isLocalControlPlaneEcho: isLocalControlPlaneEcho ?? false
        )
    }

    private static func defaultRole(for item: AgentChatItem) -> AgentTranscriptActivityRole {
        switch item.kind {
        case .assistant, .assistantInline:
            .assistant
        case .toolCall, .toolResult:
            .toolExecution
        case .system:
            .system
        case .error:
            .error
        case .thinking:
            .thinking
        case .user:
            .note
        }
    }

    private static func defaultIsSubstantiveAssistant(for item: AgentChatItem) -> Bool {
        guard item.kind == .assistant || item.kind == .assistantInline else { return false }
        guard AgentDisplayableText.hasDisplayableBody(item.text) else { return false }
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !item.attachments.isEmpty || !item.taggedFileAttachments.isEmpty || item.workflow != nil {
            return true
        }
        if trimmed.contains("\n") || trimmed.count >= 80 || trimmed.contains("```") {
            return true
        }
        let markdownHeavyMarkers = ["- ", "* ", "1. ", "## ", "### "]
        if markdownHeavyMarkers.contains(where: { trimmed.contains($0) }) {
            return true
        }
        let lowered = trimmed.lowercased()
        let lowSignalPrefixes = [
            "checking", "looking", "searching", "reading", "running", "thinking",
            "inspecting", "opening", "fetching", "planning", "using tool", "verifying",
            "validating", "confirming", "reviewing", "scanning", "probing", "trying",
            "applying", "editing", "updating"
        ]
        if lowSignalPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return false
        }
        if let lastCharacter = trimmed.last, ".!?".contains(lastCharacter) {
            return true
        }
        if trimmed.contains(":"), trimmed.count >= 24 {
            return true
        }
        return false
    }
}

public struct AgentTranscriptRequestAnchor: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var timestamp: Date
    public var sequenceIndex: Int
    public var text: String
    public var attachments: [AgentImageAttachment]
    public var taggedFileAttachments: [AgentTaggedFileAttachment]
    public var workflow: AgentWorkflowDefinition?
    public var codexGoalMode: AgentCodexGoalModeMetadata?
    public var isLocalControlPlaneEcho: Bool?

    public init(from item: AgentChatItem) {
        id = item.id
        timestamp = item.timestamp
        sequenceIndex = item.sequenceIndex
        text = item.text
        attachments = item.attachments
        taggedFileAttachments = item.taggedFileAttachments
        workflow = item.workflow
        codexGoalMode = item.codexGoalMode
        isLocalControlPlaneEcho = item.isLocalControlPlaneEcho ? true : nil
    }

    public func toItem() -> AgentChatItem {
        AgentChatItem(
            id: id,
            timestamp: timestamp,
            kind: .user,
            text: text,
            attachments: attachments,
            taggedFileAttachments: taggedFileAttachments,
            sequenceIndex: sequenceIndex,
            workflow: workflow,
            codexGoalMode: codexGoalMode,
            isLocalControlPlaneEcho: isLocalControlPlaneEcho ?? false
        )
    }
}

public struct AgentTranscriptTurnSummary: Codable, Sendable, Equatable {
    public var middleSummaryItemID: UUID
    public var requestText: String?
    public var conclusionText: String?
    public var compactConclusionText: String?
    public var middleSummaryText: String?
    public var toolCount: Int
    public var notableToolNames: [String]
    public var keyPaths: [String]
    public var compactedActivityCount: Int
    public var hadWarning: Bool
    public var hadError: Bool
    public var lastUserInteractionAt: Date?

    public init(
        middleSummaryItemID: UUID = UUID(),
        requestText: String?,
        conclusionText: String?,
        compactConclusionText: String?,
        middleSummaryText: String?,
        toolCount: Int,
        notableToolNames: [String],
        keyPaths: [String],
        compactedActivityCount: Int,
        hadWarning: Bool,
        hadError: Bool,
        lastUserInteractionAt: Date? = nil
    ) {
        self.middleSummaryItemID = middleSummaryItemID
        self.requestText = requestText
        self.conclusionText = conclusionText
        self.compactConclusionText = compactConclusionText
        self.middleSummaryText = middleSummaryText
        self.toolCount = toolCount
        self.notableToolNames = notableToolNames
        self.keyPaths = keyPaths
        self.compactedActivityCount = compactedActivityCount
        self.hadWarning = hadWarning
        self.hadError = hadError
        self.lastUserInteractionAt = lastUserInteractionAt
    }
}

struct AgentTranscriptFullRenderGroupedHistoryCache: Equatable {
    let detailedToolTailLimit: Int
    let collapseDigest: String
    let summary: AgentTranscriptGroupedHistorySummary
}

public struct AgentTranscriptProviderResponseSpan: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var providerTurnID: String?
    public var runID: UUID?
    public var lifecycle: AgentTranscriptSpanLifecycle
    public var startedAt: Date
    public var lastActivityAt: Date?
    public var completedAt: Date?
    public var activities: [AgentTranscriptActivity]
    /// Durable for compacted turns; rebuildable cache for full turns.
    public var collapsedSummary: AgentTranscriptGroupedHistorySummary?
    /// Transient in-memory cache for completed full-turn grouped-history rendering.
    var fullRenderGroupedHistoryCache: AgentTranscriptFullRenderGroupedHistoryCache?

    public init(
        id: UUID = UUID(),
        providerTurnID: String? = nil,
        runID: UUID? = nil,
        lifecycle: AgentTranscriptSpanLifecycle = .open,
        startedAt: Date,
        lastActivityAt: Date? = nil,
        completedAt: Date? = nil,
        activities: [AgentTranscriptActivity] = [],
        collapsedSummary: AgentTranscriptGroupedHistorySummary? = nil
    ) {
        self.id = id
        self.providerTurnID = providerTurnID
        self.runID = runID
        self.lifecycle = lifecycle
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.activities = activities
        self.collapsedSummary = collapsedSummary
        fullRenderGroupedHistoryCache = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerTurnID
        case runID
        case lifecycle
        case startedAt
        case lastActivityAt
        case completedAt
        case activities
        case collapsedSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        providerTurnID = try container.decodeIfPresent(String.self, forKey: .providerTurnID)
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        lifecycle = try container.decode(AgentTranscriptSpanLifecycle.self, forKey: .lifecycle)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        activities = try container.decodeIfPresent([AgentTranscriptActivity].self, forKey: .activities) ?? []
        collapsedSummary = try container.decodeIfPresent(AgentTranscriptGroupedHistorySummary.self, forKey: .collapsedSummary)
        fullRenderGroupedHistoryCache = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(providerTurnID, forKey: .providerTurnID)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(activities, forKey: .activities)
        try container.encodeIfPresent(collapsedSummary, forKey: .collapsedSummary)
    }

    public static func == (lhs: AgentTranscriptProviderResponseSpan, rhs: AgentTranscriptProviderResponseSpan) -> Bool {
        lhs.id == rhs.id
            && lhs.providerTurnID == rhs.providerTurnID
            && lhs.runID == rhs.runID
            && lhs.lifecycle == rhs.lifecycle
            && lhs.startedAt == rhs.startedAt
            && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.completedAt == rhs.completedAt
            && lhs.activities == rhs.activities
            && lhs.collapsedSummary == rhs.collapsedSummary
    }

    public var hasStoredActivities: Bool {
        !activities.isEmpty
    }
}

public struct AgentTranscriptTurn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var request: AgentTranscriptRequestAnchor?
    public var responseSpans: [AgentTranscriptProviderResponseSpan]
    public var conclusionActivityID: UUID?
    public var retentionTier: AgentTranscriptRetentionTier
    /// Durable for non-full turns; rebuildable cache for full turns.
    public var summary: AgentTranscriptTurnSummary?
    public var terminalState: AgentSessionRunState?
    public var startedAt: Date
    public var lastActivityAt: Date?
    public var completedAt: Date?
    /// Durable visibility cap for completed full turns whose tool history collapsed.
    /// `nil` means no cap was needed; frozen caps limit this turn but do not reserve global tail budget.
    public var frozenDetailedToolTailLimit: Int?

    public init(
        id: UUID = UUID(),
        request: AgentTranscriptRequestAnchor? = nil,
        responseSpans: [AgentTranscriptProviderResponseSpan] = [],
        conclusionActivityID: UUID? = nil,
        retentionTier: AgentTranscriptRetentionTier = .full,
        summary: AgentTranscriptTurnSummary? = nil,
        terminalState: AgentSessionRunState? = nil,
        startedAt: Date,
        lastActivityAt: Date? = nil,
        completedAt: Date? = nil,
        frozenDetailedToolTailLimit: Int? = nil
    ) {
        self.id = id
        self.request = request
        self.responseSpans = responseSpans
        self.conclusionActivityID = conclusionActivityID
        self.retentionTier = retentionTier
        self.summary = summary
        self.terminalState = terminalState
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.frozenDetailedToolTailLimit = frozenDetailedToolTailLimit
    }

    enum CodingKeys: String, CodingKey {
        case id
        case request
        case responseSpans
        case conclusionActivityID
        case retentionTier
        case summary
        case terminalState
        case startedAt
        case lastActivityAt
        case completedAt
        case frozenDetailedToolTailLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        request = try container.decodeIfPresent(AgentTranscriptRequestAnchor.self, forKey: .request)
        responseSpans = try container.decodeIfPresent([AgentTranscriptProviderResponseSpan].self, forKey: .responseSpans) ?? []
        conclusionActivityID = try container.decodeIfPresent(UUID.self, forKey: .conclusionActivityID)
        retentionTier = try container.decode(AgentTranscriptRetentionTier.self, forKey: .retentionTier)
        summary = try container.decodeIfPresent(AgentTranscriptTurnSummary.self, forKey: .summary)
        terminalState = try container.decodeIfPresent(AgentSessionRunState.self, forKey: .terminalState)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        frozenDetailedToolTailLimit = try container.decodeIfPresent(Int.self, forKey: .frozenDetailedToolTailLimit)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(request, forKey: .request)
        try container.encode(responseSpans, forKey: .responseSpans)
        try container.encodeIfPresent(conclusionActivityID, forKey: .conclusionActivityID)
        try container.encode(retentionTier, forKey: .retentionTier)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(terminalState, forKey: .terminalState)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(frozenDetailedToolTailLimit, forKey: .frozenDetailedToolTailLimit)
    }

    public var isCompleted: Bool {
        completedAt != nil || !(terminalState?.isActive ?? false)
    }

    public var allActivities: [AgentTranscriptActivity] {
        responseSpans.flatMap(\.activities).sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
    }

    public var hasStoredActivities: Bool {
        responseSpans.contains(where: { !$0.activities.isEmpty })
    }

    public var isStructurallyCompacted: Bool {
        retentionTier != .full && !hasStoredActivities
    }
}

public struct AgentTranscriptCompactionFrontier: Codable, Sendable, Equatable {
    public var version: Int
    public var frozenPrefixTurnCount: Int
    public var lastFrozenTurnID: UUID

    public init(version: Int = 1, frozenPrefixTurnCount: Int, lastFrozenTurnID: UUID) {
        self.version = version
        self.frozenPrefixTurnCount = frozenPrefixTurnCount
        self.lastFrozenTurnID = lastFrozenTurnID
    }
}

public struct AgentTranscript: Codable, Sendable, Equatable {
    public var version: Int
    public var turns: [AgentTranscriptTurn]
    public var nextSequenceIndex: Int
    public var compactionFrontier: AgentTranscriptCompactionFrontier?

    public init(
        version: Int = 3,
        turns: [AgentTranscriptTurn] = [],
        nextSequenceIndex: Int = 0,
        compactionFrontier: AgentTranscriptCompactionFrontier? = nil
    ) {
        self.version = version
        self.turns = turns
        self.nextSequenceIndex = nextSequenceIndex
        self.compactionFrontier = compactionFrontier
    }

    public static let empty = AgentTranscript()

    public var allActivities: [AgentTranscriptActivity] {
        turns.flatMap(\.allActivities).sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
    }
}

public enum AgentTranscriptAnchor: Hashable, Sendable {
    case request(turnID: UUID)
    case activity(turnID: UUID, spanID: UUID, activityID: UUID)
    case conclusion(turnID: UUID, activityID: UUID)
    case summary(turnID: UUID)
    case groupedHistory(turnID: UUID, spanID: UUID)
}

public enum AgentTranscriptViewportTargetID: Hashable, Sendable {
    case row(UUID)
    case block(String)
}

enum AgentDetachedAuthorityFamily: Equatable {
    case request(UUID)
    case responseSpan(turnID: UUID, spanID: UUID)
    case conclusion(UUID)
    case summary(UUID)
}

func agentDetachedAuthorityFamily(for anchor: AgentTranscriptAnchor?) -> AgentDetachedAuthorityFamily? {
    guard let anchor else { return nil }
    switch anchor {
    case let .request(turnID):
        return .request(turnID)
    case let .activity(turnID, spanID, _), let .groupedHistory(turnID, spanID):
        return .responseSpan(turnID: turnID, spanID: spanID)
    case let .conclusion(turnID, _):
        return .conclusion(turnID)
    case let .summary(turnID):
        return .summary(turnID)
    }
}

struct DetachedViewportAuthority: Equatable {
    let targetID: AgentTranscriptViewportTargetID?
    let anchor: AgentTranscriptAnchor?
    let sequenceIndex: Int?
    let blockID: String?
    let viewportMinY: CGFloat?

    var family: AgentDetachedAuthorityFamily? {
        agentDetachedAuthorityFamily(for: anchor)
    }

    var specificityRank: Int {
        switch (anchor, targetID) {
        case (.activity(_, _, _), .row(_)):
            4
        case (.activity(_, _, _), _):
            3
        case (.groupedHistory(_, _), .row(_)):
            3
        case (.groupedHistory(_, _), _):
            1
        case (_, .row(_)):
            2
        case (_, .block(_)):
            1
        case (.request(_), _), (.conclusion(_, _), _), (.summary(_), _):
            2
        case (nil, nil):
            0
        }
    }

    func isSameFamily(as other: DetachedViewportAuthority) -> Bool {
        family != nil && family == other.family
    }
}

func preferredDetachedPersistenceAuthority(
    stored: DetachedViewportAuthority?,
    live: DetachedViewportAuthority?
) -> DetachedViewportAuthority? {
    guard let live else { return stored }
    guard let stored else { return live }
    guard stored.isSameFamily(as: live) else {
        return live
    }
    if stored.specificityRank > live.specificityRank {
        return stored
    }
    return live
}

struct AgentDetachedRebaseDecisionContext {
    let storedFamily: AgentDetachedAuthorityFamily?
    let liveFamily: AgentDetachedAuthorityFamily?
    let deltaY: CGFloat?
    let viewportHeight: CGFloat
    let missingLiveAuthorityCount: Int
}

enum AgentDetachedRebaseAction: Equatable {
    case none
    case acceptDrift
    case restoreIntent
}

func decideAgentDetachedRebaseAction(_ context: AgentDetachedRebaseDecisionContext) -> AgentDetachedRebaseAction {
    if context.liveFamily == nil {
        return context.missingLiveAuthorityCount <= 1 ? .acceptDrift : .restoreIntent
    }
    if let storedFamily = context.storedFamily,
       let liveFamily = context.liveFamily,
       storedFamily != liveFamily
    {
        return .restoreIntent
    }
    guard let deltaY = context.deltaY else { return .acceptDrift }
    let magnitude = abs(deltaY)
    if magnitude <= 8 {
        return .none
    }
    if magnitude <= 24 {
        return .acceptDrift
    }
    let compensationUpperBound = min(96, context.viewportHeight * 0.18)
    if magnitude <= compensationUpperBound {
        return .restoreIntent
    }
    return .restoreIntent
}

struct AgentTranscriptViewportState: Equatable {
    var isDetachedFromLiveBottom: Bool
    var detachedAuthority: DetachedViewportAuthority?

    static let liveBottom = Self(isDetachedFromLiveBottom: false, detachedAuthority: nil)

    var effectiveDetachedAuthority: DetachedViewportAuthority? {
        isDetachedFromLiveBottom ? detachedAuthority : nil
    }
}

enum AgentTranscriptProjectionProtection: Equatable {
    case none
    case protectedTurn(UUID)

    var protectedTurnID: UUID? {
        guard case let .protectedTurn(turnID) = self else { return nil }
        return turnID
    }
}

public enum AgentTranscriptRenderBlockKind: String, Sendable, Equatable {
    case request
    case activityCluster
    case groupedHistory
    case collapsedHistoryRange
    case standaloneAssistant
    case standaloneTool
    case standaloneNote
    case middleSummary
    case conclusion
}

public enum AgentTranscriptBlockPresentation: String, Sendable, Equatable {
    case expanded
    case collapsed
}

public enum AgentTranscriptCollapsedSummaryStatus: String, Codable, Sendable, Equatable {
    case neutral
    case running
    case warning
    case failure
}

public struct AgentTranscriptCollapsedSummaryDisplay: Codable, Sendable, Equatable {
    public let title: String
    public let count: Int?
    public let detailText: String?
    /// Narration text (assistant message excerpt), shown on the detail row when present.
    public let narrationText: String?
    /// Tool group chip text (e.g. "Read File ×11, Edit ×2"), shown on the title row when narration is present.
    public let toolGroupText: String?
    public let status: AgentTranscriptCollapsedSummaryStatus

    public init(
        title: String,
        count: Int? = nil,
        detailText: String? = nil,
        narrationText: String? = nil,
        toolGroupText: String? = nil,
        status: AgentTranscriptCollapsedSummaryStatus = .neutral
    ) {
        self.title = title
        self.count = count
        self.detailText = detailText
        self.narrationText = narrationText
        self.toolGroupText = toolGroupText
        self.status = status
    }
}

/// Pre-computed tool group for display in collapsed cluster cards.
/// Built once in the service layer so the view doesn't need to recompute.
public struct ClusterToolGroup: Codable, Sendable, Equatable {
    public let icon: String
    public let label: String

    public init(icon: String, label: String) {
        self.icon = icon
        self.label = label
    }
}

public struct AgentTranscriptClusterSummary: Codable, Sendable, Equatable {
    public let toolCount: Int
    public let toolNames: [String]
    public let toolNameCounts: [String: Int]
    /// Pre-computed grouped chips (Navigation ×4, Edit ×2, etc.) — ready for direct rendering.
    public let toolGroups: [ClusterToolGroup]
    public let keyPaths: [String]
    public let containsRunningWork: Bool
    public let containsFailure: Bool
    public let containsWarning: Bool
    public let shortNarration: String?
    public let collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay?

    public init(
        toolCount: Int,
        toolNames: [String],
        toolNameCounts: [String: Int] = [:],
        toolGroups: [ClusterToolGroup] = [],
        keyPaths: [String],
        containsRunningWork: Bool,
        containsFailure: Bool,
        containsWarning: Bool,
        shortNarration: String?,
        collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay? = nil
    ) {
        self.toolCount = toolCount
        self.toolNames = toolNames
        self.toolNameCounts = toolNameCounts
        self.toolGroups = toolGroups
        self.keyPaths = keyPaths
        self.containsRunningWork = containsRunningWork
        self.containsFailure = containsFailure
        self.containsWarning = containsWarning
        self.shortNarration = shortNarration
        self.collapsedDisplay = collapsedDisplay
    }
}

public enum AgentTranscriptGroupedSectionKind: String, Sendable, Equatable {
    case assistant
    case tools
    case progress
    case notes
    case mixed
}

public struct AgentTranscriptGroupedHistorySummary: Codable, Sendable, Equatable {
    public let hiddenToolCardCount: Int
    public let hiddenAssistantCount: Int
    public let hiddenProgressCount: Int
    public let hiddenNoteCount: Int
    public let toolSummary: AgentTranscriptClusterSummary?
    public let collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay?

    public init(
        hiddenToolCardCount: Int,
        hiddenAssistantCount: Int,
        hiddenProgressCount: Int,
        hiddenNoteCount: Int,
        toolSummary: AgentTranscriptClusterSummary?,
        collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay? = nil
    ) {
        self.hiddenToolCardCount = hiddenToolCardCount
        self.hiddenAssistantCount = hiddenAssistantCount
        self.hiddenProgressCount = hiddenProgressCount
        self.hiddenNoteCount = hiddenNoteCount
        self.toolSummary = toolSummary
        self.collapsedDisplay = collapsedDisplay
    }
}

public struct AgentTranscriptGroupedSection: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: AgentTranscriptGroupedSectionKind
    public let title: String?
    public let icon: String?
    public let childBlocks: [AgentTranscriptRenderBlock]
    public let clusterSummary: AgentTranscriptClusterSummary?

    public init(
        id: String,
        kind: AgentTranscriptGroupedSectionKind,
        title: String? = nil,
        icon: String? = nil,
        childBlocks: [AgentTranscriptRenderBlock],
        clusterSummary: AgentTranscriptClusterSummary? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.icon = icon
        self.childBlocks = childBlocks
        self.clusterSummary = clusterSummary
    }
}

public struct AgentTranscriptGroupedHistory: Sendable, Equatable {
    public let summary: AgentTranscriptGroupedHistorySummary
    public let sections: [AgentTranscriptGroupedSection]

    public init(
        summary: AgentTranscriptGroupedHistorySummary,
        sections: [AgentTranscriptGroupedSection]
    ) {
        self.summary = summary
        self.sections = sections
    }
}

public struct AgentTranscriptCollapsedHistoryRange: Sendable, Equatable {
    public let hiddenTurnCount: Int

    public init(hiddenTurnCount: Int) {
        self.hiddenTurnCount = max(0, hiddenTurnCount)
    }
}

public struct AgentTranscriptRenderBlock: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: AgentTranscriptRenderBlockKind
    public let turnID: UUID
    public let spanID: UUID?
    public let retentionTier: AgentTranscriptRetentionTier
    public let rows: [AgentChatItem]
    public let isArchived: Bool
    public let primaryAnchor: AgentTranscriptAnchor?
    public let anchorActivityID: UUID?
    public let activityIDs: [UUID]
    public let clusterSummary: AgentTranscriptClusterSummary?
    public let groupedHistory: AgentTranscriptGroupedHistory?
    public let collapsedHistoryRange: AgentTranscriptCollapsedHistoryRange?
    public let defaultPresentation: AgentTranscriptBlockPresentation

    public init(
        id: String,
        kind: AgentTranscriptRenderBlockKind,
        turnID: UUID,
        spanID: UUID? = nil,
        retentionTier: AgentTranscriptRetentionTier,
        rows: [AgentChatItem],
        isArchived: Bool,
        primaryAnchor: AgentTranscriptAnchor? = nil,
        anchorActivityID: UUID? = nil,
        activityIDs: [UUID] = [],
        clusterSummary: AgentTranscriptClusterSummary? = nil,
        groupedHistory: AgentTranscriptGroupedHistory? = nil,
        collapsedHistoryRange: AgentTranscriptCollapsedHistoryRange? = nil,
        defaultPresentation: AgentTranscriptBlockPresentation = .expanded
    ) {
        self.id = id
        self.kind = kind
        self.turnID = turnID
        self.spanID = spanID
        self.retentionTier = retentionTier
        self.rows = rows
        self.isArchived = isArchived
        self.primaryAnchor = primaryAnchor
        self.anchorActivityID = anchorActivityID
        self.activityIDs = activityIDs
        self.clusterSummary = clusterSummary
        self.groupedHistory = groupedHistory
        self.collapsedHistoryRange = collapsedHistoryRange
        self.defaultPresentation = defaultPresentation
    }
}

public struct AgentTranscriptProjection: Sendable, Equatable {
    public var workingBlocks: [AgentTranscriptRenderBlock]
    public var archivedBlocks: [AgentTranscriptRenderBlock]
    public var workingRows: [AgentChatItem]
    public var archivedRows: [AgentChatItem]
    public var rowAnchorIndex: [UUID: AgentTranscriptAnchor]
    public var anchorBlockIndex: [AgentTranscriptAnchor: String]
    public var workingUnitCount: Int

    public init(
        workingBlocks: [AgentTranscriptRenderBlock] = [],
        archivedBlocks: [AgentTranscriptRenderBlock] = [],
        workingRows: [AgentChatItem] = [],
        archivedRows: [AgentChatItem] = [],
        rowAnchorIndex: [UUID: AgentTranscriptAnchor] = [:],
        anchorBlockIndex: [AgentTranscriptAnchor: String] = [:],
        workingUnitCount: Int = 0
    ) {
        self.workingBlocks = workingBlocks
        self.archivedBlocks = archivedBlocks
        self.workingRows = workingRows
        self.archivedRows = archivedRows
        self.rowAnchorIndex = rowAnchorIndex
        self.anchorBlockIndex = anchorBlockIndex
        self.workingUnitCount = workingUnitCount
    }

    public static let empty = AgentTranscriptProjection()
}

struct AgentTranscriptPresentationMetadata: Equatable {
    let latestUserMessageID: UUID?
    let latestTurnID: UUID?
    let dynamicSummaryLockTargetTurnID: UUID?
    let recentAssistantItemIDs: Set<UUID>
    let activeContextBuilderCallItemID: UUID?
    let activeContextBuilderResultItemID: UUID?
    let mostRecentEditItemID: UUID?

    init(
        latestUserMessageID: UUID? = nil,
        latestTurnID: UUID? = nil,
        dynamicSummaryLockTargetTurnID: UUID? = nil,
        recentAssistantItemIDs: Set<UUID> = [],
        activeContextBuilderCallItemID: UUID? = nil,
        activeContextBuilderResultItemID: UUID? = nil,
        mostRecentEditItemID: UUID? = nil
    ) {
        self.latestUserMessageID = latestUserMessageID
        self.latestTurnID = latestTurnID
        self.dynamicSummaryLockTargetTurnID = dynamicSummaryLockTargetTurnID
        self.recentAssistantItemIDs = recentAssistantItemIDs
        self.activeContextBuilderCallItemID = activeContextBuilderCallItemID
        self.activeContextBuilderResultItemID = activeContextBuilderResultItemID
        self.mostRecentEditItemID = mostRecentEditItemID
    }

    static let empty = AgentTranscriptPresentationMetadata()
}

struct AgentTranscriptPresentationSnapshot: Equatable {
    let tabID: UUID?
    let revision: Int
    let visibleBlocks: [AgentTranscriptRenderBlock]
    let workingBlocks: [AgentTranscriptRenderBlock]
    let visibleRows: [AgentChatItem]
    let workingRows: [AgentChatItem]
    let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
    let anchorBlockIndex: [AgentTranscriptAnchor: String]
    let archivedHistoryState: AgentArchivedHistoryState
    let isCompressedHistoryRevealed: Bool
    let isTranscriptWindowExpanded: Bool
    let isWindowCappedWhileActive: Bool
    let bindingsHydrated: Bool
    let hydratedPersistentBinding: AgentPersistentSessionBindingIdentity?
    let hydratedBindingTransitionGeneration: UInt64?
    let performanceSnapshot: AgentTranscriptPerformanceSnapshot
    let metadata: AgentTranscriptPresentationMetadata
    let rawToolResultPayloadRenderRevision: Int

    init(
        tabID: UUID? = nil,
        revision: Int = 0,
        visibleBlocks: [AgentTranscriptRenderBlock] = [],
        workingBlocks: [AgentTranscriptRenderBlock] = [],
        visibleRows: [AgentChatItem] = [],
        workingRows: [AgentChatItem] = [],
        rowAnchorIndex: [UUID: AgentTranscriptAnchor] = [:],
        anchorBlockIndex: [AgentTranscriptAnchor: String] = [:],
        archivedHistoryState: AgentArchivedHistoryState = .empty,
        isCompressedHistoryRevealed: Bool = false,
        isTranscriptWindowExpanded: Bool = false,
        isWindowCappedWhileActive: Bool = false,
        bindingsHydrated: Bool = true,
        hydratedPersistentBinding: AgentPersistentSessionBindingIdentity? = nil,
        hydratedBindingTransitionGeneration: UInt64? = nil,
        performanceSnapshot: AgentTranscriptPerformanceSnapshot = .empty,
        metadata: AgentTranscriptPresentationMetadata = .empty,
        rawToolResultPayloadRenderRevision: Int = 0
    ) {
        self.tabID = tabID
        self.revision = revision
        self.visibleBlocks = visibleBlocks
        self.workingBlocks = workingBlocks
        self.visibleRows = visibleRows
        self.workingRows = workingRows
        self.rowAnchorIndex = rowAnchorIndex
        self.anchorBlockIndex = anchorBlockIndex
        self.archivedHistoryState = archivedHistoryState
        self.isCompressedHistoryRevealed = isCompressedHistoryRevealed
        self.isTranscriptWindowExpanded = isTranscriptWindowExpanded
        self.isWindowCappedWhileActive = isWindowCappedWhileActive
        self.bindingsHydrated = bindingsHydrated
        self.hydratedPersistentBinding = hydratedPersistentBinding
        self.hydratedBindingTransitionGeneration = hydratedBindingTransitionGeneration
        self.performanceSnapshot = performanceSnapshot
        self.metadata = metadata
        self.rawToolResultPayloadRenderRevision = rawToolResultPayloadRenderRevision
    }

    func contentEqualsExcludingPerformance(_ other: Self) -> Bool {
        tabID == other.tabID
            && visibleBlocks == other.visibleBlocks
            && workingBlocks == other.workingBlocks
            && visibleRows == other.visibleRows
            && workingRows == other.workingRows
            && rowAnchorIndex == other.rowAnchorIndex
            && anchorBlockIndex == other.anchorBlockIndex
            && archivedHistoryState == other.archivedHistoryState
            && isCompressedHistoryRevealed == other.isCompressedHistoryRevealed
            && isTranscriptWindowExpanded == other.isTranscriptWindowExpanded
            && isWindowCappedWhileActive == other.isWindowCappedWhileActive
            && bindingsHydrated == other.bindingsHydrated
            && hydratedPersistentBinding == other.hydratedPersistentBinding
            && hydratedBindingTransitionGeneration == other.hydratedBindingTransitionGeneration
            && metadata == other.metadata
            && rawToolResultPayloadRenderRevision == other.rawToolResultPayloadRenderRevision
    }

    func hasVisiblePresentationDelta(comparedTo other: Self) -> Bool {
        visibleBlocks != other.visibleBlocks
            || visibleRows != other.visibleRows
            || archivedHistoryState != other.archivedHistoryState
            || isCompressedHistoryRevealed != other.isCompressedHistoryRevealed
            || isTranscriptWindowExpanded != other.isTranscriptWindowExpanded
            || isWindowCappedWhileActive != other.isWindowCappedWhileActive
            || rawToolResultPayloadRenderRevision != other.rawToolResultPayloadRenderRevision
    }

    static let empty = AgentTranscriptPresentationSnapshot()
}

struct AgentArchivedHistoryState: Equatable {
    let hasArchivedHistory: Bool
    let presentedRowCount: Int
    let blockCount: Int

    init(
        hasArchivedHistory: Bool = false,
        presentedRowCount: Int = 0,
        blockCount: Int = 0
    ) {
        self.hasArchivedHistory = hasArchivedHistory
        self.presentedRowCount = max(0, presentedRowCount)
        self.blockCount = max(0, blockCount)
    }

    static let empty = AgentArchivedHistoryState()
}

struct AgentArchivedTranscriptSnapshot: Equatable {
    let blocks: [AgentTranscriptRenderBlock]
    let rows: [AgentChatItem]
    let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
    let anchorBlockIndex: [AgentTranscriptAnchor: String]
    let compressedItems: [CompressedTranscriptItem]
    let presentedRowCount: Int
    let blockCount: Int

    init(
        blocks: [AgentTranscriptRenderBlock] = [],
        rows: [AgentChatItem] = [],
        rowAnchorIndex: [UUID: AgentTranscriptAnchor] = [:],
        anchorBlockIndex: [AgentTranscriptAnchor: String] = [:],
        compressedItems: [CompressedTranscriptItem] = [],
        presentedRowCount: Int = 0,
        blockCount: Int = 0
    ) {
        self.blocks = blocks
        self.rows = rows
        self.rowAnchorIndex = rowAnchorIndex
        self.anchorBlockIndex = anchorBlockIndex
        self.compressedItems = compressedItems
        self.presentedRowCount = max(0, presentedRowCount)
        self.blockCount = max(0, blockCount)
    }

    var historyState: AgentArchivedHistoryState {
        .init(
            hasArchivedHistory: !blocks.isEmpty || !rows.isEmpty,
            presentedRowCount: presentedRowCount,
            blockCount: blockCount
        )
    }

    static let empty = AgentArchivedTranscriptSnapshot()
}

public struct AgentTranscriptProjectionCounts: Codable, Sendable, Equatable {
    public let canonicalVisibleRowCount: Int
    public let defaultPresentedRowCount: Int

    public var hiddenArchivedRowCount: Int {
        max(0, canonicalVisibleRowCount - defaultPresentedRowCount)
    }

    public init(
        canonicalVisibleRowCount: Int = 0,
        defaultPresentedRowCount: Int = 0
    ) {
        self.canonicalVisibleRowCount = max(0, canonicalVisibleRowCount)
        self.defaultPresentedRowCount = max(0, min(defaultPresentedRowCount, self.canonicalVisibleRowCount))
    }

    public static let zero = AgentTranscriptProjectionCounts()
}

struct AgentToolResultProcessingMetrics: Equatable {
    var jsonParseAttemptCount: Int
    var jsonParseCacheHitCount: Int
    var jsonParseCacheMissCount: Int
    var jsonParseSuccessCount: Int
    var jsonParseFailureCount: Int
    var jsonParseByteCount: Int
    var toolExecutionCacheHitCount: Int
    var toolExecutionCacheMissCount: Int
    var bashMetadataCacheHitCount: Int
    var bashMetadataCacheMissCount: Int
    var regexCaptureCallCount: Int

    init(
        jsonParseAttemptCount: Int = 0,
        jsonParseCacheHitCount: Int = 0,
        jsonParseCacheMissCount: Int = 0,
        jsonParseSuccessCount: Int = 0,
        jsonParseFailureCount: Int = 0,
        jsonParseByteCount: Int = 0,
        toolExecutionCacheHitCount: Int = 0,
        toolExecutionCacheMissCount: Int = 0,
        bashMetadataCacheHitCount: Int = 0,
        bashMetadataCacheMissCount: Int = 0,
        regexCaptureCallCount: Int = 0
    ) {
        self.jsonParseAttemptCount = jsonParseAttemptCount
        self.jsonParseCacheHitCount = jsonParseCacheHitCount
        self.jsonParseCacheMissCount = jsonParseCacheMissCount
        self.jsonParseSuccessCount = jsonParseSuccessCount
        self.jsonParseFailureCount = jsonParseFailureCount
        self.jsonParseByteCount = jsonParseByteCount
        self.toolExecutionCacheHitCount = toolExecutionCacheHitCount
        self.toolExecutionCacheMissCount = toolExecutionCacheMissCount
        self.bashMetadataCacheHitCount = bashMetadataCacheHitCount
        self.bashMetadataCacheMissCount = bashMetadataCacheMissCount
        self.regexCaptureCallCount = regexCaptureCallCount
    }

    static let zero = AgentToolResultProcessingMetrics()

    mutating func add(_ other: AgentToolResultProcessingMetrics) {
        jsonParseAttemptCount += other.jsonParseAttemptCount
        jsonParseCacheHitCount += other.jsonParseCacheHitCount
        jsonParseCacheMissCount += other.jsonParseCacheMissCount
        jsonParseSuccessCount += other.jsonParseSuccessCount
        jsonParseFailureCount += other.jsonParseFailureCount
        jsonParseByteCount += other.jsonParseByteCount
        toolExecutionCacheHitCount += other.toolExecutionCacheHitCount
        toolExecutionCacheMissCount += other.toolExecutionCacheMissCount
        bashMetadataCacheHitCount += other.bashMetadataCacheHitCount
        bashMetadataCacheMissCount += other.bashMetadataCacheMissCount
        regexCaptureCallCount += other.regexCaptureCallCount
    }
}

struct AgentTranscriptPerformanceSnapshot: Equatable {
    var projectionBuildCount: Int
    var projectionPublishCount: Int
    var lastProjectionBuildDurationMS: Double?
    var maxProjectionBuildDurationMS: Double?
    var lastColdLoadProjectionBuildDurationMS: Double?
    var refreshRequestCount: Int
    var refreshCoalescedCount: Int
    var refreshImmediateCount: Int
    var lastRefreshTotalDurationMS: Double?
    var maxRefreshTotalDurationMS: Double?
    var lastImportDurationMS: Double?
    var maxImportDurationMS: Double?
    var incrementalImportAttemptCount: Int
    var incrementalImportSuccessCount: Int
    var incrementalImportFallbackCount: Int
    var frontierReuseAttemptCount: Int
    var frontierReuseSuccessCount: Int
    var frontierReuseFallbackCount: Int
    var lastIncrementalImportDurationMS: Double?
    var maxIncrementalImportDurationMS: Double?
    var lastPayloadCaptureDurationMS: Double?
    var maxPayloadCaptureDurationMS: Double?
    var lastSanitizeDurationMS: Double?
    var maxSanitizeDurationMS: Double?
    var sanitizeReuseAttemptCount: Int
    var sanitizeReuseSuccessCount: Int
    var sanitizeReuseFallbackCount: Int
    var projectionReuseAttemptCount: Int
    var projectionReuseSuccessCount: Int
    var projectionReuseFallbackCount: Int
    var lastSourceItemCount: Int?
    var lastPayloadCaptureScannedItemCount: Int?
    var lastSanitizedActivityCount: Int?
    var lastSanitizeReusedTurnCount: Int?
    var lastProjectionReusedTurnCount: Int?
    var retainedRawPayloadEntryCount: Int
    var retainedRawPayloadTotalBytes: Int
    var lastToolProcessingMetrics: AgentToolResultProcessingMetrics
    var cumulativeToolProcessingMetrics: AgentToolResultProcessingMetrics

    init(
        projectionBuildCount: Int = 0,
        projectionPublishCount: Int = 0,
        lastProjectionBuildDurationMS: Double? = nil,
        maxProjectionBuildDurationMS: Double? = nil,
        lastColdLoadProjectionBuildDurationMS: Double? = nil,
        refreshRequestCount: Int = 0,
        refreshCoalescedCount: Int = 0,
        refreshImmediateCount: Int = 0,
        lastRefreshTotalDurationMS: Double? = nil,
        maxRefreshTotalDurationMS: Double? = nil,
        lastImportDurationMS: Double? = nil,
        maxImportDurationMS: Double? = nil,
        incrementalImportAttemptCount: Int = 0,
        incrementalImportSuccessCount: Int = 0,
        incrementalImportFallbackCount: Int = 0,
        frontierReuseAttemptCount: Int = 0,
        frontierReuseSuccessCount: Int = 0,
        frontierReuseFallbackCount: Int = 0,
        lastIncrementalImportDurationMS: Double? = nil,
        maxIncrementalImportDurationMS: Double? = nil,
        lastPayloadCaptureDurationMS: Double? = nil,
        maxPayloadCaptureDurationMS: Double? = nil,
        lastSanitizeDurationMS: Double? = nil,
        maxSanitizeDurationMS: Double? = nil,
        sanitizeReuseAttemptCount: Int = 0,
        sanitizeReuseSuccessCount: Int = 0,
        sanitizeReuseFallbackCount: Int = 0,
        projectionReuseAttemptCount: Int = 0,
        projectionReuseSuccessCount: Int = 0,
        projectionReuseFallbackCount: Int = 0,
        lastSourceItemCount: Int? = nil,
        lastPayloadCaptureScannedItemCount: Int? = nil,
        lastSanitizedActivityCount: Int? = nil,
        lastSanitizeReusedTurnCount: Int? = nil,
        lastProjectionReusedTurnCount: Int? = nil,
        retainedRawPayloadEntryCount: Int = 0,
        retainedRawPayloadTotalBytes: Int = 0,
        lastToolProcessingMetrics: AgentToolResultProcessingMetrics = .zero,
        cumulativeToolProcessingMetrics: AgentToolResultProcessingMetrics = .zero
    ) {
        self.projectionBuildCount = projectionBuildCount
        self.projectionPublishCount = projectionPublishCount
        self.lastProjectionBuildDurationMS = lastProjectionBuildDurationMS
        self.maxProjectionBuildDurationMS = maxProjectionBuildDurationMS
        self.lastColdLoadProjectionBuildDurationMS = lastColdLoadProjectionBuildDurationMS
        self.refreshRequestCount = refreshRequestCount
        self.refreshCoalescedCount = refreshCoalescedCount
        self.refreshImmediateCount = refreshImmediateCount
        self.lastRefreshTotalDurationMS = lastRefreshTotalDurationMS
        self.maxRefreshTotalDurationMS = maxRefreshTotalDurationMS
        self.lastImportDurationMS = lastImportDurationMS
        self.maxImportDurationMS = maxImportDurationMS
        self.incrementalImportAttemptCount = incrementalImportAttemptCount
        self.incrementalImportSuccessCount = incrementalImportSuccessCount
        self.incrementalImportFallbackCount = incrementalImportFallbackCount
        self.frontierReuseAttemptCount = frontierReuseAttemptCount
        self.frontierReuseSuccessCount = frontierReuseSuccessCount
        self.frontierReuseFallbackCount = frontierReuseFallbackCount
        self.lastIncrementalImportDurationMS = lastIncrementalImportDurationMS
        self.maxIncrementalImportDurationMS = maxIncrementalImportDurationMS
        self.lastPayloadCaptureDurationMS = lastPayloadCaptureDurationMS
        self.maxPayloadCaptureDurationMS = maxPayloadCaptureDurationMS
        self.lastSanitizeDurationMS = lastSanitizeDurationMS
        self.maxSanitizeDurationMS = maxSanitizeDurationMS
        self.sanitizeReuseAttemptCount = sanitizeReuseAttemptCount
        self.sanitizeReuseSuccessCount = sanitizeReuseSuccessCount
        self.sanitizeReuseFallbackCount = sanitizeReuseFallbackCount
        self.projectionReuseAttemptCount = projectionReuseAttemptCount
        self.projectionReuseSuccessCount = projectionReuseSuccessCount
        self.projectionReuseFallbackCount = projectionReuseFallbackCount
        self.lastSourceItemCount = lastSourceItemCount
        self.lastPayloadCaptureScannedItemCount = lastPayloadCaptureScannedItemCount
        self.lastSanitizedActivityCount = lastSanitizedActivityCount
        self.lastSanitizeReusedTurnCount = lastSanitizeReusedTurnCount
        self.lastProjectionReusedTurnCount = lastProjectionReusedTurnCount
        self.retainedRawPayloadEntryCount = retainedRawPayloadEntryCount
        self.retainedRawPayloadTotalBytes = retainedRawPayloadTotalBytes
        self.lastToolProcessingMetrics = lastToolProcessingMetrics
        self.cumulativeToolProcessingMetrics = cumulativeToolProcessingMetrics
    }

    static let empty = AgentTranscriptPerformanceSnapshot()
}

struct AgentTranscriptAnalyticsSnapshot: Equatable {
    var observedReadFiles: Set<String>
    var latestWorkspaceContextItem: AgentChatItem?
    var latestManageSelectionItem: AgentChatItem?
    var latestContextBuilderItem: AgentChatItem?
    var estimatedTranscriptTokens: Int?
    var selectedAgent: AgentProviderKind?

    init(
        observedReadFiles: Set<String> = [],
        latestWorkspaceContextItem: AgentChatItem? = nil,
        latestManageSelectionItem: AgentChatItem? = nil,
        latestContextBuilderItem: AgentChatItem? = nil,
        estimatedTranscriptTokens: Int? = nil,
        selectedAgent: AgentProviderKind? = nil
    ) {
        self.observedReadFiles = observedReadFiles
        self.latestWorkspaceContextItem = latestWorkspaceContextItem
        self.latestManageSelectionItem = latestManageSelectionItem
        self.latestContextBuilderItem = latestContextBuilderItem
        self.estimatedTranscriptTokens = estimatedTranscriptTokens
        self.selectedAgent = selectedAgent
    }
}
