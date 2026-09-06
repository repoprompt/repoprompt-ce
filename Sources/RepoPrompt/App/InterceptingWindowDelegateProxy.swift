import AppKit

@MainActor
final class InterceptingWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var windowState: WindowState?
    weak var forwardedDelegate: NSWindowDelegate?

    init(windowState: WindowState?, forwardedDelegate: NSWindowDelegate?) {
        self.windowState = windowState
        self.forwardedDelegate = forwardedDelegate
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let windowState else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        switch windowState.closeCoordinator.handleCloseAttempt(for: sender) {
        case .allow:
            // Set isClosing early to suppress @Published mutations before AppKit
            // sends focus/key events during close (fixes EXC_BAD_ACCESS in ObservationTracking).
            let shouldClose = forwardedDelegate?.windowShouldClose?(sender) ?? true
            if shouldClose {
                windowState.beginClose()
            }
            return shouldClose
        case .background, .confirm, .denyDuplicatePrompt:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        windowState?.closeCoordinator.windowWillClose()
        // Backstop: ensure beginClose is called even if windowShouldClose was bypassed.
        windowState?.beginClose()

        if let windowID = windowState?.windowID {
            MCPBackgroundModeCoordinator.shared.clearIfBackgroundedWindow(windowID: windowID)
        }
        forwardedDelegate?.windowWillClose?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let windowID = windowState?.windowID {
            MCPBackgroundModeCoordinator.shared.clearIfBackgroundedWindow(windowID: windowID)
        }
        forwardedDelegate?.windowDidBecomeKey?(notification)
    }

    @objc(windowDidOrderOffScreen:)
    func windowDidOrderOffScreen(_ notification: Notification) {
        // AppKit can cache this selector after SwiftUI releases its delegate.
        guard let forwardedDelegate else {
            return
        }

        let selector = #selector(InterceptingWindowDelegateProxy.windowDidOrderOffScreen(_:))
        guard forwardedDelegate.responds(to: selector) else {
            return
        }
        _ = forwardedDelegate.perform(selector, with: notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardedDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate
    }
}
