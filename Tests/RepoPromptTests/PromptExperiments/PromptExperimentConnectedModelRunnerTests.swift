import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptProcess
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentConnectedModelRunnerTests: XCTestCase {
        func testOnlyToolFreeProvidersArePromptOnlyTargetsAndErrorsNameTheField() throws {
            let claude = PromptExperimentTestFixtures.execution
            let codex = try PromptExperimentTestFixtures.resolveTarget("codex")
            XCTAssertNoThrow(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(claude))
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(codex))
            let unknown = PromptExperimentResolvedTarget(role: "x", agentRaw: "notAProvider", modelRaw: "m", displayName: "X")
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(unknown))

            let errors = PromptExperimentConnectedModelRunner.targetErrors(
                PromptExperimentTargets(execution: claude, reflection: codex, judge: unknown)
            )
            XCTAssertEqual(errors.map(\.field), ["reflection", "judge"])
        }

        func testProviderFailureClassificationIsClosedAndRetryabilityIsExplicit() {
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("HTTP 429 rate limit").code, .rateLimited)
            XCTAssertTrue(PromptExperimentProviderFailureCode.rateLimited.isRetryable)
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("OAuth authentication expired").code, .rejected)
            XCTAssertFalse(PromptExperimentProviderFailureCode.rejected.isRetryable)
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("surprising opaque failure").code, .unknown)
            XCTAssertFalse(PromptExperimentProviderFailureCode.unknown.isRetryable)
            XCTAssertFalse(PromptExperimentProviderFailureCode.timedOut.isRetryable)
        }

        func testInStreamErrorEventsClassifyTransientFailuresAsRetryable() {
            let overloaded = AIStreamResult(
                type: "error",
                text: #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
            )
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(overloaded).code, .temporarilyUnavailable)
            let rateLimited = AIStreamResult(
                type: "error",
                text: #"API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}"#
            )
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(rateLimited).code, .rateLimited)
            let unavailable = AIStreamResult(type: "error", text: "API Error: 503 Service Unavailable")
            XCTAssertTrue(PromptExperimentConnectedModelRunner.classifyStreamError(unavailable).code.isRetryable)
            let typed = AIStreamResult(type: "error", text: "opaque", stopReason: "rate_limit")
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(typed).code, .rateLimited)
            let opaque = AIStreamResult(type: "error", text: "Something odd happened")
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(opaque).code, .unknown)
            XCTAssertFalse(PromptExperimentConnectedModelRunner.classifyStreamError(opaque).code.isRetryable)
        }

        func testCompletionPreservesMessageBoundariesAndTerminalUsage() throws {
            let provider = CodexExecAgentProvider(config: .init(commandName: "codex", additionalPathHints: []))
            var accumulator = PromptExperimentCompletionAccumulator()
            let answer = "{\"action\":\"answer\",\"text\":\"same answer\"}"
            for id in ["commentary-id", "final-id"] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "item.completed", "item": ["type": "agent_message", "id": id, "text": answer]
                ])
                let event = try XCTUnwrap(provider.parseJSONLEvent(data))
                XCTAssertEqual(event.contentMessageID, id)
                accumulator.consume(event)
            }
            let terminal = try XCTUnwrap(provider.parseJSONLEvent(Data(
                #"{"type":"turn.completed","usage":{"input_tokens":31,"output_tokens":9}}"#.utf8
            )))
            accumulator.consume(terminal)
            XCTAssertEqual(accumulator.output, answer)
            XCTAssertEqual(accumulator.promptTokens, 31)
            XCTAssertEqual(accumulator.completionTokens, 9)
            var deltas = PromptExperimentCompletionAccumulator()
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            XCTAssertEqual(deltas.output, "samesame", "Do not heuristically deduplicate valid token deltas")
            deltas.consume(AIStreamResult(type: "final_content", text: "authoritative final"))
            XCTAssertEqual(deltas.output, "authoritative final")
        }

        func testPromptOnlyClaudeProfileDisablesNativeAndWebTools() {
            let configuration = ClaudeCodeAgentConfig.promptExperiment(modelString: "claude-sonnet-4-6")
            XCTAssertFalse(configuration.allowNativeBashTool)
            XCTAssertTrue(configuration.mcpStrictMode)
            XCTAssertFalse(configuration.toolSearchEnabled)
            for tool in ["Bash", "Read", "Write", "Edit", "WebSearch", "WebFetch", "Task"] {
                XCTAssertTrue(configuration.disallowedBuiltInTools.contains(tool))
            }
            XCTAssertTrue(configuration.processEnvironmentOverrides.isEmpty)
        }
    }
#endif

#if DEBUG
    @MainActor
    final class PromptExperimentAgentHarnessTests: XCTestCase {
        private let specification = """
        {"schema_version":1,"checks":[{"id":"addition","path":"task.py","function":"add","arguments":[1,2],"expected":3}],"preserve_files":["GUIDE.md"],"max_turns":4,"timeout_seconds":10}
        """

        func testBuiltInEngineerUsesRealFixtureSuiteAndProductionRenderer() throws {
            let suite = try PromptSuiteLoader.load(promptID: .engineer)
            XCTAssertEqual(suite.grader.kind, .external)
            XCTAssertNil(suite.grader.rubric)
            XCTAssertEqual(suite.cases(in: .training).count, 3)
            XCTAssertEqual(suite.cases(in: .validation).count, 2)
            XCTAssertEqual(suite.cases(in: .hiddenTest).count, 2)
            for example in suite.cases {
                XCTAssertNoThrow(try PromptExperimentAgentHarness.validate(case: example))
            }
            let registry = AppDomainRuntimeComposition.shared.builtInPromptRegistry
            let body = registry.text(.engineer)
            XCTAssertTrue(AgentModePrompts.isValidEngineerTemplate(body))
            XCTAssertFalse(AgentModePrompts.isValidEngineerTemplate(body + "{{rpce.after_task}}"))
            for kind: AgentProviderKind? in [nil, .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec] {
                for codeMapsDisabled in [false, true] {
                    let baseline = SystemPromptService.agentModePrompt(
                        registry: registry, agentKind: kind, taskLabelKind: .engineer, codeMapsDisabled: codeMapsDisabled
                    )
                    XCTAssertEqual(baseline, AgentModePrompts.engineerPrompt(agentKind: kind, codeMapsDisabled: codeMapsDisabled, body: body))
                    XCTAssertFalse(baseline.contains("{{rpce."))
                }
            }
        }

        func testEngineerPromptUsesInjectedRegistry() throws {
            let root = try temporaryRoot()
            let directory = root.appendingPathComponent(BuiltInPromptID.engineer.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = "Use the injected Engineer prompt authority."
            let body = AppDomainRuntimeComposition.shared.builtInPromptRegistry.text(.engineer) + "\n\n" + marker
            try (body + "\n").write(to: directory.appendingPathComponent(BuiltInPromptID.promptFileName), atomically: true, encoding: .utf8)
            let registry = BuiltInPromptRegistry(promptsDirectory: root)
            let prompt = SystemPromptService.agentModePrompt(registry: registry, agentKind: .claudeCode, taskLabelKind: .engineer)
            XCTAssertEqual(prompt, AgentModePrompts.engineerPrompt(agentKind: .claudeCode, body: body))
            XCTAssertTrue(prompt.hasSuffix(marker))
        }

        func testFreshWorkspacesAndPrivateChecksAreUsedForEachEvaluation() async throws {
            let root = try temporaryRoot()
            let runner = FakeRunner()
            let checker = FileChecker()
            let harness = makeHarness(root: root, runner: runner, checker: checker)
            for _ in 0 ..< 2 {
                let result = try await harness.evaluate(candidate: "Project engineer instructions", example: example(), evaluationID: UUID())
                XCTAssertEqual(result.score, 1)
                XCTAssertEqual(result.usage?.completionTokens, 80)
            }
            XCTAssertEqual(runner.workspaces.count, 2)
            XCTAssertNotEqual(runner.workspaces[0], runner.workspaces[1])
            for workspace in runner.workspaces {
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "Settled task state must be removed")
            }
            XCTAssertEqual(checker.calls, 2)
        }

        func testTestExpectationCannotBeEditedAndUnrequestedChangeLowersScore() async throws {
            let runner = FakeRunner()
            runner.changeGuide = true
            let harness = try makeHarness(root: temporaryRoot(), runner: runner, checker: FileChecker())
            let result = try await harness.evaluate(candidate: "Project prompt", example: example(), evaluationID: UUID())
            XCTAssertEqual(result.score, 0.5)
            XCTAssertTrue(result.proposerFeedback.contains("unrequested change"))
            XCTAssertFalse(runner.userMessage.contains("expected"))
            XCTAssertFalse(runner.userMessage.contains("addition"), "Host acceptance inputs and expected values are never sent to the agent")
        }

        func testHeldOutCheckFeedbackNeverReachesReflection() async throws {
            let harness = try makeHarness(root: temporaryRoot(), runner: FakeRunner(), checker: FileChecker())
            let result = try await harness.evaluate(candidate: "Project prompt", example: example(split: .hiddenTest), evaluationID: UUID())
            XCTAssertEqual(result.proposerFeedback, PromptSuiteSplit.heldOutFeedback)
            XCTAssertFalse(result.proposerFeedback.contains("addition"))
            XCTAssertTrue(result.output.contains("addition"), "Full evidence remains host-side")
        }

        func testFixtureTraversalAndUnknownTestFieldsFailBeforeModelSpend() async throws {
            let runner = FakeRunner()
            let harness = try makeHarness(root: temporaryRoot(), runner: runner, checker: FileChecker())
            var bad = example()
            bad.context = .init(fileTree: nil, files: [.init(path: "../escape.py", content: "bad")])
            do {
                _ = try await harness.evaluate(candidate: "Project prompt", example: bad, evaluationID: UUID())
                XCTFail("Invalid fixture must be rejected")
            } catch {}
            XCTAssertTrue(runner.workspaces.isEmpty)
            XCTAssertThrowsError(try PromptExperimentAgentAcceptance.decode(specification.replacingOccurrences(
                of: "\"schema_version\":1", with: "\"schema_version\":1,\"ignored_test\":true"
            )))
        }

        func testCancellationStopsAgentAndRemovesItsWorkspace() async throws {
            let runner = FakeRunner()
            runner.waitUntilCancelled = true
            let harness = try makeHarness(root: temporaryRoot(), runner: runner, checker: FileChecker())
            let task = Task { try await harness.evaluate(candidate: "Project prompt", example: example(), evaluationID: UUID()) }
            while runner.workspaces.isEmpty {
                await Task.yield()
            }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {} catch { XCTFail("Unexpected cancellation result: \(error)") }
            XCTAssertTrue(runner.cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runner.workspaces[0].path))
        }

        func testLaunchUsesExplicitProfileNormalPermissionsAndNativeSystemInjection() throws {
            let root = try temporaryRoot()
            let server = PromptExperimentConnectedAgentTaskRunner.serverConfiguration(
                executable: "/test/repoprompt-mcp", workspace: root.appendingPathComponent("workspace"),
                profile: root.appendingPathComponent("profile")
            )
            XCTAssertEqual(server.args, ["--backend", "headless"])
            XCTAssertEqual(server.environmentDictionary[PromptExperimentAgentProfile.environmentKey], "engineer-v1")
            let config = ClaudeCodeAgentConfig.agentMode(
                modelString: "test-model", permissionMode: "default", allowNativeBashTool: false,
                disallowedBuiltInTools: [], mcpStrictMode: true, toolSearchEnabled: false
            )
            let provider = ClaudeCodeAgentProvider(
                runner: CLIProcessRunner(config: .init(command: "/test/claude")),
                config: config, isolatedExperiment: .init(maximumTurns: 4, timeoutSeconds: 10)
            )
            let arguments = provider.buildArguments(
                context: .init(runID: UUID(), configURL: root.appendingPathComponent("mcp.json"), environment: [:]),
                systemPromptOverride: "candidate-system"
            )
            XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            XCTAssertEqual(value("--permission-mode"), "default")
            XCTAssertEqual(value("--system-prompt"), "candidate-system")
            XCTAssertEqual(value("--tools"), "")
            XCTAssertEqual(value("--max-turns"), "4")
            XCTAssertEqual(value("--setting-sources"), "")
            XCTAssertEqual(
                Set((value("--allowedTools") ?? "").split(separator: ",").map(String.init)),
                Set(PromptExperimentAgentProfile.toolNames.map { "mcp__RepoPromptCE__\($0)" })
            )
        }

        func testSandboxedAcceptanceExecutesCodeAndDeniesWritesOutsideFixture() async throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw XCTSkip("macOS sandbox-exec is unavailable") }
            let python = try await availableAcceptancePython()
            let root = try temporaryRoot()
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let target = workspace.appendingPathComponent("task.py")
            let checker = PromptExperimentPythonAcceptanceRunner(python: python)
            try await checker.preflight()
            let check = try XCTUnwrap(PromptExperimentAgentAcceptance.decode(specification).checks.first)
            try "def addition(a, b):\n    return a + b\n".write(to: workspace.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
            try "from helper import addition\ndef add(a, b):\n    return addition(a, b)\n".write(to: target, atomically: true, encoding: .utf8)
            let passing = try await checker.check(check, workspace: workspace, timeout: 5)
            XCTAssertTrue(passing.passed, passing.feedback)
            try "def add(a, b):\n    return a - b\n".write(to: target, atomically: true, encoding: .utf8)
            let incorrect = try await checker.check(check, workspace: workspace, timeout: 5)
            XCTAssertFalse(incorrect.passed)
            let privateFile = root.appendingPathComponent("secret.txt")
            try "sealed".write(to: privateFile, atomically: true, encoding: .utf8)
            try "def add(a, b):\n    open(\(String(reflecting: privateFile.path)), 'w').write('tampered')\n    return a+b\n".write(
                to: target, atomically: true, encoding: .utf8
            )
            let blocked = try await checker.check(check, workspace: workspace, timeout: 5)
            XCTAssertFalse(blocked.passed)
            XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "sealed")
        }

        func testAcceptanceMemoryLimitAccountsForDarwinReservationsAndPreservesInheritedBounds() async throws {
            let python = try await availableAcceptancePython()
            let program = PromptExperimentPythonAcceptanceRunner.addressSpaceLimitProgram + "\n" + """
            class Kernel:
                RLIMIT_AS, RLIM_INFINITY = 5, -1
                def __init__(self, baseline, original=(-1, -1)):
                    self.baseline, self.original, self.current = baseline, original, original
                    self.changes, self.attempts = [], 0
                def getrlimit(self, resource):
                    assert resource == self.RLIMIT_AS
                    return self.current
                def setrlimit(self, resource, limits):
                    assert resource == self.RLIMIT_AS
                    self.attempts += 1
                    assert self.attempts < 150, "The search must be bounded"
                    soft, hard = limits
                    if self.current[1] != -1 and (hard == -1 or hard > self.current[1]):
                        raise PermissionError("The hard limit cannot be raised")
                    if (hard != -1 and (soft == -1 or soft > hard)) or (soft != -1 and soft < self.baseline):
                        raise ValueError("Darwin rejects a limit below mapped size")
                    self.current = limits
                    self.changes.append(limits)
            mib, gib, maximum = 1024 * 1024, 1024 * 1024 * 1024, (1 << 63) - 1
            baseline = 389 * gib + 173
            kernel = Kernel(baseline)
            limit = rpce_limit_address_space(kernel, "darwin", maximum)
            assert 512 * mib <= limit - baseline < 513 * mib
            assert kernel.current == (limit, limit)
            for index, change in enumerate(kernel.changes[:-1]):
                if change != kernel.original:
                    assert change[1] == kernel.original[1], "Probes must preserve the hard limit"
                    assert kernel.changes[index + 1] == kernel.original, "Restore immediately after every successful probe"
            for original in [(baseline + 128 * mib, baseline + 256 * mib), (baseline + 64 * mib, baseline + 64 * mib)]:
                kernel = Kernel(baseline, original)
                expected = min(value for value in original if value != -1)
                assert rpce_limit_address_space(kernel, "darwin", maximum) == expected
                assert kernel.current == (expected, expected), "Do not relax inherited limits"
            kernel = Kernel(64 * mib)
            assert rpce_limit_address_space(kernel, "linux", maximum) == 512 * mib
            assert len(kernel.changes) == 1, "Other platforms retain the absolute cap"
            class RefusingKernel(Kernel):
                def setrlimit(self, resource, limits):
                    self.attempts += 1
                    raise ValueError("Cannot apply this limit")
            kernel = RefusingKernel(baseline)
            try:
                rpce_limit_address_space(kernel, "darwin", maximum)
                raise AssertionError("Never continue without an established limit")
            except RuntimeError:
                assert kernel.attempts < 40
            class BrokenKernel(Kernel):
                def setrlimit(self, resource, limits):
                    raise OSError("Kernel operation failed")
            try:
                rpce_limit_address_space(BrokenKernel(baseline), "darwin", maximum)
                raise AssertionError("Unexpected kernel failures must escape")
            except OSError:
                pass
            print("ADDRESS_SPACE_LIMIT_OK")
            """
            let runner = CLIProcessRunner(config: .init(command: python.path, processPurpose: .tool, shellLookupMode: .disabled))
            let result = try await runner.run(
                args: ["-I", "-S", "-c", program], stdin: nil, outputMode: .none, timeout: 10, cancelChildOnTaskCancellation: true
            )
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "ADDRESS_SPACE_LIMIT_OK")
        }

        private func availableAcceptancePython() async throws -> URL {
            let configured = PromptExperimentGEPAWorker.configuredPythonExecutable().map { [$0] } ?? []
            let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3").path }
            let candidates = configured + pathCandidates + ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            guard let selected = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw XCTSkip("No Python interpreter is installed")
            }
            let runner = CLIProcessRunner(config: .init(command: selected, processPurpose: .tool, shellLookupMode: .disabled))
            let result = try await runner.run(
                args: ["-I", "-S", "-c", "import os,sys; print(os.path.realpath(sys.executable))"],
                stdin: nil, outputMode: .none, timeout: 10, cancelChildOnTaskCancellation: true
            )
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(path.hasPrefix("/"), "Python must report its absolute executable")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            return URL(fileURLWithPath: path)
        }

        func testHeadlessUsageIncludesCachesOnlyInVerifiedAggregateTotal() throws {
            let provider = ClaudeCodeAgentProvider(
                runner: CLIProcessRunner(config: .init(command: "/test/claude")),
                config: .promptExperiment(modelString: "test-model")
            )
            let events = try provider.parseStreamEvents(Data(
                #"{"type":"result","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":80,"cache_creation_input_tokens":5}}"#.utf8
            ))
            guard case let .completion(usage, _, _) = events.last else { return XCTFail("Expected terminal usage") }
            XCTAssertEqual(usage?.inputTokens, 10, "Existing billing-input field remains compatible")
            XCTAssertEqual(usage?.totalInputTokens, 95)
            XCTAssertEqual(usage?.cachedInputTokens, 80)
            XCTAssertEqual(usage?.cacheCreationInputTokens, 5)
            XCTAssertNil(usage?.contextUsedTokens, "A final aggregate is not a live context snapshot")

            var accumulator = PromptExperimentCompletionAccumulator()
            accumulator.consume(.init(type: "usage", text: nil, promptTokens: 10, contextUsedTokens: 999))
            XCTAssertNil(accumulator.totalInputTokens, "Never infer an experiment total from a live context estimate")
            accumulator.consume(.init(type: "message_stop", text: nil, completionTokens: 20, totalInputTokens: 95))
            XCTAssertEqual(accumulator.totalInputTokens, 95)
            XCTAssertEqual(accumulator.completionTokens, 20)
        }

        private func example(split: PromptSuiteSplit = .training) -> PromptSuiteCase {
            .init(
                id: "task", split: split, input: "Fix add(a,b) in task.py. Preserve GUIDE.md.",
                expectedOutput: specification,
                context: .init(fileTree: nil, files: [
                    .init(path: "task.py", content: "def add(a,b):\n    return a-b\n"),
                    .init(path: "GUIDE.md", content: "unchanged\n")
                ])
            )
        }

        private func temporaryRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("engineer-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }

        private func makeHarness(root: URL, runner: FakeRunner, checker: FileChecker) -> PromptExperimentAgentHarness {
            .init(
                executionTarget: PromptExperimentTestFixtures.execution,
                evaluationRoot: root,
                usesProductionTemplate: false,
                checkpoint: { _ in },
                progress: { _ in },
                runner: runner,
                checker: checker
            )
        }

        private final class FakeRunner: PromptExperimentAgentTaskRunning {
            var workspaces: [URL] = []
            var userMessage = ""
            var changeGuide = false
            var waitUntilCancelled = false
            var cancelled = false
            func preflight(target _: PromptExperimentResolvedTarget) throws {}
            func run(
                target _: PromptExperimentResolvedTarget, systemPrompt: String, task: String,
                workspace: URL, profile: URL, maximumTurns: Int, timeout: TimeInterval
            ) async throws -> PromptExperimentAgentTaskResult {
                workspaces.append(workspace)
                userMessage = task
                XCTAssertFalse(systemPrompt.isEmpty)
                XCTAssertFalse(profile.path.hasPrefix(workspace.path + "/"))
                XCTAssertEqual(maximumTurns, 4)
                XCTAssertEqual(timeout, 10)
                let source = workspace.appendingPathComponent("task.py")
                XCTAssertTrue(try String(contentsOf: source, encoding: .utf8).contains("return a-b"))
                XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: workspace.path)), ["task.py", "GUIDE.md"])
                if waitUntilCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        cancelled = true
                        throw error
                    }
                }
                try "def add(a,b):\n    return a+b\n".write(to: source, atomically: true, encoding: .utf8)
                if changeGuide { try "tampered".write(to: workspace.appendingPathComponent("GUIDE.md"), atomically: true, encoding: .utf8) }
                return .init(output: "Implemented addition.", transcript: "apply_edits", toolCalls: 1, promptTokens: 100, completionTokens: 80)
            }
        }

        private final class FileChecker: PromptExperimentAgentChecking {
            var calls = 0
            func preflight() async throws {}
            func check(_ check: PromptExperimentAgentAcceptance.Check, workspace: URL, timeout _: TimeInterval) async throws -> PromptExperimentAgentCheckResult {
                calls += 1
                let text = try String(contentsOf: workspace.appendingPathComponent(check.path), encoding: .utf8)
                return .init(passed: text.contains("return a+b"), feedback: "\(check.id): checked private expectation")
            }
        }
    }
#endif
