import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Headless bridge coverage for Grok Build: default-model no-op, validated dynamic model
/// application, unknown-model rejection before prompt, and full-access launch intent.
final class GrokBuildACPHeadlessAgentProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testDefaultModelDoesNotCallSetModel() async throws {
        let harness = try makeHarness()
        let provider = harness.makeHeadlessProvider(modelString: AgentModel.defaultModel.rawValue)
        try await drain(provider, message: "hi")
        XCTAssertTrue(harness.recordedMethods("session/set_model").isEmpty)
    }

    func testKnownDynamicModelIsAppliedBeforePrompt() async throws {
        let harness = try makeHarness()
        seedRegistry(with: ["grok-4.6", "grok-4.5"], current: "grok-4.6")
        let provider = harness.makeHeadlessProvider(modelString: "grok-4.5")
        try await drain(provider, message: "hi")
        let setModelCalls = harness.recordedMethods("session/set_model")
        XCTAssertEqual(setModelCalls.count, 1)
        XCTAssertEqual(setModelCalls.first?["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(harness.recordedMethods("session/prompt").count, 1)
    }

    func testUnknownDynamicModelFailsBeforePrompt() async throws {
        let harness = try makeHarness()
        seedRegistry(with: ["grok-4.6"], current: "grok-4.6")
        let provider = harness.makeHeadlessProvider(modelString: "grok-9.9")
        do {
            try await drain(provider, message: "hi")
            XCTFail("expected unknown model to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("grok-9.9"), "unexpected error: \(error)")
        }
        XCTAssertTrue(harness.recordedMethods("session/prompt").isEmpty)
    }

    /// grok CLI >= 1.0.17 advertises modern `configOptions` alongside the legacy `models`
    /// block, and may later push configOptions-only `config_option_update` snapshots. The
    /// direct provider parser must win and stay in charge so effort variants survive.
    func testConfigOptionsAlongsideModelsKeepsDirectEffortVariants() async throws {
        let harness = try makeHarness(advertiseConfigOptions: true)
        let provider = harness.makeHeadlessProvider(modelString: AgentModel.defaultModel.rawValue)
        try await drain(provider, message: "hi")
        let raws = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.options.map(\.rawValue) ?? []
        XCTAssertTrue(raws.contains("grok-4.6-xhigh"), "expected direct effort variants, got \(raws)")
        XCTAssertTrue(raws.contains("grok-4.6-low"), "expected direct effort variants, got \(raws)")
    }

    func testConfigOptionsOnlyUpdatePreservesLiveDirectEffortSelection() async throws {
        let harness = try makeHarness(advertiseConfigOptions: true)
        let config = GrokBuildAgentConfig(
            commandName: harness.scriptPath,
            additionalPathHints: [],
            modelString: "grok-4.6-low",
            includeRepoPromptMCPServer: false
        )
        let provider = EnvForwardingGrokProvider(
            config: config,
            extraEnvironment: ["ACP_RECORD_PATH": harness.recordURL.path]
        )
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: config.modelString,
            workspacePath: harness.workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)

        do {
            _ = try await controller.bootstrap()
            try await controller.prompt(AgentMessage(userMessage: "hi"), request: request)
            try await controller.setSessionModel("grok-4.6-low")
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }

        let setModelCalls = harness.recordedMethods("session/set_model")
        XCTAssertEqual(setModelCalls.count, 1)
        XCTAssertEqual(setModelCalls.first?["modelId"] as? String, "grok-4.6")
        let meta = setModelCalls.first?["_meta"] as? [String: Any]
        XCTAssertEqual(meta?["reasoningEffort"] as? String, "low")
    }

    func testFullAccessIntentReachesLaunchRequest() {
        let config = GrokBuildAgentConfig(alwaysApproveTools: true)
        let provider = GrokBuildACPHeadlessAgentProvider(config: config)
        let requestConfig = provider.test_config
        XCTAssertTrue(requestConfig.alwaysApproveTools)
    }

    // MARK: - Harness

    private struct Harness {
        let workspace: URL
        let recordURL: URL

        func makeHeadlessProvider(modelString: String?) -> GrokBuildACPHeadlessAgentProvider {
            let recordPath = recordURL.path
            return GrokBuildACPHeadlessAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: scriptPath,
                    additionalPathHints: [],
                    modelString: modelString,
                    includeRepoPromptMCPServer: false
                ),
                workspacePath: workspace.path,
                providerFactory: { config in
                    EnvForwardingGrokProvider(
                        config: config,
                        extraEnvironment: ["ACP_RECORD_PATH": recordPath]
                    )
                }
            )
        }

        var scriptPath: String {
            workspace.appendingPathComponent("grok").path
        }

        func recordedMethods(_ method: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: recordURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["method"] as? String == method
                else { return nil }
                return object["params"] as? [String: Any] ?? [:]
            }
        }
    }

    private func seedRegistry(with models: [String], current: String) {
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: models.map {
                    AgentModelOption(
                        rawValue: $0,
                        displayName: $0,
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                },
                currentModelRaw: current
            ),
            for: .grokBuild
        )
    }

    private func drain(_ provider: GrokBuildACPHeadlessAgentProvider, message: String) async throws {
        let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: message))
        for try await _ in stream {}
        await provider.dispose()
    }

    private func makeHarness(advertiseConfigOptions: Bool = false) throws -> Harness {
        let workspace = try makeTestDirectory(name: "GrokBuildACPHeadlessTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        session_id = "grok-headless-session"
        ADVERTISE_CONFIG_OPTIONS = __ADVERTISE_CONFIG_OPTIONS__

        if "--help" in sys.argv:
            print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
            sys.exit(0)

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def respond(request_id, result=None):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result or {}}), flush=True)

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
                result = {"sessionId": session_id, "models": {
                    "currentModelId": "grok-4.6",
                    "availableModels": [
                        {"modelId": "grok-4.6", "name": "Grok 4.6"},
                        {"modelId": "grok-4.5", "name": "Grok 4.5"}
                    ]
                }}
                if ADVERTISE_CONFIG_OPTIONS:
                    efforts = [{"id": e, "value": e, "default": e == "high"} for e in ["xhigh", "high", "medium", "low"]]
                    result["models"]["availableModels"][0]["_meta"] = {
                        "supportsReasoningEffort": True, "reasoningEffort": "xhigh", "reasoningEfforts": efforts}
                    result["configOptions"] = [
                        {"id": "model", "category": "model", "type": "select", "currentValue": "grok-4.6",
                         "options": [{"value": "grok-4.6", "name": "Grok 4.6"}, {"value": "grok-4.5", "name": "Grok 4.5"}]},
                        {"id": "reasoning_effort", "category": "thought_level", "type": "select", "currentValue": "xhigh",
                         "options": [{"value": e} for e in ["xhigh", "high", "medium", "low"]]}]
                respond(request_id, result)
            elif method == "session/set_model":
                respond(request_id, {"_meta": {"model": {"Ok": params.get("modelId")}}})
            elif method == "session/prompt":
                if ADVERTISE_CONFIG_OPTIONS:
                    # grok may later push a configOptions-only snapshot; it must not demote the direct path.
                    print(json.dumps({
                        "jsonrpc": "2.0", "method": "session/update",
                        "params": {"sessionId": session_id, "update": {
                            "sessionUpdate": "config_option_update",
                            "configOptions": [{"id": "model", "category": "model", "type": "select", "currentValue": "grok-4.6",
                                               "options": [{"value": "grok-4.6", "name": "Grok 4.6"}, {"value": "grok-4.5", "name": "Grok 4.5"}]}]}}
                    }), flush=True)
                print(json.dumps({
                    "jsonrpc": "2.0", "method": "session/update",
                    "params": {"sessionId": session_id, "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "pong"}}}
                }), flush=True)
                respond(request_id, {"stopReason": "end_turn"})
            elif request_id is not None:
                respond(request_id, {})
        """#.replacingOccurrences(of: "__ADVERTISE_CONFIG_OPTIONS__", with: advertiseConfigOptions ? "True" : "False") + "\n"
        let scriptURL = workspace.appendingPathComponent("grok")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return Harness(workspace: workspace, recordURL: recordURL)
    }
}

/// Wraps the real provider so the fake ACP server script sees ACP_RECORD_PATH (the real
/// provider intentionally has no environment-override channel).
private struct EnvForwardingGrokProvider: ACPAgentProvider {
    let config: GrokBuildAgentConfig
    let extraEnvironment: [String: String]

    private let inner: GrokBuildACPAgentProvider

    init(config: GrokBuildAgentConfig, extraEnvironment: [String: String]) {
        self.config = config
        self.extraEnvironment = extraEnvironment
        inner = GrokBuildACPAgentProvider(config: config)
    }

    var providerID: ACPProviderID {
        .grokBuild
    }

    func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
        try await inner.support(for: request)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        var launch = try inner.makeLaunchConfiguration(for: request)
        launch = ACPLaunchConfiguration(
            providerID: launch.providerID,
            command: launch.command,
            arguments: launch.arguments,
            environment: launch.environment.merging(extraEnvironment) { _, new in new },
            workingDirectory: launch.workingDirectory,
            additionalPathHints: launch.additionalPathHints,
            enableDebugLogging: launch.enableDebugLogging,
            cleanupArtifact: launch.cleanupArtifact,
            expectedExecutableIdentity: launch.expectedExecutableIdentity
        )
        return launch
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try inner.makeSessionConfiguration(for: request, mcpServer: mcpServer)
    }

    func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
        try inner.buildPromptBlocks(for: message, request: request)
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
        inner.normalizeSessionUpdate(payload, sessionID: sessionID)
    }

    func normalizeError(_ error: Error) -> Error {
        inner.normalizeError(error)
    }
}

extension EnvForwardingGrokProvider: ACPDirectSessionModelProvider {
    func parseDirectSessionModelSnapshot(from sessionResponse: [String: Any]) -> ACPProviderModelSnapshotResult {
        inner.parseDirectSessionModelSnapshot(from: sessionResponse)
    }

    func makeDirectModelSelectionRequest(
        sessionID: String,
        baseModelRaw: String,
        reasoningEffortRaw: String?
    ) -> ACPDirectModelSelectionRequest {
        inner.makeDirectModelSelectionRequest(
            sessionID: sessionID,
            baseModelRaw: baseModelRaw,
            reasoningEffortRaw: reasoningEffortRaw
        )
    }
}
