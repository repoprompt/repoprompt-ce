import Foundation
import RepoPromptCodeMapCore
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

/// Narrow HTTP-facing operational seams are declared here as Server composition
/// is separated from concrete persistence and authority construction.
public protocol RepoPromptOperatorOperations: Sendable {}

/// Server-owned adapter that restores the concrete CodeMap implementation behind
/// the portable workspace runtime's capability seam.
public struct ServerWorkspaceCodeMapBuilder: WorkspaceCodeMapBuilding {
    public init() {}

    public func build(content: String, fileExtension: String) throws -> WorkspaceCodeMapBuildResult {
        let result = try PortableCodeMapService.build(content: content, fileExtension: fileExtension)
        return WorkspaceCodeMapBuildResult(
            status: result.status.rawValue,
            language: result.language,
            content: result.content,
            contentDigest: result.contentDigest
        )
    }
}

public struct OperatorDesktopSettingsRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: Int64
    public let values: [String: String]
    public let updatedAt: Date

    public init(schemaVersion: Int = 1, revision: Int64, values: [String: String], updatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.values = values
        self.updatedAt = updatedAt
    }
}
