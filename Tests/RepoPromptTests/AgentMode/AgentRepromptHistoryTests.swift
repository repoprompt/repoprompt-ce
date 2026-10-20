import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentRepromptHistoryTests: XCTestCase {
    func testNoHistoryAndFewerThanTwoCompletedTurnsSendNothing() throws {
        XCTAssertTrue(AgentRepromptHistory.make(items: [], compactedAt: nil, hasActiveTurn: false).isEmpty)
        let one = turn("one", "reply")
        XCTAssertTrue(AgentRepromptHistory.make(items: one, compactedAt: nil, hasActiveTurn: false).isEmpty)
        XCTAssertTrue(AgentRepromptHistory.make(items: one + [.user("unfinished")], compactedAt: nil, hasActiveTurn: true).isEmpty)
        let message = try AgentRepromptService.message(for: .init(originalText: "first prompt"))
        XCTAssertFalse(message.conversationMessages[0].content.contains("recentChat"))
    }

    func testCanonicalCompletionProofIsRequiredWhenProvided() {
        let first = turn("one", "reply one")
        let second = turn("two", "reply two")
        XCTAssertTrue(AgentRepromptHistory.make(items: first + second, compactedAt: nil, hasActiveTurn: false, completedUserItemIDs: [first[0].id]).isEmpty)
        XCTAssertEqual(AgentRepromptHistory.make(items: first + second, compactedAt: nil, hasActiveTurn: false, completedUserItemIDs: [first[0].id, second[0].id]).count, 2)
    }

    func testMarkdownDiffFenceVariantsAreExcludedFromHistory() {
        for (opening, closing) in [("~~~diff", "~~~"), ("````patch", "````"), ("   ```diff", "   ```"), ("> ~~~~DIFF", "> ~~~~"), ("```patch", "")] {
            let reply = "Keep this summary.\n\(opening)\nSECRET DIFF CONTENT\n\(closing)"
            let history = AgentRepromptHistory.make(items: turn("one", "reply") + turn("two", reply), compactedAt: nil, hasActiveTurn: false)
            XCTAssertEqual(history.count, 2)
            XCTAssertTrue(history.last?.assistant.contains("Keep this summary.") == true)
            XCTAssertFalse(history.last?.assistant.contains("SECRET") == true, opening)
        }
        for rawDiff in ["diff --git a/file b/file\nSECRET", "```\n--- a/file\n+++ b/file\nSECRET\n```"] {
            let history = AgentRepromptHistory.make(items: turn("one", "reply") + turn("two", rawDiff), compactedAt: nil, hasActiveTurn: false)
            XCTAssertEqual(history.last?.assistant, "[diff omitted]")
        }
        let code = "```swift\nlet value = 1\n```"
        let history = AgentRepromptHistory.make(items: turn("one", "reply") + turn("two", code), compactedAt: nil, hasActiveTurn: false)
        XCTAssertEqual(history.last?.assistant, code)
    }

    func testLastThreeTurnsUseBubbleTextAndFinalAssistantOnly() {
        var items = turn("old", "old reply") + turn("two", "reply two") + turn("three", "reply three")
        items += [
            .user("Approved rewritten words", attachments: [.init(source: .localFile(path: "/secret/image.png"))], dispatchedProviderText: "SYSTEM WORKFLOW WRAPPER"),
            .init(kind: .thinking, text: "secret thoughts"),
            .init(kind: .toolResult, text: "SECRET TOOL OUTPUT"),
            .assistantInline("commentary"),
            .assistant("intermediate"),
            .assistant("final reply", reasoning: "excluded reasoning")
        ]
        let history = AgentRepromptHistory.make(items: items, compactedAt: nil, hasActiveTurn: false)
        XCTAssertEqual(history.map(\.user), ["two", "three", "Approved rewritten words"])
        XCTAssertEqual(history.last?.assistant, "final reply")
        let serialized = String(decoding: (try? JSONEncoder().encode(history)) ?? Data(), as: UTF8.self)
        for excluded in ["secret", "SECRET", "commentary", "intermediate", "WRAPPER", "excluded reasoning"] {
            XCTAssertFalse(serialized.contains(excluded))
        }
    }

    func testUTF8TrimmingPreservesStartEndAndDropsOldestWithinTotalCap() throws {
        let longReply = "START " + String(repeating: "é🙂", count: 1000) + " END"
        let trimmed = AgentRepromptHistory.trimmed(longReply, bytes: 1536)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, 1536)
        XCTAssertTrue(trimmed.hasPrefix("START ") && trimmed.hasSuffix(" END"))
        XCTAssertFalse(trimmed.contains("�"))
        let items = turn("oldest" + String(repeating: "a", count: 3000), longReply)
            + turn("middle" + String(repeating: "b", count: 3000), longReply)
            + turn("latest" + String(repeating: "c", count: 3000), longReply)
        let history = AgentRepromptHistory.make(items: items, compactedAt: nil, hasActiveTurn: false)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(history).count, 8 * 1024)
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].user.hasPrefix("latest"))
    }

    func testCompactionBoundaryAndDiffsAreExcluded() {
        let boundary = Date(timeIntervalSince1970: 100)
        let before = turn("before", "before reply", at: boundary.addingTimeInterval(-10))
        let after = turn("after one", "before\n```diff\nSECRET DIFF\n```\nafter", at: boundary.addingTimeInterval(1))
            + turn("after two", "new reply", at: boundary.addingTimeInterval(2))
        XCTAssertTrue(AgentRepromptHistory.make(items: before + Array(after.prefix(2)), compactedAt: boundary, hasActiveTurn: false).isEmpty)
        let history = AgentRepromptHistory.make(items: before + after, compactedAt: boundary, hasActiveTurn: false)
        XCTAssertEqual(history.map(\.user), ["after one", "after two"])
        XCTAssertFalse(history[0].assistant.contains("SECRET DIFF"))
    }

    private func turn(_ user: String, _ assistant: String, at date: Date = .now) -> [AgentChatItem] {
        [.init(timestamp: date, kind: .user, text: user), .init(timestamp: date.addingTimeInterval(0.001), kind: .assistant, text: assistant)]
    }
}

@MainActor
final class AgentRepromptModelPolicyTests: XCTestCase {
    func testAutomaticPrefersMatchingSubscriptionThenOtherSubscriptionBeforeAPI() {
        let claude = AgentRepromptModelPolicy.preferredClaude
        let codex = AgentRepromptModelPolicy.preferredCodex
        let models: [AIModel] = [.gpt61SolLow, claude, codex]
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, primary: .gpt61SolLow, currentProvider: .claudeCode, configured: models), claude)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, primary: .gpt61SolLow, currentProvider: .codexExec, configured: models), codex)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, primary: .gpt61SolLow, currentProvider: .codexExec, configured: [.gpt61SolLow, claude]), claude)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, primary: .gpt61SolLow, currentProvider: nil, configured: [.gpt61SolLow]), .gpt61SolLow)
    }

    func testAutomaticUsesConfiguredCompatibleAPIBeforeOracle() throws {
        let compatible = try XCTUnwrap(ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI).first)
        XCTAssertNotNil(ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: compatible))
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, primary: .gpt61SolLow, currentProvider: .claudeCode, configured: [.gpt61SolLow, compatible]), compatible)
    }

    func testExplicitModelAndUsePrimaryNeverSilentlyFallBack() {
        let codex = AgentRepromptModelPolicy.preferredCodex
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: "unknown-future-model", primary: .gpt61SolLow, currentProvider: .codexExec, configured: [codex]))
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: AIModel.gpt61SolLow.rawValue, primary: nil, currentProvider: .codexExec, configured: [codex]))
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: AgentRepromptModelPolicy.primaryOracle, primary: .gpt61SolLow, currentProvider: .codexExec, configured: [codex]))
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: AIModel.gpt61SolLow.rawValue, primary: codex, currentProvider: .codexExec, configured: [codex, .gpt61SolLow]), .gpt61SolLow)
    }

    func testRewriterEffortUsesAutoEffortDecisionWithoutMutatingImplementingModel() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let model = AgentRepromptModelPolicy.preferredClaude
        let implementing = fixture.session.selectedModelRaw
        let low = await fixture.viewModel.chooseRepromptEffort(model: model, text: "Fix a parser edge case", requestID: UUID())
        XCTAssertEqual(low.defaultReasoningEffort, "low")
        fixture.store.setAutoEffortBackendRaw(fixture.backend.id.rawValue)
        fixture.store.setAutoEffortEnabled(true)
        await fixture.runtime.reconcileDemand()
        let chosen = await fixture.viewModel.chooseRepromptEffort(model: model, text: "Fix a parser edge case", requestID: UUID())
        let requests = await fixture.backend.requests
        XCTAssertEqual(requests.last?.consumerID, .autoEffort)
        XCTAssertEqual(chosen.providerType, model.providerType)
        XCTAssertEqual(chosen.modelName, model.modelName)
        XCTAssertNotEqual(chosen.defaultReasoningEffort, "low")
        XCTAssertEqual(fixture.session.selectedModelRaw, implementing)
        XCTAssertNil(fixture.session.autoEffortJudgmentID)
    }

    func testEffortVariantsNeverChangeExplicitServiceTier() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let model = AIModel.openAIServiceTierVariant(base: .gpt61SolHigh, tier: "priority")
        let chosen = await fixture.viewModel.chooseRepromptEffort(model: model, text: "Fix parser", requestID: UUID())
        XCTAssertEqual(chosen.openAIServiceTierOverride, "priority")
        XCTAssertEqual(chosen.modelName, model.modelName)
        XCTAssertEqual(chosen.defaultReasoningEffort, "low")
    }

    func testManifestIsCheapBoundedAndSideCallModelsExcludeAgentTransports() {
        let manifest = AgentRepromptModelPolicy.manifest(rootNames: ["Project"], selectedPaths: (0 ..< 100).map { "file\($0).swift" })
        XCTAssertTrue(manifest.contains("+50 more"))
        XCTAssertLessThanOrEqual(manifest.utf8.count, 4096)
        XCTAssertTrue(AgentRepromptModelPolicy.supportsSideCall(.gpt61SolLow))
        XCTAssertTrue(AgentRepromptModelPolicy.supportsSideCall(AgentRepromptModelPolicy.preferredClaude))
    }
}
