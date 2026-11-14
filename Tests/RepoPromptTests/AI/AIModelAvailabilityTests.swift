import Foundation
import RepoPromptAIContracts
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AIModelAvailabilityTests: XCTestCase {
    private let dynamicModels: [AIModel] = [
        .openaiCustom(name: "availability-dynamic"),
        .openaiCustomResponses(name: "availability-dynamic"),
        .openaiCustomReasoning(name: "availability-dynamic", effort: .high),
        .anthropicCustom(name: "availability-dynamic"),
        .geminiCustom(name: "availability-dynamic"),
        .openrouterCustom(name: "availability-dynamic"),
        .deepseekCustom(name: "availability-dynamic"),
        .fireworksCustom(name: "availability-dynamic"),
        .azureCustom(name: "availability-dynamic"),
        .grokCustom(name: "availability-dynamic"),
        .groqCustom(name: "availability-dynamic"),
        .zaiCustom(name: "availability-dynamic"),
        .codexCustom(name: "availability-dynamic"),
        .openCodeCustom(name: "availability-dynamic"),
        .cursorCustom(name: "availability-dynamic"),
        .grokBuildCustom(name: "availability-dynamic"),
        .devinCustom(name: "availability-dynamic"),
        .claudeCodeModel(specifier: "availability-dynamic"),
        .customProvider(name: "label", provider: "provider", model: "availability-dynamic"),
        .customProviderUser(name: "availability-dynamic")
    ]

    private final class AvailabilityClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date {
            lock.withLock { value }
        }

        func set(_ value: Date) {
            lock.withLock { self.value = value }
        }
    }

    private func scanned(_ model: AIModel, definitions: [(AIModel, Date?)]) -> Bool {
        guard let definition = definitions.first(where: { $0.0 == model }), let date = definition.1 else { return true }
        return Date() >= date
    }

    func testEveryDefinitionAndDynamicMissMatchesOriginalScan() {
        let definitions = AIModel.test_availabilityDefinitions
        XCTAssertFalse(definitions.isEmpty)
        for model in definitions.map(\.0) + dynamicModels + [.ollama] {
            XCTAssertEqual(model.isAvailable, scanned(model, definitions: definitions), String(reflecting: model))
        }
        for model in dynamicModels {
            XCTAssertFalse(definitions.contains { $0.0 == model })
            XCTAssertTrue(model.isAvailable)
        }
    }

    func testFirstDefinitionWinsIncludingNilAndDifferentDates() {
        let past = Date(timeIntervalSince1970: 0)
        let future = Date.distantFuture
        let cases: [[(AIModel, Date?)]] = [
            [(.gpt5, future), (.gpt5, past)],
            [(.gpt5, past), (.gpt5, future)],
            [(.gpt5, nil), (.gpt5, future)],
            [(.gpt5, future), (.gpt5, nil)],
            [(.codexCustom(name: "caf\u{e9}"), future), (.codexCustom(name: "cafe\u{301}"), past)]
        ]
        for definitions in cases {
            AIModel.test_withAvailabilityDefinitions(definitions) {
                for model in definitions.map(\.0) + dynamicModels {
                    XCTAssertEqual(model.isAvailable, scanned(model, definitions: definitions), String(reflecting: model))
                }
            }
        }
    }

    @MainActor
    func testAllThreeCallersMatchScanWithFutureAndDuplicateDefinitions() {
        let definitions: [(AIModel, Date?)] = [
            (.gpt5, .distantFuture), (.gpt5, .distantPast),
            (.claudeCode, .distantFuture), (.claudeCode, nil),
            (.codexCliGpt56SolLow, nil), (.codexCliGpt56SolLow, .distantFuture)
        ]
        let providers: [AIProviderType] = [
            .openAI,
            .anthropic,
            .gemini,
            .azure,
            .openRouter,
            .ollama,
            .deepseek,
            .fireworks,
            .customProvider,
            .grok,
            .groq,
            .zAI,
            .claudeCode,
            .codex,
            .openCode,
            .cursor,
            .grokBuild,
            .devin
        ]
        let unfilteredProviders = AIModel.test_withAvailabilityDefinitions([]) {
            providers.map { ($0, AIModel.modelsForProvider($0)) }
        }
        let unfilteredAll = AIModel.test_withAvailabilityDefinitions([]) { AIModel.allModels() }
        AIModel.test_withAvailabilityDefinitions(definitions) {
            for (provider, unfiltered) in unfilteredProviders {
                XCTAssertEqual(
                    AIModel.modelsForProvider(provider).map { String(reflecting: $0) },
                    unfiltered.filter { scanned($0, definitions: definitions) }.map { String(reflecting: $0) }
                )
            }
            XCTAssertEqual(
                AIModel.allModels().map { String(reflecting: $0) },
                unfilteredAll.filter { scanned($0, definitions: definitions) }.map { String(reflecting: $0) }
            )
            let input: [AIModel] = [.gpt5, .claudeCode, dynamicModels[0], .gpt5]
            let expected = input.first { scanned($0, definitions: definitions) }
            XCTAssertEqual(AIModel.findBestAvailableModel(in: input, desiredFormat: .whole, priorities: input), expected)
            XCTAssertFalse(AIModel.gpt5.isAvailable)
            XCTAssertFalse(AIModel.claudeCode.isAvailable)
            XCTAssertTrue(AIModel.codexCliGpt56SolLow.isAvailable)
        }
    }

    func testReleaseDateIsComparedAgainOnEachCall() {
        let release = Date(timeIntervalSince1970: 10000)
        let clock = AvailabilityClock(release.addingTimeInterval(-1))
        AIModel.test_withAvailabilityDefinitions([(.gpt5, release)], now: { clock.now }) {
            XCTAssertFalse(AIModel.gpt5.isAvailable)
            clock.set(release)
            XCTAssertTrue(AIModel.gpt5.isAvailable)
            clock.set(release.addingTimeInterval(1))
            XCTAssertTrue(AIModel.gpt5.isAvailable)
            clock.set(release.addingTimeInterval(-1))
            XCTAssertFalse(AIModel.gpt5.isAvailable)
        }
    }
}
