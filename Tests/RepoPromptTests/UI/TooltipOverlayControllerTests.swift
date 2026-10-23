import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TooltipPendingPresentationTests: XCTestCase {
    func testPendingShowInvalidatedByOwnerLifecycleButNotAnotherWindow() {
        let owner = NSWindow()
        let other = NSWindow()
        for notification in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification, NSWindow.didMiniaturizeNotification] {
            var fire: (@MainActor () -> Void)?
            let pending = TooltipPendingPresentation { _, action in
                fire = action
                return DispatchWorkItem {}
            }
            var shows = 0
            var ends = 0
            pending.schedule(owner: owner, after: 0.3, isEligible: { _, _ in true }, onEnd: { ends += 1 }) { shows += 1 }
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
        pending.schedule(owner: owner, after: 0.3, isEligible: { _, _ in eligible }, onEnd: { ends += 1 }) { shows += 1 }
        eligible = false
        callbacks.removeFirst()()
        XCTAssertEqual(shows, 0)
        XCTAssertEqual(ends, 1, "Rejected presentation must release input monitors")

        eligible = true
        pending.schedule(owner: owner, after: 0.3, isEligible: { _, _ in eligible }) { shows += 1 }
        pending.cancel() // Hover exit, detach, disappearance, or input dismissal.
        pending.schedule(owner: owner, after: 0.3, isEligible: { _, _ in eligible }) { shows += 1 }
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
        pending.schedule(owner: nil, after: 0.3, isEligible: { _, _ in true }) { shows += 1 }
        pending.updateOwner(owner)
        fire?()
        XCTAssertEqual(shows, 1, "Hover before the first geometry report must still show")

        pending.schedule(owner: owner, after: 0.3, isEligible: { _, _ in true }) { shows += 1 }
        pending.updateOwner(other)
        fire?()
        XCTAssertEqual(shows, 1, "A hover must not transfer to another window")

        pending.schedule(owner: nil, after: 0.3, isEligible: { _, _ in true }) { shows += 1 }
        pending.updateOwner(owner)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        fire?()
        XCTAssertEqual(shows, 1, "The deferred owner must also be observed")
    }

    func testEligibilityPolicyPreservesStableNonKeyOwners() {
        let baseline = TooltipPresentationEligibility(
            windowVisible: true, windowKey: false, wasKey: false, appActive: true,
            onActiveSpace: true, pointerInside: true, miniaturized: false, hasSheet: false, tooltipsEnabled: true
        )
        let cases: [(String, (inout TooltipPresentationEligibility) -> Void, Bool)] = [
            ("stable non-key panel or secondary window", { _ in }, true),
            ("stable key owner", { $0.windowKey = true
                $0.wasKey = true }, true),
            ("resigned without notification", { $0.wasKey = true }, false),
            ("owner became key", { $0.windowKey = true }, true),
            ("inactive app", { $0.appActive = false }, false),
            ("other Space", { $0.onActiveSpace = false }, false),
            ("pointer outside moved anchor", { $0.pointerInside = false }, false),
            ("hidden owner", { $0.windowVisible = false }, false),
            ("miniaturized owner", { $0.miniaturized = true }, false),
            ("sheet presented", { $0.hasSheet = true }, false),
            ("tooltips disabled", { $0.tooltipsEnabled = false }, false)
        ]
        for (label, change, expected) in cases {
            var input = baseline
            change(&input)
            XCTAssertEqual(input.allowsPresentation, expected, label)
        }
    }

    func testPointerUsesCurrentClippedRectAndOwnerIdentity() {
        let owner = NSWindow()
        let other = NSWindow()
        let pointer = NSPoint(x: 20, y: 20)
        let rect = NSRect(x: 10, y: 10, width: 40, height: 30)
        XCTAssertTrue(TooltipPresentationEligibility.pointerIsInside(trackingWindow: owner, owner: owner, visibleRect: rect, mouseLocation: pointer))
        for (label, window, visibleRect) in [
            ("content moved under stationary pointer", owner, rect.offsetBy(dx: 100, dy: 0)),
            ("clipped away", owner, NSRect.zero),
            ("view moved to another window", other, rect)
        ] {
            XCTAssertFalse(TooltipPresentationEligibility.pointerIsInside(trackingWindow: window, owner: owner, visibleRect: visibleRect, mouseLocation: pointer), label)
        }
        XCTAssertFalse(TooltipPresentationEligibility.pointerIsInside(trackingWindow: nil, owner: owner, visibleRect: rect, mouseLocation: pointer))
    }

    func testRuntimePreservesNonKeyOwnerButRejectsKeyLossAtFireTime() async {
        let stable = RuntimeHarness()
        defer { stable.runtime.cleanup() }
        stable.schedule()
        XCTAssertEqual(stable.monitors.localAdds, 1)
        XCTAssertEqual(stable.monitors.globalAdds, 0, "No global monitor during the delay")
        stable.scheduler.fire()
        XCTAssertEqual(stable.shows, 1, "A stable non-key panel must still present")
        XCTAssertEqual(stable.monitors.removals, 1, "Pending local monitor ends before visible handoff")
        XCTAssertEqual(stable.monitors.localAdds, 2)
        XCTAssertEqual(stable.monitors.globalAdds, 1)
        stable.monitors.globalDismiss?()
        // Fence the main queue after the runtime's deferred visible dismissal.
        // This drives event ordering without sleeping or advancing wall-clock time.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(stable.monitors.removals, 3, "Global input releases visible monitors")

        let resigned = RuntimeHarness()
        defer { resigned.runtime.cleanup() }
        resigned.window.keyForTest = true
        resigned.schedule()
        resigned.window.keyForTest = false // Prove fire-time policy, without the observer.
        resigned.scheduler.fire()
        XCTAssertEqual(resigned.shows, 0)
        XCTAssertEqual(resigned.monitors.removals, 1, "Eligibility rejection cleans pending input monitoring")
    }

    func testLocalInputCancelsPendingRuntimeAndCleansMonitor() {
        let harness = RuntimeHarness()
        defer { harness.runtime.cleanup() }
        harness.schedule()
        harness.monitors.localDismiss?() // The callback installed by production runtime wiring.
        XCTAssertEqual(harness.monitors.removals, 1, "Input must invalidate and clean up synchronously")
        harness.scheduler.fire()
        XCTAssertEqual(harness.shows, 0)
        XCTAssertEqual(harness.monitors.globalAdds, 0)
    }

    func testSpaceChangeCancelsPendingRuntimeAndCleansMonitor() {
        let harness = RuntimeHarness()
        defer { harness.runtime.cleanup() }
        harness.schedule()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(harness.monitors.removals, 1)
        harness.scheduler.fire()
        XCTAssertEqual(harness.shows, 0)
        XCTAssertEqual(harness.monitors.globalAdds, 0)
    }

    func testAnchorRemovalCancelsPendingRuntimeSynchronously() {
        let harness = RuntimeHarness()
        defer { harness.runtime.cleanup() }
        harness.schedule()
        harness.anchor.removeFromSuperview() // Actual TrackingView -> runtime.updateAnchor wiring.
        XCTAssertEqual(harness.monitors.removals, 1, "Removal must cancel before deferred geometry or the timer")
        harness.scheduler.fire()
        XCTAssertEqual(harness.shows, 0)
    }

    @MainActor
    private final class RuntimeHarness {
        final class OwnerWindow: NSWindow {
            var keyForTest = false
            override var isKeyWindow: Bool {
                keyForTest
            }
        }

        @MainActor
        final class Scheduler {
            var actions: [@MainActor () -> Void] = []
            func schedule(_: TimeInterval, action: @escaping @MainActor () -> Void) -> DispatchWorkItem {
                actions.append(action)
                return DispatchWorkItem {}
            }

            func fire() {
                XCTAssertFalse(actions.isEmpty)
                if !actions.isEmpty { actions.removeFirst()() }
            }
        }

        @MainActor
        final class Monitors {
            var localDismiss: (() -> Void)?
            var globalDismiss: (() -> Void)?
            var localAdds = 0
            var globalAdds = 0
            var removals = 0
            var monitoring: TooltipHoverRuntime.EventMonitoring {
                .init(addLocal: { dismiss in
                    self.localDismiss = dismiss
                    self.localAdds += 1
                    return NSObject()
                }, addGlobal: { dismiss in
                    self.globalDismiss = dismiss
                    self.globalAdds += 1
                    return NSObject()
                }, remove: { _ in self.removals += 1 })
            }
        }

        let window = OwnerWindow()
        let scheduler = Scheduler()
        let monitors = Monitors()
        let runtime: TooltipHoverRuntime
        let anchor: AnchorGeometryView.TrackingView
        var shows = 0

        init() {
            runtime = TooltipHoverRuntime(
                pendingPresentation: TooltipPendingPresentation(scheduleWork: scheduler.schedule),
                eventMonitoring: monitors.monitoring,
                captureEligibility: { owner, wasKey, _ in
                    // Supply only volatile desktop state. The production policy
                    // still decides presentation, including the captured key state.
                    TooltipPresentationEligibility(
                        windowVisible: true, windowKey: owner.isKeyWindow, wasKey: wasKey, appActive: true,
                        onActiveSpace: true, pointerInside: true, miniaturized: false, hasSheet: false, tooltipsEnabled: true
                    )
                }
            )
            anchor = AnchorGeometryView.TrackingView(callback: runtime.updateAnchor)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            window.contentView = container
            anchor.frame = NSRect(x: 10, y: 10, width: 40, height: 30)
            container.addSubview(anchor)
            runtime.updateAnchor(anchor.frame, window, anchor)
        }

        func schedule() {
            runtime.schedulePresentation(after: 0.3, isEnabled: { true }) { [weak self] _, _ in self?.shows += 1 }
        }
    }
}

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
