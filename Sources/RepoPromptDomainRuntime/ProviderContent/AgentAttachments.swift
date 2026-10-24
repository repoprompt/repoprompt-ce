import Foundation

public enum AgentImageSource: Codable, Sendable, Equatable {
    case localFile(path: String)
    case url(String)
}

public struct AgentImageAttachment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: AgentImageSource
    public let title: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        source: AgentImageSource,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.createdAt = createdAt
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
