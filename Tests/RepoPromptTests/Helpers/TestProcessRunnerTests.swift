import Foundation
import XCTest

final class TestProcessRunnerTests: XCTestCase {
    func testDrainsLargeOutputWhileChildIsRunning() throws {
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "131072", "/dev/zero"]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.count, 131_072)
    }

    func testTimeoutTerminatesProcessAndReportsContext() throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cwd)
        }

        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf started; exec /bin/sleep 5"],
                currentDirectoryURL: cwd,
                timeout: 0.25
            )
            XCTFail("Expected process timeout")
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.executableURL.path, "/bin/sh")
            XCTAssertEqual(error.arguments, ["-c", "printf started; exec /bin/sleep 5"])
            XCTAssertEqual(error.currentDirectoryURL, cwd)
            XCTAssertEqual(error.timeout, 0.25)
            XCTAssertEqual(error.outputText, "started")
            XCTAssertTrue(error.description.contains("cwd: \(cwd.path)"))
        }
    }

    func testTimeoutReturnsWhenChildProcessKeepsPipeOpen() throws {
        let startedAt = Date()

        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf parent-started; sleep 5 & wait"],
                timeout: 0.25
            )
            XCTFail("Expected process timeout")
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.outputText, "parent-started")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
    }

    func testTimeoutReturnsWhenExitedParentLeavesChildHoldingPipe() throws {
        let startedAt = Date()

        // Hold the pipe write end with a child that ignores common signals so platform
        // SIGHUP/termination of the orphan cannot make drain complete before the grace budget.
        // Accept either drain-timeout (parent exits 0) or process-timeout as long as wall time
        // stays bounded and the output prefix matches.
        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf parent-exited; (trap '' HUP INT TERM; exec /bin/sleep 30) & exit 0"
                ],
                timeout: 0.25
            )
            XCTFail("Expected a bounded timeout while orphaned child holds the pipe")
        } catch let error as TestProcessOutputDrainTimeoutError {
            XCTAssertEqual(error.outputText, "parent-exited")
            XCTAssertEqual(error.terminationStatus, 0)
            XCTAssertTrue(error.description.contains("output drain timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.outputText, "parent-exited")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
    }
}
