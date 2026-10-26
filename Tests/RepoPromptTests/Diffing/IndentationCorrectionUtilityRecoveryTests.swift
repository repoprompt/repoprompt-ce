@testable import RepoPromptApp
import XCTest

final class IndentationCorrectionUtilityRecoveryTests: XCTestCase {
    func testReIndentConvertsBetweenSpacesAndTabsAndAbsorbsLeakedLeadingTabs() {
        let spaceStyle = IndentCorrectionUtility.reIndentUsingSearchBlock(
            oldBlock: [
                "<s4>if ready {",
                "<s8>work()",
                "<s4>}"
            ],
            searchBlock: [
                "<s4>if ready {",
                "<s8>work()",
                "<s4>}"
            ],
            newSnippet: [
                "<t1>if ready {",
                "<t2>\twork()",
                "<t1>}"
            ]
        )

        XCTAssertEqual(spaceStyle.count, 3)
        guard spaceStyle.count > 1 else { return }
        XCTAssertTrue(spaceStyle.allSatisfy { String.getIndentationEncoding(from: $0).type == "s" })
        XCTAssertFalse(spaceStyle.contains { String.removeIndentationTag($0).hasPrefix("\t") })
        XCTAssertEqual(String.getIndentationLevel(from: spaceStyle[1]), 12)

        let tabStyle = IndentCorrectionUtility.reIndentUsingSearchBlock(
            oldBlock: [
                "<t1>switch value {",
                "<t2>case 1: break",
                "<t1>}"
            ],
            searchBlock: [
                "<t1>switch value {",
                "<t2>case 1: break",
                "<t1>}"
            ],
            newSnippet: [
                "<s4>switch value {",
                "<s8>case 2: break",
                "<s4>}"
            ]
        )

        XCTAssertTrue(tabStyle.allSatisfy { String.getIndentationEncoding(from: $0).type == "t" })
        XCTAssertEqual(tabStyle.map { String.getIndentationLevel(from: $0) }, [1, 2, 1])
    }
}
