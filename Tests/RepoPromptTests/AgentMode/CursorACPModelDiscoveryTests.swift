import Foundation
import RepoPromptSecureStorage
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CursorACPModelDiscoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    func testControllerDiscoveryReturnsLiveParameterizedCursorSnapshotWithoutRegistryPublication() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }

        let workspace = try makeTestDirectory(name: "CursorACPModelDiscoveryTests")
        let scriptURL = try makeServerScript(in: workspace)
        let provider = CursorDiscoveryFakeProvider(commandPath: scriptURL.path)
        let client = CursorACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            }
        )

        let discovered = try await client.discoverModels(workspacePath: workspace.path)
        let snapshot = try XCTUnwrap(discovered)

        XCTAssertEqual(snapshot.currentModelRaw, "grok-4.6")
        XCTAssertEqual(snapshot.options.map(\.rawValue), ["grok-4.6", "composer-2.5", "claude-opus-4-5"])
        XCTAssertEqual(snapshot.modelParameterSets.map(\.baseModelRaw), ["grok-4.6", "composer-2.5"])
        XCTAssertEqual(
            snapshot.modelParameterSets.first?.parameters.map(\.configID),
            ["effort", "fast"]
        )
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .cursor))
    }

    func testControllerDiscoveryTimesOutWhenCursorWithholdsCatalogResponse() async throws {
        let workspace = try makeTestDirectory(name: "CursorACPModelDiscoveryTimeoutTests")
        let scriptURL = try makeServerScript(in: workspace)
        let provider = CursorDiscoveryFakeProvider(
            commandPath: scriptURL.path,
            environment: ["ACP_HANG_DISCOVERY": "1"]
        )
        let client = CursorACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(
                    provider: provider,
                    runRequest: request,
                    requestTimeouts: .init(bootstrapSeconds: 1, operationalSeconds: 0.05),
                    allowsProviderProcessLaunchForTesting: true
                )
            }
        )

        do {
            _ = try await client.discoverModels(workspacePath: workspace.path)
            XCTFail("Expected Cursor discovery to time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cursor/list_available_models"))
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    func testRefreshReportsAdvertisedCountAndRuntimeParametersReachResolver() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let workspace = try makeTestDirectory(name: "CursorRefreshTests")
        let provider = try CursorDiscoveryFakeProvider(commandPath: makeServerScript(in: workspace).path)
        let service = CursorACPModelPollingService(client: CursorACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            }
        ))
        let result = await service.refreshCatalog(workspacePath: workspace.path)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.advertisedCount, 3)
        XCTAssertNil(result.errorMessage)
        let parameters = try XCTUnwrap(ACPModelParameterResolver.parameterSet(
            providerID: .cursor, selectedModelRaw: "Grok 4.6"
        ))
        let effort = try XCTUnwrap(parameters.definition(kind: .thinking))
        XCTAssertEqual(effort.configID, "effort")
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "high"])
        XCTAssertNil(ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: "claude-opus-4-5"))
        await service.shutdown()
    }

    func testLegacyModelOnlyCacheDoesNotInventParameterMetadata() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let legacy = #"{"providerID":"cursor","currentModelRaw":"grok-4.6","options":[{"rawValue":"grok-4.6","displayName":"Grok 4.6","isPlaceholderDefault":false,"isProviderDefault":false,"supportedReasoningEfforts":[]}]}"#
        let record = try JSONDecoder().decode(ACPDynamicProviderRecord.self, from: Data(legacy.utf8))
        let snapshot = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: record))
        XCTAssertFalse(snapshot.hasModelParameterMetadata)
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .cursor)
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .cursor)
        await AgentACPModelRegistry.shared.test_warmStandardStore()
        XCTAssertNil(ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: "grok-4.6"))
    }

    func testCompleteEmptyCatalogDoesNotInventParameters() throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let options = [AgentModelOption(rawValue: "grok-4.6", displayName: "Grok 4.6", description: nil, isDefault: false)]
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(.init(options: options, currentModelRaw: "grok-4.6"), for: .cursor)
        XCTAssertNil(ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: "grok-4.6"))
        let record = try XCTUnwrap(ACPDynamicModelStore.canonicalProviderRecord(
            from: .init(options: options, currentModelRaw: "grok-4.6"), providerID: .cursor
        ))
        let restored = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: record))
        XCTAssertTrue(restored.hasModelParameterMetadata)
        XCTAssertTrue(restored.modelParameterSets.isEmpty)
    }

    func testFailedRefreshKeepsSnapshotAndCanRetry() async {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let snapshot = ACPDiscoveredSessionModels(
            options: [.init(rawValue: "grok-4.6", displayName: "Grok 4.6", description: nil, isDefault: false)], currentModelRaw: "grok-4.6"
        )
        let client = RetryingCursorDiscoveryClient(snapshot: snapshot)
        let service = CursorACPModelPollingService(client: client)
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .cursor)
        let failed = await service.refreshCatalog(workspacePath: nil)
        XCTAssertFalse(failed.isReady)
        XCTAssertNil(failed.advertisedCount)
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertEqual(AgentACPModelRegistry.shared.currentSnapshot(for: .cursor)?.options.map(\.rawValue), ["grok-4.6"])
        let retried = await service.refreshCatalog(workspacePath: nil)
        XCTAssertTrue(retried.isReady)
        XCTAssertEqual(retried.advertisedCount, 1)
        XCTAssertNil(retried.errorMessage)
        await service.shutdown()
    }

    @MainActor
    func testRefreshUIReportsFailureThenRetryAndClearsStateOnSignOut() async {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let client = RetryingCursorDiscoveryClient(snapshot: .init(
            options: [.init(rawValue: "grok-4.6", displayName: "Grok 4.6", description: nil, isDefault: false)], currentModelRaw: "grok-4.6"
        ))
        let service = CursorACPModelPollingService(client: client)
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager,
            loadStoredDataOnInit: false, cursorModelPollingService: service
        )
        viewModel.isCursorConnected = true
        viewModel.refreshCursorModels()
        XCTAssertTrue(viewModel.isDiscoveringCursorModels)
        await viewModel.test_waitForCursorModelRefresh()
        XCTAssertFalse(viewModel.isDiscoveringCursorModels)
        XCTAssertTrue(viewModel.cursorModelDiscoveryMessage?.contains("Try Refresh Models again") == true)
        viewModel.refreshCursorModels()
        await viewModel.test_waitForCursorModelRefresh()
        XCTAssertFalse(viewModel.isDiscoveringCursorModels)
        XCTAssertEqual(viewModel.cursorModelDiscoveryMessage, "1 models advertised.")
        viewModel.refreshCursorModels()
        viewModel.disconnectCursor()
        XCTAssertFalse(viewModel.isDiscoveringCursorModels)
        XCTAssertNil(viewModel.cursorModelDiscoveryMessage)
        await service.shutdown()
        viewModel.prepareForWindowClose()
    }

    private func makeServerScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("cursor_discovery_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        config_options = [
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": "grok-4.6",
                "options": [{"value": "grok-4.6", "name": "Cursor Grok 4.6"}],
            },
            {
                "id": "effort",
                "name": "Effort",
                "category": "thought_level",
                "type": "select",
                "currentValue": "high",
                "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}],
            },
        ]

        available_models = [
            {
                "value": "grok-4.6",
                "name": "Cursor Grok 4.6",
                "configOptions": config_options[1:] + [{
                    "id": "fast",
                    "name": "Fast",
                    "category": "model_config",
                    "type": "select",
                    "currentValue": "true",
                    "options": [{"value": "false", "name": "Standard"}, {"value": "true", "name": "Fast"}],
                }],
            },
            {
                "value": "composer-2.5",
                "name": "Composer 2.5",
                "configOptions": [{
                    "id": "fast",
                    "name": "Fast",
                    "category": "model_config",
                    "type": "select",
                    "currentValue": "true",
                    "options": [{"value": "false", "name": "Standard"}, {"value": "true", "name": "Fast"}],
                }],
            },
            {
                "value": "claude-opus-4-5",
                "name": "Claude Opus 4.5",
                "configOptions": [{
                    "id": "thinking",
                    "name": "Thinking",
                    "category": "thought_level",
                    "type": "select",
                    "currentValue": "true",
                    "options": [{"value": "false", "name": "Off"}, {"value": "true", "name": "On"}],
                }],
            },
        ]

        for line in sys.stdin:
            request = json.loads(line)
            request_id = request.get("id")
            if request_id is None:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"agentCapabilities": {}}
            elif method == "session/new":
                result = {"sessionId": "cursor-discovery", "configOptions": config_options}
            elif method == "cursor/list_available_models":
                if os.environ.get("ACP_HANG_DISCOVERY") == "1":
                    continue
                result = {"models": available_models}
            elif method == "session/set_config_option":
                result = {"configOptions": config_options}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

private actor RetryingCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    let snapshot: ACPDiscoveredSessionModels
    private var calls = 0

    init(snapshot: ACPDiscoveredSessionModels) {
        self.snapshot = snapshot
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        if calls == 1 {
            throw AIProviderError.invalidConfiguration(detail: "Discovery unavailable")
        }
        return snapshot
    }
}

private struct CursorDiscoveryFakeProvider: ACPAgentProvider {
    let commandPath: String
    var environment: [String: String] = [:]

    let providerID: ACPProviderID = .cursor
    let supportsParameterizedModelPicker = true

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        CursorACPAgentProvider(config: CursorAgentConfig()).modelParameterKind(for: input)
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
