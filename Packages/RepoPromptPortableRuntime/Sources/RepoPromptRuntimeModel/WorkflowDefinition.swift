import Foundation

public enum WorkflowValue: Codable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([WorkflowValue])
    case object([String: WorkflowValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else { throw RuntimeModelError.invalidNumber }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WorkflowValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: WorkflowValue].self))
        }
    }

    public var isValid: Bool {
        switch self {
        case .null, .boolean, .integer, .string:
            true
        case let .number(value):
            value.isFinite
        case let .array(values):
            values.allSatisfy(\.isValid)
        case let .object(values):
            values.values.allSatisfy(\.isValid)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .boolean(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else { throw RuntimeModelError.invalidNumber }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public struct WorkflowDefinition: Codable, Hashable, Sendable {
    public static let currentFormatVersion: UInt = 1

    public let formatVersion: UInt
    public let resources: [OwnedResourceReference]
    public let payload: WorkflowValue

    public init(
        formatVersion: UInt = currentFormatVersion,
        resources: [OwnedResourceReference] = [],
        payload: WorkflowValue = .null
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw RuntimeModelError.unsupportedWorkflowVersion(formatVersion)
        }
        guard payload.isValid else {
            throw RuntimeModelError.invalidNumber
        }
        self.formatVersion = formatVersion
        self.resources = resources
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatVersion: container.decode(UInt.self, forKey: .formatVersion),
            resources: container.decode([OwnedResourceReference].self, forKey: .resources),
            payload: container.decode(WorkflowValue.self, forKey: .payload)
        )
    }
}
