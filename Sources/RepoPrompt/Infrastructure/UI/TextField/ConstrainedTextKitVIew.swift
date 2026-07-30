//
//  ConstrainedTextKitVIew.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-29.
//

import AppKit
import SwiftUI

/// Suppresses vertical scrolling while still allowing horizontal scrolling.
private final class NoVerticalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let predominantlyHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if predominantlyHorizontal {
            super.scrollWheel(with: event) // genuine horizontal movement
        } else {
            nextResponder?.scrollWheel(with: event) // bubble up so gestures still work
        }
    }
}

/**
 A fork of `TextKitView` that:

 * Keeps a **fixed height** supplied by `heightConstraint`
 * Disables **soft-wrapping** so long lines scroll **horizontally**
 * Removes vertical scrolling to avoid the "one-line jiggle"

 Use this when you need an editor that stays the same height while letting the
 user pan sideways.
 */
struct ConstrainedTextKitView: NSViewRepresentable {
    @Binding var text: String

    // MARK: – Configuration

    var heightConstraint: CGFloat // ► required
    var isEditable: Bool = true
    var isSpellCheckEnabled: Bool = false
    var fontSize: Double?
    var useMonospacedFont: Bool = false

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var resolvedFontSize: CGFloat {
        if let fontSize {
            return CGFloat(fontSize)
        }
        return useMonospacedFont
            ? CGFloat(max(fontScale.preset.rawValue - 2, 9))
            : CGFloat(fontScale.preset.rawValue)
    }

    private var resolvedFont: NSFont {
        useMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: resolvedFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: resolvedFontSize)
    }

    // MARK: – Static helpers

    static func heightForLineCount(
        _ lineCount: Int,
        fontSize: Double,
        useMonospaced: Bool = false
    ) -> CGFloat {
        let font = useMonospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)

        let backingScale = NSScreen.main?.backingScaleFactor ?? 1
        let pixelAlignedLineHeight = lineHeight(for: font, backingScale: backingScale)

        return (pixelAlignedLineHeight * CGFloat(lineCount)) + 32 // + inset padding
    }

    static func lineHeight(
        for font: NSFont,
        backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 1
    ) -> CGFloat {
        // Ask a layout manager for the authoritative default line-height (in points).
        // (Use an instance to avoid static/instance ambiguities on some OS versions.)
        var h = NSLayoutManager().defaultLineHeight(for: font)
        // Align to the device-pixel grid so we never under-allocate height.
        h = ceil(h * backingScale) / backingScale // still in points
        return h
    }

    /// Returns the number of display lines in `text`, treating every `\n`
    /// as ending a line *and* accounting for empty or trailing-blank lines.
    static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 1 } // an empty string is one blank line
        return text.reduce(into: 1) { count, ch in // start at 1, add 1 per "\n"
            if ch == "\n" { count += 1 }
        }
    }

    // MARK: – Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConstrainedTextKitView
        private let undo = UndoManager()
        var internalText: String
        var highlightTask: Task<Void, Never>?
        var isActive = true

        init(_ parent: ConstrainedTextKitView) {
            self.parent = parent
            internalText = parent.text
            undo.levelsOfUndo = 100
            undo.groupsByEvent = true
        }

        func textDidChange(_ note: Notification) {
            guard isActive, let tv = note.object as? NSTextView else { return }
            let newText = tv.string
            // Only update if text actually changed
            guard newText != internalText else { return }
            internalText = newText
            parent.text = newText
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }

        func performExternalReplacement(
            in textView: NSTextView,
            mutation: () -> Void
        ) {
            TextViewUndoSafeReplacement.perform(
                in: textView,
                undoManager: undo,
                mutation: mutation
            )
        }

        func clearUndoHistory() {
            undo.removeAllActions()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: – NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        let scroll = NoVerticalScrollView() // ▸ suppress vertical scroll

        // Scroll-view configuration
        scroll.documentView = textView
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.hasHorizontalScroller = true
        scroll.usesPredominantAxisScrolling = true
        scroll.scrollsDynamically = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.backgroundColor = .clear

        setupTextView(textView, coordinator: context.coordinator)
        return scroll
    }

    private func setupTextView(_ tv: NSTextView, coordinator: Coordinator) {
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.delegate = coordinator
        tv.string = coordinator.internalText
        // ▼ NEW: highlight code if this view is used for a code block
        applySyntaxHighlighting(to: tv, coordinator: coordinator)
        tv.backgroundColor = .clear

        // Font
        tv.font = resolvedFont
        tv.textContainerInset = NSSize(width: 8, height: 8)

        // Hard-wrap OFF  →  horizontal scroll ON
        if let container = tv.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: heightConstraint
            )
        }
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = false

        // 🔑 Give the text view a real, non-zero frame right away.
        if let scroll = tv.enclosingScrollView {
            let baseWidth = scroll.contentSize.width
            tv.minSize = NSSize(width: baseWidth, height: heightConstraint)
            tv.setFrameSize(NSSize(width: baseWidth, height: heightConstraint))
            // scroll.setFrameSize(NSSize(width: baseWidth, height: heightConstraint + 16))
            tv.autoresizingMask = [.width] // stay in sync on window resize
        }

        // Let the view grow sideways without limit
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: heightConstraint
        )

        // Spell-check
        tv.isContinuousSpellCheckingEnabled = isSpellCheckEnabled
        tv.isAutomaticSpellingCorrectionEnabled = isSpellCheckEnabled

        // Plain-text only
        tv.isRichText = false
        tv.smartInsertDeleteEnabled = false
        tv.displaysLinkToolTips = false

        // Layout tweaks
        tv.layoutManager?.allowsNonContiguousLayout = false
        tv.layoutManager?.usesFontLeading = true
    }

    // MARK: – Syntax-highlighting helper

    private func applySyntaxHighlighting(to tv: NSTextView, coordinator: Coordinator) {
        guard useMonospacedFont, // Only for code blocks
              let storage = tv.textStorage else { return }

        let code = storage.string
        let fontSize = Double(resolvedFontSize)

        // Cancel any previous highlighting task
        coordinator.highlightTask?.cancel()

        // Set base attributes synchronously first (immediate display, no flash)
        let fullRange = NSRange(location: 0, length: storage.length)
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.textColor
        ], range: fullRange)

        // Apply highlighting synchronously via the cache
        coordinator.highlightTask = Task { @MainActor [weak storage] in
            guard let storage else { return }

            let highlighted = CodeHighlightCache.shared.highlighted(code, language: nil, fontPointSize: fontSize)

            // Only apply if the text hasn't changed and task wasn't cancelled
            guard !Task.isCancelled, storage.string == code else { return }

            storage.setAttributedString(highlighted)
        }
    }

    @MainActor
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView,
              let container = tv.textContainer else { return }

        // Keep container height locked; width remains infinite for sideways scroll
        // Only update if the height actually changed to avoid constraint update loops
        if container.containerSize.height != heightConstraint {
            container.containerSize.height = heightConstraint
        }

        // Prevent vertical drift - only reset if it has drifted
        if nsView.contentView.bounds.origin.y != 0 {
            nsView.contentView.bounds.origin.y = 0
        }

        // Refresh font if user toggled mono-spaced or the default preset changed
        let requiredFont = resolvedFont
        if tv.font != requiredFont {
            tv.font = requiredFont
            applySyntaxHighlighting(to: tv, coordinator: context.coordinator)
        }

        // Refresh text if external binding changed
        if tv.string != text {
            if tv.hasMarkedText() { return }

            context.coordinator.performExternalReplacement(in: tv) {
                tv.string = text
                context.coordinator.internalText = text
            }
            // ▼ Re-apply highlighting for the updated content
            applySyntaxHighlighting(to: tv, coordinator: context.coordinator)
            // Only ensure layout after text changes
            tv.layoutManager?.ensureLayout(for: container)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = nil
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = false
        coordinator.highlightTask?.cancel()
        coordinator.clearUndoHistory()
        coordinator.isActive = false
    }
}
