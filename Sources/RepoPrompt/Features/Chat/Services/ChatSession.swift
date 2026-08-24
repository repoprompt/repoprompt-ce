import Foundation

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
    var oracleGroupID: UUID?
    var oracleLaneIndex: Int?
    var oracleGroupSize: Int?
    var oracleModelRaw: String?
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
        oracleGroupID: UUID? = nil,
        oracleLaneIndex: Int? = nil,
        oracleGroupSize: Int? = nil,
        oracleModelRaw: String? = nil,
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
        self.oracleGroupID = oracleGroupID
        self.oracleLaneIndex = oracleLaneIndex
        self.oracleGroupSize = oracleGroupSize
        self.oracleModelRaw = oracleModelRaw
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
        case oracleGroupID
        case oracleLaneIndex
        case oracleGroupSize
        case oracleModelRaw
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
        oracleGroupID = try container.decodeIfPresent(UUID.self, forKey: .oracleGroupID)
        oracleLaneIndex = try container.decodeIfPresent(Int.self, forKey: .oracleLaneIndex)
        oracleGroupSize = try container.decodeIfPresent(Int.self, forKey: .oracleGroupSize)
        oracleModelRaw = try container.decodeIfPresent(String.self, forKey: .oracleModelRaw)
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
}

extension ChatSession {
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
