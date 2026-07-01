//
//  QuitHoldOverlay.swift
//  RepoPrompt
//
//  Non-focus-stealing AppKit overlay shown during a hold-⌘Q-to-quit gesture.
//  Owns the overlay panel, the linger/fade dismissal animation, and the
//  owner-window-close observer. Extracted from QuitHoldController to isolate
//  AppKit concerns from gesture orchestration.
//

import AppKit
import SwiftUI

// MARK: - Overlay

/// Owns the "Hold ⌘Q to Quit" / "Release ⌘Q to Quit" overlay panel and its
/// chrome-style linger → fade → hide dismissal.
///
/// The controller presents it via `show(message:onOwnerClose:)` (wiring the
/// owner-window-close callback to its external-cancellation path), swaps the
/// message via `update(_:)`, dismisses with a linger via `cancelWithLinger()`
/// on an early release, and tears it down immediately via `hide()` on a
/// confirmed quit or external cancel. `hide()` is the sole owner of
/// `lingerWorkItem` and the owner-close observer teardown.
@MainActor
final class QuitHoldOverlay {
    private var overlayPanel: QuitHoldPanel?
    private var ownerWillCloseObserver: NSObjectProtocol?
    /// Scheduled "dwell then fade" removal of the overlay after an early
    /// release; cancelled by `hide()` so a new hold or a confirmed quit still
    /// use the immediate-dismiss path.
    private var lingerWorkItem: DispatchWorkItem?
    /// Chrome-style overlay dismissal on early release: the message stays
    /// readable for `cancelLingerSeconds`, then fades over `cancelFadeSeconds`
    /// (~2s total) instead of vanishing instantly.
    private static let cancelLingerSeconds: TimeInterval = 1.7
    private static let cancelFadeSeconds: TimeInterval = 0.3

    /// Presents the overlay with `message`. `onOwnerClose` is invoked if the
    /// current key window (the anchor owner) closes while the overlay is shown;
    /// the controller wires it to its external-cancellation path. The observer
    /// is added here and removed in `hide()` (identical lifecycle to the inline
    /// form previously in QuitHoldController.showOverlay).
    func show(message: String, onOwnerClose: @escaping () -> Void) {
        hide()

        let panel = QuitHoldPanel()
        overlayPanel = panel
        configure(panel, message: message)

        if let owner = NSApp.keyWindow, owner.isVisible {
            ownerWillCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: owner,
                queue: .main
            ) { _ in
                // Runs on `.main`; the owner window is closing, so abort the
                // hold (reset state + dismiss overlay) — don't leave the gate
                // in a stale .holding/.armed state.
                MainActor.assumeIsolated { onOwnerClose() }
            }
        }

        panel.orderFrontRegardless()
    }

    /// Swaps the overlay's message (e.g. "Hold…" → "Release…") without
    /// dismissing it. No-op if no overlay is showing.
    func update(_ message: String) {
        guard let panel = overlayPanel else { return }
        configure(panel, message: message)
    }

    /// On early release, lingers the overlay at full opacity so the message is
    /// readable, then fades and removes it. No-op if no overlay is showing.
    func cancelWithLinger() {
        startCancelLinger()
    }

    /// Immediate teardown: cancels any in-flight linger/fade, removes the
    /// owner-close observer, and dismisses the panel.
    func hide() {
        lingerWorkItem?.cancel()
        lingerWorkItem = nil
        if let observer = ownerWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            ownerWillCloseObserver = nil
        }
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    private func configure(_ panel: QuitHoldPanel, message: String) {
        let hosting = NSHostingView(rootView: QuitHoldOverlayView(text: message))
        panel.contentView = hosting
        // Size the panel to the SwiftUI content's natural size (no fixed frame).
        let fit = hosting.fittingSize
        panel.setContentSize(NSSize(width: ceil(fit.width), height: ceil(fit.height)))
        positionOverlay(panel)
    }

    private func startCancelLinger() {
        guard let panel = overlayPanel else { return }
        lingerWorkItem?.cancel()
        let dwell = DispatchWorkItem { [weak self] in
            // DispatchQueue.main.asyncAfter runs this on the main thread.
            MainActor.assumeIsolated { self?.beginFadeOut(of: panel) }
        }
        lingerWorkItem = dwell
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelLingerSeconds, execute: dwell)
    }

    private func beginFadeOut(of panel: QuitHoldPanel) {
        lingerWorkItem = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.cancelFadeSeconds
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Runs on the main thread. Only remove this panel if it is still
            // current — a new hold started during the fade replaces it.
            MainActor.assumeIsolated {
                if self?.overlayPanel === panel {
                    self?.hide()
                }
            }
        }
    }

    private func positionOverlay(_ panel: NSPanel) {
        let size = panel.frame.size
        let anchor: NSRect = {
            if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
                return keyWindow.frame
            }
            return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }()
        panel.setFrameOrigin(NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2
        ))
    }
}

// MARK: - Overlay panel + SwiftUI view

/// Non-activating panel that can never become key/main, so it cannot steal
/// keyboard focus from the active window (S-008).
private final class QuitHoldPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 236, height: 96),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// "Hold ⌘Q to Quit" / "Release ⌘Q to Quit" card — text only (like Chrome).
private struct QuitHoldOverlayView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .semibold))
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }
}
