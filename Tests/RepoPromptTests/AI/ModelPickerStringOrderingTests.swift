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
    }

    func testSemanticOrderingUsesVersionEffortAndFamilyBeforeDisplayName() {
        let codexModels: [AIModel] = [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.4-low")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(codexModels).map(\.modelName), [
            "gpt-5.4-low",
            "gpt-5.4-fast-high",
            "gpt-5.2-high"
        ])

        let customModels: [AIModel] = [
            .customProvider(name: "Aardvark", provider: "custom", model: "zzz-1"),
            .customProvider(name: "Zed", provider: "custom", model: "aaa-1")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(customModels).map(\.modelName), ["aaa-1", "zzz-1"])
    }

    func testCodexMaxFamilyTokenIsNotParsedAsReasoningEffort() {
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max")
        XCTAssertEqual(base.baseModel, "gpt-5.1-codex-max")
        XCTAssertNil(base.reasoningEffort)

        let high = CodexModelSpecifier(raw: "gpt-5.1-codex-max-high")
        XCTAssertEqual(high.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(high.reasoningEffort, .high)
    }

    func testDisplaySuffixStrippingDistinguishesFamilyTokensFromEffortTokens() {
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max High"), "GPT-5.1 Codex Max")
    }

    func testAstraSelectionsRoundTripAndProduceSeparateModelAndEffortArguments() throws {
        let efforts: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh, .max, .ultra]
        for effort in efforts {
            let raw = "gpt-6-astra-\(effort.rawValue)"
            let agentModel = try XCTUnwrap(AgentModel.resolvedModel(forRaw: raw, agentKind: .codexExec))
            XCTAssertEqual(agentModel.rawValue, raw)
            XCTAssertTrue(AgentModel.modelsForAgent(.codexExec).contains(agentModel))
            XCTAssertEqual(try JSONDecoder().decode(AgentModel.self, from: JSONEncoder().encode(agentModel)), agentModel)

            let model = try XCTUnwrap(AIModel.fromModelName("codex_cli_\(raw)"))
            XCTAssertEqual(model.providerType, .codex)
            XCTAssertEqual(model.modelName, "gpt-6-astra")
            XCTAssertEqual(model.defaultReasoningEffort, effort.rawValue)
            XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)

            for tier in ["", "-fast"] {
                let specifier = CodexModelSpecifier(raw: "gpt-6-astra\(tier)-\(effort.rawValue)")
                XCTAssertEqual(specifier.cliModelArgs, ["--model", "gpt-6-astra"])
                XCTAssertEqual(specifier.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=\(effort.rawValue)"])
                XCTAssertEqual(specifier.appServerModelParam, "gpt-6-astra")
                XCTAssertEqual(specifier.appServerEffortParam, effort.rawValue)
                XCTAssertEqual(specifier.appServerServiceTierParam, tier.isEmpty ? nil : "fast")
            }
        }
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-astra", agentKind: .codexExec), .gpt6AstraMedium)
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-6-astra-preview-ultra").reasoningEffort)
    }

    func testAstraPickerGroupsKeepAllEffortsTogetherAndSortBeforeGPT5() {
        let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
        let models: [AIModel] = efforts.reversed().flatMap { effort in
            [AIModel.codexCustom(name: "gpt-6-astra-\(effort)"), .codexCustom(name: "gpt-6-astra-fast-\(effort)")]
        } + [.codexCliGpt56SolHigh]
        let groups = AIModel.codexMenuGroups(for: models)
        XCTAssertEqual(groups.map(\.baseModelID), ["gpt-6-astra", "gpt-6-astra-fast", "gpt-5.6-sol"])
        XCTAssertEqual(groups[0].displayName, "GPT-6 Astra")
        XCTAssertEqual(groups[1].displayName, "GPT-6 Astra Fast")
        XCTAssertEqual(groups[0].models.map(\.defaultReasoningEffort), efforts)

        let options = models.map { model in
            AgentModelOption(rawValue: model.modelName, displayName: model.displayName, description: nil, isDefault: false)
        }
        let menu = AgentModelCatalog.codexMenu(for: options)
        XCTAssertEqual(menu.groups.map(\.baseModelID), ["gpt-6-astra", "gpt-6-astra-fast", "gpt-5.6-sol"])
        XCTAssertEqual(menu.groups[0].options.map(\.rawValue), efforts.map { "gpt-6-astra-\($0)" })
        XCTAssertEqual(menu.groups[1].options.map(\.rawValue), efforts.map { "gpt-6-astra-fast-\($0)" })
    }

    func testLiveAstraCataloguePreservesDefaultAndSynthesizesFastEfforts() {
        let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
        let remote = CodexAppServerClient.RemoteModel(
            id: "gpt-6-astra", model: "gpt-6-astra", displayName: "GPT-6-Astra",
            description: "Astra", isDefault: true,
            supportedReasoningEfforts: efforts.map {
                CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: $0, description: $0)
            },
            defaultReasoningEffort: "medium"
        )
        let options = AgentCodexModelRegistry.shared.resolvedOptions(staticOptions: [], preferredLiveModels: [remote])
        let menu = AgentModelCatalog.codexMenu(for: options)
        XCTAssertEqual(menu.groups.map(\.baseModelID), ["gpt-6-astra", "gpt-6-astra-fast"])
        XCTAssertEqual(menu.groups[0].options.map(\.rawValue), efforts.map { "gpt-6-astra-\($0)" })
        XCTAssertEqual(menu.groups[1].options.map(\.rawValue), efforts.map { "gpt-6-astra-fast-\($0)" })
        XCTAssertEqual(options.filter(\.isProviderDefault).map(\.rawValue), ["gpt-6-astra-medium"])
        XCTAssertEqual(menu.groups[0].displayName, "GPT-6 Astra")
    }
}
