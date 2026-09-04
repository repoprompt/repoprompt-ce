import Foundation

protocol SecureKeyValueStorageBackend: AnyObject, Sendable {
    var persistsValuesAcrossLaunches: Bool { get }

    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws

    /// Creates a value only when no item with this backend's identity already exists.
    /// Migration code uses this to avoid rewriting an unproven pre-existing Keychain ACL.
    func create(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws

    func get(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws -> String

    func delete(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws
}

extension SecureKeyValueStorageBackend {
    func create(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        do {
            _ = try get(for: key, accessMode: accessMode)
            throw KeychainService.KeychainError.duplicateItem
        } catch KeychainService.KeychainError.itemNotFound {
            try save(value, for: key, accessMode: accessMode)
        }
    }
}

struct SecureKeyValueStorageSelection {
    let decision: RuntimeSecureStorageDecision
    let backend: SecureKeyValueStorageBackend
}

enum SecureKeyValueStorageFactory {
    private final class State: @unchecked Sendable {
        static let shared = State()

        private let lock = NSLock()
        private var officialBackendOverride: SecureKeyValueStorageBackend?

        func installOfficialBackendOverride(_ backend: SecureKeyValueStorageBackend) {
            lock.lock()
            officialBackendOverride = backend
            lock.unlock()
        }

        func officialBackend(fallback: SecureKeyValueStorageBackend) -> SecureKeyValueStorageBackend {
            lock.lock()
            defer { lock.unlock() }
            return officialBackendOverride ?? fallback
        }
    }

    private static let cachedSelection: SecureKeyValueStorageSelection = {
        let localSigningContext = RuntimeCodeSigningPolicy.currentLocalSigningContext()
        let signingInfo = RuntimeCodeSigningDetector.currentProcessSigningInfo(
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
        guard officialOverrideApplies(to: cachedSelection.decision.domain) else {
            return cachedSelection.backend
        }
        return State.shared.officialBackend(fallback: cachedSelection.backend)
    }

    /// The committed identity-migration bridge override is only meaningful for the two
    /// official Developer ID identities; every other domain keeps its dedicated backend.
    static func officialOverrideApplies(to domain: RuntimeSecureStorageDomain) -> Bool {
        switch domain {
        case .officialDeveloperID, .successorOfficialDeveloperID:
            true
        case .localSelfSigned, .appleDevelopmentDebug, .ephemeral:
            false
        }
    }

    static func currentDecision() -> RuntimeSecureStorageDecision {
        cachedSelection.decision
    }

    /// Must be called during process bootstrap, before services capture the default backend.
    static func installOfficialBackendOverride(_ backend: SecureKeyValueStorageBackend) {
        State.shared.installOfficialBackendOverride(backend)
    }

    static func selection(for decision: RuntimeSecureStorageDecision) -> SecureKeyValueStorageSelection {
        let backend: SecureKeyValueStorageBackend = switch decision.domain {
        case .officialDeveloperID:
            KeychainService.officialV2Shared
        case .successorOfficialDeveloperID:
            // The successor identity has no legacy fallback service. It stays ephemeral
            // until bootstrap installs an authenticated committed-bridge override.
            EphemeralSecureKeyValueStore.shared
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
