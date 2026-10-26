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
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: .claudeCode, configured: models), claude)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: .codexExec, configured: models), codex)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: .codexExec, configured: [.gpt61SolLow, claude]), claude)
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: nil, configured: [.gpt61SolLow]), .gpt61SolLow)
    }

    func testDefaultNeverUsesArbitraryCompatibleAPIOrExpensiveTier() throws {
        let compatible = try XCTUnwrap(ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI).first)
        XCTAssertNotNil(ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: compatible))
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: .claudeCode, configured: [.gpt61SolLow, compatible]), .gpt61SolLow)
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: .claudeCode, configured: [compatible, .gpt61SolHigh]))
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: nil, currentProvider: nil, configured: []))
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: compatible.rawValue, currentProvider: .claudeCode, configured: [compatible]), compatible, "Other API routes require an explicit choice")
    }

    func testExplicitUnavailableModelNeverSilentlyFallsBack() {
        let codex = AgentRepromptModelPolicy.preferredCodex
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: "unknown-future-model", currentProvider: .codexExec, configured: [codex]))
        XCTAssertNil(AgentRepromptModelPolicy.resolve(selection: AIModel.gpt61SolLow.rawValue, currentProvider: .codexExec, configured: [codex]))
        XCTAssertEqual(AgentRepromptModelPolicy.resolve(selection: AIModel.gpt61SolLow.rawValue, currentProvider: .codexExec, configured: [codex, .gpt61SolLow]), .gpt61SolLow)
    }

    func testResolvedDefaultDisappearingRequiresChoiceRatherThanBillingRouteSwitch() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let claude = AgentRepromptModelPolicy.preferredClaude
        fixture.viewModel.repromptEnabled = true // Enabled Re-prompt owns a pinned billing route.
        fixture.viewModel.repromptAvailability = { [claude] in $0 == claude || $0 == .gpt61SolLow }
        XCTAssertEqual(fixture.viewModel.resolvedRepromptModel(), claude)
        fixture.viewModel.repromptAvailability = { $0 == .gpt61SolLow }
        XCTAssertNil(fixture.viewModel.resolvedRepromptModel())
        XCTAssertEqual(fixture.viewModel.repromptPillProps().modelDisplayName, "Choose a model")
        fixture.viewModel.setRepromptModelRaw(AIModel.gpt61SolLow.rawValue)
        XCTAssertEqual(fixture.viewModel.resolvedRepromptModel(), .gpt61SolLow)
    }

    func testSavedUnavailableSelectionIsExplainedAndOnlyExplicitAutomaticResetResolvesDefault() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let claude = AgentRepromptModelPolicy.preferredClaude
        fixture.viewModel.repromptAvailability = { [claude] in $0 == claude }
        fixture.viewModel.setRepromptModelRaw(AIModel.gpt61SolLow.rawValue)
        XCTAssertEqual(fixture.viewModel.repromptModelResolution(), .savedSelectionUnavailable(raw: AIModel.gpt61SolLow.rawValue))
        let props = fixture.viewModel.repromptPillProps()
        XCTAssertFalse(props.isAvailable, "A disconnected saved choice is never replaced by the connected default")
        XCTAssertTrue(props.unavailableReason?.contains("saved") == true)
        fixture.viewModel.useAutomaticRepromptModel()
        XCTAssertEqual(fixture.viewModel.repromptModelSelectionRaw(), "")
        XCTAssertEqual(fixture.viewModel.resolvedRepromptModel(), claude)
    }

    func testDisabledPillRenderDoesNotPinRouteWhileAvailabilityLoads() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let claude = AgentRepromptModelPolicy.preferredClaude
        XCTAssertFalse(fixture.viewModel.repromptEnabled)
        fixture.viewModel.repromptAvailability = { $0 == .gpt61SolLow }
        XCTAssertEqual(fixture.viewModel.repromptPillProps().modelDisplayName, AIModel.gpt61SolLow.displayName)
        XCTAssertNil(fixture.viewModel.repromptDefaultModel, "Rendering an off pill is not consent or use")
        fixture.viewModel.repromptAvailability = { [claude] in $0 == claude || $0 == .gpt61SolLow }
        XCTAssertEqual(fixture.viewModel.resolvedRepromptModel(), claude, "A late subscription replaces an unused API default")
        _ = fixture.viewModel.repromptModelResolution(pinningDefault: true)
        XCTAssertEqual(fixture.viewModel.repromptDefaultModel?.model, claude)
        fixture.viewModel.repromptAvailability = { $0 == .gpt61SolLow }
        XCTAssertEqual(fixture.viewModel.repromptModelResolution(), .automaticDefaultUnavailable(claude))
    }

    func testPillReturnWithoutModelSendsAsTypedInsteadOfStartingDoomedPreparation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.repromptEnabled = true
        fixture.viewModel.repromptAvailability = { _ in false }
        XCTAssertFalse(try fixture.begin(text: "Fix the parser"), "No model: ordinary Return proceeds to the normal send path")
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertNil(fixture.viewModel.repromptUIStore.presentation)
    }

    func testUnavailableReasonsDistinguishLostDefaultFromMissingDefault() {
        let claude = AgentRepromptModelPolicy.preferredClaude
        XCTAssertNil(AgentRepromptModelResolution.resolved(claude).unavailableReason)
        XCTAssertEqual(AgentRepromptModelResolution.resolved(claude).model, claude)
        let lost = AgentRepromptModelResolution.automaticDefaultUnavailable(claude).unavailableReason ?? ""
        XCTAssertTrue(lost.contains(claude.displayName) && lost.contains("billing"))
        let none = AgentRepromptModelResolution.noAutomaticDefault.unavailableReason ?? ""
        XCTAssertTrue(none.contains("Claude Code") && none.contains("Codex"))
        XCTAssertNil(AgentRepromptModelResolution.noAutomaticDefault.model)
    }

    func testDisclosureSummaryIsConciseButKeepsEssentialConsentFacts() {
        let withChat = AgentRepromptDisclosure.summary(modelName: "Sonnet Low", routeName: "Claude Code", includesRecentChat: true)
        let withoutChat = AgentRepromptDisclosure.summary(modelName: "Sonnet Low", routeName: "Claude Code", includesRecentChat: false)
        XCTAssertEqual(withChat.count, 3)
        XCTAssertEqual(withoutChat.count, 3)
        let text = withChat.joined(separator: " ")
        XCTAssertLessThanOrEqual(text.split(separator: " ").count, 70, "The consent summary must not become a wall of text")
        for fact in ["Sonnet Low", "Claude Code", "selected paths", "Never file contents", "billing", "retention", "secrets", "Auto Effort", "recent chat"] {
            XCTAssertTrue(text.contains(fact), "Missing consent fact: \(fact)")
        }
        XCTAssertFalse(withoutChat.joined(separator: " ").contains("recent chat"), "Recent-chat exposure is disclosed only when enabled")
    }

    func testRewriterUsesLowEffortWithoutSerialDecisionOrImplementingModelMutation() async throws {
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
        XCTAssertTrue(requests.isEmpty, "A wording pass must not wait for a separate decision-backend call")
        XCTAssertEqual(chosen.providerType, model.providerType)
        XCTAssertEqual(chosen.modelName, model.modelName)
        XCTAssertEqual(chosen.defaultReasoningEffort, "low")
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
