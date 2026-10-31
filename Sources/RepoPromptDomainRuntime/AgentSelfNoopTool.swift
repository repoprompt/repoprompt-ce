import MCP

/// Call acknowledgement only. The app's exact live attempt owns declaration qualification.
package enum AgentSelfNoopTool {
    package static let definition = MCPDomainToolDefinition(
        name: MCPWindowToolName.selfNoop,
        description: "Quietly close a routine wake that needs nothing.",
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:])
        ])
    )

    package static let acknowledgement: Value = .object(["result": .string("done")])
}
