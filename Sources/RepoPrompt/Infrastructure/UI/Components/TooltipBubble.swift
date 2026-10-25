import RepoPromptSettingsCore

//
//  TooltipBubble.swift
//  RepoPrompt
//
//  Updated 2025-12-17.
//  All tooltip runtime state moved to reference container (TooltipHoverRuntime) to prevent
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

    /// Reference state avoids publishing SwiftUI changes during AppKit layout.
    @State private var runtime = TooltipHoverRuntime()

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
            .background(AnchorGeometryView(refreshID: anchorRefreshID, onUpdate: rt.updateAnchor))
            .onHover { inside in
                guard let tooltipContent else { return }
                if inside, showTooltips {
                    // Scrolling does not relayout the anchor; force a fresh report.
                    anchorRefreshID &+= 1
                    rt.schedulePresentation(after: showDelay, isEnabled: { showTooltips }) { [weak rt = rt, placement, preset] owner, rect in
                        rt?.showOverlay(content: tooltipContent, owner: owner, rect: rect, placement: placement, preset: preset)
                    }
                } else {
                    rt.cleanup()
                }
            }
            .onDisappear {
                rt.cleanup(resetContext: true)
            }
            .onChange(of: showTooltips) { _, enabled in
                if !enabled {
                    rt.cleanup()
                }
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
