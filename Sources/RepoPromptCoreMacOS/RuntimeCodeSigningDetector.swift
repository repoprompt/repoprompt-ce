import CryptoKit
import Foundation
import RepoPromptCore
import Security

package enum MacOSRuntimeCodeSigningDetector {
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
        guard infoStatus == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
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
        if SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            developerIDRequirement
        ) == errSecSuccess {
            validatedDomains.insert(.developerID)
        }
        if SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            debugRequirement
        ) == errSecSuccess {
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
        else { return nil }
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

    private static func invalidInfo(
        _ category: RuntimeCodeSigningFailureCategory
    ) -> RuntimeCodeSigningInfo {
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
