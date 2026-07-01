//
//  QuitHoldController.swift
//  RepoPrompt
//
//  Gates the keyboard ⌘Q quit gesture so a single tap no longer quits the app.
//

import AppKit
import SwiftUI

// MARK: - Pure event filter

/// Pure, side-effect-free policy that decides whether a keyboard `keyDown`
/// should be swallowed by the hold-⌘Q-to-quit gate.
///
/// A `keyDown` is swallowed **iff** the toggle is on, the key is Q
/// (`kVK_ANSI_Q == 0x0C`), and the modifier flags — after normalizing to the
/// device-independent bits and removing Caps Lock / numeric pad / Fn — equal
/// *exactly* `.command`. This is the exact-modifier-match rule from
/// `docs/spec/hold-to-quit.md`: ⌘Q is still recognized with Caps Lock / Fn /
/// numeric pad active, while ⌘⇧Q, ⌘⌥Q, ⌘⌃Q are **not** the gesture and pass
/// through untouched (which also protects ⌘W / ⇧⌘W).
///
/// This helper has no AppKit singleton or I/O coupling, so its full behavior is
/// unit-testable at the lowest faithful layer (see `QuitHoldEventFilterTests`).
enum QuitHoldEventFilter {
    /// Carbon `kVK_ANSI_Q`. Hard-coded to avoid importing Carbon.
    static let quitKeyCode: UInt16 = 0x0C

    /// Returns `true` when the given `keyDown` is an exact-modifier ⌘Q and the
    /// toggle is on (so the controller should swallow it); otherwise `false`.
    static func shouldSwallowKeyDown(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        toggleOn: Bool
    ) -> Bool {
        guard toggleOn, keyCode == quitKeyCode else { return false }
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return normalized == .command
    }
}

// MARK: - Controller

// App-lifecycle controller that gates the **keyboard** ⌘Q quit gesture.
//
// It installs a raw `NSEvent` **local** monitor on `.keyDown` / `.keyUp` /
// `.flagsChanged`. On a keyboard ⌘Q `keyDown` with the toggle on it swallows
// the event (returns `nil`) so the default "Quit RepoPrompt ⌘Q" menu key
// equivalent never fires; it then runs a pure `QuitHoldDecision` state machine,
// shows a non-focus-stealing overlay, and starts a hold timer. Menu / Dock /
// status / programmatic quits never generate a keyboard `keyDown` for ⌘Q, so
// they call `terminate(_:)` directly and bypass this gate entirely.
//
// **Quit timing (release-after-threshold):** reaching the 1.0s threshold while
// still holding ⌘Q only ARMS the quit (the overlay switches to "Release ⌘Q to
// Quit"). The actual `NSApp.terminate(nil)` is fired on ⌘Q `keyUp` / Command
// release AFTER the threshold, deferred one run-loop turn so the run loop is
// idle when terminate runs. Terminating while the key is still held wedges the
// shutdown: AppKit's `.terminateLater` wait plus sustained key-repeat delivery
// starves the Swift main-actor executor, so the shutdown `Task` never runs and
// `reply(true)` is never called. Quitting on release avoids that entirely and
// leaves the existing async shutdown path unchanged.
//
// Per the spec's event-swallowing policy, the controller swallows a `keyDown`
// based only on the toggle + exact-modifier match — *regardless* of the
// `QuitHoldDecision` intent — so a repeated ⌘Q `keyDown` during a hold
// (intent `.ignore`) is still swallowed (S-010). `keyUp` and `flagsChanged`
// are never swallowed.

@MainActor
final class QuitHoldController {
    /// The local `NSEvent` monitor token. `nonisolated(unsafe)` so `deinit` can
    /// remove it; every read/write happens on the main thread for this
    /// main-actor-owned, app-lifetime object.
    private nonisolated(unsafe) var monitor: Any?

    private var decision = QuitHoldDecision()
    private var holdWorkItem: DispatchWorkItem?
    private var overlayPanel: QuitHoldPanel?
    private var ownerWillCloseObserver: NSObjectProtocol?
    /// Scheduled "dwell then fade" removal of the overlay after an early
    /// release; cancelled by `hideOverlay()` so a new hold or a confirmed quit
    /// still use the immediate-dismiss path.
    private var lingerWorkItem: DispatchWorkItem?
    /// Chrome-style overlay dismissal on early release: the message stays
    /// readable for `cancelLingerSeconds`, then fades over `cancelFadeSeconds`
    /// (~2s total) instead of vanishing instantly.
    private static let cancelLingerSeconds: TimeInterval = 1.7
    private static let cancelFadeSeconds: TimeInterval = 0.3

    init() {}

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Lifecycle

    /// Installs the keyboard ⌘Q local monitor. Safe to call once.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event -> NSEvent? in
            // Local monitors run on the main thread, so bridge into the
            // @MainActor controller synchronously (precedent: TooltipBubble).
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // Swallow policy is independent of the decision intent: swallow iff
            // exact-modifier ⌘Q + toggle on (S-003 / S-010).
            let toggleOn = GlobalSettingsStore.shared.warnBeforeCmdQ()
            let swallow = QuitHoldEventFilter.shouldSwallowKeyDown(
                modifierFlags: event.modifierFlags,
                keyCode: event.keyCode,
                toggleOn: toggleOn
            )
            guard swallow else { return event }
            apply(decision.handle(.keyDown(toggleOn: true)))
            return nil

        case .keyUp:
            // Only Q's keyUp is a release signal (spec "held semantics"); any
            // other keyUp passes through untouched (S-002).
            if event.keyCode == QuitHoldEventFilter.quitKeyCode {
                apply(decision.handle(.keyUp))
            }
            return event

        case .flagsChanged:
            apply(decision.handle(.flagsChanged(commandDown: event.modifierFlags.contains(.command))))
            return event

        default:
            return event
        }
    }

    /// Translates a decision intent into side effects.
    private func apply(_ intent: QuitHoldIntent) {
        switch intent {
        case let .beginHold(threshold):
            showOverlay(message: "Hold ⌘Q to Quit")
            scheduleHoldTimer(threshold: threshold)
        case .arm:
            // Threshold reached while still holding: arm the quit and prompt
            // release. Do NOT terminate here (see class doc).
            updateOverlayMessage("Release ⌘Q to Quit")
        case .cancel:
            cancelHold()
        case .quit:
            fireTermination()
        case .ignore:
            break
        }
    }

    private func scheduleHoldTimer(threshold: TimeInterval) {
        holdWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // DispatchQueue.main.asyncAfter runs this on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.decision.handle(.timerElapsed))
            }
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
    }

    /// Release after the threshold: dismiss the overlay and route through the
    /// normal shutdown path one run-loop turn later (run loop idle → the
    /// shutdown Task drains cleanly).
    private func fireTermination() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        lingerWorkItem?.cancel()
        lingerWorkItem = nil
        hideOverlay()
        // Call terminate SYNCHRONOUSLY here. This runs inside the local NSEvent
        // monitor closure, which AppKit invokes during sendEvent — the same
        // dispatch context the menu/Apple-Event quit paths use, and the only
        // context in which terminateLater's shutdown Task reliably drains.
        // Deferring to a DispatchQueue callback left the app wedged in
        // terminateLater (the Task body never serviced).
        NSApp.terminate(nil)
    }

    private func cancelHold() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        // Chrome-style: keep the overlay readable for a beat on early release,
        // then fade it out instead of dismissing it instantly.
        startCancelLinger()
    }

    // MARK: - Overlay

    private func showOverlay(message: String) {
        hideOverlay()

        let panel = QuitHoldPanel()
        overlayPanel = panel
        configure(panel, message: message)

        if let owner = NSApp.keyWindow, owner.isVisible {
            ownerWillCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: owner,
                queue: .main
            ) { [weak self] _ in
                // Runs on `.main`, so bridge into the main actor.
                MainActor.assumeIsolated { self?.cancelHold() }
            }
        }

        panel.orderFrontRegardless()
    }

    /// Swaps the overlay's message (e.g. "Hold…" → "Release…") without
    /// dismissing it. No-op if no overlay is showing.
    private func updateOverlayMessage(_ message: String) {
        guard let panel = overlayPanel else { return }
        configure(panel, message: message)
    }

    private func configure(_ panel: QuitHoldPanel, message: String) {
        let hosting = NSHostingView(rootView: QuitHoldOverlayView(text: message))
        panel.contentView = hosting
        // Size the panel to the SwiftUI content's natural size (no fixed frame).
        let fit = hosting.fittingSize
        panel.setContentSize(NSSize(width: ceil(fit.width), height: ceil(fit.height)))
        positionOverlay(panel)
    }

    private func hideOverlay() {
        lingerWorkItem?.cancel()
        lingerWorkItem = nil
        if let observer = ownerWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            ownerWillCloseObserver = nil
        }
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    /// On early release, lingers the overlay at full opacity so the message is
    /// readable, then fades and removes it. No-op if no overlay is showing.
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
                    self?.hideOverlay()
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
