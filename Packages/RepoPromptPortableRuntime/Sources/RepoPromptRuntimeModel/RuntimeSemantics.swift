import Foundation

public enum ProviderExecutionMode: String, Codable, CaseIterable, Sendable {
    case readOnly
    case workspaceWrite
    case fullAccess
}

public struct ProviderModelIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AuthorityRevisionEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let revision: Int64
    public let updatedAt: Date

    public init(value: Value, revision: Int64, updatedAt: Date) {
        self.value = value
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ProviderExecutionPolicy: Codable, Hashable, Sendable {
    public let mode: ProviderExecutionMode
    public let writableRoots: [String]
    public let providerSettings: [String: String]

    public init(
        mode: ProviderExecutionMode = .workspaceWrite,
        writableRoots: [String] = [],
        providerSettings: [String: String] = [:]
    ) {
        self.mode = mode
        self.writableRoots = writableRoots
        self.providerSettings = providerSettings
    }
}
