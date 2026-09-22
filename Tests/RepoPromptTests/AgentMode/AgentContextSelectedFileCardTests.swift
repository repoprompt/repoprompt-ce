@testable import RepoPromptApp
import XCTest

final class AgentContextSelectedFileCardTests: XCTestCase {
    func testMetricRowPresentationSwitchesOnReadiness() {
        let unknownFull = AgentContextSelectedFileCardMetricRowPresentation.make(
            rowKind: .full,
            metrics: .unknown,
            parentPathDisplay: "Sources/Feature",
            displayPath: "Sources/Feature/App.swift",
            sliceCountText: nil
        )
        XCTAssertEqual(unknownFull.content, .pathOnly("Sources/Feature"))
        XCTAssertEqual(unknownFull.accessibilityLabel, "Path: Sources/Feature/App.swift")
        XCTAssertFalse(unknownFull.accessibilityLabel?.contains("tokens") ?? true)
        XCTAssertFalse(unknownFull.accessibilityLabel?.contains("selected context") ?? true)

        let unknownSlicedWithoutParent = AgentContextSelectedFileCardMetricRowPresentation.make(
            rowKind: .slices,
            metrics: .unknown,
            parentPathDisplay: nil,
            displayPath: "SliceOnly.swift",
            sliceCountText: "2"
        )
        XCTAssertEqual(unknownSlicedWithoutParent.content, .pathOnly("SliceOnly.swift"))
        XCTAssertEqual(
            unknownSlicedWithoutParent.accessibilityLabel,
            "Path: SliceOnly.swift, Selected slice ranges: 2"
        )

        let unknownCodemap = AgentContextSelectedFileCardMetricRowPresentation.make(
            rowKind: .codemap,
            metrics: .unknown,
            parentPathDisplay: "Sources/Generated",
            displayPath: "Sources/Generated/Map.swift",
            sliceCountText: nil
        )
        XCTAssertEqual(unknownCodemap.content, .hidden)
        XCTAssertNil(unknownCodemap.accessibilityLabel)

        let knownMetrics = AgentContextExportRow.Metrics.Known(
            tokenCount: 1234,
            tokenPercentage: 0.420,
            lineCount: 17
        )
        let knownSliced = AgentContextSelectedFileCardMetricRowPresentation.make(
            rowKind: .slices,
            metrics: .known(knownMetrics),
            parentPathDisplay: "Sources/Feature",
            displayPath: "Sources/Feature/App.swift",
            sliceCountText: "3"
        )
        XCTAssertEqual(knownSliced.content, .known(knownMetrics))
        XCTAssertTrue(
            knownSliced.accessibilityLabel?.contains("Approximate tokens: 1.2") ?? false
        )
        XCTAssertTrue(
            knownSliced.accessibilityLabel?.contains("Share of selected context: 42%") ?? false
        )
        XCTAssertTrue(
            knownSliced.accessibilityLabel?.contains("Included lines: 17") ?? false
        )
        XCTAssertTrue(
            knownSliced.accessibilityLabel?.contains("Selected slice ranges: 3") ?? false
        )
        XCTAssertEqual(AgentContextSelectedFileCardMetricRowPresentation.percentText(for: knownMetrics), "42%")
        let tokenTooltip = AgentContextSelectedFileCardMetricRowPresentation.tokenTooltip(for: knownMetrics)
        XCTAssertTrue(tokenTooltip.hasPrefix("≈"))
        XCTAssertTrue(tokenTooltip.contains("tokens"))
    }
}
