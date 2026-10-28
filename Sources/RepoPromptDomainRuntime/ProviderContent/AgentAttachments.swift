import Foundation

public enum AgentAttachmentSource: Codable, Sendable, Equatable {
    case localFile(path: String)
    case url(String)
}

public struct AgentFileAttachment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: AgentAttachmentSource
    public let title: String?
    public let createdAt: Date
    package let kind: AttachmentKind
    /// Last path component only. Empty for rows written before file names were recorded.
    package let fileName: String
    /// Zero for rows written before sizes were recorded.
    package let byteCount: Int

    package init(
        id: UUID = UUID(),
        source: AgentAttachmentSource,
        title: String? = nil,
        createdAt: Date = Date(),
        kind: AttachmentKind = .image,
        fileName: String = "",
        byteCount: Int = 0
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.fileName = AttachmentFacts.lastPathComponent(fileName)
        self.byteCount = max(0, byteCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, title, createdAt, kind, fileName, byteCount
    }

    /// Transcripts persisted before attachments recorded facts were image-only, so they decode as images.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            source: container.decode(AgentAttachmentSource.self, forKey: .source),
            title: container.decodeIfPresent(String.self, forKey: .title),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            kind: container.decodeIfPresent(AttachmentKind.self, forKey: .kind) ?? .image,
            fileName: container.decodeIfPresent(String.self, forKey: .fileName) ?? "",
            byteCount: container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        )
    }

    /// What presentation derives a tile from. Falls back to the original title for rows that predate
    /// recorded file names.
    package var facts: AttachmentFacts {
        AttachmentFacts(kind: kind, fileName: fileName.isEmpty ? (title ?? "") : fileName, byteCount: byteCount)
    }
}

public struct AgentTaggedFileAttachment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let displayName: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        relativePath: String,
        displayName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.displayName = displayName
        self.createdAt = createdAt
    }
}
