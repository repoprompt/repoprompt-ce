import Foundation
import SwiftAnthropic
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class ProviderModelDiscoveryTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "ProviderModelDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func preserveSharedCatalogs() {
        let keys = ["CodexDynamicModelRecords", "ClaudeCodeDiscoveredModels", "AnthropicDiscoveredModels", "GrokDiscoveredChatModels"]
            .flatMap { [$0, $0 + ".savedSelectionMetadata"] }
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let liveModels = AgentCodexModelRegistry.shared.currentLiveModels()
        _ = AgentCodexModelRegistry.shared.updateLiveModels([])
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        addTeardownBlock {
            _ = AgentCodexModelRegistry.shared.updateLiveModels(liveModels)
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private func futureCodex(id: String = "future-choice", model: String = "gpt-9-future") -> CodexAppServerClient.RemoteModel {
        .init(
            id: id,
            model: model,
            displayName: "Future Model",
            description: "Fixture",
            isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: "max", description: "Max"), .init(reasoningEffort: "ultra", description: "Ultra")],
            defaultReasoningEffort: "max"
        )
    }

    func testDecodedCacheObservesExternalWritesEmptySnapshotsAndOtherSuites() throws {
        let first = try isolatedDefaults()
        let second = try isolatedDefaults()
        let cache = ProviderModelDiscoveryCache<String>(key: "models", identity: { $0 })
        cache.save(["old"], defaults: first)
        XCTAssertEqual(cache.current(defaults: first), ["old"])
        try first.set(JSONEncoder().encode(["new"]), forKey: "models")
        XCTAssertEqual(cache.current(defaults: first), ["new"])
        XCTAssertEqual(cache.remembered(defaults: first), ["new", "old"])
        cache.save([], defaults: first)
        XCTAssertTrue(cache.current(defaults: first).isEmpty)
        XCTAssertEqual(cache.remembered(defaults: first), ["new", "old"])
        cache.save(["other"], defaults: second)
        XCTAssertEqual(cache.remembered(defaults: second), ["other"])
        XCTAssertTrue(cache.current(defaults: first).isEmpty)
        XCTAssertEqual(cache.remembered(defaults: first), ["new", "old"])
    }

    func testFutureCodexIdentityEffortAndFastVariantsReachSharedMenusAndMCP() throws {
        preserveSharedCatalogs()
        _ = AgentCodexModelRegistry.shared.updateLiveModels([futureCodex()])
        let available = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
        let options = AgentModelCatalog.options(for: .codexExec, availability: available)
        for raw in ["future-choice-max", "future-choice-ultra", "gpt-9-future-fast-max", "gpt-9-future-fast-ultra"] {
            XCTAssertTrue(options.contains { $0.rawValue == raw }, raw)
            XCTAssertTrue(AIModel.modelsForProvider(.codex).contains { $0.modelName == raw }, raw)
            let specifier = CodexModelSpecifier(raw: raw)
            XCTAssertEqual(specifier.cliModelArgs, ["--model", "gpt-9-future"])
            let effort = raw.hasSuffix("ultra") ? "ultra" : "max"
            XCTAssertEqual(specifier.appServerEffortParam, effort)
            XCTAssertEqual(specifier.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=\(effort)"])
            XCTAssertEqual(specifier.appServerServiceTierParam, raw.contains("-fast-") ? "fast" : nil)
        }
        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: available).first { $0.agent == .codexExec })
        let future = try XCTUnwrap(discovery.models.first { $0.id == "gpt-9-future" })
        XCTAssertEqual(Set(future.supportedReasoningEfforts), [.max, .ultra])
        XCTAssertEqual(Set(future.startTargets.compactMap(\.reasoningEffort)), [.max, .ultra])
        XCTAssertEqual(future.name, "Future Model")
        XCTAssertEqual(options.first { $0.rawValue == "gpt-9-future-fast-max" }?.displayName, "Future Model Fast Max")
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-9-future-max").appServerEffortParam, "max")
    }

    func testAdvertisedCodexBaseWinsSuffixCollisionAndMetadataDoesNotInventEfforts() {
        let models = [
            futureCodex(id: "gpt-9", model: "gpt-9"),
            CodexAppServerClient.RemoteModel(id: "gpt-9-max", model: "gpt-9-max", displayName: "Base Max", description: "", isDefault: false, supportedReasoningEfforts: [], defaultReasoningEffort: nil)
        ]
        let records = CodexDynamicModelStore.canonicalRecords(from: models)
        let base = CodexModelSpecifier(raw: "gpt-9-max", records: records)
        XCTAssertEqual(base.baseModel, "gpt-9-max")
        XCTAssertNil(base.reasoningEffort)
        let option = CodexDynamicModelMapper.options(from: records).filter { $0.id == "gpt-9-max" }
        XCTAssertEqual(option.count, 1)
        XCTAssertNil(option.first?.reasoningEffort)
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-5.1-codex-max", records: []).reasoningEffort)
        XCTAssertNil(CodexModelSpecifier(raw: "default", records: records).baseModel)
    }

    func testCodexRefreshRemovesChoicesButRetainsSavedSelectionRouting() throws {
        let defaults = try isolatedDefaults()
        CodexDynamicModelStore.save([futureCodex()], defaults: defaults)
        CodexDynamicModelStore.save([], defaults: defaults)
        XCTAssertTrue(CodexDynamicModelStore.modelOptions(defaults: defaults).isEmpty)
        let saved = CodexModelSpecifier(raw: "future-choice-ultra", records: CodexDynamicModelStore.resolutionRecords(defaults: defaults))
        XCTAssertEqual(saved.appServerModelParam, "gpt-9-future")
        XCTAssertEqual(saved.appServerEffortParam, "ultra")
    }

    func testHistoricalCodexBaseCannotBeReusedAsAnEffortChoice() {
        preserveSharedCatalogs()
        let old = CodexAppServerClient.RemoteModel(id: "gpt-9-max", model: "gpt-9-max", displayName: "Original Base", description: "", isDefault: false, supportedReasoningEfforts: [], defaultReasoningEffort: nil)
        let oldFast = CodexAppServerClient.RemoteModel(id: "gpt-9-fast-ultra", model: "gpt-9-fast-ultra", displayName: "Original Fast Base", description: "", isDefault: false, supportedReasoningEfforts: [], defaultReasoningEffort: nil)
        CodexDynamicModelStore.save([old, oldFast])
        CodexDynamicModelStore.save([futureCodex(id: "gpt-9", model: "gpt-9")])
        let options = CodexDynamicModelStore.modelOptions()
        XCTAssertFalse(options.contains { $0.id == "gpt-9-max" })
        XCTAssertTrue(options.contains { $0.id == "gpt-9-ultra" })
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-9-max").baseModel, "gpt-9-max")
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-9-max").reasoningEffort)
        XCTAssertFalse(AIModel.modelsForProvider(.codex).contains { $0.modelName == "gpt-9-fast-ultra" })
        let availability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
        XCTAssertFalse(AgentModelCatalog.options(for: .codexExec, availability: availability).contains { $0.rawValue == "gpt-9-fast-ultra" })
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-9-fast-ultra").baseModel, "gpt-9-fast-ultra")
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-9-fast-ultra").reasoningEffort)
    }

    func testCodexDisplayNameCannotAdvertiseAnUnlistedEffort() throws {
        preserveSharedCatalogs()
        let model = CodexAppServerClient.RemoteModel(id: "future-base", model: "future-base", displayName: "Future High", description: "", isDefault: false, supportedReasoningEfforts: [], defaultReasoningEffort: nil)
        _ = AgentCodexModelRegistry.shared.updateLiveModels([model])
        let availability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
        let agent = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .codexExec })
        let discovered = try XCTUnwrap(agent.models.first { $0.id == "future-base" })
        XCTAssertEqual(discovered.name, "Future High")
        XCTAssertTrue(discovered.supportedReasoningEfforts.isEmpty)
        XCTAssertTrue(discovered.startTargets.allSatisfy { $0.reasoningEffort == nil })
    }

    func testGrokTextChatDiscoveryAddsNamesWithoutInferringEfforts() async throws {
        preserveSharedCatalogs()
        let client = FixtureHTTPClient(pages: [#"{"models":[{"id":"future-chat-high","input_modalities":["text","image"],"output_modalities":["text"]},{"id":"future-image","input_modalities":["text"],"output_modalities":["image"]},{"id":"unclassified"}]}"#])
        let names = try await GrokModelCatalog.fetch(apiKey: "fixture", client: client)
        XCTAssertEqual(names, ["future-chat-high"])
        XCTAssertTrue(GrokModelCatalog.save(names))
        XCTAssertFalse(GrokModelCatalog.save(names))
        let model = try XCTUnwrap(AIModel.modelsForProvider(.grok).first { $0.modelName == "future-chat-high" })
        XCTAssertNil(model.defaultReasoningEffort)
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
        XCTAssertTrue(AIModel.allModels().contains(model))
        GrokModelCatalog.save([])
        XCTAssertFalse(AIModel.modelsForProvider(.grok).contains(model))
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
    }

    func testClaudeAdvertisementReachesChatAgentRoleMenusAndMCPWithoutInventedEfforts() throws {
        preserveSharedCatalogs()
        let json = #"[{"value":"claude-future","displayName":"Future Claude","description":"Fixture","supportsEffort":true,"supportedEffortLevels":["low","max"]}]"#
        XCTAssertTrue(ClaudeDynamicModelStore.update(json: json))
        XCTAssertFalse(ClaudeDynamicModelStore.update(json: json))
        let availability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.claudeCode)
        let options = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        XCTAssertTrue(options.contains { $0.rawValue == "claude-future:max" })
        XCTAssertFalse(options.contains { $0.rawValue == "claude-future:high" })
        XCTAssertEqual(AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: "claude-future", agentKind: .claudeCode), [.low, .max])
        let model = try XCTUnwrap(AIModel.modelsForProvider(.claudeCode).first { $0.claudeCodeRuntimeSpecifierRaw == "claude-future:max" })
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
        let request = try ClaudeCodeProvider.resolveCLIModelSelection(for: model)
        XCTAssertEqual(request.modelArgument, "claude-future")
        XCTAssertEqual(request.effortLevel, .max)
        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .claudeCode })
        XCTAssertTrue(discovery.models.contains { $0.id == "claude-future" && $0.startTargets.count == 2 })
        XCTAssertNil(AIModel.fromModelName("claude_code__claude-future:high"))
    }

    func testClaudeMalformedRefreshRetainsSnapshotAndSuccessfulEmptyRefreshRemovesEligibility() throws {
        let defaults = try isolatedDefaults()
        let json = #"[{"value":"future","displayName":"Future","description":"","supportedEffortLevels":["max"]}]"#
        XCTAssertTrue(ClaudeDynamicModelStore.update(json: json, defaults: defaults))
        XCTAssertFalse(ClaudeDynamicModelStore.update(json: "malformed", defaults: defaults))
        XCTAssertEqual(ClaudeDynamicModelStore.records(defaults: defaults).count, 1)
        XCTAssertTrue(ClaudeDynamicModelStore.update(json: "[]", defaults: defaults))
        XCTAssertTrue(ClaudeDynamicModelStore.records(defaults: defaults).isEmpty)
        XCTAssertEqual(ClaudeDynamicModelStore.record(for: "future", defaults: defaults)?.efforts, [.max])
    }

    func testClaudeNativeRequestSuppressesUnadvertisedDefaultEffort() async throws {
        preserveSharedCatalogs()
        ClaudeDynamicModelStore.update(json: #"[{"value":"future","displayName":"Future","description":"","supportsEffort":false}]"#)
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false"),
            environmentResolver: FixtureClaudeResolver()
        )
        let request = try await controller.test_resolveApplyFlagSettingsRequest(model: "future", effortLevel: .high)
        let settings = try XCTUnwrap(request?["settings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, "future")
        XCTAssertNil(settings["effortLevel"])
        XCTAssertNil(ClaudeDynamicModelStore.effort(.high, forModel: "future"))
    }

    func testAnthropicCapabilitiesDriveTypedChoicesAndMessagesEncoding() throws {
        preserveSharedCatalogs()
        let records = AnthropicModelCatalog.parse([
            ["id": "claude-future", "display_name": "Future", "capabilities": [
                "effort": ["supported": true, "low": ["supported": true], "max": ["supported": true], "high": ["supported": false]],
                "thinking": ["supported": true, "types": ["adaptive": ["supported": true]]]
            ]],
            ["id": "claude-unknown", "display_name": "Unknown"]
        ])
        AnthropicModelCatalog.save(records)
        XCTAssertEqual(records.first?.efforts, [.low, .max])
        XCTAssertEqual(records.last?.efforts, [])
        let choice = AIModel.anthropicCustomReasoning(name: "claude-future", effort: .max)
        XCTAssertTrue(AIModel.modelsForProvider(.anthropic).contains(choice))
        XCTAssertTrue(AIModel.allModels().contains(choice))
        XCTAssertEqual(AIModel.fromModelName(choice.rawValue), choice)
        XCTAssertEqual(choice.modelName, "claude-future")
        XCTAssertFalse(AIModel.modelsForProvider(.anthropic).contains(.anthropicCustomReasoning(name: "claude-unknown", effort: .high)))
        for stream in [true, false] {
            let parameters = MessageParameter(model: .other(choice.modelName), messages: [], maxTokens: 4096, stream: stream)
            let request = try AnthropicModelRequest(parameters: parameters, effort: .max, adaptiveThinking: true).request(apiKey: "fixture", betaHeaders: [])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "claude-future")
            XCTAssertEqual(body["stream"] as? Bool, stream)
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "max")
            XCTAssertEqual(body["thinking"] as? [String: String], ["type": "adaptive"])
            XCTAssertNil(body["temperature"])
        }
        AnthropicModelCatalog.save([])
        XCTAssertFalse(AIModel.modelsForProvider(.anthropic).contains(choice))
        XCTAssertEqual(AnthropicModelCatalog.record(for: "claude-future")?.efforts, [.low, .max])
        XCTAssertEqual(AIModel.fromModelName(choice.rawValue), choice)
    }

    func testAnthropicPaginationAndFailureDoNotPublishPartialResults() async throws {
        let client = FixtureHTTPClient(pages: [
            #"{"data":[{"id":"future-one"}],"has_more":true,"last_id":"future-one"}"#,
            #"{"data":[{"id":"future-two"}],"has_more":false}"#
        ])
        let records = try await AnthropicModelCatalog.fetch(apiKey: "fixture", client: client)
        XCTAssertEqual(records.map(\.id), ["future-one", "future-two"])
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].url?.query?.contains("after_id=future-one") == true)
        let failing = FixtureHTTPClient(pages: [
            #"{"data":[{"id":"future-one"}],"has_more":true,"last_id":"future-one"}"#, "invalid"
        ])
        do {
            _ = try await AnthropicModelCatalog.fetch(apiKey: "fixture", client: failing)
            XCTFail("Malformed second page must fail the entire discovery")
        } catch {}
    }

    private struct FixtureClaudeResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(variant: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            .init(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    private actor FixtureHTTPClient: RepoPromptApp.HTTPClient {
        let pages: [String]
        var requests: [URLRequest] = []
        init(pages: [String]) {
            self.pages = pages
        }

        func data(for request: URLRequest) async throws -> RepoPromptApp.HTTPResponse {
            let index = requests.count
            requests.append(request)
            guard index < pages.count else { throw URLError(.badServerResponse) }
            return RepoPromptApp.HTTPResponse(data: Data(pages[index].utf8), http: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
            throw URLError(.unsupportedURL)
        }
    }
}
