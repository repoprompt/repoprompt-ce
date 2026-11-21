import CryptoKit
import Foundation

public enum RemoteNotificationCryptoError: Error, Sendable, Equatable {
    case invalidCredential
    case invalidEnvelope
    case invalidPayload
    case categoryMismatch
    case desktopMismatch
    case deviceMismatch
    case unsupportedVersion
}

public enum RemoteNotificationCrypto {
    private static let derivationSalt = Data("RepoPromptRemoteNotification-v1".utf8)
    private static let derivationInfo = Data("paired-device-notification".utf8)

    public static func seal(
        _ payload: RemoteNotificationPayload,
        credential: String,
        desktopInstanceID: String,
        deviceID: String,
        envelopeID: UUID = UUID()
    ) throws -> RemoteNotificationEnvelope {
        let key = try key(for: credential)
        let plaintext = try JSONEncoder.remote.encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw RemoteNotificationCryptoError.invalidEnvelope }
        let nonceLength = sealed.nonce.withUnsafeBytes { $0.count }
        let nonce = combined.prefix(nonceLength)
        let ciphertext = combined.dropFirst(nonceLength).dropLast(sealed.tag.count)
        return RemoteNotificationEnvelope(
            envelopeID: envelopeID,
            desktopInstanceID: desktopInstanceID,
            deviceID: deviceID,
            category: payload.category,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            nonce: nonce.base64EncodedString(),
            ciphertext: Data(ciphertext).base64EncodedString(),
            authenticationTag: sealed.tag.base64EncodedString()
        )
    }

    public static func open(
        _ envelope: RemoteNotificationEnvelope,
        credential: String,
        expectedDesktopInstanceID: String? = nil,
        expectedDeviceID: String? = nil
    ) throws -> RemoteNotificationPayload {
        guard envelope.version == 1 else { throw RemoteNotificationCryptoError.unsupportedVersion }
        if let expectedDesktopInstanceID, expectedDesktopInstanceID != envelope.desktopInstanceID {
            throw RemoteNotificationCryptoError.desktopMismatch
        }
        if let expectedDeviceID, expectedDeviceID != envelope.deviceID {
            throw RemoteNotificationCryptoError.deviceMismatch
        }
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.authenticationTag)
        else { throw RemoteNotificationCryptoError.invalidEnvelope }
        let key = try key(for: credential)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        guard let payload = try? JSONDecoder.remote.decode(RemoteNotificationPayload.self, from: AES.GCM.open(sealed, using: key)) else {
            throw RemoteNotificationCryptoError.invalidPayload
        }
        guard payload.category == envelope.category,
              payload.sessionID == envelope.sessionID,
              payload.desktopInstanceID == envelope.desktopInstanceID
        else { throw RemoteNotificationCryptoError.categoryMismatch }
        return payload
    }

    private static func key(for credential: String) throws -> SymmetricKey {
        guard !credential.isEmpty else { throw RemoteNotificationCryptoError.invalidCredential }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(credential.utf8)),
            salt: derivationSalt,
            info: derivationInfo,
            outputByteCount: 32
        )
    }
}

private extension JSONEncoder {
    static var remote: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var remote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
