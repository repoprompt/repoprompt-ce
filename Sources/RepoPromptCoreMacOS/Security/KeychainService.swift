//
//  KeychainService.swift
//  RepoPrompt
//
//  Secure Keychain-based storage for sensitive data
//

import Foundation
import RepoPromptCore
import Security

package protocol SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

package struct SystemSecItemClient: SecItemClient {
    package init() {}

    package func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    package func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    package func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    package func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

/// Secure storage service for one explicitly selected CE macOS Keychain domain.
package final class KeychainService: SecureKeyValueStorageBackend, @unchecked Sendable {
    package static let legacyCanonicalServiceName = "com.pvncher.repoprompt.ce.keychain"
    package static let officialV2ServiceName = "com.pvncher.repoprompt.ce.developer-id.keychain.v2"
    package static let localSelfSignedServiceNamePrefix = "com.pvncher.repoprompt.ce.local-self-signed."
    package static let debugServiceName = "com.pvncher.repoprompt.ce.debug.keychain"

    package static let officialV2Shared = KeychainService(serviceName: officialV2ServiceName)
    package static let debugShared = KeychainService(serviceName: debugServiceName)

    package static func localSelfSignedServiceName(fingerprint: String, generation: Int) -> String {
        let normalizedFingerprint = fingerprint.filter(\.isHexDigit).lowercased()
        precondition(normalizedFingerprint.count == 64, "Local certificate fingerprint must be SHA-256")
        precondition(generation > 0, "Local secure-storage generation must be positive")
        return "\(localSelfSignedServiceNamePrefix)\(normalizedFingerprint).keychain.v\(generation)"
    }

    package static func localSelfSigned(fingerprint: String, generation: Int) -> KeychainService {
        KeychainService(serviceName: localSelfSignedServiceName(fingerprint: fingerprint, generation: generation))
    }

    package static func legacyRepairSource(secItemClient: any SecItemClient = SystemSecItemClient()) -> KeychainService {
        KeychainService(serviceName: legacyCanonicalServiceName, secItemClient: secItemClient)
    }

    package let serviceName: String
    private let secItemClient: any SecItemClient
    private let operationLock = NSRecursiveLock()

    package let persistsValuesAcrossLaunches = true

    package init(
        serviceName: String = KeychainService.officialV2ServiceName,
        secItemClient: any SecItemClient = SystemSecItemClient()
    ) {
        self.serviceName = serviceName
        self.secItemClient = secItemClient
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func query(_ values: [String: Any], accessMode: SecureStorageAccessMode) -> [String: Any] {
        guard accessMode.isNonInteractive else {
            return values
        }

        var query = values
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        return query
    }

    private func keychainError(for status: OSStatus) -> SecureStorageError {
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

    /// Save a UTF-8 string to this service only.
    package func save(
        _ value: String,
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw SecureStorageError.invalidData
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

    /// Retrieve a UTF-8 string from this service only.
    package func get(
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
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
                throw SecureStorageError.invalidData
            }
            return data
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecureStorageError.invalidData
        }
        return value
    }

    /// Delete an item from this service only.
    package func delete(
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
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
