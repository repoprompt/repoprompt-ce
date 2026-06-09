import Foundation

package protocol SecurePlainStringStoring {
    var persistsValuesAcrossLaunches: Bool { get }

    func getPlainValue(for key: String, accessMode: SecureStorageAccessMode) throws -> String?
    func savePlainValue(_ value: String, for key: String, accessMode: SecureStorageAccessMode) throws
    func deletePlainValue(for key: String, accessMode: SecureStorageAccessMode) throws
}

package extension SecurePlainStringStoring {
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
package final class SecureKeysService {
    private let secureStorage: SecureKeyValueStorageBackend

    package init(secureStorage: any SecureKeyValueStorageBackend) {
        self.secureStorage = secureStorage
    }

    package func saveAPIKey(
        _ key: String,
        for identifier: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try secureStorage.save(key, for: identifier, accessMode: accessMode)
    }

    package func getAPIKey(
        for identifier: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) async throws -> String? {
        do {
            return try secureStorage.get(for: identifier, accessMode: accessMode)
        } catch SecureStorageError.itemNotFound {
            return nil
        }
    }

    package func deleteAPIKey(
        for identifier: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: identifier, accessMode: accessMode)
    }

    package func savePlainValue(
        _ value: String,
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try secureStorage.save(value, for: key, accessMode: accessMode)
    }

    package func getPlainValue(
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws -> String? {
        do {
            return try secureStorage.get(for: key, accessMode: accessMode)
        } catch SecureStorageError.itemNotFound {
            return nil
        }
    }

    package func deletePlainValue(
        for key: String,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try secureStorage.delete(for: key, accessMode: accessMode)
    }
}

extension SecureKeysService: SecurePlainStringStoring {
    package var persistsValuesAcrossLaunches: Bool {
        secureStorage.persistsValuesAcrossLaunches
    }
}
