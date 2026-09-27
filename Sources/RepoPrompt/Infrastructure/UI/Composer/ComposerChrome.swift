//
//  ComposerChrome.swift
//  RepoPrompt
//
//  Shared floating composer bubble chrome used by both Chat and Agent Mode.
//  Handles the visual appearance, sizing, and bottom occlusion calculation.
//

import SwiftUI

// MARK: - Composer Chrome

/// A reusable floating composer bubble container that handles:
/// - Rounded rect background with shadow
/// - Internal padding and divider
/// - Height calculation based on content
/// - Bottom occlusion calculation for scroll overlap
struct ComposerChrome<Main: View, Strip: View>: View {
    static var baseBarHeight: CGFloat {
        60
    }

    /// Binding to report how much the bubble occludes content above
    @Binding var bottomOcclusion: CGFloat

    /// Current height of the main content (e.g., text field plus attachments).
    let mainContentHeight: CGFloat

    /// Optional highlight tint applied as a subtle overlay fill and stroke on the bubble.
    /// Pass `nil` (the default) for no additional emphasis.
    var highlightColor: Color?

    /// Optional Agent/Chat-specific metric overrides. Defaults preserve existing chrome sizing.
    var bubbleHorizontalPaddingOverride: CGFloat?
    var bubbleVerticalPaddingOverride: CGFloat?
    var bubbleInnerSpacingOverride: CGFloat?
    var controlStripHeightOverride: CGFloat?

    /// The main content area (above the divider)
    let main: () -> Main

    /// The control strip area (below the divider)
    let strip: () -> Strip

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                bubbleContent
            }
            .frame(height: minBarHeight)
        }
        .onChange(of: mainContentHeight) { _, _ in
            updateBottomOcclusion()
        }
        .onChange(of: fontPreset.scaleFactor) { _, _ in
            updateBottomOcclusion()
        }
        .onAppear {
            updateBottomOcclusion()
        }
    }

    private var bubbleContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: bubbleCornerRadius)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 3)

            if let highlightColor {
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .fill(highlightColor.opacity(0.04))
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .stroke(highlightColor.opacity(0.25), lineWidth: 1)
            } else if DebugBuildIdentity.isEnabled {
                // DEBUG-only identity ring at the send decision point; an explicit highlight wins.
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .stroke(
                        DebugBuildIdentity.accentColor.opacity(DebugBuildIdentity.composerRingOpacity),
                        lineWidth: 1
                    )
                    .accessibilityHidden(true)
            }

            VStack(spacing: bubbleInnerSpacing) {
                main()

                Divider()
                    .frame(height: dividerHeight)

                strip()
            }
            .padding(.horizontal, bubbleHorizontalPadding)
            .padding(.vertical, bubbleVerticalPadding)
        }
        .frame(height: bubbleHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, bubbleBottomPadding)
        .offset(y: bubbleOffset)
        .zIndex(1)
    }

    // MARK: - Occlusion Calculation

    private func updateBottomOcclusion() {
        // Report how much the bubble overlaps above its base bar height.
        let topFromBottom = (bubbleHeight + bubbleBottomPadding) - bubbleOffset
        let currentOcclusion = topFromBottom - minBarHeight
        let newOcclusion = max(0, currentOcclusion).rounded(.up)
        guard abs(bottomOcclusion - newOcclusion) >= 0.5 else { return }
        bottomOcclusion = newOcclusion
    }

    // MARK: - Layout Constants (matching ChatComposerView)

    /// The offset that nudges the bubble upward as it grows
    private var bubbleOffset: CGFloat {
        let heightDifference = defaultBubbleHeight - bubbleHeight
        let netHeight = heightDifference < 0 ? (heightDifference * 0.5) : 0
        return min(0, netHeight)
    }

    var bubbleCornerRadius: CGFloat {
        18
    }

    var bubbleHorizontalPadding: CGFloat {
        bubbleHorizontalPaddingOverride ?? 12
    }

    var bubbleVerticalPadding: CGFloat {
        bubbleVerticalPaddingOverride ?? (8 * fontPreset.scaleFactor)
    }

    var bubbleInnerSpacing: CGFloat {
        bubbleInnerSpacingOverride ?? (2 * fontPreset.scaleFactor)
    }

    var controlStripHeight: CGFloat {
        controlStripHeightOverride ?? max(40, 40 * fontPreset.scaleFactor)
    }

    var dividerHeight: CGFloat {
        1
    }

    var bubbleBottomPadding: CGFloat {
        8
    }

    var minBarHeight: CGFloat {
        Self.baseBarHeight
    }

    private var bubbleChromeHeight: CGFloat {
        controlStripHeight
            + (bubbleVerticalPadding * 2)
            + (bubbleInnerSpacing * 2)
            + dividerHeight
    }

    var bubbleHeight: CGFloat {
        mainContentHeight + bubbleChromeHeight
    }

    private var defaultBubbleHeight: CGFloat {
        (ResizableTextField.heightPresets.first ?? 36) + bubbleChromeHeight
    }
}
