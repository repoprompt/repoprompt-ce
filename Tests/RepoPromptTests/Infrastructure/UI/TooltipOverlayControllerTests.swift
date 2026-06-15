import AppKit
@testable import RepoPrompt
import XCTest

@MainActor
final class TooltipOverlayControllerTests: XCTestCase {
    func testTooltipHidesWhenDismissAllIsRequested() async {
        let owner = makeVisibleOwnerWindow()
        let controller = showTooltip(owner: owner)
        defer {
            controller.hide()
            owner.orderOut(nil)
        }

        XCTAssertTrue(controller.isVisibleForTesting)

        HoverTooltipCoordinator.dismissAll()
        await Task.yield()

        XCTAssertFalse(controller.isVisibleForTesting)
    }

    func testTooltipHidesInsteadOfMovingToWindowOriginWhenRepositionedToInvalidAnchor() {
        let owner = makeVisibleOwnerWindow()
        let controller = showTooltip(owner: owner)
        defer {
            controller.hide()
            owner.orderOut(nil)
        }

        XCTAssertTrue(controller.isVisibleForTesting)

        controller.reposition(to: .zero)

        XCTAssertFalse(controller.isVisibleForTesting)
    }

    func testTooltipDoesNotShowWithInvalidInitialAnchor() {
        let owner = makeVisibleOwnerWindow()
        let controller = TooltipOverlayController()
        defer {
            controller.hide()
            owner.orderOut(nil)
        }

        controller.show(
            text: "1 connection - View status",
            anchorRect: .zero,
            owner: owner,
            placement: .top,
            preset: .current
        )

        XCTAssertFalse(controller.isVisibleForTesting)
    }

    private func makeVisibleOwnerWindow() -> NSWindow {
        let owner = NSWindow(
            contentRect: NSRect(x: 80, y: 120, width: 320, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        owner.orderFront(nil)
        return owner
    }

    private func showTooltip(owner: NSWindow) -> TooltipOverlayController {
        let controller = TooltipOverlayController()
        controller.show(
            text: "1 connection - View status",
            anchorRect: NSRect(x: 8, y: 8, width: 80, height: 20),
            owner: owner,
            placement: .top,
            preset: .current
        )
        return controller
    }
}
