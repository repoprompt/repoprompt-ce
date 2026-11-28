import AppKit
import SwiftUI

// MARK: - Simple Code Block

/// A simple code block view with copy button, without syntax highlighting.
struct CodeBlock: View {
    let content: String
    var allowTextInteraction: Bool = true
    @State private var isCopyHovering = false
    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var scaledCodeFontSize: CGFloat {
        let baseFontSize: CGFloat = 13.0
        return baseFontSize * fontScale.preset.scaleFactor
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(content)
                .textSelection(.enabled)
                .allowsHitTesting(allowTextInteraction)
                .font(.system(size: scaledCodeFontSize, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .semanticTextDirection(.dedicatedLeftToRight)
                // In RTL the copy button sits over the same edge as the code.
                .padding(.top, layoutDirection == .rightToLeft ? 28 : 0)

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(isCopyHovering ? BubbleColors.copyIconHover : BubbleColors.copyIconNormal)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isCopyHovering = hovering
                }
            }
            .hoverTooltip("Copy code to clipboard")
            .padding(4)
        }
        .background(BubbleColors.codeBlockBackground)
        .cornerRadius(4)
    }
}

// MARK: - Syntax Highlighted Code Block

/// Displays code blocks with syntax highlighting using cached AttributedString.
struct SyntaxHighlightedCodeBlock: View, Equatable {
    let code: String
    let language: String?
    let allowInteraction: Bool

    @State private var isCopyHovering = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var scaledCodeFontSize: CGFloat {
        let baseFontSize: CGFloat = 13.0
        return baseFontSize * fontScale.preset.scaleFactor
    }

    init(code: String, language: String? = nil, allowInteraction: Bool = true) {
        self.code = code
        self.language = language
        self.allowInteraction = allowInteraction
    }

    static func == (lhs: SyntaxHighlightedCodeBlock, rhs: SyntaxHighlightedCodeBlock) -> Bool {
        lhs.code == rhs.code &&
            lhs.language == rhs.language &&
            lhs.allowInteraction == rhs.allowInteraction &&
            lhs.fontScale.preset.scaleFactor == rhs.fontScale.preset.scaleFactor
    }

    var body: some View {
        // Use synchronous highlighting with cache
        let displayCode = CodeHighlightCache.shared.highlighted(
            code,
            language: language,
            fontPointSize: scaledCodeFontSize
        )

        ZStack(alignment: .topTrailing) {
            AttributedTextView(
                attributedString: displayCode,
                isEditable: false,
                allowsTextSelection: allowInteraction
            )
            .padding(8)

            copyButton
        }
        .background(BubbleColors.codeBlockBackground)
        .cornerRadius(4)
    }

    private var copyButton: some View {
        Button(action: copyCode) {
            Image(systemName: "doc.on.clipboard")
                .foregroundColor(isCopyHovering ? BubbleColors.copyIconHover : BubbleColors.copyIconNormal)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isCopyHovering = hovering
            }
        }
        .hoverTooltip("Copy code to clipboard")
        .padding(4)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - Collapsible Code Block

/// A code block that can be collapsed/expanded, showing only a preview when collapsed.
struct CollapsibleCodeBlock: View {
    let content: String
    let language: String?
    let previewLineCount: Int
    let allowInteraction: Bool

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var localExpansion = false
    private let expansion: Binding<Bool>?
    private var isExpanded: Bool {
        expansion?.wrappedValue ?? localExpansion
    }

    @State private var isCopyHovering = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var scaledCodeFontSize: CGFloat {
        let baseFontSize: CGFloat = 13.0
        return baseFontSize * fontScale.preset.scaleFactor
    }

    init(content: String, language: String? = nil, previewLineCount: Int = 10, allowInteraction: Bool = true, expansion: Binding<Bool>? = nil) {
        self.content = content
        self.language = language
        self.previewLineCount = previewLineCount
        self.allowInteraction = allowInteraction
        self.expansion = expansion
    }

    private var lines: [String] {
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let derivedLines = content.components(separatedBy: "\n")
        #if DEBUG
            AgentTextDerivationPerfDiagnostics.record(
                source: .collapsibleCodeBlock,
                startMS: diagnosticsStartMS,
                text: content,
                lineCount: derivedLines.count,
                previewLineCount: previewLineCount,
                displayedLineCount: isExpanded ? derivedLines.count : min(derivedLines.count, previewLineCount),
                remainingLineCount: max(0, derivedLines.count - previewLineCount),
                needsCollapse: derivedLines.count > previewLineCount,
                expanded: isExpanded,
                didSplitFullArray: true
            )
        #endif
        return derivedLines
    }

    private var needsCollapse: Bool {
        lines.count > previewLineCount
    }

    private var displayContent: String {
        if isExpanded || !needsCollapse {
            return content
        }
        return lines.prefix(previewLineCount).joined(separator: "\n")
    }

    private var remainingLineCount: Int {
        max(0, lines.count - previewLineCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Text(displayContent)
                    .textSelection(.enabled)
                    .allowsHitTesting(allowInteraction)
                    .font(.system(size: scaledCodeFontSize, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .semanticTextDirection(.dedicatedLeftToRight)
                    // In RTL the copy button sits over the same edge as the code.
                    .padding(.top, layoutDirection == .rightToLeft ? 28 : 0)

                copyButton
            }

            if needsCollapse {
                expandCollapseButton
            }
        }
        .background(BubbleColors.codeBlockBackground)
        .cornerRadius(4)
    }

    private var copyButton: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        }) {
            Image(systemName: "doc.on.clipboard")
                .foregroundColor(isCopyHovering ? BubbleColors.copyIconHover : BubbleColors.copyIconNormal)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isCopyHovering = hovering
            }
        }
        .hoverTooltip("Copy code to clipboard")
        .padding(4)
    }

    private var expandCollapseButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                (expansion ?? $localExpansion).wrappedValue.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                Text(isExpanded ? "Show less" : "Show \(remainingLineCount) more lines")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BubbleColors.codeBlockBackground.opacity(0.5))
    }
}

// MARK: - Preview

#if DEBUG
    struct CodeBlockView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                CodeBlock(content: "let x = 42\nprint(x)")

                SyntaxHighlightedCodeBlock(
                    code: "func hello() {\n    print(\"Hello\")\n}",
                    language: "swift"
                )

                CollapsibleCodeBlock(
                    content: (1 ... 20).map { "Line \($0)" }.joined(separator: "\n"),
                    previewLineCount: 5
                )
            }
            .padding()
            .frame(width: 400)
        }
    }
#endif
