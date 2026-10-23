import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TooltipOverlayControllerTests: XCTestCase {
    func testPendingShowInvalidatedByOwnerLifecycleButNotAnotherWindow() {
        let owner = NSWindow()
        let other = NSWindow()
        for notification in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification] {
            var fire: (@MainActor () -> Void)?
            let pending = TooltipPendingPresentation { _, action in
                fire = action
                return DispatchWorkItem {}
            }
            var shows = 0
            var ends = 0
            pending.schedule(owner: owner, after: 0.3, isEligible: { true }, onEnd: { ends += 1 }) { shows += 1 }
            NotificationCenter.default.post(name: notification, object: other)
            NotificationCenter.default.post(name: notification, object: owner)
            fire?() // Deliberately deliver even a cancelled scheduler callback.
            XCTAssertEqual(shows, 0, notification.rawValue)
            XCTAssertEqual(ends, 1, "Owner invalidation must release input monitors immediately")
        }
    }

    func testPendingShowRevalidatesAndRejectsStaleCallbacks() {
        let owner = NSWindow()
        var callbacks: [@MainActor () -> Void] = []
        let pending = TooltipPendingPresentation { _, action in
            callbacks.append(action)
            return DispatchWorkItem {}
        }
        var eligible = true
        var shows = 0
        var ends = 0
        pending.schedule(owner: owner, after: 0.3, isEligible: { eligible }, onEnd: { ends += 1 }) { shows += 1 }
        eligible = false
        callbacks.removeFirst()()
        XCTAssertEqual(shows, 0)
        XCTAssertEqual(ends, 1, "Rejected presentation must release input monitors")

        eligible = true
        pending.schedule(owner: owner, after: 0.3, isEligible: { eligible }) { shows += 1 }
        pending.cancel() // Hover exit, detach, disappearance, or input dismissal.
        pending.schedule(owner: owner, after: 0.3, isEligible: { eligible }) { shows += 1 }
        callbacks.removeFirst()()
        XCTAssertEqual(shows, 0)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        callbacks.removeFirst()()
        XCTAssertEqual(shows, 1, "Stable owner still presents, isolated from other windows")
    }

    func testDeferredFirstAnchorBindsButOwnerReplacementCancels() {
        let owner = NSWindow()
        let other = NSWindow()
        var fire: (@MainActor () -> Void)?
        let pending = TooltipPendingPresentation { _, action in
            fire = action
            return DispatchWorkItem {}
        }
        var shows = 0
        pending.schedule(owner: nil, after: 0.3, isEligible: { true }) { shows += 1 }
        pending.updateOwner(owner)
        fire?()
        XCTAssertEqual(shows, 1, "Hover before the first geometry report must still show")

        pending.schedule(owner: owner, after: 0.3, isEligible: { true }) { shows += 1 }
        pending.updateOwner(other)
        fire?()
        XCTAssertEqual(shows, 1, "A hover must not transfer to another window")

        pending.schedule(owner: nil, after: 0.3, isEligible: { true }) { shows += 1 }
        pending.updateOwner(owner)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        fire?()
        XCTAssertEqual(shows, 1, "The deferred owner must also be observed")
    }

    func testAnchorRemovalCancelsPendingShowSynchronously() {
        let owner = NSWindow()
        let container = NSView()
        owner.contentView = container
        var fire: (@MainActor () -> Void)?
        let pending = TooltipPendingPresentation { _, action in
            fire = action
            return DispatchWorkItem {}
        }
        var detached = false
        let anchor = AnchorGeometryView.TrackingView { _, window in
            if window == nil {
                detached = true
                pending.cancel()
            }
        }
        container.addSubview(anchor)
        detached = false
        var shows = 0
        pending.schedule(owner: owner, after: 0.3, isEligible: { true }) { shows += 1 }
        anchor.removeFromSuperview()
        XCTAssertTrue(detached, "Removal must not wait for the coalesced geometry report")
        fire?()
        XCTAssertEqual(shows, 0)
    }

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
