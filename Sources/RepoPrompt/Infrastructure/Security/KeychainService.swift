//
//  KeychainService.swift
//  RepoPrompt
//
//  Secure Keychain-based storage for sensitive data
//

import Foundation
import Security

/// Controls whether a Keychain operation may display macOS authentication/approval UI.
enum KeychainAccessMode: Equatable {
    case interactive
    case nonInteractive(reason: KeychainAccessReason)

    var isNonInteractive: Bool {
        if case .nonInteractive = self {
            return true
        }
        return false
    }
}

/// Sanitized reason metadata for noninteractive Keychain access.
enum KeychainAccessReason: Equatable {
    case launch
    case bulkSettingsLoad
    case permissionDecision
    case backgroundAvailabilityCheck
    case test
}

protocol SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemSecItemClient: SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

/// Secure storage service for one explicitly selected CE macOS Keychain domain.
final class KeychainService: SecureKeyValueStorageBackend, @unchecked Sendable {
    static let legacyCanonicalServiceName = "com.pvncher.repoprompt.ce.keychain"
    static let officialV2ServiceName = "com.pvncher.repoprompt.ce.developer-id.keychain.v2"
    static let localSelfSignedServiceNamePrefix = "com.pvncher.repoprompt.ce.local-self-signed."
    static let debugServiceName = "com.pvncher.repoprompt.ce.debug.keychain"

    static let officialV2Shared = KeychainService(serviceName: officialV2ServiceName)
    static let debugShared = KeychainService(serviceName: debugServiceName)

    static func localSelfSignedServiceName(fingerprint: String, generation: Int) -> String {
        let normalizedFingerprint = fingerprint.filter(\.isHexDigit).lowercased()
        precondition(normalizedFingerprint.count == 64, "Local certificate fingerprint must be SHA-256")
        precondition(generation > 0, "Local secure-storage generation must be positive")
        return "\(localSelfSignedServiceNamePrefix)\(normalizedFingerprint).keychain.v\(generation)"
    }

    static func localSelfSigned(fingerprint: String, generation: Int) -> KeychainService {
        KeychainService(serviceName: localSelfSignedServiceName(fingerprint: fingerprint, generation: generation))
    }

    static func legacyRepairSource(secItemClient: SecItemClient = SystemSecItemClient()) -> KeychainService {
        KeychainService(serviceName: legacyCanonicalServiceName, secItemClient: secItemClient)
    }

    let serviceName: String
    private let secItemClient: SecItemClient
    private let operationLock = NSRecursiveLock()

    let persistsValuesAcrossLaunches = true

    init(
        serviceName: String = KeychainService.officialV2ServiceName,
        secItemClient: SecItemClient = SystemSecItemClient()
    ) {
        self.serviceName = serviceName
        self.secItemClient = secItemClient
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func query(_ values: [String: Any], accessMode: KeychainAccessMode) -> [String: Any] {
        guard accessMode.isNonInteractive else {
            return values
        }

        var query = values
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        return query
    }

    private func keychainError(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecDuplicateItem:
            .duplicateItem
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecUserCanceled:
            .userInteractionCancelled
        case errSecAuthFailed:
            .authenticationFailed
        default:
            .unexpectedStatus(status)
        }
    }

    enum KeychainError: Error, LocalizedError, Equatable {
        case itemNotFound
        case duplicateItem
        case invalidData
        case interactionNotAllowed
        case userInteractionCancelled
        case authenticationFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                "Item not found in keychain"
            case .duplicateItem:
                "Item already exists"
            case .invalidData:
                "Invalid data format"
            case .interactionNotAllowed:
                "Keychain interaction is not allowed in the current access mode"
            case .userInteractionCancelled:
                "Keychain interaction was cancelled"
            case .authenticationFailed:
                "Keychain authentication failed"
            case let .unexpectedStatus(status):
                "Keychain error: \(status)"
            }
        }
    }

    // MARK: - Save to Keychain

    /// Save a UTF-8 string to this service only.
    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }

            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = secItemClient.update(itemQuery as CFDictionary, attributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                break
            default:
                throw keychainError(for: updateStatus)
            }

            let addQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: false
            ], accessMode: accessMode)

            let addStatus = secItemClient.add(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(for: addStatus)
            }
        }
    }

    // MARK: - Retrieve from Keychain

    /// Retrieve a UTF-8 string from this service only.
    func get(
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> String {
        let data = try withLock {
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ], accessMode: accessMode)

            var result: AnyObject?
            let status = secItemClient.copyMatching(itemQuery as CFDictionary, &result)

            guard status == errSecSuccess else {
                throw keychainError(for: status)
            }

            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            return data
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    // MARK: - Delete from Keychain

    /// Delete an item from this service only.
    func delete(for key: String, accessMode: KeychainAccessMode = .interactive) throws {
        try withLock {
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let status = secItemClient.delete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(for: status)
            }
        }
    }
}
