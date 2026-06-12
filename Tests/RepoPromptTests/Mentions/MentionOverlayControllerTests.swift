@testable import RepoPrompt
import XCTest

@MainActor
final class MentionOverlayControllerTests: XCTestCase {
    func testVisibleRowLimitDefaultsToFiveAndNormalizesInvalidValues() {
        let overlay = MentionOverlayController()

        XCTAssertEqual(overlay.visibleRowLimit, 5)

        let expandedVisibleRows = FileMentionPickerStyle.expanded.configuration.visibleRows
        overlay.visibleRowLimit = expandedVisibleRows
        XCTAssertEqual(overlay.visibleRowLimit, expandedVisibleRows)

        overlay.visibleRowLimit = 0
        XCTAssertEqual(overlay.visibleRowLimit, 1)

        overlay.visibleRowLimit = -4
        XCTAssertEqual(overlay.visibleRowLimit, 1)
    }

    func testHighlightedRowAddsOnlySelectedAccessibilityTrait() {
        XCTAssertEqual(
            MentionSuggestionRowView.accessibilityTraits(isHighlighted: true),
            .isSelected
        )
        XCTAssertEqual(
            MentionSuggestionRowView.accessibilityTraits(isHighlighted: false),
            []
        )
    }

    func testSuggestionWindowResizesForExpandedRowsWithoutMovingAnchorEdge() {
        let suggestions = (0 ..< 12).map { index in
            MentionSuggestion(
                displayName: "File\(index).swift",
                relativePath: "Sources/File\(index).swift",
                kind: .file
            )
        }

        for placement in [MentionOverlayController.Placement.above, .below] {
            let window = MentionOverlayController.SuggestionWindow(
                parent: nil,
                placement: placement
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.setFrame(NSRect(x: 40, y: 100, width: 240, height: 1), display: false)
            window.updateSuggestions(suggestions, highlighted: 0)
            let compactFrame = window.frame

            window.setVisibleRowLimit(FileMentionPickerConfiguration.expanded.visibleRows)
            let expandedFrame = window.frame

            XCTAssertGreaterThan(expandedFrame.height, compactFrame.height)
            XCTAssertEqual(expandedFrame.width, compactFrame.width)
            switch placement {
            case .above:
                XCTAssertEqual(expandedFrame.minY, compactFrame.minY)
            case .below:
                XCTAssertEqual(expandedFrame.maxY, compactFrame.maxY)
            }
        }
    }

    func testSuggestionWindowDisablesNativeShadowForRoundedPopup() {
        let window = MentionOverlayController.SuggestionWindow(
            parent: nil,
            placement: .below
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertFalse(
            window.hasShadow,
            "Native NSWindow shadows are rectangular and can show through around the rounded mention popup."
        )
    }

    func testExpandedRootFrameClampsToVisibleScreenArea() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = NSRect(x: 900, y: 10, width: 1, height: 18)
        let popupSize = NSSize(width: 480, height: 400)

        let frame = MentionOverlayController.positionedRootFrame(
            caret: caret,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.width, popupSize.width)
        XCTAssertEqual(frame.height, popupSize.height)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    func testRootFrameFlipsAboveWhenPreferredBelowSideDoesNotFit() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = NSRect(x: 400, y: 20, width: 1, height: 18)
        let popupSize = NSSize(width: 240, height: 200)

        let frame = MentionOverlayController.positionedRootFrame(
            caret: caret,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.minY, caret.maxY + 4)
        XCTAssertFalse(frame.intersects(caret))
    }

    func testRootFrameFlipsBelowWhenPreferredAboveSideDoesNotFit() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = NSRect(x: 400, y: 770, width: 1, height: 18)
        let popupSize = NSSize(width: 240, height: 200)

        let frame = MentionOverlayController.positionedRootFrame(
            caret: caret,
            popupSize: popupSize,
            placement: .above,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxY, caret.minY - 2)
        XCTAssertFalse(frame.intersects(caret))
    }

    func testNestedUnequalHeightLevelsStayOnResolvedFlippedSideOfCaret() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = NSRect(x: 400, y: 20, width: 1, height: 18)
        let owner = NSWindow(
            contentRect: visibleFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let overlay = MentionOverlayController()
        overlay.placement = .below
        overlay.visibleRowLimit = 12
        overlay.visibleFrameOverrideForTesting = visibleFrame
        defer {
            overlay.hide()
            owner.orderOut(nil)
        }

        overlay.show(at: caret, owner: owner, items: suggestions(count: 4))
        overlay.pushLevel()
        overlay.update(items: suggestions(count: 12), highlighted: 0)
        overlay.pushLevel()
        overlay.update(items: suggestions(count: 2), highlighted: 0)
        overlay.repositionRoot(to: caret)

        let frames = overlay.testWindowFrames
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(overlay.testWindowPlacements, [.above, .above, .above])
        XCTAssertNotEqual(frames[0].height, frames[1].height)
        XCTAssertNotEqual(frames[1].height, frames[2].height)
        for frame in frames {
            XCTAssertGreaterThan(frame.minY, caret.maxY)
            XCTAssertFalse(frame.intersects(caret))
        }
    }

    func testRootFrameUsesSideWithMoreVisibleAreaWhenNeitherSideFits() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        let caret = NSRect(x: 400, y: 80, width: 1, height: 18)
        let popupSize = NSSize(width: 240, height: 200)

        let frame = MentionOverlayController.positionedRootFrame(
            caret: caret,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxY, visibleFrame.maxY)
        XCTAssertGreaterThan(frame.minY, caret.minY)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
    }

    func testChildFrameOpensLeftWhenRightSideWouldOverflow() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let parentFrame = NSRect(x: 700, y: 300, width: 240, height: 240)
        let childSize = NSSize(width: 240, height: 240)

        let childFrame = MentionOverlayController.positionedChildFrame(
            after: parentFrame,
            popupSize: childSize,
            placement: .below,
            visibleFrame: visibleFrame
        )

        XCTAssertLessThan(childFrame.maxX, parentFrame.minX)
        XCTAssertGreaterThanOrEqual(childFrame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(childFrame.maxX, visibleFrame.maxX)
    }

    func testThreeLevelPlacementDoesNotOverlapEarlierLevelsAfterDirectionChange() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let popupSize = NSSize(width: 240, height: 240)
        let root = NSRect(x: 700, y: 300, width: popupSize.width, height: popupSize.height)
        let second = MentionOverlayController.positionedChildFrame(
            after: root,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame,
            avoiding: [root]
        )
        let third = MentionOverlayController.positionedChildFrame(
            after: second,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame,
            avoiding: [root, second]
        )

        XCTAssertFalse(second.intersects(root))
        XCTAssertFalse(third.intersects(root))
        XCTAssertFalse(third.intersects(second))
    }

    func testThreeExpandedLevelsChooseLowestOverlapAfterHorizontalClamping() throws {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let popupSize = NSSize(width: 480, height: 240)
        let root = NSRect(x: 520, y: 300, width: popupSize.width, height: popupSize.height)
        let second = MentionOverlayController.positionedChildFrame(
            after: root,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame,
            avoiding: [root]
        )
        let third = MentionOverlayController.positionedChildFrame(
            after: second,
            popupSize: popupSize,
            placement: .below,
            visibleFrame: visibleFrame,
            avoiding: [root, second]
        )

        let occupied = [root, second]
        let occupiedUnion = root.union(second)
        let candidateOrigins = [
            second.maxX + 4,
            second.minX - popupSize.width - 4,
            occupiedUnion.maxX + 4,
            occupiedUnion.minX - popupSize.width - 4
        ]
        let candidateFrames = candidateOrigins.map { x in
            MentionOverlayController.clampedFrame(
                NSRect(x: x, y: second.minY, width: popupSize.width, height: popupSize.height),
                to: visibleFrame
            )
        }
        let minimumCandidateOverlap = try XCTUnwrap(candidateFrames.map { overlapArea($0, with: occupied) }.min())

        XCTAssertEqual(overlapArea(third, with: occupied), minimumCandidateOverlap)
        XCTAssertEqual(overlapArea(third, with: [root]), 0)
        XCTAssertGreaterThan(overlapArea(third, with: [second]), 0)
        XCTAssertLessThan(overlapArea(third, with: [second]), popupSize.width * popupSize.height)
        XCTAssertGreaterThanOrEqual(third.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(third.maxX, visibleFrame.maxX)
    }

    private func suggestions(count: Int) -> [MentionSuggestion] {
        (0 ..< count).map { index in
            MentionSuggestion(
                displayName: "Item \(index)",
                relativePath: "Item\(index)",
                kind: .folder
            )
        }
    }

    private func overlapArea(_ frame: NSRect, with occupiedFrames: [NSRect]) -> CGFloat {
        occupiedFrames.reduce(0) { total, occupied in
            let intersection = frame.intersection(occupied)
            guard !intersection.isNull else { return total }
            return total + intersection.width * intersection.height
        }
    }

    func testScreenSelectionUsesCaretIntersectionInsteadOfOwnerScreen() {
        let firstVisible = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let secondVisible = NSRect(x: 1000, y: 0, width: 1000, height: 780)
        let screens = [
            MentionOverlayController.ScreenGeometry(
                frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: firstVisible
            ),
            MentionOverlayController.ScreenGeometry(
                frame: NSRect(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: secondVisible
            )
        ]

        XCTAssertEqual(
            MentionOverlayController.selectedVisibleFrame(
                for: NSRect(x: 1500, y: 300, width: 1, height: 18),
                screens: screens
            ),
            secondVisible
        )
        XCTAssertEqual(
            MentionOverlayController.selectedVisibleFrame(
                for: NSRect(x: 900, y: 300, width: 300, height: 18),
                screens: screens
            ),
            secondVisible
        )
    }
}
