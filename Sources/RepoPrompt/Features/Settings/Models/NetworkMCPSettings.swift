import Foundation

struct NetworkMCPSettings: Codable, Equatable {
    static let defaultEnabled = false
    static let defaultBindAddress = "127.0.0.1"
    static let defaultPort = 4150

    var enabled: Bool?
    var bindAddress: String?
    var port: Int?
    var defaultTarget: NetworkMCPDefaultTargetMetadata?
    var token: NetworkMCPBearerTokenMetadata?
    var trustedClients: [NetworkMCPTrustedClientPolicy]?

    init(
        enabled: Bool? = nil,
        bindAddress: String? = nil,
        port: Int? = nil,
        defaultTarget: NetworkMCPDefaultTargetMetadata? = nil,
        token: NetworkMCPBearerTokenMetadata? = nil,
        trustedClients: [NetworkMCPTrustedClientPolicy]? = nil
    ) {
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.port = port
        self.defaultTarget = defaultTarget
        self.token = token
        self.trustedClients = trustedClients
    }
}

struct NetworkMCPDefaultTargetMetadata: Codable, Equatable {
    var workspaceID: UUID?
    var contextID: String?
    var displayName: String?
    var rootPaths: [String]
    var openIfNeeded: Bool?
    var updatedAt: Date?

    init(
        workspaceID: UUID? = nil,
        contextID: String? = nil,
        displayName: String? = nil,
        rootPaths: [String] = [],
        openIfNeeded: Bool? = nil,
        updatedAt: Date? = nil
    ) {
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.displayName = displayName
        self.rootPaths = rootPaths
        self.openIfNeeded = openIfNeeded
        self.updatedAt = updatedAt
    }
}

struct NetworkMCPBearerTokenMetadata: Codable, Equatable {
    var id: UUID
    var label: String
    var fingerprint: String
    var createdAt: Date
    var rotatedAt: Date?
    var secureStoragePersistsAcrossLaunches: Bool?

    init(
        id: UUID = UUID(),
        label: String,
        fingerprint: String,
        createdAt: Date,
        rotatedAt: Date? = nil,
        secureStoragePersistsAcrossLaunches: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.rotatedAt = rotatedAt
        self.secureStoragePersistsAcrossLaunches = secureStoragePersistsAcrossLaunches
    }
}

struct NetworkMCPTrustedClientPolicy: Codable, Equatable, Identifiable {
    var id: UUID
    var clientDisplayName: String?
    var normalizedClientID: String
    var tokenFingerprint: String
    var lastAddress: String?
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        clientDisplayName: String? = nil,
        normalizedClientID: String,
        tokenFingerprint: String,
        lastAddress: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.clientDisplayName = clientDisplayName
        self.normalizedClientID = normalizedClientID
        self.tokenFingerprint = tokenFingerprint
        self.lastAddress = lastAddress
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

struct NetworkMCPSettingsSnapshot: Equatable {
    var enabled: Bool
    var bindAddress: String
    var port: Int
    var defaultTarget: NetworkMCPDefaultTargetMetadata?
    var token: NetworkMCPBearerTokenMetadata?
    var trustedClients: [NetworkMCPTrustedClientPolicy]

    init(
        enabled: Bool = NetworkMCPSettings.defaultEnabled,
        bindAddress: String = NetworkMCPSettings.defaultBindAddress,
        port: Int = NetworkMCPSettings.defaultPort,
        defaultTarget: NetworkMCPDefaultTargetMetadata? = nil,
        token: NetworkMCPBearerTokenMetadata? = nil,
        trustedClients: [NetworkMCPTrustedClientPolicy] = []
    ) {
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.port = port
        self.defaultTarget = defaultTarget
        self.token = token
        self.trustedClients = trustedClients
    }
}

enum NetworkMCPSettingsError: Error, Equatable {
    case invalidBindAddress(String)
    case invalidPort(Int)
    case missingDefaultTarget
    case missingTokenMetadata
    case missingSecureTokenMaterial
}

@MainActor
final class NetworkMCPSettingsFacade {
    private let settingsStore: GlobalSettingsStore
    private let tokenStore: MCPRemoteBearerTokenStore

    init(
        settingsStore: GlobalSettingsStore = .shared,
        tokenStore: MCPRemoteBearerTokenStore = MCPRemoteBearerTokenStore()
    ) {
        self.settingsStore = settingsStore
        self.tokenStore = tokenStore
    }

    func settingsSnapshot() -> NetworkMCPSettingsSnapshot {
        settingsStore.networkMCPSettingsSnapshot()
    }

    func setEnabled(_ enabled: Bool, commit: Bool = true) throws {
        let secureTokenAvailable = if enabled {
            try tokenStore.hasPrimaryToken(
                accessMode: .nonInteractive(reason: .networkMCPAuthentication)
            )
        } else {
            false
        }
        try settingsStore.setNetworkMCPEnabled(
            enabled,
            secureTokenMaterialAvailable: secureTokenAvailable,
            commit: commit
        )
    }
}
