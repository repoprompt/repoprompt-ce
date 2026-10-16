import MCP
import RepoPromptDomainRuntime

/// Backend projection only: the app keeps the canonical discovery/export contract.
/// Direct-headless advertises only capabilities its actual adapter can honor.
enum DirectHeadlessToolAdvertisement {
    static func project(_ definition: MCPDomainToolDefinition) -> (description: String, inputSchema: Value) {
        guard definition.name == "context_builder",
              case var .object(schema) = definition.inputSchema,
              case let .object(canonicalProperties)? = schema["properties"]
        else { return (definition.description, definition.inputSchema) }
        var properties = canonicalProperties.filter {
            DirectHeadlessOracleAdapter.contextBuilderArgumentNames.contains($0.key)
        }
        properties["instructions"] = .object([
            "type": .string("string"), "minLength": .int(1), "pattern": .string("\\S"),
            "description": .string("Prompt for one-shot inference with a single configured Oracle; not autonomous discovery.")
        ])
        properties["model"] = .object([
            "type": .string("string"), "minLength": .int(1), "pattern": .string("\\S"),
            "description": .string("Optional primary Oracle model override; does not alter additional configured Oracles.")
        ])
        properties["response_type"] = .object([
            "type": .string("string"),
            "enum": .array([.string("question"), .string("plan"), .string("review")]),
            "default": .string("question"),
            "description": .string("Frozen-pack response mode (default question). For single-Oracle instructions this does not change the provider prompt; specify the desired output in instructions. Frozen packs must have the same mode.")
        ])
        schema["properties"] = .object(properties)
        schema["additionalProperties"] = .bool(false)
        schema.removeValue(forKey: "required")
        schema["oneOf"] = .array([
            .object([
                "required": .array([.string("instructions")]),
                "not": .object(["required": .array([.string("context_pack_ref")])])
            ]),
            .object([
                "required": .array([.string("context_pack_ref")]),
                "not": .object(["required": .array([.string("instructions")])])
            ])
        ])
        return (
            "Direct-headless Context Builder performs one-shot Oracle inference. With a single Oracle supply instructions; multiple Oracles require a persisted canonical context_pack_ref from this profile's artifact store. It does not discover files, commit selections, or create frozen packs, and does not export responses. App presets and clarify/discovery require the app-backed tool. Omitted response_type defaults to question for frozen-pack matching; in single-Oracle instruction mode response_type does not change the provider prompt, so specify the desired output in instructions.",
            .object(schema)
        )
    }
}
