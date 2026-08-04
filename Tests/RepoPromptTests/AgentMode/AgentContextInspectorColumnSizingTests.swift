import CoreGraphics
@testable import RepoPromptApp
import XCTest

final class AgentContextInspectorColumnSizingTests: XCTestCase {
    func testMetricsRespectDetailWidthRatioCapsAndOrdering() {
        let narrow = AgentContextInspectorColumnSizing.metrics(forDetailWidth: 600)
        XCTAssertEqual(narrow.minimumWidth, 320)
        XCTAssertEqual(narrow.idealWidth, 320)
        XCTAssertEqual(narrow.maximumWidth, 320)

        let chatPreserving = AgentContextInspectorColumnSizing.metrics(forDetailWidth: 900)
        XCTAssertEqual(chatPreserving.minimumWidth, 320)
        XCTAssertEqual(chatPreserving.idealWidth, 540)
        XCTAssertEqual(chatPreserving.maximumWidth, 540)

        let twoThirds = AgentContextInspectorColumnSizing.metrics(forDetailWidth: 1080)
        XCTAssertEqual(twoThirds.minimumWidth, 320)
        XCTAssertEqual(twoThirds.idealWidth, 720)
        XCTAssertEqual(twoThirds.maximumWidth, 720)

        let absoluteCapped = AgentContextInspectorColumnSizing.metrics(forDetailWidth: 1500)
        XCTAssertEqual(absoluteCapped.minimumWidth, 320)
        XCTAssertEqual(absoluteCapped.idealWidth, 800)
        XCTAssertEqual(absoluteCapped.maximumWidth, 800)

        for metrics in [narrow, chatPreserving, twoThirds, absoluteCapped] {
            XCTAssertLessThanOrEqual(metrics.minimumWidth, metrics.idealWidth)
            XCTAssertLessThanOrEqual(metrics.idealWidth, metrics.maximumWidth)
        }
    }
}
