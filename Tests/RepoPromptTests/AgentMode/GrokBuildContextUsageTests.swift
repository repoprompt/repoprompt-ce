import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildContextUsageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    // Synthetic ACP payloads based on #1325 and Grok source 2bdd1d6a, not wire recordings.
    // totalTokens is current conversation state; inputTokens is the last model call's prompt.
    private static let multiCallResponse = #"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"multi-call","modelId":"grok-large","totalTokens":26278,"inputTokens":25678,"outputTokens":600,"cachedReadTokens":25600,"usage":{"inputTokens":139056,"outputTokens":1200,"cachedReadTokens":114304,"cacheCreationTokens":0,"modelCalls":6}}}"#
    private static let modelResponse = #"{"sessionId":"grok-context-fixture","models":{"currentModelId":"grok-large","availableModels":[{"modelId":"grok-large","name":"Large","_meta":{"totalContextTokens":1000000,"supportsReasoningEffort":true,"reasoningEfforts":[{"id":"high","value":"high"}]}},{"modelId":"grok-small","name":"Small","_meta":{"totalContextTokens":128000}},{"modelId":"grok-unknown","name":"Unknown"},{"modelId":"grok-invalid","name":"Invalid","_meta":{"totalContextTokens":-1}}]}}"#

    private func json(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// Exercise session/new discovery and session/prompt finalization on a synthetic process only.
    private func runResponses(_ responses: [[String: Any]], modelSelections: [Int: String] = [:]) async throws -> [AIStreamResult] {
        let directory = try makeTestDirectory()
        let executable = directory.appendingPathComponent("grok")
        try Self.fakeGrokScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: ["session": json(Self.modelResponse), "responses": responses])
            .write(to: directory.appendingPathComponent("responses.json"))
        let provider = GrokBuildACPAgentProvider(config: GrokBuildAgentConfig(
            commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false
        ))
        let request = ACPRunRequest(
            agentKind: .grokBuild, modelString: "default", workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true
        )
        let stream = await controller.currentEventsStream()
        do {
            _ = try await controller.bootstrap()
            for index in responses.indices {
                if let model = modelSelections[index] {
                    try await controller.setSessionModel(model)
                }
                try await controller.prompt(AgentMessage(userMessage: index == 2 ? "compact" : "fixture turn"), request: request)
            }
        } catch {
            await controller.shutdown()
            throw error
        }
        await controller.shutdown()
        var stops: [AIStreamResult] = []
        for await event in stream {
            if case let .stream(result) = event, result.type == "message_stop" { stops.append(result) }
        }
        return stops
    }

    @MainActor
    func testDefaultSelectionUsesResponseModelWindowAndCurrentContextAfterCompaction() async throws {
        let responses = try [
            json(Self.multiCallResponse),
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"single-call","modelId":"grok-small","totalTokens":25827,"inputTokens":25811,"outputTokens":16,"usage":{"inputTokens":25811,"outputTokens":16,"cachedReadTokens":25600,"modelCalls":1}}}"#),
            // Conversation replacement reseeds totalTokens but does not clear last_turn_usage.
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"compact","modelId":"grok-small","totalTokens":20000,"inputTokens":180000,"outputTokens":1000,"usage":{"inputTokens":0,"outputTokens":0,"modelCalls":0}}}"#),
            // The API routing slug can differ from the selected catalog key, including by effort.
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"large-routing-slug","modelId":"grok-large-reasoning-high","totalTokens":210000,"inputTokens":209500,"usage":{"inputTokens":209500,"outputTokens":500,"modelCalls":1}}}"#),
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"unknown-window","modelId":"unknown-routing-slug","totalTokens":220000,"inputTokens":219500,"usage":{"inputTokens":219500,"outputTokens":500,"modelCalls":1}}}"#)
        ]
        let stops = try await runResponses(responses, modelSelections: [1: "grok-small", 3: "grok-large-high", 4: "grok-unknown"])
        XCTAssertEqual(stops.count, 5)
        // Rendering must use the stored per-turn window, even if global discovery changes.
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        let viewModel = AgentModeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath, codexControllerFactory: { _, _, _, _, _, _ in
            preconditionFailure("Grok usage tests must not start Codex")
        })
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .grokBuild
        session.selectedModelRaw = "default"
        let sidebar = AgentRuntimeSidebarViewModel()
        let expectedCounts = [26278, 25827, 20000, 210_000, 220_000]
        // Zero is an explicit withdrawal, never a real context-window capacity.
        let expectedWindows = [1_000_000, 128_000, 128_000, 1_000_000, 0]
        for (index, stop) in stops.enumerated() {
            XCTAssertEqual(stop.contextUsedTokens, expectedCounts[index])
            XCTAssertEqual(stop.modelContextWindow, expectedWindows[index])
            viewModel.ingestNonCodexTurnFinalization(
                promptTokens: stop.promptTokens, completionTokens: stop.completionTokens,
                contextUsedTokens: stop.contextUsedTokens, modelContextWindow: stop.modelContextWindow, session: session
            )
            XCTAssertEqual(session.contextUsageSnapshot?.used, expectedCounts[index])
            XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
            XCTAssertNil(session.vouchedContextCount, "Finalization estimates remain ring-only, not exact occupancy")
            sidebar.update(items: [], codexUsage: session.codexContextUsage, selectedAgent: .grokBuild, selectedModelRaw: "default")
            let reportedWindow: Int? = expectedWindows[index] > 0 ? expectedWindows[index] : nil
            XCTAssertEqual(session.contextUsageSnapshot?.window, reportedWindow)
            XCTAssertEqual(sidebar.snapshot.contextWindowTokens, reportedWindow)
            XCTAssertEqual(sidebar.snapshot.effectiveContextWindowTokens, reportedWindow ?? 500_000)
            XCTAssertEqual(AgentModeViewModel.observationContextLoad(for: session)?.windowTokens, reportedWindow)
        }
        XCTAssertEqual(stops.first?.promptTokens, 139_056)
        XCTAssertEqual(stops.first?.completionTokens, 1200)
        // Assert the SAME session after the unknown model: no unrelated fresh snapshot can
        // hide a carried 128k/1M window or a context count rejected against that stale bound.
        XCTAssertNil(session.codexContextUsage?.modelContextWindow)
        XCTAssertEqual(sidebar.snapshot.usedTokens, 220_000)
        XCTAssertEqual(sidebar.snapshot.effectiveContextWindowTokens, 500_000)
    }

    @MainActor
    func testExplicitUnknownWindowClearsStoredBoundWithoutFreshCount() {
        let viewModel = AgentModeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath, codexControllerFactory: { _, _, _, _, _, _ in
            preconditionFailure("Grok usage tests must not start Codex")
        })
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .grokBuild
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 100_000,
            modelContextWindow: 128_000, session: session
        )
        let sidebar = AgentRuntimeSidebarViewModel()
        sidebar.update(items: [], codexUsage: session.codexContextUsage, selectedAgent: .grokBuild, selectedModelRaw: "default")
        let before = sidebar.snapshot
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 0, session: session
        )
        sidebar.update(items: [], codexUsage: session.codexContextUsage, selectedAgent: .grokBuild, selectedModelRaw: "default")
        XCTAssertEqual(session.contextUsageSnapshot?.used, 100_000)
        XCTAssertNil(session.contextUsageSnapshot?.window)
        XCTAssertNotEqual(sidebar.snapshot, before, "A window withdrawal must publish even when the count is unchanged")
        XCTAssertNil(sidebar.snapshot.contextWindowTokens)
        XCTAssertEqual(sidebar.snapshot.effectiveContextWindowTokens, 500_000)
        XCTAssertNil(AgentModeViewModel.observationContextLoad(for: session)?.windowTokens)
    }

    @MainActor
    func testMissingCurrentCountDoesNotSubstituteBillingAndLegacyLastCallRemainsBestEffort() async throws {
        let stops = try await runResponses([
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"missing","modelId":"grok-large","usage":{"inputTokens":139056,"cachedReadTokens":114304}}}"#),
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"legacy","modelId":"grok-large","inputTokens":25678,"usage":{"inputTokens":139056,"cachedReadTokens":114304}}}"#),
            json(#"{"stopReason":"end_turn","_meta":{"sessionId":"grok-context-fixture","promptId":"dropped","modelId":"grok-large","totalTokens":0,"inputTokens":180000,"usage":{"inputTokens":0}}}"#)
        ])
        XCTAssertEqual(stops.count, 3)
        let viewModel = AgentModeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath, codexControllerFactory: { _, _, _, _, _, _ in
            preconditionFailure("Grok usage tests must not start Codex")
        })
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .grokBuild
        for (index, stop) in stops.enumerated() {
            XCTAssertEqual(stop.contextUsedTokens, index == 1 ? 25678 : nil)
            viewModel.ingestNonCodexTurnFinalization(
                promptTokens: stop.promptTokens, completionTokens: stop.completionTokens,
                contextUsedTokens: stop.contextUsedTokens, modelContextWindow: stop.modelContextWindow, session: session
            )
            XCTAssertEqual(session.contextUsageSnapshot?.used, index == 0 ? nil : 25678)
            XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        }
    }

    func testReportedModelWindowsSurviveCatalogPersistenceIncludingVariants() async throws {
        let registry = AgentACPModelRegistry.shared
        let provider = GrokBuildACPAgentProvider(config: GrokBuildAgentConfig())
        guard case let .valid(models) = try provider.parseDirectSessionModelSnapshot(from: json(Self.modelResponse)) else {
            return XCTFail("Expected parsed model metadata")
        }
        XCTAssertTrue(registry.updateDiscoveredModels(models, for: .grokBuild))
        registry.test_clearMemoryPreservingStore(providerID: .grokBuild)
        await registry.test_warmStandardStore()
        let stored = try XCTUnwrap(registry.resolvedSnapshot(for: .grokBuild))
        for (raw, expected) in [("grok-large", 1_000_000), ("grok-large-high", 1_000_000), ("grok-small", 128_000)] {
            XCTAssertEqual(stored.option(matching: raw)?.contextWindowTokens, expected, raw)
        }
        XCTAssertNil(stored.option(matching: "grok-unknown")?.contextWindowTokens)
        XCTAssertNil(stored.option(matching: "grok-invalid")?.contextWindowTokens)
    }

    func testOtherACPProvidersKeepTheirExistingUsageMapping() async throws {
        let provider = OpenCodeACPAgentProvider(config: OpenCodeAgentConfig(
            commandName: "/usr/bin/true", includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false, cleanupLegacyPersistentConfig: false
        ))
        let request = ACPRunRequest(agentKind: .openCode, modelString: nil, workspacePath: nil, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        let mapped = await controller.messageStopResult(
            from: ["usage": ["inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 30, "cachedWriteTokens": 5]],
            sessionID: "fixture", stopReason: "end_turn"
        )
        XCTAssertEqual(mapped.promptTokens, 100)
        XCTAssertEqual(mapped.completionTokens, 20)
        XCTAssertEqual(mapped.contextUsedTokens, 135)
    }

    private static let fakeGrokScript = #"""
    #!/usr/bin/env python3
    import json
    import sys
    from pathlib import Path

    if "--help" in sys.argv:
        print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
        sys.exit(0)
    fixture = json.loads(Path(__file__).with_name("responses.json").read_text())
    responses = iter(fixture["responses"])
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if request_id is None:
            continue
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}
        elif method == "session/new":
            result = fixture["session"]
        elif method == "session/set_model":
            result = {"_meta": {"model": {"Ok": message["params"]["modelId"]}}}
        elif method == "session/prompt":
            result = next(responses)
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
    """# + "\n"
}
