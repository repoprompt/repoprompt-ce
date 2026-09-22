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
}
