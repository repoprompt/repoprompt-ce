//
//  TooltipBubble.swift
//  RepoPrompt
//
//  Updated 2025-12-17.
//  All tooltip runtime state moved to reference container (TooltipRuntime) to prevent
//  AppKit updateConstraints/layout recursion crashes when tooltips are used inside popovers.
//

import AppKit // ← access FontScalePreset.current
import Foundation
import SwiftUI

// ──────────────────────────────────
// MARK: - Bubble

/// ──────────────────────────────────
struct TooltipBubble: View {
    let content: TooltipContent
    let preset: FontScalePreset // NEW
    private var maxWidth: CGFloat {
        320 * preset.scaleFactor
    }

    var body: some View {
        Text(content.attributedText ?? AttributedString(content.text))
            .font(preset.captionFont) // was .caption
            .multilineTextAlignment(.leading)
            .padding(8 * preset.scaleFactor) // scale padding
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6 * preset.scaleFactor) // scale corner radius
            .overlay(
                RoundedRectangle(cornerRadius: 6 * preset.scaleFactor)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(radius: 2 * preset.scaleFactor)
            .allowsHitTesting(false)
    }
}

// ──────────────────────────────────
// MARK: - Placement

/// ──────────────────────────────────
enum TooltipPlacement { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

struct TooltipContent {
    let text: String
    let attributedText: AttributedString?

    init(_ text: String) {
        self.text = text
        attributedText = nil
    }

    init(attributedText: AttributedString, plainText: String) {
        text = plainText
        self.attributedText = attributedText
    }
}

// ──────────────────────────────────
// MARK: - Modifier

/// ──────────────────────────────────
private struct HoverTooltipModifier: ViewModifier {
    let tooltipContent: TooltipContent?
    let placement: TooltipPlacement
    private let showDelay: TimeInterval = 0.3 // 300 ms

    /// IMPORTANT:
    /// Keep *all* tooltip runtime mutable state in a reference container so that
    /// geometry updates and event-driven dismissals do NOT invalidate SwiftUI layout.
    /// This prevents AppKit updateConstraints/layout recursion crashes inside popovers.
    final class TooltipRuntime {
        var pendingWork: DispatchWorkItem?
        var pendingReposition: DispatchWorkItem?
        let pendingWorkGate = WorkItemGate()
        let pendingRepositionGate = WorkItemGate()
        var overlayController: TooltipOverlayController?
        var globalMonitor: Any?
        var localMonitor: Any?
        var isCleaningUp: Bool = false

        final class AnchorInfo {
            var rect: NSRect = .zero
            weak var window: NSWindow?
        }

        let anchorInfo = AnchorInfo()
    }

    @State private var runtime = TooltipRuntime()

    /// Forces AnchorGeometryView to re-report when hover starts (fixes ScrollView offset staleness).
    @State private var anchorRefreshID: UInt64 = 0

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    private var showTooltips: Bool {
        globalSettings.showTooltips()
    }

    private var preset: FontScalePreset {
        .current
    }

    func body(content: Content) -> some View {
        let rt = runtime
        content
            .background(
                AnchorGeometryView(refreshID: anchorRefreshID) { rect, win in
                    // Update reference container without triggering SwiftUI updates
                    rt.anchorInfo.rect = rect
                    rt.anchorInfo.window = win

                    // If tooltip is visible, coalesce reposition calls
                    guard rt.overlayController != nil else { return }

                    // Avoid retain cycle: runtime -> pendingReposition -> closure -> runtime
                    rt.pendingReposition?.cancel()
                    rt.pendingRepositionGate.cancel()
                    rt.pendingReposition = rt.pendingRepositionGate.schedule { [weak rt] in
                        rt?.overlayController?.reposition(to: rect)
                    }
                }
            )
            .onHover { inside in
                guard let tooltipContent else { return }
                if inside, showTooltips {
                    // Key fix: scrolling doesn't relayout this view, so force an anchor re-measure now.
                    // This updates rt.anchorInfo.rect to the correct on-screen position before showing.
                    anchorRefreshID &+= 1

                    cancelPendingWork()

                    // Avoid retain cycle: runtime -> pendingWork -> closure -> runtime
                    rt.pendingWork = rt.pendingWorkGate.schedule(after: showDelay) { [tooltipContent, placement, preset, weak rt] in
                        guard let rt else { return }
                        guard let hostWindow = rt.anchorInfo.window else { return }
                        defer { rt.pendingWork = nil }

                        hideOverlay()

                        let controller = TooltipOverlayController()
                        controller.show(
                            content: tooltipContent,
                            anchorRect: rt.anchorInfo.rect,
                            owner: hostWindow,
                            placement: placement,
                            preset: preset
                        )

                        rt.overlayController = controller
                        installDismissMonitors()
                    }
                } else {
                    cancelPendingWork()
                    hideOverlay()
                }
            }
            .onDisappear {
                cleanup(resetContext: true)
            }
            .onChange(of: showTooltips) { _, enabled in
                if !enabled {
                    cleanup(resetContext: false)
                }
            }
    }

    @MainActor
    private func cancelPendingWork() {
        runtime.pendingWork?.cancel()
        runtime.pendingWork = nil
        runtime.pendingWorkGate.cancel()
    }

    @MainActor
    private func cancelPendingReposition() {
        runtime.pendingReposition?.cancel()
        runtime.pendingReposition = nil
        runtime.pendingRepositionGate.cancel()
    }

    @MainActor
    private func hideOverlay() {
        cancelPendingReposition()
        runtime.overlayController?.hide()
        runtime.overlayController = nil
        removeDismissMonitors()
    }

    @MainActor
    private func installDismissMonitors() {
        guard runtime.globalMonitor == nil, runtime.localMonitor == nil else { return }
        let masks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

        // Important: clean up SwiftUI state too (not just controller.hide()).
        // Defer to next runloop to avoid doing too much during event processing.
        runtime.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: masks) { [weak anchorInfo = runtime.anchorInfo] _ in
            _ = anchorInfo // prevent capture warning
            DispatchQueue.main.async {
                Task { @MainActor in
                    hideOverlay()
                }
            }
        }
        runtime.localMonitor = NSEvent.addLocalMonitorForEvents(matching: masks.union(.keyDown)) { [weak anchorInfo = runtime.anchorInfo] event in
            _ = anchorInfo // prevent capture warning
            DispatchQueue.main.async {
                Task { @MainActor in
                    hideOverlay()
                }
            }
            return event
        }
    }

    @MainActor
    private func removeDismissMonitors() {
        if let monitor = runtime.globalMonitor {
            NSEvent.removeMonitor(monitor)
            runtime.globalMonitor = nil
        }
        if let monitor = runtime.localMonitor {
            NSEvent.removeMonitor(monitor)
            runtime.localMonitor = nil
        }
    }

    @MainActor
    private func cleanup(resetContext: Bool = false) {
        // Prevent re-entrant cleanup calls
        guard !runtime.isCleaningUp else { return }
        runtime.isCleaningUp = true
        defer { runtime.isCleaningUp = false }

        cancelPendingWork()
        cancelPendingReposition()
        hideOverlay()
        if resetContext {
            runtime.anchorInfo.rect = .zero
            runtime.anchorInfo.window = nil
        }
    }
}

// ──────────────────────────────────
// MARK: - Public helper

/// ──────────────────────────────────
extension View {
    /// Adds a pure-SwiftUI hover tooltip that adapts to font presets.
    func hoverTooltip(
        _ text: String?,
        _ placement: TooltipPlacement = .top
    ) -> some View {
        modifier(HoverTooltipModifier(tooltipContent: text.map(TooltipContent.init), placement: placement))
    }

    /// Adds a pure-SwiftUI hover tooltip with attributed text for small emphasis.
    func hoverTooltip(
        _ attributedText: AttributedString?,
        plainText: String,
        _ placement: TooltipPlacement = .top
    ) -> some View {
        modifier(HoverTooltipModifier(tooltipContent: attributedText.map { TooltipContent(attributedText: $0, plainText: plainText) }, placement: placement))
    }
}
