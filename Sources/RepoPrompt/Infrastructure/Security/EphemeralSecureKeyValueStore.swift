#if DEBUG
    import Foundation

    /// Debug-build-only in-memory secure storage used when local app signing cannot safely use Keychain.
    final class EphemeralSecureKeyValueStore: SecureKeyValueStorageBackend {
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
                throw SecureStorageError.invalidData
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
                    throw SecureStorageError.itemNotFound
                }
                return data
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw SecureStorageError.invalidData
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
#endif
