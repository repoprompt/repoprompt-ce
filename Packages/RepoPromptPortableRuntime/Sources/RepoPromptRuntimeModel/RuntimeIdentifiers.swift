import Foundation

public enum RuntimeModelError: Error, Equatable, Sendable {
    case invalidIdentifier(kind: String)
    case unsupportedWorkflowVersion(UInt)
    case invalidNumber
}

public struct RuntimeOwnerID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(Self.isValid(rawValue), "RuntimeOwnerID must not be empty")
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw RuntimeModelError.invalidIdentifier(kind: "owner")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ rawValue: String) -> Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct RuntimeResourceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(Self.isValid(rawValue), "RuntimeResourceID must not be empty")
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw RuntimeModelError.invalidIdentifier(kind: "resource")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ rawValue: String) -> Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct OwnedResourceReference: Codable, Hashable, Sendable {
    public let ownerID: RuntimeOwnerID
    public let resourceID: RuntimeResourceID

    public init(ownerID: RuntimeOwnerID, resourceID: RuntimeResourceID) {
        self.ownerID = ownerID
        self.resourceID = resourceID
    }
}

public struct ResourceGrant: Codable, Hashable, Sendable {
    public let reference: OwnedResourceReference
    public let generation: UInt64

    public init(reference: OwnedResourceReference, generation: UInt64) {
        self.reference = reference
        self.generation = generation
    }
}
