import Foundation

package enum SecureStorageRepairFailure: Equatable {
    case authenticationFailed
    case invalidData
    case keychainFailure
    case verificationFailed
    case confirmationRequired
}

package enum SecureStorageRepairState: Equatable {
    case absent
    case importable
    case interactionRequired
    case imported
    case conflict
    case cancelled
    case failed(SecureStorageRepairFailure)
}

package struct SecureStorageRepairRecord: Equatable, Identifiable {
    package let account: SecureStorageAccount
    package let state: SecureStorageRepairState
    package let targetVerified: Bool

    package var id: String {
        account.identifier
    }

    package var legacyDeletionAvailable: Bool {
        state == .imported && targetVerified
    }
}

package enum SecureStorageConflictResolution {
    case preserveTarget
    case replaceTarget
}

package actor SecureStorageRepairService {
    private let accounts: [SecureStorageAccount]
    private let legacyStore: SecureKeyValueStorageBackend
    private let targetStore: SecureKeyValueStorageBackend

    package init(
        accounts: [SecureStorageAccount] = SecureStorageAccountCatalog.allAccounts,
        legacyStore: SecureKeyValueStorageBackend,
        targetStore: SecureKeyValueStorageBackend
    ) {
        self.accounts = accounts
        self.legacyStore = legacyStore
        self.targetStore = targetStore
    }

    package static func makeForCurrentRuntime() -> SecureStorageRepairService? {
        makeForRuntime(
            decision: SecureKeyValueStorageFactory.currentDecision(),
            legacyStore: KeychainService.legacyRepairSource(),
            targetStore: SecureKeyValueStorageFactory.defaultBackend()
        )
    }

    static func makeForRuntime(
        decision: RuntimeSecureStorageDecision,
        legacyStore: SecureKeyValueStorageBackend,
        targetStore: SecureKeyValueStorageBackend
    ) -> SecureStorageRepairService? {
        guard decision.domain == .officialDeveloperID else { return nil }
        return SecureStorageRepairService(legacyStore: legacyStore, targetStore: targetStore)
    }

    package func scan() -> [SecureStorageRepairRecord] {
        accounts.map(scanAccount)
    }

    package func importAccount(
        _ account: SecureStorageAccount,
        resolution: SecureStorageConflictResolution = .preserveTarget
    ) -> SecureStorageRepairRecord {
        let legacyValue: String
        do {
            legacyValue = try legacyStore.get(for: account.identifier, accessMode: .interactive)
        } catch {
            return record(account, for: error)
        }

        do {
            let targetValue = try targetStore.get(for: account.identifier, accessMode: .interactive)
            if targetValue == legacyValue {
                return importedRecord(account)
            }
            guard resolution == .replaceTarget else {
                return SecureStorageRepairRecord(account: account, state: .conflict, targetVerified: false)
            }
        } catch KeychainService.KeychainError.itemNotFound {
            // The target will be created below.
        } catch {
            return record(account, for: error)
        }

        do {
            try targetStore.save(legacyValue, for: account.identifier, accessMode: .interactive)
            let verifiedValue = try targetStore.get(for: account.identifier, accessMode: .interactive)
            guard verifiedValue == legacyValue else {
                return failedRecord(account, .verificationFailed)
            }
            return importedRecord(account)
        } catch {
            return record(account, for: error)
        }
    }

    package func deleteLegacy(
        _ account: SecureStorageAccount,
        confirmed: Bool
    ) -> SecureStorageRepairRecord {
        guard confirmed else {
            return failedRecord(account, .confirmationRequired)
        }

        let legacyValue: String
        let targetValue: String
        do {
            legacyValue = try legacyStore.get(for: account.identifier, accessMode: .interactive)
            targetValue = try targetStore.get(for: account.identifier, accessMode: .interactive)
        } catch {
            return record(account, for: error)
        }

        guard legacyValue == targetValue else {
            return SecureStorageRepairRecord(account: account, state: .conflict, targetVerified: false)
        }

        do {
            try legacyStore.delete(for: account.identifier, accessMode: .interactive)
            do {
                _ = try legacyStore.get(for: account.identifier, accessMode: .interactive)
                return failedRecord(account, .verificationFailed)
            } catch KeychainService.KeychainError.itemNotFound {
                return SecureStorageRepairRecord(account: account, state: .absent, targetVerified: true)
            } catch {
                return record(account, for: error)
            }
        } catch {
            return record(account, for: error)
        }
    }

    private func scanAccount(_ account: SecureStorageAccount) -> SecureStorageRepairRecord {
        let accessMode = KeychainAccessMode.nonInteractive(reason: .backgroundAvailabilityCheck)
        let legacyValue: String
        do {
            legacyValue = try legacyStore.get(for: account.identifier, accessMode: accessMode)
        } catch {
            return record(account, for: error)
        }

        do {
            let targetValue = try targetStore.get(for: account.identifier, accessMode: accessMode)
            if targetValue == legacyValue {
                return importedRecord(account)
            }
            return SecureStorageRepairRecord(account: account, state: .conflict, targetVerified: false)
        } catch KeychainService.KeychainError.itemNotFound {
            return SecureStorageRepairRecord(account: account, state: .importable, targetVerified: false)
        } catch {
            return record(account, for: error)
        }
    }

    private func record(_ account: SecureStorageAccount, for error: Error) -> SecureStorageRepairRecord {
        let state: SecureStorageRepairState = switch error {
        case KeychainService.KeychainError.itemNotFound:
            .absent
        case KeychainService.KeychainError.interactionNotAllowed:
            .interactionRequired
        case KeychainService.KeychainError.userInteractionCancelled:
            .cancelled
        case KeychainService.KeychainError.authenticationFailed:
            .failed(.authenticationFailed)
        case KeychainService.KeychainError.invalidData:
            .failed(.invalidData)
        default:
            .failed(.keychainFailure)
        }
        return SecureStorageRepairRecord(account: account, state: state, targetVerified: false)
    }

    private func importedRecord(_ account: SecureStorageAccount) -> SecureStorageRepairRecord {
        SecureStorageRepairRecord(account: account, state: .imported, targetVerified: true)
    }

    private func failedRecord(
        _ account: SecureStorageAccount,
        _ failure: SecureStorageRepairFailure
    ) -> SecureStorageRepairRecord {
        SecureStorageRepairRecord(account: account, state: .failed(failure), targetVerified: false)
    }
}
