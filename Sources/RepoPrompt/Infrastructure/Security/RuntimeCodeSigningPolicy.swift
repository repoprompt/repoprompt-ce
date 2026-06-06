import Foundation

enum RuntimeCodeSigningDomain: Hashable {
    case developerID
    case appleDevelopmentDebug
    case localSelfSigned
}

enum RuntimeCodeSigningFailureCategory: Equatable {
    case codeObjectUnavailable
    case signatureInvalid
    case signingInformationUnavailable
    case requirementUnavailable
}

enum RuntimeCodeSigningValidationResult: Equatable {
    case valid(domains: Set<RuntimeCodeSigningDomain>)
    case invalid(RuntimeCodeSigningFailureCategory)

    func validates(_ domain: RuntimeCodeSigningDomain) -> Bool {
        guard case let .valid(domains) = self else { return false }
        return domains.contains(domain)
    }
}

struct RuntimeCodeSigningInfo: Equatable {
    let codeIdentifier: String?
    let teamIdentifier: String?
    let signingFlags: UInt32?
    let isAdHoc: Bool
    let leafCertificateSHA256: String?
    let validationResult: RuntimeCodeSigningValidationResult

    static func synthetic(
        codeIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        isAdHoc: Bool = false,
        leafCertificateSHA256: String? = nil,
        validatedDomains: Set<RuntimeCodeSigningDomain> = [],
        failure: RuntimeCodeSigningFailureCategory? = nil
    ) -> RuntimeCodeSigningInfo {
        RuntimeCodeSigningInfo(
            codeIdentifier: codeIdentifier,
            teamIdentifier: teamIdentifier,
            signingFlags: isAdHoc ? 0x2 : 0,
            isAdHoc: isAdHoc,
            leafCertificateSHA256: leafCertificateSHA256,
            validationResult: failure.map(RuntimeCodeSigningValidationResult.invalid)
                ?? .valid(domains: validatedDomains)
        )
    }
}

enum RuntimeSecureStorageDomain: Equatable {
    case officialDeveloperID
    case localSelfSigned
    case appleDevelopmentDebug
    case ephemeral
}

enum RuntimeSecureStorageRejectionReason: Equatable {
    case missingSigningModeMarker
    case unknownSigningModeMarker
    case releaseCandidate
    case adHocDebug
    case debugEphemeralRequested
    case missingDebugStorageMarker
    case unknownDebugStorageMarker
    case signingValidationFailed
    case markerSignatureMismatch
    case localIdentityMetadataUnavailable
    case localIdentityRegistryUnavailable
    case localIdentityContinuityMismatch
}

enum RuntimeLocalSigningContext: Equatable {
    case valid(RuntimeLocalSigningExpectation)
    case invalid(RuntimeSecureStorageRejectionReason)

    var expectation: RuntimeLocalSigningExpectation? {
        guard case let .valid(expectation) = self else { return nil }
        return expectation
    }
}

struct RuntimeSecureStorageDecision: Equatable {
    let domain: RuntimeSecureStorageDomain
    let rejectionReason: RuntimeSecureStorageRejectionReason?
    let localCertificateFingerprint: String?
    let localServiceGeneration: Int?

    init(
        domain: RuntimeSecureStorageDomain,
        rejectionReason: RuntimeSecureStorageRejectionReason?,
        localCertificateFingerprint: String? = nil,
        localServiceGeneration: Int? = nil
    ) {
        self.domain = domain
        self.rejectionReason = rejectionReason
        self.localCertificateFingerprint = localCertificateFingerprint
        self.localServiceGeneration = localServiceGeneration
    }
}

enum RuntimeCodeSigningPolicy {
    static let developerIDBundleIdentifier = "com.pvncher.repoprompt.ce"
    static let appleDevelopmentDebugBundleIdentifier = "com.pvncher.repoprompt.ce.debug"
    static let signingTeamIdentifier = "648A27MST5"
    static let localSelfSignedCertificateName = "RepoPrompt CE Local Self-Signed Code Signing"

    static let developerIDRequirement =
        "anchor apple generic and identifier \"\(developerIDBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static let appleDevelopmentDebugRequirement =
        "anchor apple generic and identifier \"\(appleDevelopmentDebugBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"

    private static let signingModePlistKey = "RepoPromptSigningMode"
    private static let debugStoragePlistKey = "RepoPromptDebugSecureStorageBackend"
    private static let localSigningFingerprintPlistKey = "RepoPromptLocalSigningCertificateSHA256"
    private static let localServiceGenerationPlistKey = "RepoPromptLocalSecureStorageGeneration"

    static func currentLocalSigningContext(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> RuntimeLocalSigningContext {
        guard let registryURL = LocalSigningIdentityRegistry.defaultURL(fileManager: fileManager) else {
            return .invalid(.localIdentityRegistryUnavailable)
        }
        return localSigningContext(
            bundleFingerprint: bundle.object(forInfoDictionaryKey: localSigningFingerprintPlistKey) as? String,
            bundleGenerationMarker: bundle.object(forInfoDictionaryKey: localServiceGenerationPlistKey) as? String,
            registryResult: LocalSigningIdentityRegistry.load(from: registryURL, fileManager: fileManager)
        )
    }

    static func localSigningContext(
        bundleFingerprint: String?,
        bundleGenerationMarker: String?,
        registryResult: Result<LocalSigningIdentityRecord, LocalSigningIdentityRegistryError>
    ) -> RuntimeLocalSigningContext {
        guard let bundleFingerprint = LocalSigningIdentityRegistry.normalizedFingerprint(bundleFingerprint ?? ""),
              let generationMarker = normalized(bundleGenerationMarker),
              let bundleGeneration = Int(generationMarker),
              bundleGeneration > 0
        else {
            return .invalid(.localIdentityMetadataUnavailable)
        }
        guard case let .success(record) = registryResult else {
            return .invalid(.localIdentityRegistryUnavailable)
        }
        let expectation = RuntimeLocalSigningExpectation(
            bundleLeafCertificateSHA256: bundleFingerprint,
            registeredLeafCertificateSHA256: record.certificateSHA256,
            bundleServiceGeneration: bundleGeneration,
            registeredServiceGeneration: record.serviceGeneration
        )
        guard expectation.validatedIdentity != nil else {
            return .invalid(.localIdentityContinuityMismatch)
        }
        return .valid(expectation)
    }

    static func currentDecision(
        signingInfo: RuntimeCodeSigningInfo,
        localSigningContext: RuntimeLocalSigningContext
    ) -> RuntimeSecureStorageDecision {
        decision(
            signingModeMarker: Bundle.main.object(forInfoDictionaryKey: signingModePlistKey) as? String,
            debugStorageMarker: currentDebugStorageMarker(),
            signingInfo: signingInfo,
            localSigningContext: localSigningContext
        )
    }

    static func decision(
        signingModeMarker: String?,
        debugStorageMarker: String?,
        signingInfo: RuntimeCodeSigningInfo,
        localSigningContext: RuntimeLocalSigningContext? = nil
    ) -> RuntimeSecureStorageDecision {
        guard case .valid = signingInfo.validationResult else {
            return ephemeral(.signingValidationFailed)
        }

        switch normalized(signingModeMarker) {
        case nil:
            return ephemeral(.missingSigningModeMarker)
        case "developer-id":
            guard matches(
                signingInfo,
                domain: .developerID,
                identifier: developerIDBundleIdentifier,
                teamIdentifier: signingTeamIdentifier
            ) else {
                return ephemeral(.markerSignatureMismatch)
            }
            return RuntimeSecureStorageDecision(domain: .officialDeveloperID, rejectionReason: nil)
        case "local-self-signed":
            guard let localSigningContext else {
                return ephemeral(.localIdentityRegistryUnavailable)
            }
            guard case let .valid(expectation) = localSigningContext else {
                if case let .invalid(reason) = localSigningContext {
                    return ephemeral(reason)
                }
                return ephemeral(.localIdentityRegistryUnavailable)
            }
            guard let validatedIdentity = expectation.validatedIdentity else {
                return ephemeral(.localIdentityContinuityMismatch)
            }
            guard matches(
                signingInfo,
                domain: .localSelfSigned,
                identifier: developerIDBundleIdentifier,
                teamIdentifier: nil
            ) else {
                return ephemeral(.markerSignatureMismatch)
            }
            return RuntimeSecureStorageDecision(
                domain: .localSelfSigned,
                rejectionReason: nil,
                localCertificateFingerprint: validatedIdentity.fingerprint,
                localServiceGeneration: validatedIdentity.serviceGeneration
            )
        case "release-candidate-adhoc":
            return ephemeral(.releaseCandidate)
        case "debug-adhoc":
            return ephemeral(.adHocDebug)
        case "debug-apple-development":
            switch normalized(debugStorageMarker) {
            case "alternate-in-memory":
                return ephemeral(.debugEphemeralRequested)
            case nil:
                return ephemeral(.missingDebugStorageMarker)
            case "keychain":
                guard matches(
                    signingInfo,
                    domain: .appleDevelopmentDebug,
                    identifier: appleDevelopmentDebugBundleIdentifier,
                    teamIdentifier: signingTeamIdentifier
                ) else {
                    return ephemeral(.markerSignatureMismatch)
                }
                return RuntimeSecureStorageDecision(domain: .appleDevelopmentDebug, rejectionReason: nil)
            default:
                return ephemeral(.unknownDebugStorageMarker)
            }
        default:
            return ephemeral(.unknownSigningModeMarker)
        }
    }

    private static func currentDebugStorageMarker() -> String? {
        if let environmentMarker = normalized(ProcessInfo.processInfo.environment[debugStoragePlistKey]) {
            return environmentMarker
        }
        return Bundle.main.object(forInfoDictionaryKey: debugStoragePlistKey) as? String
    }

    private static func matches(
        _ signingInfo: RuntimeCodeSigningInfo,
        domain: RuntimeCodeSigningDomain,
        identifier: String,
        teamIdentifier: String?
    ) -> Bool {
        guard !signingInfo.isAdHoc,
              signingInfo.codeIdentifier == identifier,
              signingInfo.teamIdentifier == teamIdentifier,
              signingInfo.validationResult.validates(domain)
        else {
            return false
        }
        return true
    }

    private static func ephemeral(_ reason: RuntimeSecureStorageRejectionReason) -> RuntimeSecureStorageDecision {
        RuntimeSecureStorageDecision(domain: .ephemeral, rejectionReason: reason)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
