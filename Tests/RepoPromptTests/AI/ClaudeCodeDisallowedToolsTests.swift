import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptProcess
import XCTest

final class ClaudeCodeDisallowedToolsTests: XCTestCase {
    /// Claude Code's native orchestration tools would bypass RepoPrompt's `agent_run`.
    func testAgentModeContextsBlockNativeOrchestrationTools() {
        let orchestrationTools = ["Agent", "Task", "Workflow", "ListAgents", "SendMessage"]
        for context in [AgentCLIToolContext.agentRun, .discoverRun, .promptOnly] {
            let disallowed = Set(ClaudeCodeIntegrationConfiguration.disallowedTools(for: context))
            for tool in orchestrationTools {
                XCTAssertTrue(disallowed.contains(tool), "\(tool) must be disallowed for \(context)")
            }
        }
    }
}

// MARK: - Oracle request cancellation

@MainActor
final class ClaudeCodeProviderCancellationTests: XCTestCase {
    func testCancellationStopsOwnedChildAndCompletesProviderTask() async throws {
        let fixture = try OracleCancellationFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.start()
        let ready = await fixture.waitForReadiness()
        XCTAssertTrue(ready, "Controlled child must be ready before cancellation; outcome=\(String(describing: fixture.outcome))")
        guard ready else { return }

        fixture.cancelRequest()
        // Allow the owner's 2s TERM + 1s KILL budget and scheduling margin.
        // This is a fixture bound, not a product cleanup SLA or pre-cancel sleep.
        _ = await fixture.wait(timeout: 5) {
            fixture.outcome != nil && !fixture.childExists
        }
        let taskCompletedAfterCancellation = fixture.outcome != nil
        let childExistedAfterCancellation = fixture.childExists

        // An acknowledgement proves execution after cancellation, not just a
        // zombie visible to kill(pid, 0). No output is imported into RPCE.
        try fixture.send("probe")
        let acknowledgedAfterCancellation = await fixture.wait(timeout: 1) {
            FileManager.default.fileExists(atPath: fixture.acknowledgement.path)
                || !fixture.childExists
        } && FileManager.default.fileExists(atPath: fixture.acknowledgement.path)
        // Registered teardown releases the fixture even when these fail.
        // Teardown cleanup is not credited as request-cancellation success.
        XCTAssertFalse(childExistedAfterCancellation, "Request cancellation left the owned CLI child present")
        XCTAssertTrue(taskCompletedAfterCancellation, "Provider task did not complete after request cancellation")
        XCTAssertFalse(acknowledgedAfterCancellation, "Owned child executed a gate command after cancellation")

        guard case let .failure(error)? = fixture.outcome else {
            XCTFail("Expected cancellation failure; outcome=\(String(describing: fixture.outcome))")
            return
        }
        var cancellationSource = error
        if case let .apiError(source)? = error as? AIProviderError, let source {
            cancellationSource = source
        }
        XCTAssertTrue(cancellationSource is CancellationError, "Expected cancellation-bearing failure: \(error)")
    }

    func testNormalCompletionPreservesResponseAndUsage() async throws {
        let fixture = try OracleCancellationFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.start()
        let ready = await fixture.waitForReadiness()
        XCTAssertTrue(ready, "Controlled child must reach its gate; outcome=\(String(describing: fixture.outcome))")
        guard ready else { return }

        try fixture.send("finish")
        let completed = await fixture.wait(timeout: 3) { fixture.outcome != nil }
        XCTAssertTrue(completed, "Normal completion control did not settle")
        guard case let .success(response)? = fixture.outcome else {
            XCTFail("Normal completion failed: \(String(describing: fixture.outcome))")
            return
        }
        XCTAssertEqual(response.text, "fixture answer")
        XCTAssertEqual(response.stopCount, 1)
        XCTAssertEqual(response.promptTokens, 3)
        XCTAssertEqual(response.completionTokens, 5)
        XCTAssertEqual(response.cost, 0.01)
        XCTAssertFalse(fixture.childExists, "Runner completion must follow owned-child exit/reap")
    }
}

/// Test-local protocol: the shell publishes its own PID only after opening the
/// gate, then accepts probe/finish commands. It launches no descendants, uses no
/// model or credentials, and exits after at most thirty seconds without a command.
@MainActor
private final class OracleCancellationFixture {
    struct Response {
        var text = ""
        var stopCount = 0
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
    }

    enum Outcome {
        case success(Response)
        case failure(Error)
    }

    let acknowledgement: URL
    private let directory: URL
    private let readiness: URL
    private let gateFD: Int32
    private let provider: ClaudeCodeProvider
    private var task: Task<Void, Never>?
    private(set) var pid: pid_t?
    private(set) var outcome: Outcome?

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oracle-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gate = directory.appendingPathComponent("gate")
        guard mkfifo(gate.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        // RDWR makes both sides' open nonblocking and avoids SIGPIPE when the
        // child exits. CLOEXEC prevents the runner's child inheriting this FD.
        let gateFD = open(gate.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard gateFD >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        self.directory = directory
        self.gateFD = gateFD
        readiness = directory.appendingPathComponent("ready")
        acknowledgement = directory.appendingPathComponent("ack")
        let script = #"""
        exec 3< "$1"
        printf '%s\n' "$$" > "$2"
        while IFS= read -r -t 30 command <&3; do
            case "$command" in
                probe) printf 'alive\n' > "$3" ;;
                finish)
                    printf '%s\n' '{"result":"fixture answer","usage":{"input_tokens":3,"output_tokens":5},"total_cost_usd":0.01}'
                    exit 0 ;;
                *) exit 65 ;;
            esac
        done
        exit 66
        """#
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "/usr/bin/env",
            allowsProviderProcessLaunchForTesting: true,
            workingDirectory: directory.path,
            additionalPaths: [],
            commandSuffix: ["-i", "/bin/sh", "-c", script, "oracle-fixture", gate.path, readiness.path, acknowledgement.path],
            shellLookupMode: .disabled
        ))
        // Only the runner configuration is substituted. Production provider timeout,
        // retries, prompt construction, buffered run and parsing stay intact.
        provider = ClaudeCodeProvider(runner: runner)
    }

    var childExists: Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }

    func start() {
        task = Task {
            do {
                let message = AIMessage(
                    systemPrompt: "local fixture",
                    temperature: nil,
                    promptSectionsOrder: [],
                    disabledPromptSections: []
                )
                let stream = try await provider.streamMessage(message, model: .claudeCode)
                var response = Response()
                for try await event in stream {
                    response.text += event.text ?? ""
                    if event.type == "message_stop" {
                        response.stopCount += 1
                        response.promptTokens = event.promptTokens
                        response.completionTokens = event.completionTokens
                        response.cost = event.cost
                    }
                }
                outcome = .success(response)
            } catch {
                outcome = .failure(error)
            }
        }
    }

    func waitForReadiness() async -> Bool {
        let publishedPID = await wait(timeout: 3) {
            if let contents = try? String(contentsOf: self.readiness, encoding: .utf8),
               contents.hasSuffix("\n"),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
            {
                self.pid = pid
                return self.childExists
            }
            return false
        }
        guard publishedPID else { return false }
        do {
            try send("probe")
            let acknowledged = await wait(timeout: 1) {
                FileManager.default.fileExists(atPath: self.acknowledgement.path)
            }
            guard acknowledged, outcome == nil, childExists else { return false }
            try FileManager.default.removeItem(at: acknowledgement)
            return true
        } catch {
            return false
        }
    }

    func cancelRequest() {
        task?.cancel()
    }

    func send(_ command: String) throws {
        let data = Data("\(command)\n".utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(gateFD, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    func wait(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return true
    }

    func cleanup() async {
        task?.cancel()
        try? send("finish")
        var settled = await wait(timeout: 2) { outcome != nil && !childExists }
        if !settled {
            // The real runner's per-instance registry owns signalling/reaping;
            // no global process sweep or competing destructive waitpid owner.
            await provider.dispose()
            settled = await wait(timeout: 10) { outcome != nil && !childExists }
        } else {
            await provider.dispose()
        }
        if settled, let task { await task.value }
        XCTAssertTrue(settled, "Fixture-owned child/task did not settle during bounded cleanup")
        close(gateFD)
        try? FileManager.default.removeItem(at: directory)
    }
}
