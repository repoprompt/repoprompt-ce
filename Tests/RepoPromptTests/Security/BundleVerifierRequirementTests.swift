@testable import RepoPrompt
import Security
import XCTest

final class BundleVerifierRequirementTests: XCTestCase {
    func testOfficialReleaseRequirementExcludesAppleDevelopmentCertificateClass() {
        let officialRequirement = BundleVerifier.signingIdentityRequirementString(for: .officialDeveloperID)
        let debugRequirement = BundleVerifier.signingIdentityRequirementString(for: .debugAppleDevelopment)
        let developerIDClause = "certificate leaf[field.\(BundleVerifier.developerIDApplicationCertificateExtension)] exists"

        XCTAssertTrue(officialRequirement.contains(developerIDClause))
        XCTAssertFalse(debugRequirement.contains(developerIDClause))

        var parsedRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(officialRequirement as CFString, [], &parsedRequirement),
            errSecSuccess
        )
        XCTAssertNotNil(parsedRequirement)
    }
}
