//
//  Tool.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    public let isEnabledByDefault: Bool
    private let implementation: @Sendable ([String: Value]) async throws -> Value

    /// -----------------------------------------------------------------
    ///  Bridge the strongly-typed Swift return value → `Value`
    /// -----------------------------------------------------------------
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations = .init(),
        isEnabledByDefault: Bool = true,
        implementation: @Sendable @escaping ([String: Value]) async throws -> some Encodable
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.isEnabledByDefault = isEnabledByDefault
        self.implementation = { input in
            let result = try await implementation(input)

            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]

            let data = try encoder.encode(result)
            let decoder = JSONDecoder()
            return try decoder.decode(Value.self, from: data)
        }
    }

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations = .init(),
        isEnabledByDefault: Bool = true,
        returnsValue implementation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.isEnabledByDefault = isEnabledByDefault
        self.implementation = implementation
    }

    public func callAsFunction(_ input: [String: Value]) async throws -> Value {
        try await implementation(input)
    }
}

extension Tool {
    /// Reprojects canonical schema metadata without adding another execution wrapper.
    /// The supplied tool already owns the app `runTool` envelope.
    init(canonicalizing implementation: Tool) throws {
        let binding = try implementation.domainBinding()
        let schemaData = try JSONEncoder().encode(binding.definition.inputSchema)
        let schema = try JSONDecoder().decode(JSONSchema.self, from: schemaData)
        self.init(
            name: binding.definition.name,
            description: binding.definition.description,
            inputSchema: schema,
            annotations: binding.definition.annotations.mcpAnnotations,
            isEnabledByDefault: binding.definition.isEnabledByDefault,
            returnsValue: { arguments in
                try await implementation(arguments)
            }
        )
    }

    init(domainBinding: MCPDomainToolBinding) throws {
        let schemaData = try JSONEncoder().encode(domainBinding.definition.inputSchema)
        let schema = try JSONDecoder().decode(JSONSchema.self, from: schemaData)
        self.init(
            name: domainBinding.definition.name,
            description: domainBinding.definition.description,
            inputSchema: schema,
            annotations: domainBinding.definition.annotations.mcpAnnotations,
            isEnabledByDefault: domainBinding.definition.isEnabledByDefault,
            returnsValue: { arguments in
                try await domainBinding(arguments)
            }
        )
    }

    @MainActor
    init(
        domainBinding: MCPDomainToolBinding,
        runtime: MCPAppToolBinder
    ) throws {
        let schemaData = try JSONEncoder().encode(domainBinding.definition.inputSchema)
        let schema = try JSONDecoder().decode(JSONSchema.self, from: schemaData)
        self = runtime.tool(
            name: domainBinding.definition.name,
            freshnessPolicy: .providerManaged,
            description: domainBinding.definition.description,
            annotations: domainBinding.definition.annotations.mcpAnnotations,
            inputSchema: schema,
            isEnabledByDefault: domainBinding.definition.isEnabledByDefault
        ) { _, arguments in
            try await domainBinding(arguments)
        }
    }

    func domainBinding() throws -> MCPDomainToolBinding {
        let definition: MCPDomainToolDefinition = if let canonical = MCPDomainCanonicalToolDefinitions.definition(named: name) {
            canonical
        } else {
            try MCPDomainToolDefinition(
                name: name,
                description: description,
                inputSchema: Value(inputSchema),
                annotations: MCPDomainToolAnnotations(
                    title: annotations.title,
                    readOnlyHint: annotations.readOnlyHint,
                    destructiveHint: annotations.destructiveHint,
                    idempotentHint: annotations.idempotentHint,
                    openWorldHint: annotations.openWorldHint
                ),
                isEnabledByDefault: isEnabledByDefault
            )
        }
        return MCPDomainToolBinding(definition: definition) { arguments in
            try await self(arguments)
        }
    }
}

extension MCPDomainToolAnnotations {
    var mcpAnnotations: MCP.Tool.Annotations {
        .init(
            title: title,
            readOnlyHint: readOnlyHint,
            destructiveHint: destructiveHint,
            idempotentHint: idempotentHint,
            openWorldHint: openWorldHint
        )
    }
}

extension MCP.Tool.Annotations {
    static let repoPromptLocalReadOnly = Self(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    static let repoPromptLocalEphemeralState = Self(
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: false
    )

    static let repoPromptLocalPersistentSettings = Self(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false
    )

    static let repoPromptLocalDestructive = Self(
        readOnlyHint: false,
        destructiveHint: true,
        openWorldHint: false
    )
}
