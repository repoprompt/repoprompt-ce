//  AnchorGeometryView.swift
//  RepoPrompt
//
//  Provides the anchor rect (in window coordinates) & owning window.
//  Updated to coalesce and defer geometry reporting to prevent infinite layout loops.

import AppKit
import SwiftUI

struct AnchorGeometryView: NSViewRepresentable {
    typealias UpdateCallback = (_ frameInWindow: NSRect, _ window: NSWindow?) -> Void

    /// Bump this value to force `updateNSView` → `scheduleReport()` even when the view's
    /// own layout doesn't change (e.g. when inside a SwiftUI ScrollView where scrolling
    /// updates ancestor bounds, not this view's layout).
    let refreshID: UInt64
    let onUpdate: UpdateCallback

    init(refreshID: UInt64 = 0, onUpdate: @escaping UpdateCallback) {
        self.refreshID = refreshID
        self.onUpdate = onUpdate
    }

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(callback: onUpdate)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        _ = refreshID // keep as an explicit diffing input
        nsView.callback = onUpdate
        nsView.scheduleReport() // async + coalesced (no synchronous report here)
    }

    // MARK: – Private NSView subclass

    final class TrackingView: NSView {
        var callback: UpdateCallback

        private var reportScheduled = false
        private weak var lastWindow: NSWindow?
        private var lastFrameInWindow: NSRect = .null

        init(callback: @escaping UpdateCallback) {
            self.callback = callback
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        /// Ensure this view never intercepts mouse events
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReport()
        }

        func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true

            // Defer out of the current layout pass to avoid re-entrant layout → SwiftUI update → layout loops.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reportScheduled = false
                reportNowIfNeeded()
            }
        }

        private func reportNowIfNeeded() {
            guard let win = window else { return }

            var frameInWin = convert(bounds, to: nil)
            frameInWin = normalizeToDevicePixels(frameInWin, in: win)

            let windowChanged = (lastWindow !== win)
            let frameChanged = !rectApproximatelyEqual(frameInWin, lastFrameInWindow, epsilon: deviceEpsilon(in: win))

            guard windowChanged || frameChanged else { return }

            lastWindow = win
            lastFrameInWindow = frameInWin
            callback(frameInWin, win)
        }

        private func deviceEpsilon(in window: NSWindow) -> CGFloat {
            let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            return 1.0 / scale
        }

        private func normalizeToDevicePixels(_ rect: NSRect, in window: NSWindow) -> NSRect {
            let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            func rp(_ v: CGFloat) -> CGFloat {
                (v * scale).rounded() / scale
            }
            return NSRect(
                x: rp(rect.origin.x),
                y: rp(rect.origin.y),
                width: rp(rect.size.width),
                height: rp(rect.size.height)
            )
        }

        private func rectApproximatelyEqual(_ a: NSRect, _ b: NSRect, epsilon: CGFloat) -> Bool {
            guard !b.isNull else { return false }
            return abs(a.origin.x - b.origin.x) < epsilon
                && abs(a.origin.y - b.origin.y) < epsilon
                && abs(a.size.width - b.size.width) < epsilon
                && abs(a.size.height - b.size.height) < epsilon
        }
    }
}
