//
//  CollapsibleUserMessage.swift
//  RepoPrompt
//
//  Shared component for user message bubbles that can collapse/expand.
//  Used by both Chat (Bubbles.swift) and Agent Mode (AgentMessageBubble.swift).
//

import AppKit
import SwiftUI

// MARK: - Content Width Observation

private struct CollapsibleUserMessageContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next.isFinite, next > 1 else { return }
        value = next
    }
}

private extension View {
    func recordCollapsibleUserMessageContentWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CollapsibleUserMessageContentWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        }
        .onPreferenceChange(CollapsibleUserMessageContentWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 1 else { return }
            onChange(width)
        }
    }
}

// MARK: - Measured Plain Text View

/// Plain-text user message renderer backed by the markdown text view's
/// synchronous `sizeThatFits` measurement path. This avoids the old
/// intrinsic-size/AppKit invalidation loop and ignores any oversized height
/// proposed by the transcript viewport.
private struct MeasuredPlainTextView: View {
    let text: String
    let font: NSFont
    let fallbackMeasurementWidth: CGFloat?

    private var attributedString: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor
        ])
    }

    var body: some View {
        AttributedTextView(
            attributedString: attributedString,
            isEditable: false,
            allowsTextSelection: true,
            fallbackMeasurementWidth: fallbackMeasurementWidth
        )
    }
}

// MARK: - Collapsible User Message

/// A user message view that collapses if the text exceeds a threshold.
/// Provides expand/collapse functionality with smooth animations.
struct CollapsibleUserMessage: View {
    let text: String
    let previewCharCount: Int
    let expandLabel: String
    let collapseLabel: String

    // UI state
    @State private var isCollapsed = true
    @State private var lastKnownContentWidth: CGFloat?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// Whether the text exceeds the preview threshold.
    /// Computed in O(previewCharCount) by short-circuiting at the threshold,
    /// avoiding a full O(N) grapheme-cluster traversal via `text.count`.
    private let needsCollapse: Bool

    init(
        text: String,
        previewCharCount: Int = 500,
        expandLabel: String = "Show more…",
        collapseLabel: String = "Show less"
    ) {
        self.text = text
        self.previewCharCount = previewCharCount
        self.expandLabel = expandLabel
        self.collapseLabel = collapseLabel
        // O(previewCharCount+1) at most — short-circuits instead of counting the full string.
        self.needsCollapse = text.index(
            text.startIndex,
            offsetBy: previewCharCount + 1,
            limitedBy: text.endIndex
        ) != nil
    }

    private var displayText: String {
        if needsCollapse, isCollapsed {
            return String(text.prefix(previewCharCount))
        }
        return text
    }

    private func updateLastKnownContentWidth(_ width: CGFloat) {
        guard width.isFinite, width > 1 else { return }
        if let lastKnownContentWidth,
           abs(lastKnownContentWidth - width) <= 0.5
        {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lastKnownContentWidth = width
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Use normal Text for small messages or collapsed state.
            // Use the shared measured AppKit text path for expanded large messages.
            if !needsCollapse || isCollapsed {
                Text(displayText)
                    .font(fontPreset.font)
                    .textSelection(.enabled)
                    .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            } else {
                MeasuredPlainTextView(
                    text: displayText,
                    font: fontPreset.nsFont,
                    fallbackMeasurementWidth: lastKnownContentWidth
                )
                .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            }

            if needsCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Text(isCollapsed ? expandLabel : collapseLabel)
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
