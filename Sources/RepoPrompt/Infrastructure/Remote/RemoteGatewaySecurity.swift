import CryptoKit
import Foundation
import RepoPromptRemoteProtocol
import RepoPromptSecureStorage
import Security

enum RemoteGatewaySecurityError: LocalizedError {
    case keychainFailure(OSStatus)
    case pairingSecretInvalid
    case pairingSecretExpired
    case endpointBindingInvalid
    case unsupportedProtocol(Int)
    case deviceCredentialUnavailable

    var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            "Remote credential storage failed (Keychain status \(status))."
        case .pairingSecretInvalid:
            "The pairing code is invalid."
        case .pairingSecretExpired:
            "The pairing code has expired."
        case .endpointBindingInvalid:
            "The authenticated Iroh endpoint binding is invalid."
        case let .unsupportedProtocol(version):
            "The pairing request uses unsupported protocol version \(version)."
        case .deviceCredentialUnavailable:
            "No paired device credential is available."
        }
    }
}

struct RemoteGatewayKeychain {
    private static let accessMode = KeychainAccessMode.nonInteractive(reason: .backgroundAvailabilityCheck)
    static let shared = Self(backend: SecureKeyValueStorageFactory.defaultBackend())

    let backend: any SecureKeyValueStorageBackend

    func read(_ account: SecureStorageAccount) throws -> Data? {
        do {
            let value = try backend.get(for: account.identifier, accessMode: Self.accessMode)
            guard value != "revoked" else { return nil }
            guard let data = Data(base64Encoded: value) else { throw KeychainService.KeychainError.invalidData }
            return data
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
    }

    func write(_ data: Data, for account: SecureStorageAccount) throws {
        try backend.save(data.base64EncodedString(), for: account.identifier, accessMode: Self.accessMode)
    }

    func remove(_ account: SecureStorageAccount) throws {
        try backend.save("revoked", for: account.identifier, accessMode: Self.accessMode)
    }
}

private func remoteRandomBytes(byteCount: Int) throws -> Data {
    var bytes = Data(count: byteCount)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw RemoteGatewaySecurityError.keychainFailure(status)
    }
    return bytes
}

private func remoteBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

struct RemoteStoredDeviceCredential: Codable, Equatable {
    let deviceID: String
    let credential: String
    let expiresAt: Date
    let deviceName: String
    let irohPeerEndpointID: String
}

enum RemoteConstantTimeComparison {
    /// Compares every byte up to the larger input length. Pairing callers hash
    /// both inputs first, so production comparisons always process 32 bytes.
    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        let lhsBytes = [UInt8](lhs)
        let rhsBytes = [UInt8](rhs)
        let count = max(lhsBytes.count, rhsBytes.count)
        var difference = UInt64(lhsBytes.count ^ rhsBytes.count)
        for index in 0 ..< count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= UInt64(lhsByte ^ rhsByte)
        }
        return difference == 0
    }
}

enum RemoteCredentialAuthority {
    static func accepts(
        authorizationHeader: String?,
        credential: RemoteStoredDeviceCredential?,
        at date: Date = Date()
    ) -> Bool {
        guard let credential,
              date < credential.expiresAt,
              let authorizationHeader,
              authorizationHeader.hasPrefix("Bearer ")
        else { return false }
        return String(authorizationHeader.dropFirst("Bearer ".count)) == credential.credential
    }

    static func acceptsIroh(
        authorizationHeader: String?,
        deviceID: String,
        authenticatedPeerEndpointID: String,
        credential: RemoteStoredDeviceCredential?,
        at date: Date = Date()
    ) -> Bool {
        guard let credential,
              credential.deviceID == deviceID,
              credential.irohPeerEndpointID == authenticatedPeerEndpointID
        else { return false }
        return accepts(authorizationHeader: authorizationHeader, credential: credential, at: date)
    }
}

private struct RemoteStoredNotificationRegistration: Codable, Equatable {
    let registration: RemoteNotificationRegistration
    let updatedAt: Date
}

private struct RemotePendingPairingSecret {
    let value: String
    let digest: Data
    let issuedAt: Date
    let expiresAt: Date
}

@MainActor
final class RemotePairingManager {
    static let pairingLifetime: TimeInterval = 5 * 60
    static let credentialLifetime: TimeInterval = 60 * 60 * 24 * 30
    static let maximumDeviceNameCharacters = 128

    let desktopInstanceID: String
    private var pendingSecret: RemotePendingPairingSecret?
    private var storedDevice: RemoteStoredDeviceCredential?
    private var notificationRegistration: RemoteNotificationRegistration?

    private let now: () -> Date
    private let randomBytes: (Int) throws -> Data
    private let persistStoredDevice: (RemoteStoredDeviceCredential?) throws -> Void
    private let encoder = JSONEncoder()

    convenience init() {
        let decoder = JSONDecoder()
        let key = "RepoPrompt.remote.desktopInstanceID"
        let desktopInstanceID: String
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            desktopInstanceID = existing
        } else {
            desktopInstanceID = UUID().uuidString
            UserDefaults.standard.set(desktopInstanceID, forKey: key)
        }
        let storedDevice = try? RemoteGatewayKeychain.shared.read(.remotePairedDevice)
            .flatMap { try decoder.decode(RemoteStoredDeviceCredential.self, from: $0) }
        let notificationRegistration = try? RemoteGatewayKeychain.shared.read(.remoteNotificationRegistration)
            .flatMap { try decoder.decode(RemoteStoredNotificationRegistration.self, from: $0).registration }

        self.init(
            desktopInstanceID: desktopInstanceID,
            storedDevice: storedDevice,
            notificationRegistration: notificationRegistration,
            now: Date.init,
            randomBytes: remoteRandomBytes,
            persistStoredDevice: { credential in
                if let credential {
                    try RemoteGatewayKeychain.shared.write(
                        JSONEncoder().encode(credential),
                        for: .remotePairedDevice
                    )
                } else {
                    try RemoteGatewayKeychain.shared.remove(.remotePairedDevice)
                }
            }
        )
    }

    init(
        desktopInstanceID: String,
        storedDevice: RemoteStoredDeviceCredential? = nil,
        notificationRegistration: RemoteNotificationRegistration? = nil,
        now: @escaping () -> Date,
        randomBytes: @escaping (Int) throws -> Data,
        persistStoredDevice: @escaping (RemoteStoredDeviceCredential?) throws -> Void
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.storedDevice = storedDevice
        self.notificationRegistration = notificationRegistration
        self.now = now
        self.randomBytes = randomBytes
        self.persistStoredDevice = persistStoredDevice
    }

    var isPaired: Bool {
        storedDevice != nil
    }

    var pairedDeviceID: String? {
        storedDevice?.deviceID
    }

    var pairedCredential: String? {
        storedDevice?.credential
    }

    var pairedDeviceName: String? {
        storedDevice?.deviceName
    }

    var pairedIrohPeerEndpointID: String? {
        storedDevice?.irohPeerEndpointID
    }

    var registeredNotification: RemoteNotificationRegistration? {
        notificationRegistration
    }

    func issueAdvertisement(server: RemoteIrohEndpointAddress) throws -> RemoteIrohPairingAdvertisement {
        let pending = try createPendingSecret()
        return RemoteIrohPairingAdvertisement(
            desktopInstanceID: desktopInstanceID,
            server: server,
            oneTimeSecret: pending.value,
            expiresAt: pending.expiresAt
        )
    }

    func invalidateAdvertisement() {
        pendingSecret = nil
    }

    func pairIroh(
        request: RemoteIrohPairingRequest,
        authenticatedPeerEndpointID: String,
        serverEndpointID: String,
        desktop: RemoteDesktopSummary
    ) throws -> RemoteIrohPairingResponse {
        try validateProtocolAndDesktop(
            protocolVersion: request.protocolVersion,
            requestedDesktopInstanceID: request.desktopInstanceID
        )
        guard request.expectedServerEndpointID == serverEndpointID,
              request.clientEndpointID == authenticatedPeerEndpointID,
              Self.isCanonicalEndpointID(serverEndpointID),
              Self.isCanonicalEndpointID(authenticatedPeerEndpointID)
        else {
            throw RemoteGatewaySecurityError.endpointBindingInvalid
        }
        try consumePendingSecret(request.oneTimeSecret)
        let credential = try createAndPersistCredential(
            deviceName: request.deviceName,
            irohPeerEndpointID: authenticatedPeerEndpointID
        )
        return RemoteIrohPairingResponse(
            pairingResponse: pairingResponse(for: credential, desktop: desktop),
            serverEndpointID: serverEndpointID,
            clientEndpointID: authenticatedPeerEndpointID
        )
    }

    func isAuthorizedIroh(
        authorizationHeader: String?,
        deviceID: String,
        authenticatedPeerEndpointID: String
    ) -> Bool {
        RemoteCredentialAuthority.acceptsIroh(
            authorizationHeader: authorizationHeader,
            deviceID: deviceID,
            authenticatedPeerEndpointID: authenticatedPeerEndpointID,
            credential: storedDevice,
            at: now()
        )
    }

    func revokeDevice() throws {
        // Durable credential deletion must succeed before the in-memory paired
        // state changes, otherwise a restart could resurrect a revoked phone.
        try persistStoredDevice(nil)
        pendingSecret = nil
        storedDevice = nil
        notificationRegistration = nil
        // The bearer deletion above is the authoritative revocation. Ancillary
        // notification cleanup must not turn a successful unpair into a failure.
        try? RemoteGatewayKeychain.shared.remove(.remoteNotificationRegistration)
    }

    func registerNotifications(_ registration: RemoteNotificationRegistration) throws {
        guard !registration.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let storedDevice,
              now() < storedDevice.expiresAt
        else {
            throw RemoteGatewaySecurityError.deviceCredentialUnavailable
        }
        let stored = RemoteStoredNotificationRegistration(registration: registration, updatedAt: now())
        try RemoteGatewayKeychain.shared.write(
            encoder.encode(stored),
            for: .remoteNotificationRegistration
        )
        notificationRegistration = registration
    }

    private func createPendingSecret() throws -> RemotePendingPairingSecret {
        let issuedAt = now()
        let value = try remoteBase64URL(randomBytes(32))
        let pending = RemotePendingPairingSecret(
            value: value,
            digest: Data(SHA256.hash(data: Data(value.utf8))),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(Self.pairingLifetime)
        )
        pendingSecret = pending
        return pending
    }

    private func validateProtocolAndDesktop(
        protocolVersion: Int,
        requestedDesktopInstanceID: String
    ) throws {
        guard RemoteProtocol.supports(protocolVersion) else {
            throw RemoteGatewaySecurityError.unsupportedProtocol(protocolVersion)
        }
        guard requestedDesktopInstanceID == desktopInstanceID else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
    }

    private func consumePendingSecret(_ candidate: String) throws {
        guard let pendingSecret else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
        guard now() < pendingSecret.expiresAt else {
            self.pendingSecret = nil
            throw RemoteGatewaySecurityError.pairingSecretExpired
        }
        let candidateDigest = Data(SHA256.hash(data: Data(candidate.utf8)))
        guard RemoteConstantTimeComparison.equals(candidateDigest, pendingSecret.digest) else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
        self.pendingSecret = nil
    }

    private func createAndPersistCredential(
        deviceName: String,
        irohPeerEndpointID: String
    ) throws -> RemoteStoredDeviceCredential {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedName = String(trimmedName.prefix(Self.maximumDeviceNameCharacters))
        let credential = try RemoteStoredDeviceCredential(
            deviceID: UUID().uuidString,
            credential: remoteBase64URL(randomBytes(48)),
            expiresAt: now().addingTimeInterval(Self.credentialLifetime),
            deviceName: boundedName.isEmpty ? "Remote device" : boundedName,
            irohPeerEndpointID: irohPeerEndpointID
        )
        try persistStoredDevice(credential)
        storedDevice = credential
        notificationRegistration = nil
        try? RemoteGatewayKeychain.shared.remove(.remoteNotificationRegistration)
        return credential
    }

    private static func isCanonicalEndpointID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private func pairingResponse(
        for credential: RemoteStoredDeviceCredential,
        desktop: RemoteDesktopSummary
    ) -> RemotePairingResponse {
        RemotePairingResponse(
            desktop: desktop,
            deviceID: credential.deviceID,
            credential: credential.credential,
            credentialExpiresAt: credential.expiresAt
        )
    }
}
