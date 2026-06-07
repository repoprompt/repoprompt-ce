import Foundation
import JSONSchema
import MCP
import Ontology

enum MCPToolFreshnessPolicy {
    case none
    case rootScope(WorkspaceLookupRootScope)
    case providerManaged
    case allLoadedAggressive
}

@MainActor
final class MCPWindowToolRuntime {
    typealias ProviderImplementation = @Sendable (MCPWindowToolContext, [String: Value]) async throws -> Value
    typealias ExecuteTool = @Sendable (
        _ name: String,
        _ freshnessPolicy: MCPToolFreshnessPolicy,
        _ arguments: [String: Value],
        _ implementation: @escaping ProviderImplementation
    ) async throws -> Value

    private let windowID: Int
    private let executeTool: ExecuteTool

    init(windowID: Int, executeTool: @escaping ExecuteTool) {
        self.windowID = windowID
        self.executeTool = executeTool
    }

    func tool(
        name: String,
        freshnessPolicy: MCPToolFreshnessPolicy,
        description: String,
        annotations: MCP.Tool.Annotations = .init(),
        inputSchema: JSONSchema,
        isEnabledByDefault: Bool = true,
        implementation: @escaping ProviderImplementation
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations,
            isEnabledByDefault: isEnabledByDefault,
            returnsValue: { [weak self] args in
                guard let self else {
                    throw MCPError.internalError("Window tool runtime deallocated while executing \(name)")
                }
                return try await executeTool(name, freshnessPolicy, args, implementation)
            }
        )
    }

    func context(for toolName: String) -> MCPWindowToolContext {
        MCPWindowToolContext(toolName: toolName, windowID: windowID)
    }
}
