import Foundation
import RepoPromptCore
import RepoPromptCoreMacOS

typealias KeychainAccessMode = SecureStorageAccessMode

struct SecureKeyValueStorageSelection {
    let decision: RuntimeSecureStorageDecision
    let backend: SecureKeyValueStorageBackend
}

extension SecureKeysService {
    func saveAPIKey(
        _ key: String,
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try saveAPIKey(key, for: account.identifier, accessMode: accessMode)
    }

    func getAPIKey(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) async throws -> String? {
        try await getAPIKey(for: account.identifier, accessMode: accessMode)
    }

    func deleteAPIKey(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try deleteAPIKey(for: account.identifier, accessMode: accessMode)
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try savePlainValue(value, for: account.identifier, accessMode: accessMode)
    }

    func getPlainValue(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws -> String? {
        try getPlainValue(for: account.identifier, accessMode: accessMode)
    }

    func deletePlainValue(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try deletePlainValue(for: account.identifier, accessMode: accessMode)
    }
}

extension SecurePlainStringStoring {
    func getPlainValue(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws -> String? {
        try getPlainValue(for: account.identifier, accessMode: accessMode)
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try savePlainValue(value, for: account.identifier, accessMode: accessMode)
    }

    func deletePlainValue(
        for account: SecureStorageAccount,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        try deletePlainValue(for: account.identifier, accessMode: accessMode)
    }
}

/// Embedded macOS app policy for selecting the secure-storage adapter.
enum SecureKeyValueStorageFactory {
    private static let cachedSelection: SecureKeyValueStorageSelection = {
        let localSigningContext = RuntimeCodeSigningPolicy.currentLocalSigningContext()
        let signingInfo = RuntimeCodeSigningDetector.currentProcessSigningInfo(
            requirements: RuntimeCodeSigningRequirements(
                developerIDRequirement: RuntimeCodeSigningPolicy.developerIDRequirement,
                appleDevelopmentDebugRequirement: RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement,
                localCodeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier
            ),
            localSigningExpectation: localSigningContext.expectation
        )
        return selection(
            for: RuntimeCodeSigningPolicy.currentDecision(
                signingInfo: signingInfo,
                localSigningContext: localSigningContext
            )
        )
    }()

    static func defaultBackend() -> SecureKeyValueStorageBackend {
        cachedSelection.backend
    }

    static func currentDecision() -> RuntimeSecureStorageDecision {
        cachedSelection.decision
    }

    static func selection(for decision: RuntimeSecureStorageDecision) -> SecureKeyValueStorageSelection {
        let backend: SecureKeyValueStorageBackend = switch decision.domain {
        case .officialDeveloperID:
            KeychainService.officialV2Shared
        case .localSelfSigned:
            if let fingerprint = decision.localCertificateFingerprint,
               let generation = decision.localServiceGeneration,
               generation > 0
            {
                KeychainService.localSelfSigned(fingerprint: fingerprint, generation: generation)
            } else {
                EphemeralSecureKeyValueStore.shared
            }
        case .appleDevelopmentDebug:
            KeychainService.debugShared
        case .ephemeral:
            EphemeralSecureKeyValueStore.shared
        }
        return SecureKeyValueStorageSelection(decision: decision, backend: backend)
    }
}
