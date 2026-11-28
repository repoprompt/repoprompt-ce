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
    case attemptUnavailable
    case confirmationRejected
    case pairingInProgress
    case alreadyPaired
    case gatewayUnavailable
    case storageResetUnavailable

    var response: RemoteErrorResponse {
        let code = switch self {
        case .pairingSecretExpired: "pairing_expired"
        case .pairingSecretInvalid, .attemptUnavailable: "pairing_unavailable"
        case .endpointBindingInvalid: "endpoint_mismatch"
        case .unsupportedProtocol: "unsupported_protocol_version"
        case .confirmationRejected: "pairing_confirmation_rejected"
        case .pairingInProgress: "pairing_in_progress"
        case .alreadyPaired: "already_paired"
        case .gatewayUnavailable: "gateway_unavailable"
        case .storageResetUnavailable: "pairing_storage_unavailable"
        default: "pairing_storage_unavailable"
        }
        return .init(code: code, message: localizedDescription, retryable: code == "pairing_storage_unavailable" || code == "gateway_unavailable")
    }

    var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            "Remote credential storage failed (Keychain status \(status))."
        case .pairingSecretInvalid:
            "This pairing code is no longer available. Generate a new code on your Mac."
        case .pairingSecretExpired:
            "This pairing attempt expired. Generate a new code on your Mac."
        case .endpointBindingInvalid:
            "The authenticated Iroh endpoint binding is invalid."
        case let .unsupportedProtocol(version):
            "The pairing request uses unsupported protocol version \(version)."
        case .deviceCredentialUnavailable:
            "No paired device credential is available."
        case .attemptUnavailable:
            "This pairing attempt is no longer available. Generate a new code on your Mac."
        case .confirmationRejected:
            "The Mac could not verify this pairing confirmation. Generate a new code on your Mac."
        case .pairingInProgress:
            "A phone is already confirming this code. Resume on that phone or generate a new code."
        case .alreadyPaired:
            "This Mac is already paired. To replace the phone, unpair it in Mac Settings."
        case .gatewayUnavailable:
            "Remote is unavailable on your Mac. Enable Remote in Mac Settings to resume."
        case .storageResetUnavailable:
            "Pairing storage can be reset when the existing record is unreadable."
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
    var pairingAttemptID: UUID? = nil
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
        let bearer = authorizationHeader.dropFirst("Bearer ".count)
        guard bearer.utf8.count <= 256 else { return false }
        let received = Data(SHA256.hash(data: Data(bearer.utf8)))
        let expected = Data(SHA256.hash(data: Data(credential.credential.utf8)))
        return RemoteConstantTimeComparison.equals(received, expected)
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

struct RemotePendingPairingSecret: Codable, Equatable {
    let value: String
    let expiresAt: Date
}

struct RemotePendingPairing: Codable, Equatable {
    let attemptID: UUID
    let secretDigest: Data
    let serverEndpointID: String
    let expiresAt: Date
    let credential: RemoteStoredDeviceCredential
}

/// One Keychain item is the transaction boundary for prepare, promotion and revocation.
struct RemoteStoredPairingState: Codable, Equatable {
    let version: Int
    var active: RemoteStoredDeviceCredential?
    var pending: RemotePendingPairing?
    var advertisement: RemotePendingPairingSecret?

    init(
        active: RemoteStoredDeviceCredential? = nil,
        pending: RemotePendingPairing? = nil,
        advertisement: RemotePendingPairingSecret? = nil
    ) {
        version = 1
        self.active = active
        self.pending = pending
        self.advertisement = advertisement
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(Self.self, from: data), state.version == 1 {
            return state
        }
        return try Self(active: decoder.decode(RemoteStoredDeviceCredential.self, from: data))
    }
}

enum RemoteDesktopPairingStatus: Equatable {
    case idle
    case codeReady(expiresAt: Date)
    case codeExpired
    case pending(deviceName: String, expiresAt: Date)
    case attemptExpired
    case paired(expiresAt: Date)
    case credentialExpired
    case storageUnavailable
    case storageUnreadable
}

@MainActor
final class RemotePairingManager {
    static let pairingLifetime = RemoteWireProtocol.pairingAttemptLifetime
    static let credentialLifetime: TimeInterval = 60 * 60 * 24 * 30
    static let maximumDeviceNameCharacters = 128

    let desktopInstanceID: String
    private var pendingSecret: RemotePendingPairingSecret? {
        storedState.advertisement
    }

    private var storedState: RemoteStoredPairingState
    private(set) var storageError: Error?
    private let reloadStoredState: (() throws -> RemoteStoredPairingState)?
    private var storedDevice: RemoteStoredDeviceCredential? {
        storedState.active
    }

    private var notificationRegistration: RemoteNotificationRegistration?

    private let now: () -> Date
    private let randomBytes: (Int) throws -> Data
    private let persistState: (RemoteStoredPairingState) throws -> Void
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
        let notificationRegistration = try? RemoteGatewayKeychain.shared.read(.remoteNotificationRegistration)
            .flatMap { try decoder.decode(RemoteStoredNotificationRegistration.self, from: $0).registration }
        self.init(
            desktopInstanceID: desktopInstanceID,
            notificationRegistration: notificationRegistration,
            now: Date.init,
            randomBytes: remoteRandomBytes,
            reloadStoredState: {
                try RemoteGatewayKeychain.shared.read(.remotePairedDevice)
                    .map(RemoteStoredPairingState.decode) ?? RemoteStoredPairingState()
            },
            persistState: { state in
                if state.pending == nil, state.advertisement == nil {
                    if let active = state.active {
                        // Existing desktop builds can still read confirmed credentials after a rollback.
                        try RemoteGatewayKeychain.shared.write(
                            JSONEncoder().encode(active), for: .remotePairedDevice
                        )
                    } else {
                        try RemoteGatewayKeychain.shared.remove(.remotePairedDevice)
                    }
                } else {
                    try RemoteGatewayKeychain.shared.write(
                        JSONEncoder().encode(state), for: .remotePairedDevice
                    )
                }
            }
        )
    }

    init(
        desktopInstanceID: String,
        storedState: RemoteStoredPairingState = .init(),
        notificationRegistration: RemoteNotificationRegistration? = nil,
        now: @escaping () -> Date,
        randomBytes: @escaping (Int) throws -> Data,
        reloadStoredState: (() throws -> RemoteStoredPairingState)? = nil,
        persistState: @escaping (RemoteStoredPairingState) throws -> Void
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.storedState = storedState
        self.notificationRegistration = notificationRegistration
        self.now = now
        self.randomBytes = randomBytes
        self.reloadStoredState = reloadStoredState
        self.persistState = persistState
        retryStorageRead()
    }

    func retryStorageRead() {
        guard let reloadStoredState else { return }
        do {
            storedState = try reloadStoredState()
            storageError = nil
        } catch {
            storageError = error
        }
    }

    var hasStoredPairing: Bool {
        storedDevice != nil || storedState.pending != nil || pendingSecret != nil
    }

    var isPaired: Bool {
        guard storageError == nil, let storedDevice else { return false }
        return now() < storedDevice.expiresAt
    }

    var status: RemoteDesktopPairingStatus {
        if let storageError {
            let unreadable = storageError is DecodingError
                || (storageError as? KeychainService.KeychainError) == .invalidData
            return unreadable ? .storageUnreadable : .storageUnavailable
        }
        if isPaired, let storedDevice {
            return .paired(expiresAt: storedDevice.expiresAt)
        }
        if let pending = storedState.pending {
            return now() < pending.expiresAt
                ? .pending(deviceName: pending.credential.deviceName, expiresAt: pending.expiresAt)
                : .attemptExpired
        }
        if let pendingSecret {
            return now() < pendingSecret.expiresAt ? .codeReady(expiresAt: pendingSecret.expiresAt) : .codeExpired
        }
        return storedDevice == nil ? .idle : .credentialExpired
    }

    var pairedDeviceID: String? {
        isPaired ? storedDevice?.deviceID : nil
    }

    var pairedCredential: String? {
        isPaired ? storedDevice?.credential : nil
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
        if let storageError {
            throw storageError
        }
        guard !isPaired else { throw RemoteGatewaySecurityError.alreadyPaired }
        let pending = try createPendingSecret()
        try save(.init(active: storedDevice, advertisement: pending))
        return makeAdvertisement(server: server, secret: pending)
    }

    func restoreAdvertisement(server: RemoteIrohEndpointAddress) -> RemoteIrohPairingAdvertisement? {
        guard let pendingSecret, case .codeReady = status else { return nil }
        return makeAdvertisement(server: server, secret: pendingSecret)
    }

    private func makeAdvertisement(
        server: RemoteIrohEndpointAddress, secret: RemotePendingPairingSecret
    ) -> RemoteIrohPairingAdvertisement {
        RemoteIrohPairingAdvertisement(
            desktopInstanceID: desktopInstanceID,
            server: server,
            oneTimeSecret: secret.value,
            expiresAt: secret.expiresAt,
            requiresPairingConfirmation: true
        )
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
        if let storageError {
            throw storageError
        }
        guard !isPaired else { throw RemoteGatewaySecurityError.alreadyPaired }
        guard request.oneTimeSecret.utf8.count <= 256 else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
        let digest = Data(SHA256.hash(data: Data(request.oneTimeSecret.utf8)))
        if let pending = storedState.pending {
            guard pending.attemptID == request.attemptID,
                  pending.serverEndpointID == serverEndpointID,
                  pending.credential.irohPeerEndpointID == authenticatedPeerEndpointID,
                  RemoteConstantTimeComparison.equals(digest, pending.secretDigest)
            else { throw RemoteGatewaySecurityError.pairingInProgress }
            guard now() < pending.expiresAt else { throw RemoteGatewaySecurityError.pairingSecretExpired }
            return provisionalResponse(for: pending, desktop: desktop)
        }

        try validatePendingSecret(digest)
        let credential = try createCredential(
            deviceName: request.deviceName,
            irohPeerEndpointID: authenticatedPeerEndpointID,
            attemptID: request.attemptID
        )
        guard let attemptID = request.attemptID else {
            // A legacy phone can redeem only a fresh QR; it cannot replace a staged or active pairing.
            try activate(credential)
            return RemoteIrohPairingResponse(
                pairingResponse: pairingResponse(for: credential, desktop: desktop),
                serverEndpointID: serverEndpointID,
                clientEndpointID: authenticatedPeerEndpointID
            )
        }
        let pending = RemotePendingPairing(
            attemptID: attemptID,
            secretDigest: digest,
            serverEndpointID: serverEndpointID,
            expiresAt: now().addingTimeInterval(Self.pairingLifetime),
            credential: credential
        )
        try save(.init(active: storedDevice, pending: pending))
        return provisionalResponse(for: pending, desktop: desktop)
    }

    /// Returns true only for the promotion. An authenticated retry returns the same acknowledgment.
    func confirmIroh(
        _ confirmation: RemotePairingConfirmation,
        authenticatedPeerEndpointID: String,
        serverEndpointID: String
    ) throws -> Bool {
        let hello = confirmation.authentication
        try validateProtocolAndDesktop(
            protocolVersion: hello.protocolVersion,
            requestedDesktopInstanceID: hello.desktopInstanceID
        )
        guard hello.expectedServerEndpointID == serverEndpointID else {
            throw RemoteGatewaySecurityError.endpointBindingInvalid
        }
        if let storageError {
            throw storageError
        }
        func matches(_ credential: RemoteStoredDeviceCredential) -> Bool {
            credential.pairingAttemptID == confirmation.attemptID && RemoteCredentialAuthority.acceptsIroh(
                authorizationHeader: "Bearer \(hello.credential)",
                deviceID: hello.deviceID,
                authenticatedPeerEndpointID: authenticatedPeerEndpointID,
                credential: credential,
                at: now()
            )
        }
        if let storedDevice, isPaired {
            guard matches(storedDevice) else { throw RemoteGatewaySecurityError.confirmationRejected }
            return false
        }
        guard let pending = storedState.pending else { throw RemoteGatewaySecurityError.attemptUnavailable }
        guard pending.serverEndpointID == serverEndpointID, matches(pending.credential) else {
            throw RemoteGatewaySecurityError.confirmationRejected
        }
        guard now() < pending.expiresAt else { throw RemoteGatewaySecurityError.pairingSecretExpired }
        try activate(pending.credential)
        return true
    }

    private func activate(_ credential: RemoteStoredDeviceCredential) throws {
        try save(.init(active: credential))
        notificationRegistration = nil
        try? RemoteGatewayKeychain.shared.remove(.remoteNotificationRegistration)
    }

    func isAuthorizedIroh(
        authorizationHeader: String?,
        deviceID: String,
        authenticatedPeerEndpointID: String
    ) -> Bool {
        storageError == nil && RemoteCredentialAuthority.acceptsIroh(
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
        if let storageError {
            throw storageError
        }
        try clearPairingStorage()
    }

    func resetUnreadableStorage() throws {
        guard status == .storageUnreadable else {
            throw RemoteGatewaySecurityError.storageResetUnavailable
        }
        try clearPairingStorage()
    }

    private func clearPairingStorage() throws {
        try save(.init())
        storageError = nil
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
        return RemotePendingPairingSecret(
            value: value,
            expiresAt: issuedAt.addingTimeInterval(Self.pairingLifetime)
        )
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

    private func validatePendingSecret(_ candidateDigest: Data) throws {
        guard let pendingSecret else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
        guard now() < pendingSecret.expiresAt else {
            throw RemoteGatewaySecurityError.pairingSecretExpired
        }
        let expectedDigest = Data(SHA256.hash(data: Data(pendingSecret.value.utf8)))
        guard RemoteConstantTimeComparison.equals(candidateDigest, expectedDigest) else {
            throw RemoteGatewaySecurityError.pairingSecretInvalid
        }
    }

    private func save(_ state: RemoteStoredPairingState) throws {
        try persistState(state)
        storedState = state
    }

    private func createCredential(
        deviceName: String,
        irohPeerEndpointID: String,
        attemptID: UUID?
    ) throws -> RemoteStoredDeviceCredential {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedName = String(trimmedName.prefix(Self.maximumDeviceNameCharacters))
        return try RemoteStoredDeviceCredential(
            deviceID: UUID().uuidString,
            credential: remoteBase64URL(randomBytes(48)),
            expiresAt: now().addingTimeInterval(Self.credentialLifetime),
            deviceName: boundedName.isEmpty ? "Remote device" : boundedName,
            irohPeerEndpointID: irohPeerEndpointID,
            pairingAttemptID: attemptID
        )
    }

    private func provisionalResponse(
        for pending: RemotePendingPairing,
        desktop: RemoteDesktopSummary
    ) -> RemoteIrohPairingResponse {
        RemoteIrohPairingResponse(
            pairingResponse: pairingResponse(for: pending.credential, desktop: desktop),
            serverEndpointID: pending.serverEndpointID,
            clientEndpointID: pending.credential.irohPeerEndpointID,
            attemptID: pending.attemptID
        )
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
