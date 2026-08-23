import Foundation
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptRuntimeModel

public typealias RepoPromptMCPBinding = AuthorityMCPBinding
public typealias RepoPromptMCPServingCapability = RepoPromptMCPServing

/// State-free canonical MCP transport adapter. It retains only the host-issued
/// serving interface and owns no project, selection, run, or persistence state.
public actor RepoPromptMCPAdapter {
    private let serving: any RepoPromptMCPServing

    public init(serving: any RepoPromptMCPServing) {
        self.serving = serving
    }

    public nonisolated static var canonicalToolNames: [String] {
        MCPDomainToolCatalog.orderedToolNames
    }

    public func projectSnapshot(id: UUID) async throws -> ProjectSnapshot {
        try await serving.projectSnapshot(id: id)
    }

    public func sessionSnapshot(id: UUID) async throws -> SessionSnapshot {
        try await serving.sessionSnapshot(id: id)
    }

    public func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        try await serving.events(after: cursor, limit: limit)
    }

    public func advertisedToolNames(isRootSession: Bool) async throws -> Set<String> {
        try await serving.advertisedToolNames(isRootSession: isRootSession)
    }

    public func invoke(
        toolName: String,
        argumentsJSON: Data,
        binding: RepoPromptMCPBinding
    ) async throws -> Data {
        try await serving.invoke(toolName: toolName, argumentsJSON: argumentsJSON, binding: binding)
    }
}
