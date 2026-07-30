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
