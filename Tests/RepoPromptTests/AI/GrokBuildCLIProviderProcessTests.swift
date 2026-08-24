import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildCLIProviderProcessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        registerDiscoveredModels()
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testOneShotUsesTrustedPathPrivatePromptAndNoToolPolicy() async throws {
        let harness = try makeHarness(scenario: "ok")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness, apiKeyProvider: { "test-grok-key" })
        defer { Task { await provider.dispose() } }

        let results = try await collect(
            provider: provider,
            message: AgentMessage(systemPrompt: "System rules", userMessage: "hi")
        )

        XCTAssertEqual(results.map(\.type), ["reasoning", "content", "message_stop"])
        XCTAssertEqual(results[0].reasoning, "because")
        XCTAssertEqual(results[1].text, "oneshot ok")
        XCTAssertEqual(results[2].stopReason, "end_turn")
        XCTAssertEqual(results[2].promptTokens, 3)
        XCTAssertEqual(results[2].completionTokens, 2)

        let record = try harness.record()
        let argv = try XCTUnwrap(record["argv"] as? [String])
        XCTAssertFalse(argv.contains("agent"))
        XCTAssertFalse(argv.contains("stdio"))
        XCTAssertEqual(argument(after: "--output-format", in: argv), "json")
        XCTAssertEqual(argument(after: "--max-turns", in: argv), "1")
        XCTAssertTrue(argv.contains("--verbatim"))
        XCTAssertTrue(argv.contains("--no-subagents"))
        XCTAssertTrue(argv.contains("--no-plan"))
        XCTAssertTrue(argv.contains("--no-memory"))
        XCTAssertTrue(argv.contains("--disable-web-search"))
        XCTAssertEqual(argument(after: "-m", in: argv), "grok-4.6")

        XCTAssertEqual(argument(after: "--tools", in: argv), "read_file")
        XCTAssertEqual(
            Set(
                (argument(after: "--disallowed-tools", in: argv) ?? "")
                    .split(separator: ",")
                    .map(String.init)
            ),
            Set(["read_file", "search_tool", "use_tool"])
        )
        XCTAssertEqual(
            Set(arguments(afterEach: "--deny", in: argv)),
            Set(["Read", "Grep", "Edit", "Write", "Bash", "WebFetch", "MCPTool"])
        )
        XCTAssertEqual(
            argument(after: "--system-prompt-override", in: argv),
            "You are a text-only assistant.\nNo tools are available.\nDo not claim to call, inspect, read, search, or modify external resources.\nAnswer from the supplied prompt and context.\nProvide the final answer directly without progress narration."
        )
        XCTAssertFalse(argv.contains { $0.contains("System rules") })
        XCTAssertFalse(argv.contains { $0.contains("hi") })

        XCTAssertEqual(record["xai"] as? String, "test-grok-key")
        XCTAssertEqual(record["prompt"] as? String, "System rules\n\nhi")
        XCTAssertEqual(record["prompt_mode"] as? String, "0o600")
        XCTAssertEqual(record["prompt_dir_mode"] as? String, "0o700")
        XCTAssertEqual(
            normalizedTemporaryPath(record["executable"] as? String),
            normalizedTemporaryPath(harness.executable.path)
        )

        let promptPath = try XCTUnwrap(record["prompt_path"] as? String)
        XCTAssertEqual(
            normalizedTemporaryPath(record["cwd"] as? String),
            normalizedTemporaryPath((promptPath as NSString).deletingLastPathComponent)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: promptPath))
    }

    func testEffortVariantDecomposesOnlyAfterRegistryValidation() async throws {
        let harness = try makeHarness(scenario: "ok")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness, modelString: "grok-4.6-high")
        defer { Task { await provider.dispose() } }

        _ = try await collect(provider: provider)

        let argv = try XCTUnwrap(harness.record()["argv"] as? [String])
        XCTAssertEqual(argument(after: "-m", in: argv), "grok-4.6")
        XCTAssertEqual(argument(after: "--reasoning-effort", in: argv), "high")
    }

    func testUnknownModelFailsBeforeProcessLaunch() async throws {
        let harness = try makeHarness(scenario: "ok")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness, modelString: "grok-does-not-exist")
        defer { Task { await provider.dispose() } }

        do {
            _ = try await collect(provider: provider)
            XCTFail("unknown model should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not in the discovered model set"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.recordURL.path))
    }

    func testKeyProviderFailurePropagatesBeforeProcessLaunch() async throws {
        let harness = try makeHarness(scenario: "ok")
        defer { harness.cleanup() }
        let expectedError = NSError(domain: "GrokBuildKeyProvider", code: 1)
        let provider = makeProvider(harness: harness, apiKeyProvider: { throw expectedError })
        defer { Task { await provider.dispose() } }

        do {
            _ = try await collect(provider: provider)
            XCTFail("key-provider failure should propagate")
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, expectedError.domain)
            XCTAssertEqual(error.code, expectedError.code)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.recordURL.path))
    }

    func testStructuredStdoutErrorPreservesProviderMessage() async throws {
        let harness = try makeHarness(scenario: "structured-error")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness)
        defer { Task { await provider.dispose() } }

        do {
            _ = try await collect(provider: provider)
            XCTFail("structured error should fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("quota exhausted {retry later}"),
                "\(error)"
            )
        }
    }

    func testEmptyCompletedAnswerFails() async throws {
        let harness = try makeHarness(scenario: "empty")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness)
        defer { Task { await provider.dispose() } }

        do {
            _ = try await collect(provider: provider)
            XCTFail("empty completed JSON should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("no completion"), "\(error)")
        }
    }

    func testCancellingReturnedStreamKillsChildAndRemovesPrompt() async throws {
        let harness = try makeHarness(scenario: "hang")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness, requestTimeout: 8)
        defer { Task { await provider.dispose() } }

        let stream = try await provider.streamAgentMessage(
            AgentMessage(userMessage: "hi"),
            runID: nil
        )
        let consumer = Task {
            var results: [AIStreamResult] = []
            for try await result in stream {
                results.append(result)
            }
            return results
        }

        let pidDeadline = Date().addingTimeInterval(6)
        while harness.childPID() == nil, Date() < pidDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pid = try XCTUnwrap(harness.childPID(), "fake grok never started")
        let promptPath = try XCTUnwrap(harness.record()["prompt_path"] as? String)
        XCTAssertEqual(kill(pid, 0), 0, "child \(pid) was not running before cancellation")

        consumer.cancel()
        _ = try? await consumer.value

        let exitDeadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotEqual(kill(pid, 0), 0, "child \(pid) still running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: promptPath))
    }

    func testUnsafeConfiguredExecutableIsRejected() async throws {
        let harness = try makeHarness(scenario: "ok", executableName: "fake-grok")
        defer { harness.cleanup() }
        let provider = makeProvider(harness: harness)
        defer { Task { await provider.dispose() } }

        do {
            _ = try await collect(provider: provider)
            XCTFail("unsafe executable should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("unsafe"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.recordURL.path))
    }

    private func registerDiscoveredModels() {
        let base = AgentModelOption(
            rawValue: "grok-4.6",
            displayName: "Grok 4.6",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: true
        )
        let high = AgentModelOption(
            rawValue: "grok-4.6-high",
            displayName: "Grok 4.6 High",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(
                baseModelRaw: "grok-4.6",
                reasoningEffort: .high
            )
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [base, high],
                currentModelRaw: "grok-4.6"
            ),
            for: .grokBuild
        )
    }

    private func makeProvider(
        harness: Harness,
        modelString: String = "grok-4.6",
        requestTimeout: TimeInterval = 5,
        apiKeyProvider: @escaping GrokBuildOneShotHeadlessAgentProvider.APIKeyProvider = { nil }
    ) -> GrokBuildOneShotHeadlessAgentProvider {
        GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildAgentConfig(
                commandName: harness.executable.path,
                additionalPathHints: [],
                modelString: modelString,
                includeRepoPromptMCPServer: false,
                alwaysApproveTools: false
            ),
            launchResolver: GrokBuildACPLaunchResolver(environmentProvider: { _ in
                ProcessInfo.processInfo.environment
            }),
            requestTimeout: requestTimeout,
            apiKeyProvider: apiKeyProvider
        )
    }

    private func collect(
        provider: GrokBuildOneShotHeadlessAgentProvider,
        message: AgentMessage = AgentMessage(userMessage: "hi")
    ) async throws -> [AIStreamResult] {
        let stream = try await provider.streamAgentMessage(message, runID: nil)
        var results: [AIStreamResult] = []
        for try await result in stream {
            results.append(result)
        }
        return results
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private func arguments(afterEach flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag else { return nil }
            let valueIndex = arguments.index(after: index)
            return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
        }
    }

    private func normalizedTemporaryPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private struct Harness {
        let directory: URL
        let executable: URL
        let recordURL: URL

        func record() throws -> [String: Any] {
            let data = try Data(contentsOf: recordURL)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func childPID() -> pid_t? {
            let pidURL = directory.appendingPathComponent("pid")
            guard let raw = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
            return pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness(
        scenario: String,
        executableName: String = "grok"
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-grok-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(executableName)
        let recordURL = directory.appendingPathComponent("record.json")
        let script = """
        #!/usr/bin/env python3
        import json, os, sys, time

        here = os.path.dirname(os.path.abspath(__file__))
        argv = sys.argv[1:]
        if argv == ["agent", "--help"]:
            print("Commands:\\n  stdio", flush=True)
            sys.exit(0)

        prompt_path = None
        if "--prompt-file" in argv:
            prompt_path = argv[argv.index("--prompt-file") + 1]
        record = {
            "argv": argv,
            "xai": os.environ.get("XAI_API_KEY"),
            "prompt_path": prompt_path,
            "prompt": open(prompt_path).read() if prompt_path and os.path.exists(prompt_path) else None,
            "prompt_mode": oct(os.stat(prompt_path).st_mode & 0o777) if prompt_path else None,
            "prompt_dir_mode": oct(os.stat(os.path.dirname(prompt_path)).st_mode & 0o777) if prompt_path else None,
            "executable": os.path.realpath(sys.argv[0]),
            "cwd": os.getcwd(),
        }
        open(os.path.join(here, "record.json"), "w").write(json.dumps(record))

        scenario = "\(scenario)"
        if scenario == "hang":
            open(os.path.join(here, "pid"), "w").write(str(os.getpid()))
            time.sleep(30)
            sys.exit(0)
        if scenario == "empty":
            print(json.dumps({"text": "", "stopReason": "end_turn"}), flush=True)
            sys.exit(0)
        if scenario == "structured-error":
            print(json.dumps({"type": "error", "message": "quota exhausted {retry later}"}), flush=True)
            sys.exit(42)
        print(json.dumps({
            "text": "oneshot ok",
            "thought": "because",
            "stopReason": "end_turn",
            "sessionId": "session-1",
            "usage": {"input_tokens": 3, "output_tokens": 2}
        }), flush=True)
        """
        try script.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n")
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Harness(directory: directory, executable: executable, recordURL: recordURL)
    }
}
