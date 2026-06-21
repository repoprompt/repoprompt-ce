import Foundation

package enum SecureStorageAccessMode: Equatable {
    case interactive
    case nonInteractive(reason: SecureStorageAccessReason)

    package var isNonInteractive: Bool {
        if case .nonInteractive = self { return true }
        return false
    }
}

package enum SecureStorageAccessReason: Equatable {
    case launch
    case bulkSettingsLoad
    case permissionDecision
    case backgroundAvailabilityCheck
    case test
}

package enum SecureStorageError: Error, LocalizedError, Equatable {
    case itemNotFound
    case duplicateItem
    case invalidData
    case interactionNotAllowed
    case userInteractionCancelled
    case authenticationFailed
    case unexpectedStatus(Int32)

    package var errorDescription: String? {
        switch self {
        case .itemNotFound: "Item not found in secure storage"
        case .duplicateItem: "Item already exists"
        case .invalidData: "Invalid data format"
        case .interactionNotAllowed: "Secure-storage interaction is not allowed in the current access mode"
        case .userInteractionCancelled: "Secure-storage interaction was cancelled"
        case .authenticationFailed: "Secure-storage authentication failed"
        case let .unexpectedStatus(status): "Secure-storage error: \(status)"
        }
    }
}

package protocol SecureKeyValueStorageBackend: AnyObject, Sendable {
    var persistsValuesAcrossLaunches: Bool { get }
    func save(_ value: String, for key: String, accessMode: SecureStorageAccessMode) throws
    func get(for key: String, accessMode: SecureStorageAccessMode) throws -> String
    func delete(for key: String, accessMode: SecureStorageAccessMode) throws
}
