import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

final class NonProseURLLinkificationBoundaryTests: XCTestCase {
    @MainActor
    func testUnifiedDiffKeepsRTLFirstLinesAfterTheGutter() {
        let deletion = "-العربية Sources/App/main.swift"
        let addition = "+עברית --flag"
        let context = " שָׁלוֹם 👩‍💻"
        let document = UnifiedDiffCardRendering.parse(
            ["@@ -10,2 +20,2 @@", deletion, addition, context].joined(separator: "\n")
        )
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            colorScheme: .light,
            lineSpacing: 2
        ).build()
        let prefixes = ["10     ", "   20  ", "11 21  "]
        XCTAssertEqual(attributed.string, [
            prefixes[0] + deletion, prefixes[1] + addition, prefixes[2] + context
        ].joined(separator: "\n"))

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 580, height: 200))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let logicalText = storage.string as NSString

        var markerX: [CGFloat] = []
        for (prefix, line) in zip(prefixes, [deletion, addition, context]) {
            let range = logicalText.range(of: prefix + line)
            guard range.location != NSNotFound else { return XCTFail("Missing rendered diff line: \(line)") }
            let markerLocation = range.location + prefix.utf16.count
            let style = storage.attribute(.paragraphStyle, at: markerLocation, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.baseWritingDirection, .leftToRight)

            let gutterGlyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let markerGlyph = layoutManager.glyphIndexForCharacter(at: markerLocation)
            let bodyStart = markerLocation + 1
            let bodyLength = NSMaxRange(range) - bodyStart
            let bodyGlyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: bodyStart, length: bodyLength),
                actualCharacterRange: nil
            )
            let x = layoutManager.location(forGlyphAt: markerGlyph).x
            let bodyBounds = layoutManager.boundingRect(forGlyphRange: bodyGlyphs, in: container)
            XCTAssertEqual(layoutManager.location(forGlyphAt: gutterGlyph).x, 0, accuracy: 0.5)
            XCTAssertLessThan(x, bodyBounds.minX)
            markerX.append(x)
        }
        XCTAssertEqual(markerX[0], markerX[1], accuracy: 0.5)
        XCTAssertEqual(markerX[1], markerX[2], accuracy: 0.5)
    }

    @MainActor
    func testUnifiedDiffAttributedTextDoesNotAddLinksForURLsInDiffLines() {
        let document = UnifiedDiffCardRendering.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old https://deleted.example
        +new https://added.example
        """)
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            colorScheme: .light,
            lineSpacing: 2
        ).build()

        XCTAssertTrue(linkedSubstrings(in: attributed).isEmpty)
    }
}
