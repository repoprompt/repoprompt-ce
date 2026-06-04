import Foundation

protocol SecureKeyValueStorageBackend: AnyObject {
    var persistsValuesAcrossLaunches: Bool { get }

    func save(
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

enum SecureKeyValueStorageFactory {
    private static let cachedBackend: SecureKeyValueStorageBackend = {
        #if DEBUG
            let signingInfo = RuntimeCodeSigningDetector.currentProcessSigningInfo()
            let marker = DebugSecureStorageRuntimePolicy.currentDebugStorageMarker()
            switch DebugSecureStorageRuntimePolicy.backendKind(for: signingInfo, debugStorageMarker: marker) {
            case .keychain:
                return KeychainService.shared
            case .alternateInMemory:
                return EphemeralSecureKeyValueStore.shared
            }
        #else
            switch PersistentKeychainRuntimePolicy.backendKind() {
            case .localSelfSigned:
                return KeychainService.localSelfSignedShared
            case .canonical:
                return KeychainService.shared
            }
        #endif
    }()

    static func defaultBackend() -> SecureKeyValueStorageBackend {
        cachedBackend
    }
}

enum PersistentKeychainBackendKind: Equatable {
    case localSelfSigned
    case canonical
}

enum PersistentKeychainRuntimePolicy {
    private static let localSelfSignedMarker = "local-self-signed"
    private static let signingModePlistKey = "RepoPromptSigningMode"

    static func backendKind() -> PersistentKeychainBackendKind {
        backendKind(signingModeMarker: Bundle.main.object(forInfoDictionaryKey: signingModePlistKey) as? String)
    }

    static func backendKind(signingModeMarker: String?) -> PersistentKeychainBackendKind {
        switch normalizedString(signingModeMarker) {
        case localSelfSignedMarker:
            .localSelfSigned
        default:
            .canonical
        }
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
    enum DebugSecureStorageBackendKind: Equatable {
        case keychain
        case alternateInMemory
    }

    enum DebugSecureStorageRuntimePolicy {
        private static let keychainMarker = "keychain"
        private static let plistMarkerKey = "RepoPromptDebugSecureStorageBackend"

        static func currentDebugStorageMarker() -> String? {
            if let environmentMarker = normalizedString(ProcessInfo.processInfo.environment[plistMarkerKey]) {
                return environmentMarker
            }
            return normalizedString(Bundle.main.object(forInfoDictionaryKey: plistMarkerKey) as? String)
        }

        static func backendKind(
            for signingInfo: RuntimeCodeSigningInfo,
            debugStorageMarker: String?
        ) -> DebugSecureStorageBackendKind {
            // DEBUG uses persistent Keychain only when packaging explicitly opted in and
            // the launched binary has a real TeamIdentifier. Auto-detected debug signing
            // deliberately keeps using alternate in-memory storage to avoid Keychain prompts.
            guard normalizedString(debugStorageMarker) == keychainMarker,
                  let teamIdentifier = signingInfo.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !teamIdentifier.isEmpty
            else {
                return .alternateInMemory
            }
            return .keychain
        }

        private static func normalizedString(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
    }
#endif
