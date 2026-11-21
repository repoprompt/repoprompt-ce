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

public struct RemoteIrohPairingAdvertisement: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let server: RemoteIrohEndpointAddress
    public let alpn: String
    public let oneTimeSecret: String
    public let expiresAt: Date
    public let legacyFallback: RemotePairingAdvertisement

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        server: RemoteIrohEndpointAddress,
        alpn: String = RemoteProtocol.irohALPN,
        oneTimeSecret: String,
        expiresAt: Date,
        legacyFallback: RemotePairingAdvertisement
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.server = server
        self.alpn = alpn
        self.oneTimeSecret = oneTimeSecret
        self.expiresAt = expiresAt
        self.legacyFallback = legacyFallback
    }
}

public enum RemotePairingCode: Codable, Sendable, Equatable {
    case legacyLAN(RemotePairingAdvertisement)
    case iroh(RemoteIrohPairingAdvertisement)

    private enum Discriminator: String, Codable {
        case legacyLAN = "legacy_lan"
        case iroh
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case advertisement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .kind) {
        case .legacyLAN:
            self = .legacyLAN(try container.decode(RemotePairingAdvertisement.self, forKey: .advertisement))
        case .iroh:
            self = .iroh(try container.decode(RemoteIrohPairingAdvertisement.self, forKey: .advertisement))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .legacyLAN(advertisement):
            try container.encode(Discriminator.legacyLAN, forKey: .kind)
            try container.encode(advertisement, forKey: .advertisement)
        case let .iroh(advertisement):
            try container.encode(Discriminator.iroh, forKey: .kind)
            try container.encode(advertisement, forKey: .advertisement)
        }
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

public struct RemoteTransportBootstrapResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let wireVersion: Int
    public let desktopInstanceID: String
    public let server: RemoteIrohEndpointAddress
    public let alpn: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        desktopInstanceID: String,
        server: RemoteIrohEndpointAddress,
        alpn: String = RemoteProtocol.irohALPN
    ) {
        self.protocolVersion = protocolVersion
        self.wireVersion = wireVersion
        self.desktopInstanceID = desktopInstanceID
        self.server = server
        self.alpn = alpn
    }
}

public struct RemoteIrohBindingRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let deviceID: String
    public let expectedServerEndpointID: String
    public let clientEndpointID: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        deviceID: String,
        expectedServerEndpointID: String,
        clientEndpointID: String
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.expectedServerEndpointID = expectedServerEndpointID
        self.clientEndpointID = clientEndpointID
    }
}

public struct RemoteIrohBindingResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktopInstanceID: String
    public let deviceID: String
    public let serverEndpointID: String
    public let clientEndpointID: String

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktopInstanceID: String,
        deviceID: String,
        serverEndpointID: String,
        clientEndpointID: String
    ) {
        self.protocolVersion = protocolVersion
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.serverEndpointID = serverEndpointID
        self.clientEndpointID = clientEndpointID
    }
}
