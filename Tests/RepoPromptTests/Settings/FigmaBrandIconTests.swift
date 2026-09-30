@testable import RepoPromptApp
import XCTest

final class FigmaBrandIconTests: XCTestCase {
    func testVisiblePathGeometryIsTheSizingContract() {
        let bounds = FigmaBrandIconGeometry.visiblePathBounds

        XCTAssertEqual(bounds, CGRect(x: 312, y: 0, width: 400, height: 940))
        XCTAssertEqual(FigmaBrandIconGeometry.visibleAspectRatio, 400 / 940, accuracy: 0.000_001)
        XCTAssertEqual(
            FigmaBrandIconGeometry.settingsVisibleHeight * FigmaBrandIconGeometry.visibleAspectRatio,
            400 * 18 / 940,
            accuracy: 0.000_001
        )
        XCTAssertEqual(FigmaBrandIconGeometry.settingsVisibleHeight, 18)
        XCTAssertEqual(FigmaBrandIconGeometry.settingsIconSlotWidth, 16)
        XCTAssertEqual(FigmaBrandIconGeometry.settingsVerticalAlignmentOffset, -3)
    }
}
