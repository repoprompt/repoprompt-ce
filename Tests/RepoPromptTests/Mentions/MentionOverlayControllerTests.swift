@testable import RepoPrompt
import XCTest

@MainActor
final class MentionOverlayControllerTests: XCTestCase {
    func testVisibleRowLimitDefaultsToFiveAndNormalizesInvalidValues() {
        let overlay = MentionOverlayController()

        XCTAssertEqual(overlay.visibleRowLimit, 5)

        overlay.visibleRowLimit = FileMentionPickerStyle.expanded.configuration.visibleRows
        XCTAssertEqual(overlay.visibleRowLimit, 15)

        overlay.visibleRowLimit = 0
        XCTAssertEqual(overlay.visibleRowLimit, 1)

        overlay.visibleRowLimit = -4
        XCTAssertEqual(overlay.visibleRowLimit, 1)
    }

    func testSuggestionWindowDisablesNativeShadowForRoundedPopup() {
        let window = MentionOverlayController.SuggestionWindow(
            parent: nil,
            placement: .below
        )

        XCTAssertFalse(
            window.hasShadow,
            "Native NSWindow shadows are rectangular and can show through around the rounded mention popup."
        )
    }
}
