import AppKit
import SwiftUI

/// Thin UI layer that renders the floating suggestion popup.
/// Owns *only* view-code; no model / search / navigation logic.
@MainActor
final class MentionOverlayController {
    enum Placement {
        case above
        case below
    }

    typealias ScreenGeometry = ScreenGeometrySnapshot

    struct RootPlacementResult: Equatable {
        let frame: NSRect
        let placement: Placement
    }

    var placement: Placement = .below
    var onRowClicked: ((_ level: Int, _ index: Int) -> Void)?
    var suggestedWidth: CGFloat = 240
    var visibleRowLimit: Int = 5 {
        didSet {
            let normalizedLimit = Self.normalizedVisibleRowLimit(visibleRowLimit)
            if visibleRowLimit != normalizedLimit {
                visibleRowLimit = normalizedLimit
            }
            for window in windows {
                window.setVisibleRowLimit(normalizedLimit)
            }
            enforceScreenBounds()
        }
    }

    /// Remember latest caret rect so we can re-anchor after every resize.
    private var latestCaretRect: NSRect?
    private var resolvedPlacement: Placement?

    // MARK: – Public API -----------------------------------------------------

    /// Show a brand-new overlay near `caret` with an initial set of items
    /// and attach it to `owner` so it closes/moves with the parent window.
    func show(
        at caret: NSRect,
        owner: NSWindow,
        items: [MentionSuggestion]
    ) {
        prepareRootWindowIfNeeded(owner: owner)
        guard let root = windows.first else { return }

        latestCaretRect = caret
        enforceScreenBounds()

        root.orderFront(nil)
        root.alphaValue = 1
        update(items: items, highlighted: 0)
    }

    /// Re-aligns the root window to the current caret (call after each resize
    /// or when the caret moved horizontally while typing).
    func repositionRoot(to caret: NSRect) {
        latestCaretRect = caret
        enforceScreenBounds()
    }

    /// Replace the list of rows in the *current* level.
    func update(items: [MentionSuggestion], highlighted: Int) {
        guard let win = windows.last else { return }
        win.updateSuggestions(items, highlighted: highlighted)
        enforceScreenBounds()
    }

    /// Move selection by ±delta in the *current* level.
    func moveHighlight(by delta: Int) {
        windows.last?.moveHighlight(delta: delta)
    }

    /// Push a new level (drill-down into folder). Automatically positioned.
    func pushLevel() {
        guard let previous = windows.last else { return }
        let w = SuggestionWindow(
            parent: previous.parentTextView,
            placement: resolvedPlacement ?? placement,
            width: suggestedWidth,
            visibleRowLimit: Self.normalizedVisibleRowLimit(visibleRowLimit)
        )
        wireRowClick(for: w)
        windows.append(w)
        chainWindow(w, after: previous)
        enforceScreenBounds()
    }

    /// Pop the deepest overlay level (go up one folder).
    func popLevel() {
        guard windows.count > 1 else { return }
        let win = windows.removeLast()
        win.orderOut(nil)
        win.parent?.removeChildWindow(win)
    }

    /// Close *all* overlay windows.
    func hide() {
        for w in windows {
            w.orderOut(nil)
            w.parent?.removeChildWindow(w)
        }
        windows.removeAll()
        ownerWindow = nil
        latestCaretRect = nil
        resolvedPlacement = nil
    }

    // MARK: – Private --------------------------------------------------------

    private weak var ownerWindow: NSWindow?
    private var windows: [SuggestionWindow] = []

    private func prepareRootWindowIfNeeded(owner: NSWindow) {
        guard windows.isEmpty else { return }
        ownerWindow = owner
        let root = SuggestionWindow(
            parent: nil,
            placement: placement,
            width: suggestedWidth,
            visibleRowLimit: Self.normalizedVisibleRowLimit(visibleRowLimit)
        )
        wireRowClick(for: root)
        owner.addChildWindow(root, ordered: .above)
        windows.append(root)
    }

    private static func normalizedVisibleRowLimit(_ limit: Int) -> Int {
        max(limit, 1)
    }

    static func positionedRootFrame(
        caret: NSRect,
        popupSize: NSSize,
        placement: Placement,
        visibleFrame: NSRect?
    ) -> NSRect {
        resolvedRootPlacement(
            caret: caret,
            popupSize: popupSize,
            placement: placement,
            visibleFrame: visibleFrame
        ).frame
    }

    static func resolvedRootPlacement(
        caret: NSRect,
        popupSize: NSSize,
        placement: Placement,
        visibleFrame: NSRect?
    ) -> RootPlacementResult {
        let preferred = rootFrame(caret: caret, popupSize: popupSize, placement: placement)
        guard let visibleFrame else {
            return RootPlacementResult(frame: preferred, placement: placement)
        }

        if fitsVertically(preferred, in: visibleFrame) {
            return RootPlacementResult(
                frame: clampedFrame(preferred, to: visibleFrame),
                placement: placement
            )
        }

        let alternatePlacement: Placement = placement == .above ? .below : .above
        let alternate = rootFrame(caret: caret, popupSize: popupSize, placement: alternatePlacement)
        if fitsVertically(alternate, in: visibleFrame) {
            return RootPlacementResult(
                frame: clampedFrame(alternate, to: visibleFrame),
                placement: alternatePlacement
            )
        }

        let preferredArea = visibleIntersectionArea(preferred, visibleFrame)
        let alternateArea = visibleIntersectionArea(alternate, visibleFrame)
        if alternateArea > preferredArea {
            return RootPlacementResult(
                frame: clampedFrame(alternate, to: visibleFrame),
                placement: alternatePlacement
            )
        }
        return RootPlacementResult(
            frame: clampedFrame(preferred, to: visibleFrame),
            placement: placement
        )
    }

    static func positionedChildFrame(
        after previousFrame: NSRect,
        popupSize: NSSize,
        placement: Placement,
        visibleFrame: NSRect?,
        avoiding occupiedFrames: [NSRect] = []
    ) -> NSRect {
        let verticalOrigin = placement == .above
            ? previousFrame.minY
            : previousFrame.maxY - popupSize.height
        let gap: CGFloat = 4
        let occupied = occupiedFrames.isEmpty ? [previousFrame] : occupiedFrames
        let occupiedUnion = occupied.dropFirst().reduce(occupied[0]) { $0.union($1) }
        let candidateXPositions = [
            previousFrame.maxX + gap,
            previousFrame.minX - popupSize.width - gap,
            occupiedUnion.maxX + gap,
            occupiedUnion.minX - popupSize.width - gap
        ]

        var candidates: [NSRect] = []
        for x in candidateXPositions {
            let candidate = clampedFrame(
                NSRect(
                    x: x,
                    y: verticalOrigin,
                    width: popupSize.width,
                    height: popupSize.height
                ),
                to: visibleFrame
            )
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        return candidates.enumerated().min { lhs, rhs in
            let leftOverlap = overlapArea(lhs.element, frames: occupied)
            let rightOverlap = overlapArea(rhs.element, frames: occupied)
            return leftOverlap == rightOverlap ? lhs.offset < rhs.offset : leftOverlap < rightOverlap
        }?.element ?? clampedFrame(NSRect(origin: .zero, size: popupSize), to: visibleFrame)
    }

    static func selectedVisibleFrame(
        for caret: NSRect,
        screens: [ScreenGeometry]
    ) -> NSRect? {
        ScreenVisibleFrameResolver.selectedVisibleFrame(for: caret, screens: screens)
    }

    static func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame else { return frame }
        var clamped = frame

        if clamped.width <= visibleFrame.width {
            clamped.origin.x = min(max(clamped.minX, visibleFrame.minX), visibleFrame.maxX - clamped.width)
        } else {
            clamped.origin.x = visibleFrame.minX
        }

        return clampedVertically(clamped, to: visibleFrame)
    }

    private static func rootFrame(
        caret: NSRect,
        popupSize: NSSize,
        placement: Placement
    ) -> NSRect {
        let origin = switch placement {
        case .above:
            NSPoint(x: caret.minX, y: caret.maxY + 4)
        case .below:
            NSPoint(x: caret.minX, y: caret.minY - 2 - popupSize.height)
        }
        return NSRect(origin: origin, size: popupSize)
    }

    private static func fitsVertically(_ frame: NSRect, in visibleFrame: NSRect) -> Bool {
        frame.minY >= visibleFrame.minY && frame.maxY <= visibleFrame.maxY
    }

    private static func clampedVertically(_ frame: NSRect, to visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame else { return frame }
        var clamped = frame
        if clamped.height <= visibleFrame.height {
            clamped.origin.y = min(max(clamped.minY, visibleFrame.minY), visibleFrame.maxY - clamped.height)
        } else {
            clamped.origin.y = visibleFrame.minY
        }
        return clamped
    }

    private static func overlapArea(_ frame: NSRect, frames: [NSRect]) -> CGFloat {
        frames.reduce(0) { $0 + visibleIntersectionArea(frame, $1) }
    }

    private static func visibleIntersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(intersection.width, 0) * max(intersection.height, 0)
    }

    private func chainWindow(_ w: SuggestionWindow, after prev: NSWindow) {
        let parentWin = prev.parent ?? prev
        let childPlacement = resolvedPlacement ?? placement
        parentWin.addChildWindow(w, ordered: .above)
        w.orderFront(nil)
        w.setPlacement(childPlacement)
        w.setFrame(
            Self.positionedChildFrame(
                after: prev.frame,
                popupSize: w.frame.size,
                placement: childPlacement,
                visibleFrame: visibleFrame,
                avoiding: windows.dropLast().map(\.frame)
            ),
            display: true
        )
        w.alphaValue = 1
    }

    private func wireRowClick(for window: SuggestionWindow) {
        window.onRowClicked = { [weak self, weak window] index in
            guard let self, let window,
                  let level = windows.firstIndex(where: { $0 === window })
            else { return }
            popToLevel(level)
            onRowClicked?(level, index)
        }
    }

    private func popToLevel(_ level: Int) {
        guard windows.indices.contains(level) else { return }
        while windows.count > level + 1 {
            let window = windows.removeLast()
            window.orderOut(nil)
            window.parent?.removeChildWindow(window)
        }
    }

    private var visibleFrame: NSRect? {
        #if DEBUG
            if let visibleFrameOverrideForTesting {
                return visibleFrameOverrideForTesting
            }
        #endif
        if let caret = latestCaretRect,
           let selected = Self.selectedVisibleFrame(
               for: caret,
               screens: NSScreen.screens.map {
                   ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
               }
           )
        {
            return selected
        }
        return ownerWindow?.screen?.visibleFrame
    }

    #if DEBUG
        var visibleFrameOverrideForTesting: NSRect?

        var testWindowCount: Int {
            windows.count
        }

        var testWindowFrames: [NSRect] {
            windows.map(\.frame)
        }

        var testWindowPlacements: [Placement] {
            windows.map(\.placement)
        }

        func clickRowForTesting(level: Int, index: Int) {
            guard windows.indices.contains(level) else { return }
            windows[level].clickRowForTesting(index)
        }
    #endif

    private func enforceScreenBounds() {
        guard !windows.isEmpty else { return }
        if let root = windows.first,
           let caret = latestCaretRect
        {
            let result = Self.resolvedRootPlacement(
                caret: caret,
                popupSize: root.frame.size,
                placement: placement,
                visibleFrame: visibleFrame
            )
            resolvedPlacement = result.placement
            root.setPlacement(result.placement)
            root.setFrame(result.frame, display: true)
        }

        guard windows.count > 1 else { return }
        let childPlacement = resolvedPlacement ?? placement
        for idx in 1 ..< windows.count {
            let previous = windows[idx - 1]
            let current = windows[idx]
            current.setPlacement(childPlacement)
            current.setFrame(
                Self.positionedChildFrame(
                    after: previous.frame,
                    popupSize: current.frame.size,
                    placement: childPlacement,
                    visibleFrame: visibleFrame,
                    avoiding: windows[..<idx].map(\.frame)
                ),
                display: true
            )
        }
    }
}

// ==========================================================================
// MARK: – SwiftUI-backed suggestion window

// ==========================================================================

extension MentionOverlayController {
    /// Borderless floating window that hosts a SwiftUI `MentionSuggestionListView`
    /// via `NSHostingView`, rendered on top of an `NSVisualEffectView` for the
    /// system vibrancy / popover material.
    final class SuggestionWindow: NSWindow {
        weak var parentTextView: MentionTextView?
        private(set) var placement: MentionOverlayController.Placement

        // SwiftUI bridge
        private let model = MentionSuggestionListModel()
        private var hostingView: NSHostingView<MentionSuggestionListView>?
        var onRowClicked: ((Int) -> Void)?

        // MARK: – Init

        private var visibleRowLimit: Int

        init(
            parent: MentionTextView?,
            placement: MentionOverlayController.Placement,
            width: CGFloat = 240,
            visibleRowLimit: Int = 5
        ) {
            parentTextView = parent
            self.placement = placement
            self.visibleRowLimit = MentionOverlayController.normalizedVisibleRowLimit(visibleRowLimit)
            let rect = NSRect(x: 0, y: 0, width: width, height: 1)
            super.init(
                contentRect: rect,
                styleMask: .borderless,
                backing: .buffered,
                defer: true
            )

            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            level = .floating

            // Vibrancy background -----------------------------------------------
            let visualEffect = NSVisualEffectView(frame: rect)
            visualEffect.material = .popover
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = 8
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 0.5
            visualEffect.layer?.borderColor = NSColor.separatorColor.cgColor

            // SwiftUI content ---------------------------------------------------
            model.visibleRowLimit = self.visibleRowLimit
            let listView = MentionSuggestionListView(model: model)
            let hosting = NSHostingView(rootView: listView)
            hosting.frame = visualEffect.bounds
            hosting.autoresizingMask = [.width, .height]

            // Ensure the hosting view is transparent so the vibrancy material
            // shines through behind the SwiftUI content.
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor

            visualEffect.addSubview(hosting)
            hostingView = hosting

            contentView = visualEffect

            // Wire up mouse click → highlight update
            model.onRowClicked = { [weak self] index in
                guard let self else { return }
                model.highlightedIndex = index
                onRowClicked?(index)
            }
        }

        // MARK: – Public helpers

        func updateSuggestions(_ items: [MentionSuggestion], highlighted: Int) {
            let rowCountForSizing = max(items.count, 1)

            // Always re-apply sizing, even when model values are unchanged.
            // This avoids a 1px-tall popup when the first update contains an
            // empty result set (e.g. slash-command query with no matching skills).
            if model.suggestions != items || model.highlightedIndex != highlighted {
                model.suggestions = items
                model.highlightedIndex = highlighted
            }

            resizeWindow(for: rowCountForSizing)
        }

        func moveHighlight(delta: Int) {
            guard !model.suggestions.isEmpty else { return }
            model.highlightedIndex = (model.highlightedIndex + delta + model.suggestions.count)
                % model.suggestions.count
        }

        func setPlacement(_ placement: MentionOverlayController.Placement) {
            self.placement = placement
        }

        func setVisibleRowLimit(_ limit: Int) {
            visibleRowLimit = MentionOverlayController.normalizedVisibleRowLimit(limit)
            model.visibleRowLimit = visibleRowLimit
            resizeWindow(for: max(model.suggestions.count, 1))
        }

        #if DEBUG
            func clickRowForTesting(_ index: Int) {
                model.onRowClicked?(index)
            }
        #endif

        // MARK: – Layout

        private func resizeWindow(for itemCount: Int) {
            let visibleRows = min(itemCount, visibleRowLimit)
            let rowH = FontScalePreset.current.rowHeight + 4
            // 4pt padding top/bottom inside the VStack, plus 2pt spacing per gap
            let spacing = max(CGFloat(visibleRows - 1), 0) * 2
            let height = 4 + CGFloat(visibleRows) * rowH + spacing + 4
            var f = frame

            if placement == .below {
                let topY = f.maxY
                f.size.height = height
                f.origin.y = topY - height
            } else {
                f.size.height = height
            }

            setFrame(f, display: true)
        }
    }
}
