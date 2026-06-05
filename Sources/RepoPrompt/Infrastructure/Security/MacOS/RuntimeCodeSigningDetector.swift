import Foundation
import Security

struct RuntimeCodeSigningInfo: Equatable {
    let teamIdentifier: String?
    let codeIdentifier: String?
    let detectionErrorDescription: String?
}

enum RuntimeCodeSigningDetector {
    static func currentProcessSigningInfo() -> RuntimeCodeSigningInfo {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return RuntimeCodeSigningInfo(
                teamIdentifier: nil,
                codeIdentifier: nil,
                detectionErrorDescription: errorDescription(for: selfStatus)
            )
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return RuntimeCodeSigningInfo(
                teamIdentifier: nil,
                codeIdentifier: nil,
                detectionErrorDescription: errorDescription(for: staticStatus)
            )
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
            return RuntimeCodeSigningInfo(
                teamIdentifier: nil,
                codeIdentifier: nil,
                detectionErrorDescription: errorDescription(for: infoStatus)
            )
        }

        let teamIdentifier = normalizedString(dictionary[kSecCodeInfoTeamIdentifier as String])
        let codeIdentifier = normalizedString(dictionary[kSecCodeInfoIdentifier as String])
        return RuntimeCodeSigningInfo(
            teamIdentifier: teamIdentifier,
            codeIdentifier: codeIdentifier,
            detectionErrorDescription: nil
        )
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func errorDescription(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Code signing information unavailable (\(status))"
    }
}
