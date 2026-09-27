import Foundation

/// Minimal storage for one message's raw text, plus metadata.
struct StoredMessage: Codable {
    let id: UUID
    let isUser: Bool

    /// The user-facing message text.
    let rawText: String

    /// Token usage information.
    let promptTokens: Int?
    let completionTokens: Int?
    let cost: Double?

    /// AI model name used for this assistant response (nil for user messages).
    let modelName: String?

    let timestamp: Date
    let sequenceIndex: Int

    /// The user's selected file paths at the time this message was created
    /// (may be nil for older data).
    let allowedFilePaths: [String]?

    /// Image thumbnails attached to this message (nil for older data or
    /// messages without image attachments).
    let imageAttachments: [AIChatImageAttachment]?

    enum CodingKeys: String, CodingKey {
        case id, isUser, rawText, timestamp
        case sequenceIndex, allowedFilePaths
        case promptTokens, completionTokens, cost
        case modelName, imageAttachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        rawText = try container.decode(String.self, forKey: .rawText)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sequenceIndex =
            try container.decodeIfPresent(Int.self, forKey: .sequenceIndex) ?? 0
        allowedFilePaths =
            try container.decodeIfPresent([String].self, forKey: .allowedFilePaths)
        imageAttachments =
            try container.decodeIfPresent([AIChatImageAttachment].self, forKey: .imageAttachments)

        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sequenceIndex, forKey: .sequenceIndex)
        try container.encode(allowedFilePaths, forKey: .allowedFilePaths)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(cost, forKey: .cost)
        try container.encode(modelName, forKey: .modelName)
    }

    init(
        id: UUID = UUID(),
        isUser: Bool,
        rawText: String,
        timestamp: Date = Date(),
        sequenceIndex: Int = 0,
        allowedFilePaths: [String]? = nil,
        imageAttachments: [AIChatImageAttachment]? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        modelName: String? = nil
    ) {
        self.id = id
        self.isUser = isUser
        self.rawText = rawText
        self.timestamp = timestamp
        self.sequenceIndex = sequenceIndex
        self.allowedFilePaths = allowedFilePaths
        self.imageAttachments = imageAttachments
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.modelName = modelName
    }
}
