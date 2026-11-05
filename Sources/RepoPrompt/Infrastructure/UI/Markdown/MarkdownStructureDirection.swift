import AppKit
import Markdown
import RepoPromptC

/// Resolves one base writing direction for a Markdown structure (a list or a table) from the first
/// strong directional character of its natural-language content, so list markers, continuation
/// indentation and table columns are laid out the same way for every item and row instead of
/// flipping per paragraph when an item happens to start with a code span or an English word (#654).
///
/// Display-only: callers set `NSParagraphStyle.baseWritingDirection` (and, for fallback tables,
/// `.writingDirection` attribute embeddings). No bidi control characters are inserted and the
/// backing string is never changed, so search, links, selection, copying and accessibility keep
/// their original offsets.
///
/// Policy: a structure whose prose has no strong character (only digits, punctuation, code or
/// HTML) resolves to nil and keeps the platform-resolved `.natural` direction; it is never encoded
/// as an explicit direction.
enum MarkdownStructureDirection {
    /// The direction of the first strong character in `markup`'s prose, or nil when there is none.
    ///
    /// Code spans, code blocks and raw HTML are skipped: their content is LTR-embedded separately
    /// and would otherwise decide the direction of the RTL prose around them.
    static func baseWritingDirection(for markup: any Markup) -> NSWritingDirection? {
        var scanner = FirstStrongScanner()
        return scanner.direction(in: markup)
    }

    /// First-strong detection over one paragraph of plain text (see `FirstStrongScanner`).
    static func firstStrongDirection(in text: String) -> NSWritingDirection? {
        var scanner = FirstStrongScanner()
        return scanner.scan(text)
    }

    /// Applies an explicit direction; nil leaves the platform-resolved `.natural` direction alone.
    static func apply(_ direction: NSWritingDirection?, to paragraphStyle: NSMutableParagraphStyle) {
        guard let direction else { return }
        paragraphStyle.baseWritingDirection = direction
    }
}

/// Unicode bidi rule P2 (UAX #9) using the real Bidi_Class of each scalar from the system ICU:
/// the first character of class L is left-to-right, of class R or AL right-to-left. Characters
/// between an isolate initiator (LRI, RLI, FSI) and its matching PDI are skipped; an unmatched PDI
/// is ignored; an unmatched initiator hides the rest of its paragraph. Embedding and override
/// controls (LRE, RLE, LRO, RLO, PDF) are skipped themselves but not their contents, and PDF never
/// closes an isolate. Isolate nesting is counted without the rendering depth limit.
///
/// The isolate state spans the inline nodes of one paragraph (text, emphasis, links) and starts
/// over at every real paragraph boundary: block elements, table cells, hard line breaks (which the
/// compiler renders as a line feed) and paragraph-separator characters.
struct FirstStrongScanner {
    private var isolateDepth = 0

    mutating func scan(_ text: String) -> NSWritingDirection? {
        for scalar in text.unicodeScalars {
            switch rpce_bidi_first_strong_class(scalar.value) {
            case .leftToRight:
                if isolateDepth == 0 { return .leftToRight }
            case .rightToLeft:
                if isolateDepth == 0 { return .rightToLeft }
            case .isolateInitiator:
                isolateDepth += 1
            case .popDirectionalIsolate:
                if isolateDepth > 0 { isolateDepth -= 1 }
            case .paragraphSeparator:
                isolateDepth = 0
            case .other:
                break
            }
        }
        return nil
    }

    mutating func direction(in markup: any Markup) -> NSWritingDirection? {
        switch markup {
        case is InlineCode, is CodeBlock, is HTMLBlock, is InlineHTML:
            return nil
        case let text as Text:
            return scan(text.string)
        case is LineBreak:
            isolateDepth = 0
            return nil
        default:
            let startsParagraph = markup is BlockMarkup || markup is Table.Cell
            if startsParagraph { isolateDepth = 0 }
            for child in markup.children {
                if let direction = direction(in: child) {
                    return direction
                }
            }
            if startsParagraph { isolateDepth = 0 }
            return nil
        }
    }
}
