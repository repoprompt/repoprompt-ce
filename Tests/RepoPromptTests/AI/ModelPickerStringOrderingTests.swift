import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class ModelPickerStringOrderingTests: XCTestCase {
    func testScalarOrderingUsesAsciiFoldThenRawScalarTieBreak() {
        XCTAssertEqual(
            ModelPickerStringOrdering.compare("GPT-5", "gpt-5", caseInsensitiveASCII: true),
            .orderedAscending
        )
        XCTAssertEqual(
            ["ı", "i", "I"].sorted { ModelPickerStringOrdering.precedes($0, $1) },
            ["I", "i", "ı"]
        )
        XCTAssertTrue(ModelPickerStringOrdering.precedes("gpt-5.6-sol-Low", "gpt-5.6-sol-low"))
    }

    func testAIModelSemanticPickerOrderingCoversGptVersionsServiceTierReasoningAndRawTieBreaks() {
        let models: [AIModel] = [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.6-sol-high"),
            .codexCustom(name: "gpt-5.4-low"),
            .codexCustom(name: "gpt-5.6-sol-low"),
            .codexCustom(name: "gpt-5.4-fast-low"),
            .codexCustom(name: "gpt-5.6-sol-Low")
        ]

        let sorted = AIModel.sortedForPicker(models).map(\.modelName)

        XCTAssertEqual(sorted, [
            "gpt-5.6-sol-Low",
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-high",
            "gpt-5.4-low",
            "gpt-5.4-fast-low",
            "gpt-5.4-fast-high",
            "gpt-5.2-high"
        ])
    }

    func testSemanticOrderingUsesFamilyBeforeDisplayNameAcrossFamilies() {
        let sorted = AIModel.sortedForPicker([
            .customProvider(name: "Aardvark", provider: "custom", model: "zzz-1"),
            .customProvider(name: "Zed", provider: "custom", model: "aaa-1")
        ])

        XCTAssertEqual(sorted.map(\.modelName), ["aaa-1", "zzz-1"])
    }

    func testStaleGeminiCLIPrefixedModelsAreRejectedForFallback() {
        XCTAssertNil(AIModel.fromModelName("gemini_cli_flash-2.5"))
        XCTAssertNil(AIModel.fromModelName(" gemini_cli_pro-3.1-preview "))
        XCTAssertEqual(AIModel.fromModelName("gemini-3-pro-preview"), .gemini3p1ProPreview)
    }

    func testClaudeCodePickerExposesFable5WithEffortVariantsFirst() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-fable-5")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-fable-5:xhigh")))
        XCTAssertEqual(
            AIModel.fromModelName("\(ClaudeCodeAIModelCatalog.rawPrefix)claude-fable-5:xhigh"),
            .claudeCodeModel(specifier: "claude-fable-5:xhigh")
        )

        let menu = AIModel.claudeCodeMenu(for: models)
        XCTAssertEqual(menu.groups.first?.baseModelRaw, "claude-fable-5")
        let fableGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-fable-5" })
        XCTAssertEqual(fableGroup.displayName, "Fable 5")
        XCTAssertTrue(fableGroup.options.contains { $0.displayName == "XHigh" })
    }

    func testClaudeCodePickerExposesSonnet5WithAllOfficialEffortVariants() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5:max")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5:xhigh")))
        XCTAssertEqual(
            AIModel.fromModelName("\(ClaudeCodeAIModelCatalog.rawPrefix)claude-sonnet-5:xhigh"),
            .claudeCodeModel(specifier: "claude-sonnet-5:xhigh")
        )

        let menu = AIModel.claudeCodeMenu(for: models)
        let sonnet5Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5Group.displayName, "Sonnet 5")
        XCTAssertEqual(sonnet5Group.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw), [
            "claude-sonnet-5:low",
            "claude-sonnet-5:medium",
            "claude-sonnet-5:high",
            "claude-sonnet-5:max",
            "claude-sonnet-5:xhigh"
        ])
        XCTAssertEqual(sonnet5Group.options.map(\.displayName), ["Low", "Medium", "High", "Max", "XHigh"])
    }

    func testClaudeCodeProviderResolvesSonnet5EffortSpecifierForCLI() throws {
        let maxSelection = try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-sonnet-5:max"))
        XCTAssertEqual(maxSelection.modelArgument, "claude-sonnet-5")
        XCTAssertEqual(maxSelection.effortLevel, .max)

        let xhighSelection = try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-sonnet-5:xhigh"))
        XCTAssertEqual(xhighSelection.modelArgument, "claude-sonnet-5")
        XCTAssertEqual(xhighSelection.effortLevel, .xhigh)
    }

    func testCodexReasoningEffortParsesExtendedEffortsWithoutChangingRecommendations() {
        XCTAssertEqual(CodexReasoningEffort.parse("max"), .max)
        XCTAssertEqual(CodexReasoningEffort.parse("maximum"), .max)
        XCTAssertEqual(CodexReasoningEffort.parse("ultra"), .ultra)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-max").baseModel, "gpt-5.6-sol")
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-max").reasoningEffort, .max)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-ultra").baseModel, "gpt-5.6-sol")
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-ultra").reasoningEffort, .ultra)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-max", agentKind: .codexExec), .gpt56SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-ultra", agentKind: .codexExec), .gpt56SolUltra)
        XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.6-sol-max"), .codexCliGpt56SolMax)
        XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.6-sol-ultra"), .codexCliGpt56SolUltra)
        XCTAssertEqual(AIModel.codexCliGpt56SolMax.defaultReasoningEffort, "max")
        XCTAssertEqual(AIModel.codexCliGpt56SolUltra.defaultReasoningEffort, "ultra")
    }

    func testCodexModelSpecifierDoesNotMisparseGpt51CodexMaxBase() {
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max")
        XCTAssertEqual(base.baseModel, "gpt-5.1-codex-max")
        XCTAssertNil(base.reasoningEffort)

        let low = CodexModelSpecifier(raw: "gpt-5.1-codex-max-low")
        XCTAssertEqual(low.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(low.reasoningEffort, .low)

        let high = CodexModelSpecifier(raw: "gpt-5.1-codex-max-high")
        XCTAssertEqual(high.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(high.reasoningEffort, .high)
    }

    func testAIModelPickerDoesNotTreatGpt51CodexMaxFamilyTokenAsMaxEffort() {
        let codexMaxFamilySorted = AIModel.sortedForPicker([
            .gpt5CodexXHigh,
            .gpt5CodexMed,
            .gpt5CodexHigh,
            .gpt5CodexLow
        ]).map(\.rawValue)

        XCTAssertEqual(codexMaxFamilySorted, [
            "gpt-5.1-codex-max-low",
            "gpt-5.1-codex-max",
            "gpt-5.1-codex-max-high",
            "gpt-5.1-codex-max-xhigh"
        ])

        let extendedEffortSorted = AIModel.sortedForPicker([
            .codexCliGpt56SolUltra,
            .codexCliGpt56SolMax,
            .codexCliGpt56SolXHigh
        ]).map(\.rawValue)

        XCTAssertEqual(extendedEffortSorted, [
            "codex_cli_gpt-5.6-sol-xhigh",
            "codex_cli_gpt-5.6-sol-max",
            "codex_cli_gpt-5.6-sol-ultra"
        ])
    }

    func testStripCodexReasoningSuffixIsFamilyAwareForUltraFastAndCodexMaxLabels() {
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Ultra"), "GPT-5.6 Sol")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast X-High"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max High"), "GPT-5.1 Codex Max")

        let strippedFastUltra = AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra")
        XCTAssertEqual("\(strippedFastUltra) Ultra", "GPT-5.6 Sol Fast Ultra")
        XCTAssertFalse("\(strippedFastUltra) Ultra".contains("Ultra Fast Ultra"))
    }

    func testUnsupportedMaxUltraAgentModelResolutionReturnsNilInsteadOfMediumFallback() {
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.1-codex-max", agentKind: .codexExec))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-luna-ultra", agentKind: .codexExec))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-preview-ultra", agentKind: .codexExec))
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-max", agentKind: .codexExec), .gpt56SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-ultra", agentKind: .codexExec), .gpt56SolUltra)
    }

    func testCodexPickerExposesExtendedEffortsOnlyWhereSupportedAndInOrder() {
        let models = AgentModel.modelsForAgent(.codexExec)
        guard let solXHighIndex = models.firstIndex(of: .gpt56SolXHigh),
              let solMaxIndex = models.firstIndex(of: .gpt56SolMax),
              let solUltraIndex = models.firstIndex(of: .gpt56SolUltra),
              let terraXHighIndex = models.firstIndex(of: .gpt56TerraXHigh),
              let terraMaxIndex = models.firstIndex(of: .gpt56TerraMax),
              let terraUltraIndex = models.firstIndex(of: .gpt56TerraUltra),
              let lunaXHighIndex = models.firstIndex(of: .gpt56LunaXHigh),
              let lunaMaxIndex = models.firstIndex(of: .gpt56LunaMax)
        else {
            XCTFail("Expected GPT-5.6 extended effort entries in Codex picker")
            return
        }
        XCTAssertLessThan(solXHighIndex, solMaxIndex)
        XCTAssertLessThan(solMaxIndex, solUltraIndex)
        XCTAssertLessThan(terraXHighIndex, terraMaxIndex)
        XCTAssertLessThan(terraMaxIndex, terraUltraIndex)
        XCTAssertLessThan(lunaXHighIndex, lunaMaxIndex)
        XCTAssertNil(AgentModel(rawValue: "gpt-5.6-luna-ultra"))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-luna-ultra", agentKind: .codexExec))
        XCTAssertNil(AIModel.fromModelName("codex_cli_gpt-5.6-luna-ultra"))
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-5.6-luna-ultra").reasoningEffort)
        XCTAssertTrue(AgentModel.gpt56SolMax.description.contains("choose intentionally"))
        XCTAssertTrue(AgentModel.gpt56SolUltra.description.contains("choose intentionally"))
    }

    func testGpt56DiscoveryTagsStayOnPriorLowAndHighRecommendationLevels() {
        XCTAssertEqual(AgentModel.gpt56SolLow.discoveryTags, [.fast, .exploration, .engineering])
        XCTAssertEqual(AgentModel.gpt56SolHigh.discoveryTags, [.complex, .engineering, .pair])
        XCTAssertEqual(AgentModel.gpt56SolMedium.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolXHigh.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolMax.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolUltra.discoveryTags, [])
    }

    func testDynamicCodexModelEvidenceIncludesUltraOnlyForSolAndTerra() throws {
        let options = CodexDynamicModelMapper.options(from: [
            dynamicCodexRecord(id: "gpt-5.6-sol", defaultEffort: "low", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            dynamicCodexRecord(id: "gpt-5.6-terra", defaultEffort: "medium", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            dynamicCodexRecord(id: "gpt-5.6-luna", defaultEffort: "medium", efforts: ["low", "medium", "high", "xhigh", "max"])
        ])

        func ids(for baseID: String) -> [String] {
            options.filter { $0.baseID == baseID }.map(\.id)
        }

        XCTAssertEqual(ids(for: "gpt-5.6-sol"), [
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-medium",
            "gpt-5.6-sol-high",
            "gpt-5.6-sol-xhigh",
            "gpt-5.6-sol-max",
            "gpt-5.6-sol-ultra"
        ])
        XCTAssertEqual(ids(for: "gpt-5.6-terra"), [
            "gpt-5.6-terra-low",
            "gpt-5.6-terra-medium",
            "gpt-5.6-terra-high",
            "gpt-5.6-terra-xhigh",
            "gpt-5.6-terra-max",
            "gpt-5.6-terra-ultra"
        ])
        XCTAssertEqual(ids(for: "gpt-5.6-luna"), [
            "gpt-5.6-luna-low",
            "gpt-5.6-luna-medium",
            "gpt-5.6-luna-high",
            "gpt-5.6-luna-xhigh",
            "gpt-5.6-luna-max"
        ])
        XCTAssertFalse(ids(for: "gpt-5.6-luna").contains("gpt-5.6-luna-ultra"))
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-sol-low" }).isDefault)
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-terra-medium" }).isDefault)
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-luna-medium" }).isDefault)
    }

    func testBestPracticeRecommendationsDoNotDefaultToMaxOrUltra() {
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelLabel, "GPT-5.6 Sol")
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-5.6-sol")
        let recommendedModelStrings = BestPracticeProfiles.all.compactMap(\.modelString)
        XCTAssertFalse(recommendedModelStrings.contains { $0.contains("-max") || $0.contains("-ultra") })
        XCTAssertFalse(BestPracticeProfiles.all.compactMap(\.agentModel).contains(.gpt56SolMax))
        XCTAssertFalse(BestPracticeProfiles.all.compactMap(\.agentModel).contains(.gpt56SolUltra))
        XCTAssertFalse(BestPracticeProfiles.codexVsOpenAIExplanation.contains("Sol XHigh for ChatGPT"))
    }

    func testSentryTelemetryModelFamilyIncludesGpt56() {
        XCTAssertEqual(SentryTelemetryBootstrap.ModelFamily.gpt56.rawValue, "gpt_5_6")
    }

    func testAIModelCodexMenuGroupsUseStableSemanticOrdering() {
        let groups = AIModel.codexMenuGroups(for: [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.6-sol-high"),
            .codexCustom(name: "gpt-5.4-low"),
            .codexCustom(name: "gpt-5.6-sol-low"),
            .codexCustom(name: "gpt-5.4-fast-low"),
            .codexCustom(name: "gpt-5.6-sol-Low")
        ])

        XCTAssertEqual(groups.map(\.baseModelID), [
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])
        XCTAssertEqual(
            groups.first { $0.baseModelID == "gpt-5.6-sol" }?.models.map(\.modelName),
            ["gpt-5.6-sol-Low", "gpt-5.6-sol-low", "gpt-5.6-sol-high"]
        )
    }

    func testAgentModelCatalogCodexMenuUsesStableSemanticOrdering() {
        let menu = AgentModelCatalog.codexMenu(for: [
            option(raw: AgentModel.defaultModel.rawValue, displayName: AgentModel.defaultModel.displayName, placeholderDefault: true),
            option(raw: "gpt-5.2-high", displayName: "GPT-5.2 High"),
            option(raw: "gpt-5.4-fast-high", displayName: "GPT-5.4 Fast High"),
            option(raw: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High"),
            option(raw: "gpt-5.4-low", displayName: "GPT-5.4 Low"),
            option(raw: "gpt-5.6-sol-low", displayName: "GPT-5.6 Sol Low"),
            option(raw: "gpt-5.4-fast-low", displayName: "GPT-5.4 Fast Low"),
            option(raw: "gpt-5.6-sol-Low", displayName: "GPT-5.6 Sol Low")
        ])

        XCTAssertEqual(menu.defaultOption?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertEqual(menu.groups.map(\.baseModelID), [
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])
        XCTAssertEqual(
            menu.groups.first { $0.baseModelID == "gpt-5.6-sol" }?.options.map(\.rawValue),
            ["gpt-5.6-sol-Low", "gpt-5.6-sol-low", "gpt-5.6-sol-high"]
        )
    }

    @MainActor
    func testCollapsedCodexOptionsUseStableSemanticOrderingAndPreserveDefaults() throws {
        let collapsed: [AgentModelOption] = CodexAgentModeCoordinator.test_collapseCodexModelOptions([
            option(raw: AgentModel.defaultModel.rawValue, displayName: AgentModel.defaultModel.displayName, placeholderDefault: true),
            option(raw: "gpt-5.2-high", displayName: "GPT-5.2 High"),
            option(raw: "gpt-5.4-fast-high", displayName: "GPT-5.4 Fast High"),
            option(raw: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High", providerDefault: true),
            option(raw: "gpt-5.4-low", displayName: "GPT-5.4 Low"),
            option(raw: "gpt-5.6-sol-low", displayName: "GPT-5.6 Sol Low"),
            option(raw: "gpt-5.4-fast-low", displayName: "GPT-5.4 Fast Low")
        ])

        XCTAssertEqual(collapsed.map(\.rawValue), [
            AgentModel.defaultModel.rawValue,
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])

        let gpt56Sol = try XCTUnwrap(collapsed.first { $0.rawValue == "gpt-5.6-sol" })
        XCTAssertEqual(gpt56Sol.supportedReasoningEfforts, [CodexReasoningEffort.low, .high])
        XCTAssertEqual(gpt56Sol.defaultReasoningEffort, .high)
        XCTAssertEqual(gpt56Sol.isProviderDefault, true)
    }

    private func dynamicCodexRecord(
        id: String,
        defaultEffort: String,
        efforts: [String]
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: id,
            description: id,
            isDefault: true,
            supportedReasoningEfforts: efforts.map {
                CodexDynamicReasoningRecord(reasoningEffort: $0, description: "\($0) effort")
            },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func option(
        raw: String,
        displayName: String,
        placeholderDefault: Bool = false,
        providerDefault: Bool = false,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: raw,
            displayName: displayName,
            description: nil,
            isPlaceholderDefault: placeholderDefault,
            isProviderDefault: providerDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort
        )
    }
}
