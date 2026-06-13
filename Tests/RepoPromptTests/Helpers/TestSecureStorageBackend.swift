import Foundation
@testable import RepoPrompt

final class TestSecureStorageBackend: SecureKeyValueStorageBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case get
        case save
        case delete
    }

    struct Call: Equatable {
        let operation: Operation
        let account: SecureStorageAccount
        let accessMode: KeychainAccessMode
    }

    let persistsValuesAcrossLaunches = true
    var getErrors: [SecureStorageAccount: KeychainService.KeychainError] = [:]
    var saveErrors: [SecureStorageAccount: KeychainService.KeychainError] = [:]
    var deleteErrors: [SecureStorageAccount: KeychainService.KeychainError] = [:]
    var savedValueOverride: String?

    private var values: [String: String]
    private(set) var calls: [Call] = []
    private let lock = NSRecursiveLock()

    init(values: [SecureStorageAccount: String] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.identifier, $0.value) })
    }

    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            let account = try account(for: key)
            calls.append(Call(operation: .save, account: account, accessMode: accessMode))
            if let error = saveErrors[account] { throw error }
            values[key] = savedValueOverride ?? value
        }
    }

    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        try withLock {
            let account = try account(for: key)
            calls.append(Call(operation: .get, account: account, accessMode: accessMode))
            if let error = getErrors[account] { throw error }
            guard let value = values[key] else { throw KeychainService.KeychainError.itemNotFound }
            return value
        }
    }

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            let account = try account(for: key)
            calls.append(Call(operation: .delete, account: account, accessMode: accessMode))
            if let error = deleteErrors[account] { throw error }
            values.removeValue(forKey: key)
        }
    }

    func value(for account: SecureStorageAccount) -> String? {
        withLock { values[account.identifier] }
    }

    private func account(for key: String) throws -> SecureStorageAccount {
        guard let account = SecureStorageAccountCatalog.allAccounts.first(where: { $0.identifier == key }) else {
            throw KeychainService.KeychainError.itemNotFound
        }
        return account
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
