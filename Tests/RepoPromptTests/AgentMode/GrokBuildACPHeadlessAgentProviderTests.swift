import Darwin
import Foundation
import os
import RepoPromptProcess
import RepoPromptSettingsCore
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
        let cases: [(name: String, order: String, reportedID: String?, postSelectionID: String?, afterSelection: String?, afterPrompt: String?)] = [
            ("model-only update before response", "before", nil, nil, nil, nil),
            ("report before response", "before", "eff-low", nil, "low", "low"),
            ("response before differing report", "after", "eff-high", nil, nil, "high"),
            ("unresolvable option id", "before", "eff-low", "not-advertised", "low", nil)
        ]
        var observedEfforts: [[String?]] = []
        for testCase in cases {
            let harness = try makeHarness(advertiseConfigOptions: true)
            let config = GrokBuildAgentConfig(
                commandName: harness.scriptPath,
                additionalPathHints: [],
                modelString: "grok-4.6-low",
                includeRepoPromptMCPServer: false
            )
            var environment = [
                "ACP_RECORD_PATH": harness.recordURL.path,
                "ACP_EFFORT_REPORT_ORDER": testCase.order
            ]
            environment["ACP_REPORTED_EFFORT_ID"] = testCase.reportedID
            environment["ACP_POST_SELECTION_EFFORT_ID"] = testCase.postSelectionID
            let provider = EnvForwardingGrokProvider(config: config, extraEnvironment: environment)
            let request = ACPRunRequest(
                agentKind: .grokBuild,
                modelString: config.modelString,
                workspacePath: harness.workspace.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            )
            let controller = try ACPAgentSessionController(
                provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true
            )

            do {
                let bootstrap = try await controller.bootstrap()
                let initialState = await controller.currentDiscoveredSessionModels()
                let initial = try XCTUnwrap(initialState, testCase.name)
                XCTAssertEqual(initial.currentEffortRaw, "xhigh", "initial authority: \(testCase.name)")
                XCTAssertTrue(initial.options.contains { $0.rawValue == "grok-4.6-low" }, testCase.name)
                XCTAssertTrue(initial.options.contains { $0.rawValue == "grok-4.6-max" }, testCase.name)

                // Preserve the original model-only update-before-selection regression.
                try await controller.prompt(AgentMessage(userMessage: "before selection"), request: request)
                try await controller.setSessionModel("grok-4.6-low")
                let selected = await controller.currentDiscoveredSessionModels()
                XCTAssertEqual(selected?.currentModelRaw, "grok-4.6", testCase.name)

                // The peer releases the late report only on this request, which cannot be
                // dispatched until setSessionModel has returned. Its prompt reply fences processing.
                try await controller.prompt(AgentMessage(userMessage: "after selection"), request: request)
                let reported = await controller.currentDiscoveredSessionModels()
                XCTAssertEqual(reported?.currentModelRaw, "grok-4.6", testCase.name)
                observedEfforts.append([selected?.currentEffortRaw, reported?.currentEffortRaw])
                XCTAssertEqual(reported?.options, initial.options, "direct catalog: \(testCase.name)")
                let mapped = provider.makeDirectModelSelectionRequest(
                    sessionID: bootstrap.sessionID, baseModelRaw: "grok-4.6", reasoningEffortRaw: "max"
                )
                XCTAssertEqual((mapped.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "maximum", "exact wire alias: \(testCase.name)")
                await controller.shutdown()
            } catch {
                await controller.shutdown()
                throw error
            }

            let setModelCalls = harness.recordedMethods("session/set_model")
            XCTAssertEqual(setModelCalls.count, 1, testCase.name)
            XCTAssertEqual(setModelCalls.first?["modelId"] as? String, "grok-4.6", testCase.name)
            let meta = setModelCalls.first?["_meta"] as? [String: Any]
            XCTAssertEqual(meta?["reasoningEffort"] as? String, "low", testCase.name)
        }
        // Exercise every row before asserting the red effort outcomes.
        XCTAssertEqual(observedEfforts, cases.map { [$0.afterSelection, $0.afterPrompt] }, cases.map(\.name).joined(separator: "; "))
    }

    func testSetModelTimeoutInvalidatesDirectAuthority() async throws {
        let harness = try makeHarness(advertiseConfigOptions: true)
        let provider = EnvForwardingGrokProvider(
            config: GrokBuildAgentConfig(
                commandName: harness.scriptPath,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            extraEnvironment: [
                "ACP_RECORD_PATH": harness.recordURL.path,
                "ACP_WITHHOLD_SET_MODEL_RESPONSE": "1"
            ]
        )
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: "grok-4.6-low",
            workspacePath: harness.workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 0.1),
            allowsProviderProcessLaunchForTesting: true
        )
        let initial: ACPDiscoveredSessionModels
        do {
            _ = try await controller.bootstrap()
            let snapshot = await controller.currentDiscoveredSessionModels()
            initial = try XCTUnwrap(snapshot)
            XCTAssertEqual(initial.currentModelRaw, "grok-4.6")
            XCTAssertEqual(initial.currentEffortRaw, "xhigh")
        } catch {
            await controller.shutdown()
            throw error
        }

        let completed = expectation(description: "session/set_model operational timeout")
        let selectionTask = Task {
            let failure: String?
            do {
                try await controller.setSessionModel("grok-4.6-low")
                try await controller.prompt(AgentMessage(userMessage: "must not send"), request: request)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            completed.fulfill()
            return failure
        }
        // Bound the known-bad missing-timeout path, then always release its continuation
        // and join it. Inspect authority before shutdown, which clears all snapshots.
        await fulfillment(of: [completed], timeout: 2)
        let afterTimeout = await controller.currentDiscoveredSessionModels()
        await controller.shutdown()
        let failure = await selectionTask.value

        XCTAssertTrue(failure?.hasPrefix("ACP request session/set_model timed out after 0.1s.") == true, "unexpected failure: \(failure ?? "none")")
        XCTAssertNil(afterTimeout?.currentModelRaw)
        XCTAssertNil(afterTimeout?.currentEffortRaw)
        XCTAssertEqual(afterTimeout?.options, initial.options)
        XCTAssertEqual(harness.recordedMethods("session/set_model").count, 1)
        XCTAssertTrue(harness.recordedMethods("session/prompt").isEmpty)
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
        let backgroundKeys = ["GROK_MEMORY", "GROK_SUBAGENTS", "GROK_WORKFLOWS", "GROK_AUTO_WAKE"]
        let managedEnvironment = Dictionary(uniqueKeysWithValues: backgroundKeys.map { ($0, "0") })
        for (usage, backgroundEnvironment) in [
            ("Context Builder", [:]),
            ("forwarded managed policy", managedEnvironment)
        ] {
            let harness = try makeHarness()
            let mcp = RepoPromptMCPServerConfiguration(
                command: harness.scriptPath,
                args: ["--backend", "app"],
                env: [.init(name: "RP_TEST_ROUTE", value: "scoped")]
            )
            let recordPath = harness.recordURL.path
            // Deterministic fixture defaults sit below real launch overrides: an empty
            // policy preserves native values, while a forwarded policy disables them.
            let fixtureEnvironment = Dictionary(uniqueKeysWithValues: backgroundKeys.map { ($0, "1") })
                .merging([
                    "ACP_RECORD_PATH": recordPath,
                    "GROK_CLAUDE_MCPS_ENABLED": "1",
                    "GROK_CURSOR_MCPS_ENABLED": "1"
                ]) { _, new in new }
            let provider = GrokBuildACPHeadlessAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: harness.scriptPath,
                    apiKey: "xai-test-key-123",
                    backgroundFeatureEnvironment: backgroundEnvironment
                ),
                workspacePath: harness.workspace.path,
                providerFactory: { config in
                    EnvForwardingGrokProvider(
                        config: config,
                        extraEnvironment: fixtureEnvironment,
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
            for key in backgroundKeys {
                XCTAssertEqual(environment[key] as? String, backgroundEnvironment[key] ?? "1", "\(usage): \(key)")
            }
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
        effort_report_order = os.environ.get("ACP_EFFORT_REPORT_ORDER")
        reported_effort_id = os.environ.get("ACP_REPORTED_EFFORT_ID")
        post_selection_effort_id = os.environ.get("ACP_POST_SELECTION_EFFORT_ID")
        withhold_set_model_response = os.environ.get("ACP_WITHHOLD_SET_MODEL_RESPONSE") == "1"
        selected_model = "grok-4.6"
        late_effort_report_pending = False

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

        def config_update(effort_id=None):
            options = [{"id": "model", "category": "model", "type": "select", "currentValue": selected_model,
                        "options": [{"value": "grok-4.6", "name": "Grok 4.6"}, {"value": "grok-4.5", "name": "Grok 4.5"}]}]
            if effort_id is not None:
                options.append({"id": "reasoning_effort", "category": "thought_level", "type": "select", "currentValue": effort_id,
                                "options": [{"value": "eff-" + e} for e in ["xhigh", "high", "medium", "low", "maximum"]]})
            print(json.dumps({"jsonrpc": "2.0", "method": "session/update",
                              "params": {"sessionId": session_id, "update": {
                                  "sessionUpdate": "config_option_update", "configOptions": options}}}), flush=True)

        record("launchEnvironment", {key: os.environ.get(key) for key in
            ["GROK_MEMORY", "GROK_SUBAGENTS", "GROK_WORKFLOWS", "GROK_AUTO_WAKE",
             "GROK_CLAUDE_MCPS_ENABLED", "GROK_CURSOR_MCPS_ENABLED", "XAI_API_KEY"]})
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
                    efforts = [{"id": "eff-" + e, "value": e, "default": e == "high"} for e in ["xhigh", "high", "medium", "low", "maximum"]]
                    result["models"]["availableModels"][0]["_meta"] = {
                        "supportsReasoningEffort": True, "reasoningEffort": "xhigh", "reasoningEfforts": efforts}
                    result["_meta"] = {"x.ai/sessionConfig": {"options": [
                        {"id": "eff-xhigh", "category": "mode", "selected": True}]}}
                    result["configOptions"] = [
                        {"id": "model", "category": "model", "type": "select", "currentValue": "grok-4.6",
                         "options": [{"value": "grok-4.6", "name": "Grok 4.6"}, {"value": "grok-4.5", "name": "Grok 4.5"}]},
                        {"id": "reasoning_effort", "category": "thought_level", "type": "select", "currentValue": "eff-xhigh",
                         "options": [{"value": "eff-" + e} for e in ["xhigh", "high", "medium", "low", "maximum"]]}]
                if CLOSE_STDIN_ON_OPEN:
                    # Close before replying so the next write fails deterministically; keep
                    # stdout and the process alive until controller shutdown, avoiding exit races.
                    os.close(sys.stdin.fileno())
                respond(request_id, result)
                if CLOSE_STDIN_ON_OPEN:
                    signal.pause()
                    break
            elif method == "session/set_model":
                if withhold_set_model_response:
                    # Consume the request but leave the peer and both pipes open until shutdown.
                    continue
                selected_model = params.get("modelId")
                if effort_report_order == "before":
                    config_update(reported_effort_id)
                late_effort_report_pending = effort_report_order == "after" or post_selection_effort_id is not None
                respond(request_id, {"_meta": {"model": {"Ok": selected_model}}})
            elif method == "session/prompt":
                if ADVERTISE_CONFIG_OPTIONS:
                    # A subsequent request fences the late report behind selection completion.
                    config_update((post_selection_effort_id or reported_effort_id) if late_effort_report_pending else None)
                    late_effort_report_pending = False
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

/// Wraps the real provider so the fake ACP server script sees ACP_RECORD_PATH and
/// deterministic fixture defaults, with real launch overrides remaining authoritative.
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
            environment: extraEnvironment.merging(launch.environment) { _, launchValue in launchValue },
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
    func parseDirectSessionEffortReport(
        from configOptions: [[String: Any]],
        sessionID: String,
        options: [AgentModelOption]
    ) -> ACPDirectSessionEffortReport? {
        inner.parseDirectSessionEffortReport(from: configOptions, sessionID: sessionID, options: options)
    }

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
