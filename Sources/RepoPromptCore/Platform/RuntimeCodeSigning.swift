import Foundation

package enum RuntimeCodeSigningDomain: Hashable {
    case developerID
    case appleDevelopmentDebug
    case localSelfSigned
}

package enum RuntimeCodeSigningFailureCategory: Equatable {
    case codeObjectUnavailable
    case signatureInvalid
    case signingInformationUnavailable
    case requirementUnavailable
}

package enum RuntimeCodeSigningValidationResult: Equatable {
    case valid(domains: Set<RuntimeCodeSigningDomain>)
    case invalid(RuntimeCodeSigningFailureCategory)

    package func validates(_ domain: RuntimeCodeSigningDomain) -> Bool {
        guard case let .valid(domains) = self else { return false }
        return domains.contains(domain)
    }
}

package struct RuntimeCodeSigningInfo: Equatable {
    package let codeIdentifier: String?
    package let teamIdentifier: String?
    package let signingFlags: UInt32?
    package let isAdHoc: Bool
    package let leafCertificateSHA256: String?
    package let validationResult: RuntimeCodeSigningValidationResult

    package init(
        codeIdentifier: String?,
        teamIdentifier: String?,
        signingFlags: UInt32?,
        isAdHoc: Bool,
        leafCertificateSHA256: String?,
        validationResult: RuntimeCodeSigningValidationResult
    ) {
        self.codeIdentifier = codeIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingFlags = signingFlags
        self.isAdHoc = isAdHoc
        self.leafCertificateSHA256 = leafCertificateSHA256
        self.validationResult = validationResult
    }

    package static func synthetic(
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

package struct RuntimeValidatedLocalSigningIdentity: Equatable {
    package let fingerprint: String
    package let serviceGeneration: Int

    package init(fingerprint: String, serviceGeneration: Int) {
        self.fingerprint = fingerprint
        self.serviceGeneration = serviceGeneration
    }
}

package struct RuntimeLocalSigningExpectation: Equatable {
    package let bundleLeafCertificateSHA256: String
    package let registeredLeafCertificateSHA256: String
    package let bundleServiceGeneration: Int
    package let registeredServiceGeneration: Int

    package init(
        bundleLeafCertificateSHA256: String,
        registeredLeafCertificateSHA256: String,
        bundleServiceGeneration: Int,
        registeredServiceGeneration: Int
    ) {
        self.bundleLeafCertificateSHA256 = bundleLeafCertificateSHA256
        self.registeredLeafCertificateSHA256 = registeredLeafCertificateSHA256
        self.bundleServiceGeneration = bundleServiceGeneration
        self.registeredServiceGeneration = registeredServiceGeneration
    }

    package var validatedIdentity: RuntimeValidatedLocalSigningIdentity? {
        let bundleFingerprint = Self.normalizedFingerprint(bundleLeafCertificateSHA256)
        let registeredFingerprint = Self.normalizedFingerprint(registeredLeafCertificateSHA256)
        guard bundleFingerprint.count == 64,
              bundleFingerprint == registeredFingerprint,
              bundleServiceGeneration > 0,
              bundleServiceGeneration == registeredServiceGeneration
        else { return nil }
        return RuntimeValidatedLocalSigningIdentity(
            fingerprint: bundleFingerprint,
            serviceGeneration: bundleServiceGeneration
        )
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        value.filter(\.isHexDigit).uppercased()
    }
}

package struct RuntimeCodeSigningRequirements: Equatable {
    package let developerIDRequirement: String
    package let appleDevelopmentDebugRequirement: String
    package let localCodeIdentifier: String

    package init(
        developerIDRequirement: String,
        appleDevelopmentDebugRequirement: String,
        localCodeIdentifier: String
    ) {
        self.developerIDRequirement = developerIDRequirement
        self.appleDevelopmentDebugRequirement = appleDevelopmentDebugRequirement
        self.localCodeIdentifier = localCodeIdentifier
    }
}
