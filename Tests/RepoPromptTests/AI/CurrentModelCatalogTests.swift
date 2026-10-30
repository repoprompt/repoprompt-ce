import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Coverage for the September 2026 built-in catalog refresh: GPT-6.1 Sol / GPT-6 Astra / Luna / Sol
/// and Claude Sonnet 5.5 / Opus 5.5 / Fable 5.1 / Mythos 5.1 across every built-in surface.
final class CurrentModelCatalogTests: XCTestCase {
    // MARK: Codex CLI (chat)

    func testCodexCLIGPT6EntriesRoundTripWithExpectedEfforts() {
        let expectations: [(AIModel, String, String, String)] = [
            (.codexCliGpt61SolLow, "codex_cli_gpt-6.1-sol-low", "gpt-6.1-sol", "low"),
            (.codexCliGpt61SolMedium, "codex_cli_gpt-6.1-sol-medium", "gpt-6.1-sol", "medium"),
            (.codexCliGpt61SolHigh, "codex_cli_gpt-6.1-sol-high", "gpt-6.1-sol", "high"),
            (.codexCliGpt61SolXHigh, "codex_cli_gpt-6.1-sol-xhigh", "gpt-6.1-sol", "xhigh"),
            (.codexCliGpt61SolMax, "codex_cli_gpt-6.1-sol-max", "gpt-6.1-sol", "max"),
            (.codexCliGpt61SolUltra, "codex_cli_gpt-6.1-sol-ultra", "gpt-6.1-sol", "ultra"),
            (.codexCliGpt6AstraLow, "codex_cli_gpt-6-astra-low", "gpt-6-astra", "low"),
            (.codexCliGpt6AstraMax, "codex_cli_gpt-6-astra-max", "gpt-6-astra", "max"),
            (.codexCliGpt6LunaLow, "codex_cli_gpt-6-luna-low", "gpt-6-luna", "low"),
            (.codexCliGpt6LunaMax, "codex_cli_gpt-6-luna-max", "gpt-6-luna", "max"),
            (.codexCliGpt6SolMedium, "codex_cli_gpt-6-sol-medium", "gpt-6-sol", "medium"),
            (.codexCliGpt6SolMax, "codex_cli_gpt-6-sol-max", "gpt-6-sol", "max")
        ]
        let codexModels = AIModel.modelsForProvider(.codex)
        for (model, raw, base, effort) in expectations {
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(AIModel.fromModelName(raw), model, raw)
            XCTAssertEqual(model.modelName, base, raw)
            XCTAssertEqual(model.defaultReasoningEffort, effort, raw)
            XCTAssertEqual(model.providerType, .codex, raw)
            XCTAssertTrue(model.displayName.hasPrefix("CLI·GPT-6"), raw)
            if CodexDynamicModelStore.load().isEmpty {
                XCTAssertTrue(codexModels.contains(model), raw)
            }
        }
    }

    func testCodexSpecifierDecodesGPT6ExtendedEffortsWithoutDiscovery() {
        let solUltra = CodexModelSpecifier(raw: "gpt-6.1-sol-ultra", discoveredRecords: [])
        XCTAssertEqual(solUltra.baseModel, "gpt-6.1-sol")
        XCTAssertEqual(solUltra.reasoningEffort, .ultra)

        let astraMax = CodexModelSpecifier(raw: "gpt-6-astra-max", discoveredRecords: [])
        XCTAssertEqual(astraMax.baseModel, "gpt-6-astra")
        XCTAssertEqual(astraMax.reasoningEffort, .max)

        // Astra is not advertised with Ultra; an unknown suffix stays part of the base ID.
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-6-astra-ultra", discoveredRecords: []).reasoningEffort)
    }

    // MARK: Codex Agent Mode

    func testAgentModeCodexCatalogListsGPT6FamilyAndResolvesSelections() {
        let codexModels = AgentModel.modelsForAgent(.codexExec)
        for model: AgentModel in [
            .gpt61SolLow, .gpt61SolMedium, .gpt61SolHigh, .gpt61SolXHigh, .gpt61SolMax, .gpt61SolUltra,
            .gpt6AstraLow, .gpt6AstraMedium, .gpt6AstraHigh, .gpt6AstraXHigh, .gpt6AstraMax,
            .gpt6LunaLow, .gpt6LunaMax, .gpt6SolLow, .gpt6SolMax
        ] {
            XCTAssertTrue(codexModels.contains(model), model.rawValue)
            XCTAssertEqual(model.contextWindowTokens, 1_050_000, model.rawValue)
            XCTAssertTrue(model.isExtendedContext, model.rawValue)
        }
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6.1-sol-high", agentKind: .codexExec), .gpt61SolHigh)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6.1-sol", agentKind: .codexExec), .gpt61SolMedium)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-astra-max", agentKind: .codexExec), .gpt6AstraMax)
        XCTAssertEqual(AgentModel.gpt61SolHigh.discoveryTags, [.complex, .engineering, .pair, .extendedContext])
    }

    func testNewestSolFamilyIsGPT61AmongStaticCodexOptions() throws {
        let options = AgentModel.modelsForAgent(.codexExec).map {
            AgentModelOption(rawValue: $0.rawValue, displayName: $0.displayName, description: nil, isDefault: false)
        }
        let sol = try XCTUnwrap(AgentModelCatalog.preferredCodexFamilyOption("sol", from: options))
        XCTAssertEqual(CodexModelSpecifier(raw: sol.rawValue, discoveredRecords: []).baseModel, "gpt-6.1-sol")
        let luna = try XCTUnwrap(AgentModelCatalog.preferredCodexFamilyOption("luna", from: options))
        XCTAssertEqual(CodexModelSpecifier(raw: luna.rawValue, discoveredRecords: []).baseModel, "gpt-6-luna")
    }

    // MARK: Direct OpenAI API

    func testDirectOpenAIGPT6EntriesUseResponsesAPIWithEfforts() {
        let expectations: [(AIModel, String, String, String)] = [
            (.gpt61Sol, "gpt-6.1-sol", "gpt-6.1-sol", "medium"),
            (.gpt61SolLow, "gpt-6.1-sol-low", "gpt-6.1-sol", "low"),
            (.gpt61SolHigh, "gpt-6.1-sol-high", "gpt-6.1-sol", "high"),
            (.gpt61SolXHigh, "gpt-6.1-sol-xhigh", "gpt-6.1-sol", "xhigh"),
            (.gpt61SolMax, "gpt-6.1-sol-max", "gpt-6.1-sol", "max"),
            (.gpt61Terra, "gpt-6.1-terra", "gpt-6.1-terra", "medium"),
            (.gpt61TerraNone, "gpt-6.1-terra-none", "gpt-6.1-terra", "none"),
            (.gpt61TerraLow, "gpt-6.1-terra-low", "gpt-6.1-terra", "low"),
            (.gpt61TerraHigh, "gpt-6.1-terra-high", "gpt-6.1-terra", "high"),
            (.gpt61TerraXHigh, "gpt-6.1-terra-xhigh", "gpt-6.1-terra", "xhigh"),
            (.gpt61TerraMax, "gpt-6.1-terra-max", "gpt-6.1-terra", "max"),
            (.gpt6Astra, "gpt-6-astra", "gpt-6-astra", "medium"),
            (.gpt6AstraMax, "gpt-6-astra-max", "gpt-6-astra", "max"),
            (.gpt6Luna, "gpt-6-luna", "gpt-6-luna", "medium"),
            (.gpt6LunaLow, "gpt-6-luna-low", "gpt-6-luna", "low"),
            (.gpt6Sol, "gpt-6-sol", "gpt-6-sol", "medium")
        ]
        let openAIModels = AIModel.modelsForProvider(.openAI)
        for (model, raw, apiName, effort) in expectations {
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(AIModel.fromModelName(raw), model, raw)
            XCTAssertEqual(model.modelName, apiName, raw)
            XCTAssertEqual(model.providerType, .openAI, raw)
            XCTAssertTrue(model.usesResponsesAPI, raw)
            XCTAssertEqual(model.defaultReasoningEffort, effort, raw)
            XCTAssertTrue(openAIModels.contains(model), raw)
        }
    }

    // MARK: Direct Anthropic API

    func testDirectAnthropicClaude5EntriesAreAdaptiveThinkingOnly() {
        let expectations: [(AIModel, String)] = [
            (.claudeSonnet55, "claude-sonnet-5-5"),
            (.claudeSonnet5, "claude-sonnet-5"),
            (.claudeOpus55, "claude-opus-5-5"),
            (.claudeOpus5, "claude-opus-5"),
            (.claudeFable51, "claude-fable-5-1"),
            (.claudeMythos51, "claude-mythos-5-1")
        ]
        let anthropicModels = AIModel.modelsForProvider(.anthropic)
        for (model, raw) in expectations {
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(AIModel.fromModelName(raw), model, raw)
            XCTAssertEqual(model.modelName, raw)
            XCTAssertEqual(model.providerType, .anthropic, raw)
            XCTAssertTrue(anthropicModels.contains(model), raw)
            XCTAssertTrue(AnthropicProvider.usesAdaptiveThinkingOnly(model.modelName), raw)
        }
        XCTAssertTrue(AIModel.claudeMythos51.displayName.contains("Restricted"))
        // Pre-5.x models keep the legacy budget_tokens / temperature request shape.
        for legacy in ["claude-opus-4-6", "claude-sonnet-4-5-20250929", "claude-haiku-4-5", "claude-sonnet-4-5-20250929-thinking"] {
            XCTAssertFalse(AnthropicProvider.usesAdaptiveThinkingOnly(legacy), legacy)
        }
    }

    // MARK: OpenRouter

    func testOpenRouterPresetsUseDottedVersionSlugs() {
        let expectations: [(AIModel, String)] = [
            (.openrouterGpt61Sol, "openai/gpt-6.1-sol"),
            (.openrouterGpt6Astra, "openai/gpt-6-astra"),
            (.openrouterGpt6Luna, "openai/gpt-6-luna"),
            (.openrouterClaudeSonnet55, "anthropic/claude-sonnet-5.5"),
            (.openrouterClaudeOpus55, "anthropic/claude-opus-5.5"),
            (.openrouterClaudeFable51, "anthropic/claude-fable-5.1")
        ]
        let openRouterModels = AIModel.modelsForProvider(.openRouter)
        for (model, slug) in expectations {
            XCTAssertEqual(model.rawValue, slug)
            XCTAssertEqual(model.modelName, slug)
            XCTAssertEqual(AIModel.fromModelName(slug), model, slug)
            XCTAssertEqual(model.providerType, .openRouter, slug)
            XCTAssertTrue(openRouterModels.contains(model), slug)
        }
    }

    // MARK: Defaults

    func testPriorityListsPromoteGPT61SolAheadOfGPT56Sol() throws {
        for list in [AIModel.simpleDiffPriority, AIModel.mediumDiffPriority, AIModel.highDiffPriority] {
            let gpt61 = try XCTUnwrap(list.firstIndex { $0.modelName == "gpt-6.1-sol" && $0.providerType == .codex })
            let gpt56 = try XCTUnwrap(list.firstIndex { $0.modelName == "gpt-5.6-sol" && $0.providerType == .codex })
            XCTAssertLessThan(gpt61, gpt56)
            let sonnet55 = try XCTUnwrap(list.firstIndex(of: .claudeSonnet55))
            let sonnet45 = try XCTUnwrap(list.firstIndex(of: .claude4Sonnet))
            XCTAssertLessThan(sonnet55, sonnet45)
            XCTAssertFalse(list.contains(.claudeMythos51))
        }
        XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.agentModel, .gpt61SolHigh)
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-6.1-sol")
    }
}

final class OpenAIProModeTests: XCTestCase {
    private let variants: [(AIModel, String)] = [
        (.gpt6AstraProLow, "low"),
        (.gpt6AstraPro, "medium"),
        (.gpt6AstraProHigh, "high"),
        (.gpt6AstraProXHigh, "xhigh"),
        (.gpt6AstraProMax, "max")
    ]

    func testProSelectionsRoundTripWithoutChangingTheAPIModelIdentity() {
        let catalog = AIModel.modelsForProvider(.openAI)
        for (model, effort) in variants {
            XCTAssertTrue(catalog.contains(model))
            XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
            XCTAssertEqual(model.modelName, "gpt-6-astra")
            XCTAssertEqual(model.providerType, .openAI)
            XCTAssertTrue(model.usesResponsesAPI)
            XCTAssertFalse(model.canStream)
            XCTAssertEqual(model.openAIReasoningMode, "pro")
            XCTAssertEqual(model.defaultReasoningEffort, effort)
            XCTAssertNotEqual(model, AIModel.gpt6Astra)
            XCTAssertTrue(model.displayName.contains("Astra Pro"))
        }
        for model: AIModel in [.gpt6Astra, .gpt6AstraMax, .gpt61Sol, .gpt54Pro, .codexCliGpt6AstraMax] {
            XCTAssertNil(model.openAIReasoningMode, model.rawValue)
        }
    }

    func testProAliasesAreExcludedFromAutomaticAzureOfferingsWithoutDroppingExplicitSelections() throws {
        let azureModelNames = Set(AIModel.modelsForProvider(.azure).map(\.modelName))
        let defaultIDs = Set(AzureOpenAIProvider.defaultModelDescriptors.map(\.id))
        XCTAssertTrue(azureModelNames.contains(AIModel.gpt6Astra.rawValue))
        XCTAssertTrue(defaultIDs.contains(AIModel.gpt6Astra.rawValue))

        let explicit = variants.map { model, _ in
            AzureOpenAIConfiguration.ModelDescriptor(
                id: model.rawValue, displayName: "My deployment", endpoint: .responses,
                supportsStreaming: false, baseModelID: model.rawValue,
                supportsChatCompletions: false, supportsResponses: true
            )
        }
        let merged = AzureOpenAIProvider.mergedWithDefaultDescriptors(explicit)
        for (model, _) in variants {
            XCTAssertFalse(azureModelNames.contains(model.rawValue), model.rawValue)
            XCTAssertFalse(defaultIDs.contains(model.rawValue), model.rawValue)

            let retained = try XCTUnwrap(merged.first { $0.id == model.rawValue })
            XCTAssertEqual(retained.baseModelID, model.rawValue)
            XCTAssertEqual(retained.endpoint, .responses)
            XCTAssertEqual(retained.supportsStreaming, false)

            let storedSelection = AIModel.azureCustom(name: model.rawValue).rawValue
            XCTAssertEqual(AIModel.fromModelName(storedSelection)?.rawValue, storedSelection)
        }
    }

    func testForegroundAndBackgroundRequestsPreserveEffortAndOtherSDKFields() throws {
        let provider = OpenAIProvider(apiKey: "test-key", configuredMaxTokens: 4096)
        let message = AIMessage(systemPrompt: "Review carefully", userMessage: "Find defects")
        for (model, effort) in variants {
            for stream in [false, true] {
                let parameters = try provider.buildForegroundResponseParameters(message, model: model, maxTokens: 4096, stream: stream)
                let request = try provider.buildProResponseRequest(parameters, model: model)
                let body = try json(request)
                let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
                XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
                XCTAssertEqual(reasoning["mode"] as? String, "pro")
                XCTAssertEqual(reasoning["effort"] as? String, effort)
                XCTAssertEqual(reasoning["summary"] as? String, stream ? "auto" : nil)
                XCTAssertEqual(body["stream"] as? Bool, stream)
                XCTAssertEqual(body["instructions"] as? String, "Review carefully")
                XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
                XCTAssertNotNil(body["input"])
                XCTAssertNil(body["temperature"])
            }
            let parameters = try provider.buildBackgroundResponseParameters(message, model: model, maxTokens: 4096)
            let body = try json(provider.buildProResponseRequest(parameters, model: model))
            XCTAssertEqual(body["background"] as? Bool, true)
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["mode"] as? String, "pro")
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, effort)
        }
    }

    func testProModePreservesExplicitServiceTierAndCustomEndpoint() throws {
        let model = AIModel.openAIServiceTierVariant(base: .gpt6AstraProMax, tier: "flex")
        XCTAssertFalse(model.canStream)
        let provider = OpenAIProvider(apiKey: "test-key", baseURL: URL(string: "https://example.test/proxy"), overrideVersion: "v4")
        let parameters = try provider.buildForegroundResponseParameters(AIMessage(systemPrompt: "", userMessage: "review"), model: model, maxTokens: nil, stream: false)
        let request = try provider.buildProResponseRequest(parameters, model: model)
        let body = try json(request)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/proxy/v4/responses")
        XCTAssertEqual(body["service_tier"] as? String, "flex")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["mode"] as? String, "pro")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "max")
        XCTAssertNil(body["max_output_tokens"])
    }

    func testStandardRequestRemainsUnchangedAndCannotUseProAdapter() throws {
        let provider = OpenAIProvider(apiKey: "test-key")
        let parameters = try provider.buildForegroundResponseParameters(AIMessage(systemPrompt: "", userMessage: "review"), model: .gpt6AstraMax, maxTokens: nil, stream: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any])
        XCTAssertNil((body["reasoning"] as? [String: Any])?["mode"])
        XCTAssertThrowsError(try provider.buildProResponseRequest(parameters, model: .gpt6AstraMax))
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
