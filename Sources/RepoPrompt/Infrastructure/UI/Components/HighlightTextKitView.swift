//
//  HighlightTextKitView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-16.
//

import AppKit
import Neon
import SwiftTreeSitter
import SwiftUI

// Workaround: The library expects a property named `nsRange` on NamedRange.
public extension NamedRange {
    var nsRange: NSRange {
        range
    }
}

/**
 A SwiftUI wrapper around an NSTextView with Neon-based syntax highlighting.
 Spell‑check/autocorrect are disabled to avoid interfering with highlight logic.
 */
struct HighlightedTextKitView: NSViewRepresentable {
    @Binding var text: String
    var highlightRanges: [NamedRange]
    var isEditable: Bool = true
    var fontSize: CGFloat = 12

    @ObservedObject private var highlighterHolder = NeonHighlighterHolder()
    class NeonHighlighterHolder: ObservableObject {
        var highlighter: TextSystemStyler<TextViewSystemInterface>?
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextKitView
        let textViewUndoManager = UndoManager()
        var internalText: String

        init(_ parent: HighlightedTextKitView) {
            self.parent = parent
            internalText = parent.text
            textViewUndoManager.levelsOfUndo = 100
            textViewUndoManager.groupsByEvent = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let previousLength = internalText.utf16.count
            let updatedLength = textView.string.utf16.count
            parent.highlighterHolder.highlighter?.didChangeContent(
                in: NSRange(location: 0, length: previousLength),
                delta: updatedLength - previousLength
            )
            internalText = textView.string
            parent.text = textView.string
            // Reapply highlighting after the text changes
            parent.highlighterHolder.highlighter?.invalidate(.all)
            parent.highlighterHolder.highlighter?.validate()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textViewUndoManager
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        setupTextView(textView, coordinator: context.coordinator)

        // Wrap the NSTextView in Neon’s TextViewSystemInterface
        let textInterface = TextViewSystemInterface(
            textView: textView,
            attributeProvider: neonAttributeProvider
        )
        // Create the Neon highlighter using our token provider
        let highlighter = TextSystemStyler(textSystem: textInterface, tokenProvider: neonTokenProvider)
        highlighterHolder.highlighter = highlighter

        // Invalidate once on creation
        DispatchQueue.main.async {
            highlighter.invalidate(.all)
            highlighter.validate()
        }

        scrollView.scrollsDynamically = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

    private func setupTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = coordinator
        textView.string = coordinator.internalText

        /*
         if let container = textView.textContainer {
         	container.containerSize = NSSize(width: 0, height: 1_000_000)
         	container.widthTracksTextView = true
         	container.heightTracksTextView = false
         }
         */

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let layoutManager = textView.layoutManager {
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.usesFontLeading = true
        }

        if let scrollView = textView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = false
        }

        textView.isRichText = false
        textView.smartInsertDeleteEnabled = false
        textView.displaysLinkToolTips = false

        // Disable spell-check & autocorrection for highlighting
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
    }

    @MainActor
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    // MARK: - Neon Token Provider

    private var neonTokenProvider: TokenProvider {
        let textLength = text.utf16.count

        // Filter out ranges that are out of bounds
        let validRanges = highlightRanges.filter {
            $0.nsRange.location + $0.nsRange.length <= textLength
        }

        // Convert valid highlightRanges into Neon tokens
        let tokens: [Token] = validRanges.map { nr in
            let tokenName = nr.nameComponents.joined(separator: ".")
            return Token(name: tokenName, range: nr.nsRange)
        }

        let application = TokenApplication(tokens: tokens, action: .replace)
        return TokenProvider(
            syncValue: { _ in application },
            asyncValue: { _, _ in application }
        )
    }

    // MARK: - Neon Attribute Provider

    private func neonAttributeProvider(_ token: Token) -> [NSAttributedString.Key: Any] {
        ComprehensiveHighlighter.shared.attributes(for: token)
    }
}
