import Foundation
@testable import RepoPromptApp
import XCTest

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
