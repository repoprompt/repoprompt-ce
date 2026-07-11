//
//  EnhancedMarkdownView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-28.
//

import AppKit
import Markdown
import SwiftUI

// MARK: - Enhanced Text Rendering

/// High-performance markdown text view that renders complete attributed strings
struct EnhancedMarkdownView: View {
    let text: String
    let isFinalized: Bool
    let allowTextSelection: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var attributedString: NSAttributedString?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        content
            .onAppear {
                generateAttributedString()
            }
            .onChange(of: text) { _, _ in
                generateAttributedString()
            }
            .onChange(of: fontScale.preset) { _, _ in
                generateAttributedString()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let attributedString {
            AttributedTextView(
                attributedString: attributedString,
                isEditable: false,
                allowsTextSelection: allowTextSelection
            )
        } else {
            Text(text)
                .font(fontPreset.font)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func generateAttributedString() {
        renderTask?.cancel()
        renderTask = nil

        guard isFinalized else {
            attributedString = nil
            return
        }

        let textToParse = text
        let fontPresetValue = fontPreset.rawValue

        renderTask = Task {
            let document = Markdown.Document(parsing: textToParse)
            var compiler = EnhancedMarkdownCompiler()
            compiler.fontSize = CGFloat(fontPresetValue)

            let result = compiler.attributedString(from: document)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard text == textToParse else { return }
                guard fontPreset.rawValue == fontPresetValue else { return }
                attributedString = result
            }
        }
    }
}

// MARK: - Custom TextView with Code Block Backgrounds ---------------

/// A non-scrolling `NSTextView` that renders code block / inline code
/// backgrounds. Sizing is handled externally by `AttributedTextView.sizeThatFits`
/// rather than via `intrinsicContentSize`, which avoids the asynchronous
/// invalidation feedback loop that previously caused ScrollView jitter.
final class CodeBlockTextView: NSTextView {
    /// Last measured size, used as a stable fallback when SwiftUI hasn't
    /// proposed a concrete width yet (e.g. the very first layout pass).
    private(set) var lastMeasuredSize: CGSize = .init(width: 0, height: 20)

    /// Monotonically increasing version, bumped when text content changes.
    /// Used by the measurement cache to avoid redundant `ensureLayout` calls.
    private(set) var contentVersion: UInt64 = 0

    private static let plainTextLayoutHeightAllowance: CGFloat = 2
    private static let textTableLayoutHeightAllowance: CGFloat = 4

    /// The (contentVersion, width) pair that produced `lastMeasuredSize`.
    private var cachedMeasurementKey: (version: UInt64, width: CGFloat) = (0, 0)

    func scrollWheelForwardingTarget() -> NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    func shouldForwardScrollWheelToAncestorScrollView() -> Bool {
        !isEditable
    }

    override func scrollWheel(with event: NSEvent) {
        guard shouldForwardScrollWheelToAncestorScrollView(),
              let target = scrollWheelForwardingTarget()
        else {
            super.scrollWheel(with: event)
            return
        }

        target.scrollWheel(with: event)
    }

    /// Cached text-table detection for the current attributed-string content.
    private var cachedTextTablePresence: (version: UInt64, containsTextTables: Bool)?

    /// Call after replacing the text storage content so the next
    /// `measuredHeight(constrainedTo:)` performs a real measurement.
    func incrementContentVersion() {
        contentVersion &+= 1
        cachedTextTablePresence = nil
    }

    /// Synchronously measures the wrapped-text height for the given width.
    /// This is called from `AttributedTextView.sizeThatFits` during SwiftUI
    /// layout — no async invalidation, no deferred dispatch.
    ///
    /// **Caching**: If the content hasn't changed and the width is the same
    /// (within 0.5pt), the previously measured height is returned without
    /// touching the text container or layout manager. This is critical
    /// because `sizeThatFits` is called on every layout pass (including
    /// during scrolling), and calling `ensureLayout` each time creates
    /// AppKit side-effects that can corrupt the parent ScrollView's state.
    ///
    /// **Important**: the text container's `widthTracksTextView` must be
    /// `false` so that this method is the sole authority for the container
    /// width.
    // MARK: Frame-driven container sync --------------------------------

    /// Keeps the text container width in sync with the actual frame width
    /// assigned by SwiftUI. This is a lightweight alternative to
    /// `widthTracksTextView = true` that avoids AppKit's full width-tracking
    /// machinery (which triggers intrinsic-size invalidation and can cause
    /// layout feedback loops in scrolling contexts).
    ///
    /// When `sizeThatFits` returns a size and SwiftUI assigns the frame,
    /// the container width must match the frame for correct text wrapping.
    /// Without this, a stale container width from a previous measurement
    /// causes text to render at the wrong width.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 1 else { return }
        if let container = textContainer,
           abs(container.containerSize.width - newSize.width) > 0.5
        {
            container.containerSize = NSSize(
                width: newSize.width,
                height: .greatestFiniteMagnitude
            )
            // Keep the fallback width aligned with the actual frame, but invalidate
            // the measured-height cache. During rapid shrinks SwiftUI can assign a
            // narrower frame after measuring at a wider proposal; preserving that
            // old cached height lets the table render taller than its allocation
            // until a later 1px resize forces another measurement.
            lastMeasuredSize = CGSize(
                width: newSize.width,
                height: lastMeasuredSize.height
            )
            cachedMeasurementKey = (version: contentVersion &+ 1, width: -1)
            needsDisplay = true
        }
    }

    func measuredHeight(constrainedTo width: CGFloat) -> CGFloat {
        let measureWidth = max(width, 1)

        // Fast path: return cached result when content and width are unchanged.
        if cachedMeasurementKey.version == contentVersion,
           abs(cachedMeasurementKey.width - measureWidth) < 0.5
        {
            return lastMeasuredSize.height
        }

        textContainer?.containerSize = NSSize(
            width: measureWidth,
            height: .greatestFiniteMagnitude
        )
        if let container = textContainer {
            layoutManager?.ensureLayout(for: container)
        }
        let used = layoutManager?.usedRect(for: textContainer!).size ?? .zero
        let heightAllowance = containsTextTableBlocks()
            ? Self.textTableLayoutHeightAllowance
            : Self.plainTextLayoutHeightAllowance
        let height = ceil(used.height) + heightAllowance

        lastMeasuredSize = CGSize(width: measureWidth, height: height)
        cachedMeasurementKey = (contentVersion, measureWidth)
        return height
    }

    private func containsTextTableBlocks() -> Bool {
        if let cachedTextTablePresence,
           cachedTextTablePresence.version == contentVersion
        {
            return cachedTextTablePresence.containsTextTables
        }

        guard let storage = textStorage, storage.length > 0 else {
            cachedTextTablePresence = (contentVersion, false)
            return false
        }

        var containsTextTables = false
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, _, stop in
            guard let paragraphStyle = value as? NSParagraphStyle else { return }
            if paragraphStyle.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                containsTextTables = true
                stop.pointee = true
            }
        }

        cachedTextTablePresence = (contentVersion, containsTextTables)
        return containsTextTables
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw code block backgrounds first, then inline code chips
        drawCodeBlockBackgrounds()
        drawInlineCodeBackgrounds()

        // Then draw the text
        super.draw(dirtyRect)
    }

    /// Draws rounded-rect backgrounds behind inline code spans (backtick text).
    private func drawInlineCodeBackgrounds() {
        guard let storage = textStorage,
              let layoutManager,
              let container = textContainer else { return }

        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.inlineCode, in: full) { value, range, _ in
            guard value != nil else { return }

            layoutManager.ensureLayout(for: container)

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )

            // Collect per-line bounding rects (inline code can wrap across lines)
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                rects.append(rect)
            }

            let hPad: CGFloat = 0.5
            let radius: CGFloat = 3.0

            for var rect in rects {
                // Shift into view coordinates (no vertical expansion)
                rect.origin.x += self.textContainerOrigin.x - hPad
                rect.size.width += hPad * 2
                rect.origin.y += self.textContainerOrigin.y

                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

                // Fill only – no border to keep inline code lightweight
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let fillAlpha: CGFloat = isDark ? 0.25 : 0.1
                NSColor.controlColor.withAlphaComponent(fillAlpha).setFill()
                path.fill()
            }
        }
    }

    private func drawCodeBlockBackgrounds() {
        guard let storage = textStorage,
              let layoutManager,
              let container = textContainer else { return }

        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.codeBlockSource, in: full) { value, range, _ in
            guard value != nil else { return }

            // Ensure layout is current
            layoutManager.ensureLayout(for: container)

            // Get the union of line fragment rects (includes empty lines)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var unionLineRect = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                unionLineRect = unionLineRect.union(lineRect)
            }

            // Add visual padding around the background (beyond text bounds)
            let backgroundPadding: CGFloat = 6

            // Start with the line fragment rect which includes text insets
            var rect = unionLineRect

            // Expand the background outward by padding amount
            rect = rect.insetBy(dx: -backgroundPadding, dy: -backgroundPadding)

            // Constrain to container bounds
            rect.origin.x = max(0, rect.origin.x)
            rect.size.width = min(container.size.width, rect.size.width)

            // Convert to view coordinates
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y

            // Draw rounded background - increased opacity for better visibility
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.controlColor.withAlphaComponent(0.1).setFill() // Increased from 0.05
            path.fill()

            // Draw border
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}

// MARK: - AttributedTextView with Custom Drawing ----------------------

final class MarkdownTextViewCoordinator: NSObject, NSTextViewDelegate {
    var opener: MarkdownFileLinkOpener?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let target = fileLinkTarget(in: textView, link: link, charIndex: charIndex) else {
            return false
        }
        guard let opener else {
            return true
        }

        Task { @MainActor in
            _ = await opener.open(target)
        }
        return true
    }

    private func fileLinkTarget(in textView: NSTextView, link: Any, charIndex: Int) -> MarkdownFileLinkTarget? {
        let rawDestination: String? = if let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length {
            storage.attribute(.markdownRawLink, at: charIndex, effectiveRange: nil) as? String
        } else {
            nil
        }

        if let rawDestination {
            return MarkdownFileLinkTarget.parse(rawDestination: rawDestination)
        }
        if let link = link as? URL {
            return MarkdownFileLinkTarget.parse(rawDestination: link.absoluteString)
        }
        if let link = link as? String {
            return MarkdownFileLinkTarget.parse(rawDestination: link)
        }
        return nil
    }
}

enum AttributedTextMeasurementWidthResolver {
    private static let minimumValidWidth: CGFloat = 1
    private static let meaningfulWidthDifference: CGFloat = 0.5

    static func resolveWidth(
        proposedWidth: CGFloat?,
        boundsWidth: CGFloat,
        lastMeasuredWidth: CGFloat,
        fallbackWidth: CGFloat?
    ) -> CGFloat? {
        if let proposedWidth, isValid(proposedWidth) {
            if isValid(boundsWidth), boundsWidth < proposedWidth - meaningfulWidthDifference {
                return boundsWidth
            }
            return proposedWidth
        }

        if let fallbackWidth, isValid(fallbackWidth) {
            if isValid(boundsWidth), boundsWidth < fallbackWidth - meaningfulWidthDifference {
                return boundsWidth
            }
            return fallbackWidth
        }

        if isValid(lastMeasuredWidth) {
            if isValid(boundsWidth) {
                return min(lastMeasuredWidth, boundsWidth)
            }
            return lastMeasuredWidth
        }

        if isValid(boundsWidth) {
            return boundsWidth
        }

        return nil
    }

    private static func isValid(_ width: CGFloat) -> Bool {
        width.isFinite && width > minimumValidWidth
    }
}

struct AttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let isEditable: Bool
    let allowsTextSelection: Bool
    let linkOpener: MarkdownFileLinkOpener?
    let fallbackMeasurementWidth: CGFloat?

    init(
        attributedString: NSAttributedString,
        isEditable: Bool,
        allowsTextSelection: Bool,
        linkOpener: MarkdownFileLinkOpener? = nil,
        fallbackMeasurementWidth: CGFloat? = nil
    ) {
        self.attributedString = attributedString
        self.isEditable = isEditable
        self.allowsTextSelection = allowsTextSelection
        self.linkOpener = linkOpener
        self.fallbackMeasurementWidth = fallbackMeasurementWidth
    }

    // MARK: Coordinator -------------------------------------------------

    typealias Coordinator = MarkdownTextViewCoordinator

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.opener = linkOpener
        return coordinator
    }

    // MARK: View creation -----------------------------------------------

    func makeNSView(context: Context) -> CodeBlockTextView {
        let tv = CodeBlockTextView()
        configure(textView: tv, context: context)
        return tv
    }

    func updateNSView(_ textView: CodeBlockTextView, context: Context) {
        context.coordinator.opener = linkOpener
        // Detect attribute changes (not just the raw string).
        let current = textView.attributedString()
        if !current.isEqual(to: attributedString) {
            let wasFirstResponder = (textView.window?.firstResponder as? NSTextView) == textView
            let previousSelection = textView.selectedRange()
            let shouldScrollSelectionToVisible = TextViewSelectionRestorePolicy
                .shouldScrollSelectionToVisibleAfterAttributedReplacement(
                    isEditable: isEditable,
                    wasFirstResponder: wasFirstResponder
                )
            textView.textStorage?.setAttributedString(attributedString)
            textView.setSelectedRange(previousSelection)
            textView.clampSelectionToCurrentString(scrollToVisible: shouldScrollSelectionToVisible)
            // Bump content version so the next sizeThatFits performs a real measurement.
            textView.incrementContentVersion()
            textView.needsDisplay = true
        }

        // Always sync interaction flags
        textView.isEditable = isEditable
        textView.isSelectable = allowsTextSelection
        textView.delegate = context.coordinator
        if textView.layoutManager?.allowsNonContiguousLayout != false {
            textView.layoutManager?.allowsNonContiguousLayout = false
        }
    }

    // MARK: Explicit sizing -----------------------------------------------

    /// Provides synchronous, width-constrained sizing to SwiftUI.
    /// This replaces the old `IntrinsicTextView` approach which used deferred
    /// `invalidateIntrinsicContentSize()` and caused a layout feedback loop
    /// that destabilized the Agent Mode transcript ScrollView.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: CodeBlockTextView,
        context: Context
    ) -> CGSize? {
        // Resolve a measurement width from the proposal, the last successful
        // measurement, an explicit fallback width, or the view's current bounds.
        //
        // IMPORTANT: lastMeasuredSize is preferred over bounds.width because
        // during scrolling SwiftUI may re-call sizeThatFits without a concrete
        // proposal, and bounds.width can be transient/stale at that point.
        // Using volatile bounds would poison the measurement cache and cause
        // the view to render at the wrong height until a full layout pass
        // repairs it.
        let proposedWidth = proposal.width
        let resolvedWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
            proposedWidth: proposedWidth,
            boundsWidth: textView.bounds.width,
            lastMeasuredWidth: textView.lastMeasuredSize.width,
            fallbackWidth: fallbackMeasurementWidth
        )

        guard let resolvedWidth else {
            // Very first layout pass with no width info — return last known
            // height to avoid collapsing the view. SwiftUI will re-propose
            // with a real width shortly.
            return CGSize(
                width: proposedWidth ?? textView.lastMeasuredSize.width,
                height: textView.lastMeasuredSize.height
            )
        }

        let measuredHeight = textView.measuredHeight(constrainedTo: resolvedWidth)
        return CGSize(width: proposedWidth ?? resolvedWidth, height: measuredHeight)
    }

    // MARK: Helpers ------------------------------------------------------

    private func configure(textView: CodeBlockTextView, context: Context) {
        textView.drawsBackground = false
        textView.isEditable = isEditable
        textView.isSelectable = allowsTextSelection
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        // widthTracksTextView must be false so that sizeThatFits is the sole
        // authority for the text container width. When true, the container
        // syncs to bounds.width after each frame, which can differ from the
        // width used by sizeThatFits and cause a layout oscillation loop.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributedString)
        textView.layoutManager?.allowsNonContiguousLayout = false
    }
}

/// Enhanced code block with syntax highlighting and better performance
struct EnhancedCodeBlock: View {
    let code: String
    let language: String?
    let isFinalized: Bool
    let allowTextSelection: Bool

    @State private var highlightedCode: NSAttributedString?
    @State private var isCopyHovering = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var scaledCodeFontSize: CGFloat {
        let baseFontSize: CGFloat = 12.0
        return baseFontSize * fontScale.preset.scaleFactor
    }

    // NEW: extract the copy button so it can be reused in overlay
    private var copyButtonView: some View {
        Button(action: copyCode) {
            Image(systemName: "doc.on.clipboard")
                .foregroundColor(
                    isCopyHovering ? BubbleColors.copyIconHover
                        : BubbleColors.copyIconNormal
                )
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .padding(8) // keep padding inside overlay
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isCopyHovering = hovering
            }
        }
    }

    var body: some View {
        codeContent
            .padding(8) // Add insets around the code block
            .background(BubbleColors.codeBlockBackground)
            .cornerRadius(8)
            // ❶  Overlay the button ‑ only the button area
            //    receives mouse events; the transparent remainder
            //    lets text-selection pass straight to the text view.
            .overlay(alignment: .topTrailing) {
                copyButtonView
            }
            .onAppear {
                if isFinalized {
                    generateHighlightedCode()
                }
            }
            .onChange(of: code) { _, _ in
                if isFinalized {
                    generateHighlightedCode()
                }
            }
            .onChange(of: fontScale.preset) { _, _ in
                if isFinalized {
                    generateHighlightedCode()
                }
            }
    }

    // MARK: UI -----------------------------------------------------

    @ViewBuilder
    private var codeContent: some View {
        if let highlightedCode, isFinalized {
            // ① final + highlighted
            AttributedTextView(
                attributedString: highlightedCode,
                isEditable: false,
                allowsTextSelection: allowTextSelection
            )
        } else {
            // ② streaming / not-highlighted → still attributed (no more SwiftUI.Text)
            AttributedTextView(
                attributedString: plainAttributedCode,
                isEditable: false,
                allowsTextSelection: allowTextSelection
            )
        }
    }

    // MARK: Helpers ------------------------------------------------

    /// Lightweight monospaced rendering used while the block is still streaming
    /// or before the async highlighter finishes.
    private var plainAttributedCode: NSAttributedString {
        let font = NSFont.monospacedSystemFont(
            ofSize: scaledCodeFontSize,
            weight: .regular
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        return NSAttributedString(string: code, attributes: attrs)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func generateHighlightedCode() {
        highlightedCode = applySyntaxHighlighting(to: code, language: language)
    }

    private func applySyntaxHighlighting(to code: String, language: String?) -> NSAttributedString {
        // Use the shared cache for better performance
        CodeHighlightCache.shared.highlighted(code, language: language, fontPointSize: scaledCodeFontSize)
    }
}
