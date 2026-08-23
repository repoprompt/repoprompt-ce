import Foundation

/// Canonical subset executed by the shared domain read provider.
/// Schema ownership remains in `MCPDomainCanonicalToolDefinitions` for all 27 tools.
public enum MCPDomainReadToolDefinitions {
    public static let toolNames: [String] = [
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.workspaceContext,
        MCPWindowToolName.prompt,
        MCPWindowToolName.oracleChatLog,
        MCPWindowToolName.git,
        MCPWindowToolName.history,
    ]

    public static let definitions: [MCPDomainToolDefinition] = toolNames.compactMap {
        MCPDomainCanonicalToolDefinitions.definition(named: $0)
    }

    public static func definition(named name: String) -> MCPDomainToolDefinition? {
        guard toolNames.contains(name) else { return nil }
        return MCPDomainCanonicalToolDefinitions.definition(named: name)
    }
}
