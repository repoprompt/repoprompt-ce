import Foundation
import MCP

package struct MCPDomainToolAnnotations: Codable, Hashable, Sendable {
    package let title: String?
    package let readOnlyHint: Bool?
    package let destructiveHint: Bool?
    package let idempotentHint: Bool?
    package let openWorldHint: Bool?

    package init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    package func projected(for profile: MCPClientToolAnnotationProfile) -> Self {
        switch profile {
        case .canonical:
            self
        case .suppressReadOnlyHint:
            .init(
                title: title,
                readOnlyHint: nil,
                destructiveHint: destructiveHint,
                idempotentHint: idempotentHint,
                openWorldHint: openWorldHint
            )
        }
    }
}

package struct MCPDomainToolDefinition: Codable, Hashable, Sendable {
    package let name: String
    package let description: String
    package let inputSchema: Value
    package let annotations: MCPDomainToolAnnotations
    package let isEnabledByDefault: Bool

    package init(
        name: String,
        description: String,
        inputSchema: Value,
        annotations: MCPDomainToolAnnotations = .init(),
        isEnabledByDefault: Bool = true
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.isEnabledByDefault = isEnabledByDefault
    }
}

package struct MCPDomainToolBinding: Sendable {
    package let definition: MCPDomainToolDefinition
    private let operation: @Sendable ([String: Value]) async throws -> Value

    package init(
        definition: MCPDomainToolDefinition,
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) {
        self.definition = definition
        self.operation = operation
    }

    package func callAsFunction(_ arguments: [String: Value]) async throws -> Value {
        try await operation(arguments)
    }
}

package struct DomainStandaloneScopeID: Codable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum MCPDomainToolRegistrationScope: Hashable, Sendable {
    case application
    case window(id: Int)
    case standalone(id: DomainStandaloneScopeID)

    package var kind: MCPDomainToolScopeKind {
        switch self {
        case .application: .application
        case .window: .window
        case .standalone: .standalone
        }
    }
}

package struct MCPDomainToolRegistrationID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    package init(rawValue: UInt) {
        let high = UInt64(rawValue)
        let low = UInt64(rawValue) &* 0x9E37_79B9_7F4A_7C15
        self.rawValue = UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8),
            UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56),
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ))
    }
}

package struct MCPDomainToolRegistrationHandle: Hashable, Sendable {
    package let registryID: UUID
    package let registrationID: MCPDomainToolRegistrationID
    package let generation: UInt64

    package init(
        registryID: UUID,
        registrationID: MCPDomainToolRegistrationID,
        generation: UInt64
    ) {
        self.registryID = registryID
        self.registrationID = registrationID
        self.generation = generation
    }
}

/// A resolved value represents admitted work. Registry removal prevents future
/// resolution but does not cancel or await an operation already captured here;
/// connection/service teardown remains the cancellation authority for admitted work.
package struct MCPDomainResolvedTool: Sendable {
    package let handle: MCPDomainToolRegistrationHandle
    package let scope: MCPDomainToolRegistrationScope
    package let binding: MCPDomainToolBinding
}
