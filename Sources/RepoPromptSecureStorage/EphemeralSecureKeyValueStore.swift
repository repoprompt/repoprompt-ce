import Foundation

/// Process-local secure storage used whenever runtime signing cannot select a persistent domain.
final class EphemeralSecureKeyValueStore: SecureKeyValueStorageBackend, @unchecked Sendable {
    static let shared = EphemeralSecureKeyValueStore()

    let persistsValuesAcrossLaunches = false

    private var entries: [String: Data] = [:]
    private let lock = NSRecursiveLock()

    init() {}

    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainService.KeychainError.invalidData
        }

        withLock {
            entries[key] = data
        }
    }

    func get(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws -> String {
        let data = try withLock {
            guard let data = entries[key] else {
                throw KeychainService.KeychainError.itemNotFound
            }
            return data
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainService.KeychainError.invalidData
        }
        return value
    }

    func delete(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        _ = withLock {
            entries.removeValue(forKey: key)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
