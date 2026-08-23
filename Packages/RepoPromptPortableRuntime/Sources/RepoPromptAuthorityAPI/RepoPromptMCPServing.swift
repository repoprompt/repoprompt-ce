import Foundation
import RepoPromptRuntimeModel

public struct AuthorityMCPBinding: Sendable {
    public static let untrustedClientID = "unknown-client"
    public let sessionID: UUID
    public let actor: ExternalActor
    public let mcpClientID: String

    public init(sessionID: UUID, actor: ExternalActor, mcpClientID: String = untrustedClientID) {
        self.sessionID = sessionID
        self.actor = actor
        self.mcpClientID = mcpClientID
    }
}

/// State-free adapter seam. Concrete authority/store ownership remains in the
/// host target; child transports only receive this data-oriented interface.
public protocol RepoPromptMCPServing: Sendable {
    func projectSnapshot(id: UUID) async throws -> ProjectSnapshot
    func sessionSnapshot(id: UUID) async throws -> SessionSnapshot
    func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage
    func advertisedToolNames(isRootSession: Bool) async throws -> Set<String>
    func invoke(toolName: String, argumentsJSON: Data, binding: AuthorityMCPBinding) async throws -> Data
}
