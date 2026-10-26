import AppKit
import SwiftUI

private final class EdgeForwardingScrollView: NSScrollView {
    private let edgeTolerance: CGFloat = 0.5

    override func scrollWheel(with event: NSEvent) {
        let predominantlyVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        guard predominantlyVertical else {
            super.scrollWheel(with: event)
            return
        }

        let maxOffsetY = maximumVerticalContentOffset
        let previousOffsetY = contentView.bounds.origin.y
        let wasAtVerticalEdge = previousOffsetY <= edgeTolerance || previousOffsetY >= (maxOffsetY - edgeTolerance)

        super.scrollWheel(with: event)

        let updatedOffsetY = contentView.bounds.origin.y
        let didConsumeVerticalScroll = abs(updatedOffsetY - previousOffsetY) > edgeTolerance
        guard wasAtVerticalEdge, !didConsumeVerticalScroll else { return }
        nextResponder?.scrollWheel(with: event)
    }

    private var maximumVerticalContentOffset: CGFloat {
        guard let documentView else { return 0 }
        return max(documentView.bounds.height - contentView.bounds.height, 0)
    }
}

extension NSAttributedString.Key {
    static let unifiedDiffLineBackgroundColor = NSAttributedString.Key("RepoPromptUnifiedDiffLineBackgroundColor")
}

extension NSTextView {
    func disableAutomaticLinkAndDataDetection() {
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
    }
}

private final class UnifiedDiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage else { return }
        let fullWidth = firstTextView?.bounds.width ?? 0

        enumerateLineFragments(forGlyphRange: glyphsToShow) { lineFragmentRect, _, _, glyphRange, _ in
            let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard characterRange.length > 0,
                  let backgroundColor = textStorage.attribute(.unifiedDiffLineBackgroundColor, at: characterRange.location, effectiveRange: nil) as? NSColor
            else {
                return
            }

            var fillRect = lineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            fillRect.origin.x = 0
            fillRect.size.width = max(fullWidth, fillRect.maxX)

            backgroundColor.setFill()
            fillRect.fill()
        }
    }
}

struct UnifiedDiffTextView: NSViewRepresentable {
    let document: UnifiedDiffDocument
    let fontSize: CGFloat
    let fontPreset: FontScalePreset
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EdgeForwardingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = UnifiedDiffLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.disableAutomaticLinkAndDataDetection()
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: UnifiedDiffCardRendering.appKitVerticalTextInset(for: fontPreset))
        textView.textContainer?.lineFragmentPadding = UnifiedDiffCardRendering.appKitHorizontalTextPadding(for: fontPreset)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        if let layoutManager = textView.layoutManager {
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.usesFontLeading = true
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let horizontalPadding = UnifiedDiffCardRendering.appKitHorizontalTextPadding(for: fontPreset)
        let verticalInset = UnifiedDiffCardRendering.appKitVerticalTextInset(for: fontPreset)
        let lineSpacing = UnifiedDiffCardRendering.appKitLineSpacing(for: fontPreset)
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = horizontalPadding
        let signature = RenderSignature(
            renderID: document.renderID,
            fontSize: font.pointSize,
            colorScheme: colorScheme,
            lineSpacing: lineSpacing,
            horizontalPadding: horizontalPadding,
            verticalInset: verticalInset
        )

        guard context.coordinator.lastRenderSignature != signature else { return }
        let attributedString = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: colorScheme,
            lineSpacing: lineSpacing
        ).build()
        textView.textStorage?.setAttributedString(attributedString)
        context.coordinator.lastRenderSignature = signature
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate var lastRenderSignature: RenderSignature?
    }

    fileprivate struct RenderSignature: Equatable {
        let renderID: Int
        let fontSize: CGFloat
        let colorScheme: ColorScheme
        let lineSpacing: CGFloat
        let horizontalPadding: CGFloat
        let verticalInset: CGFloat
    }
}

@MainActor
struct UnifiedDiffAttributedStringBuilder {
    private struct LineAttributeSet {
        let prefix: [NSAttributedString.Key: Any]
        let body: [NSAttributedString.Key: Any]
    }

    let document: UnifiedDiffDocument
    let font: NSFont
    let colorScheme: ColorScheme
    let lineSpacing: CGFloat

    func build() -> NSAttributedString {
        EditFlowPerf.measure(
            EditFlowPerf.Stage.UnifiedDiff.attributedBuild,
            EditFlowPerf.Dimensions(lineCount: document.lines.count)
        ) {
            let output = NSMutableAttributedString()
            output.beginEditing()
            let paragraphStyle = makeParagraphStyle()
            let numberColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
            let blankNumber = String(repeating: " ", count: document.maxLineNumberDigits)
            let attributesByKind = makeAttributesByKind(numberColor: numberColor, paragraphStyle: paragraphStyle)
            let lastIndex = document.lines.count - 1

            for (index, line) in document.lines.enumerated() {
                guard let attributeSet = attributesByKind[line.kind] else { continue }
                let prefix = numberPrefix(for: line, blankNumber: blankNumber)
                output.append(NSAttributedString(string: prefix, attributes: attributeSet.prefix))
                output.append(NSAttributedString(string: line.text, attributes: attributeSet.body))
                if index < lastIndex {
                    output.append(NSAttributedString(string: "\n", attributes: attributeSet.body))
                }
            }

            output.endEditing()
            return output
        }
    }

    private func makeParagraphStyle() -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        paragraphStyle.maximumLineHeight = paragraphStyle.minimumLineHeight
        return paragraphStyle
    }

    private func makeAttributesByKind(
        numberColor: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> [UnifiedDiffDocument.Line.Kind: LineAttributeSet] {
        let kinds: [UnifiedDiffDocument.Line.Kind] = [.addition, .deletion, .context, .gap, .fileHeader]
        var result: [UnifiedDiffDocument.Line.Kind: LineAttributeSet] = [:]
        result.reserveCapacity(kinds.count)
        for kind in kinds {
            let background = kind.nsBackgroundColor(colorScheme: colorScheme)
            result[kind] = LineAttributeSet(
                prefix: makeLineAttributes(
                    foregroundColor: numberColor,
                    paragraphStyle: paragraphStyle,
                    backgroundColor: background
                ),
                body: makeLineAttributes(
                    foregroundColor: kind.nsTextColor(colorScheme: colorScheme),
                    paragraphStyle: paragraphStyle,
                    backgroundColor: background
                )
            )
        }
        return result
    }

    private func makeLineAttributes(
        foregroundColor: NSColor,
        paragraphStyle: NSParagraphStyle,
        backgroundColor: NSColor?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        if let backgroundColor {
            attributes[.unifiedDiffLineBackgroundColor] = backgroundColor
        }
        return attributes
    }

    private func numberPrefix(for line: UnifiedDiffDocument.Line, blankNumber: String) -> String {
        "\(paddedLineNumber(line.oldLineNumber, blankNumber: blankNumber)) \(paddedLineNumber(line.newLineNumber, blankNumber: blankNumber))  "
    }

    private func paddedLineNumber(_ value: Int?, blankNumber: String) -> String {
        guard let value else { return blankNumber }
        let raw = String(value)
        let padding = document.maxLineNumberDigits - raw.count
        guard padding > 0 else { return raw }
        return String(repeating: " ", count: padding) + raw
    }
}
