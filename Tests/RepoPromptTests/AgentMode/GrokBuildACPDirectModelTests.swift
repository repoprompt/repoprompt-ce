import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Direct-model (SessionModelState) path coverage for the Grok Build ACP provider:
/// session-open ingestion into the registry, `session/set_model` dispatch, validation,
/// and modern-configOptions precedence. Uses a self-contained fake ACP server.
final class GrokBuildACPDirectModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testSessionModelStatePopulatesRegistryWhenConfigOptionsAbsent() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        // The registry canonicalizes ordering; membership is the contract.
        XCTAssertEqual(Set(snapshot?.options.map(\.rawValue) ?? []), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(snapshot?.currentModelRaw, "grok-4.6")
    }

    func testDirectSetModelSendsExactProviderRequest() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.5")

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.params["sessionId"] as? String, "grok-direct-session")
        XCTAssertEqual(mutations.first?.params["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.5"
        )
    }

    func testDirectSetModelSkipsWhenSessionAlreadyCurrent() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.6")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testDefaultNeverSendsSetModel() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("default")
        try await fixture.controller.setSessionModel(" Default ")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testUnknownDirectModelIsRejectedBeforeRPC() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-9.9")
            XCTFail("expected unknown model to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("grok-9.9"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testErrModelOutcomeThrowsAndPreservesCurrentModel() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "err")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected Err outcome to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rejected"), "unexpected error: \(error)")
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6",
            "a rejected selection must not move local model authority"
        )
    }

    func testMissingModelAckFailsClosed() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "missing")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected missing acknowledgement to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6"
        )
    }

    func testMalformedModelAckFailsClosed() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "malformed")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected malformed acknowledgement to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6"
        )
    }

    func testMismatchedOkFailsClosed() async throws {
        // The server confirms a DIFFERENT model than requested: local state must not move.
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "mismatch")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected mismatched Ok to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6",
            "an Ok naming another model must not be treated as confirmation"
        )
    }

    func testMalformedSessionModelStateDoesNotPersistAndSelectionFails() async throws {
        let fixture = try makeFixture(shape: "grok_direct_malformed")
        try await bootstrap(fixture.controller)

        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild))
        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected malformed metadata to fail selection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("malformed"), "unexpected error: \(error)")
        }
    }

    func testModernConfigOptionsTakePrecedenceOverSessionModelState() async throws {
        // A session advertising BOTH a modern selector and legacy `models` must use the
        // modern path: no direct RPC, configOptions remain authoritative.
        let fixture = try makeFixture(shape: "grok_dual")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("model-b")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
        let configMutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
        XCTAssertEqual(configMutations.count, 1)
        XCTAssertEqual(configMutations.first?.params["value"] as? String, "model-b")
    }

    func testDiscoveryClientRetainsVerifiedSessionPerWorkspace() async throws {
        // Polling must not mint a fresh persistent Grok session every 300s: the first
        // discovery opens session/new, later discoveries for the same workspace reuse the
        // verified identity through session/load.
        let workspace = try makeTestDirectory(name: "GrokBuildDiscoveryRetention")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let environment = [
            "ACP_RECORD_PATH": recordURL.path,
            "ACP_SHAPE": "grok_direct",
            "PATH": "/usr/bin:/bin"
        ]
        let client = GrokBuildACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in
                GrokDirectFakeACPProvider(commandPath: scriptURL.path, environment: environment)
            },
            controllerFactory: { provider, runRequest in
                try ACPAgentSessionController(provider: provider, runRequest: runRequest)
            }
        )

        _ = try await client.discoverModels(workspacePath: workspace.path)
        _ = try await client.discoverModels(workspacePath: workspace.path)

        let newCalls = recordedRequests(at: recordURL, method: "session/new")
        let loadCalls = recordedRequests(at: recordURL, method: "session/load")
        XCTAssertEqual(newCalls.count, 1)
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls.first?.params["sessionId"] as? String, "grok-direct-session")
    }

    func testStderrNoiseIsFilteredThroughProviderOverride() async throws {
        // Regression: `shouldEmitStderrLine` must be a protocol requirement so the
        // controller's existential call dispatches to the Grok override. The fake server
        // emits both suppressed noise and a regular stderr line.
        let workspace = try makeTestDirectory(name: "GrokBuildStderrFilter")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let provider = GrokDirectFakeACPProvider(
            commandPath: scriptURL.path,
            environment: [
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_SHAPE": "grok_direct",
                "PATH": "/usr/bin:/bin"
            ]
        )
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        let events = await controller.currentEventsStream()
        var systemTexts: [String] = []
        let collector = Task {
            for await event in events {
                if case let .stream(result) = event, result.type == "system", let text = result.text {
                    systemTexts.append(text)
                }
            }
        }
        _ = try await controller.bootstrap()
        try await Task.sleep(nanoseconds: 300_000_000)
        await controller.shutdown()
        _ = await collector.value

        XCTAssertFalse(
            systemTexts.contains { $0.contains("worker quit with fatal: Transport channel closed") },
            "suppressed worker-transport noise must not surface: \(systemTexts)"
        )
        XCTAssertTrue(
            systemTexts.contains { $0.contains("ordinary grok stderr line") },
            "regular stderr lines must still surface: \(systemTexts)"
        )
    }

    // MARK: - Harness

    private struct Fixture {
        let controller: ACPAgentSessionController
        let recordURL: URL
    }

    private struct RecordedRequest {
        let method: String
        let params: [String: Any]
    }

    private func recordedRequests(at url: URL, method: String) -> [RecordedRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let requestMethod = object["method"] as? String,
                  requestMethod == method
            else { return nil }
            return RecordedRequest(
                method: requestMethod,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    private func bootstrap(_ controller: ACPAgentSessionController) async throws {
        do {
            _ = try await controller.bootstrap()
        } catch {
            await controller.shutdown()
            throw error
        }
        addTeardownBlock {
            await controller.shutdown()
        }
    }

    private func makeFixture(shape: String, setModelAck: String = "ok") throws -> Fixture {
        let workspace = try makeTestDirectory(name: "GrokBuildACPDirectModelTests")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let environment = [
            "ACP_RECORD_PATH": recordURL.path,
            "ACP_SHAPE": shape,
            "ACP_SET_MODEL_ACK": setModelAck,
            "PATH": "/usr/bin:/bin"
        ]
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let provider = GrokDirectFakeACPProvider(
            commandPath: scriptURL.path,
            environment: environment
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        return Fixture(controller: controller, recordURL: recordURL)
    }

    private func makeFakeGrokACPServerScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake_grok_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        shape = os.environ.get("ACP_SHAPE", "grok_direct")
        set_model_ack = os.environ.get("ACP_SET_MODEL_ACK", "ok")
        session_id = "grok-direct-session"
        current_model = "grok-4.6"
        modern_current_model = "model-a"

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def send(payload):
            print(json.dumps(payload), flush=True)

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result if result is not None else {}
            send(payload)

        def grok_models():
            return {
                "currentModelId": current_model,
                "availableModels": [
                    {"modelId": "grok-4.6", "name": "Grok 4.6", "description": "Frontier",
                     "_meta": {"totalContextTokens": 500000}},
                    {"modelId": "grok-4.5", "name": "Grok 4.5"}
                ]
            }

        def modern_model_selector(value=None):
            return {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": value if value is not None else modern_current_model,
                "options": [
                    {"value": "model-a", "name": "Model A"},
                    {"value": "model-b", "name": "Model B"}
                ]
            }

        def session_result():
            if shape == "grok_direct":
                return {"sessionId": session_id, "models": grok_models()}
            if shape == "grok_direct_malformed":
                return {"sessionId": session_id, "models": {"currentModelId": "x", "availableModels": "nope"}}
            if shape == "grok_dual":
                return {
                    "sessionId": session_id,
                    "configOptions": [modern_model_selector()],
                    "models": grok_models()
                }
            return {"sessionId": session_id}

        sys.stderr.write("2026-08-14T00:00:00Z ERROR worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)\n")
        sys.stderr.flush()
        sys.stderr.write("ordinary grok stderr line\n")
        sys.stderr.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            method = message.get("method")
            request_id = message.get("id")
            params = message.get("params") or {}
            if method is None:
                continue
            record(method, params)
            if method == "initialize":
                respond(request_id, {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": True, "promptCapabilities": {"embeddedContext": True}},
                    "authMethods": []
                })
            elif method == "session/new":
                respond(request_id, session_result())
            elif method == "session/load":
                respond(request_id, session_result())
            elif method == "session/set_model":
                requested = params.get("modelId")
                if set_model_ack == "missing":
                    respond(request_id, {})
                elif set_model_ack == "malformed":
                    respond(request_id, {"_meta": {"model": "not-a-model-outcome"}})
                elif set_model_ack == "mismatch":
                    respond(request_id, {"_meta": {"model": {"Ok": "grok-4.6"}}})
                elif set_model_ack == "err":
                    respond(request_id, {"_meta": {"model": {"Err": {"message": "model unavailable"}}}})
                elif requested in ("grok-4.5", "grok-4.6"):
                    current_model = requested
                    respond(request_id, {"_meta": {"model": {"Ok": requested}}})
                else:
                    respond(request_id, error={"code": -32602, "message": "unknown model"})
            elif method == "session/set_config_option":
                if params.get("configId") == "model":
                    modern_current_model = params.get("value")
                respond(request_id, {"configOptions": [modern_model_selector()]})
            elif method == "session/prompt":
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {"sessionUpdate": "agent_message_chunk",
                                   "content": {"type": "text", "text": "pong"}}
                    }
                })
                respond(request_id, {
                    "stopReason": "end_turn",
                    "_meta": {"usage": {"inputTokens": 10, "outputTokens": 5}}
                })
            elif method == "session/cancel":
                pass
            elif request_id is not None:
                respond(request_id, {})
        """# + "\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

/// Fake provider that speaks the Grok direct-model capability while launching the fake
/// server script directly (no executable discovery).
private struct GrokDirectFakeACPProvider: ACPAgentProvider, ACPDirectSessionModelProvider {
    let commandPath: String
    let environment: [String: String]

    var providerID: ACPProviderID {
        .grokBuild
    }

    private let directDelegate = GrokBuildACPAgentProvider(
        config: GrokBuildAgentConfig(commandName: "/bin/echo", includeRepoPromptMCPServer: false)
    )

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(
            mode: mode,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        GrokBuildACPEventNormalizer.normalize(payload)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        directDelegate.shouldEmitStderrLine(line)
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }

    func parseDirectSessionModelSnapshot(from sessionResponse: [String: Any]) -> ACPProviderModelSnapshotResult {
        directDelegate.parseDirectSessionModelSnapshot(from: sessionResponse)
    }

    func makeDirectModelSelectionRequest(sessionID: String, modelRaw: String) -> ACPDirectModelSelectionRequest {
        directDelegate.makeDirectModelSelectionRequest(sessionID: sessionID, modelRaw: modelRaw)
    }
}
