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

/// App-lifecycle controller that gates the **keyboard** ⌘Q quit gesture.
///
/// It installs a raw `NSEvent` **local** monitor on `.keyDown` / `.keyUp` /
/// `.flagsChanged`. On a keyboard ⌘Q `keyDown` with the toggle on it swallows
/// the event (returns `nil`) so the default "Quit RepoPrompt ⌘Q" menu key
/// equivalent never fires; it then runs a pure `QuitHoldDecision` state machine,
/// shows a non-focus-stealing overlay, and starts a hold timer. Menu / Dock /
/// status / programmatic quits never generate a keyboard `keyDown` for ⌘Q, so
/// they call `terminate(_:)` directly and bypass this gate entirely. On a
/// confirmed hold the controller calls `NSApp.terminate(nil)`, reusing the
/// existing async shutdown path unchanged (it does **not** touch
/// `applicationShouldTerminate`).
///
/// Per the spec's event-swallowing policy, the controller swallows a `keyDown`
/// based only on the toggle + exact-modifier match — *regardless* of the
/// `QuitHoldDecision` intent — so a repeated ⌘Q `keyDown` during a hold
/// (intent `.ignore`) is still swallowed (S-010). `keyUp` and `flagsChanged`
/// are never swallowed.
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
            let intent = decision.handle(.keyDown(toggleOn: true))
            handleKeyDownIntent(intent)
            return nil

        case .keyUp:
            // Only Q's keyUp breaks the hold (spec "held semantics"); any other
            // keyUp passes through untouched and does not cancel (S-002).
            if event.keyCode == QuitHoldEventFilter.quitKeyCode {
                let intent = decision.handle(.keyUp)
                if intent == .cancel { cancelHold() }
            }
            return event

        case .flagsChanged:
            let commandDown = event.modifierFlags.contains(.command)
            let intent = decision.handle(.flagsChanged(commandDown: commandDown))
            if intent == .cancel { cancelHold() }
            return event

        default:
            return event
        }
    }

    private func handleKeyDownIntent(_ intent: QuitHoldIntent) {
        switch intent {
        case let .beginHold(threshold):
            showOverlay()
            scheduleHoldTimer(threshold: threshold)
        case .ignore, .cancel, .quit:
            break
        }
    }

    /// The hold timer elapsed: if the decision commits to quit, dismiss the
    /// overlay and route through the normal shutdown path.
    private func handleTimerElapsed() {
        let intent = decision.handle(.timerElapsed)
        switch intent {
        case .quit:
            holdWorkItem = nil
            hideOverlay()
            NSApp.terminate(nil)
        case .cancel:
            cancelHold()
        case .ignore, .beginHold:
            break
        }
    }

    private func scheduleHoldTimer(threshold: TimeInterval) {
        holdWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // DispatchQueue.main.asyncAfter runs this on the main thread.
            MainActor.assumeIsolated { self?.handleTimerElapsed() }
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
    }

    private func cancelHold() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        hideOverlay()
    }

    // MARK: - Overlay

    private func showOverlay() {
        hideOverlay()

        let panel = QuitHoldPanel()
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(QuitHoldDecision.threshold)
        panel.contentView = NSHostingView(
            rootView: QuitHoldOverlayView(startDate: startDate, endDate: endDate)
        )
        positionOverlay(panel)
        overlayPanel = panel

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

    private func hideOverlay() {
        if let observer = ownerWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            ownerWillCloseObserver = nil
        }
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
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

/// "Hold ⌘Q to Quit" card with a determinate progress bar over the threshold.
private struct QuitHoldOverlayView: View {
    let startDate: Date
    let endDate: Date

    var body: some View {
        VStack(spacing: 10) {
            Text("Hold ⌘Q to Quit")
                .font(.headline)
            ProgressView(timerInterval: startDate ... endDate, countsDown: false)
        }
        .padding(16)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
