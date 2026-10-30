import Darwin
import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
@testable import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class CodexExecAgentProviderRuntimePreparationTests: XCTestCase {
    func testPrepareUsesRuntimeStateAuthorityAndMapsFailureBeforeMCPBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecAgentProviderRuntimePreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex 0.156.0'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = PreparedRuntimeRecorder()
        let provider = CodexExecAgentProvider(
            config: .init(commandName: executable.path, additionalPathHints: []),
            runtimeStatePreparer: { runtime in
                recorder.record(runtime)
                throw RuntimePreparationFailure.conflict
            }
        )

        do {
            _ = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                try await provider.prepare()
            }
            XCTFail("prepare must fail when isolated Codex state preparation fails")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("unable to prepare its isolated Codex state"))
            XCTAssertTrue(detail.contains("projection conflict"))
        } catch {
            XCTFail("Expected invalidConfiguration, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.runtime?.source, .externalOverride)
        XCTAssertEqual(recorder.runtime?.executableURL, executable)
    }
}

private enum RuntimePreparationFailure: Error, LocalizedError {
    case conflict

    var errorDescription: String? {
        "projection conflict"
    }
}

private final class PreparedRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRuntime: CodexRuntimeAuthority.Runtime?
    private var recordedCallCount = 0

    func record(_ runtime: CodexRuntimeAuthority.Runtime) {
        lock.lock()
        recordedRuntime = runtime
        recordedCallCount += 1
        lock.unlock()
    }

    var runtime: CodexRuntimeAuthority.Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRuntime
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }
}

// MARK: - Portable Codex Exec owner contracts (rehomed with the provider)

final class CodexExecAgentProviderTests: XCTestCase {
    func testServerEntryEqualityIncludesEveryExistingIdentityField() {
        let entry = CodexExecServerEntry(rawName: "Raw", normalizedName: "normalized", cliPathComponent: "path")
        XCTAssertEqual(entry, .init(rawName: "Raw", normalizedName: "normalized", cliPathComponent: "path"))
        for changed in [
            CodexExecServerEntry(rawName: "Other", normalizedName: "normalized", cliPathComponent: "path"),
            CodexExecServerEntry(rawName: "Raw", normalizedName: "other", cliPathComponent: "path"),
            CodexExecServerEntry(rawName: "Raw", normalizedName: "normalized", cliPathComponent: "other")
        ] {
            XCTAssertNotEqual(entry, changed)
        }
        func requireCheckedSendable<T: Sendable>(_ value: T) -> T {
            value
        }
        XCTAssertEqual(requireCheckedSendable(entry), entry)
    }

    func testParserPreservesFormatsUsageAndToolInvocationIdentity() throws {
        let host = ExecHost()
        let provider = makeProvider(host)
        let content = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}"#.utf8)))
        XCTAssertEqual(content.type, "content")
        XCTAssertEqual(content.text, "answer")
        let reasoning = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"msg":{"type":"agent_reasoning","text":"thinking"}}"#.utf8)))
        XCTAssertEqual(reasoning.reasoning, "thinking")
        let stop = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.25}"#.utf8)))
        XCTAssertEqual(stop.type, "message_stop")
        XCTAssertEqual(stop.promptTokens, 11)
        XCTAssertEqual(stop.completionTokens, 7)
        XCTAssertEqual(stop.cost, 0.25)
        let started = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"item.started","item":{"type":"command_execution","id":"command-1","command":"pwd"}}"#.utf8)))
        let completed = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"item.completed","item":{"type":"command_execution","id":"command-1","command":"pwd","exit_code":2}}"#.utf8)))
        XCTAssertEqual(started.type, "tool_result")
        XCTAssertEqual(started.toolName, "bash")
        XCTAssertNotNil(started.toolInvocationID)
        XCTAssertEqual(completed.toolInvocationID, started.toolInvocationID)
        XCTAssertEqual(completed.toolIsError, true)
        let restarted = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"item.started","item":{"type":"command_execution","id":"command-1","command":"pwd"}}"#.utf8)))
        XCTAssertNotEqual(restarted.toolInvocationID, started.toolInvocationID)
        XCTAssertNil(provider.parseJSONLEvent(Data("not JSON".utf8)))
    }

    func testProvenanceChecksRawToolAndServerWithoutSuppressingForeignTools() throws {
        let provider = makeProvider(ExecHost())
        for item in [
            #"{"type":"tool_call","name":"mcp__owned__read","id":"1"}"#,
            #"{"type":"tool_call","name":"read","server_name":"owned","id":"2"}"#,
            #"{"type":"tool_call","name":"read","callName":"mcp__owned__read","id":"3"}"#
        ] {
            XCTAssertNil(provider.parseJSONLEvent(Data("{\"type\":\"item.started\",\"item\":\(item)}".utf8)))
        }
        let foreign = try XCTUnwrap(provider.parseJSONLEvent(Data(#"{"type":"item.started","item":{"type":"tool_call","name":"mcp__foreign__read","server":"foreign","arguments":{"path":"file"},"id":"4"}}"#.utf8)))
        XCTAssertEqual(foreign.type, "tool_call")
        XCTAssertEqual(foreign.toolName, "read")
        XCTAssertTrue(try XCTUnwrap(foreign.toolArgsJSON).contains("file"))
    }

    func testStructuredStdoutErrorsTakePriorityOverPlainTail() {
        let provider = makeProvider(ExecHost())
        let data = Data("plain failure\n{\"type\":\"item.completed\",\"item\":{\"type\":\"error\",\"text\":\"structured failure\"}}\nlate plain failure\n".utf8)
        XCTAssertEqual(provider.extractCLIErrorDetail(fromStdout: data), "structured failure")
        XCTAssertEqual(provider.extractCLIErrorDetail(fromStdout: Data("first\nlast\n".utf8)), "last")
        XCTAssertNil(provider.extractCLIErrorDetail(fromStdout: Data("{}\n[]\n".utf8)))
    }

    func testNoiseFilterKeepsStructuredErrorsAndUserDiagnostics() {
        for noise in ["", "session_heartbeat active", "2026-04-09T10:51:37 INFO internal", "middleware.go:123", #"{"jsonrpc":"2.0","id":1}"#] {
            XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(noise), noise)
        }
        for visible in ["login required", #"{"error":"rejected"}"#, #"{"jsonrpc":"2.0","message":"visible failure"}"#] {
            XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(visible), visible)
        }
    }

    func testPreflightAndReadinessFailuresStopBeforeLaterEffects() async throws {
        let unavailable = ExecHost(available: false)
        do {
            _ = try await makeProvider(unavailable).prepare()
            XCTFail("Unavailable runtime must fail")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, "fixture unavailable")
        }
        XCTAssertEqual(unavailable.events, ["preflight"])

        let notRunning = ExecHost(running: false)
        do {
            _ = try await makeProvider(notRunning).prepare()
            XCTFail("MCP readiness must fail")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, "Could not start MCP server. Check MCP settings and try again.")
        }
        XCTAssertEqual(notRunning.events, ["preflight", "state", "filter", "readiness"])
    }

    func testPreparePreservesRuntimeEnvironmentAndEnsureFailure() async throws {
        let host = ExecHost()
        let runID = UUID()
        let context = try await makeProvider(host).prepare(runID: runID)
        XCTAssertEqual(context.runID, runID)
        XCTAssertNil(context.configURL)
        XCTAssertEqual(context.environment["CODEX_HOME"], host.runtime.statePaths.codexHome.path)
        XCTAssertEqual(context.environment["CODEX_SQLITE_HOME"], host.runtime.statePaths.sqliteHome.path)
        XCTAssertEqual(host.events, ["preflight", "state", "filter", "readiness", "ensure"])

        let failed = ExecHost(ensureSuccess: false)
        do {
            _ = try await makeProvider(failed).prepare()
            XCTFail("Config provisioning must fail")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, "fixture ensure failure")
        }
        XCTAssertEqual(failed.events, ["preflight", "state", "filter", "readiness", "ensure"])
    }

    func testActualProcessFlushesTrailingContentAndStderrBeforeStopAndTrackingCleanup() async throws {
        let executable = try script("printf '%s' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"trailing answer\"}}'\nprintf '%s' 'visible trailing diagnostic' >&2\n")
        let host = ExecHost(executable: executable)
        let results = try await run(makeProvider(host))
        XCTAssertEqual(results.filter { $0.type == "content" }.map(\.text), ["trailing answer"])
        XCTAssertEqual(results.filter { $0.type == "system" }.map(\.text), ["visible trailing diagnostic"])
        XCTAssertEqual(results.last?.type, "message_stop")
        XCTAssertEqual(results.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertEqual(host.events.suffix(3), ["pid-start", "pid-clear", "tracking-stop"])
        XCTAssertEqual(Array(host.events.prefix(10)), ["preflight", "state", "filter", "readiness", "ensure", "entries", "cache", "model:requested", "tool-policy", "server-policy:"])
    }

    func testEntryCapturePrecedesCacheSuspensionAndPolicyReadsFollowIt() async throws {
        let executable = try script("printf '%s\\n' '{\"type\":\"turn.completed\"}'\n")
        let gate = ExecCacheGate()
        let reached = expectation(description: "broken cache awaited")
        let host = ExecHost(executable: executable, cacheGate: gate, cacheReached: reached)
        let provider = makeProvider(host)
        addTeardownBlock { await gate.release()
            await provider.dispose()
        }
        let consumer = Task { try await run(provider, releasing: gate) }
        await fulfillment(of: [reached], timeout: 10)
        XCTAssertEqual(host.events.suffix(2), ["entries", "cache"])
        XCTAssertFalse(host.events.contains(where: { $0.hasPrefix("model:") || $0 == "tool-policy" }))
        await gate.release()
        let results = try await consumer.value
        XCTAssertEqual(results.last?.type, "message_stop")
        XCTAssertEqual(Array(host.events.dropFirst(5).prefix(5)), ["entries", "cache", "model:requested", "tool-policy", "server-policy:"])
    }

    func testActualProcessRetriesModelThenBrokenServerExactlyOnceEach() async throws {
        let directory = try temporaryDirectory()
        let count = directory.appendingPathComponent("attempts").path
        let executable = try script("""
        n=0
        if [ -f '\(count)' ]; then n=$(/bin/cat '\(count)'); fi
        n=$((n + 1))
        printf '%s' "$n" > '\(count)'
        case "$n" in
          1) printf '%s\\n' '{"error":"missing-model"}'; exit 1 ;;
          2) printf '%s\\n' 'broken-server' >&2; exit 1 ;;
          *) printf '%s\\n' '{"type":"turn.completed"}'; exit 0 ;;
        esac
        """)
        let host = ExecHost(executable: executable)
        let results = try await run(makeProvider(host))
        XCTAssertEqual(try String(contentsOfFile: count, encoding: .utf8), "3")
        XCTAssertEqual(results.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertEqual(results.count(where: { $0.text?.contains("Retrying with fallback") == true }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "preflight" }), 3)
        XCTAssertEqual(host.events.count(where: { $0 == "tracking-stop" }), 3)
        XCTAssertEqual(host.events.count(where: { $0 == "pid-clear" }), 3)
        XCTAssertEqual(host.events.filter { $0.hasPrefix("model:") }, ["model:requested", "model:fallback", "model:fallback"])
        XCTAssertEqual(host.events.filter { $0.hasPrefix("server-policy:") }, ["server-policy:", "server-policy:", "server-policy:broken"])
        XCTAssertEqual(host.events.count(where: { $0 == "cache-add:broken" }), 1)
    }

    func testStdoutPrimaryErrorPreventsStderrBrokenServerRetry() async throws {
        let executable = try script("printf '%s\\n' '{\"error\":\"primary refusal\"}'\nprintf '%s\\n' 'broken-server' >&2\nexit 3\n")
        let host = ExecHost(executable: executable)
        do {
            _ = try await run(makeProvider(host))
            XCTFail("Structured stdout refusal must fail")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, "primary refusal")
        }
        XCTAssertEqual(host.events.count(where: { $0 == "preflight" }), 1)
        XCTAssertFalse(host.events.contains("cache-add:broken"))
        XCTAssertEqual(host.events.last, "tracking-stop")
    }

    func testCompletionCancelsBlockedPhysicalProcessAndStopsTracking() async throws {
        let directory = try temporaryDirectory()
        let fifo = directory.appendingPathComponent("block")
        try makeFIFO(fifo)
        // The existing runner's blocking read requests 64 KiB. Supply that chunk so the
        // terminal event is delivered before this child blocks, rather than waiting for EOF.
        let executable = try script("exec 3<> '\(fifo.path)'\nprintf '%s\\n' '{\"type\":\"turn.completed\"}'\nprintf '%65536s' ''\nread -r value <&3\n")
        let cleared = expectation(description: "physical PID cleared")
        let host = ExecHost(executable: executable, cleared: cleared)
        let provider = makeProvider(host)
        addTeardownBlock { self.releaseFixtureFIFO(fifo)
            await provider.dispose()
        }
        let results = try await run(provider, releasingFIFO: fifo)
        await fulfillment(of: [cleared], timeout: 10)
        XCTAssertEqual(results.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "pid-start" }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "pid-clear" }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "tracking-stop" }), 1)
        // cancelAll requests termination; the existing physical finalizer owns PID clearing.
        XCTAssertLessThan(try XCTUnwrap(host.events.firstIndex(of: "pid-start")), try XCTUnwrap(host.events.firstIndex(of: "pid-clear")))
    }

    func testDisposeCancelsBlockedPhysicalProcessWithoutASecondLifecycle() async throws {
        let directory = try temporaryDirectory()
        let fifo = directory.appendingPathComponent("block")
        try makeFIFO(fifo)
        let executable = try script("exec 3<> '\(fifo.path)'\nread -r value <&3\n")
        let started = expectation(description: "actual PID registered")
        let stopped = expectation(description: "tracking drained")
        let cleared = expectation(description: "physical PID cleared")
        let host = ExecHost(executable: executable, started: started, stopped: stopped, cleared: cleared)
        let provider = makeProvider(host)
        addTeardownBlock { self.releaseFixtureFIFO(fifo)
            await provider.dispose()
        }
        let consumer = Task { try await run(provider, releasingFIFO: fifo) }
        await fulfillment(of: [started], timeout: 10)
        await provider.dispose()
        let outcome = await consumer.result
        await fulfillment(of: [stopped, cleared], timeout: 10)
        switch outcome {
        case let .success(results):
            XCTAssertTrue(results.isEmpty)
        case let .failure(error):
            switch error {
            case let AIProviderError.invalidConfiguration(detail):
                XCTAssertEqual(detail, "Codex Exec run cancelled.")
            case let AIProviderError.apiError(source):
                // The unchanged cancelled iterator may end before a termination event is delivered.
                let error = try XCTUnwrap(source) as NSError
                XCTAssertEqual(error.domain, "CodexCLI")
                XCTAssertEqual(error.code, -999)
                XCTAssertEqual(error.localizedDescription, "codex exec did not report a termination status.")
            default:
                XCTFail("Unexpected cancellation result: \(error)")
            }
        }
        XCTAssertEqual(host.events.count(where: { $0 == "pid-start" }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "pid-clear" }), 1)
        XCTAssertEqual(host.events.count(where: { $0 == "tracking-stop" }), 1)
    }

    private func makeProvider(_ host: ExecHost) -> CodexExecAgentProvider {
        CodexExecAgentProvider(config: .init(commandName: host.runtime.executableURL.path, additionalPathHints: [], modelString: "requested", enableDebugLogging: false, fullAccess: false), host: host)
    }

    private func run(_ provider: CodexExecAgentProvider, releasing gate: ExecCacheGate? = nil, releasingFIFO fifo: URL? = nil) async throws -> [AIStreamResult] {
        // Match existing subprocess-test watchdogs: success is event-driven; expiry is a failure.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return false }
            XCTFail("Codex Exec fixture exceeded its bounded deadline")
            await gate?.release()
            if let fifo { self.releaseFixtureFIFO(fifo) }
            await provider.dispose()
            return true
        }
        do {
            let results = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                let stream = try await provider.streamAgentMessage(AgentMessage(systemPrompt: "system", userMessage: "user"), runID: UUID())
                var results: [AIStreamResult] = []
                for try await result in stream {
                    results.append(result)
                }
                return results
            }
            watchdog.cancel()
            if await watchdog.value { throw ExecFixtureFailure.deadline }
            return results
        } catch {
            watchdog.cancel()
            if await watchdog.value { throw ExecFixtureFailure.deadline }
            throw error
        }
    }

    private func releaseFixtureFIFO(_ fifo: URL) {
        // Failure/teardown cleanup must not block opening a FIFO whose child has already exited.
        let descriptor = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            XCTFail("Could not open owned fixture FIFO for cleanup")
            return
        }
        defer { Darwin.close(descriptor) }
        var newline: UInt8 = 10
        XCTAssertEqual(Darwin.write(descriptor, &newline, 1), 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexExecOwner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func script(_ body: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeFIFO(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class ExecHost: CodexExecAgentHost, CodexExecToolTracking {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var broken: Set<String> = []
    private let available: Bool
    private let running: Bool
    private let ensureSuccess: Bool
    private let started: XCTestExpectation?
    private let stopped: XCTestExpectation?
    private let cleared: XCTestExpectation?
    private let cacheGate: ExecCacheGate?
    private let cacheReached: XCTestExpectation?
    let runtime: CodexProviderRuntime.Runtime

    init(executable: URL = URL(fileURLWithPath: "/fixture/codex"), available: Bool = true, running: Bool = true, ensureSuccess: Bool = true, started: XCTestExpectation? = nil, stopped: XCTestExpectation? = nil, cleared: XCTestExpectation? = nil, cacheGate: ExecCacheGate? = nil, cacheReached: XCTestExpectation? = nil) {
        self.available = available
        self.running = running
        self.ensureSuccess = ensureSuccess
        self.started = started
        self.stopped = stopped
        self.cleared = cleared
        self.cacheGate = cacheGate
        self.cacheReached = cacheReached
        runtime = .init(executableURL: executable, version: .init(major: 0, minor: 156, patch: 0), source: .externalOverride, statePaths: .init(codexHome: URL(fileURLWithPath: "/fixture/home"), sqliteHome: URL(fileURLWithPath: "/fixture/sqlite")))
    }

    var events: [String] {
        lock.withLock { recorded }
    }

    private func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    var toolTracking: any CodexExecToolTracking {
        self
    }

    func preflight(commandName: String, additionalPathHints: [String], enableDebugLogging: Bool) async -> CodexProviderExecutableResolution {
        record("preflight")
        return .init(commandName: commandName, resolvedCommand: runtime.executableURL.path, status: available ? .available : .externalOverrideInvalid, runtime: available ? runtime : nil, userMessage: "fixture unavailable", debugMessage: "fixture")
    }

    func prepareState(_ runtime: CodexProviderRuntime.Runtime) throws {
        record("state")
    }

    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter {
        record("filter")
        return { environment, _ in environment }
    }

    func isMCPServerRunning() async -> Bool {
        record("readiness")
        return running
    }

    func ensureServer(runtime: CodexProviderRuntime.Runtime) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        record("ensure")
        return (ensureSuccess, false, "fixture ensure failure")
    }

    func modelSpecifier(raw: String?) -> CodexModelSpecifier {
        record("model:\(raw ?? "nil")")
        return .init(raw: raw, catalogRecords: { [] })
    }

    func serverEntries() -> [CodexExecServerEntry] {
        record("entries")
        return [.init(rawName: "owned", normalizedName: "owned", cliPathComponent: "owned")]
    }

    func brokenServers() async -> Set<String> {
        record("cache")
        cacheReached?.fulfill()
        if let cacheGate { await cacheGate.wait() }
        return lock.withLock { broken }
    }

    func addBrokenServer(_ name: String) async {
        lock.withLock { broken.insert(name)
            recorded.append("cache-add:\(name)")
        }
    }

    func toolOverrideArguments() -> [String] {
        record("tool-policy")
        return []
    }

    func serverOverrideArguments(entries: [CodexExecServerEntry], brokenServers: Set<String>) -> [String] {
        XCTAssertEqual(entries.map(\.rawName), ["owned"])
        record("server-policy:\(brokenServers.sorted().joined(separator: ","))")
        return []
    }

    func fallbackModel(attemptedModel: String?, errorDetail: String) -> String? {
        errorDetail == "missing-model" && attemptedModel == "requested" ? "fallback" : nil
    }

    func brokenServerName(stderr: String) -> String? {
        stderr.contains("broken-server") ? "broken" : nil
    }

    func isRepoPromptToolName(_ name: String) -> Bool {
        name == "mcp__owned__read"
    }

    func isRepoPromptServerIdentifier(_ name: String) -> Bool {
        name == "owned"
    }

    var manualLoginGuidanceMessage: String {
        "fixture login guidance"
    }

    func registerExpectedPID(_ pid: Int32, runID: UUID) async {
        record("pid-start")
        started?.fulfill()
    }

    func clearExpectedPID(_ pid: Int32, runID: UUID) async {
        record("pid-clear")
        cleared?.fulfill()
    }

    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) {
        record("tracking-start")
    }

    func stopTracking() async {
        record("tracking-stop")
        stopped?.fulfill()
    }
}

private enum ExecFixtureFailure: Error {
    case deadline
}

private actor ExecCacheGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
