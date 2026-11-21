import CryptoKit
import Darwin
import Foundation
import RepoPromptRemoteProtocol
import RepoPromptSecureStorage
import Security

enum RemoteGatewaySecurityError: LocalizedError {
    case keychainFailure(OSStatus)
    case certificateUnavailable
    case identityGenerationFailed(String)
    case identityImportFailed(OSStatus)
    case pairingSecretInvalid
    case pairingSecretExpired
    case endpointBindingInvalid
    case unsupportedProtocol(Int)
    case deviceCredentialUnavailable

    var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            "Remote credential storage failed (Keychain status \(status))."
        case .certificateUnavailable:
            "The Remote TLS certificate is unavailable."
        case let .identityGenerationFailed(message):
            "The Remote TLS identity could not be generated: \(message)"
        case let .identityImportFailed(status):
            "The Remote TLS identity could not be imported (status \(status))."
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
    private static let legacyAccount = "remote"
    private static let revoked = "revoked"
    private static let accessMode = KeychainAccessMode.nonInteractive(reason: .backgroundAvailabilityCheck)

    static let shared = Self(
        backend: SecureKeyValueStorageFactory.defaultBackend(),
        readLegacy: Self.readLegacyItem
    )

    let backend: any SecureKeyValueStorageBackend
    let readLegacy: @Sendable (String) throws -> Data?

    func read(_ account: SecureStorageAccount) throws -> Data? {
        let service = account.identifier
        do {
            return try readCurrent(service: service)
        } catch KeychainService.KeychainError.itemNotFound {
            guard backend.persistsValuesAcrossLaunches,
                  let legacy = try readLegacy(service) else { return nil }
            do {
                try backend.create(legacy.base64EncodedString(), for: service, accessMode: Self.accessMode)
                return legacy
            } catch KeychainService.KeychainError.duplicateItem {
                // A concurrent update or revocation wins over an older record.
                return try readCurrent(service: service)
            }
        }
    }

    func write(_ data: Data, for account: SecureStorageAccount) throws {
        try backend.save(data.base64EncodedString(), for: account.identifier, accessMode: Self.accessMode)
    }

    func remove(_ account: SecureStorageAccount) throws {
        // Keep a durable tombstone so the app can never reimport an old credential
        // after unpairing, including when the current signer cannot delete the old item.
        try backend.save(Self.revoked, for: account.identifier, accessMode: Self.accessMode)
    }

    private func readCurrent(service: String) throws -> Data? {
        let value = try backend.get(for: service, accessMode: Self.accessMode)
        guard value != Self.revoked else { return nil }
        guard let data = Data(base64Encoded: value) else {
            throw KeychainService.KeychainError.invalidData
        }
        return data
    }

    private static func readLegacyItem(service: String) throws -> Data? {
        // File-based storage from builds before signing identities were isolated.
        // A stale ACL must not display an authorization dialog at gateway startup.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainService.KeychainError.invalidData }
            return data
        case errSecItemNotFound, errSecInteractionNotAllowed:
            return nil
        default:
            throw RemoteGatewaySecurityError.keychainFailure(status)
        }
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

struct RemoteTLSIdentity {
    let identity: SecIdentity
    let certificateSHA256: String
    var wasCreated: Bool
}

/// Owns the self-signed identity used by the opt-in LAN gateway. The PKCS#12
/// blob is kept in Keychain; the private key is never checked into the source
/// tree or left in the temporary generation directory.
final class RemoteTLSIdentityStore {
    private let importPassphrase = "RepoPromptRemoteIdentity"

    func loadOrCreate() throws -> RemoteTLSIdentity {
        if let stored = try RemoteGatewayKeychain.shared.read(.remoteTLSIdentity) {
            var identity = try importIdentity(from: stored)
            identity.wasCreated = false
            return identity
        }

        if let legacy = try RemoteGatewayKeychain.shared.read(.remoteLegacyTLSIdentity),
           var identity = try? importIdentity(from: legacy)
        {
            try RemoteGatewayKeychain.shared.write(legacy, for: .remoteTLSIdentity)
            try? RemoteGatewayKeychain.shared.remove(.remoteLegacyTLSIdentity)
            identity.wasCreated = false
            return identity
        }

        let bundle = try generatePKCS12Bundle()
        try RemoteGatewayKeychain.shared.write(bundle, for: .remoteTLSIdentity)
        var identity = try importIdentity(from: bundle)
        identity.wasCreated = true
        return identity
    }

    private func importIdentity(from data: Data) throws -> RemoteTLSIdentity {
        var imported: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: importPassphrase]
        if #available(macOS 15, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess,
              let entries = imported as? [[String: Any]],
              let first = entries.first,
              let identityValue = first[kSecImportItemIdentity as String]
        else {
            throw RemoteGatewaySecurityError.identityImportFailed(status)
        }
        guard CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw RemoteGatewaySecurityError.identityImportFailed(status)
        }
        let identity = identityValue as! SecIdentity

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let certificateData = SecCertificateCopyData(certificate) as Data?
        else {
            throw RemoteGatewaySecurityError.certificateUnavailable
        }

        let digest = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        return RemoteTLSIdentity(identity: identity, certificateSHA256: digest, wasCreated: false)
    }

    private func generatePKCS12Bundle() throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoprompt-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyURL = directory.appendingPathComponent("key.pem")
        let certificateURL = directory.appendingPathComponent("certificate.pem")
        let bundleURL = directory.appendingPathComponent("identity.p12")

        try runOpenSSL(arguments: [
            "req", "-x509", "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyURL.path,
            "-out", certificateURL.path,
            "-days", "3650",
            "-subj", "/CN=RepoPrompt Remote"
        ])
        try runOpenSSL(arguments: [
            "pkcs12", "-export",
            "-out", bundleURL.path,
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-passout", "pass:\(importPassphrase)"
        ])
        do {
            return try Data(contentsOf: bundleURL)
        } catch {
            throw RemoteGatewaySecurityError.identityGenerationFailed(error.localizedDescription)
        }
    }

    private func runOpenSSL(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RemoteGatewaySecurityError.identityGenerationFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteGatewaySecurityError.identityGenerationFailed(
                diagnostic?.isEmpty == false ? diagnostic! : "openssl exited with status \(process.terminationStatus)"
            )
        }
    }
}

struct RemoteStoredDeviceCredential: Codable, Equatable {
    let deviceID: String
    let credential: String
    let expiresAt: Date
    let deviceName: String
    let irohPeerEndpointID: String?

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case credential
        case expiresAt
        case deviceName
        case irohPeerEndpointID
    }

    init(
        deviceID: String,
        credential: String,
        expiresAt: Date,
        deviceName: String,
        irohPeerEndpointID: String? = nil
    ) {
        self.deviceID = deviceID
        self.credential = credential
        self.expiresAt = expiresAt
        self.deviceName = deviceName
        self.irohPeerEndpointID = irohPeerEndpointID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        credential = try container.decode(String.self, forKey: .credential)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "Remote device"
        irohPeerEndpointID = try container.decodeIfPresent(String.self, forKey: .irohPeerEndpointID)
    }
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

struct RemoteIssuedPairingAdvertisements {
    let legacy: RemotePairingAdvertisement
    let iroh: RemoteIrohPairingAdvertisement
}

/// Enforces the first-release one-device pairing rule. Pairing material stays
/// in memory until used or manually replaced; the issued bearer credential is
/// Keychain-backed.
@MainActor
final class RemotePairingManager {
    static let pairingLifetime: TimeInterval = 5 * 60
    static let credentialLifetime: TimeInterval = 60 * 60 * 24 * 30
    static let maximumDeviceNameCharacters = 128

    let desktopInstanceID: String
    private(set) var certificateSHA256: String
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
        certificateSHA256: String = "",
        storedDevice: RemoteStoredDeviceCredential? = nil,
        notificationRegistration: RemoteNotificationRegistration? = nil,
        now: @escaping () -> Date,
        randomBytes: @escaping (Int) throws -> Data,
        persistStoredDevice: @escaping (RemoteStoredDeviceCredential?) throws -> Void
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.certificateSHA256 = certificateSHA256
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

    func setCertificateSHA256(_ fingerprint: String) {
        certificateSHA256 = fingerprint
    }

    func issueAdvertisement(
        port: UInt16,
        serviceName: String,
        host: String?
    ) throws -> RemotePairingAdvertisement {
        let pending = try createPendingSecret()
        return makeLegacyAdvertisement(
            pending: pending,
            port: port,
            serviceName: serviceName,
            host: host
        )
    }

    func issuePairingAdvertisements(
        port: UInt16,
        serviceName: String,
        host: String?,
        server: RemoteIrohEndpointAddress
    ) throws -> RemoteIssuedPairingAdvertisements {
        let pending = try createPendingSecret()
        let legacy = makeLegacyAdvertisement(
            pending: pending,
            port: port,
            serviceName: serviceName,
            host: host
        )
        let iroh = RemoteIrohPairingAdvertisement(
            desktopInstanceID: desktopInstanceID,
            server: server,
            oneTimeSecret: pending.value,
            expiresAt: pending.expiresAt,
            legacyFallback: legacy
        )
        return RemoteIssuedPairingAdvertisements(legacy: legacy, iroh: iroh)
    }

    func pair(
        request: RemotePairingRequest,
        desktop: RemoteDesktopSummary
    ) throws -> RemotePairingResponse {
        try validateProtocolAndDesktop(
            protocolVersion: request.protocolVersion,
            requestedDesktopInstanceID: request.desktopInstanceID
        )
        guard !certificateSHA256.isEmpty else {
            throw RemoteGatewaySecurityError.certificateUnavailable
        }
        try consumePendingSecret(request.oneTimeSecret)
        let credential = try createAndPersistCredential(
            deviceName: request.deviceName,
            irohPeerEndpointID: nil
        )
        return pairingResponse(for: credential, desktop: desktop)
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
        guard !certificateSHA256.isEmpty else {
            throw RemoteGatewaySecurityError.certificateUnavailable
        }
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

    func bindIrohEndpoint(
        request: RemoteIrohBindingRequest,
        authorizationHeader: String?,
        serverEndpointID: String
    ) throws -> RemoteIrohBindingResponse {
        try validateProtocolAndDesktop(
            protocolVersion: request.protocolVersion,
            requestedDesktopInstanceID: request.desktopInstanceID
        )
        guard let storedDevice,
              RemoteCredentialAuthority.accepts(
                  authorizationHeader: authorizationHeader,
                  credential: storedDevice,
                  at: now()
              ),
              request.deviceID == storedDevice.deviceID,
              request.expectedServerEndpointID == serverEndpointID,
              Self.isCanonicalEndpointID(request.clientEndpointID),
              Self.isCanonicalEndpointID(serverEndpointID)
        else {
            throw RemoteGatewaySecurityError.endpointBindingInvalid
        }

        let updated = RemoteStoredDeviceCredential(
            deviceID: storedDevice.deviceID,
            credential: storedDevice.credential,
            expiresAt: storedDevice.expiresAt,
            deviceName: storedDevice.deviceName,
            irohPeerEndpointID: request.clientEndpointID
        )
        try persistStoredDevice(updated)
        self.storedDevice = updated
        return RemoteIrohBindingResponse(
            desktopInstanceID: desktopInstanceID,
            deviceID: updated.deviceID,
            serverEndpointID: serverEndpointID,
            clientEndpointID: request.clientEndpointID
        )
    }

    func isAuthorized(_ authorizationHeader: String?) -> Bool {
        RemoteCredentialAuthority.accepts(
            authorizationHeader: authorizationHeader,
            credential: storedDevice,
            at: now()
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

    func clearIrohPeerBinding() throws {
        guard let storedDevice, storedDevice.irohPeerEndpointID != nil else { return }
        let updated = RemoteStoredDeviceCredential(
            deviceID: storedDevice.deviceID,
            credential: storedDevice.credential,
            expiresAt: storedDevice.expiresAt,
            deviceName: storedDevice.deviceName
        )
        try persistStoredDevice(updated)
        self.storedDevice = updated
    }

    func revokeDevice() throws {
        // Durable credential deletion must succeed before the in-memory paired
        // state changes, otherwise a restart could resurrect a revoked phone.
        try persistStoredDevice(nil)
        pendingSecret = nil
        storedDevice = nil
        notificationRegistration = nil
        // The bearer deletion above is the authoritative revocation. Ancillary
        // notification cleanup must not turn a successful unpair into HTTP 500.
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

    private func makeLegacyAdvertisement(
        pending: RemotePendingPairingSecret,
        port: UInt16,
        serviceName: String,
        host: String?
    ) -> RemotePairingAdvertisement {
        RemotePairingAdvertisement(
            desktopInstanceID: desktopInstanceID,
            serviceName: serviceName,
            host: host,
            port: Int(port),
            certificateSHA256: certificateSHA256,
            oneTimeSecret: pending.value,
            expiresAt: pending.expiresAt
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
        irohPeerEndpointID: String?
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

enum RemoteLocalAddress {
    static func preferredIPv4Address() -> String? {
        var address: String?
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0 else { return nil }
        defer { freeifaddrs(interfacePointer) }
        var current = interfacePointer
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let name = interface.ifa_name,
                  String(cString: name) != "lo0"
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var sockaddr = addressPointer.pointee
            let status = getnameinfo(
                &sockaddr,
                socklen_t(addressPointer.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }
}
