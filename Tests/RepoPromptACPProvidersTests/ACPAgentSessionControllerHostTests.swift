import Darwin
import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class ACPAgentSessionControllerHostTests: XCTestCase {
    func testACPBootstrapRefusesDevinNewAndColdResumeWithoutFixtureOptIn() async throws {
        for resumeID in [nil, "persisted-devin-session"] as [String?] {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ACPRefusal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let recordURL = workspace.appendingPathComponent("requests.jsonl")
            let script = workspace.appendingPathComponent("server.py")
            try "import os\nopen(os.environ['OBS_FILE'], 'w').write('launched')\n".write(to: script, atomically: true, encoding: .utf8)
            let provider = FixtureProvider(providerID: .devin, script: script.path, observations: recordURL.path)
            let request = ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: workspace.path, resumeSessionID: resumeID, attachments: [], taskLabelKind: nil)
            let host = RecordingHost()
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, host: host)
            let expectedMode: ACPSessionConfiguration.Mode = resumeID.map { .load(existingSessionID: $0) } ?? .new
            XCTAssertEqual(host.initialSessionConfiguration()?.mode, expectedMode)
            XCTAssertEqual(host.initialSessionConfiguration()?.workingDirectory, workspace.path)
            do {
                _ = try await controller.bootstrap()
                XCTFail("Discovery and cold resume must fail closed without an explicit fixture permit")
            } catch {
                XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
            }
            let identity = await controller.currentProviderSessionIdentity()
            XCTAssertNil(identity.runtimeSessionID)
            XCTAssertEqual(identity.loadSessionID, resumeID)
            await controller.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "Refusal must precede ACP initialization")
        }
    }

    func testAntigravityVerifiesCompoundSelectionAndMapsTheAdvertisedEditMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravitySelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agy-acp-fixture")
        try #"""
        #!/usr/bin/python3
        import json, sys
        base, level, mode = "gemini-pro", "high", "default"
        def selector(key, current, allowed):
            return {"id": key, "category": key, "type": "select", "currentValue": current,
                    "options": [{"value": value, "name": value} for value in allowed]}
        def configuration():
            return {"configOptions": [
                selector("model", base, ["gemini-pro", "gemini-flash"]),
                selector("thought_level", level, ["low", "high", "xhigh"]),
                selector("mode", mode, ["default", "accept-edits", "auto", "plan"])]}
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if "id" not in request: continue
            if method == "session/new":
                result = {"sessionId": "antigravity-fixture", **configuration(),
                          "models": {"availableModels": [
                              {"modelId": "gemini-pro-high", "name": "Pro (High)"},
                              {"modelId": "gemini-flash-low", "name": "Flash (Low)"},
                              {"modelId": "gemini-flash-xhigh", "name": "Flash (XHigh)"}]}}
            elif method == "session/set_config_option":
                params = request["params"]
                if params["configId"] == "model":
                    base, level = "gemini-flash", "low"
                elif params["configId"] == "mode":
                    assert params["value"] == "accept-edits"
                    mode = params["value"]
                result = configuration()
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = AntigravityACPAgentProvider(
            executablePath: script.path,
            harnessPath: nil,
            installedRuntime: { nil },
            prepareSessionHome: { directory },
            toolNames: ACPToolNameResolution(
                isRepoPromptServerIdentifier: { _ in false },
                canonicalRepoPromptToolName: { _ in nil },
                isRepoPromptToolNameWithServerPrefix: { _ in false }
            ),
            includeRepoPromptMCPServer: false
        )
        let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, host: RecordingHost(), allowsProviderProcessLaunchForTesting: true)
        do {
            _ = try await controller.bootstrap()
            let initial = await controller.currentDiscoveredSessionModels()
            XCTAssertEqual(initial?.currentModelRaw, "gemini-pro-high")
            XCTAssertEqual(initial?.options.map(\.rawValue), ["gemini-pro-high", "gemini-flash-low", "gemini-flash-xhigh"])
            try await controller.setSessionModel("gemini-flash-low")
            try await controller.setSessionMode("auto_edit")
            let selected = await controller.currentDiscoveredSessionModels()
            XCTAssertEqual(selected?.currentModelRaw, "gemini-flash-low")

            do {
                try await controller.setSessionModel("gemini-flash-xhigh")
                XCTFail("The base model alone must not confirm a reasoning-variant selection.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("did not confirm"), error.localizedDescription)
            }
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    func testAntigravityBootstrapKeepsRawFramesOutOfTimeoutDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityStderr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("agy-acp-fixture")
        let warning = "W0906 123 local_connection.py:42] Retrying connection"
        let marker = "raw-websocket-fixture-payload"
        try #"""
        #!/bin/sh
        printf '%s\n' '\#(warning)' 'I0906 123 local_connection.py:42] RAW WS MSG: {"content":"\#(marker)"}' >&2
        while IFS= read -r line; do :; done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = AntigravityACPAgentProvider(
            executablePath: script.path,
            harnessPath: nil,
            installedRuntime: { nil },
            prepareSessionHome: { directory },
            toolNames: ACPToolNameResolution(
                isRepoPromptServerIdentifier: { _ in false },
                canonicalRepoPromptToolName: { _ in nil },
                isRepoPromptToolNameWithServerPrefix: { _ in false }
            ),
            includeRepoPromptMCPServer: false
        )
        let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            host: RecordingHost(),
            diagnosticSink: { event in
                if case let .stderrLine(line) = event {
                    XCTAssertFalse(line.contains(marker))
                }
            },
            requestTimeouts: .init(bootstrapSeconds: 2),
            allowsProviderProcessLaunchForTesting: true
        )
        do {
            _ = try await controller.bootstrap()
            XCTFail("The fixture never responds to initialize.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(warning), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(marker))
        }
        await controller.shutdown()
    }

    func testAntigravityUnexpectedExitSurfacesLastStderrDiagnosticWithoutTranscriptSystemEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityExitStderr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let startupInfo = "I1121 13:38:11.713540 8556827392 main.py:80] Starting AGY ACP Server..."
        let fatalError = "E1121 13:38:11.900000 8556827392 main.py:99] OAuth token refresh failed: invalid_grant"
        let rawMarker = "raw-websocket-exit-payload"
        let unterminatedError = "fatal: missing credentials without trailing newline"

        let cases: [(name: String, scriptBody: String, exitCode: Int32, expectedStderr: String)] = [
            (
                name: "discarded-frame-after-error",
                scriptBody: #"""
                #!/bin/sh
                printf '%s\n' '\#(startupInfo)' '\#(fatalError)' 'I1121 13:38:11.901000 8556827392 local_connection.py:42] RAW WS MSG: {"content":"\#(rawMarker)"}' >&2
                exit 7
                """#,
                exitCode: 7,
                expectedStderr: fatalError
            ),
            (
                name: "unterminated-stderr-flushed-on-exit",
                scriptBody: #"""
                #!/bin/sh
                printf '%s\n' '\#(startupInfo)' >&2
                printf '%s' '\#(unterminatedError)' >&2
                exit 9
                """#,
                exitCode: 9,
                expectedStderr: unterminatedError
            )
        ]

        for testCase in cases {
            let script = directory.appendingPathComponent("agy-exit-\(testCase.name)")
            try testCase.scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            let provider = AntigravityACPAgentProvider(
                executablePath: script.path,
                harnessPath: nil,
                installedRuntime: { nil },
                prepareSessionHome: { directory },
                toolNames: ACPToolNameResolution(
                    isRepoPromptServerIdentifier: { _ in false },
                    canonicalRepoPromptToolName: { _ in nil },
                    isRepoPromptToolNameWithServerPrefix: { _ in false }
                ),
                includeRepoPromptMCPServer: false
            )
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            final class StderrRecorder: @unchecked Sendable {
                private let lock = NSLock()
                private var storage: [String] = []
                var lines: [String] {
                    lock.withLock { storage }
                }

                func append(_ line: String) {
                    lock.withLock { storage.append(line) }
                }
            }
            let recordedDiagnostics = StderrRecorder()
            let controller = try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                host: RecordingHost(),
                diagnosticSink: { event in
                    if case let .stderrLine(line) = event {
                        XCTAssertFalse(line.contains(rawMarker))
                        recordedDiagnostics.append(line)
                    }
                },
                requestTimeouts: .init(bootstrapSeconds: 5),
                allowsProviderProcessLaunchForTesting: true
            )

            let events = await controller.events
            let collected = Task { () -> [AIStreamResult] in
                var results: [AIStreamResult] = []
                for await event in events {
                    if case let .stream(result) = event {
                        results.append(result)
                    }
                }
                return results
            }

            do {
                _ = try await controller.bootstrap()
                XCTFail("Expected unexpected exit for \(testCase.name)")
            } catch {
                let description = error.localizedDescription
                XCTAssertTrue(description.contains("code \(testCase.exitCode)"), description)
                XCTAssertTrue(description.contains(testCase.expectedStderr), description)
                XCTAssertFalse(description.contains(rawMarker), description)
            }

            await controller.shutdown()
            let results = await collected.value
            XCTAssertFalse(results.contains { $0.type == "system" }, "Unexpected system events for \(testCase.name): \(results)")
            XCTAssertTrue(
                results.contains {
                    $0.type == "error"
                        && ($0.text?.contains("code \(testCase.exitCode)") == true)
                        && ($0.text?.contains(testCase.expectedStderr) == true)
                        && ($0.text?.contains(rawMarker) == false)
                },
                "Expected error event with stderr preview for \(testCase.name), got: \(results)"
            )
            XCTAssertTrue(recordedDiagnostics.lines.contains(startupInfo))
            XCTAssertTrue(recordedDiagnostics.lines.contains(testCase.expectedStderr))
        }
    }

    func testRequiredHostRoutesLaunchAndReadsRegistryAtSelectionTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPHost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py")
        let observations = directory.appendingPathComponent("observations")
        try #"""
        import json, os, sys
        with open(os.environ['OBS_FILE'], 'w') as output:
            output.write(os.environ.get('FIXTURE_ROUTE', 'missing'))
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if 'id' not in request: continue
            if method == 'initialize':
                result = {'agentCapabilities': {}}
            elif method == 'session/new':
                result = {'sessionId': 'session-one'}
            elif method == 'session/set_model':
                result = {'_meta': {'model': {'Ok': request['params']['modelId']}}}
            else:
                result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let clearing = expectation(description: "original shutdown entered host cleanup")
        let joined = expectation(description: "second shutdown joined original producer")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let host = RecordingHost(beforeClear: {
            clearing.fulfill()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        host.setSnapshot("old")
        let provider = FixtureProvider(providerID: .grokBuild, script: script.path, observations: observations.path)
        let request = ACPRunRequest(agentKind: .grokBuild, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(
            provider: provider, runRequest: request, host: host,
            diagnosticSink: { event in
                if case .info("Joining ACP controller shutdown") = event { joined.fulfill() }
            },
            allowsProviderProcessLaunchForTesting: true
        )
        XCTAssertEqual(host.events(), ["configuration", "preflight-init"])
        do {
            _ = try await controller.bootstrap()
            XCTAssertEqual(try String(contentsOf: observations, encoding: .utf8), "carrier")
            XCTAssertEqual(Array(host.events().prefix(6)), ["configuration", "preflight-init", "filter", "carrier", "preflight-launch", "register"])
            do {
                try await controller.setSessionModel("new")
                XCTFail("A model absent from the current registry must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("not in the discovered model set"))
            }
            host.setSnapshot("new")
            try await controller.setSessionModel("new")
            XCTAssertGreaterThanOrEqual(host.events().count(where: { $0 == "registry" }), 2)
            let original = Task { await controller.shutdown() }
            await fulfillment(of: [clearing], timeout: 10)
            let repeated = Task { await controller.shutdown() }
            repeated.cancel()
            await fulfillment(of: [joined], timeout: 10)
            XCTAssertFalse(host.events().contains("clear"), "The original host cleanup is still suspended")
            release.continuation.yield(())
            await repeated.value
            XCTAssertTrue(host.events().contains("clear"), "A cancelled waiter must still join actual shutdown completion")
            await original.value
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 1)
        } catch {
            release.continuation.finish()
            await controller.shutdown()
            throw error
        }
    }

    /// #1699: Devin's retryable `EmptyResponse` fails only the turn. The live process and session
    /// stay open, nothing is cancelled or resent, and the next explicit prompt runs in that session.
    /// A steer already waiting on the turn when the error lands is refused, as after any failed turn.
    func testDevinEmptyResponseFailsTheTurnButKeepsTheSessionForTheNextPrompt() async throws {
        for (retryable, steers) in [(true, false), (false, false), (true, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPEmptyResponse-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("server.py")
            let observations = directory.appendingPathComponent("requests.jsonl")
            try #"""
            import json, os, sys
            prompts = 0
            held = None
            for line in sys.stdin:
                request = json.loads(line)
                with open(os.environ['OBS_FILE'], 'a') as output:
                    output.write(json.dumps(request) + '\n')
                if request.get('method') == 'session/cancel' and held is not None:
                    error = json.loads(os.environ['FIXTURE_PROMPT_ERROR'])
                    print(json.dumps({'jsonrpc': '2.0', 'id': held, 'error': error}), flush=True)
                    held = None
                    continue
                if 'id' not in request: continue
                method = request.get('method')
                reply = {'jsonrpc': '2.0', 'id': request['id'], 'result': {}}
                if method == 'initialize':
                    reply['result'] = {'agentCapabilities': {}}
                elif method == 'session/new':
                    reply['result'] = {'sessionId': 'devin-session'}
                elif method == 'session/prompt':
                    prompts += 1
                    if prompts == 1 and \#(steers ? "True" : "False"):
                        held = request['id']
                        continue
                    if prompts == 1:
                        del reply['result']
                        reply['error'] = json.loads(os.environ['FIXTURE_PROMPT_ERROR'])
                    else:
                        reply['result'] = {'stopReason': 'end_turn'}
                print(json.dumps(reply), flush=True)
            """#.write(to: script, atomically: true, encoding: .utf8)
            let promptError: [String: Any] = [
                "code": -32021,
                "message": "The model ended its turn without a response. Send a message to continue.",
                "data": ["cognition.ai/errorKind": "empty_response", "cognition.ai/retryable": retryable]
            ]
            var provider = FixtureProvider(providerID: .grokBuild, script: script.path, observations: observations.path)
            provider.promptError = try String(decoding: JSONSerialization.data(withJSONObject: promptError), as: UTF8.self)
            provider.promptErrorClassifier = makeDevinProvider()
            let host = RecordingHost(allowsDiagnostics: true)
            let request = ACPRunRequest(agentKind: .grokBuild, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, host: host, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            _ = try await controller.bootstrap()
            let message = AgentMessage(systemPrompt: "", userMessage: "Run the tools", resumeSessionID: nil)

            let firstEvents = await controller.events
            let firstPrompt = Task { try await controller.prompt(message) }
            if steers {
                var sent = false
                for _ in 0 ..< 100 where !sent {
                    sent = try recordedMethods(at: observations).contains("session/prompt")
                    if !sent { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                do {
                    try await controller.interruptActivePromptForSteering()
                    XCTFail("A steer waiting on the turn when the provider ends it must be refused")
                } catch {}
            }
            do {
                try await firstPrompt.value
                XCTFail("The provider error must fail the turn")
            } catch {
                XCTAssertEqual(error is ACPSessionPreservingPromptFailure, retryable, "\(error)")
            }
            let firstTerminal = await terminalEvent(in: firstEvents)
            XCTAssertEqual(firstTerminal?.state, .failed)
            let reusable = await controller.hasReusableSession
            let retained = await controller.retainsSessionAfterLastPromptFailure
            XCTAssertEqual(reusable, retryable)
            XCTAssertEqual(retained, retryable)
            let methods = try recordedMethods(at: observations)
            XCTAssertEqual(methods.count(where: { $0 == "session/prompt" }), 1, "The failed turn must never be resent")

            guard retryable else {
                XCTAssertTrue(try XCTUnwrap(firstTerminal?.errorText).contains("cognition.ai"), "Unclassified errors keep today's detail")
                let retired = await controller.isRetired
                XCTAssertTrue(retired)
                var cancelled = false
                for _ in 0 ..< 100 where !cancelled {
                    cancelled = try recordedMethods(at: observations).contains("session/cancel")
                    if !cancelled { try await Task.sleep(nanoseconds: 50_000_000) }
                }
                XCTAssertTrue(cancelled, "An ordinary prompt failure still cancels the provider turn")
                continue
            }
            XCTAssertEqual(firstTerminal?.errorText, DevinACPAgentProvider.emptyResponseUserMessage)
            do {
                try await controller.interruptActivePromptForSteering()
                XCTFail("Steering into the failed turn's run must be refused, as after any failed turn")
            } catch {}
            let prepared = await controller.prepareForNextTurn()
            XCTAssertTrue(prepared)
            let secondEvents = await controller.events
            try await controller.prompt(message)
            let secondTerminal = await terminalEvent(in: secondEvents)
            XCTAssertEqual(secondTerminal?.state, .completed)
            let retainedAfterSuccess = await controller.retainsSessionAfterLastPromptFailure
            XCTAssertFalse(retainedAfterSuccess)
            let allMethods = try recordedMethods(at: observations)
            XCTAssertEqual(allMethods.count(where: { $0 == "initialize" }), 1, "The next prompt must reuse the live process")
            XCTAssertEqual(allMethods.count(where: { $0 == "session/new" }), 1)
            XCTAssertEqual(allMethods.count(where: { $0 == "session/prompt" }), 2)
            XCTAssertFalse(allMethods.contains("session/load"))
            XCTAssertEqual(allMethods.count(where: { $0 == "session/cancel" }), steers ? 1 : 0, "Only the steer cancels")
            XCTAssertEqual(host.events().count(where: { $0 == "register" }), 1)
        }
    }

    func testDevinStderrStaysOutOfTheTranscriptButReachesDiagnostics() async throws {
        let warning = "2026-10-01T16:04:15.144229Z  WARN run_acp_server: [MCP] environment variable 'MISSING' is not set"
        let directory = try makeStderrFixtureDirectory()
        let diagnostics = StderrDiagnosticRecorder()
        let controller = try makeDevinStderrController(
            directory: directory,
            sessionNew: ["print(\(Self.pythonLiteral(warning)), file=sys.stderr, flush=True)"],
            diagnostics: diagnostics
        )
        let collected = await collectStreamResults(from: controller)

        _ = try await controller.bootstrap()
        try await controller.prompt(AgentMessage(systemPrompt: "", userMessage: "hi", resumeSessionID: nil), request: makeDevinStderrRequest(directory))
        for _ in 0 ..< 500 where !diagnostics.lines.contains(warning) {
            try await Task.sleep(for: .milliseconds(10))
        }
        await controller.shutdown()
        let results = await collected.value

        XCTAssertEqual(diagnostics.lines, [warning])
        XCTAssertFalse(results.contains { $0.type == "system" }, "Process stderr must never become transcript content")
        XCTAssertFalse(results.compactMap(\.text).joined().contains(warning))
    }

    func testDevinProcessFailureKeepsTheFinalUnterminatedStderrLine() async throws {
        let directory = try makeStderrFixtureDirectory()
        let controller = try makeDevinStderrController(
            directory: directory,
            sessionNew: ["sys.stderr.write('permission denied while reading test config')", "sys.stderr.flush()", "os._exit(7)"]
        )
        let collected = await collectStreamResults(from: controller)

        do {
            _ = try await controller.bootstrap()
            XCTFail("session/new never completes; the process exited")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission denied while reading test config"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 7"), error.localizedDescription)
        }
        await controller.shutdown()
        let results = await collected.value
        XCTAssertFalse(results.contains { $0.type == "system" })
    }

    func testDevinProcessFailureDoesNotWaitForADescendantHoldingStderrOpen() async throws {
        let directory = try makeStderrFixtureDirectory()
        let controller = try makeDevinStderrController(
            directory: directory,
            sessionNew: [
                "if os.fork() == 0:",
                "    time.sleep(8)",
                "    os._exit(0)",
                "os.write(sys.stderr.fileno(), b'permission denied while reading test config')",
                "os._exit(7)"
            ]
        )
        let collected = await collectStreamResults(from: controller)
        let started = ContinuousClock.now

        do {
            _ = try await controller.bootstrap()
            XCTFail("session/new never completes; the process exited")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission denied while reading test config"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 7"), error.localizedDescription)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6), "Failure must not wait for the descendant's stderr EOF")
        await controller.shutdown()
        _ = await collected.value
    }

    private func makeStderrFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPDevinStderr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeDevinStderrRequest(_ directory: URL) -> ACPRunRequest {
        ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
    }

    private func makeDevinStderrController(
        directory: URL,
        sessionNew: [String],
        diagnostics: StderrDiagnosticRecorder? = nil
    ) throws -> ACPAgentSessionController {
        let script = directory.appendingPathComponent("server.py")
        let body = sessionNew.map { "        \($0)" }.joined(separator: "\n")
        try """
        import json, os, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request.get('method')
            reply = {'jsonrpc': '2.0', 'id': request['id'], 'result': {}}
            if method == 'initialize':
                reply['result'] = {'agentCapabilities': {}}
            elif method == 'session/new':
        \(body)
                reply['result'] = {'sessionId': 'devin-session'}
            elif method == 'session/prompt':
                reply['result'] = {'stopReason': 'end_turn'}
            print(json.dumps(reply), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        var provider = FixtureProvider(
            providerID: .devin,
            script: script.path,
            observations: directory.appendingPathComponent("requests.jsonl").path
        )
        provider.stderrDisposition = .diagnosticsOnly
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeDevinStderrRequest(directory),
            host: RecordingHost(allowsDiagnostics: true),
            diagnosticSink: { event in
                if case let .stderrLine(line) = event { diagnostics?.append(line) }
            },
            allowsProviderProcessLaunchForTesting: true
        )
        addTeardownBlock { await controller.shutdown() }
        return controller
    }

    private func collectStreamResults(from controller: ACPAgentSessionController) async -> Task<[AIStreamResult], Never> {
        let events = await controller.events
        return Task {
            var results: [AIStreamResult] = []
            for await event in events {
                if case let .stream(result) = event { results.append(result) }
            }
            return results
        }
    }

    private static func pythonLiteral(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private func terminalEvent(in events: AsyncStream<NormalizedAgentRuntimeEvent>) async -> (state: AgentSessionRunState, errorText: String?)? {
        for await event in events {
            if case let .terminal(state, errorText) = event { return (state, errorText) }
        }
        return nil
    }

    private func makeDevinProvider() -> DevinACPAgentProvider {
        DevinACPAgentProvider(
            config: DevinAgentConfig(additionalPathHints: []),
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(name: "fixture-host", command: "/usr/bin/true"),
            launchResolver: DevinACPLaunchResolver(
                launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: [:]) },
                supplementalPathProvider: { $0 },
                environmentFilter: { value, _ in value },
                failureRecorder: { _, _ in }
            ),
            isolateForeignMCPImports: false,
            toolNames: ACPToolNameResolution(isRepoPromptServerIdentifier: { _ in false }, canonicalRepoPromptToolName: { _ in nil }, isRepoPromptToolNameWithServerPrefix: { _ in false }),
            permissionArguments: { _ in [] },
            prepareIntegration: { _, _, _, _ in throw CancellationError() },
            cleanupIntegration: { _ in }
        )
    }
}

private func recordedMethods(at url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return request?["method"] as? String
    }
}

private struct FixtureProvider: ACPAgentProvider, ACPDirectSessionModelProvider {
    let providerID: ACPProviderID
    let script: String
    let observations: String
    var emitsFixtureText = false
    var responseText: String?
    var promptError: String?
    /// Classifies prompt errors with Devin's shipped rules.
    var promptErrorClassifier: DevinACPAgentProvider?
    /// Overrides the default stderr classification, as Devin does.
    var stderrDisposition: ACPStderrLineDisposition?

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        var environment = ["OBS_FILE": observations]
        if let responseText {
            environment["FIXTURE_RESPONSE"] = responseText
        }
        if let promptError {
            environment["FIXTURE_PROMPT_ERROR"] = promptError
        }
        return ACPLaunchConfiguration(providerID: providerID, command: "/usr/bin/python3", arguments: ["-u", script], environment: environment, workingDirectory: nil, additionalPathHints: [], enableDebugLogging: false)
    }

    func makeSessionConfiguration(for request: ACPRunRequest, mcpServer: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
        XCTAssertEqual(mcpServer.name, "fixture-host")
        let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
    }

    func buildPromptBlocks(for _: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        []
    }

    func normalizeSessionUpdate(_ update: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        guard emitsFixtureText, let text = update["fixtureText"] as? String else { return [] }
        return [.stream(AIStreamResult(type: "content", text: text))]
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }

    func stderrLineDisposition(_ line: String) -> ACPStderrLineDisposition {
        stderrDisposition ?? (shouldEmitStderrLine(line) ? .transcript : .diagnosticsOnly)
    }

    func sessionPreservingPromptFailure(forResponseError error: [String: Any]) -> ACPSessionPreservingPromptFailure? {
        promptErrorClassifier?.sessionPreservingPromptFailure(forResponseError: error)
    }

    func parseDirectSessionModelSnapshot(from _: [String: Any]) -> ACPProviderModelSnapshotResult {
        .absent
    }

    func parseDirectSessionEffortReport(from _: [[String: Any]], sessionID _: String, options _: [AgentModelOption]) -> ACPDirectSessionEffortReport? {
        nil
    }

    func makeDirectModelSelectionRequest(sessionID: String, baseModelRaw: String, reasoningEffortRaw _: String?) -> ACPDirectModelSelectionRequest {
        ACPDirectModelSelectionRequest(method: "session/set_model", params: ["sessionId": sessionID, "modelId": baseModelRaw], expectedConfirmationModelRaw: baseModelRaw)
    }
}

private final class RecordingHost: ACPAgentSessionHost, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var snapshot: ACPDiscoveredSessionModels?
    private var initialConfiguration: ACPSessionConfiguration?
    private let clearedExpectation: XCTestExpectation?
    private let allowsDiagnostics: Bool
    private let beforeClear: (@Sendable () async -> Void)?

    init(clearedExpectation: XCTestExpectation? = nil, allowsDiagnostics: Bool = false, beforeClear: (@Sendable () async -> Void)? = nil) {
        self.clearedExpectation = clearedExpectation
        self.allowsDiagnostics = allowsDiagnostics
        self.beforeClear = beforeClear
    }

    private func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    func events() -> [String] {
        lock.withLock { recorded }
    }

    func initialSessionConfiguration() -> ACPSessionConfiguration? {
        lock.withLock { initialConfiguration }
    }

    func setSnapshot(_ raw: String) {
        let option = AgentModelOption(rawValue: raw, displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        lock.withLock { snapshot = ACPDiscoveredSessionModels(options: [option], currentModelRaw: nil) }
    }

    var applicationVersion: String {
        "fixture"
    }

    var repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration {
        record("configuration")
        return RepoPromptMCPServerConfiguration(name: "fixture-host", command: "/usr/bin/true")
    }

    var cursorAutoModelRaw: String {
        "auto"
    }

    func preflightInjectedMCPServers(in configuration: ACPSessionConfiguration) throws {
        lock.withLock {
            initialConfiguration = configuration
            recorded.append("preflight-init")
        }
    }

    func preflightInjectedMCPServers(in _: ACPSessionConfiguration, environment: [String: String]) throws {
        XCTAssertEqual(environment["FIXTURE_ROUTE"], "carrier")
        record("preflight-launch")
    }

    func mcpClientNameHint(for _: AgentProviderKind) -> String? {
        "fixture-client"
    }

    func displayName(for _: AgentProviderKind) -> String {
        "Fixture"
    }

    func normalizedModelParameterSelections(_ selections: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        selections
    }

    func canonicalParameterModelRaw(_ raw: String, providerID _: ACPProviderID) -> String {
        raw
    }

    func parameterIdentityMatches(_: ACPModelParameterSelection, providerID _: ACPProviderID, baseModelRaw _: String, kind _: ACPModelParameterKind) -> Bool {
        XCTFail("Unexpected identity lookup")
        return false
    }

    func recognizedDevinPermissionMode(_: String?) -> Bool {
        XCTFail("Unexpected Devin policy")
        return false
    }

    func normalizedDevinPermissionMode(_ mode: String?) -> String? {
        mode
    }

    func devinThinkingSelection(for _: String) -> ACPDevinThinkingSelection? {
        XCTFail("Unexpected Devin lookup")
        return nil
    }

    func grokDecomposition(raw: String, options: [AgentModelOption]) -> ACPGrokModelDecomposition? {
        options.first(where: { $0.rawValue == raw }).map { ACPGrokModelDecomposition(base: $0, explicitEffort: nil) }
    }

    func grokCompoundRaw(base: String, effort _: CodexReasoningEffort?) -> String {
        base
    }

    func resolvedModelSnapshot(for _: ACPProviderID) -> ACPDiscoveredSessionModels? {
        record("registry")
        return lock.withLock { snapshot }
    }

    func publishDiscoveredModels(_: ACPDiscoveredSessionModels, for _: ACPProviderID) {
        record("publish")
    }

    func filterEnvironment(_ environment: [String: String], launchConfiguration _: ACPLaunchConfiguration, kind _: AgentProviderKind) async -> [String: String] {
        record("filter")
        var result = environment
        result["FIXTURE_ROUTE"] = "filtered"
        return result
    }

    func mergingCurrentCarrier(into environment: [String: String]) -> [String: String] {
        record("carrier")
        var result = environment
        result["FIXTURE_ROUTE"] = "carrier"
        return result
    }

    func registerExpectedAgentPID(_: pid_t, clientName: String, runID _: UUID?) async {
        XCTAssertEqual(clientName, "fixture-client")
        record("register")
    }

    func clearExpectedAgentPID(_: pid_t, clientName: String, runID _: UUID?) async {
        XCTAssertEqual(clientName, "fixture-client")
        await beforeClear?()
        record("clear")
        clearedExpectation?.fulfill()
    }

    func permissionIsAutoSelectable(optionID _: String?, providerID _: ACPProviderID) -> Bool {
        XCTFail("Unexpected permission policy")
        return false
    }

    func permissionOneTimeAllow(options _: [(optionID: String, kind: String)], providerID _: ACPProviderID) -> String? {
        XCTFail("Unexpected permission policy")
        return nil
    }

    func permissionOneTimeReject(options _: [(optionID: String, kind: String)]) -> String? {
        XCTFail("Unexpected permission policy")
        return nil
    }

    #if DEBUG
        func diagnosticErrorKind(_: Error) -> String {
            "fixture"
        }

        func recordRunRoutingEvent(runID _: UUID, event: String, fields _: [String: String]) async {
            if allowsDiagnostics {
                record("routing:\(event)")
            } else {
                XCTFail("Unexpected diagnostics")
            }
        }
    #endif
}

final class ACPCLIProviderExecutionTests: XCTestCase {
    func testInjectedConfigurationIsResolvedPerRequestAndTerminalStreamsReleaseEachProcess() async throws {
        for consumer in Consumer.allCases {
            let fixture = try makeFixture(consumer: consumer, holdPrompt: false)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cleared = expectation(description: "\(consumer) terminal processes released")
            cleared.expectedFulfillmentCount = 2
            let host = RecordingHost(clearedExpectation: cleared, allowsDiagnostics: true)
            var configuredModels: [AIModel] = []
            let cli = makeCLI(consumer: consumer, fixture: fixture.provider, host: host) { model in
                configuredModels.append(model)
                return model == consumer.model("second") ? "second" : "first"
            }
            XCTAssertTrue(configuredModels.isEmpty, "Construction must not eagerly snapshot request policy")
            for name in ["first", "second"] {
                let result = try await cli.completeMessage(AIMessage(systemPrompt: "", userMessage: "Execute"), model: consumer.model(name), maxTokens: nil)
                XCTAssertEqual(result.text, name, "Injected config must reach the actual provider process for this request")
            }
            await fulfillment(of: [cleared], timeout: 10)
            await cli.dispose()
            await cli.dispose()
            XCTAssertEqual(configuredModels, [consumer.model("first"), consumer.model("second")])
            XCTAssertEqual(host.events().count(where: { $0 == "register" }), 2)
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 2)
            let methods = try recordedMethods(at: fixture.observations)
            XCTAssertEqual(methods.count(where: { $0 == "session/new" }), 2)
            XCTAssertEqual(methods.count(where: { $0 == "session/prompt" }), 2)
            XCTAssertFalse(methods.contains("session/load"), "CLI requests must not resume an earlier conversation")
        }
    }

    func testCancellingCLIConsumptionDisposesTheExistingHeadlessController() async throws {
        for consumer in Consumer.allCases {
            let fixture = try makeFixture(consumer: consumer, holdPrompt: true)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cleared = expectation(description: "\(consumer) cancelled process released")
            let content = expectation(description: "\(consumer) partial content received")
            let host = RecordingHost(clearedExpectation: cleared, allowsDiagnostics: true)
            let cli = makeCLI(consumer: consumer, fixture: fixture.provider, host: host) { _ in "partial" }
            let stream = try await cli.streamMessage(AIMessage(systemPrompt: "", userMessage: "Wait for cancellation"), model: consumer.model("partial"), maxTokens: nil)
            let execution = Task {
                do {
                    for try await result in stream {
                        if result.type == "content", result.text == "partial" {
                            content.fulfill()
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        XCTFail("Unexpected stream failure: \(error)")
                    }
                }
            }
            await fulfillment(of: [content], timeout: 10)
            execution.cancel()
            _ = await execution.result
            await fulfillment(of: [cleared], timeout: 10)
            await cli.dispose()
            await cli.dispose()
            XCTAssertEqual(host.events().count(where: { $0 == "register" }), 1)
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 1)
        }
    }

    func testOpenCodeStaleTerminationCannotRemoveTheReplacementProvider() {
        final class Provider {}
        let first = Provider()
        let second = Provider()
        let third = Provider()
        let store = ActiveOpenCodeCLIProviderStore<Provider>()
        XCTAssertNil(store.replace(first))
        XCTAssertTrue(store.replace(second) === first)
        XCTAssertTrue(store.remove(first))
        XCTAssertTrue(store.contains(second))
        XCTAssertTrue(store.replace(third) === second)
        XCTAssertTrue(store.remove(second))
        XCTAssertTrue(store.contains(third))
        let remaining = store.removeAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.first === third)
        XCTAssertFalse(store.contains(third))
        XCTAssertNil(store.replace(first), "Draining must retire the current-provider identity too")
    }

    private enum Consumer: CaseIterable {
        case cursor
        case openCode

        var providerID: ACPProviderID {
            switch self {
            case .cursor: .cursor
            case .openCode: .openCode
            }
        }

        var sessionMode: String {
            switch self {
            case .cursor: CursorAgentConfig.promptOnlySessionModeID
            case .openCode: OpenCodeAgentConfig.managedNoToolsSessionModeID
            }
        }

        func model(_ name: String) -> AIModel {
            switch self {
            case .cursor: .cursorCustom(name: name)
            case .openCode: .openCodeCustom(name: name)
            }
        }
    }

    private func makeCLI(
        consumer: Consumer,
        fixture: FixtureProvider,
        host: RecordingHost,
        resolveConfiguration: @escaping (AIModel) -> String
    ) -> any AIProvider {
        switch consumer {
        case .cursor:
            CursorCLIProvider(
                configurationFactory: { model in
                    let name = resolveConfiguration(model)
                    return CursorAgentConfig(enableDebugLogging: name == "second", modelString: name, includeRepoPromptMCPServer: false, sessionModeID: CursorAgentConfig.promptOnlySessionModeID)
                },
                headlessProviderFactory: { config, workspacePath in
                    XCTAssertNil(workspacePath)
                    var configured = fixture
                    configured.responseText = config.modelString
                    let provider = configured
                    return CursorACPHeadlessAgentProvider(
                        config: config, workspacePath: workspacePath, baseModel: nil,
                        providerFactory: { _ in provider },
                        controllerFactory: { provider, request, diagnosticSink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, host: host, diagnosticSink: diagnosticSink, allowsProviderProcessLaunchForTesting: true)
                        },
                        applySelectedModel: { _, _ in }
                    )
                }
            )
        case .openCode:
            OpenCodeCLIProvider(
                configurationFactory: { model in
                    let name = resolveConfiguration(model)
                    return OpenCodeAgentConfig(modelString: name, enableDebugLogging: name == "second", includeRepoPromptMCPServer: false, toolProfile: .noTools)
                },
                headlessProviderFactory: { config, workspacePath in
                    XCTAssertNil(workspacePath)
                    var configured = fixture
                    configured.responseText = config.modelString
                    let provider = configured
                    return OpenCodeACPHeadlessAgentProvider(
                        config: config, workspacePath: workspacePath,
                        providerFactory: { _ in provider },
                        controllerFactory: { provider, request, diagnosticSink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, host: host, diagnosticSink: diagnosticSink, allowsProviderProcessLaunchForTesting: true)
                        },
                        selectedModel: { _ in nil }
                    )
                }
            )
        }
    }

    private func makeFixture(consumer: Consumer, holdPrompt: Bool) throws -> (directory: URL, observations: URL, provider: FixtureProvider) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let observations = directory.appendingPathComponent(holdPrompt ? "hold.jsonl" : "terminal.jsonl")
        let script = directory.appendingPathComponent("server.py")
        try #"""
        import json, os, sys
        for line in sys.stdin:
            request = json.loads(line)
            with open(os.environ['OBS_FILE'], 'a') as output:
                output.write(json.dumps(request) + '\n')
            if 'id' not in request: continue
            method = request.get('method')
            if method == 'initialize':
                result = {'agentCapabilities': {}}
            elif method == 'session/new':
                result = {'sessionId': 'fixture-session', 'configOptions': [{'id': 'mode', 'name': 'Mode', 'category': 'mode', 'type': 'select', 'currentValue': '\#(consumer.sessionMode)', 'options': [{'value': '\#(consumer.sessionMode)', 'name': 'Fixture'}]}]}
            elif method == 'session/prompt':
                print(json.dumps({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': 'fixture-session', 'update': {'sessionUpdate': 'agent_message_chunk', 'fixtureText': os.environ['FIXTURE_RESPONSE']}}}), flush=True)
                if os.environ['OBS_FILE'].endswith('hold.jsonl'): continue
                result = {'stopReason': 'end_turn'}
            else:
                result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        return (directory, observations, FixtureProvider(providerID: consumer.providerID, script: script.path, observations: observations.path, emitsFixtureText: true))
    }
}

private final class StderrDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var lines: [String] {
        lock.withLock { recorded }
    }

    func append(_ line: String) {
        lock.withLock { recorded.append(line) }
    }
}
