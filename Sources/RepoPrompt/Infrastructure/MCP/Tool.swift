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
    func domainBinding() throws -> MCPDomainToolBinding {
        let definition = try MCPDomainToolDefinition(
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
