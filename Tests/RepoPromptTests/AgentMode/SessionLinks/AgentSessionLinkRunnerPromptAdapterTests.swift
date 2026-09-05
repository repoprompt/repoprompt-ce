import Foundation
@testable import RepoPromptApp
import XCTest

/// Headless runner adapter, driven through the real `HeadlessAgentModeRunner`.
///
/// Assertions read the `AgentMessage` that actually crossed `streamAgentMessage`, so a regression
/// that stops composing, composes at the wrong point, or mutates the wrong channel is caught at the
/// provider boundary rather than in a re-implementation of it.
@MainActor
final class AgentSessionLinkHeadlessRunnerPromptAdapterTests: XCTestCase {
    private var harnesses: [AgentSessionLinkRunnerHarness] = []

    override func tearDown() {
        harnesses.removeAll()
        super.tearDown()
    }

    private func makeHarness(
        provider: AgentSessionLinkCapturingHeadlessProvider,
        stubSystemPrompt: String = "BASE INSTRUCTIONS"
    ) -> AgentSessionLinkRunnerHarness {
        let harness = AgentSessionLinkRunnerHarness(
            stubSystemPrompt: stubSystemPrompt,
            headlessProviderFactory: { _, _ in provider }
        )
        harnesses.append(harness)
        return harness
    }

    /// Drives the real `HeadlessAgentModeRunner` directly.
    ///
    /// No shipping agent kind routes to this runner through `AgentModeRunService.startRun` (Codex,
    /// Claude-compatible, and ACP kinds each go elsewhere), so constructing the runner is the only way
    /// to exercise its adapter and acceptance boundary.
    private func startRun(
        _ harness: AgentSessionLinkRunnerHarness,
        session: AgentModeViewModel.TabSession,
        message: String
    ) async {
        let runner = harness.makeHeadlessRunner()
        await runner.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: message,
            initialMessageForRun: message,
            attachments: [],
            makeLease: { runID in harness.makeLease(runID: runID, tabID: session.tabID) }
        )
        await session.agentTask?.value
    }

    // MARK: Exactly once

    func testStreamCreationCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        let harness = makeHarness(provider: provider)
        harness.publishInventory(revision: 1, targetCount: 2)
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "headless turn")

        let captured = await provider.messages
        let first = try XCTUnwrap(captured.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            first.userMessage,
            userContent: "headless turn"
        )
        XCTAssertEqual(harness.acceptedClaims.count, 1)

        session.runState = .idle
        await startRun(harness, session: session, message: "second turn")

        let afterSecond = await provider.messages
        XCTAssertEqual(afterSecond.count, 2)
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(afterSecond.last).userMessage
        )
        XCTAssertEqual(harness.acceptedClaims.count, 1, "one accepted revision, one acknowledgement")
        MonitorSupplementAssertions.assertNotPersisted(in: session)
    }

    // MARK: Required lane refusal

    func testHeadlessAutoWakeWithUnavailableRequiredBatchMakesNoProviderCall() async {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        let harness = makeHarness(provider: provider)
        harness.publishInventory(revision: 1, targetCount: 1)
        harness.forcedAutoWakeID = UUID()
        harness.passiveNotices = nil
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "")

        let providerMessageCount = await provider.messageCount
        XCTAssertEqual(providerMessageCount, 0)
        XCTAssertTrue(harness.acceptedClaims.isEmpty)
        XCTAssertFalse(session.items.contains(where: { $0.kind == .error }))
    }

    // MARK: Stream-creation failure

    func testStreamCreationFailureLeavesTheClaimPendingForTheNextTurn() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
        let harness = makeHarness(provider: provider)
        harness.publishInventory(revision: 1, targetCount: 1)
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "failing turn")

        let afterFailure = await provider.messages
        let failed = try XCTUnwrap(afterFailure.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            failed.userMessage,
            userContent: "failing turn"
        )
        XCTAssertTrue(
            harness.acceptedClaims.isEmpty,
            "a throwing stream creation is not an acceptance signal"
        )

        // The supplement is still owed, and the retry ships a byte-equivalent fragment.
        session.runState = .idle
        await startRun(harness, session: session, message: "retry turn")

        let afterRetry = await provider.messages
        let retried = try XCTUnwrap(afterRetry.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            retried.userMessage,
            userContent: "retry turn"
        )
        XCTAssertEqual(harness.acceptedClaims.count, 1)
        XCTAssertEqual(
            harness.acceptedClaims.first?.fragment,
            fragment(of: failed.userMessage),
            "a revision-stable retry must reuse the same rendered fragment"
        )
    }

    // MARK: Composition point

    func testMembershipChangeDuringLeaseInitializationIsReflectedAtDispatch() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        let harness = makeHarness(provider: provider)
        harness.publishInventory(revision: 1, targetCount: 1)
        let session = harness.makeSession(agent: .openCode)

        // Enqueued while the runner is still synchronously on MainActor building the message, so it
        // runs during the very next suspension — the lease's `providerInitializationStarted` hop.
        // Composing before that hop would ship revision 1; composing after it ships revision 2.
        harness.onHeadlessMessageBuilt = { [weak harness] in
            harness?.onHeadlessMessageBuilt = nil
            Task { @MainActor in harness?.publishInventory(revision: 2, targetCount: 5) }
        }

        await startRun(harness, session: session, message: "headless turn")

        let captured = await provider.messages
        let message = try XCTUnwrap(captured.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            message.userMessage,
            userContent: "headless turn"
        )
        XCTAssertTrue(
            message.userMessage.contains("count=\"5\""),
            "membership changed during the lease hop must reach the provider"
        )
        XCTAssertEqual(harness.acceptedClaims.first?.linkSetRevision, 2)
    }

    // MARK: Revocation

    func testLastLinkRevocationDeliversOneClosingNoticeThenSilence() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        let harness = makeHarness(provider: provider)
        harness.publishInventory(revision: 1, targetCount: 1)
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "linked turn")

        harness.publishInventory(revision: 2, targetCount: 0)
        session.runState = .idle
        await startRun(harness, session: session, message: "after revoke")

        let afterRevoke = await provider.messages
        let closing = try XCTUnwrap(afterRevoke.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            closing.userMessage,
            userContent: "after revoke"
        )
        XCTAssertTrue(closing.userMessage.contains("status=\"ended\""))

        session.runState = .idle
        await startRun(harness, session: session, message: "silent turn")

        let afterSilence = await provider.messages
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(afterSilence.last).userMessage
        )
        XCTAssertEqual(harness.acceptedClaims.count, 2, "inventory once, closing notice once")
    }

    // MARK: System prompt channel

    func testClaudeCompatibleNativeSystemModeLeavesSystemPromptUntouched() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        // `nativeSystemPrompt` delivery: base instructions ride the system channel.
        let harness = makeHarness(provider: provider, stubSystemPrompt: "CLAUDE BASE INSTRUCTIONS")
        harness.publishInventory(revision: 1, targetCount: 1)
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "claude headless turn")

        let captured = await provider.messages
        let message = try XCTUnwrap(captured.first)
        XCTAssertEqual(message.systemPrompt, "CLAUDE BASE INSTRUCTIONS")
        XCTAssertFalse(message.systemPrompt.contains(AgentSessionLinkPrompts.envelopeTag))
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            message.userMessage,
            userContent: "claude headless turn"
        )
    }

    func testGenericHeadlessEmptySystemModeLeavesSystemPromptUntouched() async throws {
        let provider = AgentSessionLinkCapturingHeadlessProvider()
        // `userMessageXML`-with-empty-system delivery: nothing may appear in the system channel.
        let harness = makeHarness(provider: provider, stubSystemPrompt: "")
        harness.publishInventory(revision: 1, targetCount: 1)
        let session = harness.makeSession(agent: .openCode)

        await startRun(harness, session: session, message: "generic headless turn")

        let captured = await provider.messages
        let message = try XCTUnwrap(captured.first)
        XCTAssertEqual(message.systemPrompt, "")
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            message.userMessage,
            userContent: "generic headless turn"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: session)
    }

    // MARK: Helpers

    private func fragment(of text: String) -> String? {
        guard let range = text.range(of: MonitorSupplementAssertions.openTag) else { return nil }
        return String(text[range.lowerBound...])
    }
}

/// ACP runner adapter, driven through the real `ACPIntegratedAgentModeRunner` and a real
/// `ACPAgentSessionController` talking to a scripted ACP server over stdio.
///
/// Capture happens in the provider's `buildPromptBlocks`, which the controller invokes inside
/// `prompt`, so every assertion reads the message that actually reached `controller.prompt`.
@MainActor
final class AgentSessionLinkACPRunnerPromptAdapterTests: XCTestCase {
    private var harnesses: [AgentSessionLinkRunnerHarness] = []
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        harnesses.removeAll()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let harness: AgentSessionLinkRunnerHarness
        let provider: AgentSessionLinkCapturingACPProvider
        let session: AgentModeViewModel.TabSession
        let request: ACPRunRequest
        let workspacePath: String
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkACPRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFixture(failPromptsContaining: String? = nil) throws -> Fixture {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: workspace)
        var environment: [String: String] = [:]
        if let failPromptsContaining {
            environment["ACP_FAIL_PROMPTS_CONTAINING"] = failPromptsContaining
        }
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .openCode,
            commandPath: scriptURL.path,
            environment: environment
        )
        let harness = AgentSessionLinkRunnerHarness(
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acpProviderFactory: { _, _ in provider },
            workspacePath: workspace.path
        )
        harnesses.append(harness)
        let session = harness.makeSession(agent: .openCode)
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        return Fixture(
            harness: harness,
            provider: provider,
            session: session,
            request: request,
            workspacePath: workspace.path
        )
    }

    private func startRun(_ fixture: Fixture, message: String) async {
        _ = await fixture.harness.service.startRun(
            tabID: fixture.session.tabID,
            session: fixture.session,
            initialUserMessage: message,
            initialMessageForRun: message,
            attachments: []
        )
        await fixture.session.agentTask?.value
    }

    // MARK: Required lane refusal

    func testACPAutoWakeWithUnavailableRequiredBatchMakesNoProviderCall() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        fixture.harness.forcedAutoWakeID = UUID()
        fixture.harness.passiveNotices = nil

        await startRun(fixture, message: "")

        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        XCTAssertTrue(fixture.harness.acceptedClaims.isEmpty)
        XCTAssertFalse(fixture.session.items.contains(where: { $0.kind == .error }))
    }

    // MARK: Initial, reuse, follow-up

    func testInitialPromptCarriesExactlyOneSupplement() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 2)

        await startRun(fixture, message: "acp initial")

        let prompted = fixture.provider.promptedMessages
        let first = try XCTUnwrap(prompted.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            first.userMessage,
            userContent: "acp initial"
        )
        XCTAssertFalse(
            first.systemPrompt.contains(AgentSessionLinkPrompts.envelopeTag),
            "resumed ACP sessions omit systemPrompt, so the supplement must ride the user channel"
        )
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1)
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testNonThrowingPromptReturnConsumesTheRevisionExactlyOnce() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)

        await startRun(fixture, message: "acp initial")
        fixture.session.runState = .idle
        await startRun(fixture, message: "acp follow-up")

        let prompted = fixture.provider.promptedMessages
        XCTAssertEqual(prompted.count, 2)
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(prompted.last).userMessage
        )
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1)
    }

    func testReusedSessionFollowUpDeliversTheNewMembershipRevision() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await startRun(fixture, message: "acp initial")

        fixture.harness.publishInventory(revision: 2, targetCount: 3)
        fixture.session.runState = .idle
        await startRun(fixture, message: "acp follow-up")

        let prompted = fixture.provider.promptedMessages
        let followUp = try XCTUnwrap(prompted.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            followUp.userMessage,
            userContent: "acp follow-up"
        )
        XCTAssertTrue(followUp.userMessage.contains("count=\"3\""))
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 2)
    }

    // MARK: Composition point

    func testMembershipChangeDuringPrepareForNextTurnIsReflectedAtDispatch() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await startRun(fixture, message: "acp initial")
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1)

        // Fires after the message is built and before `prepareForNextTurn()` suspends — exactly the
        // window the old composition point sat in. Composing there would ship revision 1 (already
        // acknowledged, so: nothing at all); composing after the suspension ships revision 2.
        fixture.harness.onAttachmentsConsumed = { [weak harness = fixture.harness] in
            harness?.publishInventory(revision: 2, targetCount: 4)
            harness?.onAttachmentsConsumed = nil
        }
        fixture.session.runState = .idle
        await startRun(fixture, message: "acp reused turn")

        let prompted = fixture.provider.promptedMessages
        let reused = try XCTUnwrap(prompted.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            reused.userMessage,
            userContent: "acp reused turn"
        )
        XCTAssertTrue(
            reused.userMessage.contains("count=\"4\""),
            "membership added while the turn was suspended must reach the provider"
        )
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 2)
    }

    // MARK: Revocation

    func testLastLinkRevocationDeliversOneClosingNoticeThenSilence() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await startRun(fixture, message: "acp linked")

        fixture.harness.publishInventory(revision: 2, targetCount: 0)
        fixture.session.runState = .idle
        await startRun(fixture, message: "acp after revoke")

        let prompted = fixture.provider.promptedMessages
        let closing = try XCTUnwrap(prompted.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            closing.userMessage,
            userContent: "acp after revoke"
        )
        XCTAssertTrue(closing.userMessage.contains("status=\"ended\""))

        fixture.session.runState = .idle
        await startRun(fixture, message: "acp silent turn")

        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(fixture.provider.promptedMessages.last).userMessage
        )
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 2)
    }

    // MARK: Active steering

    func testActiveSteeringPromptCarriesExactlyOneSupplement() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await startRun(fixture, message: "acp initial")

        // Steering owes a fresh supplement only when membership moved.
        fixture.harness.publishInventory(revision: 2, targetCount: 2)
        let controller = try XCTUnwrap(fixture.session.acpController)
        fixture.session.runState = .running
        // Run identity is installed through the process-identity owner; `ensureProcessRunID` is the
        // reuse-or-create operation that replaced direct `runID` assignment.
        _ = AgentModeProcessRunIdentity.ensureProcessRunID(for: fixture.session)
        fixture.session.beginRunAttempt(source: "test.acp.steer")

        let sent = await fixture.harness.service.test_submitACPActivePrompt(
            session: fixture.session,
            messageForRun: "acp steering",
            runRequest: fixture.request,
            controller: controller
        )
        XCTAssertTrue(sent, "the scripted server accepts the steering prompt")

        let prompted = fixture.provider.promptedMessages
        let steered = try XCTUnwrap(prompted.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            steered.userMessage,
            userContent: "acp steering"
        )
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 2)
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testFailedSteerRequeuedAsFollowUpDeliversExactlyOneFragment() async throws {
        // The scripted server rejects any prompt carrying this marker, so the steering attempt fails
        // while the later follow-up (different text) succeeds.
        let fixture = try makeFixture(failPromptsContaining: "acp steering")
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await startRun(fixture, message: "acp initial")
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1)

        fixture.harness.publishInventory(revision: 2, targetCount: 2)
        let controller = try XCTUnwrap(fixture.session.acpController)
        fixture.session.runState = .running
        fixture.session.beginRunAttempt(source: "test.acp.failed-steer")

        let sent = await fixture.harness.service.test_submitACPActivePrompt(
            session: fixture.session,
            messageForRun: "acp steering",
            runRequest: fixture.request,
            controller: controller
        )
        XCTAssertFalse(sent, "the rejected steer must report failure so the batch requeues")
        XCTAssertEqual(
            fixture.harness.acceptedClaims.count,
            1,
            "a failed steer is not an acceptance signal"
        )

        // Requeued as an ordinary follow-up turn.
        fixture.session.runState = .idle
        await startRun(fixture, message: "acp requeued follow-up")

        let prompted = fixture.provider.promptedMessages
        let followUp = try XCTUnwrap(prompted.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            followUp.userMessage,
            userContent: "acp requeued follow-up"
        )
        XCTAssertEqual(
            fixture.harness.acceptedClaims.count,
            2,
            "revision 2 is delivered exactly once across the failed steer and its requeue"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }
}
