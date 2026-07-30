@testable import RepoPromptApp
import XCTest

final class CollapsibleUserMessageTests: XCTestCase {
    func testPreviewUsesThresholdEqualityAndGraphemeBoundaries() {
        let family = "👨‍👩‍👧‍👦"
        let decomposedE = "e\u{301}"
        let scenarios: [(text: String, limit: Int, needsCollapse: Bool, preview: String)] = [
            ("", 0, false, ""),
            ("a", 0, true, ""),
            ("abc", 3, false, "abc"),
            ("abcd", 3, true, "abc"),
            (family, 1, false, family),
            (family + "x", 1, true, family),
            (decomposedE + "x", 1, true, decomposedE)
        ]

        for scenario in scenarios {
            let preview = CollapsibleUserMessagePreview(
                text: scenario.text,
                characterLimit: scenario.limit
            )

            XCTAssertEqual(preview.needsCollapse, scenario.needsCollapse, scenario.text)
            XCTAssertEqual(preview.text, scenario.preview, scenario.text)
        }

        let decomposedPreview = CollapsibleUserMessagePreview(
            text: decomposedE + "x",
            characterLimit: 1
        )
        XCTAssertEqual(
            decomposedPreview.text.unicodeScalars.map(\.value),
            decomposedE.unicodeScalars.map(\.value)
        )
    }

    func testPreviewBoundsLargeBridgedStringAtThreshold() {
        let expectedPreview = String(repeating: "👩🏽‍💻", count: 500)
        let bridgedText = (expectedPreview + String(repeating: "x", count: 1_000_000)) as NSString as String

        let preview = CollapsibleUserMessagePreview(
            text: bridgedText,
            characterLimit: 500
        )

        XCTAssertTrue(preview.needsCollapse)
        XCTAssertEqual(preview.text, expectedPreview)
        XCTAssertEqual(preview.text.count, 500)
    }
}
