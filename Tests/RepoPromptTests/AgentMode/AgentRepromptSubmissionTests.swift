import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRepromptSubmissionTests: XCTestCase {
    func testMandatoryApprovalAndOneShotCompletion() async throws {
        let store = AgentRepromptUIStore()
        let operation = try makeOperation(store: store)
        var outcome: AgentRepromptOperation.Outcome?
        let waiter = Task { outcome = await operation.prepare() }
        try await waitForReview(store)
        XCTAssertNil(outcome, "A generated brief must never dispatch automatically")
        store.reviewText = "My edited brief"
        operation.approve()
        operation.sendOriginal()
        await waiter.value
        guard case let .approved(text) = outcome else { return XCTFail("Expected explicit approval") }
        XCTAssertEqual(text, "My edited brief")
        XCTAssertNil(store.presentation)
    }

    func testStaleReviewRecoversLatestEditedBriefWithoutSubmitting() async throws {
        let store = AgentRepromptUIStore()
        var current = true
        let operation = try makeOperation(store: store, isCurrent: { current })
        let waiter = Task { await operation.prepare() }
        try await waitForReview(store)
        store.reviewText = "Do not lose these edits"
        current = false
        operation.approve()
        guard case .cancelled = await waiter.value else { return XCTFail("Stale review submitted") }
        XCTAssertEqual(store.recoveries[operation.sourceTabID]?.text, "Do not lose these edits")
        XCTAssertEqual(store.recoveries[operation.sourceTabID]?.originalDraft, "original")
    }

    func testSendOriginalAndCancelResolveWithoutApproval() async throws {
        for sendOriginal in [false, true] {
            let store = AgentRepromptUIStore()
            let operation = try makeOperation(store: store)
            let waiter = Task { await operation.prepare() }
            try await waitForReview(store)
            if sendOriginal {
                operation.sendOriginal()
            } else {
                operation.finish(.cancelled)
            }
            let outcome = await waiter.value
            if sendOriginal {
                guard case .original = outcome else { return XCTFail("Expected original") }
            } else {
                guard case .cancelled = outcome else { return XCTFail("Expected cancellation") }
            }
        }
    }

    func testEligibilityAndReplacementCarryAcrossAutomationAndHydrationWrappers() async throws {
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: " \n /unknown"))
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: " \n\t"))
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: "text", hasStagedCommand: true))
        XCTAssertTrue(AgentModeViewModel.isRepromptEligible(text: "A local follow-up"))
        for wrapper in 0 ..< 4 {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
            fixture.session.installRunID(UUID())
            fixture.session.runState = .running
            fixture.session.isMCPInstructionDispatchInProgress = true
            fixture.session.hasLoadedPersistedState = true
            fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
            let raw = "  Source words  "
            let approved = "/review This is approved text, not a new command"
            let claim = try fixture.claim(text: raw)
            defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
            switch wrapper {
            case 0:
                let result = await fixture.viewModel.submitUserTurnAfterFreshTaskRouting(text: "Source words", claim: claim, session: fixture.session, destinationTabID: fixture.session.tabID, repromptedText: approved)
                XCTAssertEqual(result, .submitted)
            case 1:
                let result = await fixture.viewModel.submitUserTurnAfterUsageBalancing(text: "Source words", claim: claim, session: fixture.session, destinationTabID: fixture.session.tabID, repromptedText: approved)
                XCTAssertEqual(result, .submitted)
            case 2:
                let result = await fixture.viewModel.submitUserTurnAfterAutoEffort(text: "Source words", claim: claim, session: fixture.session, destinationTabID: fixture.session.tabID, repromptedText: approved)
                XCTAssertEqual(result, .submitted)
            default:
                await fixture.viewModel.submitUserTurnAfterHydration(
                    tabID: fixture.session.tabID, originalSession: fixture.session, originalBinding: fixture.session.persistentSessionBindingIdentity,
                    trimmedText: "Source words", attachmentsToSend: [], taggedFilesToSend: [], activeWorkflow: nil,
                    rawDraftText: raw, composerOrigin: .localComposer, repromptedText: approved,
                    stopFence: AgentRunStartStopFence(session: fixture.session)
                )
            }
            XCTAssertEqual(fixture.session.items.last(where: { $0.kind == .user })?.text, approved)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, approved)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.draftText, raw)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.skipsSlashExpansion, true)
        }
    }

    func testRejectedACPSteeringPreservesApprovedSlashText() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.session.runState = .running
        let queued = AgentTabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID, targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "/review approved brief", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "Original words",
            optimisticUserItemID: nil, createdAt: Date(), skipsSlashExpansion: true
        )
        fixture.session.pendingACPSteeringInstructions.append(queued)
        fixture.viewModel.test_settleRejectedACPSteeringSubmission(
            id: queued.id, session: fixture.session, stopFence: AgentRunStartStopFence(session: fixture.session)
        )
        let pending = try XCTUnwrap(fixture.session.pendingInstructions.first)
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertEqual(pending.providerText, queued.providerText)
        XCTAssertEqual(pending.localDraftText, queued.draftText)
        XCTAssertTrue(pending.skipsSlashExpansion, "The rejected steer must not reinterpret approved text as a slash command.")
    }

    func testBypassedSubmissionsPreserveRecovery() async throws {
        for (enabled, text) in [(false, "Ordinary draft"), (true, "/review"), (true, " \n")] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.viewModel.repromptEnabled = enabled
            let claim = try fixture.claim(text: text)
            defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
            fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID] = .init(
                text: "Recovered brief", originalDraft: "Original", reason: "Context changed", draftAtInvalidation: "Original"
            )
            guard case .original = await fixture.viewModel.prepareComposerReprompt(text: text, claim: claim) else {
                return XCTFail("Expected bypass")
            }
            XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "Recovered brief")
        }
    }

    func testImplementingModelAndStreamingDoNotInvalidateButDraftChangeDoes() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let claim = try fixture.claim(text: "Original")
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        let task = Task { await fixture.viewModel.prepareComposerReprompt(text: "Original", claim: claim) }
        try await waitForReview(fixture.viewModel.repromptUIStore)
        fixture.viewModel.repromptUIStore.reviewText = "Keep my review edits"
        fixture.session.selectedModelRaw += ":high"
        fixture.session.appendItem(.assistant("Streaming delta", sequenceIndex: fixture.session.nextSequenceIndex))
        XCTAssertTrue(fixture.viewModel.repromptOperation?.validate() == true)
        XCTAssertEqual(fixture.viewModel.repromptUIStore.presentation?.phase, .reviewing)
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "A new local draft")
        XCTAssertNil(fixture.viewModel.repromptUIStore.presentation, "Draft writes eagerly invalidate without a review action.")
        guard case .cancelled = await task.value else { return XCTFail("Draft change must cancel") }
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "Keep my review edits")
    }

    func testNaturalRunBoundaryEagerlyInvalidatesReview() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let claim = try fixture.claim(text: "Original")
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        let task = Task { await fixture.viewModel.prepareComposerReprompt(text: "Original", claim: claim) }
        try await waitForReview(fixture.viewModel.repromptUIStore)
        fixture.session.runState = .completed
        try await AsyncTestWait.waitUntil("run boundary invalidates review", timeout: 3) { fixture.viewModel.repromptUIStore.presentation == nil }
        guard case .cancelled = await task.value else { return XCTFail("Run boundary must cancel") }
    }

    func testOnlyCapturedEffectiveSettingsScopeInvalidates() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let claim = try fixture.claim(text: "Original")
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        let task = Task { await fixture.viewModel.prepareComposerReprompt(text: "Original", claim: claim) }
        try await waitForReview(fixture.viewModel.repromptUIStore)
        fixture.store.setWorkspaceAgentModelsProfile(workspaceID: UUID(), profile: .init(agentRepromptGuidance: "Other workspace"))
        XCTAssertTrue(fixture.viewModel.repromptOperation?.validate() == true)
        var profile = fixture.store.globalAgentModelsProfile()
        profile.agentRepromptGuidance = "Changed captured guidance"
        fixture.store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        _ = fixture.viewModel.repromptOperation?.validate()
        guard case .cancelled = await task.value else { return XCTFail("Captured settings change must cancel") }
    }

    private func makeOperation(store: AgentRepromptUIStore, isCurrent: @escaping () -> Bool = { true }) throws -> AgentRepromptOperation {
        AgentRepromptOperation(
            sourceTabID: UUID(), rawDraft: "original", request: .init(originalText: "original"),
            model: .gpt61Sol,
            service: .init(transport: { _, _ in AgentRepromptServiceTests.valid }),
            store: store, consultant: nil, isCurrent: isCurrent
        )
    }

    private func waitForReview(_ store: AgentRepromptUIStore) async throws {
        for _ in 0 ..< 100 {
            if store.presentation?.phase == .reviewing {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Review never became ready: \(String(describing: store.presentation?.phase))")
    }
}
