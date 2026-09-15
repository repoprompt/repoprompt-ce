import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class OpenCodeACPModelDiscoveryTests: XCTestCase {
    /// The bootstrap catalog must reflect the REAL OpenCode exchange (live capture
    /// 2026-09-15): `session/new` advertises only the `model` and `mode` selectors — NO
    /// `effort`. Effort appears only after a model set, so a catalog-only pass has empty
    /// `modelParameterSets`.
    func testControllerDiscoveryReturnsLiveBootstrapCatalogWithoutRegistryPublication() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let workspace = try makeTestDirectory(name: "OpenCodeACPModelDiscoveryTests")
        let provider = try makeFaithfulDiscoveryProvider(in: workspace)
        let client = OpenCodeACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )

        let discovered = try await client.discoverModels(workspacePath: workspace.path, modelRaw: nil)
        let snapshot = try XCTUnwrap(discovered?.catalog)

        XCTAssertEqual(snapshot.currentModelRaw, "ollama-cloud/kimi-k3")
        XCTAssertEqual(
            snapshot.options.map(\.rawValue),
            ["ollama-cloud/kimi-k3", "anthropic/claude-sonnet", "openrouter/x-ai/grok-4.6"]
        )
        // No model set was issued, so OpenCode has not advertised effort yet.
        XCTAssertTrue(snapshot.modelParameterSets.isEmpty)
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
    }

    func testPollingServicePublishesDiscoveryResultToRegistryAfterColdStart() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let workspace = try makeTestDirectory(name: "OpenCodeACPModelPollingTests")
        let provider = try makeFaithfulDiscoveryProvider(in: workspace)
        let client = OpenCodeACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )
        let service = OpenCodeACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))

        let snapshot = try await service.discoverOnce(workspacePath: workspace.path)
        let published = try XCTUnwrap(snapshot)
        XCTAssertEqual(published.models.currentModelRaw, "ollama-cloud/kimi-k3")
        // Catalog-only discovery: bootstrap advertises no effort, so no parameter sets.
        XCTAssertTrue(published.models.modelParameterSets.isEmpty)
        XCTAssertEqual(
            AgentACPModelRegistry.shared.currentSnapshot(for: .openCode)?.currentModelRaw,
            "ollama-cloud/kimi-k3"
        )
    }

    func testOpenCodeClassifierRecognizesEffortAndRejectsUnrelatedOptions() {
        let provider = OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                modelString: nil,
                enableDebugLogging: false,
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false,
                cleanupLegacyPersistentConfig: false,
                toolProfile: .noTools
            )
        )
        XCTAssertTrue(provider.supportsParameterizedModelPicker)
        let effortChoices = [
            ACPModelParameterChoice(rawValue: "low", displayName: "Low"),
            ACPModelParameterChoice(rawValue: "high", displayName: "High")
        ]

        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "effort",
                category: "thought_level",
                displayName: "Effort",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "effort",
                category: nil,
                displayName: "Effort",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "mode",
                category: "thought_level",
                displayName: "Mode",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertNil(
            provider.modelParameterKind(for: .init(
                configID: "fast",
                category: "model_config",
                displayName: "Fast",
                choices: [
                    ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
                    ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
                ]
            ))
        )
    }

    func testParameterSetLookupMatchesCanonicalOpenCodeIdentityAndMissingModelReturnsNil() {
        let workspacePath = "/workspace-a"
        let parameterSet = ACPModelParameterSet(
            baseModelRaw: "ollama-cloud/kimi-k3",
            parameters: [
                .init(
                    kind: .thinking,
                    configID: "effort",
                    displayName: "Effort",
                    choices: [
                        .init(rawValue: "low", displayName: "Low"),
                        .init(rawValue: "high", displayName: "High")
                    ],
                    currentValueRaw: "low"
                )
            ]
        )
        let available = OpenCodeACPModelParameterSnapshot(
            key: OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: "ollama-cloud/kimi-k3"),
            state: .available(parameterSet),
            updatedAt: Date()
        )

        // The resolver accepts a `.available` observation whose key matches the requested
        // normalized workspace+model; canonical model identity comparison is case/space-insensitive.
        XCTAssertEqual(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: " Ollama-Cloud/Kimi-K3 ",
                workspacePath: workspacePath,
                openCodeParameters: available
            )?.parameters.map(\.configID),
            ["effort"]
        )

        // Wrong-context observation (different requested model) resolves to nothing.
        XCTAssertNil(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: "anthropic/claude-sonnet",
                workspacePath: workspacePath,
                openCodeParameters: available
            )
        )

        // A mismatched workspace key never yields metadata.
        XCTAssertNil(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: "ollama-cloud/kimi-k3",
                workspacePath: "/other-workspace",
                openCodeParameters: available
            )
        )

        // Missing observation, and non-.available observations, yield no parameter authority.
        XCTAssertNil(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: "ollama-cloud/kimi-k3",
                workspacePath: workspacePath
            )
        )
        for state in [
            OpenCodeACPModelParameterState.loading,
            .noUsableParameters,
            .failed(detail: "boom")
        ] {
            let nonAvailable = OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: "ollama-cloud/kimi-k3"),
                state: state,
                updatedAt: Date()
            )
            XCTAssertNil(
                ACPModelParameterResolver.parameterSet(
                    providerID: .openCode,
                    selectedModelRaw: "ollama-cloud/kimi-k3",
                    workspacePath: workspacePath,
                    openCodeParameters: nonAvailable
                )
            )
        }
    }

    /// A verified, matching model that legitimately advertises NO selector is a successful
    /// `.noUsableParameters`, not a "matched 0 parameter sets" failure (classification bug).
    func testParameterProbeClassifiesNoSelectorAsNoUsableParametersNotFailure() async {
        let state = await OpenCodeACPControllerModelDiscoveryClient.classifyParameterOutcome(
            modelRaw: "ollama-cloud/kimi-k3"
        ) { _ in
            ACPDiscoveredSessionModels(
                options: [
                    .init(
                        rawValue: "ollama-cloud/kimi-k3",
                        displayName: "Kimi K3",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "ollama-cloud/kimi-k3",
                modelParameterSets: [] // matching model advertises no selector
            )
        }
        guard case .noUsableParameters = state else {
            return XCTFail("Expected .noUsableParameters for a matching model with no selector, got \(state)")
        }
    }

    // MARK: - Controller-level forced discovery (capture-derived fixtures)

    /// One shared fixture for the real-client selector-RPC cases: a capture-faithful scripted
    /// OpenCode server plus a bootstrapped controller, with request recording. The current-model
    /// and other-model cases differ only in which model they probe; fixture construction is not.
    private func withParameterDiscoveryController<Result>(
        environment: [String: String] = [:],
        name: String = "OpenCodeACPParameterDiscovery",
        _ body: (
            _ controller: ACPAgentSessionController,
            _ recordURL: URL
        ) async throws -> Result
    ) async throws -> Result {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        let workspace = try makeTestDirectory(name: name)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let controller = try makeParameterDiscoveryController(
            in: workspace,
            recordURL: recordURL,
            environment: environment
        )
        _ = try await controller.bootstrap()
        return try await body(controller, recordURL)
    }

    /// A request to discover parameters for the model that is ALREADY the bootstrap current
    /// model must still send a model-selector RPC: OpenCode only advertises `effort` after a
    /// model set (live capture, 2026-09-15), so skipping a "no-op" set returns bootstrap
    /// metadata with no effort. The verified post-mutation readback surfaces the effort set.
    func testDiscoverSessionModelParametersForBootstrapCurrentModelStillForcesSelectorRPC() async throws {
        try await withParameterDiscoveryController { controller, recordURL in
            let snapshot = try await controller.discoverSessionModelParameters(for: "ollama-cloud/kimi-k3")

            XCTAssertEqual(snapshot.currentModelRaw, "ollama-cloud/kimi-k3")
            let parameterSet = try XCTUnwrap(snapshot.modelParameterSets.first)
            let effort = try XCTUnwrap(parameterSet.definition(kind: .thinking))
            XCTAssertEqual(effort.configID, "effort")
            // Live wire shape: choices arrive under the `options` key as {value, name} objects.
            XCTAssertEqual(effort.choices.map(\.rawValue), ["max"])
            XCTAssertEqual(effort.currentValueRaw, "max")

            let modelMutations = recordedRequests(at: recordURL).filter {
                $0.method == "session/set_config_option" && $0.params["configId"] as? String == "model"
            }
            XCTAssertEqual(modelMutations.count, 1)
            XCTAssertEqual(modelMutations.first?.params["value"] as? String, "ollama-cloud/kimi-k3")

            // Discovery must never mutate effort or prompt the session.
            XCTAssertTrue(recordedRequests(at: recordURL, method: "session/prompt").isEmpty)
            XCTAssertTrue(recordedRequests(at: recordURL).allSatisfy {
                $0.method != "session/set_config_option" || $0.params["configId"] as? String == "model"
            })

            // The disposable controller never publishes to the global registry.
            XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
        }
    }

    /// Discovery for a non-bootstrap model forces the RPC, and the verified snapshot's
    /// current model matches the requested identity (never another model's metadata).
    func testDiscoverSessionModelParametersForOtherModelReturnsVerifiedSnapshotForRequestedModel() async throws {
        try await withParameterDiscoveryController { controller, recordURL in
            let snapshot = try await controller.discoverSessionModelParameters(
                for: " OpenRouter/x-ai/Grok-4.6 "
            )

            XCTAssertEqual(snapshot.currentModelRaw, "openrouter/x-ai/grok-4.6")
            let parameterSet = try XCTUnwrap(snapshot.modelParameterSets.first)
            XCTAssertEqual(
                ACPModelParameterIdentity.canonicalBaseModelRaw(parameterSet.baseModelRaw, providerID: .openCode),
                ACPModelParameterIdentity.canonicalBaseModelRaw("openrouter/x-ai/grok-4.6", providerID: .openCode)
            )
            let effort = try XCTUnwrap(parameterSet.definition(kind: .thinking))
            XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
            XCTAssertEqual(effort.currentValueRaw, "low")

            let modelMutations = recordedRequests(at: recordURL).filter {
                $0.method == "session/set_config_option" && $0.params["configId"] as? String == "model"
            }
            XCTAssertEqual(modelMutations.map { $0.params["value"] as? String }, ["openrouter/x-ai/grok-4.6"])
            XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
        }
    }

    /// When the agent confirms a DIFFERENT model than requested, the verified mutation path
    /// rejects the readback and discovery throws that verification failure rather than
    /// returning foreign metadata (assert the INTENDED failure, not merely any throw).
    func testDiscoverSessionModelParametersRejectsWrongModelReadback() async throws {
        try await withParameterDiscoveryController(
            environment: ["ACP_CONFIRM_MODEL": "anthropic/claude-sonnet"]
        ) { controller, _ in
            do {
                _ = try await controller.discoverSessionModelParameters(for: "ollama-cloud/kimi-k3")
                XCTFail("Expected the wrong-model readback to throw")
            } catch {
                // The intended failure is the verified-mutation rejection: the post-mutation
                // readback confirmed 'anthropic/claude-sonnet', not the requested kimi-k3.
                // (ControllerError is fileprivate, so assert its surfaced reason.)
                XCTAssertEqual(
                    error.localizedDescription,
                    "ACP protocol violation: session/set_config_option response did not confirm requested model 'ollama-cloud/kimi-k3'"
                )
            }
        }
    }

    /// A malformed mutation readback (missing the complete configOptions snapshot) is rejected
    /// with the verified-mutation failure, not an incidental error.
    func testDiscoverSessionModelParametersRejectsMalformedReadback() async throws {
        try await withParameterDiscoveryController(
            environment: ["ACP_MALFORMED_MUTATION": "1"]
        ) { controller, _ in
            do {
                _ = try await controller.discoverSessionModelParameters(for: "ollama-cloud/kimi-k3")
                XCTFail("Expected the malformed readback to throw")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "ACP protocol violation: session/set_config_option response missing complete configOptions snapshot"
                )
            }
        }
    }

    /// Discovery requires an open session; calling it before bootstrap is an invalid state.
    func testDiscoverSessionModelParametersRequiresOpenSession() async throws {
        let workspace = try makeTestDirectory(name: "OpenCodeACPParameterDiscovery")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let controller = try makeParameterDiscoveryController(in: workspace, recordURL: recordURL)

        await XCTAssertThrowsErrorAsync {
            try await controller.discoverSessionModelParameters(for: "ollama-cloud/kimi-k3")
        }
        XCTAssertTrue(recordedRequests(at: recordURL).isEmpty)
    }

    private struct RecordedDiscoveryRequest {
        let method: String
        let params: [String: Any]
    }

    // MARK: - Contract test: real client sends a model-set RPC and surfaces metadata

    /// One shared fixture for the real-client discovery cases: a capture-faithful server plus a
    /// client over it, so the selector-RPC and partial-failure cases share construction.
    private func withRealDiscoveryClient<Result>(
        environment: [String: String] = [:],
        _ body: (
            _ client: OpenCodeACPControllerModelDiscoveryClient,
            _ workspace: URL,
            _ recordURL: URL
        ) async throws -> Result
    ) async throws -> Result {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        let workspace = try makeTestDirectory(name: "OpenCodeACPDiscoveryContract")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let provider = try makeFaithfulDiscoveryProvider(
            in: workspace,
            recordURL: recordURL,
            environment: environment
        )
        let client = OpenCodeACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )
        return try await body(client, workspace, recordURL)
    }

    /// Drives the REAL `OpenCodeACPControllerModelDiscoveryClient` over the capture-faithful
    /// scripted transport. OpenCode only advertises `effort` after a model set, so a correct
    /// discovery MUST send one model-selector RPC and return that model's parameter outcome
    /// alongside the pristine bootstrap catalog. This is the test a fake discovery client
    /// cannot satisfy — its absence is what let the defect ship.
    func testRealClientDiscoveryForModelSendsSelectorRPCAndReturnsBootstrapCatalog() async throws {
        try await withRealDiscoveryClient { client, workspace, recordURL in
            let discovered = try await client.discoverModels(
                workspacePath: workspace.path,
                modelRaw: "openrouter/x-ai/grok-4.6"
            )
            let result = try XCTUnwrap(discovered)

            // 1. A model-selector RPC was actually sent during discovery (effort requires it).
            let modelMutations = recordedRequests(at: recordURL).filter {
                $0.method == "session/set_config_option" && $0.params["configId"] as? String == "model"
            }
            XCTAssertEqual(modelMutations.count, 1)
            XCTAssertEqual(modelMutations.first?.params["value"] as? String, "openrouter/x-ai/grok-4.6")

            // 2. Bootstrap catalog is retained verbatim: bootstrap current model, full option list,
            // and NO substitution of the probe session's current model.
            XCTAssertEqual(result.catalog.currentModelRaw, "ollama-cloud/kimi-k3")
            XCTAssertEqual(
                result.catalog.options.map(\.rawValue),
                ["ollama-cloud/kimi-k3", "anthropic/claude-sonnet", "openrouter/x-ai/grok-4.6"]
            )
            XCTAssertTrue(result.catalog.modelParameterSets.isEmpty)

            // 3. The requested model's parameter metadata reaches the caller, with the live-captured
            // choices under the `options` wire key.
            guard case let .available(parameterSet) = result.parameterState else {
                return XCTFail("Expected .available parameter state, got \(String(describing: result.parameterState))")
            }
            XCTAssertEqual(
                ACPModelParameterIdentity.canonicalBaseModelRaw(parameterSet.baseModelRaw, providerID: .openCode),
                ACPModelParameterIdentity.canonicalBaseModelRaw("openrouter/x-ai/grok-4.6", providerID: .openCode)
            )
            let effort = try XCTUnwrap(parameterSet.definition(kind: .thinking))
            XCTAssertEqual(effort.configID, "effort")
            XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])

            // 4. Discovery never mutates effort nor prompts the session.
            XCTAssertTrue(recordedRequests(at: recordURL, method: "session/prompt").isEmpty)
            XCTAssertTrue(recordedRequests(at: recordURL).allSatisfy {
                $0.method != "session/set_config_option" || $0.params["configId"] as? String == "model"
            })
            XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
        }
    }

    /// A probe whose selector RPC fails must still return the COMPLETE bootstrap catalog —
    /// losing the model list to a parameter failure is a worse regression than the bug we fixed.
    func testRealClientParameterFailureStillReturnsCompleteBootstrapCatalog() async throws {
        try await withRealDiscoveryClient(
            environment: ["ACP_MALFORMED_MUTATION": "1"]
        ) { client, workspace, _ in
            let discovered = try await client.discoverModels(
                workspacePath: workspace.path, modelRaw: "ollama-cloud/kimi-k3"
            )
            let result = try XCTUnwrap(discovered)
            XCTAssertEqual(result.catalog.options.count, 3)
            XCTAssertEqual(result.catalog.currentModelRaw, "ollama-cloud/kimi-k3")
            guard case .failed = result.parameterState else {
                return XCTFail("Expected .failed parameter state, got \(String(describing: result.parameterState))")
            }
        }
    }

    /// Builds a provider backed by the capture-faithful scripted server (bootstrap advertises
    /// only `model`/`mode`; `effort` appears only after a model set). Returns the provider.
    private func makeFaithfulDiscoveryProvider(
        in directory: URL,
        recordURL: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> OpenCodeDiscoveryFakeProvider {
        let scriptURL = directory.appendingPathComponent("opencode_discovery_server_\(UUID().uuidString).py")
        try Self.parameterDiscoveryServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var serverEnvironment = environment
        serverEnvironment["ACP_RECORD_PATH"] = recordURL?.path
            ?? directory.appendingPathComponent("requests.jsonl").path
        return OpenCodeDiscoveryFakeProvider(commandPath: scriptURL.path, environment: serverEnvironment)
    }

    private func makeParameterDiscoveryController(
        in directory: URL,
        recordURL: URL,
        environment: [String: String] = [:]
    ) throws -> ACPAgentSessionController {
        let scriptURL = directory.appendingPathComponent("opencode_parameter_discovery_server.py")
        try Self.parameterDiscoveryServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var serverEnvironment = environment
        serverEnvironment["ACP_RECORD_PATH"] = recordURL.path
        let provider = OpenCodeDiscoveryFakeProvider(commandPath: scriptURL.path, environment: serverEnvironment)
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: ACPRunRequest(
                agentKind: .openCode,
                modelString: nil,
                workspacePath: directory.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            )
        )
        addTeardownBlock { await controller.shutdown() }
        return controller
    }

    private func recordedRequests(
        at url: URL,
        method: String? = nil
    ) -> [RecordedDiscoveryRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let recordedMethod = object["method"] as? String,
                  method == nil || method == recordedMethod
            else { return nil }
            return RecordedDiscoveryRequest(
                method: recordedMethod,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    /// Capture-derived fixture (redacted; live ACP probe of `opencode acp` 1.18.30, 2026-09-15):
    /// - `session/new` advertises ONLY the `model` and `mode` selectors.
    /// - After `session/set_config_option` on `model`, the snapshot gains an `effort`
    ///   (`thought_level`) selector for the now-current model. Effort availability is
    ///   per-model and per-installation (`opencode.json` may narrow variants), so the fixture
    ///   carries one narrowed single-choice model (kimi-k3: `max` only) and one multi-choice
    ///   model (grok-4.6: low/medium/high/xhigh). Choices arrive under the wire key `options`
    ///   as `{value, name}` objects.
    private static let parameterDiscoveryServerScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    model = "ollama-cloud/kimi-k3"
    mode = "build"

    MODELS = [
        ("ollama-cloud/kimi-k3", "Kimi K3"),
        ("anthropic/claude-sonnet", "Claude Sonnet"),
        ("openrouter/x-ai/grok-4.6", "Grok 4.6"),
    ]
    EFFORTS = {
        "ollama-cloud/kimi-k3": ("max", [("max", "Max")]),
        "anthropic/claude-sonnet": ("high", [("low", "Low"), ("medium", "Medium"), ("high", "High")]),
        "openrouter/x-ai/grok-4.6": ("low", [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "XHigh")]),
    }

    def selector(id, name, category, current, choices):
        return {"id": id, "name": name, "category": category, "type": "select",
                "currentValue": current, "options": [{"value": v, "name": n} for v, n in choices]}

    def bootstrap_options():
        return [
            selector("model", "Model", "model", model, MODELS),
            selector("mode", "Mode", "mode", mode, [("build", "Build"), ("plan", "Plan")]),
        ]

    def post_mutation_options():
        options = bootstrap_options()
        effort_current, effort_choices = EFFORTS.get(model, ("max", [("max", "Max")]))
        return options + [selector("effort", "Effort", "thought_level", effort_current, effort_choices)]

    for line in sys.stdin:
        request = json.loads(line)
        with open(os.environ["ACP_RECORD_PATH"], "a") as record:
            record.write(json.dumps(request) + "\n")
        request_id = request.get("id")
        if request_id is None:
            continue
        method = request.get("method")
        params = request.get("params", {})
        if method == "initialize":
            result = {"agentCapabilities": {}}
        elif method == "session/new":
            result = {"sessionId": "opencode-parameter-discovery", "configOptions": bootstrap_options()}
        elif method == "session/set_config_option":
            config_id = params.get("configId")
            if config_id == "model":
                confirmed = os.environ.get("ACP_CONFIRM_MODEL") or params.get("value", model)
                model = confirmed
            if os.environ.get("ACP_MALFORMED_MUTATION"):
                result = {}
            else:
                result = {"configOptions": post_mutation_options()}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
    """#

    // NOTE: the previous `makeServerScript` fixture advertised `effort` AT BOOTSTRAP, which is
    // not what OpenCode does (live capture 2026-09-15). That dishonest fixture is precisely why
    // this defect shipped past a green suite. It is intentionally removed; use
    // `makeFaithfulDiscoveryProvider` (bootstrap: model+mode only) and the scripted
    // `ScriptedDiscoveryClient` double instead of a Python subprocess.
}

private struct OpenCodeDiscoveryFakeProvider: ACPAgentProvider {
    let commandPath: String
    var environment: [String: String] = [:]

    let providerID: ACPProviderID = .openCode
    private var productionProvider: OpenCodeACPAgentProvider {
        OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                modelString: nil,
                enableDebugLogging: false,
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false,
                cleanupLegacyPersistentConfig: false,
                toolProfile: .noTools
            )
        )
    }

    var supportsParameterizedModelPicker: Bool {
        productionProvider.supportsParameterizedModelPicker
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        productionProvider.modelParameterKind(for: input)
    }

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
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

/// A controllable, gated `OpenCodeACPModelDiscoveryClient` for orchestration tests: it
/// exercises the polling service's job/coalescing/eviction/cancellation logic without any
/// Python subprocess or wire protocol. Barriers (`waitForCallCount`, `waitForIdle`) are used
/// only through the file's `bound*` wrappers so they always have a bounded failure exit.
private actor ScriptedDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    init() {}

    func discoverModels(workspacePath _: String?, modelRaw: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
        let catalog = ACPDiscoveredSessionModels(
            options: [
                .init(rawValue: "ollama-cloud/kimi-k3", displayName: "Kimi K3", description: nil, isPlaceholderDefault: false, isProviderDefault: true),
                .init(rawValue: "openrouter/x-ai/grok-4.6", displayName: "Grok 4.6", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
            ],
            currentModelRaw: "ollama-cloud/kimi-k3",
            modelParameterSets: []
        )
        var parameterState: OpenCodeACPModelParameterState?
        if let modelRaw {
            parameterState = .available(
                ACPModelParameterSet(
                    baseModelRaw: modelRaw,
                    parameters: [
                        .init(
                            kind: .thinking,
                            configID: "effort",
                            displayName: "Effort",
                            choices: [.init(rawValue: "max", displayName: "Max")],
                            currentValueRaw: "max"
                        )
                    ]
                )
            )
        }
        return OpenCodeACPModelDiscoveryResult(catalog: catalog, parameterState: parameterState)
    }
}
