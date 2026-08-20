import Foundation
import MCP

public struct MCPDomainToolAnnotations: Codable, Hashable, Sendable {
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
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

    public func projected(for profile: MCPClientToolAnnotationProfile) -> Self {
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

public struct MCPDomainToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: Value
    public let annotations: MCPDomainToolAnnotations
    public let isEnabledByDefault: Bool

    public init(
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

public struct MCPDomainToolBinding: Sendable {
    public let definition: MCPDomainToolDefinition
    private let operation: @Sendable ([String: Value]) async throws -> Value

    public init(
        definition: MCPDomainToolDefinition,
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) {
        self.definition = definition
        self.operation = operation
    }

    public func callAsFunction(_ arguments: [String: Value]) async throws -> Value {
        try await operation(arguments)
    }
}

public struct DomainStandaloneScopeID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum MCPDomainToolRegistrationScope: Hashable, Sendable {
    case application
    case window(id: Int)
    case standalone(id: DomainStandaloneScopeID)

    public var kind: MCPDomainToolScopeKind {
        switch self {
        case .application: .application
        case .window: .window
        case .standalone: .standalone
        }
    }
}

public struct MCPDomainToolRegistrationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(rawValue: UInt) {
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

public struct MCPDomainToolRegistrationHandle: Hashable, Sendable {
    public let registryID: UUID
    public let registrationID: MCPDomainToolRegistrationID
    public let generation: UInt64

    public init(
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
public struct MCPDomainResolvedTool: Sendable {
    public let handle: MCPDomainToolRegistrationHandle
    public let scope: MCPDomainToolRegistrationScope
    public let binding: MCPDomainToolBinding
}
