import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexAppServerClientProcessExitTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testStderrCaptureRetainsExactRawSuffixAtEveryBoundary() async {
        let invalidUTF8 = Data([0x66, 0x80, 0x67])
        let scenarios: [[Data]] = [
            [],
            [Data([0x01])],
            [Data(repeating: 0x02, count: 8191)],
            [Data(repeating: 0x03, count: 8192)],
            [Data(repeating: 0x04, count: 8193)],
            [Data(repeating: 0x05, count: 8190), invalidUTF8]
        ]

        for chunks in scenarios {
            let capture = CodexProcessStderrCapture(byteLimit: 8 * 1024)
            let complete = Task { await capture.waitUntilFinished(timeout: 1) }
            let allBytes = chunks.reduce(into: Data()) { $0.append($1) }
            for chunk in chunks {
                capture.append(chunk)
            }
            capture.finish()

            let didFinish = await complete.value
            XCTAssertTrue(didFinish)
            let snapshot = capture.snapshot()
            XCTAssertEqual(snapshot.bytes, Data(allBytes.suffix(8 * 1024)))
            XCTAssertEqual(snapshot.wasTruncated, allBytes.count > 8 * 1024)
        }
    }

    func testStartupEOFReturnsTypedExitWithSettledBoundedStderr() async throws {
        let directory = try makeTemporaryDirectory()
        let payload = Data(repeating: 0x41, count: 9000) + Data([0x80, 0x42])
        let stderrReleaseURL = directory.appendingPathComponent("release-stderr")
        let executable = try makeEarlyExitServer(
            in: directory,
            stderr: payload,
            termination: .exit(23),
            stderrReleaseURL: stderrReleaseURL
        )
        let expectedPIDEvents = ExpectedAgentPIDEventRecorder()
        let outcomePublicationGate = ChildExitOutcomePublicationGate()
        let registrar = CodexAppServerClient.ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await expectedPIDEvents.recordRegister(pid: pid, clientName: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await expectedPIDEvents.recordClear(pid: pid, clientName: clientName, runID: runID)
            }
        )
        let client = try await makeClient(
            executable: executable,
            launchDirectory: directory,
            timeout: 5,
            processExitObserverFactory: { pid in
                ChildProcessExitObserver(
                    pid: pid,
                    beforePublishingOutcome: { outcomePublicationGate.hold($0) }
                )
            },
            expectedAgentPIDRegistrar: registrar
        )
        addTeardownBlock {
            outcomePublicationGate.release()
            await client.stop()
        }
        await client.setExpectedAgentPIDRegistration(.init(clientName: "test-client", runID: UUID()))
        let startupCompletion = CompletionFlag()
        let startup = Task {
            do {
                try await client.startIfNeeded()
                await startupCompletion.markComplete()
            } catch {
                await startupCompletion.markComplete()
                throw error
            }
        }
        let deadline = CodexProcessExitTestDeadline(timeout: 5)
        guard await outcomePublicationGate.waitUntilHolding(timeout: deadline.remaining) else {
            let debugProcessID = await client.debugProcessID()
            let observerPresent = await client.debugProcessExitObserver() != nil
            let terminalProbe = debugProcessID.map {
                ProcessTermination.childIsTerminalOrAlreadyReaped($0)
            }
            let terminalObserverJoinCount = await client.debugTerminalObserverJoinCount()
            throw WaitUntilError.timedOut(
                "child exit outcome publication gate " +
                    "(debugProcessID: \(String(describing: debugProcessID)), " +
                    "observerPresent: \(observerPresent), " +
                    "terminalProbe: \(String(describing: terminalProbe)), " +
                    "terminalObserverJoinCount: \(terminalObserverJoinCount))"
            )
        }
        let heldObserverValue = await client.debugProcessExitObserver()
        let heldObserver = try XCTUnwrap(heldObserverValue)
        XCTAssertNil(heldObserver.signalRootProcessFamilyIfUnreaped(processGroupID: nil, signal: 0))
        try await waitUntil("terminal observer join after settlement timeout", timeout: deadline.remaining) {
            await client.debugTerminalObserverJoinCount() == 1
        }
        let startupCompletedWhileOutcomeWasHeld = await startupCompletion.isComplete
        XCTAssertFalse(startupCompletedWhileOutcomeWasHeld)
        outcomePublicationGate.release()

        try await waitUntil("typed exit-23 transport claim", timeout: deadline.remaining) {
            guard case .observedProcessExit(status: .exited(code: 23)) =
                await client.debugLastTransportTerminationReason()
            else {
                return false
            }
            return true
        }
        try await waitUntil("expected PID clear", timeout: deadline.remaining) {
            await expectedPIDEvents.clearCount == 1
        }
        let registrationCount = await expectedPIDEvents.registerCount
        let startupCompletedAfterPIDClear = await startupCompletion.isComplete
        XCTAssertEqual(registrationCount, 1)
        XCTAssertFalse(startupCompletedAfterPIDClear)

        let stopCompletion = CompletionFlag()
        let stop = Task {
            await client.stop()
            await stopCompletion.markComplete()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let stopReturnedBeforeSettlement = await stopCompletion.isComplete
        XCTAssertFalse(stopReturnedBeforeSettlement)
        await stop.value

        do {
            try await startup.value
            XCTFail("The early-exit fixture must fail startup")
        } catch let CodexAppServerClient.ClientError.processExited(evidence) {
            XCTAssertEqual(evidence.executablePath, executable.path)
            XCTAssertEqual(evidence.launchDirectory, directory.path)
            XCTAssertEqual(evidence.status, .exited(code: 23))
            XCTAssertEqual(evidence.stderrTail, Data(payload.suffix(8 * 1024)))
            XCTAssertTrue(evidence.stderrWasTruncated)
            XCTAssertTrue(evidence.stderrWasSettled)
            XCTAssertTrue(evidence.stderrTail.contains(0x80))
        } catch {
            XCTFail("Expected typed processExited evidence, got \(error)")
        }
        let activePID = await client.debugProcessID()
        let activeObserver = await client.debugProcessExitObserver()
        let clearCount = await expectedPIDEvents.clearCount
        XCTAssertNil(activePID)
        XCTAssertNil(activeObserver)
        XCTAssertEqual(clearCount, 1)
    }

    func testNilLaunchDirectoryUsesCLIProcessConfigurationDefaultInExitEvidence() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeWorkingDirectoryExitServer(in: directory)
        let client = try await makeClient(
            executable: executable,
            launchDirectory: nil,
            timeout: 5
        )
        addTeardownBlock {
            await client.stop()
        }

        do {
            try await client.startIfNeeded()
            XCTFail("The cwd-reporting fixture must fail startup")
        } catch let CodexAppServerClient.ClientError.processExited(evidence) {
            let expectedDirectory = CLIProcessConfiguration.resolvedWorkingDirectory(nil)
            let actualDirectory = String(decoding: evidence.stderrTail, as: UTF8.self)
            XCTAssertEqual(evidence.launchDirectory, expectedDirectory)
            XCTAssertEqual(
                GitRepoRootAuthorization.canonicalPath(actualDirectory),
                GitRepoRootAuthorization.canonicalPath(expectedDirectory)
            )
            XCTAssertEqual(evidence.status, .exited(code: 41))
            XCTAssertTrue(evidence.stderrWasSettled)
        } catch {
            XCTFail("Expected typed processExited evidence, got \(error)")
        }
    }

    func testStartupStdoutEOFWhileRootLivesKeepsGenericFailure() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeLiveAfterStdoutEOFServer(in: directory)
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)
        addTeardownBlock {
            await client.stop()
        }

        do {
            try await client.startIfNeeded()
            XCTFail("The stdout-closed fixture must fail startup")
        } catch CodexAppServerClient.ClientError.processNotRunning {
            // The root is still live at EOF, so no typed exit exists to preserve.
        } catch {
            XCTFail("Expected generic processNotRunning, got \(error)")
        }

        let terminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(terminationReason, .stdoutEOF)
        await client.stop()
    }

    func testStartupSignalExitKeepsSignalSemanticsAndOmitsEmptyStderr() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeEarlyExitServer(
            in: directory,
            stderr: Data(),
            termination: .signal(SIGKILL)
        )
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)

        do {
            try await client.startIfNeeded()
            XCTFail("The signaled fixture must fail startup")
        } catch let CodexAppServerClient.ClientError.processExited(evidence) {
            XCTAssertEqual(evidence.status, .uncaughtSignal(signal: SIGKILL))
            XCTAssertTrue(evidence.stderrTail.isEmpty)
            XCTAssertFalse(evidence.stderrWasTruncated)
            XCTAssertTrue(evidence.stderrWasSettled)
            XCTAssertFalse(CodexAppServerClient.ClientError.processExited(evidence).localizedDescription.contains("stderr"))
        } catch {
            XCTFail("Expected typed processExited evidence, got \(error)")
        }
    }

    func testListModelsRetriesTypedProcessExitOnceOnFreshProcess() async throws {
        let directory = try makeTemporaryDirectory()
        let attemptURL = directory.appendingPathComponent("attempt-count")
        let executable = try makeExitThenModelServer(in: directory, attemptURL: attemptURL)
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)

        let models = try await client.listModels()

        XCTAssertEqual(models.map(\.id), ["recovered-model"])
        XCTAssertEqual(try String(contentsOf: attemptURL, encoding: .utf8), "2")
        await client.stop()
    }

    func testExplicitStopWinsOverObservedTermination() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(
            in: directory,
            recordURL: recordURL,
            ignoredMethods: ["blocked"]
        )
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)
        try await client.startIfNeeded()

        let pending = Task {
            try await client.request(method: "blocked", params: nil)
        }
        try await waitForRecordedMethod("blocked", at: recordURL)
        await client.stop()

        do {
            _ = try await pending.value
            XCTFail("Explicit stop must fail the pending request")
        } catch let error as CodexAppServerClient.ClientError {
            guard case .processNotRunning = error else {
                return XCTFail("Explicit stop was relabeled as \(error)")
            }
        }
        let terminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(terminationReason, .explicitStop)
    }

    func testTransportWriteFailureWinsOverObservedTermination() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(in: directory, recordURL: recordURL)
        let client = CodexAppServerClient(writeFrameHandler: { _, _ in
            throw FDWriteError.brokenPipe(errno: EPIPE)
        })
        await client.updateConfig(.init(
            commandName: executable.path,
            additionalPathHints: [],
            requestTimeout: 5,
            processLaunchDirectory: directory.path
        ))

        do {
            try await client.startIfNeeded()
            XCTFail("The injected stdin failure must fail initialization")
        } catch let CodexAppServerClient.ClientError.transportWriteFailed(_, errnoValue) {
            XCTAssertEqual(errnoValue, EPIPE)
        } catch {
            XCTFail("stdin failure was relabeled as \(error)")
        }

        let terminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(terminationReason, .stdinWrite(method: "initialize", errno: EPIPE))
        await client.stop()
    }

    func testDecodeRecoveryExhaustionWinsOverObservedTermination() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(in: directory, recordURL: recordURL)
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)
        addTeardownBlock {
            await client.stop()
        }
        try await client.startIfNeeded()
        let generation = await client.debugTransportGeneration()
        let invalidLine = Data("not-json".utf8)

        for _ in 0 ... CodexAppServerClient.debugMaxDecodeRecoveryAttemptsPerGeneration() {
            await client.debugIngestRawStdoutLine(invalidLine)
        }
        try await waitUntil("decode recovery teardown", timeout: 2) {
            await !(client.debugIsProcessRunning())
        }

        let terminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(terminationReason, .decodeRecoveryBudgetExceeded(generation: generation))
        await client.stop()
    }

    func testTimeoutPoisoningWinsOverObservedTermination() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(
            in: directory,
            recordURL: recordURL,
            ignoredMethods: ["thread/start"]
        )
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)
        try await client.startIfNeeded()

        do {
            _ = try await client.request(method: "thread/start", params: [:], timeout: 0.05)
            XCTFail("The ignored request must time out")
        } catch let CodexAppServerClient.ClientError.requestFailed(failure) {
            XCTAssertTrue(failure.message.contains("timed out"))
        } catch {
            XCTFail("Timeout poisoning was relabeled as \(error)")
        }

        let terminationReason = await client.debugLastTransportTerminationReason()
        guard case .timeout(method: "thread/start", requestID: _) = terminationReason else {
            return XCTFail("Timeout did not retain lifecycle precedence")
        }
        await client.stop()
    }

    func testStaleObservedExitCannotMutateReplacementGeneration() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(in: directory, recordURL: recordURL)
        let client = try await makeClient(executable: executable, launchDirectory: directory, timeout: 5)
        try await client.startIfNeeded()
        let staleGeneration = await client.debugTransportGeneration()
        let staleObserverValue = await client.debugProcessExitObserver()
        let staleObserver = try XCTUnwrap(staleObserverValue)

        await client.stop()
        try await client.startIfNeeded()
        let replacementGeneration = await client.debugTransportGeneration()
        let replacementPID = await client.debugProcessID()
        let replacementObserverValue = await client.debugProcessExitObserver()
        let replacementObserver = try XCTUnwrap(replacementObserverValue)

        await client.debugDeliverObservedProcessExit(
            .exited(.exited(code: 99)),
            observer: staleObserver,
            generation: staleGeneration
        )

        let currentGeneration = await client.debugTransportGeneration()
        let currentPID = await client.debugProcessID()
        let currentObserver = await client.debugProcessExitObserver()
        let isRunning = await client.debugIsProcessRunning()
        let terminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(currentGeneration, replacementGeneration)
        XCTAssertEqual(currentPID, replacementPID)
        XCTAssertTrue(currentObserver === replacementObserver)
        XCTAssertTrue(isRunning)
        XCTAssertNil(terminationReason)
        await client.stop()
    }

    func testStopDuringRestartPreparationPreventsSpawnAfterReturn() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let spawnCountURL = directory.appendingPathComponent("spawn-count")
        let executable = try makePersistentServer(
            in: directory,
            recordURL: recordURL,
            spawnCountURL: spawnCountURL
        )
        let spawnPreparation = ProcessSpawnPreparationGate(blockedInvocation: 2)
        let client = try await makeClient(
            executable: executable,
            launchDirectory: directory,
            timeout: 5,
            processSpawnPreparation: { await spawnPreparation.prepare() }
        )
        let restartTaskCleanup = ThrowingTaskCleanup()
        addTeardownBlock {
            await spawnPreparation.release()
            await client.stop()
            await restartTaskCleanup.finish()
        }
        try await client.startIfNeeded()
        try await waitUntil("initial spawn count", timeout: 2) {
            (try? String(contentsOf: spawnCountURL, encoding: .utf8)) == "1"
        }
        await client.stop()

        let restart = Task {
            try await client.startIfNeeded()
        }
        await restartTaskCleanup.track(restart)
        try await waitUntil("restart preparation gate", timeout: 2) {
            await spawnPreparation.isBlocked
        }
        await client.stop()
        await spawnPreparation.release()

        do {
            try await restart.value
            XCTFail("The stopped restart must not reach process spawn")
        } catch is CancellationError {
            // Expected: stop revokes startup authority before returning.
        } catch {
            XCTFail("Expected restart cancellation, got \(error)")
        }
        XCTAssertEqual(try String(contentsOf: spawnCountURL, encoding: .utf8), "1")
        let isRunning = await client.debugIsProcessRunning()
        let processObserver = await client.debugProcessExitObserver()
        XCTAssertFalse(isRunning)
        XCTAssertNil(processObserver)
        await client.stop()
    }

    func testDeinitLeavesReapOwnershipWithObserver() async throws {
        let directory = try makeTemporaryDirectory()
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executable = try makePersistentServer(in: directory, recordURL: recordURL)
        var client: CodexAppServerClient? = try await makeClient(
            executable: executable,
            launchDirectory: directory,
            timeout: 5
        )
        try await client?.startIfNeeded()
        let pidValue = await client?.debugProcessID()
        let observerValue = await client?.debugProcessExitObserver()
        let pid = try XCTUnwrap(pidValue)
        let observer = try XCTUnwrap(observerValue)
        client = nil

        guard let outcome = await observer.wait(timeout: 3) else {
            return XCTFail("The cancellation-independent observer did not reap after client deinit")
        }
        guard case .exited = outcome else {
            return XCTFail("The sole observer failed to reap after client deinit: \(outcome)")
        }

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    private enum EarlyTermination {
        case exit(Int32)
        case signal(Int32)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerClientProcessExitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeClient(
        executable: URL,
        launchDirectory: URL?,
        timeout: TimeInterval,
        processSpawnPreparation: @escaping @Sendable () async throws -> Void = {},
        processExitObserverFactory: @escaping @Sendable (pid_t) -> ChildProcessExitObserver = {
            ChildProcessExitObserver(pid: $0)
        },
        expectedAgentPIDRegistrar: CodexAppServerClient.ExpectedAgentPIDRegistrar = .serverNetworkManager
    ) async throws -> CodexAppServerClient {
        let client = CodexAppServerClient(
            processSpawnPreparation: processSpawnPreparation,
            processExitObserverFactory: processExitObserverFactory,
            expectedAgentPIDRegistrar: expectedAgentPIDRegistrar
        )
        await client.updateConfig(.init(
            commandName: executable.path,
            additionalPathHints: [],
            requestTimeout: timeout,
            processLaunchDirectory: launchDirectory?.path
        ))
        return client
    }

    private func makeEarlyExitServer(
        in directory: URL,
        stderr: Data,
        termination: EarlyTermination,
        stderrReleaseURL: URL? = nil
    ) throws -> URL {
        let executable = directory.appendingPathComponent("early-exit-codex")
        let terminationSource = switch termination {
        case let .exit(code):
            "os._exit(\(code))"
        case let .signal(signal):
            "os.kill(os.getpid(), \(signal))"
        }
        let releasePath = stderrReleaseURL?.path
        let script = """
        #!/usr/bin/env python3
        import base64
        import os
        import signal
        import sys
        import time

        sys.stdin.readline()
        os.write(2, base64.b64decode(\(String(reflecting: stderr.base64EncodedString()))))
        release_path = \(releasePath.map(String.init(reflecting:)) ?? "None")
        if release_path is not None:
            holder = os.fork()
            if holder == 0:
                os.close(0)
                os.close(1)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while not os.path.exists(release_path):
                    time.sleep(0.005)
                os.close(2)
                os._exit(0)
        os.close(1)
        \(terminationSource)
        """
        return try writeExecutable(script, to: executable)
    }

    private func makeExitThenModelServer(
        in directory: URL,
        attemptURL: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent("exit-then-model-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import sys

        attempt_path = \(String(reflecting: attemptURL.path))
        try:
            with open(attempt_path, "r", encoding="utf-8") as handle:
                attempt = int(handle.read())
        except FileNotFoundError:
            attempt = 0
        attempt += 1
        with open(attempt_path, "w", encoding="utf-8") as handle:
            handle.write(str(attempt))

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "model/list" and attempt == 1:
                os.close(1)
                os._exit(17)
            if "id" not in request:
                continue
            result = {}
            if method == "model/list":
                result = {
                    "data": [{"id": "recovered-model"}],
                    "nextCursor": None,
                }
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """
        return try writeExecutable(script, to: executable)
    }

    private func makeLiveAfterStdoutEOFServer(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("live-after-stdout-eof-codex")
        let script = """
        #!/usr/bin/env python3
        import os
        import sys
        import time

        sys.stdin.readline()
        os.close(1)
        while True:
            time.sleep(1)
        """
        return try writeExecutable(script, to: executable)
    }

    private func makeWorkingDirectoryExitServer(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("working-directory-exit-codex")
        let script = """
        #!/usr/bin/env python3
        import os
        import sys

        sys.stdin.readline()
        os.write(2, os.getcwd().encode("utf-8"))
        os.close(1)
        os._exit(41)
        """
        return try writeExecutable(script, to: executable)
    }

    private func makePersistentServer(
        in directory: URL,
        recordURL: URL,
        spawnCountURL: URL? = nil,
        ignoredMethods: Set<String> = []
    ) throws -> URL {
        let executable = directory.appendingPathComponent("persistent-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = \(String(reflecting: recordURL.path))
        spawn_count_path = \(spawnCountURL.map(\.path).map(String.init(reflecting:)) ?? "None")
        ignored = set(\(String(reflecting: Array(ignoredMethods).sorted())))

        if spawn_count_path is not None:
            try:
                with open(spawn_count_path, "r", encoding="utf-8") as handle:
                    spawn_count = int(handle.read())
            except FileNotFoundError:
                spawn_count = 0
            with open(spawn_count_path, "w", encoding="utf-8") as handle:
                handle.write(str(spawn_count + 1))
                handle.flush()
                os.fsync(handle.fileno())

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method}) + "\\n")
                handle.flush()
            if "id" in request and method not in ignored:
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}), flush=True)
        """
        return try writeExecutable(script, to: executable)
    }

    private func writeExecutable(_ script: String, to url: URL) throws -> URL {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitForRecordedMethod(
        _ method: String,
        at recordURL: URL,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: recordURL),
               let text = String(data: data, encoding: .utf8),
               text.split(whereSeparator: \.isNewline).contains(where: { line in
                   guard let data = String(line).data(using: .utf8),
                         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                   else {
                       return false
                   }
                   return object["method"] as? String == method
               })
            {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(method)")
    }

    private enum WaitUntilError: LocalizedError {
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case let .timedOut(label): "Timed out waiting for \(label)"
            }
        }
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WaitUntilError.timedOut(label)
    }
}

private struct CodexProcessExitTestDeadline {
    private let expiration: TimeInterval

    init(timeout: TimeInterval) {
        expiration = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
    }

    var remaining: TimeInterval {
        max(0, expiration - ProcessInfo.processInfo.systemUptime)
    }
}

private final class ChildExitOutcomePublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let holdingSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var released = false

    func hold(_: ChildProcessExitObserver.Outcome) {
        lock.lock()
        let shouldWait = !released
        lock.unlock()
        holdingSemaphore.signal()
        if shouldWait {
            releaseSemaphore.wait()
        }
    }

    func waitUntilHolding(timeout: TimeInterval) async -> Bool {
        let timeout = DispatchTime.now() + max(timeout, 0)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [holdingSemaphore] in
                continuation.resume(returning: holdingSemaphore.wait(timeout: timeout) == .success)
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private actor ThrowingTaskCleanup {
    private var task: Task<Void, Error>?

    func track(_ task: Task<Void, Error>) {
        self.task = task
    }

    func finish() async {
        guard let task else { return }
        _ = try? await task.value
        self.task = nil
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor ProcessSpawnPreparationGate {
    private let blockedInvocation: Int
    private var invocationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false

    init(blockedInvocation: Int) {
        self.blockedInvocation = blockedInvocation
    }

    func prepare() async {
        invocationCount += 1
        guard invocationCount == blockedInvocation else { return }
        isBlocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isBlocked = false
    }
}

private actor ExpectedAgentPIDEventRecorder {
    private(set) var registerCount = 0
    private(set) var clearCount = 0

    func recordRegister(pid _: pid_t, clientName _: String, runID _: UUID) {
        registerCount += 1
    }

    func recordClear(pid _: pid_t, clientName _: String, runID _: UUID) {
        clearCount += 1
    }
}
