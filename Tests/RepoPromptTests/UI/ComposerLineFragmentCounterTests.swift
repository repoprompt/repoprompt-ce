import AppKit
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
