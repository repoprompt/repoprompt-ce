import Foundation

public enum RemoteWireProtocol {
    public static let currentVersion = 1
    public static let maximumClientFrameBytes = 1_048_576
    public static let maximumServerResponseFrameBytes = 8_388_608
    public static let maximumEventFrameBytes = 1_048_576
    public static let maximumConcurrentRPCStreams = 8
    public static let maximumEventStreams = 1
}

public enum RemoteWireFrameKind: String, Codable, Sendable, CaseIterable {
    case authenticatedHello = "authenticated_hello"
    case pairingHello = "pairing_hello"
    case helloAccepted = "hello_accepted"
    case rpcRequest = "rpc_request"
    case rpcResponse = "rpc_response"
    case eventSubscribe = "event_subscribe"
    case event
    case heartbeat
    case streamError = "stream_error"
}

public struct RemoteWireFrame: Codable, Sendable, Equatable {
    public let wireVersion: Int
    public let kind: RemoteWireFrameKind
    public let messageID: UUID?
    public let payload: Data

    public init(
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        kind: RemoteWireFrameKind,
        messageID: UUID? = nil,
        payload: Data = Data()
    ) {
        self.wireVersion = wireVersion
        self.kind = kind
        self.messageID = messageID
        self.payload = payload
    }

    public init<Payload: Encodable>(
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        kind: RemoteWireFrameKind,
        messageID: UUID? = nil,
        encoding payload: Payload,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.init(
            wireVersion: wireVersion,
            kind: kind,
            messageID: messageID,
            payload: try encoder.encode(payload)
        )
    }

    public func decodedPayload<Payload: Decodable>(
        as type: Payload.Type,
        expectedKind: RemoteWireFrameKind,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Payload {
        guard wireVersion == RemoteWireProtocol.currentVersion else {
            throw RemoteWireContractError.unsupportedWireVersion(wireVersion)
        }
        guard kind == expectedKind else {
            throw RemoteWireContractError.unexpectedKind(expected: expectedKind, actual: kind)
        }
        do {
            return try decoder.decode(type, from: payload)
        } catch {
            throw RemoteWireContractError.malformedPayload
        }
    }

    /// Enforces the limit on the complete encoded frame. The transport's
    /// four-byte length prefix is intentionally excluded from this count.
    public func validateEncodedLimit(direction: RemoteWireDirection) throws {
        guard wireVersion == RemoteWireProtocol.currentVersion else {
            throw RemoteWireContractError.unsupportedWireVersion(wireVersion)
        }
        let maximum = direction.maximumEncodedFrameBytes
        let actual = try JSONEncoder().encode(self).count
        guard actual <= maximum else {
            throw RemoteWireContractError.frameTooLarge(actual: actual, maximum: maximum)
        }
    }
}

public enum RemoteWireDirection: Sendable, Equatable {
    case clientToServer
    case serverResponse
    case serverEvent

    public var maximumEncodedFrameBytes: Int {
        switch self {
        case .clientToServer:
            RemoteWireProtocol.maximumClientFrameBytes
        case .serverResponse:
            RemoteWireProtocol.maximumServerResponseFrameBytes
        case .serverEvent:
            RemoteWireProtocol.maximumEventFrameBytes
        }
    }
}

public enum RemoteWireContractError: Error, Sendable, Equatable {
    case unsupportedWireVersion(Int)
    case unexpectedKind(expected: RemoteWireFrameKind, actual: RemoteWireFrameKind)
    case malformedPayload
    case frameTooLarge(actual: Int, maximum: Int)
}

public enum RemoteRPCOperation: String, Codable, Sendable, CaseIterable {
    case unpair
    case snapshot
    case diagnostics
    case workspaces
    case sessions
    case agents
    case workflows
    case history
    case transcript
    case command
    case contextBuilder = "context_builder"
    case transportBootstrap = "transport_bootstrap"
    case bindIrohEndpoint = "bind_iroh_endpoint"
}

public struct RemoteRPCRequest: Codable, Sendable, Equatable {
    public let operation: RemoteRPCOperation
    public let payload: Data

    public init(operation: RemoteRPCOperation, payload: Data = Data()) {
        self.operation = operation
        self.payload = payload
    }
}

public struct RemoteRPCResponse: Codable, Sendable, Equatable {
    public let result: Data?
    public let error: RemoteErrorResponse?

    public init(result: Data) {
        self.result = result
        error = nil
    }

    public init(error: RemoteErrorResponse) {
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(Data.self, forKey: .result)
        error = try container.decodeIfPresent(RemoteErrorResponse.self, forKey: .error)
        guard (result != nil) != (error != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "An RPC response must contain exactly one of result or error."
            )
        }
    }
}

public struct RemoteAuthenticatedHello: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let expectedServerEndpointID: String
    public let deviceID: String
    public let credential: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        expectedServerEndpointID: String,
        deviceID: String,
        credential: String
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.expectedServerEndpointID = expectedServerEndpointID
        self.deviceID = deviceID
        self.credential = credential
    }
}

public struct RemotePairingHello: Codable, Sendable, Equatable {
    public let request: RemoteIrohPairingRequest

    public init(request: RemoteIrohPairingRequest) {
        self.request = request
    }
}

public struct RemoteHelloAccepted: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let wireVersion: Int
    public let desktopInstanceID: String
    public let serverEndpointID: String
    public let clientEndpointID: String
    public let deviceID: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        desktopInstanceID: String,
        serverEndpointID: String,
        clientEndpointID: String,
        deviceID: String
    ) {
        self.protocolVersion = protocolVersion
        self.wireVersion = wireVersion
        self.desktopInstanceID = desktopInstanceID
        self.serverEndpointID = serverEndpointID
        self.clientEndpointID = clientEndpointID
        self.deviceID = deviceID
    }
}

public struct RemoteHistoryRPCRequest: Codable, Sendable, Equatable {
    public let query: String?
    public let limit: Int

    public init(query: String? = nil, limit: Int = 50) {
        self.query = query
        self.limit = limit
    }
}

public enum RemoteTranscriptRPCPagingMode: String, Codable, Sendable, Equatable {
    case legacyForward = "legacy_forward"
    case recentBackward = "recent_backward"
}

public struct RemoteTranscriptRPCRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let afterSequenceIndex: Int?
    public let itemID: UUID?
    public let before: RemoteTranscriptCursor?
    public let pagingMode: RemoteTranscriptRPCPagingMode?
    public let limit: Int
    public let includeDetails: Bool

    public init(
        sessionID: UUID,
        afterSequenceIndex: Int? = nil,
        itemID: UUID? = nil,
        before: RemoteTranscriptCursor? = nil,
        pagingMode: RemoteTranscriptRPCPagingMode? = nil,
        limit: Int = 100,
        includeDetails: Bool = false
    ) {
        self.sessionID = sessionID
        self.afterSequenceIndex = afterSequenceIndex
        self.itemID = itemID
        self.before = before
        self.pagingMode = pagingMode
        self.limit = limit
        self.includeDetails = includeDetails
    }
}

public struct RemoteEventSubscriptionRequest: Codable, Sendable, Equatable {
    public let desktopInstanceID: String
    public let after: UInt64?

    public init(desktopInstanceID: String, after: UInt64?) {
        self.desktopInstanceID = desktopInstanceID
        self.after = after
    }
}

public struct RemoteHeartbeat: Codable, Sendable, Equatable {
    public let sentAt: Date

    public init(sentAt: Date = Date()) {
        self.sentAt = sentAt
    }
}
