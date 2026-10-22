import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildContextUsageTests: XCTestCase {
    /// Synthetic ACP payload reconstructed from #1325's observed counts and Grok source
    /// 2bdd1d6a, mvp_agent::build_prompt_response_meta. Not a captured wire recording.
    private static let multiCallResponse = #"{"stopReason":"end_turn","_meta":{"modelId":"grok-4.7","inputTokens":25678,"cachedReadTokens":25600,"usage":{"inputTokens":139056,"outputTokens":1200,"cachedReadTokens":114304,"cacheCreationTokens":0,"modelCalls":6}}}"#

    private func result(_ response: [String: Any], providerID: ACPProviderID = .grokBuild) async throws -> AIStreamResult {
        let directory = try makeTestDirectory()
        let executable = directory.appendingPathComponent("grok")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider: any ACPAgentProvider = providerID == .grokBuild
            ? GrokBuildACPAgentProvider(config: GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false))
            : OpenCodeACPAgentProvider(config: OpenCodeAgentConfig(commandName: "/usr/bin/true", includeRepoPromptMCPServer: false, includeManagedConfigOverlay: false, cleanupLegacyPersistentConfig: false))
        let request = ACPRunRequest(
            agentKind: providerID == .grokBuild ? .grokBuild : .openCode,
            modelString: nil, workspacePath: nil, resumeSessionID: nil,
            attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        return await controller.messageStopResult(from: response, sessionID: "fixture", stopReason: "end_turn")
    }

    @MainActor
    func testLastCallPromptFeedsEstimatorWithoutChangingBilling() async throws {
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.multiCallResponse.utf8)) as? [String: Any])
        let first = try await result(response)
        XCTAssertEqual(first.promptTokens, 139_056)
        XCTAssertEqual(first.completionTokens, 1200)
        XCTAssertEqual(first.contextUsedTokens, 25678)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .grokBuild
        let estimator = ACPContextUsageEstimator()
        estimator.ingestTurnFinalizationSignal(contextUsedTokens: first.contextUsedTokens, modelContextWindow: 500_000, session: session)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 25678)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)

        response["_meta"] = ["inputTokens": 25811, "usage": ["inputTokens": 25811, "cachedReadTokens": 25600]]
        let next = try await result(response)
        estimator.ingestTurnFinalizationSignal(contextUsedTokens: next.contextUsedTokens, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 25811)

        response["_meta"] = ["usage": ["inputTokens": 139_056, "cachedReadTokens": 114_304]]
        let missing = try await result(response)
        XCTAssertNil(missing.contextUsedTokens)
        estimator.ingestTurnFinalizationSignal(contextUsedTokens: missing.contextUsedTokens, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 25811)
        let freshSession = AgentTabSession(tabID: UUID())
        freshSession.selectedAgent = .grokBuild
        estimator.ingestTurnFinalizationSignal(contextUsedTokens: missing.contextUsedTokens, modelContextWindow: nil, session: freshSession)
        XCTAssertNil(freshSession.contextUsageSnapshot)
    }

    @MainActor
    func testReportedModelWindowsSurviveRegistryAndFollowSelection() async {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .grokBuild)
        defer { registry.test_reset(providerID: .grokBuild) }
        let provider = GrokBuildACPAgentProvider(config: GrokBuildAgentConfig())
        let response: [String: Any] = ["models": [
            "currentModelId": "grok-large",
            "availableModels": [
                ["modelId": "grok-large", "_meta": ["totalContextTokens": 1_000_000, "supportsReasoningEffort": true, "reasoningEfforts": [["id": "high", "value": "high"]]]],
                ["modelId": "grok-small", "_meta": ["totalContextTokens": 128_000]],
                ["modelId": "grok-unknown"],
                ["modelId": "grok-invalid", "_meta": ["totalContextTokens": -1]]
            ] as [[String: Any]]
        ]]
        guard case let .valid(models) = provider.parseDirectSessionModelSnapshot(from: response) else {
            return XCTFail("Expected parsed model metadata")
        }
        XCTAssertTrue(registry.updateDiscoveredModels(models, for: .grokBuild))
        // Exercise Codable persistence as well as the registry's canonicalization.
        registry.test_clearMemoryPreservingStore(providerID: .grokBuild)
        await registry.test_warmStandardStore()
        XCTAssertNotNil(registry.resolvedSnapshot(for: .grokBuild))
        for (raw, expected) in [("grok-large", 1_000_000), ("grok-large-high", 1_000_000), ("grok-small", 128_000), ("grok-unknown", 500_000), ("grok-invalid", 500_000)] {
            var snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot()
            snapshot.selectedAgent = .grokBuild
            snapshot.selectedModelRaw = raw
            XCTAssertEqual(snapshot.effectiveContextWindowTokens, expected, raw)
        }
    }

    func testOtherACPProvidersKeepTheirExistingUsageMapping() async throws {
        let mapped = try await result(["usage": ["inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 30, "cachedWriteTokens": 5]], providerID: .openCode)
        XCTAssertEqual(mapped.promptTokens, 100)
        XCTAssertEqual(mapped.completionTokens, 20)
        XCTAssertEqual(mapped.contextUsedTokens, 135)
    }
}
