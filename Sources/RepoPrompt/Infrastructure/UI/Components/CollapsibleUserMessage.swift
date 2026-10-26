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

struct CollapsibleUserMessagePreview {
    let text: String
    let needsCollapse: Bool

    init(text: String, characterLimit: Int) {
        precondition(characterLimit >= 0, "characterLimit must be nonnegative")

        guard let previewEnd = text.index(
            text.startIndex,
            offsetBy: characterLimit,
            limitedBy: text.endIndex
        ), previewEnd != text.endIndex else {
            self.text = text
            needsCollapse = false
            return
        }

        self.text = String(text[..<previewEnd])
        needsCollapse = true
    }
}

/// A user message view that collapses if the text exceeds a threshold.
/// Provides expand/collapse functionality with smooth animations.
struct CollapsibleUserMessage: View {
    let text: String
    let bareURLLinkificationPolicy: BareURLLinkificationPolicy
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

    /// Computed with a bounded grapheme traversal and reused for rendering.
    private let preview: CollapsibleUserMessagePreview

    init(
        text: String,
        bareURLLinkificationPolicy: BareURLLinkificationPolicy = .disabled,
        previewCharCount: Int = 500,
        expandLabel: String = "Show more…",
        collapseLabel: String = "Show less"
    ) {
        self.text = text
        self.bareURLLinkificationPolicy = bareURLLinkificationPolicy
        self.previewCharCount = previewCharCount
        self.expandLabel = expandLabel
        self.collapseLabel = collapseLabel
        preview = CollapsibleUserMessagePreview(
            text: text,
            characterLimit: previewCharCount
        )
    }

    private var displayText: String {
        if preview.needsCollapse, isCollapsed {
            return preview.text
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
        let shouldCollapse = preview.needsCollapse
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
