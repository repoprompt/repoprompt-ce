import AppKit
import Markdown
@testable import RepoPromptApp
import XCTest

@MainActor
final class EnhancedMarkdownCompilerBidirectionalTests: XCTestCase {
    private let leftToRightEmbedding = NSNumber(
        value: NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue
    )

    func testAdjacentInlineCodeSpansKeepExactEmbeddingRangesAcrossNeutralCharacters() {
        let attributed = compile("`alpha`/`beta`—`--flag`")
        let expectedString = "alpha/beta—--flag"

        XCTAssertEqual(attributed.string, expectedString)
        assertWritingDirectionRuns(
            in: attributed,
            equal: [
                range(of: "alpha", in: expectedString),
                range(of: "beta", in: expectedString),
                range(of: "--flag", in: expectedString)
            ]
        )
        assertContainsNoBidiControls(attributed.string)
    }

    func testInlineCodeEmbeddingCoversExactRangesWithoutChangingRTLParagraphStrings() {
        let cases = [
            (
                markdown: "עברית לפני `path/to/file` אחרי",
                expected: "עברית לפני path/to/file אחרי",
                code: "path/to/file"
            ),
            (
                markdown: "`--flag` العربية",
                expected: "--flag العربية",
                code: "--flag"
            )
        ]

        for testCase in cases {
            let attributed = compile(testCase.markdown)

            XCTAssertEqual(attributed.string, testCase.expected)
            assertWritingDirectionRuns(
                in: attributed,
                equal: [range(of: testCase.code, in: testCase.expected)]
            )
            assertContainsNoBidiControls(attributed.string)
        }
    }

    func testTableCellSecondPassPreservesInlineCodeEmbeddingAndBackingString() {
        let markdown = """
        | מפתח | Value |
        | --- | --- |
        | עברית | `--flag` |
        """
        let expectedString = "מפתח\nValue\nעברית\n--flag\n"
        let attributed = compile(markdown)

        XCTAssertEqual(attributed.string, expectedString)
        assertWritingDirectionRuns(
            in: attributed,
            equal: [range(of: "--flag", in: expectedString)]
        )
        assertContainsNoBidiControls(attributed.string)
    }

    private func compile(_ markdown: String) -> NSAttributedString {
        let document = Markdown.Document(parsing: markdown)
        var compiler = EnhancedMarkdownCompiler()
        return compiler.attributedString(from: document)
    }

    private func assertWritingDirectionRuns(
        in attributed: NSAttributedString,
        equal expectedRanges: [NSRange],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualRanges: [NSRange] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.writingDirection, in: fullRange) { value, range, _ in
            guard let directions = value as? [NSNumber] else { return }
            XCTAssertEqual(directions, [leftToRightEmbedding], file: file, line: line)
            actualRanges.append(range)
        }
        XCTAssertEqual(actualRanges, expectedRanges, file: file, line: line)
    }

    private func range(of substring: String, in string: String) -> NSRange {
        let result = (string as NSString).range(of: substring)
        XCTAssertNotEqual(result.location, NSNotFound)
        return result
    }

    private func assertContainsNoBidiControls(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bidiControlValues = Set<UInt32>([
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ])
        XCTAssertFalse(
            string.unicodeScalars.contains { bidiControlValues.contains($0.value) },
            file: file,
            line: line
        )
    }
}

/// #654: list markers, continuation indentation and table columns in mixed RTL/LTR Markdown are
/// laid out from one base direction per structure, resolved display-only through paragraph styles.
@MainActor
final class EnhancedMarkdownCompilerStructureDirectionTests: XCTestCase {
    private let leftToRightEmbedding = NSNumber(
        value: NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue
    )

    // MARK: - Direction resolution

    func testFirstStrongDirectionSkipsDigitsMarksAndPunctuation() {
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "עברית"), .rightToLeft)
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "العربية"), .rightToLeft)
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "English"), .leftToRight)
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "12. — (שלום) hello"), .rightToLeft)
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "٣ items, then abc"), .leftToRight)
        XCTAssertEqual(
            MarkdownStructureDirection.firstStrongDirection(in: "\u{05B0}\u{05B1} abc"),
            .leftToRight,
            "Hebrew points alone are not strong"
        )
        XCTAssertNil(MarkdownStructureDirection.firstStrongDirection(in: "123 — ! ٤٥"))
        XCTAssertNil(MarkdownStructureDirection.firstStrongDirection(in: ""))
    }

    func testStructureDirectionIgnoresCodeAndHTMLContent() {
        let document = Markdown.Document(parsing: "- `--flag` <br/> עברית")
        XCTAssertEqual(MarkdownStructureDirection.baseWritingDirection(for: document), .rightToLeft)
        let codeOnly = Markdown.Document(parsing: "- `only code`\n- `more code`")
        XCTAssertNil(MarkdownStructureDirection.baseWritingDirection(for: codeOnly))
        let linkText = Markdown.Document(parsing: "1. [קישור](https://example.com/path)")
        XCTAssertEqual(MarkdownStructureDirection.baseWritingDirection(for: linkText), .rightToLeft)
    }

    // MARK: - Lists

    func testUnorderedListItemsShareOneDirectionEvenWhenAnItemStartsWithCode() {
        let markdown = """
        - עברית ראשון
        - `--flag` עברית
        - English third
        """
        let attributed = compile(markdown)
        let expected = "\t•\tעברית ראשון\n\t•\t--flag עברית\n\t•\tEnglish third"

        XCTAssertEqual(attributed.string, expected)
        XCTAssertEqual(markerDirections(in: attributed, marker: "\t•\t"), [.rightToLeft, .rightToLeft, .rightToLeft])
        assertWritingDirectionRuns(in: attributed, equal: [range(of: "--flag", in: expected)])
        assertContainsNoBidiControls(attributed.string)
    }

    func testOrderedListInLeftToRightProseStaysLeftToRightAndNeutralListStaysNatural() {
        let ordered = compile("1. First item\n2. פריט שני\n3. Third")
        XCTAssertEqual(ordered.string, "\t1.\tFirst item\n\t2.\tפריט שני\n\t3.\tThird")
        XCTAssertEqual(markerDirections(in: ordered, marker: "\t1.\t"), [.leftToRight])
        XCTAssertEqual(markerDirections(in: ordered, marker: "\t2.\t"), [.leftToRight])

        let neutral = compile("- 123\n- 456")
        XCTAssertEqual(markerDirections(in: neutral, marker: "\t•\t"), [.natural, .natural])
    }

    func testEachListResolvesItsOwnDirectionAndKeepsItsIndentation() {
        let markdown = """
        1. Outer English
           - עברית פנימי
           - `code` עוד
        2. Outer again
        """
        let attributed = compile(markdown)
        XCTAssertEqual(markerDirections(in: attributed, marker: "\t1.\t"), [.leftToRight])
        XCTAssertEqual(markerDirections(in: attributed, marker: "\t2.\t"), [.leftToRight])
        let nestedStyles = markerParagraphStyles(in: attributed, marker: "\t•\t")
        XCTAssertEqual(nestedStyles.map(\.baseWritingDirection), [.rightToLeft, .rightToLeft])
        // Continuation indentation (headIndent) and tab stops are untouched; the direction only
        // decides which edge they measure from.
        for style in nestedStyles {
            XCTAssertGreaterThan(style.headIndent, 0)
            XCTAssertEqual(style.tabStops.count, 2)
        }
        assertContainsNoBidiControls(attributed.string)
    }

    // MARK: - Tables

    func testTextTableCellsShareTheTableDirectionAndKeepColumnOrder() {
        let markdown = """
        | מפתח | Value |
        | --- | --- |
        | עברית | `--flag` |
        | English | قيمة |
        """
        let attributed = compile(markdown)
        let expected = "מפתח\nValue\nעברית\n--flag\nEnglish\nقيمة\n"
        XCTAssertEqual(attributed.string, expected)

        let cells = tableCellParagraphStyles(in: attributed)
        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(cells.map(\.baseWritingDirection), Array(repeating: .rightToLeft, count: 6))
        XCTAssertEqual(cells.map(\.alignment), Array(repeating: .natural, count: 6))
        XCTAssertEqual(cells.map(\.block.startingColumn), [0, 1, 0, 1, 0, 1])
        XCTAssertEqual(cells.map(\.block.startingRow), [0, 0, 1, 1, 2, 2])
        assertWritingDirectionRuns(in: attributed, equal: [range(of: "--flag", in: expected)])
        assertContainsNoBidiControls(attributed.string)
    }

    func testLeftToRightTableWithRightToLeftCellsStaysLeftToRightAndHonorsExplicitAlignment() {
        let markdown = """
        | Key | ערך |
        | :-- | --: |
        | עברית | 1 |
        """
        let cells = tableCellParagraphStyles(in: compile(markdown))
        XCTAssertEqual(cells.map(\.baseWritingDirection), Array(repeating: .leftToRight, count: 4))
        XCTAssertEqual(cells.map(\.alignment), [.left, .right, .left, .right])
    }

    func testPlainTableFallbackRowsUseOneLeftToRightColumnOrder() {
        // More rows than the inline NSTextTable layout accepts forces the plain fallback.
        let rows = (0 ..< 301).map { "| שורה \($0) | value \($0) |" }
        let markdown = (["| כותרת | Header |", "| --- | --- |"] + rows).joined(separator: "\n")
        let attributed = compile(markdown)

        let lines = attributed.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "כותרת  |  Header")
        XCTAssertEqual(lines.count, 302)
        // Rows are left-to-right paragraphs (column 0 on the left, like the NSTextTable path),
        // right-aligned because the table itself is right-to-left.
        var directions = Set<NSWritingDirection>()
        var alignments = Set<NSTextAlignment>()
        var location = 0
        for line in lines {
            let length = (line as NSString).length
            if length > 0 {
                let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
                directions.insert(style?.baseWritingDirection ?? .natural)
                alignments.insert(style?.alignment ?? .natural)
            }
            location += length + 1
        }
        XCTAssertEqual(directions, [.leftToRight])
        XCTAssertEqual(alignments, [.right])
        assertContainsNoBidiControls(attributed.string)
    }

    // MARK: - Helpers

    private func compile(_ markdown: String) -> NSAttributedString {
        let document = Markdown.Document(parsing: markdown)
        var compiler = EnhancedMarkdownCompiler()
        return compiler.attributedString(from: document)
    }

    private func markerDirections(in attributed: NSAttributedString, marker: String) -> [NSWritingDirection] {
        markerParagraphStyles(in: attributed, marker: marker).map(\.baseWritingDirection)
    }

    /// Paragraph styles at every occurrence of `marker` (the tab-wrapped list marker that starts
    /// each item's paragraph; TextKit takes the paragraph style from the paragraph's first character).
    private func markerParagraphStyles(in attributed: NSAttributedString, marker: String) -> [NSParagraphStyle] {
        let string = attributed.string as NSString
        var styles: [NSParagraphStyle] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: marker, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            let style = attributed.attribute(.paragraphStyle, at: found.location, effectiveRange: nil) as? NSParagraphStyle
            styles.append(style ?? NSParagraphStyle.default)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return styles
    }

    private struct TableCellStyle {
        let baseWritingDirection: NSWritingDirection
        let alignment: NSTextAlignment
        let block: NSTextTableBlock
    }

    private func tableCellParagraphStyles(in attributed: NSAttributedString) -> [TableCellStyle] {
        var cells: [TableCellStyle] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock
            else { return }
            cells.append(TableCellStyle(
                baseWritingDirection: style.baseWritingDirection,
                alignment: style.alignment,
                block: block
            ))
        }
        return cells
    }

    private func assertWritingDirectionRuns(
        in attributed: NSAttributedString,
        equal expectedRanges: [NSRange],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualRanges: [NSRange] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.writingDirection, in: fullRange) { value, range, _ in
            guard let directions = value as? [NSNumber] else { return }
            XCTAssertEqual(directions, [leftToRightEmbedding], file: file, line: line)
            actualRanges.append(range)
        }
        XCTAssertEqual(actualRanges, expectedRanges, file: file, line: line)
    }

    private func range(of substring: String, in string: String) -> NSRange {
        let result = (string as NSString).range(of: substring)
        XCTAssertNotEqual(result.location, NSNotFound)
        return result
    }

    private func assertContainsNoBidiControls(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bidiControlValues = Set<UInt32>([
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ])
        XCTAssertFalse(
            string.unicodeScalars.contains { bidiControlValues.contains($0.value) },
            file: file,
            line: line
        )
    }
}

/// Follow-up to #1596 (#654): first-strong detection from real Unicode bidi classes, list
/// continuation paragraphs that keep the list's direction and indent, fallback tables whose column
/// order does not depend on the script of each row, and quotes that keep list/table styles.
/// Geometry assertions are relative (same edge, left of, right of), never absolute coordinates.
@MainActor
final class EnhancedMarkdownCompilerStructureLayoutTests: XCTestCase {
    private let leftToRightEmbedding = NSNumber(
        value: NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue
    )

    // MARK: - First-strong detection (UAX #9 P2)

    func testFirstStrongUsesBidiClassesOfMarksAndNonLetters() {
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "\u{200F}English"), .rightToLeft, "RLM is R")
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "\u{200E}עברית"), .leftToRight, "LRM is L")
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "\u{061C}English"), .rightToLeft, "ALM is AL")
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "؟ English"), .rightToLeft, "Arabic question mark is AL")
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "\u{05BE}English"), .rightToLeft, "Hebrew maqaf is R")
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "12. — (שלום) hello"), .rightToLeft)
        XCTAssertEqual(MarkdownStructureDirection.firstStrongDirection(in: "٣ items"), .leftToRight, "Arabic-Indic digits are AN")
        XCTAssertNil(MarkdownStructureDirection.firstStrongDirection(in: "123 — ! ٤٥"))
    }

    func testFirstStrongSkipsIsolatesAndOnlyTheEmbeddingControlsThemselves() {
        let direction = MarkdownStructureDirection.firstStrongDirection(in:)
        XCTAssertEqual(direction("\u{2067}עברית\u{2069} English"), .leftToRight, "RLI…PDI content is skipped")
        XCTAssertEqual(direction("\u{2068}English\u{2069}עברית"), .rightToLeft, "FSI…PDI content is skipped")
        XCTAssertEqual(direction("\u{2066}\u{2067}א\u{2069}b\u{2069}ג"), .rightToLeft, "nested isolates are matched")
        XCTAssertEqual(direction("\u{2069}עברית"), .rightToLeft, "an unmatched PDI is ignored")
        XCTAssertNil(direction("\u{2066}English"), "an unmatched initiator hides the rest of the paragraph")
        XCTAssertEqual(direction("\u{2067}\u{202C}א\u{2069}b"), .leftToRight, "PDF does not close an isolate")
        XCTAssertEqual(direction("\u{202B}English"), .leftToRight, "RLE is skipped, its content is not")
        XCTAssertEqual(direction("\u{202E}English"), .leftToRight, "RLO is skipped, its content is not")
        XCTAssertEqual(direction("\u{2067}abc\u{2029}עברית"), .rightToLeft, "a paragraph separator ends the isolate")

        let deep = 130 // beyond the bidi algorithm's 125-level rendering limit
        let opened = String(repeating: "\u{2066}", count: deep)
        XCTAssertNil(direction(opened + String(repeating: "\u{2069}", count: deep - 1) + "א"))
        XCTAssertEqual(direction(opened + String(repeating: "\u{2069}", count: deep) + "א"), .rightToLeft)
    }

    func testIsolatesSpanInlineNodesButEndAtHardBreaksAndBlocks() {
        func direction(_ markdown: String) -> NSWritingDirection? {
            MarkdownStructureDirection.baseWritingDirection(for: Markdown.Document(parsing: markdown))
        }
        XCTAssertEqual(direction("- \u{2067}*עברית*\u{2069} English"), .leftToRight, "isolate spans emphasis")
        XCTAssertEqual(direction("- \u{2067}[עברית](https://example.com)\u{2069} English"), .leftToRight, "isolate spans a link")
        XCTAssertNil(direction("- \u{2067}abc\n  עברית"), "a soft break stays in the paragraph")
        XCTAssertEqual(direction("- \u{2067}abc  \n  עברית"), .rightToLeft, "a hard break starts a new paragraph")
        XCTAssertEqual(direction("- \u{2067}abc\n- עברית"), .rightToLeft, "each item starts a new paragraph")
    }

    func testListStartingWithRightToLeftMarkResolvesRightToLeft() {
        let attributed = compile("- \u{200F}English\n- More English")
        XCTAssertEqual(attributed.string, "\t•\t\u{200F}English\n\t•\tMore English")
        XCTAssertEqual(paragraphStyles(atOccurrencesOf: "\t•\t", in: attributed).map(\.baseWritingDirection), [.rightToLeft, .rightToLeft])
    }

    // MARK: - List continuation paragraphs

    func testContinuationParagraphsKeepListDirectionAndContentIndent() {
        let cases: [(markdown: String, expected: String, marker: String, continuation: String)] = [
            ("- עברית ראשונה  \n  שורה המשך", "\t•\tעברית ראשונה\nשורה המשך", "\t•\t", "שורה המשך"),
            ("- עברית ראשונה\n\n  פסקה שנייה", "\t•\tעברית ראשונה\nפסקה שנייה", "\t•\t", "פסקה שנייה"),
            ("1. עברית ראשונה\n\n   פסקה שנייה\n2. שני", "\t1.\tעברית ראשונה\nפסקה שנייה\n\t2.\tשני", "\t1.\t", "פסקה שנייה"),
            ("- First English  \n  continued here", "\t•\tFirst English\ncontinued here", "\t•\t", "continued here")
        ]
        for testCase in cases {
            let attributed = compile(testCase.markdown)
            XCTAssertEqual(attributed.string, testCase.expected, testCase.markdown)
            let marker = paragraphStyles(atOccurrencesOf: testCase.marker, in: attributed)[0]
            let continuation = paragraphStyle(at: range(of: testCase.continuation, in: attributed).location, in: attributed)
            XCTAssertEqual(continuation.baseWritingDirection, marker.baseWritingDirection, testCase.markdown)
            XCTAssertNotEqual(continuation.baseWritingDirection, .natural, testCase.markdown)
            XCTAssertGreaterThan(marker.headIndent, 0, testCase.markdown)
            XCTAssertEqual(continuation.headIndent, marker.headIndent, testCase.markdown)
            XCTAssertEqual(continuation.firstLineHeadIndent, marker.headIndent, testCase.markdown)
            XCTAssertEqual(marker.firstLineHeadIndent, 0, testCase.markdown)
            assertContainsNoBidiControls(attributed.string)
        }
    }

    func testItemContinuationKeepsNestedListCodeBlockAndInlineCodeStyles() {
        let markdown = """
        - עברית `--flag` ראשונה
          - פנימי
          ```
          code line
          ```
          פסקה אחרונה
        """
        let attributed = compile(markdown)
        let string = attributed.string
        let outer = paragraphStyle(at: 0, in: attributed)
        let nestedMarker = paragraphStyles(atOccurrencesOf: "\t•\t", in: attributed)[1]
        XCTAssertGreaterThan(nestedMarker.headIndent, outer.headIndent, "nested list keeps its deeper indent")

        let code = paragraphStyle(at: range(of: "code line", in: attributed).location, in: attributed)
        XCTAssertEqual(code.headIndent, 8, "code block keeps its own inset style")
        XCTAssertEqual(code.baseWritingDirection, .natural)

        let last = paragraphStyle(at: range(of: "פסקה אחרונה", in: attributed).location, in: attributed)
        XCTAssertEqual(last.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(last.firstLineHeadIndent, outer.headIndent)

        let flag = range(of: "--flag", in: attributed)
        XCTAssertEqual(attributed.attribute(.writingDirection, at: flag.location, effectiveRange: nil) as? [NSNumber], [leftToRightEmbedding])
        XCTAssertTrue(string.hasPrefix("\t•\tעברית --flag ראשונה\n"))
    }

    func testEmptyItemsAndItemsThatStartWithBlocksKeepThoseBlocksStyles() {
        let empty = compile("- \n- עברית")
        XCTAssertEqual(empty.string, "\t•\t\n\t•\tעברית")
        XCTAssertEqual(paragraphStyles(atOccurrencesOf: "\t•\t", in: empty).map(\.baseWritingDirection), [.rightToLeft, .rightToLeft])

        let codeFirst = compile("- ```\n  code line\n  ```\n- עברית")
        let code = paragraphStyle(at: range(of: "code line", in: codeFirst).location, in: codeFirst)
        XCTAssertEqual(code.headIndent, 8, "a leading code block is not restyled as the marker line")

        let listFirst = compile("- - פנימי\n- חיצוני")
        let markers = paragraphStyles(atOccurrencesOf: "\t•\t", in: listFirst)
        XCTAssertEqual(markers.count, 3)
        XCTAssertGreaterThan(markers[1].headIndent, markers[0].headIndent, "a leading nested list keeps its indent")

        let tableFirst = compile("- | א | ב |\n  | - | - |\n  | 1 | 2 |")
        XCTAssertEqual(tableCellStyleCount(in: tableFirst), 4, "a leading table keeps its text blocks")
    }

    func testWrappedAndContinuationLinesStartAtTheContentEdge() {
        let hebrew = Array(repeating: "מילה ארוכה", count: 12).joined(separator: " ")
        let english = Array(repeating: "longer words", count: 12).joined(separator: " ")
        for (text, isRightToLeft) in [(hebrew, true), (english, false)] {
            let attributed = compile("- \(text)  \n  \(text)\n\n  \(text)")
            let layout = Layout(attributed, width: 220)
            let full = NSRange(location: 0, length: attributed.length)
            let markerLength = ("\t•\t" as NSString).length
            var starts = layout.lineStartCharacters(in: full)
            XCTAssertGreaterThan(starts.count, 6, "text must wrap at this width")
            XCTAssertEqual(starts.first, 0)
            starts[0] = markerLength
            let edges = starts.map { layout.leadingEdge(ofCharacterAt: $0, rightToLeft: isRightToLeft) }
            // Wrapped and continuation lines start exactly at `headIndent`; the marker line reaches
            // the same edge through the content tab stop, which TextKit rounds by about a point in
            // right-to-left paragraphs.
            for edge in edges.dropFirst() {
                XCTAssertEqual(edge, edges[1], accuracy: 0.5, "wrapped and continuation lines share the content edge")
            }
            XCTAssertEqual(edges[0], edges[1], accuracy: 2, "the marker line's content starts at the same edge")
            let marker = layout.rect(of: NSRange(location: 1, length: 1))
            if isRightToLeft {
                XCTAssertGreaterThan(marker.maxX, edges[0] + 1, "RTL marker sits right of the content")
            } else {
                XCTAssertLessThan(marker.maxX, edges[0] + 1, "LTR marker sits left of the content")
            }
        }
    }

    // MARK: - Fallback tables

    func testFallbackTableColumnOrderIgnoresTheScriptOfEachRow() {
        for header in ["| כותרת | עמודה |", "| Header | Column |"] {
            let attributed = compile(tableMarkdown(header: header, rows: alternatingRows(count: 301)))
            XCTAssertEqual(tableCellStyleCount(in: attributed), 0, "301 rows use the plain fallback")
            assertColumnsInStringOrder(attributed, lines: 0 ..< 6, header)
        }
    }

    func testFallbackTableEdgeCellsKeepColumnOrder() {
        let edgeRows = [
            "| `--only-code` | `a` and `b` |",
            "| 123 | 4.5 |",
            "| | empty-left |",
            "| empty-right | |",
            "| A\u{202C}lpha | Beta |",
            "| A\u{2069}lpha | Beta |",
            "| \u{202B}Alpha | Beta |",
            "| \u{202E}עברית | ערך |",
            "| \u{202D}עברית | ערך |",
            "| ערך! | 456 |",
            "| עברית English | ערך |"
        ]
        for header in ["| כותרת | עמודה |", "| Header | Column |"] {
            let rows = edgeRows + alternatingRows(count: 300)
            let attributed = compile(tableMarkdown(header: header, rows: rows))
            XCTAssertEqual(tableCellStyleCount(in: attributed), 0)
            assertColumnsInStringOrder(attributed, lines: 1 ..< 1 + edgeRows.count, header)
        }
    }

    func testFallbackTableEmbedsCellsAroundExistingDirectionsAndKeepsBackingString() {
        let rows = [
            "| `--only-code` | `a` and `b` |",
            "| | [קישור](https://example.com/a) |",
            "| \u{2067}עברית | ערך |"
        ] + alternatingRows(count: 300)
        let attributed = compile(tableMarkdown(header: "| כותרת | Header |", rows: rows))
        let lines = attributed.string.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), [
            "כותרת  |  Header",
            "--only-code  |  a and b",
            "  |  קישור",
            "\u{2067}עברית  |  ערך"
        ], "the backing string is unchanged apart from layout separators")

        let string = attributed.string as NSString
        let codeLine = string.range(of: "--only-code  |  a and b")
        var runs: [String: [NSNumber]] = [:]
        var separatorDirections: [[NSNumber]?] = []
        attributed.enumerateAttribute(.writingDirection, in: codeLine) { value, range, _ in
            let text = string.substring(with: range)
            if text.contains("|") {
                separatorDirections.append(value as? [NSNumber])
            } else {
                runs[text] = value as? [NSNumber]
            }
        }
        XCTAssertEqual(runs["--only-code"], [leftToRightEmbedding, leftToRightEmbedding])
        XCTAssertEqual(runs["a"], [leftToRightEmbedding, leftToRightEmbedding])
        XCTAssertEqual(runs[" and "], [leftToRightEmbedding])
        XCTAssertEqual(runs["b"], [leftToRightEmbedding, leftToRightEmbedding])
        XCTAssertEqual(separatorDirections, [nil], "separators stay outside every cell embedding")

        let link = string.range(of: "קישור")
        var linkRange = NSRange()
        XCTAssertNotNil(attributed.attribute(.link, at: link.location, effectiveRange: &linkRange))
        XCTAssertEqual(linkRange, link, "links keep their exact ranges")
        // Embeddings do not isolate: an unmatched isolate initiator inside a cell may still reorder
        // its row, so only the attributes are pinned for that case.
        let isolate = string.range(of: "\u{2067}עברית")
        XCTAssertEqual(attributed.attribute(.writingDirection, at: isolate.location, effectiveRange: nil) as? [NSNumber], [leftToRightEmbedding])
    }

    func testNeutralFallbackTableGetsNoExplicitDirection() {
        let rows = ["| `a` | 3 |"] + (0 ..< 301).map { "| \($0) | \($0 * 2) |" }
        let attributed = compile(tableMarkdown(header: "| 1 | 2 |", rows: rows))
        XCTAssertEqual(tableCellStyleCount(in: attributed), 0)
        let style = paragraphStyle(at: 0, in: attributed)
        XCTAssertEqual(style.baseWritingDirection, .natural)
        XCTAssertEqual(style.alignment, .natural)
        var directions: [[NSNumber]] = []
        attributed.enumerateAttribute(.writingDirection, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let value = value as? [NSNumber] { directions.append(value) }
        }
        XCTAssertEqual(directions, [[leftToRightEmbedding]], "only the inline code keeps its embedding")
    }

    func testColumnOrderMatchesAcrossTheTextTableAndFallbackSwitchPoints() {
        for header in ["| כותרת | עמודה |", "| Header | Column |"] {
            // 300 rows including the header still use NSTextTable; 301 switch to the fallback.
            for (bodyRows, usesTextTable) in [(299, true), (300, false)] {
                let attributed = compile(tableMarkdown(header: header, rows: alternatingRows(count: bodyRows)))
                XCTAssertEqual(tableCellStyleCount(in: attributed) > 0, usesTextTable, "\(bodyRows) body rows")
                assertColumnsInStringOrder(attributed, cells: firstCells(count: 4), header)
            }
            // The character budget (50,000) switches independently of the row count.
            for (fillerLength, usesTextTable) in [(470, true), (520, false)] {
                let filler = String(repeating: "word ", count: fillerLength / 5)
                let rows = alternatingRows(count: 100).map { $0 + " \(filler) |" }
                let attributed = compile(tableMarkdown(header: String(header.dropLast()) + "| x |", rows: rows))
                XCTAssertEqual(tableCellStyleCount(in: attributed) > 0, usesTextTable, "filler \(fillerLength)")
                assertColumnsInStringOrder(attributed, cells: firstCells(count: 4), header)
            }
        }
    }

    // MARK: - Block quotes

    func testQuotedListsAndTablesKeepTheirStylesIndentedByTheQuote() {
        let list = "- עברית ראשונה  \n  שורה המשך"
        let plain = compile(list)
        let quoted = compile(list.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
        XCTAssertEqual(quoted.string, plain.string)
        for text in ["\t•\t", "שורה המשך"] {
            let before = paragraphStyle(at: range(of: text, in: plain).location, in: plain)
            let after = paragraphStyle(at: range(of: text, in: quoted).location, in: quoted)
            XCTAssertEqual(after.baseWritingDirection, .rightToLeft, text)
            XCTAssertEqual(after.headIndent, before.headIndent + 20, text)
            XCTAssertEqual(after.firstLineHeadIndent, before.firstLineHeadIndent + 20, text)
            XCTAssertEqual(after.tabStops.map(\.location), before.tabStops.map { $0.location + 20 }, text)
        }

        let table = compile("> | מפתח | Value |\n> | --- | --- |\n> | עברית | x |")
        XCTAssertEqual(tableCellStyleCount(in: table), 4, "quoted table cells keep their text blocks")
        let quotedParagraph = compile("> עברית רגילה")
        XCTAssertEqual(paragraphStyle(at: 0, in: quotedParagraph).headIndent, 20, "plain quoted prose is unchanged")
    }

    // MARK: - Helpers

    private func compile(_ markdown: String) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        return compiler.attributedString(from: Markdown.Document(parsing: markdown))
    }

    private func tableMarkdown(header: String, rows: [String]) -> String {
        let columns = header.count(where: { $0 == "|" }) - 1
        let separator = "|" + Array(repeating: " --- |", count: columns).joined()
        return ([header, separator] + rows).joined(separator: "\n")
    }

    /// Even rows are English, odd rows Hebrew, so neighbouring rows resolve opposite directions.
    private func alternatingRows(count: Int) -> [String] {
        (0 ..< count).map { $0.isMultiple(of: 2) ? "| English\($0) | Value\($0) |" : "| עברית\($0) | ערך\($0) |" }
    }

    private func firstCells(count: Int) -> [[String]] {
        (0 ..< count).map { $0.isMultiple(of: 2) ? ["English\($0)", "Value\($0)"] : ["עברית\($0)", "ערך\($0)"] }
    }

    /// Column 0 is left of column 1 (TextKit lays NSTextTable columns out in string order).
    private func assertColumnsInStringOrder(
        _ attributed: NSAttributedString,
        cells: [[String]],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layout = Layout(attributed, width: 2000)
        for row in cells {
            let xs = row.map { layout.rect(of: range(of: $0, in: attributed)).minX }
            XCTAssertEqual(xs, xs.sorted(), "\(message): \(row)", file: file, line: line)
        }
    }

    /// Same check for fallback rows given by line index; cells are split at the "  |  " separator.
    private func assertColumnsInStringOrder(
        _ attributed: NSAttributedString,
        lines: Range<Int>,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layout = Layout(attributed, width: 2000)
        let string = attributed.string as NSString
        var lineStart = 0
        for (index, text) in attributed.string.components(separatedBy: "\n").enumerated() {
            defer { lineStart += (text as NSString).length + 1 }
            guard lines.contains(index) else { continue }
            var cellStart = lineStart
            var cellRanges: [NSRange] = []
            for cell in text.components(separatedBy: "  |  ") {
                let length = (cell as NSString).length
                if length > 0 { cellRanges.append(NSRange(location: cellStart, length: length)) }
                cellStart += length + 5
            }
            let xs = cellRanges.map { layout.rect(of: $0).minX }
            XCTAssertEqual(xs, xs.sorted(), "\(message): \(string.substring(with: NSRange(location: lineStart, length: (text as NSString).length)))", file: file, line: line)
        }
    }

    private func paragraphStyle(at location: Int, in attributed: NSAttributedString) -> NSParagraphStyle {
        attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
    }

    private func paragraphStyles(atOccurrencesOf marker: String, in attributed: NSAttributedString) -> [NSParagraphStyle] {
        let string = attributed.string as NSString
        var styles: [NSParagraphStyle] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: marker, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            styles.append(paragraphStyle(at: found.location, in: attributed))
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return styles
    }

    private func tableCellStyleCount(in attributed: NSAttributedString) -> Int {
        var count = 0
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { count += 1 }
        }
        return count
    }

    private func range(of substring: String, in attributed: NSAttributedString) -> NSRange {
        let result = (attributed.string as NSString).range(of: substring)
        XCTAssertNotEqual(result.location, NSNotFound, substring)
        return result
    }

    private func assertContainsNoBidiControls(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        let controls = Set<UInt32>([0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069])
        XCTAssertFalse(string.unicodeScalars.contains { controls.contains($0.value) }, file: file, line: line)
    }
}

/// TextKit 1 layout of an attributed string, matching the Markdown views' NSLayoutManager.
/// Layout is computed lazily, so sampling the first rows of a large table stays cheap.
@MainActor
private struct Layout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer

    init(_ attributed: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: attributed)
        container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func rect(of range: NSRange) -> NSRect {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// The leading edge (right for RTL, left for LTR) of the glyph for one character.
    func leadingEdge(ofCharacterAt index: Int, rightToLeft: Bool) -> CGFloat {
        let glyph = rect(of: NSRange(location: index, length: 1))
        return rightToLeft ? glyph.maxX : glyph.minX
    }

    /// Character index of the first character of every line fragment in `range`.
    func lineStartCharacters(in range: NSRange) -> [Int] {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var starts: [Int] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            starts.append(manager.characterIndexForGlyph(at: lineGlyphs.location))
        }
        return starts
    }
}
