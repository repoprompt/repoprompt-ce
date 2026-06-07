import AppKit
import Markdown
@testable import RepoPrompt
import XCTest

@MainActor
final class MarkdownTextTableMeasurementTests: XCTestCase {
    func testSmallMarkdownTableUsesNSTextTableBlocks() {
        let attributed = compileMarkdown(
            """
            | Name | Count |
            | --- | ---: |
            | Alpha | 3 |
            | Beta | 12 |
            """
        )

        let blocks = textTableBlocks(in: attributed)
        XCTAssertGreaterThanOrEqual(blocks.count, 6)
        XCTAssertTrue(blocks.allSatisfy { $0.table.numberOfColumns == 2 })
        XCTAssertTrue(tableParagraphStyles(in: attributed).contains { $0.alignment == .right })
        XCTAssertTrue(attributed.string.contains("Alpha"))
        XCTAssertTrue(attributed.string.contains("Beta"))
    }

    func testRowCountLargeTableFallsBackToPlainText() {
        let attributed = compileMarkdown(generatedTable(bodyRowCount: 301))

        XCTAssertTrue(textTableBlocks(in: attributed).isEmpty)
        XCTAssertTrue(attributed.string.contains("  |  "))
        XCTAssertTrue(attributed.string.contains("row-0-col-0"))
        XCTAssertTrue(attributed.string.contains("row-300-col-1"))
    }

    func testCharacterCountLargeTableFallsBackToPlainText() {
        let oversizedCell = String(repeating: "x", count: 50001)
        let attributed = compileMarkdown(
            """
            | Name | Details |
            | --- | --- |
            | Alpha | \(oversizedCell) |
            """
        )

        XCTAssertTrue(textTableBlocks(in: attributed).isEmpty)
        XCTAssertTrue(attributed.string.contains("  |  "))
        XCTAssertTrue(attributed.string.contains(String(oversizedCell.prefix(128))))
    }

    func testWrappedTableMeasurementUsesTableOnlyGeometry() {
        let attributed = compileMarkdown(
            """
            Intro paragraph before the table to verify mixed Markdown keeps neighboring prose in the same TextKit view.

            | Item | Notes |
            | --- | --- |
            | Alpha | This cell contains enough prose to wrap repeatedly at narrow widths while remaining a single table cell. |
            | Beta | Another long description that should require more vertical space when the table is measured narrowly. |

            Closing paragraph after the table.
            """,
            fontSize: 22
        )
        XCTAssertFalse(textTableBlocks(in: attributed).isEmpty)

        let textView = configuredTextView(with: attributed)
        let wideHeight = textView.measuredHeight(constrainedTo: 520)
        let wideInset = textView.textContainerInset
        XCTAssertGreaterThan(wideInset.width, 0)
        XCTAssertGreaterThan(wideInset.height, 0)
        XCTAssertLessThanOrEqual(wideInset.width, 2)
        XCTAssertEqual(
            textView.textContainer?.containerSize.width ?? 0,
            520 - wideInset.width * 2,
            accuracy: 1
        )

        let narrowHeight = textView.measuredHeight(constrainedTo: 220)
        XCTAssertGreaterThan(narrowHeight, wideHeight)
        XCTAssertEqual(textView.lastMeasuredSize.width, 220, accuracy: 0.5)

        textView.setFrameSize(NSSize(width: 220, height: narrowHeight))
        XCTAssertEqual(
            textView.textContainer?.containerSize.width ?? 0,
            220 - textView.textContainerInset.width * 2,
            accuracy: 1
        )
    }

    func testTextTableDrawingRectIncludesRightAndBottomBorderAllowanceInsideViewBounds() throws {
        let attributed = compileMarkdown(
            """
            | Item | Notes | Status |
            | --- | --- | --- |
            | Alpha | This cell wraps enough text to make the table span several painted rows at a constrained width. | OK |
            | Beta | Another wrapped cell keeps the final row and outer border away from neighboring prose. | OK |
            | Gamma | Final row used to verify the bottom border remains inside the rendered view. | OK |
            """
        )
        XCTAssertFalse(textTableBlocks(in: attributed).isEmpty)

        let textView = configuredTextView(with: attributed)
        let width: CGFloat = 260
        let height = ceil(textView.measuredHeight(constrainedTo: width))
        textView.setFrameSize(NSSize(width: width, height: height))

        let container = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: container)

        let usedRect = layoutManager.usedRect(for: container)
        let textOrigin = textView.textContainerOrigin
        let drawingRect = usedRect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
        let collapsedBorderAllowance: CGFloat = 0.5

        XCTAssertGreaterThan(textView.textContainerInset.width, 0)
        XCTAssertLessThanOrEqual(drawingRect.maxX + collapsedBorderAllowance, textView.bounds.maxX + 0.5)
        XCTAssertLessThanOrEqual(drawingRect.maxY + collapsedBorderAllowance, textView.bounds.maxY + 0.5)
    }

    func testReusedTextViewResetsTableGeometryAcrossContentReplacement() {
        let tableAttributed = compileMarkdown(
            """
            | First | Second |
            | --- | --- |
            | Alpha | Wrapped table content that requires table-specific geometry. |
            """
        )
        let plainAttributed = compileMarkdown(
            """
            A plain paragraph with **bold** text, `inline code`, and enough trailing prose to wrap at a moderate width.

            - First item
            - Second item
            """
        )
        let textView = configuredTextView(with: tableAttributed)

        let width: CGFloat = 360
        let tableHeight = textView.measuredHeight(constrainedTo: width)
        textView.setFrameSize(NSSize(width: width, height: tableHeight))
        XCTAssertGreaterThan(textView.textContainerInset.width, 0)
        XCTAssertEqual(textView.textContainer?.containerSize.width ?? 0, width - textView.textContainerInset.width * 2, accuracy: 1)

        replaceContent(of: textView, with: plainAttributed)
        textView.resynchronizeTextLayoutGeometryForCurrentBounds()
        _ = textView.measuredHeight(constrainedTo: width)
        XCTAssertEqual(textView.textContainerInset.width, 0, accuracy: 0.01)
        XCTAssertEqual(textView.textContainerInset.height, 0, accuracy: 0.01)
        XCTAssertEqual(textView.textContainer?.containerSize.width ?? 0, width, accuracy: 0.5)

        replaceContent(of: textView, with: tableAttributed)
        textView.resynchronizeTextLayoutGeometryForCurrentBounds()
        _ = textView.measuredHeight(constrainedTo: width)
        XCTAssertGreaterThan(textView.textContainerInset.width, 0)
        XCTAssertEqual(textView.textContainer?.containerSize.width ?? 0, width - textView.textContainerInset.width * 2, accuracy: 1)
    }

    func testNonTableMarkdownKeepsZeroInsetAndFullEffectiveWidth() {
        let attributed = compileMarkdown(
            """
            A plain paragraph with **bold** text, `inline code`, and enough trailing prose to wrap at a moderate width.

            - First item
            - Second item
            """
        )
        XCTAssertTrue(textTableBlocks(in: attributed).isEmpty)

        let textView = configuredTextView(with: attributed)
        _ = textView.measuredHeight(constrainedTo: 360)

        XCTAssertEqual(textView.textContainerInset.width, 0, accuracy: 0.01)
        XCTAssertEqual(textView.textContainerInset.height, 0, accuracy: 0.01)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(textView.textContainer?.containerSize.width ?? 0, 360, accuracy: 0.5)
        XCTAssertEqual(textView.lastMeasuredSize.width, 360, accuracy: 0.5)
    }

    private func compileMarkdown(_ markdown: String, fontSize: CGFloat = 16) -> NSAttributedString {
        let document = Document(parsing: markdown)
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = fontSize
        return compiler.attributedString(from: document)
    }

    private func configuredTextView(with attributed: NSAttributedString) -> CodeBlockTextView {
        let textView = CodeBlockTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributed)
        textView.layoutManager?.allowsNonContiguousLayout = false
        textView.incrementContentVersion()
        return textView
    }

    private func replaceContent(of textView: CodeBlockTextView, with attributed: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributed)
        textView.incrementContentVersion()
    }

    private func textTableBlocks(in attributed: NSAttributedString) -> [NSTextTableBlock] {
        var blocks: [NSTextTableBlock] = []
        guard attributed.length > 0 else { return blocks }
        attributed.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let paragraphStyle = value as? NSParagraphStyle else { return }
            blocks.append(contentsOf: paragraphStyle.textBlocks.compactMap { $0 as? NSTextTableBlock })
        }
        return blocks
    }

    private func tableParagraphStyles(in attributed: NSAttributedString) -> [NSParagraphStyle] {
        var styles: [NSParagraphStyle] = []
        guard attributed.length > 0 else { return styles }
        attributed.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let paragraphStyle = value as? NSParagraphStyle,
                  paragraphStyle.textBlocks.contains(where: { $0 is NSTextTableBlock })
            else { return }
            styles.append(paragraphStyle)
        }
        return styles
    }

    private func generatedTable(bodyRowCount: Int) -> String {
        var lines = [
            "| First | Second |",
            "| --- | --- |"
        ]
        for rowIndex in 0 ..< bodyRowCount {
            lines.append("| row-\(rowIndex)-col-0 | row-\(rowIndex)-col-1 |")
        }
        return lines.joined(separator: "\n")
    }
}
