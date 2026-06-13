import CryptoKit
import Foundation

/// Correlation identity shared by the app, transport, bridge ledger, and CLI proxy.
///
/// Individual layers may initially know only part of the identity. Later layers preserve
/// the known fields and fill the remaining values without changing the JSON-RPC payload.
public struct MCPRequestTimelineIdentity: Equatable, Sendable {
    public let jsonRPCRequestID: JSONRPCBridgeID?
    public let connectionID: String?
    public let connectionGeneration: UInt64?
    public let appInvocationID: String?
    public let requestOrdinal: UInt64?

    public init(
        jsonRPCRequestID: JSONRPCBridgeID? = nil,
        connectionID: String? = nil,
        connectionGeneration: UInt64? = nil,
        appInvocationID: String? = nil,
        requestOrdinal: UInt64? = nil
    ) {
        self.jsonRPCRequestID = jsonRPCRequestID
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.appInvocationID = appInvocationID ?? Self.deterministicAppInvocationID(
            jsonRPCRequestID: jsonRPCRequestID,
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            requestOrdinal: requestOrdinal
        )
        self.requestOrdinal = requestOrdinal
    }

    public static func deterministicAppInvocationID(
        jsonRPCRequestID: JSONRPCBridgeID?,
        connectionID: String?,
        connectionGeneration: UInt64?,
        requestOrdinal: UInt64?
    ) -> String? {
        guard let jsonRPCRequestID, let connectionID, let connectionGeneration, let requestOrdinal else { return nil }
        let seed = "\(connectionID)|\(jsonRPCRequestID.description)|\(connectionGeneration)|\(requestOrdinal)"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }

    public func fillingMissingFields(from fallback: MCPRequestTimelineIdentity?) -> MCPRequestTimelineIdentity {
        MCPRequestTimelineIdentity(
            jsonRPCRequestID: jsonRPCRequestID ?? fallback?.jsonRPCRequestID,
            connectionID: connectionID ?? fallback?.connectionID,
            connectionGeneration: connectionGeneration ?? fallback?.connectionGeneration,
            appInvocationID: appInvocationID ?? fallback?.appInvocationID,
            requestOrdinal: requestOrdinal ?? fallback?.requestOrdinal
        )
    }
}

public enum MCPRequestTimelineContext {
    @TaskLocal public static var current: MCPRequestTimelineIdentity?
}
