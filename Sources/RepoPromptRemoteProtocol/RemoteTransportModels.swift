import Foundation

public enum RemoteIrohPathKind: String, Codable, Sendable, Equatable {
    case localDirect = "local_direct"
    case internetDirect = "internet_direct"
    case relay
    case unknown
}

public struct RemoteIrohEndpointAddress: Codable, Sendable, Equatable {
    public static let maximumDirectAddressCount = 4

    public let endpointID: String
    public let directAddresses: [String]
    public let relayURL: String?
    /// Opaque serde representation consumed only by the locked Iroh bridge.
    /// Endpoint identity is still checked independently before connecting.
    public let transportAddressJSON: String?

    public init(
        endpointID: String,
        directAddresses: [String] = [],
        relayURL: String? = nil,
        transportAddressJSON: String? = nil
    ) {
        self.endpointID = endpointID
        self.directAddresses = Array(directAddresses.prefix(Self.maximumDirectAddressCount))
        self.relayURL = relayURL
        self.transportAddressJSON = transportAddressJSON
    }

    private enum CodingKeys: String, CodingKey {
        case endpointID
        case directAddresses
        case relayURL
        case transportAddressJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpointID = try container.decode(String.self, forKey: .endpointID)
        let addresses = try container.decodeIfPresent([String].self, forKey: .directAddresses) ?? []
        guard addresses.count <= Self.maximumDirectAddressCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .directAddresses,
                in: container,
                debugDescription: "An Iroh endpoint address may contain at most four direct addresses."
            )
        }
        directAddresses = addresses
        relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL)
        transportAddressJSON = try container.decodeIfPresent(String.self, forKey: .transportAddressJSON)
    }
}

/// Short-lived pairing data containing the authenticated Mac endpoint.
public struct RemoteIrohPairingAdvertisement: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let server: RemoteIrohEndpointAddress
    public let alpn: String
    public let oneTimeSecret: String
    public let expiresAt: Date

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        server: RemoteIrohEndpointAddress,
        alpn: String = RemoteProtocol.irohALPN,
        oneTimeSecret: String,
        expiresAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.server = server
        self.alpn = alpn
        self.oneTimeSecret = oneTimeSecret
        self.expiresAt = expiresAt
    }
}

public struct RemoteIrohPairingRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let expectedServerEndpointID: String
    public let clientEndpointID: String
    public let oneTimeSecret: String
    public let deviceName: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        expectedServerEndpointID: String,
        clientEndpointID: String,
        oneTimeSecret: String,
        deviceName: String
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.expectedServerEndpointID = expectedServerEndpointID
        self.clientEndpointID = clientEndpointID
        self.oneTimeSecret = oneTimeSecret
        self.deviceName = deviceName
    }
}

public struct RemoteIrohPairingResponse: Codable, Sendable, Equatable {
    public let pairingResponse: RemotePairingResponse
    public let serverEndpointID: String
    public let clientEndpointID: String

    public init(
        pairingResponse: RemotePairingResponse,
        serverEndpointID: String,
        clientEndpointID: String
    ) {
        self.pairingResponse = pairingResponse
        self.serverEndpointID = serverEndpointID
        self.clientEndpointID = clientEndpointID
    }
}
