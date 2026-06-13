import Foundation
@testable import RepoPrompt
import XCTest

final class CLIProcessRunnerLifecycleTests: XCTestCase {
    func testStreamingProcessLifecycleCallbacksUseSamePIDAndTerminate() async throws {
        let recorder = ProcessLifecycleRecorder()
        let runner = CLIProcessRunner(
            config: CLIProcessConfiguration(command: "/bin/cat", enableDebugLogging: false)
        )

        let stream = try await runner.runStreaming(
            args: [],
            stdin: "callback-test",
            outputMode: .none,
            timeout: 2,
            onProcessStarted: { pid in
                await recorder.recordStarted(pid)
            },
            onProcessTerminated: { pid in
                await recorder.recordTerminated(pid)
            }
        )

        var sawTermination = false
        for try await event in stream {
            if case .terminated = event {
                sawTermination = true
            }
        }

        XCTAssertTrue(sawTermination)
        let callbacksCompleted = await recorder.waitForTermination()
        XCTAssertTrue(callbacksCompleted)
        let snapshot = await recorder.snapshot()
        XCTAssertNotNil(snapshot.startedPID)
        XCTAssertEqual(snapshot.terminatedPID, snapshot.startedPID)
    }

    func testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation() async throws {
        let recorder = ProcessLifecycleRecorder()
        let runner = CLIProcessRunner(
            config: CLIProcessConfiguration(command: "/bin/sleep", enableDebugLogging: false)
        )

        let stream = try await runner.runStreaming(
            args: ["5"],
            stdin: nil,
            outputMode: .none,
            timeout: 10,
            onProcessStarted: { pid in
                await recorder.recordStarted(pid)
            },
            onProcessTerminated: { pid in
                await recorder.recordTerminated(pid)
            }
        )
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        let processStarted = await recorder.waitForStart()
        XCTAssertTrue(processStarted)
        consumer.cancel()
        await runner.cancelAll()
        _ = await consumer.result

        let processTerminated = await recorder.waitForTermination()
        XCTAssertTrue(processTerminated)
        let snapshot = await recorder.snapshot()
        XCTAssertNotNil(snapshot.startedPID)
        XCTAssertEqual(snapshot.terminatedPID, snapshot.startedPID)
    }
}

private actor ProcessLifecycleRecorder {
    private var startedPID: pid_t?
    private var terminatedPID: pid_t?

    func recordStarted(_ pid: pid_t) {
        startedPID = pid
    }

    func recordTerminated(_ pid: pid_t) {
        terminatedPID = pid
    }

    func waitForStart() async -> Bool {
        for _ in 0 ..< 100 {
            if startedPID != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitForTermination() async -> Bool {
        for _ in 0 ..< 300 {
            if terminatedPID != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func snapshot() -> (startedPID: pid_t?, terminatedPID: pid_t?) {
        (startedPID, terminatedPID)
    }
}
