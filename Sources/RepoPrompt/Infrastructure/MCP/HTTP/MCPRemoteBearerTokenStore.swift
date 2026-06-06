import CryptoKit
import Foundation
import Security

struct MCPRemoteBearerTokenStore {
    static let primaryTokenStorageKey = "com.pvncher.repoprompt.ce.networkMCP.primaryBearerToken"
    static let defaultTokenLabel = "Network MCP token"

    private let secureStrings: SecurePlainStringStoring
    private let now: () -> Date
    private let idGenerator: () -> UUID
    private let randomBytes: (Int) throws -> [UInt8]

    init(
        secureStrings: SecurePlainStringStoring = SecureKeysService(),
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init,
        randomBytes: @escaping (Int) throws -> [UInt8] = Self.secureRandomBytes(count:)
    ) {
        self.secureStrings = secureStrings
        self.now = now
        self.idGenerator = idGenerator
        self.randomBytes = randomBytes
    }

    @discardableResult
    func generateAndSavePrimaryToken(
        label: String? = nil,
        byteCount: Int = 32,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> (token: String, metadata: NetworkMCPBearerTokenMetadata) {
        let token = try Self.base64URLToken(from: randomBytes(byteCount))
        let metadata = try savePrimaryToken(token, label: label, accessMode: accessMode)
        return (token, metadata)
    }

    @discardableResult
    func savePrimaryToken(
        _ token: String,
        label: String? = nil,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> NetworkMCPBearerTokenMetadata {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MCPRemoteBearerTokenStoreError.emptyToken
        }

        try secureStrings.savePlainValue(normalized, for: Self.primaryTokenStorageKey, accessMode: accessMode)
        let timestamp = now()
        return NetworkMCPBearerTokenMetadata(
            id: idGenerator(),
            label: normalizedLabel(label),
            fingerprint: Self.fingerprint(for: normalized),
            createdAt: timestamp,
            rotatedAt: timestamp,
            secureStoragePersistsAcrossLaunches: secureStrings.persistsValuesAcrossLaunches
        )
    }

    func loadPrimaryToken(
        accessMode: KeychainAccessMode = .nonInteractive(reason: .networkMCPAuthentication)
    ) throws -> String? {
        let token = try secureStrings.getPlainValue(for: Self.primaryTokenStorageKey, accessMode: accessMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    func hasPrimaryToken(
        accessMode: KeychainAccessMode = .nonInteractive(reason: .networkMCPAuthentication)
    ) throws -> Bool {
        try loadPrimaryToken(accessMode: accessMode) != nil
    }

    func deletePrimaryToken(accessMode: KeychainAccessMode = .interactive) throws {
        try secureStrings.deletePlainValue(for: Self.primaryTokenStorageKey, accessMode: accessMode)
    }

    func authenticate(
        authorizationHeader: String?,
        accessMode: KeychainAccessMode = .nonInteractive(reason: .networkMCPAuthentication)
    ) -> MCPRemoteBearerAuthenticationResult {
        guard let authorizationHeader else {
            return .rejected(.missingAuthorizationHeader)
        }

        let trimmedHeader = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeader.isEmpty else {
            return .rejected(.missingAuthorizationHeader)
        }

        let schemeEnd = trimmedHeader.firstIndex { $0 == " " || $0 == "\t" }
        let scheme = schemeEnd.map { String(trimmedHeader[..<$0]) } ?? trimmedHeader
        guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else {
            return .rejected(.unsupportedAuthorizationScheme)
        }
        guard let schemeEnd else {
            return .rejected(.emptyBearerToken)
        }

        let presentedToken = String(trimmedHeader[schemeEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !presentedToken.isEmpty else {
            return .rejected(.emptyBearerToken)
        }

        let storedToken: String
        do {
            guard let loaded = try loadPrimaryToken(accessMode: accessMode) else {
                return .rejected(.tokenUnavailable)
            }
            storedToken = loaded
        } catch {
            return .rejected(.secureStorageUnavailable)
        }

        guard Self.constantTimeEquals(presentedToken, storedToken) else {
            return .rejected(.invalidBearerToken)
        }

        return .authenticated(fingerprint: Self.fingerprint(for: storedToken))
    }

    static func fingerprint(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(String(hex.prefix(16)))"
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0 ..< maxCount {
            let lhsValue = index < lhsBytes.count ? Int(lhsBytes[index]) : 0
            let rhsValue = index < rhsBytes.count ? Int(rhsBytes[index]) : 0
            difference |= lhsValue ^ rhsValue
        }

        return difference == 0
    }

    private func normalizedLabel(_ label: String?) -> String {
        guard let label else { return Self.defaultTokenLabel }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultTokenLabel : trimmed
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        guard count > 0 else { throw MCPRemoteBearerTokenStoreError.invalidByteCount(count) }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPRemoteBearerTokenStoreError.tokenGenerationFailed(status)
        }
        return bytes
    }

    private static func base64URLToken(from bytes: [UInt8]) throws -> String {
        guard !bytes.isEmpty else { throw MCPRemoteBearerTokenStoreError.invalidByteCount(bytes.count) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MCPRemoteBearerTokenStoreError: Error, Equatable {
    case emptyToken
    case invalidByteCount(Int)
    case tokenGenerationFailed(OSStatus)
}

enum MCPRemoteBearerAuthenticationResult: Equatable {
    case authenticated(fingerprint: String)
    case rejected(MCPRemoteBearerAuthenticationFailure)
}

enum MCPRemoteBearerAuthenticationFailure: Equatable {
    case missingAuthorizationHeader
    case unsupportedAuthorizationScheme
    case emptyBearerToken
    case invalidBearerToken
    case tokenUnavailable
    case secureStorageUnavailable

    var httpStatusCode: Int {
        switch self {
        case .missingAuthorizationHeader, .unsupportedAuthorizationScheme, .emptyBearerToken, .invalidBearerToken:
            401
        case .tokenUnavailable, .secureStorageUnavailable:
            503
        }
    }

    var mcpErrorCode: Int {
        switch self {
        case .missingAuthorizationHeader, .unsupportedAuthorizationScheme, .emptyBearerToken, .invalidBearerToken:
            -32001
        case .tokenUnavailable, .secureStorageUnavailable:
            -32003
        }
    }
}
