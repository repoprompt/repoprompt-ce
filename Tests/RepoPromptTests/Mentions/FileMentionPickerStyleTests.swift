@testable import RepoPromptApp
import XCTest

final class FileMentionPickerStyleTests: XCTestCase {
    func testCompactConfigurationPreservesExistingDefaults() {
        XCTAssertEqual(FileMentionPickerStyle.defaultStyle, .compact)
        XCTAssertEqual(FileMentionPickerStyle.compact.displayName, "Compact")

        let configuration = FileMentionPickerStyle.compact.configuration
        XCTAssertEqual(configuration.maxResults, 5)
        XCTAssertEqual(configuration.visibleRows, 5)
        XCTAssertEqual(configuration.overlayWidth, 240)
        XCTAssertFalse(configuration.showsFileSubtitles)
    }

    func testExpandedConfigurationUsesRoomierFilePickerValues() {
        XCTAssertEqual(FileMentionPickerStyle.expanded.displayName, "Expanded")

        let configuration = FileMentionPickerStyle.expanded.configuration
        XCTAssertEqual(configuration.maxResults, 99)
        XCTAssertEqual(configuration.visibleRows, 10)
        XCTAssertEqual(configuration.overlayWidth, 480)
        XCTAssertTrue(configuration.showsFileSubtitles)
    }

    func testNormalizationDefaultsMissingEmptyAndInvalidRawValuesToCompact() {
        XCTAssertEqual(FileMentionPickerStyle.normalized(rawValue: nil), .compact)
        XCTAssertEqual(FileMentionPickerStyle.normalized(rawValue: ""), .compact)
        XCTAssertEqual(FileMentionPickerStyle.normalized(rawValue: "   \n"), .compact)
        XCTAssertEqual(FileMentionPickerStyle.normalized(rawValue: "wide"), .compact)
        XCTAssertEqual(FileMentionPickerStyle.normalized(rawValue: "expanded"), .expanded)
    }
}
