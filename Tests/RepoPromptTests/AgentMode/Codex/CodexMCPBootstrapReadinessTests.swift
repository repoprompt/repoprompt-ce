import Foundation
@testable import RepoPromptApp
import XCTest

/// Fail-closed RepoPrompt MCP provisioning contract for the Codex native session controller
/// (issue #514). A Codex child that expects RepoPrompt MCP tools must not launch its app-server
/// process or send a thread request when provisioning cannot be validated, and a cancellation that
/// races provisioning must not cross the launch boundary. A child that provisions successfully must
/// proceed unchanged.
final class CodexMCPBootstrapReadinessTests: XCTestCase {
    private let expectedClientName = "RepoPromptCE"

    // MARK: - Throwing provisioner fails closed (fresh start and resume)

    func testThrowingProvisionerAbortsBeforeProcessStartAndThreadRequest() async throws {
        // Both a fresh start (existing == nil → thread/start) and a resume (existing set →
        // thread/resume) must abort at the provisioning gate before any request is sent.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMCPBootstrapReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executableURL = try makeFakeCodexAppServer(in: directory)
        let resumeRef = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
        for existing in [nil, resumeRef] {
            let registrar = RecordingExpectedAgentPIDRegistrar()
            let client = CodexAppServerClient(
                provisionsRepoPromptMCPOnStart: false,
                expectedAgentPIDRegistrar: registrar.registrar
            )
            await client.updateConfig(.init(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                processLaunchDirectory: directory.path
            ))
            let requests = RecordedRequests()
            let provisionerCalls = CallCounter()

            var options = makeAgentModeOptions()
            options.repoPromptMCPProvisioner = { _ in
                provisionerCalls.increment()
                throw MCPBootstrapReadinessError.provisioningUnavailable
            }

            let controller = CodexNativeSessionController(
                client: client,
                runID: UUID(),
                tabID: UUID(),
                windowID: 0,
                workspacePaths: .uniform("/tmp/codex-mcp-readiness-throwing"),
                options: options,
                clientShutdownBehavior: .stopOnShutdown,
                expectedMCPClientName: expectedClientName,
                requestExecutor: requests.executor
            )
            addTeardownBlock { await controller.shutdown() }

            let label = existing == nil ? "fresh start" : "resume"
            do {
                _ = try await controller.startOrResume(existing: existing, baseInstructions: "Agent")
                XCTFail("[\(label)] startOrResume must throw when provisioning is unavailable")
            } catch let error as MCPBootstrapReadinessError {
                XCTAssertEqual(error, .provisioningUnavailable, "[\(label)] expected the typed provisioning failure")
            }

            XCTAssertEqual(provisionerCalls.value, 1, "[\(label)] provisioner runs exactly once")
            XCTAssertEqual(requests.methods, [], "[\(label)] no thread/start or thread/resume may be sent")
            let processRunning = await client.debugIsProcessRunning()
            XCTAssertFalse(processRunning, "[\(label)] no app-server process may start")
            XCTAssertEqual(registrar.registeredCount, 0, "[\(label)] no expected-agent PID may be registered")
            XCTAssertEqual(registrar.clearedCount, 0, "[\(label)] nothing registered, so no spurious PID clear")
        }
    }

    // MARK: - Cancellation cannot cross the launch boundary

    func testCancellationDuringProvisioningDoesNotCrossLaunchBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMCPBootstrapReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executableURL = try makeFakeCodexAppServer(in: directory)
        let registrar = RecordingExpectedAgentPIDRegistrar()
        let client = CodexAppServerClient(
            provisionsRepoPromptMCPOnStart: false,
            expectedAgentPIDRegistrar: registrar.registrar
        )
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 5,
            processLaunchDirectory: directory.path
        ))
        let requests = RecordedRequests()
        let gate = ProvisionerSuspensionGate()

        var options = makeAgentModeOptions()
        // Suspend inside the provisioner so the test can cancel the start while it is parked at the
        // gate — reproducing a cancellation that races provisioning without any sleeps.
        options.repoPromptMCPProvisioner = { _ in await gate.arriveAndWait() }

        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform("/tmp/codex-mcp-readiness-cancellation"),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: expectedClientName,
            requestExecutor: requests.executor
        )
        addTeardownBlock { await controller.shutdown() }
        // Safety net: guarantee the parked provisioner is released even if an assertion throws first.
        defer { gate.release() }

        let start = Task { try await controller.startOrResume(existing: nil, baseInstructions: "Agent") }
        await gate.waitUntilArrived()

        start.cancel()
        gate.release()

        do {
            _ = try await start.value
            XCTFail("startOrResume must throw when cancelled during provisioning")
        } catch is CancellationError {
            // Expected: the cancellation checkpoint after provisioning aborts the start.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let processRunning = await client.debugIsProcessRunning()
        XCTAssertFalse(processRunning, "a cancelled start must not launch the app-server process")
        XCTAssertEqual(requests.methods, [], "a cancelled start must send no thread request")
        XCTAssertEqual(registrar.registeredCount, 0, "a cancelled start must register no expected-agent PID")
    }

    // MARK: - Successful provisioner proceeds, in order

    func testSuccessfulProvisionerProceedsToProcessStartAndThreadRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMCPBootstrapReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let environmentURL = directory.appendingPathComponent("child-environment.json")
        let versionProbeURL = directory.appendingPathComponent("version-probes")
        let executableURL = try makeFakeCodexAppServer(
            in: directory,
            environmentURL: environmentURL,
            versionProbeURL: versionProbeURL
        )

        let registrar = RecordingExpectedAgentPIDRegistrar()
        let shellHome = directory.appendingPathComponent("shell-home", isDirectory: true).path
        let client = CodexAppServerClient(
            processEnvironmentBuilder: { request in
                await ProcessEnvironmentBuilder.build(
                    request,
                    shellEnvironmentProvider: { _, _ in
                        CLIEnvironmentSnapshot(
                            environment: [
                                "HOME": shellHome,
                                CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: executableURL.path
                            ],
                            source: .capturedLoginShell
                        )
                    }
                )
            },
            provisionsRepoPromptMCPOnStart: false,
            expectedAgentPIDRegistrar: registrar.registrar
        )
        await client.updateConfig(
            CodexAppServerClient.Config(
                additionalPathHints: [],
                requestTimeout: 5,
                processLaunchDirectory: directory.path
            )
        )

        let requests = RecordedRequests(threadStartResult: [
            "thread": ["id": "fresh-thread", "status": "idle", "turns": []]
        ])
        let gate = ProvisionerSuspensionGate()
        let provisionedRuntime = ProvisionedRuntimeRecorder()
        var options = makeAgentModeOptions()
        // Park the provisioner so the ordering can be observed: nothing downstream may happen while
        // it is suspended.
        options.repoPromptMCPProvisioner = { runtime in
            provisionedRuntime.record(runtime)
            await gate.arriveAndWait()
        }

        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: expectedClientName,
            requestExecutor: requests.executor
        )
        addTeardownBlock { await controller.shutdown() }
        defer { gate.release() }

        let start = Task { try await controller.startOrResume(existing: nil, baseInstructions: "Agent") }
        await gate.waitUntilArrived()

        // While the provisioner is parked, nothing downstream of the gate may have run.
        let processRunningWhileParked = await client.debugIsProcessRunning()
        XCTAssertFalse(processRunningWhileParked, "the process must not start before provisioning succeeds")
        XCTAssertEqual(requests.methods, [], "no request may be sent before provisioning succeeds")

        gate.release()
        let sessionRef = try await start.value

        XCTAssertEqual(sessionRef.conversationID, "fresh-thread", "a successful provisioner lets thread/start bind a session")
        let processRunning = await client.debugIsProcessRunning()
        XCTAssertTrue(processRunning, "a successful provisioner lets the app-server process start")
        XCTAssertEqual(registrar.registeredClientNames, [expectedClientName], "the launched process registers its expected-agent PID")
        XCTAssertEqual(requests.methods, ["thread/start"], "the only controller request after a successful start is thread/start")

        let runtime = try XCTUnwrap(provisionedRuntime.runtime)
        XCTAssertEqual(runtime.source, .externalOverride)
        XCTAssertEqual(runtime.executableURL, executableURL)
        XCTAssertEqual(try String(contentsOf: versionProbeURL, encoding: .utf8), "probe\n")

        let environmentData = try Data(contentsOf: environmentURL)
        let childEnvironment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: environmentData) as? [String: String]
        )
        XCTAssertEqual(childEnvironment["CODEX_HOME"], runtime.statePaths.codexHome.path)
        XCTAssertEqual(childEnvironment["CODEX_SQLITE_HOME"], runtime.statePaths.sqliteHome.path)
    }

    // MARK: - Helpers

    private func makeAgentModeOptions() -> CodexNativeSessionController.Options {
        .agentModeDefault(
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user }
        )
    }

    /// Minimal stdin/stdout JSON-RPC stand-in for the Codex app-server: it replies to every request
    /// with an empty result so the startup handshake (initialize, memory-mode disable) completes
    /// without the real `codex` binary. Thread requests are intercepted by the injected request
    /// executor, so the process only has to complete startup; its launch is observed via
    /// `debugIsProcessRunning()`.
    private func makeFakeCodexAppServer(
        in directory: URL,
        environmentURL: URL? = nil,
        versionProbeURL: URL? = nil
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let environmentPath = environmentURL.map { String(reflecting: $0.path) } ?? "None"
        let versionProbePath = versionProbeURL.map { String(reflecting: $0.path) } ?? "None"
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import sys
        version_probe_path = \(versionProbePath)
        if sys.argv[1:] == ["--version"]:
            if version_probe_path is not None:
                with open(version_probe_path, "a", encoding="utf-8") as handle:
                    handle.write("probe\\n")
            print("codex 0.144.6")
            raise SystemExit(0)
        environment_path = \(environmentPath)
        if environment_path is not None:
            with open(environment_path, "w", encoding="utf-8") as handle:
                json.dump({
                    "CODEX_HOME": os.environ.get("CODEX_HOME", ""),
                    "CODEX_SQLITE_HOME": os.environ.get("CODEX_SQLITE_HOME", "")
                }, handle)
        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            if "id" not in request:
                continue
            respond(request["id"], {})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

// MARK: - Test doubles

private final class ProvisionedRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CodexRuntimeAuthority.Runtime?

    func record(_ runtime: CodexRuntimeAuthority.Runtime) {
        lock.lock()
        value = runtime
        lock.unlock()
    }

    var runtime: CodexRuntimeAuthority.Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Records the JSON-RPC methods the controller sends through its injected request executor, and
/// returns a canned `thread/start` result so a session can bind without a real app-server response.
private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let threadStartResult: [String: Any]

    init(threadStartResult: [String: Any] = [:]) {
        self.threadStartResult = threadStartResult
    }

    var executor: @Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any] {
        { [self] method, _, _ in
            lock.lock()
            recorded.append(method)
            lock.unlock()
            return method == "thread/start" ? threadStartResult : [:]
        }
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Captures `ExpectedAgentPIDRegistrar` traffic so a test can assert on registrations without
/// touching the shared `ServerNetworkManager`.
private final class RecordingExpectedAgentPIDRegistrar: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [String] = []
    private var cleared = 0

    var registrar: CodexAppServerClient.ExpectedAgentPIDRegistrar {
        .init(
            register: { [weak self] _, clientName, _ in
                guard let self else { return }
                lock.lock()
                registered.append(clientName)
                lock.unlock()
            },
            clear: { [weak self] _, _, _ in
                guard let self else { return }
                lock.lock()
                cleared += 1
                lock.unlock()
            }
        )
    }

    var registeredClientNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registered.count
    }

    var clearedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleared
    }
}

/// Lets a test suspend the injected provisioner, observe that nothing downstream has run, then
/// release it — a deterministic barrier with no sleeps.
private actor ProvisionerSuspensionGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the provisioner: records arrival, wakes anyone awaiting arrival, then
    /// suspends until `release()`.
    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    /// Suspends the caller until the provisioner has arrived.
    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    nonisolated func release() {
        Task { await self.performRelease() }
    }

    private func performRelease() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
