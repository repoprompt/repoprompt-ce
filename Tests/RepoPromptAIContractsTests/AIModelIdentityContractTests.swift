import Foundation
import RepoPromptAIContracts
import XCTest

final class AIModelIdentityContractTests: XCTestCase {
    func testProviderAndAssociatedValueIdentityDistinctionsRemainHashable() {
        let models: [AIModel] = [
            .gpt41, .gpt5, .gpt5Low, .gpt5High, .gpt5XHigh,
            .gpt61Sol, .gpt61SolLow, .gpt61SolHigh, .gpt61SolXHigh, .gpt61SolMax,
            .codexCliGpt61SolLow, .codexCliGpt61SolMedium, .codexCliGpt61SolHigh,
            .claudeCode, .claudeCodeSonnet, .claudeCodeHaiku, .claudeCodeOpus, .ollama,
            .openrouterCustom(name: "same"), .openaiCustom(name: "same"),
            .openaiCustomResponses(name: "same"), .openaiCustomReasoning(name: "same", effort: .low),
            .openaiCustomReasoning(name: "same", effort: .high), .anthropicCustom(name: "same"),
            .geminiCustom(name: "same"), .deepseekCustom(name: "same"), .fireworksCustom(name: "same"),
            .azureCustom(name: "same"), .grokCustom(name: "same"), .groqCustom(name: "same"),
            .zaiCustom(name: "same"), .codexCustom(name: "same"), .openCodeCustom(name: "same"),
            .cursorCustom(name: "same"), .grokBuildCustom(name: "same"), .devinCustom(name: "same"),
            .customProvider(name: "same", provider: "provider", model: "model"),
            .customProvider(name: "different", provider: "provider", model: "model"),
            .customProvider(name: "same", provider: "different", model: "model"),
            .customProvider(name: "same", provider: "provider", model: "different"),
            .customProviderUser(name: "same"), .claudeCodeModel(specifier: "same"),
            .codexCustom(name: "SAME"), .codexCustom(name: " same ")
        ]
        XCTAssertEqual(Set(models).count, models.count, "Provider cases and every associated field are identity, not display aliases")
        XCTAssertNotEqual(AIModel.openaiCustom(name: "Exact"), .openaiCustom(name: "exact"))
        XCTAssertNotEqual(AIModel.openaiCustom(name: "Exact"), .openaiCustom(name: " Exact "))
    }

    func testClaudeIdentityUsesOnlyExistingTrimAndLowercaseRule() {
        let a = AIModel.claudeCodeModel(specifier: " \nCC:BACKEND:OPUS:HIGH\t")
        let b = AIModel.claudeCodeModel(specifier: "cc:backend:opus:high")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual([a: "retained"][b], "retained", "Equal model values must share hash identity")
        XCTAssertNotEqual(b, .claudeCodeModel(specifier: "cc:backend:opus:max"))
        XCTAssertNotEqual(AIModel.claudeCodeModel(specifier: "opus : high"), .claudeCodeModel(specifier: "opus:high"))
        XCTAssertNotEqual(AIModel.claudeCodeModel(specifier: "opus"), .claudeCodeOpus, "Static and custom aliases remain distinct")
        XCTAssertEqual(AIModel.claudeCodeModel(specifier: " \n"), .claudeCodeModel(specifier: ""))
    }

    func testServiceTierIdentityRetainsExactTierAndRecursiveBase() {
        let models: [AIModel] = [
            .gpt5,
            .openAIServiceTierVariant(base: .gpt5, tier: "priority"),
            .openAIServiceTierVariant(base: .gpt5, tier: "Priority"),
            .openAIServiceTierVariant(base: .gpt5, tier: " priority "),
            .openAIServiceTierVariant(base: .gpt5Low, tier: "priority"),
            .openAIServiceTierVariant(base: .openAIServiceTierVariant(base: .gpt5, tier: "priority"), tier: "priority")
        ]
        XCTAssertEqual(Set(models).count, models.count)
        let a = AIModel.openAIServiceTierVariant(base: .claudeCodeModel(specifier: " OPUS "), tier: "Exact")
        let b = AIModel.openAIServiceTierVariant(base: .claudeCodeModel(specifier: "opus"), tier: "Exact")
        XCTAssertEqual(a, b)
        XCTAssertEqual([a: "nested"][b], "nested")
    }

    func testProviderVocabularyRetainsSynthesizedCodableGoldenEncodings() throws {
        let rows: [(AIProviderType, String)] = [
            (.anthropic, "anthropic"), (.openAI, "openAI"), (.ollama, "ollama"),
            (.azure, "azure"), (.openRouter, "openRouter"), (.gemini, "gemini"),
            (.deepseek, "deepseek"), (.customProvider, "customProvider"), (.fireworks, "fireworks"),
            (.grok, "grok"), (.groq, "groq"), (.zAI, "zAI"), (.claudeCode, "claudeCode"),
            (.codex, "codex"), (.openCode, "openCode"), (.cursor, "cursor"),
            (.grokBuild, "grokBuild"), (.devin, "devin")
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (provider, key) in rows {
            let golden = Data("{\"\(key)\":{}}".utf8)
            XCTAssertEqual(try encoder.encode(provider), golden, key)
            XCTAssertEqual(try JSONDecoder().decode(AIProviderType.self, from: golden), provider, key)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AIProviderType.self, from: Data("{\"newProvider\":{}}".utf8)))
    }
}
