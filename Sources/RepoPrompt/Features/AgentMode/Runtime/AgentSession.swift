import Foundation

// MARK: - Agent Session Error

enum AgentSessionError: Error, LocalizedError {
    case emptySession
    case invalidFilename(String)
    case decodingFailed(DecodingError)
    case loadFailed(Error)
    case noActiveWorkspace
    case invalidHandoffCutoff

    var localizedDescription: String {
        switch self {
        case .emptySession:
            "Cannot save an empty agent session"
        case let .invalidFilename(name):
            "Invalid agent session filename: \(name)"
        case let .decodingFailed(error):
            "Failed to decode agent session: \(error.localizedDescription)"
        case let .loadFailed(error):
            "Failed to load agent session: \(error.localizedDescription)"
        case .noActiveWorkspace:
            "No active workspace for agent session"
        case .invalidHandoffCutoff:
            "The selected handoff point is no longer available in this session transcript."
        }
    }

    var errorDescription: String? {
        localizedDescription
    }
}

struct AgentTokenUsagePersist: Codable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let contextUsedTokens: Int?
    let estimatedUserInputTokens: Int
    let estimatedToolInputTokens: Int
    let estimatedToolOutputTokens: Int
    let timestamp: Date

    init(
        promptTokens: Int,
        completionTokens: Int,
        contextUsedTokens: Int? = nil,
        estimatedUserInputTokens: Int = 0,
        estimatedToolInputTokens: Int = 0,
        estimatedToolOutputTokens: Int = 0,
        timestamp: Date = Date()
    ) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        if let contextUsedTokens {
            let normalized = max(0, contextUsedTokens)
            self.contextUsedTokens = normalized > 0 ? normalized : nil
        } else {
            self.contextUsedTokens = nil
        }
        self.estimatedUserInputTokens = max(0, estimatedUserInputTokens)
        self.estimatedToolInputTokens = max(0, estimatedToolInputTokens)
        self.estimatedToolOutputTokens = max(0, estimatedToolOutputTokens)
        self.timestamp = timestamp
    }

    var estimatedInputTokens: Int {
        estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
    }

    var providerTotalTokens: Int {
        promptTokens + completionTokens
    }

    var totalTokens: Int {
        if let contextUsedTokens, contextUsedTokens > 0 {
            return contextUsedTokens
        }
        let provider = providerTotalTokens
        if provider > 0 {
            return provider
        }
        return estimatedInputTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens
        case completionTokens
        case contextUsedTokens
        case estimatedUserInputTokens
        case estimatedToolInputTokens
        case estimatedToolOutputTokens
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try max(0, container.decode(Int.self, forKey: .promptTokens))
        completionTokens = try max(0, container.decode(Int.self, forKey: .completionTokens))
        if let decodedContext = try container.decodeIfPresent(Int.self, forKey: .contextUsedTokens) {
            let normalized = max(0, decodedContext)
            contextUsedTokens = normalized > 0 ? normalized : nil
        } else {
            contextUsedTokens = nil
        }
        estimatedUserInputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedUserInputTokens) ?? 0)
        estimatedToolInputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedToolInputTokens) ?? 0)
        estimatedToolOutputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedToolOutputTokens) ?? 0)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encodeIfPresent(contextUsedTokens, forKey: .contextUsedTokens)
        try container.encode(estimatedUserInputTokens, forKey: .estimatedUserInputTokens)
        try container.encode(estimatedToolInputTokens, forKey: .estimatedToolInputTokens)
        try container.encode(estimatedToolOutputTokens, forKey: .estimatedToolOutputTokens)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Agent Session

/// Persisted agent mode session containing the chat transcript and configuration
struct AgentSession: Codable, Identifiable {
    static let currentSerializationVersion = 7
    static let legacyUnversionedSerializationVersion = 0

    let id: UUID
    var serializationVersion: Int
    var workspaceID: UUID?
    var composeTabID: UUID?
    var name: String
    var savedAt: Date
    var fileURL: URL?

    /// Last user interaction timestamp (user message or answered question)
    var lastUserMessageAt: Date?

    /// Mutable full-detail working suffix retained for runtime compatibility and legacy decode.
    /// Newly persisted sessions store this empty and rebuild it from the transcript when needed.
    var items: [AgentChatItemPersist]

    /// Structured transcript source of truth. Compacted turns may retain only summary shells.
    var transcript: AgentTranscript?

    /// Optional lightweight item count for sessions where transcript/items are unloaded.
    var itemCount: Int?

    /// Snapshot of canonical vs default-presented transcript counts.
    var transcriptProjectionCounts: AgentTranscriptProjectionCounts?

    /// Agent kind used for this session (e.g., "claudeCode", "codexExec", "openCode")
    var agentKind: String?

    /// Model used for this session (e.g., "sonnet", "opus", "codexMedium")
    var agentModel: String?

    /// User-selected reasoning effort (Codex-only)
    var agentReasoningEffort: String?

    /// State of the last run
    var lastRunState: String?

    /// Provider-specific resumable session identifier (e.g., Claude CLI session_id)
    /// Used to resume conversations with --resume instead of replaying history
    var providerSessionID: String?

    /// Provider-neutral cleanup metadata. This is distinct from resumability:
    /// a session ID may route cleanup, but does not imply remote deletion support.
    var providerCleanupHandle: ProviderConversationCleanupHandle?
    var autoEditEnabled: Bool

    /// Persisted per-turn token usage for non-Codex providers.
    /// Used to rebuild context usage after reopen/resume when tool payloads are pruned.
    var providerTokenUsageByTurn: [AgentTokenUsagePersist]

    /// Codex native session identifiers (v2 thread and rollout path)
    var codexConversationID: String?
    var codexRolloutPath: String?

    /// Codex native session metadata
    var codexModel: String?
    var codexReasoningEffort: String?
    var codexContextWindow: Int?
    var codexLastTotalTokens: Int?
    var codexTotalTotalTokens: Int?
    var codexMcpSessionKey: String?

    /// Parent session ID for thread nesting (child sessions spawned from another session)
    var parentSessionID: UUID?

    /// Whether this session was originally created by an MCP client (vs the user in the UI).
    /// Used to scope cleanup operations to MCP-originated sessions only.
    var isMCPOriginated: Bool

    /// Persisted per-session logical-root to worktree bindings.
    /// Runtime cwd/path projection is resolved by downstream worktree-system layers.
    var worktreeBindings: [AgentSessionWorktreeBinding]

    /// Persisted resumable worktree-merge operations for this Agent session.
    /// Patch contents live in merge preview artifacts, not in the session JSON.
    var worktreeMergeOperations: [AgentSessionWorktreeMergeOperation]

    /// Pending handoff payload (injected into the provider-facing text on the destination tab's
    /// first user send, then cleared). Persisted so it survives close/reopen.
    var pendingHandoffPayload: String?
    var pendingHandoffCreatedAt: Date?
    var pendingHandoffSourceItemID: UUID?
    var pendingHandoffDefersProviderLockUntilSend: Bool

    init(
        id: UUID = UUID(),
        serializationVersion: Int = AgentSession.currentSerializationVersion,
        workspaceID: UUID? = nil,
        composeTabID: UUID? = nil,
        name: String = "Agent Session",
        savedAt: Date = Date(),
        fileURL: URL? = nil,
        items: [AgentChatItemPersist] = [],
        transcript: AgentTranscript? = nil,
        itemCount: Int? = nil,
        transcriptProjectionCounts: AgentTranscriptProjectionCounts? = nil,
        lastUserMessageAt: Date? = nil,
        agentKind: String? = nil,
        agentModel: String? = nil,
        agentReasoningEffort: String? = nil,
        lastRunState: String? = nil,
        providerSessionID: String? = nil,
        providerCleanupHandle: ProviderConversationCleanupHandle? = nil,
        autoEditEnabled: Bool = true,
        providerTokenUsageByTurn: [AgentTokenUsagePersist] = [],
        codexConversationID: String? = nil,
        codexRolloutPath: String? = nil,
        codexModel: String? = nil,
        codexReasoningEffort: String? = nil,
        codexContextWindow: Int? = nil,
        codexLastTotalTokens: Int? = nil,
        codexTotalTotalTokens: Int? = nil,
        codexMcpSessionKey: String? = nil,
        parentSessionID: UUID? = nil,
        pendingHandoffPayload: String? = nil,
        pendingHandoffCreatedAt: Date? = nil,
        pendingHandoffSourceItemID: UUID? = nil,
        pendingHandoffDefersProviderLockUntilSend: Bool = false,
        isMCPOriginated: Bool = false,
        worktreeBindings: [AgentSessionWorktreeBinding] = [],
        worktreeMergeOperations: [AgentSessionWorktreeMergeOperation] = []
    ) {
        self.id = id
        self.serializationVersion = serializationVersion
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.name = name
        self.savedAt = savedAt
        self.fileURL = fileURL
        self.items = items
        self.transcript = transcript
        self.itemCount = itemCount
        self.transcriptProjectionCounts = transcriptProjectionCounts
        self.lastUserMessageAt = lastUserMessageAt
        self.agentKind = agentKind
        self.agentModel = agentModel
        self.agentReasoningEffort = agentReasoningEffort
        self.lastRunState = lastRunState
        self.providerSessionID = providerSessionID
        self.providerCleanupHandle = providerCleanupHandle
        self.autoEditEnabled = autoEditEnabled
        self.providerTokenUsageByTurn = providerTokenUsageByTurn
        self.codexConversationID = codexConversationID
        self.codexRolloutPath = codexRolloutPath
        self.codexModel = codexModel
        self.codexReasoningEffort = codexReasoningEffort
        self.codexContextWindow = codexContextWindow
        self.codexLastTotalTokens = codexLastTotalTokens
        self.codexTotalTotalTokens = codexTotalTotalTokens
        self.codexMcpSessionKey = codexMcpSessionKey
        self.parentSessionID = parentSessionID
        self.pendingHandoffPayload = pendingHandoffPayload
        self.pendingHandoffCreatedAt = pendingHandoffCreatedAt
        self.pendingHandoffSourceItemID = pendingHandoffSourceItemID
        self.pendingHandoffDefersProviderLockUntilSend = pendingHandoffDefersProviderLockUntilSend
        self.isMCPOriginated = isMCPOriginated
        self.worktreeBindings = worktreeBindings
        self.worktreeMergeOperations = worktreeMergeOperations
    }

    enum CodingKeys: String, CodingKey {
        case id
        case serializationVersion
        case workspaceID
        case composeTabID
        case name
        case savedAt
        case fileURL
        case items
        case transcript
        case itemCount
        case transcriptProjectionCounts
        case lastUserMessageAt
        case agentKind
        case agentModel
        case agentReasoningEffort
        case lastRunState
        case providerSessionID
        case providerCleanupHandle
        case autoEditEnabled
        case providerTokenUsageByTurn
        case codexConversationID
        case codexRolloutPath
        case codexModel
        case codexReasoningEffort
        case codexContextWindow
        case codexLastTotalTokens
        case codexTotalTotalTokens
        case codexMcpSessionKey
        case parentSessionID
        case pendingHandoffPayload
        case pendingHandoffCreatedAt
        case pendingHandoffSourceItemID
        case pendingHandoffDefersProviderLockUntilSend
        case isMCPOriginated
        case worktreeBindings
        case worktreeMergeOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
            ?? Self.legacyUnversionedSerializationVersion
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        items = try container.decodeIfPresent([AgentChatItemPersist].self, forKey: .items) ?? []
        transcript = try container.decodeIfPresent(AgentTranscript.self, forKey: .transcript)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
        transcriptProjectionCounts = try container.decodeIfPresent(AgentTranscriptProjectionCounts.self, forKey: .transcriptProjectionCounts)
        lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
        agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
        agentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffort)
        lastRunState = try container.decodeIfPresent(String.self, forKey: .lastRunState)
        providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
        providerCleanupHandle = try container.decodeIfPresent(ProviderConversationCleanupHandle.self, forKey: .providerCleanupHandle)
        autoEditEnabled = try container.decode(Bool.self, forKey: .autoEditEnabled)
        providerTokenUsageByTurn = try container.decodeIfPresent([AgentTokenUsagePersist].self, forKey: .providerTokenUsageByTurn) ?? []
        codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
        codexRolloutPath = try container.decodeIfPresent(String.self, forKey: .codexRolloutPath)
        codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
        codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort)
        codexContextWindow = try container.decodeIfPresent(Int.self, forKey: .codexContextWindow)
        codexLastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexLastTotalTokens)
        codexTotalTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexTotalTotalTokens)
        codexMcpSessionKey = try container.decodeIfPresent(String.self, forKey: .codexMcpSessionKey)
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        pendingHandoffPayload = try container.decodeIfPresent(String.self, forKey: .pendingHandoffPayload)
        pendingHandoffCreatedAt = try container.decodeIfPresent(Date.self, forKey: .pendingHandoffCreatedAt)
        pendingHandoffSourceItemID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffSourceItemID)
        pendingHandoffDefersProviderLockUntilSend = try container.decodeIfPresent(Bool.self, forKey: .pendingHandoffDefersProviderLockUntilSend) ?? false
        isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated) ?? false
        worktreeBindings = try container.decodeIfPresent([AgentSessionWorktreeBinding].self, forKey: .worktreeBindings) ?? []
        worktreeMergeOperations = try container.decodeIfPresent([AgentSessionWorktreeMergeOperation].self, forKey: .worktreeMergeOperations) ?? []
    }

    /// Coalesces whitespace and falls back to "Agent Session" when empty.
    static func validatedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "Agent Session" : collapsed
    }
}

// MARK: - AgentSession Extensions

extension AgentSession {
    /// Canonical item count for UI and sorting when `items` may be unloaded.
    var effectiveItemCount: Int {
        effectiveCanonicalItemCount
    }

    var effectiveCanonicalItemCount: Int {
        if let transcriptProjectionCounts {
            return transcriptProjectionCounts.canonicalVisibleRowCount
        }
        if let itemCount {
            return itemCount
        }
        if let transcript {
            return AgentTranscriptProjectionBuilder.projectionCounts(for: transcript).canonicalVisibleRowCount
        }
        return items.count
    }

    var effectiveDefaultPresentedItemCount: Int {
        if let transcriptProjectionCounts {
            return transcriptProjectionCounts.defaultPresentedRowCount
        }
        if let transcript {
            return AgentTranscriptProjectionBuilder.projectionCounts(for: transcript).defaultPresentedRowCount
        }
        if let itemCount {
            return itemCount
        }
        return items.count
    }

    func visibleItemCount(showCompressedHistory: Bool) -> Int {
        showCompressedHistory ? effectiveCanonicalItemCount : effectiveDefaultPresentedItemCount
    }

    var resolvedProviderCleanupHandle: ProviderConversationCleanupHandle? {
        ProviderConversationCleanupHandle.resolved(
            provider: agentKind ?? AgentProviderKind.claudeCode.rawValue,
            explicit: providerCleanupHandle,
            providerSessionID: providerSessionID,
            codexConversationID: codexConversationID,
            codexRolloutPath: codexRolloutPath
        )
    }

    var hasItems: Bool {
        effectiveItemCount > 0
    }

    /// Returns true if this session is a lightweight stub (items unloaded)
    var isListStub: Bool {
        items.isEmpty && transcript == nil && itemCount != nil
    }

    /// Returns a lightweight copy suitable for session lists (drops heavy payloads)
    func listStub() -> AgentSession {
        var copy = self
        copy.itemCount = effectiveCanonicalItemCount
        copy.items = []
        copy.transcript = nil
        return copy
    }

    /// Converts the session into renderable chat rows, including compacted transcript summaries.
    func toLiveItems() -> [AgentChatItem] {
        if let transcript {
            let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
            return (projection.archivedRows + projection.workingRows).sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
        }
        return items.map { $0.toItem() }
    }

    /// Returns only the mutable full-detail suffix used by runtime/live refresh logic.
    func workingSourceItems() -> [AgentChatItem] {
        if let transcript {
            return AgentTranscriptIO.workingSourceItems(from: transcript)
        }
        return items.map { $0.toItem() }
    }

    /// Creates a new session with updated items from live chat items
    func withItems(_ liveItems: [AgentChatItem]) -> AgentSession {
        var copy = self
        copy.items = liveItems.map { AgentChatItemPersist(from: $0) }
        let transcript = AgentTranscriptIO.buildTranscript(
            from: liveItems,
            nextSequenceIndex: (liveItems.map(\.sequenceIndex).max() ?? -1) + 1,
            policy: .canonical
        )
        copy.transcript = transcript
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
        copy.itemCount = projectionCounts.canonicalVisibleRowCount
        copy.transcriptProjectionCounts = projectionCounts
        copy.lastUserMessageAt = AgentTranscriptIO.lastUserInteractionDate(in: transcript)
        copy.savedAt = Date()
        return copy
    }
}

// MARK: - Conversation History Builder

extension AgentSession {
    /// Builds a conversation history string suitable for sending to an agent on session resume.
    /// This allows the agent to continue where it left off.
    func buildConversationHistory() -> String {
        if let transcript {
            return AgentTranscriptIO.buildConversationHistory(from: transcript)
        }
        return AgentTranscriptIO.buildConversationHistory(
            from: AgentTranscriptIO.buildTranscript(
                from: items.map { $0.toItem() },
                nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1,
                policy: .canonical,
                compact: false
            )
        )
    }
}
