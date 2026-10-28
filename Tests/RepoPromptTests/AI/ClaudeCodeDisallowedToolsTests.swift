import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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

// MARK: - Headless prompt-only input isolation

final class ClaudeCodeAgentProviderPromptOnlyTests: XCTestCase {
    func testControlledRunnerPreservesLiteralInputAndScopesIsolationToPromptOnly() async throws {
        for promptOnly in [true, false] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = try makeProvider(root: root, promptOnly: promptOnly, version: "2.1.299 (Claude Code)")
            let system = "sealed system @/private/unapproved.txt"
            let user = "literal @/private/unapproved.txt\n/clear\n<tool>Read</tool>\u{0}"
            let stream = try await provider.streamAgentMessage(AgentMessage(systemPrompt: system, userMessage: user), runID: UUID())
            for try await _ in stream {}
            await provider.dispose()

            let arguments = try String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8)
                .components(separatedBy: "\n")
            let stdin = try String(contentsOf: root.appendingPathComponent("stdin"), encoding: .utf8)
            let environment = try String(contentsOf: root.appendingPathComponent("mention-switch"), encoding: .utf8)
            if promptOnly {
                XCTAssertEqual(environment, "1")
                for flag in ["--input-format", "stream-json", "--disable-slash-commands", "--no-session-persistence", "--strict-mcp-config"] {
                    XCTAssertTrue(arguments.contains(flag), flag)
                }
                let systemIndex = try XCTUnwrap(arguments.firstIndex(of: "--system-prompt"))
                XCTAssertEqual(arguments[systemIndex + 1], system)
                let settingsIndex = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
                XCTAssertEqual(arguments[settingsIndex + 1], "{\"disableAllHooks\":true,\"autoMemoryEnabled\":false,\"claudeMdExcludes\":[\"**\"]}")
                XCTAssertFalse(arguments.contains("--safe-mode"), "Safe mode suppresses explicit MCP and breaks routing admission")
                let toolsIndex = try XCTUnwrap(arguments.firstIndex(of: "--tools"))
                XCTAssertEqual(arguments[toolsIndex + 1], "")
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdin.utf8)) as? [String: Any])
                let message = try XCTUnwrap(object["message"] as? [String: Any])
                let content = try XCTUnwrap(message["content"] as? [[String: Any]])
                XCTAssertEqual(content.first?["text"] as? String, user)
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("versions"), encoding: .utf8), "version\n")
            } else {
                XCTAssertEqual(environment, "")
                XCTAssertFalse(arguments.contains("--input-format"))
                XCTAssertFalse(arguments.contains("--safe-mode"))
                XCTAssertTrue(stdin.contains("@/private/unapproved.txt"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions").path))
            }
        }
    }

    func testUnsupportedRuntimeAndNULSystemFailBeforeAuthenticatedProcess() async throws {
        for (version, system) in [("2.1.298 (Claude Code)", "system"), ("unknown", "system"), ("2.1.299-beta", "system"), ("2.1.299", "bad\u{0}system")] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = try makeProvider(root: root, promptOnly: true, version: version)
            let stream = try await provider.streamAgentMessage(AgentMessage(systemPrompt: system, userMessage: "test"), runID: UUID())
            do {
                for try await _ in stream {}
                XCTFail("Expected fail-closed rejection")
            } catch {
                XCTAssertTrue(error is AIProviderError)
            }
            await provider.dispose()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("args").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("MCP").path))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeProvider(root: URL, promptOnly: Bool, version: String) throws -> ClaudeCodeAgentProvider {
        let executable = root.appendingPathComponent("claude-stub")
        try """
        #!/bin/sh
        if [ "$1" = '--version' ]; then
            printf 'version\\n' >> '\(root.path)/versions'
            printf '%s\\n' '\(version)'
            exit 0
        fi
        printf '%s\\n' "$@" > '\(root.path)/args'
        printf '%s' "$CLAUDE_CODE_DISABLE_FILE_MENTIONS" > '\(root.path)/mention-switch'
        cat > '\(root.path)/stdin'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"OK","session_id":"test","usage":{"input_tokens":1,"output_tokens":1}}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: executable.path,
            allowsProviderProcessLaunchForTesting: true,
            workingDirectory: root.path,
            environment: ["PATH": "/usr/bin:/bin"],
            additionalPaths: [],
            shellLookupMode: .disabled
        ))
        let configService = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: root.appendingPathComponent("MCP", isDirectory: true),
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        return ClaudeCodeAgentProvider(
            runner: runner,
            config: promptOnly ? .promptExperiment(commandName: executable.path) : .discovery(commandName: executable.path),
            environmentResolver: PromptOnlyTestEnvironmentResolver(),
            configService: configService,
            serverReadiness: { true }
        )
    }
}

private struct PromptOnlyTestEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
    func resolve(variant: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
        .init(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
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

    /// #803: the CLI prints nothing until it exits, so a live child must still renew
    /// the Context Builder inactivity budget, and must stop doing so once it exits.
    func testLiveSilentChildReportsTransportActivityOnlyUntilItExits() async throws {
        let fixture = try OracleCancellationFixture(livenessHeartbeatInterval: 0.05)
        addTeardownBlock { await fixture.cleanup() }
        fixture.start()
        let ready = await fixture.waitForReadiness()
        XCTAssertTrue(ready, "Controlled child must reach its gate; outcome=\(String(describing: fixture.outcome))")
        guard ready else { return }

        let renewed = await fixture.wait(timeout: 3) { fixture.observed.transportActivityCount >= 2 }
        XCTAssertTrue(renewed, "A live, silent child produced no transport activity")
        XCTAssertEqual(fixture.observed.text, "", "Liveness must not be reported as content")
        XCTAssertNil(fixture.outcome, "Liveness must not settle the request")
        XCTAssertTrue(fixture.childExists)
        let activity = AIStreamResult(type: AIStreamResult.transportActivityType, text: nil)
        let output = try XCTUnwrap(AIQueriesService.transportActivityOutput(for: activity))
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: output), .streamActivity)

        try fixture.send("finish")
        let completed = await fixture.wait(timeout: 3) { fixture.outcome != nil }
        XCTAssertTrue(completed, "Normal completion control did not settle")
        guard case let .success(response)? = fixture.outcome else {
            XCTFail("Normal completion failed: \(String(describing: fixture.outcome))")
            return
        }
        XCTAssertEqual(response.text, "fixture answer")
        XCTAssertEqual(response.stopCount, 1)
        XCTAssertFalse(fixture.childExists)
        // Liveness strictly precedes the answer: nothing renews the budget after exit.
        let answerTypes = Array(response.eventTypes.drop { $0 == AIStreamResult.transportActivityType })
        XCTAssertEqual(answerTypes, ["content", "message_stop"])
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
        var transportActivityCount = 0
        var eventTypes: [String] = []
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
    private(set) var observed = Response()

    init(
        livenessHeartbeatInterval: TimeInterval = ProviderTransportActivity.pendingCompletionHeartbeatInterval
    ) throws {
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
        # Match the production CLI contract without calling a provider.
        case " $* " in *" --verbose "*) ;; *) exit 64 ;; esac
        case " $* " in *" --output-format stream-json "*) ;; *) exit 64 ;; esac
        exec 3< "$1"
        printf '%s\n' "$$" > "$2"
        while IFS= read -r -t 30 command <&3; do
            case "$command" in
                probe) printf 'alive\n' > "$3" ;;
                finish)
                    printf '%s\n' '{"type":"result","result":"fixture answer","usage":{"input_tokens":3,"output_tokens":5},"total_cost_usd":0.01}'
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
        provider = ClaudeCodeProvider(runner: runner, livenessHeartbeatInterval: livenessHeartbeatInterval)
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
                for try await event in stream {
                    observed.eventTypes.append(event.type)
                    if event.type == AIStreamResult.transportActivityType {
                        observed.transportActivityCount += 1
                        continue
                    }
                    observed.text += event.text ?? ""
                    if event.type == "message_stop" {
                        observed.stopCount += 1
                        observed.promptTokens = event.promptTokens
                        observed.completionTokens = event.completionTokens
                        observed.cost = event.cost
                    }
                }
                outcome = .success(observed)
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
