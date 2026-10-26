import Foundation

/// Wire event written by the MCP helper when it cannot report a client failure
/// over the normal transport. App-only presentation remains in the app target.
public struct MCPExternalClientEvent: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case repopromptCLI
    }

    public enum Kind: String, Codable, Sendable {
        case discoveryError
        case runtimeError
    }

    public enum Code: String, Codable, Sendable {
        case timeoutNoServices = "timeout_no_services"
        case timeoutWithCandidates = "timeout_with_candidates"
        case serviceNameMismatch = "service_name_mismatch"
        case deviceMismatch = "device_mismatch"
        case buildFlavorMismatch = "build_flavor_mismatch"
        case protocolVersionMismatch = "protocol_version_mismatch"
        case malformedServiceName = "malformed_service_name"
        case localNetworkPolicyDenied = "local_network_policy_denied"
        case incompatibleServiceVersion = "incompatible_service_version"
        case connectionFailed = "connection_failed"
        case approvalDenied = "approval_denied"
        case unknown
    }

    public let id: UUID
    public let timestamp: Date
    public let source: Source
    public let kind: Kind
    public let code: Code
    public let humanMessage: String
    public let clientName: String?
    public let details: [String: String]?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: Source,
        kind: Kind,
        code: Code,
        humanMessage: String,
        clientName: String? = nil,
        details: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.code = code
        self.humanMessage = humanMessage
        self.clientName = clientName
        self.details = details
    }
}
