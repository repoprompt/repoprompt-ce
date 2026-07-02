import Darwin
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
        let fifo = try Self.makeLifecycleFIFO(prefix: "cli-process-runner-cancellation")
        var fifoGateFD: Int32? = fifo.gateFD
        defer {
            if let fifoGateFD {
                Darwin.close(fifoGateFD)
            }
            try? FileManager.default.removeItem(at: fifo.url)
        }

        let recorder = ProcessLifecycleRecorder()
        let runner = CLIProcessRunner(
            config: CLIProcessConfiguration(command: "/bin/sh", enableDebugLogging: false)
        )

        let stream = try await runner.runStreaming(
            args: [
                "-c",
                "exec 3<\"$1\"; printf 'ready\\n'; exec /bin/cat <&3 >/dev/null 2>/dev/null",
                "lifecycle-cat",
                fifo.url.path
            ],
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
        let readinessToken = Data("ready\n".utf8)
        let consumer = Task {
            do {
                for try await event in stream {
                    if case let .stdout(data) = event {
                        await recorder.recordStdout(data, readinessToken: readinessToken)
                    }
                }
            } catch {}
        }

        let processStarted = await recorder.waitForStart()
        XCTAssertTrue(processStarted)
        let childReady = await recorder.waitForReadiness()
        XCTAssertTrue(childReady)
        consumer.cancel()
        if let gateFD = fifoGateFD {
            Darwin.close(gateFD)
            fifoGateFD = nil
        }
        await runner.cancelAll()
        _ = await consumer.result

        let processTerminated = await recorder.waitForTermination()
        XCTAssertTrue(processTerminated)
        let snapshot = await recorder.snapshot()
        XCTAssertNotNil(snapshot.startedPID)
        XCTAssertEqual(snapshot.terminatedPID, snapshot.startedPID)
    }

    private static func makeLifecycleFIFO(prefix: String) throws -> (url: URL, gateFD: Int32) {
        let directory = FileManager.default.temporaryDirectory
        let fifoURL = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).fifo")
        let creationResult = fifoURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = ENOENT
                return -1
            }
            return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard creationResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let gateFD = fifoURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = ENOENT
                return -1
            }
            return Darwin.open(path, O_RDWR | O_CLOEXEC)
        }
        guard gateFD >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: fifoURL)
            throw error
        }
        return (fifoURL, gateFD)
    }
}

private actor ProcessLifecycleRecorder {
    private var startedPID: pid_t?
    private var terminatedPID: pid_t?
    private var stdoutBuffer = Data()
    private var readinessObserved = false

    func recordStarted(_ pid: pid_t) {
        startedPID = pid
    }

    func recordTerminated(_ pid: pid_t) {
        terminatedPID = pid
    }

    func recordStdout(_ data: Data, readinessToken: Data) {
        stdoutBuffer.append(data)
        if stdoutBuffer.range(of: readinessToken) != nil {
            readinessObserved = true
        }
    }

    func waitForStart() async -> Bool {
        for _ in 0 ..< 100 {
            if startedPID != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitForReadiness() async -> Bool {
        for _ in 0 ..< 100 {
            if readinessObserved { return true }
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
