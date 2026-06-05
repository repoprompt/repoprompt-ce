import Foundation

protocol SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool { get }

    func getPlainValue(for key: String, accessMode: KeychainAccessMode) throws -> String?
    func savePlainValue(_ value: String, for key: String, accessMode: KeychainAccessMode) throws
    func deletePlainValue(for key: String, accessMode: KeychainAccessMode) throws
}

extension SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool {
        true
    }

    func getPlainValue(for key: String) throws -> String? {
        try getPlainValue(for: key, accessMode: .interactive)
    }

    func savePlainValue(_ value: String, for key: String) throws {
        try savePlainValue(value, for: key, accessMode: .interactive)
    }

    func deletePlainValue(for key: String) throws {
        try deletePlainValue(for: key, accessMode: .interactive)
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
        for identifier: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.save(key, for: identifier, accessMode: accessMode)
    }

    func getAPIKey(
        for identifier: String,
        accessMode: KeychainAccessMode = .interactive
    ) async throws -> String? {
        do {
            return try secureStorage.get(for: identifier, accessMode: accessMode)
        } catch SecureStorageError.itemNotFound {
            return nil
        }
    }

    func deleteAPIKey(
        for identifier: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: identifier, accessMode: accessMode)
    }

    // MARK: - Plain String Storage

    func savePlainValue(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.save(value, for: key, accessMode: accessMode)
    }

    func getPlainValue(
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> String? {
        do {
            return try secureStorage.get(for: key, accessMode: accessMode)
        } catch SecureStorageError.itemNotFound {
            return nil
        }
    }

    func deletePlainValue(
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: key, accessMode: accessMode)
    }
}

extension SecureKeysService: SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool {
        secureStorage.persistsValuesAcrossLaunches
    }
}
