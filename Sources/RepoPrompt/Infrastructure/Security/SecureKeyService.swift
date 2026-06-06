import Foundation

protocol SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool { get }

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String?
    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws
    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws
}

extension SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool {
        true
    }

    func getPlainValue(for account: SecureStorageAccount) throws -> String? {
        try getPlainValue(for: account, accessMode: .interactive)
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount) throws {
        try savePlainValue(value, for: account, accessMode: .interactive)
    }

    func deletePlainValue(for account: SecureStorageAccount) throws {
        try deletePlainValue(for: account, accessMode: .interactive)
    }
}

/// Secure key storage service backed by canonical Keychain/plain UTF-8 values.
final class SecureKeysService {
    private let secureStorage: SecureKeyValueStorageBackend

    init(
        secureStorage: SecureKeyValueStorageBackend = SecureKeyValueStorageFactory.defaultBackend()
    ) {
        self.secureStorage = secureStorage
    }

    // MARK: - API Key Storage

    func saveAPIKey(
        _ key: String,
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.save(key, for: account.identifier, accessMode: accessMode)
    }

    func getAPIKey(
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) async throws -> String? {
        do {
            return try secureStorage.get(for: account.identifier, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
    }

    func deleteAPIKey(
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: account.identifier, accessMode: accessMode)
    }

    // MARK: - Plain String Storage

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.save(value, for: account.identifier, accessMode: accessMode)
    }

    func getPlainValue(
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> String? {
        do {
            return try secureStorage.get(for: account.identifier, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
    }

    func deletePlainValue(
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: account.identifier, accessMode: accessMode)
    }
}

extension SecureKeysService: SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool {
        secureStorage.persistsValuesAcrossLaunches
    }
}
