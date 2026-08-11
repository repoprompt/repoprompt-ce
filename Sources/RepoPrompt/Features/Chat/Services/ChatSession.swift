import Foundation

enum OracleLane: String, Codable, CaseIterable, Hashable, Sendable {
    case primary
    case secondary
    case oracle3 = "oracle_3"
    case oracle4 = "oracle_4"
    case oracle5 = "oracle_5"

    /// Stable one-based position used by persistence, transport, and UI ordering.
    var ordinal: Int {
        switch self {
        case .primary: 1
        case .secondary: 2
        case .oracle3: 3
        case .oracle4: 4
        case .oracle5: 5
        }
    }

    var isPrimary: Bool {
        self == .primary
    }

    var displayLabel: String {
        switch self {
        case .primary: "Primary Oracle"
        case .secondary: "Secondary Oracle"
        case .oracle3: "Oracle 3"
        case .oracle4: "Oracle 4"
        case .oracle5: "Oracle 5"
        }
    }

    /// Returns the only valid ordered lane prefix for a configured Oracle count.
    static func orderedPrefix(count: Int) throws -> [OracleLane] {
        guard (1 ... allCases.count).contains(count) else {
            throw OracleLaneValidationError.invalidCount(count)
        }
        return Array(allCases.prefix(count))
    }

    /// Ensures lanes are unique, contiguous, and ordered from Primary.
    static func validateOrderedPrefix(_ lanes: [OracleLane]) throws {
        let expected = try orderedPrefix(count: lanes.count)
        guard lanes == expected else {
            throw OracleLaneValidationError.invalidPrefix(expected: expected, actual: lanes)
        }
    }
}

enum OracleLaneValidationError: LocalizedError, Equatable, Sendable {
    case invalidCount(Int)
    case invalidPrefix(expected: [OracleLane], actual: [OracleLane])

    var errorDescription: String? {
        switch self {
        case let .invalidCount(count):
            "Oracle lane count must be between 1 and \(OracleLane.allCases.count); received \(count)."
        case let .invalidPrefix(expected, actual):
            "Oracle lanes must be the ordered prefix [\(expected.map(\.rawValue).joined(separator: ", "))]; received [\(actual.map(\.rawValue).joined(separator: ", "))]."
        }
    }
}

enum ChatSessionError: Error {
    case emptySession
    case invalidFilename(String)
    case decodingFailed(DecodingError)
    case loadFailed(Error)

    var localizedDescription: String {
        switch self {
        case .emptySession:
            "Cannot save an empty chat session"
        case let .invalidFilename(name):
            "Invalid chat session filename: \(name)"
        case let .decodingFailed(error):
            "Failed to decode chat session: \(error.localizedDescription)"
        case let .loadFailed(error):
            "Failed to load chat session: \(error.localizedDescription)"
        }
    }
}

struct ChatSession: Codable, Identifiable {
    let id: UUID
    var workspaceID: UUID?
    var composeTabID: UUID?
    var agentModeSessionID: UUID?
    var agentModeRunID: UUID?
    var oraclePairID: UUID?
    var oracleLane: OracleLane?
    /// Expected member count for the logical Oracle group containing this session.
    /// Legacy Primary/Secondary pairs decode as a two-member group.
    var oracleGroupSize: Int?
    var oracleHistoryDiverged: Bool
    var name: String
    var savedAt: Date
    var fileURL: URL?
    var messages: [StoredMessage]
    /// Optional lightweight message count for sessions where `messages` is unloaded.
    /// When nil, callers should use `messages.count`.
    var messageCount: Int?
    var selectedFilePaths: [String]
    var selectedPromptIDs: [UUID]

    /// NEW: The user's selected AI model at the time of saving.
    var preferredAIModel: String?

    /// NEW: The selected Chat Preset for this session
    var selectedChatPresetID: UUID?

    /// Human-readable short identifier combining name slug and UUID prefix
    var shortID: String

    /// Creates a short ID from name and UUID
    static func makeShortID(name: String, uuid: UUID) -> String {
        let slug = name.slugify(maxLength: 24)
        let uuidPrefix = uuid.uuidString.prefix(6)
        return "\(slug)-\(uuidPrefix)"
    }

    init(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        composeTabID: UUID? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        oraclePairID: UUID? = nil,
        oracleLane: OracleLane? = nil,
        oracleGroupSize: Int? = nil,
        oracleHistoryDiverged: Bool = false,
        name: String = "Untitled",
        savedAt: Date = Date(),
        fileURL: URL? = nil,
        messages: [StoredMessage] = [],
        selectedFilePaths: [String] = [],
        selectedPromptIDs: [UUID] = [],
        // NEW:
        preferredAIModel: String? = nil,
        selectedChatPresetID: UUID? = nil,
        messageCount: Int? = nil,
        shortID: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.agentModeSessionID = agentModeSessionID
        self.agentModeRunID = agentModeRunID
        self.oraclePairID = oraclePairID
        self.oracleLane = oracleLane
        self.oracleGroupSize = oracleGroupSize ?? Self.inferredLegacyOracleGroupSize(
            pairID: oraclePairID,
            lane: oracleLane
        )
        self.oracleHistoryDiverged = oracleHistoryDiverged
        self.name = name
        self.savedAt = savedAt
        self.fileURL = fileURL
        self.messages = messages
        self.messageCount = messageCount
        self.selectedFilePaths = selectedFilePaths
        self.selectedPromptIDs = selectedPromptIDs
        self.preferredAIModel = preferredAIModel
        self.selectedChatPresetID = selectedChatPresetID
        self.shortID = shortID ?? Self.makeShortID(name: name, uuid: id)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case composeTabID
        case agentModeSessionID
        case agentModeRunID
        case oraclePairID
        case oracleLane
        case oracleGroupSize
        case oracleHistoryDiverged
        case name
        case savedAt
        case fileURL
        case messages
        case messageCount
        case selectedFilePaths
        case selectedPromptIDs
        case preferredAIModel // NEW
        case selectedChatPresetID // NEW
        case shortID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
        agentModeSessionID = try container.decodeIfPresent(UUID.self, forKey: .agentModeSessionID)
        agentModeRunID = try container.decodeIfPresent(UUID.self, forKey: .agentModeRunID)
        oraclePairID = try container.decodeIfPresent(UUID.self, forKey: .oraclePairID)
        oracleLane = try container.decodeIfPresent(OracleLane.self, forKey: .oracleLane)
        oracleGroupSize = try container.decodeIfPresent(Int.self, forKey: .oracleGroupSize)
            ?? Self.inferredLegacyOracleGroupSize(pairID: oraclePairID, lane: oracleLane)
        oracleHistoryDiverged = try container.decodeIfPresent(Bool.self, forKey: .oracleHistoryDiverged) ?? false
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        messages = try container.decode([StoredMessage].self, forKey: .messages)
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
        selectedFilePaths = try container.decodeIfPresent([String].self, forKey: .selectedFilePaths) ?? []
        selectedPromptIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedPromptIDs) ?? []
        preferredAIModel = try container.decodeIfPresent(String.self, forKey: .preferredAIModel)
        selectedChatPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedChatPresetID)

        // Handle backward compatibility for shortID
        if let decodedShortID = try container.decodeIfPresent(String.self, forKey: .shortID) {
            shortID = decodedShortID
        } else {
            // Generate shortID for sessions that don't have one
            shortID = Self.makeShortID(name: name, uuid: id)
        }
    }

    /// Coalesces whitespace and falls back to "Untitled Chat" when empty.
    static func validatedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        return collapsed.isEmpty ? "Untitled Chat" : collapsed
    }

    private static func inferredLegacyOracleGroupSize(pairID: UUID?, lane: OracleLane?) -> Int? {
        guard pairID != nil, lane == .primary || lane == .secondary else { return nil }
        return 2
    }
}

extension ChatSession {
    /// Generic terminology for new multi-Oracle code while preserving the durable
    /// `oraclePairID` key and all existing pair call sites.
    var oracleGroupID: UUID? {
        get { oraclePairID }
        set { oraclePairID = newValue }
    }

    /// Message count for UI and sorting when `messages` may be unloaded.
    var effectiveMessageCount: Int {
        messageCount ?? messages.count
    }

    var hasMessages: Bool {
        effectiveMessageCount > 0
    }

    /// Returns true if this session is a lightweight stub (messages unloaded).
    /// A stub has empty messages but retains messageCount for UI display.
    var isListStub: Bool {
        messages.isEmpty &&
            messageCount != nil
    }

    /// Returns a lightweight copy suitable for session lists (drops heavy payloads).
    func listStub() -> ChatSession {
        var copy = self
        copy.messageCount = effectiveMessageCount
        copy.messages = []
        return copy
    }
}
