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

// MARK: - Collapsible User Message

/// A user message view that collapses if the text exceeds a threshold.
/// Provides expand/collapse functionality with smooth animations.
struct CollapsibleUserMessage: View {
    let text: String
    var bareURLLinkificationPolicy: BareURLLinkificationPolicy = .disabled

    /// Number of characters to show in collapsed state
    var previewCharCount: Int = 500

    /// Label shown on expand button
    var expandLabel: String = "Show more…"

    /// Label shown on collapse button
    var collapseLabel: String = "Show less"

    // UI state
    @State private var isCollapsed = true
    @State private var lastKnownContentWidth: CGFloat?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var displayText: String {
        if text.count > previewCharCount, isCollapsed {
            return String(text.prefix(previewCharCount))
        }
        return text
    }

    private var needsCollapse: Bool {
        text.count > previewCharCount
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
        let shouldCollapse = needsCollapse
        let visibleText = displayText
        let visibleTextMightContainBareWebURL = bareURLLinkificationPolicy.isEnabled &&
            BareURLLinkifier.containsHTTPHTTPSURLSignal(in: visibleText)

        return VStack(alignment: .leading, spacing: 6) {
            // Keep the original SwiftUI Text path unless the displayed text has a
            // cheap http/https signal. If it does, route through PlainProseTextView
            // so the accurate detector can decide which ranges are real URLs.
            if visibleTextMightContainBareWebURL {
                PlainProseTextView(
                    text: visibleText,
                    font: fontPreset.nsFont,
                    fallbackMeasurementWidth: lastKnownContentWidth,
                    bareURLLinkificationPolicy: bareURLLinkificationPolicy,
                    suppressLinksTouchingEndBoundary: shouldCollapse && isCollapsed
                )
                .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            } else if !shouldCollapse || isCollapsed {
                Text(visibleText)
                    .font(fontPreset.font)
                    .textSelection(.enabled)
                    .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            } else {
                PlainProseTextView(
                    text: visibleText,
                    font: fontPreset.nsFont,
                    fallbackMeasurementWidth: lastKnownContentWidth,
                    bareURLLinkificationPolicy: .disabled
                )
                .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            }

            if shouldCollapse {
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
