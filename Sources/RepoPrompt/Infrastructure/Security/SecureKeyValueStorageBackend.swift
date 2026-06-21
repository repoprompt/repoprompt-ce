import Foundation
import RepoPromptCore
import RepoPromptCoreMacOS

struct SecureKeyValueStorageSelection {
    let decision: RuntimeSecureStorageDecision
    let backend: any SecureKeyValueStorageBackend
}

enum SecureKeyValueStorageFactory {
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

    static func defaultBackend() -> any SecureKeyValueStorageBackend {
        cachedSelection.backend
    }

    static func currentDecision() -> RuntimeSecureStorageDecision {
        cachedSelection.decision
    }

    static func selection(for decision: RuntimeSecureStorageDecision) -> SecureKeyValueStorageSelection {
        let backend: any SecureKeyValueStorageBackend = switch decision.domain {
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
