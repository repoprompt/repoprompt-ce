import Darwin
import Foundation
@testable import RepoPromptMCP
import XCTest

final class MCPBackendSelectionTests: XCTestCase {
    func testExplicitBackendsNeverProbeAppSocket() {
        var probeCount = 0
        let probe: () -> Bool = {
            probeCount += 1
            return false
        }

        XCTAssertEqual(MCPBackendSelection.resolve(requested: .app, appIsAvailable: probe), .app)
        XCTAssertEqual(MCPBackendSelection.resolve(requested: .headless, appIsAvailable: probe), .headless)
        XCTAssertEqual(probeCount, 0)
    }

    func testAutoSelectsExactlyOnceBeforeSessionComposition() {
        var probeCount = 0
        let selected = MCPBackendSelection.resolve(requested: .auto) {
            probeCount += 1
            return true
        }

        XCTAssertEqual(selected, .app)
        XCTAssertEqual(probeCount, 1)
    }

    func testAutoFallsBackToHeadlessWhenAppSocketIsUnavailable() {
        XCTAssertEqual(
            MCPBackendSelection.resolve(requested: .auto, appIsAvailable: { false }),
            .headless
        )
    }
}
