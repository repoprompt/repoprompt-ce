import AppKit

/// A value snapshot keeps the presentation policy testable independently of
/// activation, Spaces, cursor location, and visible AppKit windows.
struct TooltipPresentationEligibility {
    var windowVisible: Bool
    var windowKey: Bool
    var wasKey: Bool
    var appActive: Bool
    var onActiveSpace: Bool
    var pointerInside: Bool
    var miniaturized: Bool
    var hasSheet: Bool
    var tooltipsEnabled: Bool

    var allowsPresentation: Bool {
        windowVisible && (windowKey || !wasKey) && appActive && onActiveSpace
            && pointerInside && !miniaturized && !hasSheet && tooltipsEnabled
    }

    static func pointerIsInside(trackingWindow: NSWindow?, owner: NSWindow, visibleRect: NSRect, mouseLocation: NSPoint) -> Bool {
        trackingWindow === owner && !visibleRect.isEmpty && visibleRect.contains(mouseLocation)
    }

    @MainActor
    static func capture(owner: NSWindow, wasKey: Bool, trackingView: NSView?) -> Self {
        let pointerInside: Bool
        if let trackingView, trackingView.window === owner {
            let rect = trackingView.convert(trackingView.visibleRect, to: nil)
            pointerInside = pointerIsInside(trackingWindow: trackingView.window, owner: owner, visibleRect: rect, mouseLocation: owner.mouseLocationOutsideOfEventStream)
        } else {
            pointerInside = false
        }
        return Self(
            windowVisible: owner.isVisible,
            windowKey: owner.isKeyWindow,
            wasKey: wasKey,
            appActive: NSApp?.isActive == true,
            onActiveSpace: owner.isOnActiveSpace,
            pointerInside: pointerInside,
            miniaturized: owner.isMiniaturized,
            hasSheet: owner.attachedSheet != nil,
            tooltipsEnabled: true
        )
    }
}

/// Reference-owned lifecycle wiring shared by the modifier and deterministic
/// tests. Geometry and dismissal never publish SwiftUI state during layout.
@MainActor
final class TooltipHoverRuntime {
    struct EventMonitoring {
        var addLocal: (@escaping () -> Void) -> Any?
        var addGlobal: (@escaping () -> Void) -> Any?
        var remove: (Any) -> Void

        static var live: Self {
            let masks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            return Self(
                addLocal: { dismiss in
                    NSEvent.addLocalMonitorForEvents(matching: masks.union(.keyDown)) { event in
                        dismiss()
                        return event
                    }
                },
                addGlobal: { dismiss in
                    NSEvent.addGlobalMonitorForEvents(matching: masks) { _ in dismiss() }
                },
                remove: { NSEvent.removeMonitor($0) }
            )
        }
    }

    private let pendingPresentation: TooltipPendingPresentation
    private let eventMonitoring: EventMonitoring
    private let captureEligibility: (NSWindow, Bool, NSView?) -> TooltipPresentationEligibility
    private var pendingReposition: DispatchWorkItem?
    private let pendingRepositionGate = WorkItemGate()
    private var overlayController: TooltipOverlayController?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorRect: NSRect = .zero
    private weak var anchorWindow: NSWindow?
    private weak var trackingView: NSView?

    init(
        pendingPresentation: TooltipPendingPresentation? = nil,
        eventMonitoring: EventMonitoring? = nil,
        captureEligibility: ((NSWindow, Bool, NSView?) -> TooltipPresentationEligibility)? = nil
    ) {
        self.pendingPresentation = pendingPresentation ?? TooltipPendingPresentation()
        self.eventMonitoring = eventMonitoring ?? .live
        self.captureEligibility = captureEligibility ?? TooltipPresentationEligibility.capture
    }

    func updateAnchor(_ rect: NSRect, _ window: NSWindow?, _ view: NSView) {
        pendingPresentation.updateOwner(window)
        if overlayController != nil, anchorWindow !== window || window == nil {
            hideOverlay()
        }
        anchorRect = rect
        anchorWindow = window
        trackingView = view
        guard overlayController != nil else { return }
        cancelPendingReposition()
        pendingReposition = pendingRepositionGate.schedule { [weak self] in
            self?.overlayController?.reposition(to: rect)
        }
    }

    func schedulePresentation(
        after delay: TimeInterval,
        isEnabled: @escaping () -> Bool,
        show: @escaping (NSWindow, NSRect) -> Void
    ) {
        pendingPresentation.cancel()
        // Only local input matters before presentation. Global dismissal is
        // installed only for the lifetime of an actually visible tooltip.
        installDismissMonitors(includeGlobal: false)
        pendingPresentation.schedule(owner: anchorWindow, after: delay, isEligible: { [weak self] owner, wasKey in
            guard let self, anchorWindow === owner, trackingView?.window === owner else { return false }
            var eligibility = captureEligibility(owner, wasKey, trackingView)
            eligibility.tooltipsEnabled = isEnabled()
            return eligibility.allowsPresentation
        }, onEnd: { [weak self] in
            self?.removeDismissMonitors()
        }) { [weak self] in
            guard let self, let owner = anchorWindow else { return }
            hideOverlay()
            show(owner, anchorRect)
            installDismissMonitors(includeGlobal: true)
        }
    }

    func showOverlay(content: TooltipContent, owner: NSWindow, rect: NSRect, placement: TooltipPlacement, preset: FontScalePreset) {
        let controller = TooltipOverlayController()
        controller.show(content: content, anchorRect: rect, owner: owner, placement: placement, preset: preset)
        overlayController = controller
    }

    func cleanup(resetContext: Bool = false) {
        pendingPresentation.cancel()
        hideOverlay()
        if resetContext {
            anchorRect = .zero
            anchorWindow = nil
            trackingView = nil
        }
    }

    private func cancelPendingReposition() {
        pendingReposition?.cancel()
        pendingReposition = nil
        pendingRepositionGate.cancel()
    }

    private func hideOverlay() {
        cancelPendingReposition()
        overlayController?.hide()
        overlayController = nil
        removeDismissMonitors()
    }

    private func installDismissMonitors(includeGlobal: Bool) {
        if localMonitor == nil {
            localMonitor = eventMonitoring.addLocal { [weak self] in
                self?.dismissForInput()
            }
        }
        if includeGlobal, globalMonitor == nil {
            globalMonitor = eventMonitoring.addGlobal { [weak self] in
                self?.dismissForInput()
            }
        }
    }

    private func dismissForInput() {
        pendingPresentation.cancel()
        // Cancel synchronously, but keep visible-window work out of event dispatch.
        DispatchQueue.main.async { [weak self] in self?.hideOverlay() }
    }

    private func removeDismissMonitors() {
        if let globalMonitor { eventMonitoring.remove(globalMonitor) }
        if let localMonitor { eventMonitoring.remove(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
