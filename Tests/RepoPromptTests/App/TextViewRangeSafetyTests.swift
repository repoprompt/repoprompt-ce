import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TextViewRangeSafetyTests: XCTestCase {
    func testRestoreSelectionCandidateClampsShorterAndEmptyReplacementsBeforeInstallation() {
        let textView = RecordingSelectionTextView(string: "prefix 👩‍💻 suffix")
        let previousLength = textView.currentStringLength()
        textView.setSelectedRange(NSRange(location: previousLength - 1, length: 1))
        let previousSelection = textView.selectedRange()

        textView.textStorage?.setAttributedString(NSAttributedString(string: "e\u{301}"))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.resetRecordedCalls()

        let shorterRestored = textView.restoreSelectionCandidate(previousSelection)

        XCTAssertEqual(textView.currentStringLength(), 2)
        XCTAssertEqual(shorterRestored, NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.selectedRange(), shorterRestored)
        XCTAssertTrue(textView.didReceiveSetSelectedRanges)
        assertRecordedSelectionsWereInBounds(textView)

        textView.textStorage?.setAttributedString(NSAttributedString())
        textView.resetRecordedCalls()

        let emptyRestored = textView.restoreSelectionCandidate(previousSelection)

        XCTAssertEqual(emptyRestored, NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.selectedRange(), emptyRestored)
        assertRecordedSelectionsWereInBounds(textView)
    }

    func testRestoreSelectionCandidatePreservesUTF16BoundariesAndTruncatesOverrun() {
        let content = "A👩‍💻e\u{301}Z"
        let nsContent = content as NSString
        let emojiRange = nsContent.range(of: "👩‍💻")
        let combiningRange = nsContent.range(of: "e\u{301}")
        let textView = RecordingSelectionTextView(string: content)

        for validRange in [emojiRange, combiningRange] {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.resetRecordedCalls()

            let restored = textView.restoreSelectionCandidate(validRange)

            XCTAssertEqual(restored, validRange)
            XCTAssertEqual(textView.selectedRange(), validRange)
            assertRecordedSelectionsWereInBounds(textView)
        }

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.resetRecordedCalls()
        let overrun = NSRange(location: combiningRange.location, length: nsContent.length)

        let restoredOverrun = textView.restoreSelectionCandidate(overrun)

        XCTAssertEqual(
            restoredOverrun,
            NSRange(
                location: combiningRange.location,
                length: nsContent.length - combiningRange.location
            )
        )
        XCTAssertEqual(textView.selectedRange(), restoredOverrun)
        assertRecordedSelectionsWereInBounds(textView)
    }

    func testRestoreSelectionCandidateHandlesNSNotFoundAndPreservesLegacyClampBehavior() {
        let textView = RecordingSelectionTextView(string: "abc")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.resetRecordedCalls()

        let restoredNotFound = textView.restoreSelectionCandidate(
            NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(restoredNotFound, NSRange(location: 3, length: 0))
        XCTAssertEqual(textView.selectedRange(), restoredNotFound)
        assertRecordedSelectionsWereInBounds(textView)

        let validSelection = NSRange(location: 1, length: 1)
        textView.setSelectedRange(validSelection)
        textView.resetRecordedCalls()

        let clamped = textView.clampSelectionToCurrentString(scrollToVisible: true)

        XCTAssertEqual(clamped, validSelection)
        XCTAssertEqual(textView.selectedRange(), validSelection)
        XCTAssertFalse(textView.didReceiveSetSelectedRanges)
        XCTAssertTrue(textView.scrolledRanges.contains(validSelection))
    }

    private func assertRecordedSelectionsWereInBounds(
        _ textView: RecordingSelectionTextView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for record in textView.recordedSelections {
            guard record.range.location != NSNotFound,
                  record.range.location >= 0,
                  record.range.location <= record.storageLength
            else {
                XCTFail(
                    "Installed range had invalid location \(record.range) for storage length \(record.storageLength)",
                    file: file,
                    line: line
                )
                continue
            }
            XCTAssertGreaterThanOrEqual(record.range.length, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                record.range.length,
                record.storageLength - record.range.location,
                file: file,
                line: line
            )
        }
    }
}

@MainActor
private final class RecordingSelectionTextView: NSTextView {
    struct RecordedSelection {
        let range: NSRange
        let storageLength: Int
    }

    private(set) var recordedSelections: [RecordedSelection] = []
    private(set) var scrolledRanges: [NSRange] = []
    private(set) var didReceiveSetSelectedRanges = false

    convenience init(string: String) {
        self.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        isEditable = true
        isSelectable = true
        isRichText = false
        self.string = string
        resetRecordedCalls()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let storageLength = textStorage?.length ?? (string as NSString).length
        didReceiveSetSelectedRanges = true
        recordedSelections.append(
            contentsOf: ranges.map {
                RecordedSelection(range: $0.rangeValue, storageLength: storageLength)
            }
        )
        super.setSelectedRanges(
            ranges,
            affinity: affinity,
            stillSelecting: stillSelectingFlag
        )
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        scrolledRanges.append(range)
        super.scrollRangeToVisible(range)
    }

    func resetRecordedCalls() {
        recordedSelections.removeAll(keepingCapacity: true)
        scrolledRanges.removeAll(keepingCapacity: true)
        didReceiveSetSelectedRanges = false
    }
}
