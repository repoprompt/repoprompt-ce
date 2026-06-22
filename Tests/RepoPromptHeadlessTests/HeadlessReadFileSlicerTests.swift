@testable import RepoPromptHeadless
import XCTest

final class HeadlessReadFileSlicerTests: XCTestCase {
    func testRejectsZeroStartLine() {
        XCTAssertThrowsError(try HeadlessReadFileSlicer.slice(text: "a\n", startLine: 0, limit: nil))
    }

    func testRejectsLimitWithNegativeStart() {
        XCTAssertThrowsError(try HeadlessReadFileSlicer.slice(text: "a\nb\n", startLine: -1, limit: 1))
    }

    func testNegativeStartReadsTailAndPreservesEndings() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "a\r\nb\nc", startLine: -2, limit: nil)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "b\nc", totalLines: 3, firstLine: 2, lastLine: 3, message: nil))
    }

    func testZeroLimitReturnsSuccessfulEmptySlice() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "a\nb\n", startLine: 2, limit: 0)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "", totalLines: 2, firstLine: 2, lastLine: 1, message: nil))
    }

    func testNegativeLimitWithPositiveStartIsUnbounded() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "a\nb\nc", startLine: 2, limit: -1)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "b\nc", totalLines: 3, firstLine: 2, lastLine: 3, message: nil))
    }

    func testStartBeyondEOFReturnsHelpfulMetadata() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "a\nb", startLine: 4, limit: nil)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "", totalLines: 2, firstLine: 4, lastLine: 2, message: "Requested start_line exceeds file length."))
    }

    func testEmptyFileHasZeroMetadataWithoutOutOfRangeMessage() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "", startLine: 50, limit: nil)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "", totalLines: 0, firstLine: 0, lastLine: 0, message: nil))
    }

    func testTrailingNewlineDoesNotCreatePhantomLine() throws {
        let result = try HeadlessReadFileSlicer.slice(text: "a\nb\n", startLine: nil, limit: nil)
        XCTAssertEqual(result, HeadlessReadFileSlice(content: "a\nb\n", totalLines: 2, firstLine: 1, lastLine: 2, message: nil))
    }
}
