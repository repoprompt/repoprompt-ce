//
//  QuitHoldController.swift
//  RepoPrompt
//
//  Gates the keyboard ⌘Q quit gesture so a single tap no longer quits the app.
//

import AppKit

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
// The controller owns gesture orchestration only — the overlay panel, its
// linger/fade dismissal, and the owner-window-close observer live in
// `QuitHoldOverlay`.
//
// **Quit timing (release-after-threshold):** reaching the 1.0s threshold while
// still holding ⌘Q only ARMS the quit (the overlay switches to "Release ⌘Q to
// Quit"). The actual `NSApp.terminate(nil)` is fired SYNCHRONOUSLY on ⌘Q
// `keyUp` / Command release AFTER the threshold, from within this monitor's
// event handler (i.e., during AppKit's `sendEvent`). It must NOT be deferred
// to a `DispatchQueue` callback: AppKit's `.terminateLater` wait then starves
// the Swift main-actor executor, the shutdown `Task` never runs, and
// `reply(true)` is never called (the app wedges). Calling terminate during
// `sendEvent` — like the menu and Apple-Event quit paths — drains cleanly and
// leaves the existing async shutdown path unchanged.
//
// **External cancellation:** if the owner window closes or the app resigns
// active mid-hold, an `.externalCancel` event resets the decision to `idle`
// and dismisses the overlay immediately (no linger), so a later ⌘Q can't arm
// or quit from stale `.holding`/`.armed` state.
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
    /// Current gesture phase (inspection/test seam).
    var holdState: QuitHoldDecision.State {
        decision.state
    }

    private var holdWorkItem: DispatchWorkItem?
    /// App-lifetime observer that aborts an in-flight hold when the app loses
    /// focus (the local key monitor won't see the keyUp then).
    private var resignActiveObserver: NSObjectProtocol?

    private let overlay = QuitHoldOverlay()

    private let warnBeforeCmdQ: @MainActor () -> Bool

    init(warnBeforeCmdQ: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.warnBeforeCmdQ() }) {
        self.warnBeforeCmdQ = warnBeforeCmdQ
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
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
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Runs on `.main`; abort any in-flight hold so state can't get
            // stuck when the keyUp is never delivered (app no longer frontmost).
            MainActor.assumeIsolated { self?.handleExternalCancellation() }
        }
    }

    // MARK: - Event handling

    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // Swallow policy is independent of the decision intent: swallow iff
            // exact-modifier ⌘Q + toggle on (S-003 / S-010).
            let toggleOn = warnBeforeCmdQ()
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

    /// External condition (owner window closed / app resigned active): feed
    /// an `.externalCancel` so the decision resets to idle and the overlay is
    /// dismissed immediately (no linger). The resign-active observer and the
    /// overlay's owner-close observer call this; tests call it directly as the
    /// lifecycle seam.
    func handleExternalCancellation() {
        apply(decision.handle(.externalCancel))
    }

    /// Translates a decision intent into side effects.
    private func apply(_ intent: QuitHoldIntent) {
        switch intent {
        case let .beginHold(threshold):
            overlay.show(message: "Hold ⌘Q to Quit") { [weak self] in
                self?.handleExternalCancellation()
            }
            scheduleHoldTimer(threshold: threshold)
        case .arm:
            // Threshold reached while still holding: arm the quit and prompt
            // release. Do NOT terminate here (see class doc).
            overlay.update("Release ⌘Q to Quit")
        case .cancel:
            cancelHold()
        case .quit:
            fireTermination()
        case .dismiss:
            // External cancellation (owner window closed / app resigned active):
            // state was already reset to idle by the decision; tear down the
            // overlay immediately — no linger.
            cancelHoldTimer()
            overlay.hide()
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

    /// Sole owner of `holdWorkItem` teardown; `overlay.hide()` owns the overlay
    /// + linger teardown. Cancels and nils the in-flight hold timer.
    private func cancelHoldTimer() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }

    /// Release after the threshold: dismiss the overlay and call
    /// `NSApp.terminate(nil)` SYNCHRONOUSLY (during `sendEvent` — see class
    /// doc) so the normal shutdown path drains cleanly.
    private func fireTermination() {
        cancelHoldTimer()
        overlay.hide()
        // Call terminate SYNCHRONOUSLY here. This runs inside the local NSEvent
        // monitor closure, which AppKit invokes during sendEvent — the same
        // dispatch context the menu/Apple-Event quit paths use, and the only
        // context in which terminateLater's shutdown Task reliably drains.
        // Deferring to a DispatchQueue callback left the app wedged in
        // terminateLater (the Task body never serviced).
        NSApp.terminate(nil)
    }

    private func cancelHold() {
        cancelHoldTimer()
        // Chrome-style: keep the overlay readable for a beat on early release,
        // then fade it out instead of dismissing it instantly.
        overlay.cancelWithLinger()
    }
}
