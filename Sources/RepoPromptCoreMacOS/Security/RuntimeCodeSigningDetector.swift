import CryptoKit
import Foundation
import Security

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
        else {
            return nil
        }
        return RuntimeValidatedLocalSigningIdentity(
            fingerprint: bundleFingerprint,
            serviceGeneration: bundleServiceGeneration
        )
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        value.filter(\.isHexDigit).uppercased()
    }
}

package struct RuntimeCodeSigningRequirements {
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

package enum RuntimeCodeSigningDetector {
    package static func currentProcessSigningInfo(
        requirements: RuntimeCodeSigningRequirements,
        localSigningExpectation: RuntimeLocalSigningExpectation? = nil
    ) -> RuntimeCodeSigningInfo {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return invalidInfo(.codeObjectUnavailable)
        }

        let validityStatus = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            return invalidInfo(.signatureInvalid)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return invalidInfo(.signingInformationUnavailable)
        }

        var information: CFDictionary?
        let informationFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation | kSecCSRequirementInformation
        )
        let infoStatus = SecCodeCopySigningInformation(staticCode, informationFlags, &information)
        guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
            return invalidInfo(.signingInformationUnavailable)
        }

        let codeIdentifier = normalizedString(dictionary[kSecCodeInfoIdentifier as String])
        let teamIdentifier = normalizedString(dictionary[kSecCodeInfoTeamIdentifier as String])
        let signingFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let isAdHoc = signingFlags.map {
            SecCodeSignatureFlags(rawValue: $0).contains(.adhoc)
        } ?? false
        let leafCertificateSHA256 = leafCertificateFingerprint(from: dictionary)

        guard let developerIDRequirement = requirement(from: requirements.developerIDRequirement),
              let debugRequirement = requirement(from: requirements.appleDevelopmentDebugRequirement)
        else {
            return RuntimeCodeSigningInfo(
                codeIdentifier: codeIdentifier,
                teamIdentifier: teamIdentifier,
                signingFlags: signingFlags,
                isAdHoc: isAdHoc,
                leafCertificateSHA256: leafCertificateSHA256,
                validationResult: .invalid(.requirementUnavailable)
            )
        }

        var validatedDomains: Set<RuntimeCodeSigningDomain> = []
        if SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), developerIDRequirement) == errSecSuccess {
            validatedDomains.insert(.developerID)
        }
        if SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), debugRequirement) == errSecSuccess {
            validatedDomains.insert(.appleDevelopmentDebug)
        }
        if let expectedFingerprint = localSigningExpectation?.validatedIdentity?.fingerprint,
           !isAdHoc,
           codeIdentifier == requirements.localCodeIdentifier,
           teamIdentifier == nil,
           leafCertificateSHA256 == expectedFingerprint
        {
            validatedDomains.insert(.localSelfSigned)
        }

        return RuntimeCodeSigningInfo(
            codeIdentifier: codeIdentifier,
            teamIdentifier: teamIdentifier,
            signingFlags: signingFlags,
            isAdHoc: isAdHoc,
            leafCertificateSHA256: leafCertificateSHA256,
            validationResult: .valid(domains: validatedDomains)
        )
    }

    private static func requirement(from source: String) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(source as CFString, [], &requirement)
        guard status == errSecSuccess else { return nil }
        return requirement
    }

    private static func leafCertificateFingerprint(from dictionary: [String: Any]) -> String? {
        guard let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leafCertificate = certificates.first
        else {
            return nil
        }
        let certificateData = SecCertificateCopyData(leafCertificate) as Data
        return SHA256.hash(data: certificateData)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func invalidInfo(_ category: RuntimeCodeSigningFailureCategory) -> RuntimeCodeSigningInfo {
        RuntimeCodeSigningInfo(
            codeIdentifier: nil,
            teamIdentifier: nil,
            signingFlags: nil,
            isAdHoc: false,
            leafCertificateSHA256: nil,
            validationResult: .invalid(category)
        )
    }
}
