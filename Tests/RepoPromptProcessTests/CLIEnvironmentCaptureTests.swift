import Darwin
import Foundation
@testable import RepoPromptProcess
import XCTest

final class CLIEnvironmentCaptureTests: XCTestCase {
    func testCaptureDrainsOutputAfterChildExitBeforeParsing() async {
        let readers = DispatchSemaphore(value: 0)
        let exited = expectation(description: "shell exited with readers parked")
        // Keep the output smaller than a pipe so the shell can exit before either
        // reader runs. The exit boundary releases them; parsing must then join them.
        defer {
            readers.signal()
            readers.signal()
        }
        let captured = await Task.detached {
            CLIEnvironmentCache.test_captureEnvironment(
                arguments: ["-c", "printf 'FIRST=one\\nVALUE=two=three\\nLAST=complete'; printf 'diagnostic\\n' >&2"],
                beforeStdoutRead: { readers.wait() },
                beforeStderrRead: { readers.wait() },
                beforeDrain: {
                    exited.fulfill()
                    readers.signal()
                    readers.signal()
                }
            )
        }.value

        await fulfillment(of: [exited], timeout: 2)
        XCTAssertEqual(captured, ["FIRST": "one", "VALUE": "two=three", "LAST": "complete"])
    }

    func testCaptureDeadlineRejectsOutputUntilStderrDrainFinishes() async {
        let reader = DispatchSemaphore(value: 0)
        let stderrEntered = expectation(description: "stderr reader parked")
        let stderrReleased = expectation(description: "stderr reader released")
        let exited = expectation(description: "shell exited")
        let finished = expectation(description: "capture returned at its deadline")
        defer { reader.signal() }
        let capture = Task.detached {
            defer { finished.fulfill() }
            return CLIEnvironmentCache.test_captureEnvironment(
                arguments: ["-c", "printf 'COMPLETE=yes\\n'; printf 'diagnostic\\n' >&2"],
                beforeStderrRead: {
                    stderrEntered.fulfill()
                    reader.wait()
                    stderrReleased.fulfill()
                },
                beforeDrain: { exited.fulfill() }
            )
        }

        await fulfillment(of: [stderrEntered, exited, finished], timeout: 10)
        // Release even on a failing implementation before awaiting its task, so a
        // missing drain deadline cannot strand the test or its owned pipe.
        reader.signal()
        let captured = await capture.value
        XCTAssertNil(captured, "A successful root exit cannot publish a still-incomplete pipe capture")
        await fulfillment(of: [stderrReleased], timeout: 2)
    }

    func testLaunchFailureDoesNotWaitForParkedReaders() async {
        let readers = DispatchSemaphore(value: 0)
        let readerReleased = expectation(description: "failed-launch readers released")
        readerReleased.expectedFulfillmentCount = 2
        let finished = expectation(description: "failed launch returned")
        let pipesClosed = expectation(description: "failed-launch pipes closed")
        pipesClosed.expectedFulfillmentCount = 2
        defer {
            readers.signal()
            readers.signal()
        }
        let beforeRead: @Sendable () -> Void = {
            readers.wait()
            readerReleased.fulfill()
        }
        let capture = Task.detached {
            defer { finished.fulfill() }
            return CLIEnvironmentCache.test_captureEnvironment(
                shell: "/nonexistent-repoprompt-shell-\(UUID().uuidString)",
                arguments: [],
                beforeStdoutRead: beforeRead,
                beforeStderrRead: beforeRead,
                onPipeClosed: { pipesClosed.fulfill() }
            )
        }

        await fulfillment(of: [finished], timeout: 2)
        readers.signal()
        readers.signal()
        let captured = await capture.value
        XCTAssertNil(captured)
        await fulfillment(of: [readerReleased, pipesClosed], timeout: 2)
    }

    func testPipeDrainStopsWithoutEOFWhenAnotherWriterRemainsOpen() async throws {
        let pipe = Pipe()
        let duplicate = dup(pipe.fileHandleForWriting.fileDescriptor)
        guard duplicate >= 0 else {
            XCTFail("Could not duplicate the fixture pipe writer")
            return
        }
        // This duplicate has the same EOF semantics as a descriptor inherited by
        // a shell descendant, without creating a process the test cannot reap.
        let inheritedWriter = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? inheritedWriter.close() }
        try pipe.fileHandleForWriting.close()
        try inheritedWriter.write(contentsOf: Data("COMPLETE=yes\n".utf8))
        let readSubmitted = expectation(description: "active pipe read submitted")
        let pipeClosed = expectation(description: "active pipe closed while writer remained open")
        let capture = ShellOutputCapture(
            fileHandle: pipe.fileHandleForReading,
            onReadSubmitted: { readSubmitted.fulfill() },
            onClosed: { pipeClosed.fulfill() }
        )
        defer { capture.stop() }

        await fulfillment(of: [readSubmitted], timeout: 2)
        XCTAssertNil(capture.drainedData(deadline: .now()), "No EOF is possible while the inherited writer remains open")
        capture.stop()
        await fulfillment(of: [pipeClosed], timeout: 2)
    }

    func testCancellationAfterChildExitDoesNotPublishCapturedOutput() async {
        let drain = DispatchSemaphore(value: 0)
        let exited = expectation(description: "shell exited before draining")
        defer { drain.signal() }
        let capture = Task.detached {
            CLIEnvironmentCache.test_captureEnvironment(
                arguments: ["-c", "printf 'COMPLETE=yes\\n'"],
                beforeDrain: {
                    exited.fulfill()
                    drain.wait()
                }
            )
        }

        await fulfillment(of: [exited], timeout: 2)
        capture.cancel()
        drain.signal()
        let captured = await capture.value
        XCTAssertNil(captured)
    }
}
