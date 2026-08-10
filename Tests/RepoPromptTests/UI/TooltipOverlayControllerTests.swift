import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TooltipOverlayControllerTests: XCTestCase {
    func testConstrainedTopLeftUsesScreenIntersectingAnchor() throws {
        let firstVisibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let secondVisibleFrame = NSRect(x: 1000, y: 0, width: 1000, height: 780)
        let screens = [
            ScreenGeometrySnapshot(
                frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: firstVisibleFrame
            ),
            ScreenGeometrySnapshot(
                frame: NSRect(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: secondVisibleFrame
            )
        ]

        let topLeft = try XCTUnwrap(
            TooltipOverlayController.constrainedTopLeft(
                NSPoint(x: 900, y: 500),
                bubbleSize: NSSize(width: 200, height: 80),
                anchor: NSRect(x: 900, y: 300, width: 300, height: 20),
                screens: screens
            )
        )

        XCTAssertEqual(topLeft.x, secondVisibleFrame.minX)
        XCTAssertEqual(topLeft.y, 500)
    }

    func testConstrainedTopLeftClampsWithinAnchorScreenVisibleFrame() throws {
        let visibleFrame = NSRect(x: 1000, y: 40, width: 1000, height: 740)
        let screens = [
            ScreenGeometrySnapshot(
                frame: NSRect(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: visibleFrame
            )
        ]
        let bubbleSize = NSSize(width: 240, height: 100)

        let topRight = try XCTUnwrap(
            TooltipOverlayController.constrainedTopLeft(
                NSPoint(x: 1950, y: 900),
                bubbleSize: bubbleSize,
                anchor: NSRect(x: 1900, y: 700, width: 20, height: 20),
                screens: screens
            )
        )
        let bottomLeft = try XCTUnwrap(
            TooltipOverlayController.constrainedTopLeft(
                NSPoint(x: 900, y: 20),
                bubbleSize: bubbleSize,
                anchor: NSRect(x: 1100, y: 100, width: 20, height: 20),
                screens: screens
            )
        )

        XCTAssertEqual(topRight.x, visibleFrame.maxX - bubbleSize.width)
        XCTAssertEqual(topRight.y, visibleFrame.maxY)
        XCTAssertEqual(bottomLeft.x, visibleFrame.minX)
        XCTAssertEqual(bottomLeft.y, visibleFrame.minY + bubbleSize.height)
    }
}
