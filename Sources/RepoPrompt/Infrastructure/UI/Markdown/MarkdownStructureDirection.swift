import AppKit
import Markdown

/// Resolves one base writing direction for a Markdown structure (a list or a table) from the first
/// strong directional character of its natural-language content, so list markers, continuation
/// indentation and table columns are laid out the same way for every item and row instead of
/// flipping per paragraph when an item happens to start with a code span or an English word (#654).
///
/// Display-only: callers set `NSParagraphStyle.baseWritingDirection`. No bidi control characters are
/// inserted and the backing string is never changed, so search, links, selection, copying and
/// accessibility keep their original offsets. Structures with no strong character keep `.natural`.
enum MarkdownStructureDirection {
    /// The direction of the first strong character in `markup`'s prose, or nil when there is none.
    ///
    /// Code spans, code blocks and raw HTML are skipped: their content is LTR-embedded separately
    /// and would otherwise decide the direction of the RTL prose around them.
    static func baseWritingDirection(for markup: any Markup) -> NSWritingDirection? {
        switch markup {
        case is InlineCode, is CodeBlock, is HTMLBlock, is InlineHTML:
            return nil
        case let text as Text:
            return firstStrongDirection(in: text.string)
        default:
            for child in markup.children {
                if let direction = baseWritingDirection(for: child) {
                    return direction
                }
            }
            return nil
        }
    }

    /// First-strong detection (Unicode bidi rules P2/P3) over scalars: right-to-left letters win as
    /// `.rightToLeft`, any other letter as `.leftToRight`; digits, marks and punctuation are weak or
    /// neutral and skipped. Script blocks stand in for the bidi class, which Swift does not expose.
    static func firstStrongDirection(in text: String) -> NSWritingDirection? {
        for scalar in text.unicodeScalars {
            if isRightToLeftLetter(scalar) { return .rightToLeft }
            if isLetter(scalar) { return .leftToRight }
        }
        return nil
    }

    /// Applies an explicit direction; nil leaves the platform-resolved `.natural` direction alone.
    static func apply(_ direction: NSWritingDirection?, to paragraphStyle: NSMutableParagraphStyle) {
        guard let direction else { return }
        paragraphStyle.baseWritingDirection = direction
    }

    private static let rightToLeftBlocks: [ClosedRange<UInt32>] = [
        0x0590 ... 0x05FF, // Hebrew
        0x0600 ... 0x06FF, // Arabic
        0x0700 ... 0x074F, // Syriac
        0x0750 ... 0x077F, // Arabic Supplement
        0x0780 ... 0x07BF, // Thaana
        0x07C0 ... 0x07FF, // NKo
        0x0800 ... 0x083F, // Samaritan
        0x0840 ... 0x085F, // Mandaic
        0x0860 ... 0x086F, // Syriac Supplement
        0x0870 ... 0x089F, // Arabic Extended-B
        0x08A0 ... 0x08FF, // Arabic Extended-A
        0xFB1D ... 0xFB4F, // Hebrew presentation forms
        0xFB50 ... 0xFDFF, // Arabic Presentation Forms-A
        0xFE70 ... 0xFEFF, // Arabic Presentation Forms-B
        0x10800 ... 0x10FFF, // Historic right-to-left scripts (Phoenician, Imperial Aramaic, ...)
        0x1E800 ... 0x1EFFF // Mende Kikakui, Adlam, Arabic Mathematical Alphabetic Symbols
    ]

    private static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard isLetter(scalar) else { return false }
        let value = scalar.value
        return rightToLeftBlocks.contains { $0.contains(value) }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }
}
