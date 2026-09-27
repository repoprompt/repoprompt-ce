@testable import RepoPromptApp
import XCTest

final class DebugBuildIdentityTests: XCTestCase {
    func testDebugTestBuildsEnableInWindowIdentity() {
        // Tests compile with DEBUG, so the identity must be active here; release builds compile it out.
        XCTAssertTrue(DebugBuildIdentity.isEnabled)
    }

    func testBadgeTextMeetsWCAGAAContrastOnAccentFill() {
        let accent = DebugBuildIdentity.accentSRGB
        let accentLuminance = Self.relativeLuminance(red: accent.red, green: accent.green, blue: accent.blue)
        let whiteLuminance = 1.0
        let contrast = (whiteLuminance + 0.05) / (accentLuminance + 0.05)

        // The badge draws small bold white text on the accent capsule; hold the normal-text AA bar.
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "DEBUG badge contrast \(contrast) is below WCAG AA")
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}
