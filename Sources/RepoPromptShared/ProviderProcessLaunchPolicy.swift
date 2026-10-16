import Foundation

/// Provider launches fail closed in an in-process XCTest host, including nested test runners.
/// Separate non-XCTest child processes are not guarded; user arguments and inherited test
/// environment variables never establish test-host identity.
/// Fixture-process tests opt in for one configured instance or task scope; no process-global
/// environment toggle can authorize an unrelated test or a controller that lost its fake.
package enum ProviderProcessLaunchPolicy {
    @TaskLocal package static var allowsLaunchForTesting = false

    package struct Refusal: LocalizedError {
        package var errorDescription: String? {
            "Provider process launch refused under XCTest. Inject a fake or explicitly opt in with ProviderProcessLaunchPolicy.$allowsLaunchForTesting."
        }
    }

    package static func check(allowsLaunchInTests: Bool = false) throws {
        // Check at the launch boundary: XCTest can load after an earlier non-test lookup.
        if NSClassFromString("XCTestCase") != nil, !allowsLaunchInTests, !allowsLaunchForTesting {
            throw Refusal()
        }
    }
}
