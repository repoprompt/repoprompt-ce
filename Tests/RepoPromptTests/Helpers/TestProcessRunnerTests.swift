import Foundation
import XCTest

final class TestProcessRunnerTests: XCTestCase {
    func testDrainsLargeOutputWhileChildIsRunning() throws {
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "65536", "/dev/zero"]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.count, 65536)
    }
}
