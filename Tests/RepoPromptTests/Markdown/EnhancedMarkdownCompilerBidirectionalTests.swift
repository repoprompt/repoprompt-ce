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

    func testPlainTableFallbackRowsShareTheTableDirection() {
        // More rows than the inline NSTextTable layout accepts forces the plain fallback.
        let rows = (0 ..< 301).map { "| שורה \($0) | value \($0) |" }
        let markdown = (["| כותרת | Header |", "| --- | --- |"] + rows).joined(separator: "\n")
        let attributed = compile(markdown)

        let lines = attributed.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "כותרת  |  Header")
        XCTAssertEqual(lines.count, 302)
        var directions = Set<NSWritingDirection>()
        var location = 0
        for line in lines {
            let length = (line as NSString).length
            if length > 0 {
                let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
                directions.insert(style?.baseWritingDirection ?? .natural)
            }
            location += length + 1
        }
        XCTAssertEqual(directions, [.rightToLeft])
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
