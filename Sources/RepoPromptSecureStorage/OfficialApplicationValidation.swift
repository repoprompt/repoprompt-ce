import Foundation
import Security

/// Narrow package seam for history acquisition. Requirement strings remain owned
/// by secure storage; callers cannot supply an arbitrary signing requirement.
package enum OfficialApplicationIdentity: String {
    case legacy
    case successor

    package var bundleIdentifier: String {
        switch self {
        case .legacy: RuntimeCodeSigningPolicy.developerIDBundleIdentifier
        case .successor: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier
        }
    }

    package var teamIdentifier: String {
        switch self {
        case .legacy: RuntimeCodeSigningPolicy.signingTeamIdentifier
        case .successor: RuntimeCodeSigningPolicy.successorSigningTeamIdentifier
        }
    }

    package static var currentRunningIdentity: Self? {
        switch SecureKeyValueStorageFactory.currentDecision().domain {
        case .officialDeveloperID: .legacy
        case .successorOfficialDeveloperID: .successor
        default: nil
        }
    }

    package func validatesOfficialApplication(at url: URL) -> Bool {
        let source = switch self {
        case .legacy: RuntimeCodeSigningPolicy.developerIDRequirement
        case .successor: RuntimeCodeSigningPolicy.successorDeveloperIDRequirement
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              let requirement = RuntimeCodeSigningDetector.requirement(from: source)
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
