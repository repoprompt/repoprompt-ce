import Darwin
import Foundation
import os
import RepoPromptProcess
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
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)

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

    /// Uses this suite's fixture for the real controller/stdio boundary, not the headless facade.
    /// Diagnostics establish notification send-attempt ordering after the successful response, not delivery.
    func testPermissionOverridesReachSessionOpenBeforePrompt() async throws {
        let cases: [(name: String, resumeID: String?, openMethods: [String])] = [
            ("new", nil, ["session/new"]),
            ("load", "saved-session", ["session/load"]),
            ("load-to-new fallback", "missing-session", ["session/load", "session/new"])
        ]
        for fullAccess in [false, true] {
            for testCase in cases {
                let context = "\(testCase.name), fullAccess=\(fullAccess)"
                let harness = try makeHarness()
                let provider = EnvForwardingGrokProvider(
                    config: GrokBuildAgentConfig(
                        commandName: harness.scriptPath,
                        additionalPathHints: [],
                        includeRepoPromptMCPServer: false
                    ),
                    extraEnvironment: ["ACP_RECORD_PATH": harness.recordURL.path]
                )
                let request = ACPRunRequest(
                    agentKind: .grokBuild,
                    modelString: nil,
                    workspacePath: harness.workspace.path,
                    resumeSessionID: testCase.resumeID,
                    attachments: [],
                    taskLabelKind: nil,
                    autoApproveAllToolPermissions: fullAccess
                )
                let permissionMethod = "_x.ai/yolo_mode_changed"
                let lifecycle = OSAllocatedUnfairLock(initialState: [String]())
                let controller = try ACPAgentSessionController(
                    provider: provider,
                    runRequest: request,
                    diagnosticSink: { event in
                        switch event {
                        case let .phaseCompleted(phase) where phase == "session/new" || phase == "session/load":
                            lifecycle.withLock { $0.append("opened") }
                        case let .outboundJSON(line):
                            guard let data = line.data(using: .utf8),
                                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let method = message["method"] as? String,
                                  method == permissionMethod || method == "session/prompt"
                            else { return }
                            lifecycle.withLock { $0.append(method) }
                        default:
                            break
                        }
                    },
                    allowsProviderProcessLaunchForTesting: true
                )
                do {
                    _ = try await controller.bootstrap()
                    try await controller.prompt(AgentMessage(userMessage: "hi"), request: request)
                    await controller.shutdown()
                } catch {
                    await controller.shutdown()
                    throw error
                }

                let messages = harness.recordedMessages()
                let methods = messages.compactMap { $0["method"] as? String }
                // Shutdown may send session/cancel after prompting; only setup traffic is relevant.
                let setupMethods = methods.filter { ["session/new", "session/load", permissionMethod, "session/prompt"].contains($0) }
                let expectedMethods = testCase.openMethods + (fullAccess ? [] : [permissionMethod]) + ["session/prompt"]
                XCTAssertEqual(setupMethods, expectedMethods, context)
                XCTAssertEqual(
                    lifecycle.withLock { $0 },
                    ["opened"] + (fullAccess ? [] : [permissionMethod]) + ["session/prompt"],
                    context
                )

                for method in testCase.openMethods {
                    let params = try XCTUnwrap(harness.recordedMethods(method).first, context)
                    if fullAccess {
                        XCTAssertNil(params["_meta"], context)
                    } else {
                        XCTAssertEqual(
                            params["_meta"] as? [String: Bool],
                            ["yoloMode": false, "autoMode": false],
                            context
                        )
                    }
                }
                let arguments = try XCTUnwrap(harness.recordedMethods("launchArguments").first?["arguments"] as? [String], context)
                XCTAssertEqual(arguments.contains("--always-approve"), fullAccess, context)

                if !fullAccess, let notification = messages.first(where: { $0["method"] as? String == permissionMethod }) {
                    XCTAssertEqual(notification["jsonrpc"] as? String, "2.0", context)
                    XCTAssertNil(notification["id"], "must be a notification: \(context)")
                    XCTAssertEqual(notification["params"] as? [String: Bool], ["auto_mode": false], context)
                }
            }
        }
    }

    func testPostOpenNotificationWriteFailurePreventsPrompt() async throws {
        let harness = try makeHarness(closeStdinOnOpen: true)
        let provider = EnvForwardingGrokProvider(
            config: GrokBuildAgentConfig(
                commandName: harness.scriptPath,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            extraEnvironment: ["ACP_RECORD_PATH": harness.recordURL.path]
        )
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: harness.workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )

        do {
            _ = try await controller.bootstrap()
            XCTFail("Expected the post-open notification write to fail")
        } catch {
            XCTAssertEqual(error as? FDWriteError, .brokenPipe(errno: EPIPE))
        }
        let reusable = await controller.hasReusableSession
        XCTAssertFalse(reusable, "Failed permission setup must not leave a prompt-ready session")
        do {
            try await controller.prompt(AgentMessage(userMessage: "must not send"), request: request)
            XCTFail("Expected an unopened session to refuse the prompt")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP controller expected sessionOpen or promptRunning, but was openingSession.")
        }
        XCTAssertEqual(harness.recordedMethods("session/new").count, 1)
        XCTAssertTrue(harness.recordedMethods("session/prompt").isEmpty)
        await controller.shutdown()
    }

    func testContextBuilderLaunchIsolatesImportsAndPreservesMCPInjection() async throws {
        let harness = try makeHarness()
        let mcp = RepoPromptMCPServerConfiguration(
            command: harness.scriptPath,
            args: ["--backend", "app"],
            env: [.init(name: "RP_TEST_ROUTE", value: "scoped")]
        )
        let recordPath = harness.recordURL.path
        let provider = GrokBuildACPHeadlessAgentProvider(
            config: GrokBuildAgentConfig(commandName: harness.scriptPath, apiKey: "xai-test-key-123"),
            workspacePath: harness.workspace.path,
            providerFactory: { config in
                EnvForwardingGrokProvider(
                    config: config,
                    extraEnvironment: ["ACP_RECORD_PATH": recordPath],
                    repoPromptMCPConfiguration: mcp
                )
            },
            controllerFactory: { provider, request, diagnosticSink in
                try ACPAgentSessionController(
                    provider: provider, runRequest: request, diagnosticSink: diagnosticSink,
                    allowsProviderProcessLaunchForTesting: true
                )
            }
        )
        try await drain(provider, message: "ping")

        let environment = try XCTUnwrap(harness.recordedMethods("launchEnvironment").first)
        XCTAssertEqual(environment["GROK_CLAUDE_MCPS_ENABLED"] as? String, "0")
        XCTAssertEqual(environment["GROK_CURSOR_MCPS_ENABLED"] as? String, "0")
        XCTAssertEqual(environment["XAI_API_KEY"] as? String, "xai-test-key-123")
        let session = try XCTUnwrap(harness.recordedMethods("session/new").first)
        XCTAssertEqual(session["cwd"] as? String, harness.workspace.path)
        let servers = try XCTUnwrap(session["mcpServers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 1)
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server["name"] as? String, "RepoPromptCEGrokRuntime")
        XCTAssertEqual(server["command"] as? String, mcp.command)
        XCTAssertEqual(server["args"] as? [String], mcp.args)
        XCTAssertEqual(server["env"] as? [[String: String]], mcp.env.map(\.acpJSONObject))
    }

    func testMaintenanceRecognitionIsForwardedThroughProviderExistential() {
        let provider: any ACPAgentProvider = EnvForwardingGrokProvider(
            config: GrokBuildAgentConfig(),
            extraEnvironment: [:]
        )
        XCTAssertTrue(provider.recognizesUnmatchedResponseID("skills-reload"))
        XCTAssertTrue(provider.recognizesUnmatchedResponseID("workflows-reload"))
        XCTAssertFalse(provider.recognizesUnmatchedResponseID("other-reload"))
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
                },
                controllerFactory: { provider, request, diagnosticSink in
                    try ACPAgentSessionController(
                        provider: provider, runRequest: request, diagnosticSink: diagnosticSink,
                        allowsProviderProcessLaunchForTesting: true
                    )
                }
            )
        }

        var scriptPath: String {
            workspace.appendingPathComponent("grok").path
        }

        func recordedMessages() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: recordURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            }
        }

        func recordedMethods(_ method: String) -> [[String: Any]] {
            recordedMessages().filter { $0["method"] as? String == method }
                .map { $0["params"] as? [String: Any] ?? [:] }
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

    private func makeHarness(advertiseConfigOptions: Bool = false, closeStdinOnOpen: Bool = false) throws -> Harness {
        let workspace = try makeTestDirectory(name: "GrokBuildACPHeadlessTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import signal
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        session_id = "grok-headless-session"
        ADVERTISE_CONFIG_OPTIONS = __ADVERTISE_CONFIG_OPTIONS__
        CLOSE_STDIN_ON_OPEN = __CLOSE_STDIN_ON_OPEN__

        if "--help" in sys.argv:
            print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
            sys.exit(0)

        def record(method, params, message=None):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(message if message is not None else {"method": method, "params": params}) + "\n")

        def respond(request_id, result=None):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result or {}}), flush=True)

        record("launchEnvironment", {key: os.environ.get(key) for key in
            ["GROK_CLAUDE_MCPS_ENABLED", "GROK_CURSOR_MCPS_ENABLED", "XAI_API_KEY"]})
        record("launchArguments", {"arguments": sys.argv[1:]})

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
            record(method, params, message)
            if method == "initialize":
                respond(request_id, {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": True, "promptCapabilities": {"embeddedContext": True}},
                    "authMethods": []
                })
            elif method in ("session/new", "session/load"):
                if method == "session/load":
                    if params.get("sessionId") == "missing-session":
                        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {
                            "code": -32602, "message": "Session not found"}}), flush=True)
                        continue
                    session_id = params.get("sessionId")
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
                if CLOSE_STDIN_ON_OPEN:
                    # Close before replying so the next write fails deterministically; keep
                    # stdout and the process alive until controller shutdown, avoiding exit races.
                    os.close(sys.stdin.fileno())
                respond(request_id, result)
                if CLOSE_STDIN_ON_OPEN:
                    signal.pause()
                    break
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
        """#.replacingOccurrences(of: "__ADVERTISE_CONFIG_OPTIONS__", with: advertiseConfigOptions ? "True" : "False")
            .replacingOccurrences(of: "__CLOSE_STDIN_ON_OPEN__", with: closeStdinOnOpen ? "True" : "False") + "\n"
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

    init(
        config: GrokBuildAgentConfig,
        extraEnvironment: [String: String],
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) {
        self.config = config
        self.extraEnvironment = extraEnvironment
        inner = GrokBuildACPAgentProvider(config: config, repoPromptMCPConfiguration: repoPromptMCPConfiguration)
    }

    var providerID: ACPProviderID {
        .grokBuild
    }

    func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            try await inner.support(for: request)
        }
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

    func recognizesUnmatchedResponseID(_ id: String) -> Bool {
        inner.recognizesUnmatchedResponseID(id)
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
