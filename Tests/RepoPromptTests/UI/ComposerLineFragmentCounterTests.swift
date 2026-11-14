import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ComposerLineFragmentCounterTests: XCTestCase {
    private let maximumCountOfInterest = ResizableTextField.maximumVisibleLineFragmentCount

    func testSaturatedDraftDoesNotLayOutOrEnumerateTheWholeDocument() {
        let stack = ProbeLayoutStack(text: Self.newlineSeparatedLines(400), font: .systemFont(ofSize: 14))

        let count = stack.boundedCount(maximumCountOfInterest: maximumCountOfInterest)

        XCTAssertEqual(count, maximumCountOfInterest)
        XCTAssertLessThanOrEqual(
            stack.layoutManager.lineFragmentCallbackCount,
            maximumCountOfInterest,
            "A saturated draft must stop enumerating once the last height preset is reached"
        )
        XCTAssertLessThan(
            stack.layoutManager.firstUnlaidCharacterIndex(),
            stack.textStorage.length,
            "A saturated draft must not force layout for the whole document"
        )
    }

    func testSaturatedWrappedSingleLineDraftIsAlsoBounded() {
        let stack = ProbeLayoutStack(
            text: String(repeating: "wrapping composer draft ", count: 200),
            font: .systemFont(ofSize: 14)
        )

        let count = stack.boundedCount(maximumCountOfInterest: maximumCountOfInterest)

        XCTAssertEqual(count, maximumCountOfInterest)
        XCTAssertLessThanOrEqual(stack.layoutManager.lineFragmentCallbackCount, maximumCountOfInterest)
    }

    func testShorterDraftsKeepExactLineFragmentMeasurement() {
        for fontSize in [12.0, 14.0, 18.0] as [CGFloat] {
            let font = NSFont.systemFont(ofSize: fontSize)
            for lineCount in 1 ... maximumCountOfInterest {
                let text = Self.newlineSeparatedLines(lineCount)
                let bounded = ProbeLayoutStack(text: text, font: font)
                    .boundedCount(maximumCountOfInterest: maximumCountOfInterest)
                let exact = ProbeLayoutStack(text: text, font: font).exactCount()

                XCTAssertEqual(exact, lineCount, "font \(fontSize), \(lineCount) lines")
                XCTAssertEqual(bounded, exact, "font \(fontSize), \(lineCount) lines")
            }
        }
    }

    func testTrailingNewlineStillCountsTheEmptyLineFragment() {
        let text = "alpha\nbeta\n"
        let bounded = ProbeLayoutStack(text: text, font: .systemFont(ofSize: 14))
            .boundedCount(maximumCountOfInterest: maximumCountOfInterest)
        let exact = ProbeLayoutStack(text: text, font: .systemFont(ofSize: 14)).exactCount()

        XCTAssertEqual(exact, 3)
        XCTAssertEqual(bounded, exact)
    }

    func testEmptyDraftResolvesToTheSmallestHeightPreset() {
        let bounded = ProbeLayoutStack(text: "", font: .systemFont(ofSize: 14))
            .boundedCount(maximumCountOfInterest: maximumCountOfInterest)

        XCTAssertEqual(
            ResizableTextField.presetIndex(forVisibleLineFragmentCount: bounded, preset: .normal),
            0
        )
    }

    func testBoundedAndExactMeasurementsSelectTheSameHeightPreset() {
        for preset in FontScalePreset.allCases {
            for lineCount in 1 ... (maximumCountOfInterest + 4) {
                let text = Self.newlineSeparatedLines(lineCount)
                let bounded = ProbeLayoutStack(text: text, font: preset.nsFont)
                    .boundedCount(maximumCountOfInterest: maximumCountOfInterest)
                let exact = ProbeLayoutStack(text: text, font: preset.nsFont).exactCount()

                XCTAssertEqual(
                    ResizableTextField.presetIndex(forVisibleLineFragmentCount: bounded, preset: preset),
                    ResizableTextField.presetIndex(forVisibleLineFragmentCount: exact, preset: preset),
                    "preset \(preset), \(lineCount) lines"
                )
                XCTAssertEqual(
                    ResizableTextField.height(
                        forPresetIndex: ResizableTextField.presetIndex(
                            forVisibleLineFragmentCount: bounded,
                            preset: preset
                        ),
                        preset: preset
                    ),
                    ResizableTextField.height(
                        forPresetIndex: ResizableTextField.presetIndex(
                            forVisibleLineFragmentCount: exact,
                            preset: preset
                        ),
                        preset: preset
                    ),
                    "preset \(preset), \(lineCount) lines"
                )
            }
        }
    }

    private static func newlineSeparatedLines(_ count: Int) -> String {
        (0 ..< count).map { "line \($0)" }.joined(separator: "\n")
    }
}

@MainActor
private final class ProbeLayoutStack {
    let textStorage: NSTextStorage
    let layoutManager: SpyLayoutManager
    let textContainer: NSTextContainer
    let textView: NSTextView

    init(text: String, font: NSFont, width: CGFloat = 320) {
        textStorage = NSTextStorage(string: text, attributes: [.font: font])
        layoutManager = SpyLayoutManager()
        textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.allowsNonContiguousLayout = true

        textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 120),
            textContainer: textContainer
        )
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = font
        textContainer.widthTracksTextView = true
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.resetCounters()
    }

    func boundedCount(maximumCountOfInterest: Int) -> Int {
        ComposerLineFragmentCounter.visibleLineFragmentCount(
            layoutManager: layoutManager,
            textContainer: textContainer,
            maximumCountOfInterest: maximumCountOfInterest
        )
    }

    func exactCount() -> Int {
        ComposerLineFragmentCounter.exactVisibleLineFragmentCount(
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }
}

private final class SpyLayoutManager: NSLayoutManager {
    private(set) var lineFragmentCallbackCount = 0

    func resetCounters() {
        lineFragmentCallbackCount = 0
    }

    override func enumerateLineFragments(
        forGlyphRange glyphRange: NSRange,
        using block: @escaping (NSRect, NSRect, NSTextContainer, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        super.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, container, range, stop in
            self.lineFragmentCallbackCount += 1
            block(rect, usedRect, container, range, stop)
        }
    }
}

final class AgentAssistantLineDerivationTests: XCTestCase {
    func testRecognizesEveryFoundationNewlineScalar() {
        let separators: [(name: String, scalar: Unicode.Scalar)] = [
            ("LF", "\n"),
            ("CR", "\r"),
            ("VT", "\u{000B}"),
            ("FF", "\u{000C}"),
            ("NEL", "\u{0085}"),
            ("line separator", "\u{2028}"),
            ("paragraph separator", "\u{2029}")
        ]

        for separator in separators {
            let text = "before\(String(separator.scalar))after"
            let bounded = AgentAssistantLineDerivation.lineCount(upTo: 10, in: text)
            let preview = AgentAssistantLineDerivation.previewSummary(
                for: text,
                previewLineCount: 10
            )

            XCTAssertEqual(bounded.count, 2, separator.name)
            XCTAssertTrue(bounded.isExact, separator.name)
            XCTAssertEqual(preview.lineCount, 2, separator.name)
            XCTAssertEqual(preview.previewText, "before\nafter", separator.name)
            XCTAssertFalse(preview.needsCollapse, separator.name)
        }
    }

    func testCRLFCountsAsTwoScalarSeparatorsAndMatchesPreview() {
        let shortText = "before\r\nafter"
        let shortCount = AgentAssistantLineDerivation.lineCount(upTo: 10, in: shortText)
        let shortPreview = AgentAssistantLineDerivation.previewSummary(
            for: shortText,
            previewLineCount: 10
        )

        XCTAssertEqual(shortCount.count, 3, "CRLF must increment once for CR and once for LF")
        XCTAssertTrue(shortCount.isExact)
        XCTAssertEqual(shortPreview.lineCount, shortCount.count)
        XCTAssertEqual(shortPreview.previewText, "before\n\nafter")
        XCTAssertFalse(shortPreview.needsCollapse)

        let lineLimit = 10
        let boundaryText = String(repeating: "line\n", count: 8) + "line\r\nfinal"
        let boundaryCount = AgentAssistantLineDerivation.lineCount(upTo: lineLimit, in: boundaryText)
        let boundaryPreview = AgentAssistantLineDerivation.previewSummary(
            for: boundaryText,
            previewLineCount: lineLimit
        )

        XCTAssertEqual(boundaryCount.count, 11)
        XCTAssertFalse(boundaryCount.isExact)
        XCTAssertEqual(boundaryPreview.lineCount, boundaryCount.count)
        XCTAssertTrue(boundaryPreview.needsCollapse)
        XCTAssertEqual(!boundaryCount.isExact || boundaryCount.count > lineLimit, boundaryPreview.needsCollapse)
    }

    func testEmptyAndTrailingSeparatorInputs() {
        let cases: [(name: String, text: String, count: Int, preview: String)] = [
            ("empty", "", 1, ""),
            ("trailing LF", "value\n", 2, "value\n"),
            ("trailing CR", "value\r", 2, "value\n"),
            ("trailing VT", "value\u{000B}", 2, "value\n"),
            ("trailing FF", "value\u{000C}", 2, "value\n"),
            ("trailing NEL", "value\u{0085}", 2, "value\n"),
            ("trailing line separator", "value\u{2028}", 2, "value\n"),
            ("trailing paragraph separator", "value\u{2029}", 2, "value\n"),
            ("trailing CRLF", "value\r\n", 3, "value\n\n")
        ]

        for testCase in cases {
            let bounded = AgentAssistantLineDerivation.lineCount(upTo: 10, in: testCase.text)
            let preview = AgentAssistantLineDerivation.previewSummary(
                for: testCase.text,
                previewLineCount: 10
            )

            XCTAssertEqual(bounded.count, testCase.count, testCase.name)
            XCTAssertTrue(bounded.isExact, testCase.name)
            XCTAssertEqual(preview.lineCount, testCase.count, testCase.name)
            XCTAssertEqual(preview.previewText, testCase.preview, testCase.name)
            XCTAssertFalse(preview.needsCollapse, testCase.name)
        }
    }

    func testCombiningAndEmojiGraphemesDoNotCreateLines() {
        let cases: [(name: String, text: String)] = [
            ("combining grapheme", "e\u{0301}"),
            ("emoji ZWJ grapheme", "👩🏽‍💻")
        ]

        for testCase in cases {
            let bounded = AgentAssistantLineDerivation.lineCount(upTo: 10, in: testCase.text)
            let preview = AgentAssistantLineDerivation.previewSummary(
                for: testCase.text,
                previewLineCount: 10
            )

            XCTAssertEqual(bounded.count, 1, testCase.name)
            XCTAssertTrue(bounded.isExact, testCase.name)
            XCTAssertEqual(preview.lineCount, 1, testCase.name)
            XCTAssertEqual(preview.previewText, testCase.text, testCase.name)
            XCTAssertFalse(preview.needsCollapse, testCase.name)
        }
    }

    func testLimitBoundariesReportExactnessAndMatchPreviewDecision() {
        let cases: [(limit: Int, lineCount: Int, expectedCount: Int, isExact: Bool)] = [
            (0, 11, 1, false),
            (9, 9, 9, true),
            (9, 10, 10, false),
            (10, 10, 10, true),
            (10, 11, 11, false),
            (11, 11, 11, true)
        ]

        for testCase in cases {
            let text = Array(repeating: "line", count: testCase.lineCount).joined(separator: "\n")
            let bounded = AgentAssistantLineDerivation.lineCount(upTo: testCase.limit, in: text)
            let preview = AgentAssistantLineDerivation.previewSummary(
                for: text,
                previewLineCount: testCase.limit
            )
            let message = "limit=\(testCase.limit), lines=\(testCase.lineCount)"

            XCTAssertEqual(bounded.count, testCase.expectedCount, message)
            XCTAssertEqual(bounded.isExact, testCase.isExact, message)
            XCTAssertEqual(!bounded.isExact || bounded.count > testCase.limit, preview.needsCollapse, message)
        }
    }
}
