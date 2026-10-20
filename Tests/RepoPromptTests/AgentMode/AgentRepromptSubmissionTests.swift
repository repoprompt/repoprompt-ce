import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRepromptSubmissionTests: XCTestCase {
    func testFirstSendPreparesWithoutClaimAndSecondSendAdoptsEditedDraft() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let gate = AgentRepromptStartGate()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("A streamed ")
            _ = await gate.wait()
            try await publish("brief.")
        })
        defer { Task { await gate.release() } }
        fixture.session.pendingImageAttachments = [.init(source: .localFile(path: "/tmp/kept-image.png"))]
        let images = fixture.session.pendingImageAttachments
        let token = fixture.session.composerSubmissionToken
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("incremental draft", timeout: 5) { fixture.session.draftText == "A streamed " }
        XCTAssertEqual(fixture.session.composerSubmissionToken, token)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
        XCTAssertTrue(fixture.session.items.isEmpty)
        XCTAssertEqual(fixture.session.pendingImageAttachments, images)
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty, "Never route partial tokens")
        await gate.release()
        try await ready(fixture)
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "/review Edited as ordinary data")
        XCTAssertFalse(try fixture.begin(text: fixture.session.draftText), "Second Send must not re-prompt even after edits")
        let claim = try fixture.claim(text: fixture.session.draftText, local: true)
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        XCTAssertEqual(fixture.viewModel.repromptDispatchTexts[claim.attempt.id], "/review Edited as ordinary data")
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertTrue(fixture.session.items.isEmpty, "Only executeSubmit can dispatch, not preparation")
    }

    func testCancelRestoresOriginalAndLateChunksCannotChangeIt() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let gate = AgentRepromptStartGate()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("Partial")
            _ = await gate.wait()
            try await publish(" late result")
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("partial", timeout: 5) { fixture.session.draftText == "Partial" }
        let oldID = try XCTUnwrap(fixture.viewModel.repromptOperation?.id)
        fixture.viewModel.cancelReprompt()
        XCTAssertEqual(fixture.session.draftText, "Original")
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.session.draftText, "Original")
        XCTAssertNil(fixture.viewModel.repromptSpeculations[oldID])
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "Partial")
    }

    func testUserMutationDuringStreamingWinsAndRecoversPartial() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let gate = AgentRepromptStartGate()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("Partial")
            _ = await gate.wait()
            try await publish(" late")
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("partial", timeout: 5) { fixture.session.draftText == "Partial" }
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "User wins")
        XCTAssertNil(fixture.viewModel.repromptOperation)
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.session.draftText, "User wins")
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "Partial")
    }

    func testSessionReplacementRejectsLateChunksAndDoesNotOverwriteReplacementDraft() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let gate = AgentRepromptStartGate()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("Partial")
            _ = await gate.wait()
            try await publish(" stale")
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("partial", timeout: 5) { fixture.session.draftText == "Partial" }
        let replacement = AgentTabSession(tabID: fixture.session.tabID)
        replacement.draftText = "Replacement draft"
        fixture.viewModel.test_installLiveSession(replacement)
        fixture.viewModel.invalidateRepromptIfNeeded()
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertEqual(replacement.draftText, "Replacement draft")
        XCTAssertEqual(fixture.session.draftText, "Partial")
    }

    func testUndoKeepsEditedVersionRecoverableAndBypassPreservesIt() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await ready(fixture)
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "My edited brief")
        fixture.viewModel.undoReprompt()
        XCTAssertEqual(fixture.session.draftText, "Original")
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "My edited brief")
        XCTAssertFalse(try fixture.begin(text: "/review"))
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "My edited brief")
        XCTAssertFalse(fixture.viewModel.restoreRepromptRecovery(tabID: fixture.session.tabID))
        XCTAssertTrue(fixture.viewModel.restoreRepromptRecovery(tabID: fixture.session.tabID, confirmedReplacement: true))
        XCTAssertEqual(fixture.session.draftText, "My edited brief")
    }

    func testRunOrSettingsChangeInvalidatesWithoutDispatch() async throws {
        for changeSettings in [false, true] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.enableReprompt()
            XCTAssertTrue(try fixture.begin(text: "Original"))
            try await ready(fixture)
            if changeSettings {
                var profile = fixture.store.globalAgentModelsProfile()
                profile.agentRepromptGuidance = "New guidance"
                fixture.store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
            } else { fixture.session.runState = .completed }
            fixture.viewModel.invalidateRepromptIfNeeded()
            XCTAssertNil(fixture.viewModel.repromptOperation)
            XCTAssertTrue(fixture.session.items.isEmpty)
            XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, AgentRepromptServiceTests.valid)
        }
    }

    func testLatePublisherAfterSuccessOrFailureCannotMutateComposer() async throws {
        for fails in [false, true] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.enableReprompt()
            let publisher = AgentRepromptCapturedPublisher()
            fixture.viewModel.repromptService = .init(transport: { _, _, publish in
                await publisher.save(publish)
                try await publish("Complete body")
                if fails { throw AgentRepromptError.incomplete }
            })
            XCTAssertTrue(try fixture.begin(text: "Original"))
            try await AsyncTestWait.waitUntil("settled", timeout: 5) {
                fixture.viewModel.repromptOperation?.phase == (fails ? .failed : .completed)
            }
            do { try await publisher.emit(" late bytes")
                XCTFail("Late publication was accepted")
            } catch { XCTAssertTrue(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(fixture.session.draftText, "Complete body")
        }
    }

    func testRealSecondSendTreatsGeneratedNativeSlashAsText() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.session.hasLoadedPersistedState = true
        fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
        fixture.enableReprompt()
        let approved = "/compact This line is literal approved text"
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in try await publish(approved) })
        XCTAssertTrue(try fixture.begin(text: "Original request"))
        try await ready(fixture)
        XCTAssertFalse(try fixture.begin(text: approved))
        let claim = try fixture.claim(text: approved, local: true)
        let result = await fixture.viewModel.executeComposerSubmitAttempt(text: approved, claim: claim, createAndActivateSessionTab: {
            XCTFail("An existing session must not be replaced")
            return nil
        })
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(fixture.session.items.last(where: { $0.kind == .user })?.text, approved)
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, approved)
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.skipsSlashExpansion, true)
    }

    func testSafetyCeilingIncludesCancellationIgnoringEffortJudgment() async throws {
        let store = AgentRepromptUIStore()
        let gate = AgentRepromptStartGate()
        let service = AgentRepromptService(transport: { _, _, _ in XCTFail("Timed-out judgment must not start the provider") }, timeoutOverride: 0.02)
        let operation = AgentRepromptOperation(
            sourceTabID: UUID(), rawDraft: "Original", draftGeneration: 0,
            request: .init(originalText: "Original"), model: .gpt61SolLow, service: service, store: store,
            currentDraft: { "Original" }, applyDraft: { _ in XCTFail("No tokens should publish")
                return 0
            },
            chooseEffort: { model in _ = await gate.wait()
                return model
            }, isCurrent: { true }
        )
        operation.start()
        try await AsyncTestWait.waitUntil("whole-call safety ceiling", timeout: 3) { store.presentation?.phase == .failed }
        XCTAssertEqual(store.presentation?.error, AgentRepromptError.timeout.errorDescription)
        operation.cancel(restoreOriginal: false)
        await gate.release()
    }

    func testSendOriginalCompletesPreparationButDoesNotDispatch() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "Original"))
        fixture.viewModel.useRepromptOriginal()
        XCTAssertEqual(fixture.session.draftText, "Original")
        XCTAssertEqual(fixture.viewModel.repromptOperation?.phase, .completed)
        XCTAssertFalse(try fixture.begin(text: "Original"))
        let claim = try fixture.claim(text: "Original", local: true)
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        XCTAssertEqual(fixture.viewModel.repromptAudits[claim.attempt.id]?.outcome, .sentOriginal)
        XCTAssertTrue(fixture.session.items.isEmpty)
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
        fixture.viewModel.test_settleRejectedACPSteeringSubmission(id: queued.id, session: fixture.session, stopFence: AgentRunStartStopFence(session: fixture.session))
        let pending = try XCTUnwrap(fixture.session.pendingInstructions.first)
        XCTAssertEqual(pending.providerText, queued.providerText)
        XCTAssertEqual(pending.localDraftText, queued.draftText)
        XCTAssertTrue(pending.skipsSlashExpansion)
    }

    func testEligibilityAndReplacementCarryAcrossAutomationAndHydrationWrappers() async throws {
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: " \n /unknown"))
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: " \n\t"))
        XCTAssertFalse(AgentModeViewModel.isRepromptEligible(text: "text", hasStagedCommand: true))
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
                await fixture.viewModel.submitUserTurnAfterHydration(tabID: fixture.session.tabID, originalSession: fixture.session, originalBinding: fixture.session.persistentSessionBindingIdentity, trimmedText: "Source words", attachmentsToSend: [], taggedFilesToSend: [], activeWorkflow: nil, rawDraftText: raw, composerOrigin: .localComposer, repromptedText: approved, stopFence: AgentRunStartStopFence(session: fixture.session))
            }
            XCTAssertEqual(fixture.session.items.last(where: { $0.kind == .user })?.text, approved)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, approved)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.draftText, raw)
            XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.skipsSlashExpansion, true)
        }
    }

    private func ready(_ fixture: AgentRepromptTestFixture) async throws {
        try await AsyncTestWait.waitUntil("completed preparation", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
    }
}

actor AgentRepromptCapturedPublisher {
    private var publication: AgentRepromptService.Publication?
    func save(_ publication: @escaping AgentRepromptService.Publication) {
        self.publication = publication
    }

    func emit(_ text: String) async throws {
        try await publication?(text)
    }
}
