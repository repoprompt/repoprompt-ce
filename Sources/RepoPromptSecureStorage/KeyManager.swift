import Foundation

package actor SecureStorageKeyManager<Provider: Hashable & Sendable> {
    private let secureService: SecureKeysService
    private let accountForProvider: @Sendable (Provider) -> SecureStorageAccount?

    /// Simple in-memory store of keys
    private var cache = [Provider: String]()

    package init(
        secureService: SecureKeysService = SecureKeysService(),
        accountForProvider: @escaping @Sendable (Provider) -> SecureStorageAccount?
    ) {
        self.secureService = secureService
        self.accountForProvider = accountForProvider
    }

    /// Lazily loads the key from disk only if not already in the `cache`.
    package func getAPIKey(
        for provider: Provider,
        accessMode: KeychainAccessMode = .interactive
    ) async throws -> String? {
        if let cached = cache[provider] {
            return cached
        }

        guard let account = accountForProvider(provider) else { return nil }
        let keyFromDisk = try await secureService.getAPIKey(for: account, accessMode: accessMode)

        if let k = keyFromDisk {
            cache[provider] = k
        }

        return keyFromDisk
    }

    /// Saves to both in-memory cache and disk.
    package func saveAPIKey(
        _ key: String,
        for provider: Provider,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        guard let account = accountForProvider(provider) else { return }
        cache[provider] = key
        try secureService.saveAPIKey(key, for: account, accessMode: accessMode)
    }

    /// Deletes from both in-memory cache and disk.
    package func deleteAPIKey(
        for provider: Provider,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        cache.removeValue(forKey: provider)
        guard let account = accountForProvider(provider) else { return }
        try secureService.deleteAPIKey(for: account, accessMode: accessMode)
    }
}
