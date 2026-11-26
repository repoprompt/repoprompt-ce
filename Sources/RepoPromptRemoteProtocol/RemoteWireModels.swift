import Foundation

public enum RemoteWireProtocol {
    public static let currentVersion = 1
    public static let maximumClientFrameBytes = 1_048_576
    public static let maximumServerResponseFrameBytes = 8_388_608
    /// Reserve capacity for the snapshot RPC envelope and both base64 layers.
    public static let maximumSnapshotJSONBytes = maximumServerResponseFrameBytes / 8
    public static let maximumEventFrameBytes = 1_048_576
    public static let maximumConcurrentRPCStreams = 8
    public static let maximumEventStreams = 1
    public static let pairingAttemptLifetime: TimeInterval = 5 * 60
}

public enum RemoteWireFrameKind: String, Codable, Sendable, CaseIterable {
    case authenticatedHello = "authenticated_hello"
    case pairingHello = "pairing_hello"
    case pairingPrepare = "pairing_prepare"
    case pairingConfirm = "pairing_confirm"
    case pairingConfirmed = "pairing_confirmed"
    case syncConfirm = "sync_confirm"
    case syncConfirmed = "sync_confirmed"
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
    public let sessionID: UUID?
    public let payload: Data

    public init(
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        kind: RemoteWireFrameKind,
        messageID: UUID? = nil,
        sessionID: UUID? = nil,
        payload: Data = Data()
    ) {
        self.wireVersion = wireVersion
        self.kind = kind
        self.messageID = messageID
        self.sessionID = sessionID
        self.payload = payload
    }

    public init(
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        kind: RemoteWireFrameKind,
        messageID: UUID? = nil,
        sessionID: UUID? = nil,
        encoding payload: some Encodable,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        try self.init(
            wireVersion: wireVersion,
            kind: kind,
            messageID: messageID,
            sessionID: sessionID,
            payload: encoder.encode(payload)
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
    case imageAttachment = "image_attachment"
    case command
    case contextBuilder = "context_builder"
}

public struct RemoteRPCRequest: Codable, Sendable, Equatable {
    public let operation: RemoteRPCOperation
    public let payload: Data
    public let acceptsCompressedSnapshot: Bool?

    public init(
        operation: RemoteRPCOperation,
        payload: Data = Data(),
        acceptsCompressedSnapshot: Bool? = nil
    ) {
        self.operation = operation
        self.payload = payload
        self.acceptsCompressedSnapshot = acceptsCompressedSnapshot
    }
}

public struct RemoteRPCResponse: Codable, Sendable, Equatable {
    public let result: Data?
    public let error: RemoteErrorResponse?
    public let syncTicket: UUID?
    public let uncompressedSnapshotBytes: Int?

    public init(result: Data, syncTicket: UUID? = nil, compressSnapshot: Bool = false) {
        self.syncTicket = syncTicket
        error = nil
        if compressSnapshot, let compressed = RemoteSnapshotCompression.encode(result) {
            self.result = compressed
            uncompressedSnapshotBytes = result.count
        } else {
            self.result = result
            uncompressedSnapshotBytes = nil
        }
    }

    public init(error: RemoteErrorResponse) {
        syncTicket = nil
        result = nil
        uncompressedSnapshotBytes = nil
        self.error = error
    }

    public func decodedResult() throws -> Data? {
        guard let result, let uncompressedSnapshotBytes else { return result }
        return try RemoteSnapshotCompression.decode(result, expectedBytes: uncompressedSnapshotBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
        case syncTicket
        case uncompressedSnapshotBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(Data.self, forKey: .result)
        error = try container.decodeIfPresent(RemoteErrorResponse.self, forKey: .error)
        syncTicket = try container.decodeIfPresent(UUID.self, forKey: .syncTicket)
        uncompressedSnapshotBytes = try container.decodeIfPresent(Int.self, forKey: .uncompressedSnapshotBytes)
        guard (result != nil) != (error != nil), uncompressedSnapshotBytes == nil || result != nil else {
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
    public let supportsSyncConfirmation: Bool?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        expectedServerEndpointID: String,
        deviceID: String,
        credential: String,
        supportsSyncConfirmation: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.expectedServerEndpointID = expectedServerEndpointID
        self.deviceID = deviceID
        self.credential = credential
        self.supportsSyncConfirmation = supportsSyncConfirmation
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
    public let sessionID: UUID?
    public let serverAddress: RemoteIrohEndpointAddress?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        desktopInstanceID: String,
        serverEndpointID: String,
        clientEndpointID: String,
        deviceID: String,
        sessionID: UUID? = nil,
        serverAddress: RemoteIrohEndpointAddress? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.wireVersion = wireVersion
        self.desktopInstanceID = desktopInstanceID
        self.serverEndpointID = serverEndpointID
        self.clientEndpointID = clientEndpointID
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.serverAddress = serverAddress
    }
}

public struct RemotePairingConfirmation: Codable, Sendable, Equatable {
    public let attemptID: UUID
    public let authentication: RemoteAuthenticatedHello

    public init(attemptID: UUID, authentication: RemoteAuthenticatedHello) {
        self.attemptID = attemptID
        self.authentication = authentication
    }
}

public struct RemoteHistoryRPCRequest: Codable, Sendable, Equatable {
    public let query: String?
    public let limit: Int
    public let workspaceID: UUID?
    public let before: RemoteHistoryCursor?

    public init(
        query: String? = nil,
        limit: Int = 50,
        workspaceID: UUID? = nil,
        before: RemoteHistoryCursor? = nil
    ) {
        self.query = query
        self.limit = limit
        self.workspaceID = workspaceID
        self.before = before
    }
}

public enum RemoteTranscriptRPCPagingMode: String, Codable, Sendable, Equatable {
    case legacyForward = "legacy_forward"
    case recentBackward = "recent_backward"
}

public enum RemoteImageAttachmentVariant: String, Codable, Sendable {
    case thumbnail
    case original
}

/// A paired device can request an image referenced by a transcript row. No filesystem path crosses the wire.
public struct RemoteImageAttachmentRequest: Codable, Sendable, Equatable {
    public static let chunkBytes = 512 * 1024
    public static let maxThumbnailBytes = 128 * 1024

    public let sessionID: UUID
    public let itemID: UUID
    public let attachmentID: UUID
    public let variant: RemoteImageAttachmentVariant
    public let offset: Int
    public let revision: String?

    public init(
        sessionID: UUID, itemID: UUID, attachmentID: UUID,
        variant: RemoteImageAttachmentVariant, offset: Int = 0, revision: String? = nil
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.attachmentID = attachmentID
        self.variant = variant
        self.offset = offset
        self.revision = revision
    }

    public var isValid: Bool {
        switch variant {
        case .thumbnail:
            offset == 0 && revision == nil
        case .original:
            (0 ..< RemoteAttachmentLimits.maxFileBytes).contains(offset)
                && (offset == 0 ? revision == nil : revision?.isEmpty == false && (revision?.utf8.count ?? 0) <= 128)
        }
    }
}

public struct RemoteImageAttachmentChunk: Codable, Sendable, Equatable {
    public let offset: Int
    public let totalBytes: Int
    public let revision: String?
    public let bytes: Data

    public init(offset: Int, totalBytes: Int, revision: String? = nil, bytes: Data) {
        self.offset = offset
        self.totalBytes = totalBytes
        self.revision = revision
        self.bytes = bytes
    }
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
