import Foundation
import JSONSchema
import MCP
import RepoPromptDomainRuntime

/// Builds the agent-only `session_admin` window tool.
///
/// The canonical description and schema come from `MCPDomainSessionAdminToolDefinition`; catalog
/// materialization reprojects them over whatever this provider supplies. Advertisement is gated live
/// in `ServerNetworkManager`, and the service re-resolves the exact caller on every call.
@MainActor
final class MCPSessionAdminToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .agentControl

    private let runtime: MCPAppToolBinder
    private let dependencies: MCPAppPhysicalCapabilityAdapters.Execution

    init(runtime: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution) {
        self.runtime = runtime
        dependencies = execution
    }

    func buildTools() -> [Tool] {
        let definition = MCPDomainSessionAdminToolDefinition.definition
        return [
            runtime.tool(
                name: MCPWindowToolName.sessionAdmin,
                freshnessPolicy: .none,
                description: definition.description,
                annotations: definition.annotations.mcpAnnotations,
                inputSchema: .object(
                    properties: [
                        "op": .string(
                            description: "Required operation.",
                            enum: MCPDomainSessionAdminToolDefinition.operations.map { .string($0) }
                        )
                    ],
                    required: ["op"]
                )
            ) { [dependencies] _, args in
                try await dependencies.executeSessionAdmin(args)
            }
        ]
    }
}
