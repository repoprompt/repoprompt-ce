import Combine
import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

// Overseer compaction on ACP sessions.
//
// LIVE-UNVERIFIED: no provider-recorded `available_commands_update` or post-`/compact` traffic
// exists yet. Every fixture here is synthetic, modelled on the ACP spec's shapes
// (`available_commands_update` with `availableCommands: [{name, description, input}]`, a slash
// command sent as the text of an ordinary `session/prompt`, and `usage_update` with `used`/`size`).
// These suites pin RepoPrompt's side of the contract only; whether a given agent compacts on
// `/compact` is not established by them.

private enum ACPCompactFixtures {
    static let sessionID = "monitor-acp-session"

    static func makeTemporaryDirectory(tracking urls: inout [URL]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkACPCompact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        urls.append(url)
        return url
    }

    /// Each `session/prompt` `prompt` array the fake server received, in order.
    static func loggedPrompts(at url: URL) throws -> [[[String: String]]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [[String: String]], "prompt blocks must be string-valued")
        }
    }

    static let bareCompactPrompt: [[String: String]] = [["type": "text", "text": "/compact"]]
}

// MARK: - Controller: advertisement capture and the raw command prompt

final class ACPAdvertisedCommandControllerTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var controllers: [ACPAgentSessionController] = []

    override func tearDown() async throws {
        for controller in controllers {
            await controller.shutdown()
        }
        controllers.removeAll()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try await super.tearDown()
    }

    private struct Fixture {
        let controller: ACPAgentSessionController
        let provider: AgentSessionLinkCapturingACPProvider
        let promptLog: URL
        let request: ACPRunRequest
    }

    private func makeBootstrappedController(environment: [String: String]) async throws -> Fixture {
        let directory = try ACPCompactFixtures.makeTemporaryDirectory(tracking: &temporaryURLs)
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: directory)
        let promptLog = directory.appendingPathComponent("prompts.jsonl")
        var environment = environment
        environment["ACP_PROMPT_LOG"] = promptLog.path
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .antigravity,
            commandPath: scriptURL.path,
            environment: environment
        )
        let request = ACPRunRequest(
            agentKind: .antigravity,
            modelString: nil,
            workspacePath: directory.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        controllers.append(controller)
        _ = try await controller.bootstrap()
        return Fixture(controller: controller, provider: provider, promptLog: promptLog, request: request)
    }

    private func waitForAdvertisement(_ controller: ACPAgentSessionController) async throws {
        try await AsyncTestWait.waitUntil("the post-session/new advertisement to be captured") {
            controller.currentAdvertisedCommands() != nil
        }
    }

    func testTheAdvertisementIsRecordedForTheAdvertisingSessionOnly() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "compact,/review"])
        try await waitForAdvertisement(fixture.controller)

        XCTAssertEqual(
            fixture.controller.currentAdvertisedCommands(),
            .init(sessionID: ACPCompactFixtures.sessionID, names: ["compact", "review"]),
            "Names are stored without a leading slash"
        )
        XCTAssertTrue(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))
        XCTAssertFalse(
            fixture.controller.advertisesCommand("compact", inProviderSession: "another-session"),
            "A stale or foreign advertisement never authorizes another provider session"
        )
        XCTAssertFalse(fixture.controller.advertisesCommand("init", inProviderSession: ACPCompactFixtures.sessionID))
    }

    func testTheAdvertisedCommandIsSentAsExactlyOneBareTextBlock() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "compact"])
        try await waitForAdvertisement(fixture.controller)

        try await fixture.controller.promptAdvertisedCommand("compact", expectedSessionID: ACPCompactFixtures.sessionID)

        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog), [ACPCompactFixtures.bareCompactPrompt])
        XCTAssertTrue(
            fixture.provider.promptedMessages.isEmpty,
            "The provider's prompt builder (system prompt, framing, attachments) is never consulted"
        )
    }

    func testAnUnadvertisedCommandOrAnotherSessionIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "review"])
        try await waitForAdvertisement(fixture.controller)

        do {
            try await fixture.controller.promptAdvertisedCommand("compact", expectedSessionID: ACPCompactFixtures.sessionID)
            XCTFail("An unadvertised command must be refused")
        } catch is ACPAgentSessionController.ProviderCommandRefusal {}
        do {
            try await fixture.controller.promptAdvertisedCommand("review", expectedSessionID: "another-session")
            XCTFail("A command admitted for another provider session must be refused")
        } catch is ACPAgentSessionController.ProviderCommandRefusal {}

        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog), [])
        let reusable = await fixture.controller.hasReusableSession
        XCTAssertTrue(reusable, "A refusal leaves the session open and usable")
    }

    func testAReplacementListWithoutTheCommandWithdrawsIt() async throws {
        let fixture = try await makeBootstrappedController(environment: [
            "ACP_ADVERTISE_COMMANDS": "compact",
            "ACP_ADVERTISE_AFTER_PROMPT": "review"
        ])
        try await waitForAdvertisement(fixture.controller)
        XCTAssertTrue(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))

        try await fixture.controller.prompt(AgentMessage(userMessage: "ordinary turn"), request: fixture.request)

        XCTAssertFalse(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))
        XCTAssertTrue(fixture.controller.advertisesCommand("review", inProviderSession: ACPCompactFixtures.sessionID))
    }

    func testAMalformedListAdvertisesNothing() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "__malformed__"])
        try await waitForAdvertisement(fixture.controller)

        XCTAssertEqual(fixture.controller.currentAdvertisedCommands()?.names, [])
        XCTAssertFalse(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))
    }

    func testAnUpdateNamingAnotherSessionNeverReplacesTheOpenSessionsList() async throws {
        let fixture = try await makeBootstrappedController(environment: [
            "ACP_ADVERTISE_COMMANDS": "compact",
            "ACP_FOREIGN_ADVERTISE_AFTER_PROMPT": "review"
        ])
        try await waitForAdvertisement(fixture.controller)

        try await fixture.controller.prompt(AgentMessage(userMessage: "ordinary turn"), request: fixture.request)

        XCTAssertEqual(
            fixture.controller.currentAdvertisedCommands(),
            .init(sessionID: ACPCompactFixtures.sessionID, names: ["compact"])
        )
    }

    func testACommandWhileATurnIsInFlightIsRefusedAndWritesNothing() async throws {
        let directory = try ACPCompactFixtures.makeTemporaryDirectory(tracking: &temporaryURLs)
        let gate = try AgentSessionLinkACPResponseGate(directory: directory)
        let fixture = try await makeBootstrappedController(environment: [
            "ACP_ADVERTISE_COMMANDS": "compact",
            "ACP_HOLD_METHOD": "session/prompt",
            "ACP_RESPONSE_GATE": gate.path
        ])
        try await waitForAdvertisement(fixture.controller)
        let controller = fixture.controller
        let request = fixture.request
        let ordinary = Task { try await controller.prompt(AgentMessage(userMessage: "ordinary turn"), request: request) }
        try await gate.waitUntilEntered()

        do {
            try await controller.promptAdvertisedCommand("compact", expectedSessionID: ACPCompactFixtures.sessionID)
            XCTFail("A command must never be written into an in-flight turn")
        } catch let refusal as ACPAgentSessionController.ProviderCommandRefusal {
            XCTAssertTrue(refusal.sessionIsUsable, "The session is healthy, only busy")
        }
        gate.release()
        try await ordinary.value

        let prompts = try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertNotEqual(prompts.first, ACPCompactFixtures.bareCompactPrompt)
    }

    func testARefusalAfterShutdownMarksTheSessionUnusable() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "compact"])
        try await waitForAdvertisement(fixture.controller)
        let retiredWhileOpen = await fixture.controller.isRetired
        XCTAssertFalse(retiredWhileOpen, "An open, idle session is not retired")
        await fixture.controller.shutdown()
        let retiredAfterShutdown = await fixture.controller.isRetired
        XCTAssertTrue(retiredAfterShutdown)

        do {
            try await fixture.controller.promptAdvertisedCommand("compact", expectedSessionID: ACPCompactFixtures.sessionID)
            XCTFail("A closed controller must refuse")
        } catch let refusal as ACPAgentSessionController.ProviderCommandRefusal {
            XCTAssertFalse(refusal.sessionIsUsable, "Its owner must retire it as after any failed turn")
        }
    }

    func testAProtocolFailureDropsTheAdvertisement() async throws {
        // The server fails the controller with an unmatched response id, then re-advertises `compact`
        // for the same session when the failed prompt's `session/cancel` arrives — strictly after the
        // controller has failed. A retired controller must not pick that up.
        let fixture = try await makeBootstrappedController(environment: [
            "ACP_ADVERTISE_COMMANDS": "compact",
            "ACP_UNMATCHED_RESPONSE_ON_PROMPT": "1",
            "ACP_ADVERTISE_ON_CANCEL": "compact"
        ])
        try await waitForAdvertisement(fixture.controller)

        _ = try? await fixture.controller.prompt(AgentMessage(userMessage: "ordinary turn"), request: fixture.request)

        // Absence cannot be awaited; give the late advertisement a bounded window to (wrongly) land.
        for _ in 0 ..< 10 {
            XCTAssertNil(fixture.controller.currentAdvertisedCommands(), "A failed controller advertises nothing")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))
    }

    /// The current request must match the resumed Devin process's launch-time permission mode.
    /// A command never relaunches to apply a changed mode, or normalizes an unrecognized mode into
    /// authority. The final actor-owned dispatch seam must refuse it without writing a prompt.
    func testAResumedDevinCommandIsCheckedAgainstTheCurrentRequest() async throws {
        let directory = try ACPCompactFixtures.makeTemporaryDirectory(tracking: &temporaryURLs)
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: directory)
        let promptLog = directory.appendingPathComponent("prompts.jsonl")
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .devin,
            commandPath: scriptURL.path,
            environment: [
                "ACP_LOAD": "1",
                "ACP_ADVERTISE_COMMANDS": "compact",
                "ACP_PROMPT_LOG": promptLog.path
            ]
        )
        func request(launchPermissionMode: String?) -> ACPRunRequest {
            ACPRunRequest(
                agentKind: .devin,
                modelString: nil,
                workspacePath: directory.path,
                resumeSessionID: "resumed-devin",
                attachments: [],
                taskLabelKind: nil,
                launchPermissionMode: launchPermissionMode
            )
        }
        // Opened while an applicable permission level was selected.
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request(launchPermissionMode: "auto"))
        controllers.append(controller)
        _ = try await controller.bootstrap()
        try await AsyncTestWait.waitUntil("the load advertisement to be captured") {
            controller.advertisesCommand("compact", inProviderSession: "resumed-devin")
        }

        for mode in ["dangerous", "unknown-mode"] {
            do {
                try await controller.promptAdvertisedCommand(
                    "compact",
                    expectedSessionID: "resumed-devin",
                    request: request(launchPermissionMode: mode)
                )
                XCTFail("A changed or unrecognized launch mode must be refused before the write")
            } catch let refusal as ACPAgentSessionController.ProviderCommandRefusal {
                XCTAssertTrue(refusal.sessionIsUsable)
            }
            let reusable = await controller.hasReusableSession
            XCTAssertTrue(reusable, "Refusal retains the live controller; it must not relaunch")
        }
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: promptLog), [], "Nothing was written")

        try await controller.promptAdvertisedCommand(
            "compact",
            expectedSessionID: "resumed-devin",
            request: request(launchPermissionMode: "auto")
        )
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: promptLog), [ACPCompactFixtures.bareCompactPrompt])
    }

    func testShutdownDropsTheAdvertisement() async throws {
        let fixture = try await makeBootstrappedController(environment: ["ACP_ADVERTISE_COMMANDS": "compact"])
        try await waitForAdvertisement(fixture.controller)

        await fixture.controller.shutdown()

        XCTAssertNil(fixture.controller.currentAdvertisedCommands())
        XCTAssertFalse(fixture.controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID))
    }
}

// MARK: - Run service and ACP runner

@MainActor
final class AgentSessionLinkACPCompactRunnerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private var harnesses: [AgentSessionLinkRunnerHarness] = []
    private var temporaryURLs: [URL] = []

    override func tearDown() async throws {
        for controller in liveControllers {
            await controller.shutdown()
        }
        liveControllers.removeAll()
        harnesses.removeAll()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try await super.tearDown()
    }

    private var liveControllers: [ACPAgentSessionController] = []

    private struct Fixture {
        let harness: AgentSessionLinkRunnerHarness
        let provider: AgentSessionLinkCapturingACPProvider
        let session: AgentModeViewModel.TabSession
        let promptLog: URL
        let binding: AgentPersistentSessionBindingIdentity
    }

    private func makeFixture(
        agent: AgentProviderKind = .antigravity,
        providerID: ACPProviderID = .antigravity,
        environment: [String: String] = ["ACP_ADVERTISE_COMMANDS": "compact"]
    ) throws -> Fixture {
        let workspace = try ACPCompactFixtures.makeTemporaryDirectory(tracking: &temporaryURLs)
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: workspace)
        let promptLog = workspace.appendingPathComponent("prompts.jsonl")
        var environment = environment
        environment["ACP_PROMPT_LOG"] = promptLog.path
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: providerID,
            commandPath: scriptURL.path,
            environment: environment
        )
        let harness = AgentSessionLinkRunnerHarness(
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acpProviderFactory: { _, _ in provider },
            workspacePath: workspace.path
        )
        harnesses.append(harness)
        let session = harness.makeSession(agent: agent)
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        session.installPersistentSessionBinding(binding)
        return Fixture(harness: harness, provider: provider, session: session, promptLog: promptLog, binding: binding)
    }

    private func run(_ fixture: Fixture, message: String) async {
        _ = await fixture.harness.service.startRun(
            tabID: fixture.session.tabID,
            session: fixture.session,
            initialUserMessage: message,
            initialMessageForRun: message,
            attachments: []
        )
        await fixture.session.agentTask?.value
        XCTAssertEqual(fixture.session.runState, .completed, "The ordinary turn must leave a live session")
        if let controller = fixture.session.acpController, !liveControllers.contains(where: { $0 === controller }) {
            liveControllers.append(controller)
        }
    }

    @discardableResult
    private func runCommand(
        _ fixture: Fixture,
        _ command: AgentProviderControlCommand
    ) async -> AgentRunStartOutcomeRecorder {
        let recorder = AgentRunStartOutcomeRecorder()
        _ = await fixture.harness.service.startRun(
            tabID: fixture.session.tabID,
            session: fixture.session,
            initialUserMessage: command.providerText,
            initialMessageForRun: command.providerText,
            attachments: [],
            providerControlCommand: command,
            startOutcome: recorder
        )
        await fixture.session.agentTask?.value
        return recorder
    }

    private func compactCommand(
        _ fixture: Fixture,
        binding: AgentPersistentSessionBindingIdentity? = nil,
        conversation: String = ACPCompactFixtures.sessionID
    ) -> AgentProviderControlCommand {
        .compact(expectedBinding: binding ?? fixture.binding, expectedProviderConversation: conversation)
    }

    func testTheCommandRunsOnTheLiveControllerAsTheBarePromptAndLeavesTheSupplementOwed() async throws {
        let fixture = try makeFixture()
        fixture.harness.publishInventory(revision: 1, targetCount: 1)
        await run(fixture, message: "acp initial")
        let liveController = try XCTUnwrap(fixture.session.acpController)
        XCTAssertEqual(fixture.session.providerSessionID, ACPCompactFixtures.sessionID)
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1)

        fixture.harness.publishInventory(revision: 2, targetCount: 2)
        fixture.session.runState = .idle
        fixture.session.contextUsageSnapshot = ContextUsageSnapshot(
            used: 900,
            window: 1000,
            confidence: .exact,
            source: .acpUsageEvent,
            compactedAt: nil
        )
        fixture.session.noteLiveContextUsageReport(contextUsedTokens: 900, promptTokens: nil, modelContextWindow: 1000)
        XCTAssertEqual(fixture.session.vouchedContextCount?.tokens, 900)
        let outcome = await runCommand(fixture, compactCommand(fixture))

        XCTAssertTrue(outcome.outcome.didStart)
        let prompts = try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts.last, ACPCompactFixtures.bareCompactPrompt, "Exactly /compact: no supplement, handoff, or framing")
        XCTAssertEqual(fixture.provider.promptedMessages.count, 1, "The command never goes through the provider's prompt builder")
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 1, "The command consumes no oversight revision")
        XCTAssertTrue(fixture.session.acpController === liveController, "The live controller is reused, never replaced")
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertNil(fixture.session.vouchedContextCount, "The count vouch is invalidated at dispatch")
        XCTAssertEqual(fixture.session.vouchedContextWindow?.tokens, 1000)
        XCTAssertFalse(fixture.session.contextCountVouchAwaitsOccupancyReport, "The suspension ends with the turn")

        // The revision the command skipped is still owed to the next ordinary turn.
        fixture.session.runState = .idle
        await run(fixture, message: "acp follow-up")
        XCTAssertEqual(fixture.harness.acceptedClaims.count, 2)
        XCTAssertTrue(fixture.session.acpController === liveController)
    }

    /// Devin's `/compact` is fire-and-forget: the prompt answer returns immediately with an empty
    /// turn while compaction continues in the provider's background. A lane transcript row must
    /// say so — both so the lane's user sees it and so nothing reads the empty turn as done or
    /// failed. The fake provider answers every prompt instantly with no stream events, which is
    /// exactly that signature.
    func testAnInstantlyEmptyCommandTurnLeavesABackgroundCompactionNote() async throws {
        let fixture = try makeFixture()
        let itemsBeforeOrdinary = fixture.session.items.count
        await run(fixture, message: "acp initial")
        XCTAssertTrue(
            fixture.session.items.dropFirst(itemsBeforeOrdinary)
                .allSatisfy { !($0.kind == .system && $0.text.contains("background")) },
            "The note is scoped to provider control commands, not every instant-empty turn"
        )
        XCTAssertFalse(fixture.session.isSettlingACPBackgroundCompaction, "Only a compaction command is held")
        fixture.session.runState = .idle
        let before = fixture.session.items.count

        let outcome = await runCommand(fixture, compactCommand(fixture))

        XCTAssertTrue(outcome.outcome.didStart)
        XCTAssertEqual(fixture.session.runState, .completed)
        let appended = fixture.session.items.dropFirst(before)
        let notes = appended.filter { $0.kind == .system && $0.text.contains("background") }
        XCTAssertEqual(
            notes.count,
            1,
            "One row names the unobservable background work instead of a silently empty turn"
        )
        XCTAssertTrue(notes.allSatisfy { $0.text.contains("cancel") })
        XCTAssertTrue(
            fixture.session.isSettlingACPBackgroundCompaction,
            "The signature is enforced, not only described: the session is held while it settles"
        )
        XCTAssertEqual(
            AgentSessionLinkDeliveryReadiness.evaluate(
                snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
                    session: fixture.session,
                    endpointMatchesGrant: true,
                    isClosing: false
                )
            ),
            .blocked(.targetNotIdle)
        )

        // The session's own next turn proceeds (its user is never held) and ends the hold, which
        // that turn has made moot.
        fixture.session.runState = .idle
        await run(fixture, message: "acp follow-up")
        XCTAssertFalse(fixture.session.isSettlingACPBackgroundCompaction)
    }

    func testSelfCompactPreparationRefusalAfterPipelineStartSettlesTheBoundAttempt() async throws {
        let fixture = try makeFixture()
        await run(fixture, message: "acp initial")
        let controller = try XCTUnwrap(fixture.session.acpController)
        fixture.session.runState = .idle
        let owner = AgentSelfCompactOwner(
            windowID: 1, workspaceID: UUID(), tabID: fixture.session.tabID,
            sessionID: fixture.binding.sessionID,
            persistentBindingGeneration: fixture.binding.generation,
            bindingTransitionGeneration: fixture.session.bindingTransitionGeneration,
            runID: UUID(), runAttemptID: UUID()
        )
        var attempt = AgentSelfCompactAttempt(
            idempotencyKey: "acp-preparation-refusal", note: "recoverable continuation",
            owner: owner, phase: .awaitingCompactTurn
        )
        attempt.admittedSupport = .acpAdvertisedCommand
        fixture.session.selfCompactState = AgentSelfCompactState(active: attempt)
        let coordinator = AgentSelfCompactNativeCompletionCoordinator(
            load: { fixture.session.selfCompactState },
            store: { fixture.session.selfCompactState = $0 },
            isCurrentOwner: { _ in true },
            dispatchNote: { _, _ in XCTFail("Failed command must not send the note")
                return false
            }
        )
        fixture.session.selfCompactNativeCompletion = coordinator
        await controller.test_rejectNextTurnPreparation()
        let command = AgentProviderControlCommand.compact(
            expectedBinding: fixture.binding,
            expectedProviderConversation: ACPCompactFixtures.sessionID,
            selfCompactDispatchID: .init(requestID: attempt.id, stage: .compact)
        )
        let recorder = AgentRunStartOutcomeRecorder()
        _ = await fixture.harness.service.startRun(
            tabID: fixture.session.tabID, session: fixture.session,
            initialUserMessage: command.providerText, initialMessageForRun: command.providerText,
            attachments: [], providerControlCommand: command, startOutcome: recorder
        )
        let ownership = try XCTUnwrap(fixture.session.activeRunOwnership)
        let runID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(recorder.outcome.didStart, "The pipeline was accepted before preparation")
        await fixture.session.agentTask?.value
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog).count, 1)
        XCTAssertEqual(fixture.session.runState, .failed)
        XCTAssertEqual(fixture.session.selfCompactState.active?.compactRunID, runID)
        XCTAssertEqual(fixture.session.selfCompactState.active?.compactRunAttemptID, ownership.attemptID)
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(), ownership: ownership, terminalState: .failed,
            failureReason: nil, expectedRunID: runID,
            sourceItemsRevision: fixture.session.sourceItemsRevision,
            assistantDeltaFlushGeneration: fixture.session.assistantDeltaFlushGeneration,
            providerDrainGeneration: fixture.session.providerTerminalDrainGeneration,
            mcpPublicationEnvelope: nil, successorKind: nil, providerSuccessorID: nil
        )
        coordinator.compactTurnSettled(
            revision: revision, publication: .accepted(successorEpoch: nil),
            teardownSettled: { true }, assistantOrToolRowCount: 0
        )
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .failed)
        XCTAssertFalse(fixture.session.selfCompactState.blocksOverseerDelivery)
        XCTAssertFalse(fixture.session.selfCompactState.blocksAutomaticWake)
    }

    func testARefusalAfterARebindSendsNothingAndKeepsTheLiveSession() async throws {
        let fixture = try makeFixture()
        await run(fixture, message: "acp initial")
        let liveController = try XCTUnwrap(fixture.session.acpController)
        fixture.session.runState = .idle

        let staleBinding = AgentPersistentSessionBindingIdentity(tabID: fixture.session.tabID, sessionID: UUID())
        let outcome = await runCommand(fixture, compactCommand(fixture, binding: staleBinding))

        XCTAssertTrue(outcome.outcome.didStart, "Admission passed; the runner refused before the write")
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog).count, 1, "Nothing was sent")
        XCTAssertEqual(fixture.session.runState, .failed)
        XCTAssertTrue(fixture.session.acpController === liveController, "A pre-send refusal never discards the warm session")
        let reusable = await liveController.hasReusableSession
        XCTAssertTrue(reusable, "…nor shuts its process down")

        fixture.session.runState = .idle
        await run(fixture, message: "acp follow-up")
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog).count, 2)
        XCTAssertTrue(fixture.session.acpController === liveController, "The next ordinary turn reuses it")
    }

    func testAWithdrawnAdvertisementIsRefusedBeforeARunStarts() async throws {
        let fixture = try makeFixture(environment: [
            "ACP_ADVERTISE_COMMANDS": "compact",
            "ACP_ADVERTISE_AFTER_PROMPT": "review"
        ])
        await run(fixture, message: "acp initial")
        let liveController = try XCTUnwrap(fixture.session.acpController)
        fixture.session.runState = .idle

        let outcome = await runCommand(fixture, compactCommand(fixture))

        XCTAssertFalse(outcome.outcome.didStart)
        XCTAssertEqual(fixture.session.runState, .idle, "No run attempt began")
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog).count, 1)
        XCTAssertTrue(fixture.session.acpController === liveController)
    }

    func testACommandForAnotherProviderConversationIsRefusedBeforeARunStarts() async throws {
        let fixture = try makeFixture()
        await run(fixture, message: "acp initial")
        fixture.session.runState = .idle

        let outcome = await runCommand(fixture, compactCommand(fixture, conversation: "earlier-session"))

        XCTAssertFalse(outcome.outcome.didStart)
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog).count, 1)
    }

    func testWithoutALiveSessionNoProcessIsLaunched() async throws {
        let fixture = try makeFixture()
        fixture.session.providerSessionID = ACPCompactFixtures.sessionID

        let outcome = await runCommand(fixture, compactCommand(fixture))

        XCTAssertFalse(outcome.outcome.didStart)
        XCTAssertNil(fixture.session.acpController, "A command never starts a fresh ACP process")
        XCTAssertEqual(try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog), [])
    }

    func testOpenCodeAndCursorNeverDispatchEvenWhileAdvertising() async throws {
        for (agent, providerID) in [(AgentProviderKind.openCode, ACPProviderID.openCode), (.cursor, .cursor)] {
            let fixture = try makeFixture(agent: agent, providerID: providerID)
            await run(fixture, message: "acp initial")
            let controller = try XCTUnwrap(fixture.session.acpController, "\(agent)")
            XCTAssertTrue(
                controller.advertisesCommand("compact", inProviderSession: ACPCompactFixtures.sessionID),
                "\(agent) fixture advertises compact"
            )
            XCTAssertFalse(
                AgentModeRunService.dispatchesProviderControlCommand(compactCommand(fixture), for: fixture.session),
                "\(agent): an advertised `compact` is not trusted as native compaction"
            )
        }
    }
}

// MARK: - View model: support and the whole transaction

@MainActor
final class AgentSessionLinkACPCompactTransactionTests: XCTestCase {
    private var retainedViewModels: [AgentModeViewModel] = []
    private var temporaryURLs: [URL] = []
    private var liveControllers: [ACPAgentSessionController] = []

    override func tearDown() async throws {
        for controller in liveControllers {
            await controller.shutdown()
        }
        liveControllers.removeAll()
        retainedViewModels.removeAll()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try await super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        /// Held because the view model references its workspace manager and prompt manager weakly.
        let manager: WorkspaceManagerViewModel
        let prompt: PromptViewModel
        let apiSettings: APISettingsViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let provider: AgentSessionLinkCapturingACPProvider
        let promptLog: URL
        let workspacePath: String
    }

    private func makeFixture(
        agent: AgentProviderKind = .grokBuild,
        providerID: ACPProviderID = .grokBuild,
        environment: [String: String] = ["ACP_ADVERTISE_COMMANDS": "compact"]
    ) throws -> Fixture {
        let directory = try ACPCompactFixtures.makeTemporaryDirectory(tracking: &temporaryURLs)
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: directory)
        let promptLog = directory.appendingPathComponent("prompts.jsonl")
        var environment = environment
        environment["ACP_PROMPT_LOG"] = promptLog.path
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: providerID,
            commandPath: scriptURL.path,
            environment: environment
        )
        provider.usesDefaultNormalizer = true

        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "ACP overseer compaction",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: directory.path,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            acpProviderFactory: { _, _ in provider },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
                if let runID { await MCPRoutingWaiter.notifyRouted(runID: runID) }
            },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        viewModel.workspaceManager = manager
        // A deterministic availability context: Grok Build is available only through this in-memory
        // flag (setting it directly persists nothing), never through the machine's installed CLIs.
        apiSettings.isGrokBuildConnected = true
        viewModel.promptManager = prompt
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }

        let session = viewModel.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        return Fixture(
            viewModel: viewModel,
            manager: manager,
            prompt: prompt,
            apiSettings: apiSettings,
            tabID: tabID,
            session: session,
            sessionID: sessionID,
            provider: provider,
            promptLog: promptLog,
            workspacePath: directory.path
        )
    }

    /// Installs a bootstrapped, idle controller exactly as a completed ordinary turn leaves it.
    /// The request is the run service's own, so the runner's reuse compatibility check is exact.
    /// `waitForAdvertisement` is off only for fixtures whose fake provider never sends one.
    @discardableResult
    private func installLiveController(
        _ fixture: Fixture,
        waitForAdvertisement: Bool = true
    ) async throws -> ACPAgentSessionController {
        let request = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: fixture.session,
            workspacePath: fixture.workspacePath,
            attachments: [],
            runtimePermission: fixture.viewModel.providerBindingService.runtimePermission(
                for: fixture.session.selectedAgent,
                profile: fixture.session.permissionProfile
            )
        ))
        let controller = try ACPAgentSessionController(provider: fixture.provider, runRequest: request)
        liveControllers.append(controller)
        let bootstrap = try await controller.bootstrap()
        if waitForAdvertisement {
            try await AsyncTestWait.waitUntil("the advertisement to be captured") {
                controller.currentAdvertisedCommands() != nil
            }
        }
        fixture.session.acpController = controller
        fixture.session.providerSessionID = bootstrap.sessionID
        fixture.session.installRunID(UUID())
        return controller
    }

    private static let liveLiveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true,
        targetEndpointIsLive: true,
        targetWindowIsClosing: false
    )

    private let request = AgentSessionLinkCompactRequest(
        linkID: UUID(),
        linkGeneration: 1,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        ),
        observerDisplayName: "Planning"
    )

    /// The candidate is taken at request time, as the bridge does, after the live session is installed.
    private func compact(_ fixture: Fixture) async throws -> AgentSessionLinkSendTransactionOutcome {
        let candidate = try XCTUnwrap(fixture.viewModel.agentSessionLinkCandidate(
            tabID: fixture.tabID,
            sessionID: fixture.sessionID,
            tabName: "ACP lane",
            isWindowClosing: false
        ))
        return await fixture.viewModel.agentSessionLinkPerformCompact(
            to: candidate,
            request: request,
            liveness: { Self.liveLiveness },
            commitAuthorization: { .committed }
        )
    }

    /// A live ACP occupancy report, so the count starts out vouched.
    private func reportOccupancy(_ fixture: Fixture, used: Int, window: Int) {
        _ = fixture.viewModel.ingestNonCodexUsageReport(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: used,
            modelContextWindow: window,
            session: fixture.session
        )
        XCTAssertEqual(fixture.session.vouchedContextCount?.tokens, used)
    }

    func testSupportFollowsTheLiveAdvertisementForTheTargetsOwnProviderSession() async throws {
        let advertising = try makeFixture()
        var support = await advertising.viewModel.agentSessionLinkCompactSupport(for: advertising.session)
        XCTAssertEqual(support, .noProviderSession)
        try await installLiveController(advertising)
        support = await advertising.viewModel.agentSessionLinkCompactSupport(for: advertising.session)
        XCTAssertEqual(support, .acpAdvertisedCommand)
        advertising.session.providerSessionID = "restored-older-session"
        support = await advertising.viewModel.agentSessionLinkCompactSupport(for: advertising.session)
        XCTAssertEqual(
            support,
            .notSupported,
            "An advertisement from another provider session never answers for this one"
        )

        let silent = try makeFixture(environment: ["ACP_ADVERTISE_COMMANDS": "review"])
        try await installLiveController(silent)
        let silentSupport = await silent.viewModel.agentSessionLinkCompactSupport(for: silent.session)
        XCTAssertEqual(silentSupport, .notSupported)

        let relaunched = try makeFixture(agent: .devin, providerID: .devin)
        relaunched.session.providerSessionID = ACPCompactFixtures.sessionID
        let relaunchedSupport = await relaunched.viewModel.agentSessionLinkCompactSupport(for: relaunched.session)
        XCTAssertEqual(
            relaunchedSupport,
            .noProviderSession,
            "No live controller (for example after a relaunch) means the session is retryable, "
                + "not incapable: one ordinary turn brings the provider session up"
        )

        let openCode = try makeFixture(agent: .openCode, providerID: .openCode)
        try await installLiveController(openCode)
        let openCodeSupport = await openCode.viewModel.agentSessionLinkCompactSupport(for: openCode.session)
        XCTAssertEqual(openCodeSupport, .notSupported)
    }

    /// Only a live provider session's *observed* command list can prove incapability. Everything
    /// short of that — no controller at all (post-relaunch), a dead controller, or a live session
    /// whose `available_commands_update` has not been seen — is the retryable `noProviderSession`.
    /// `notSupported` is reserved for a snapshot that provably lacks `compact`.
    func testOnlyALiveSessionsAdvertisementDecidesBetweenRetryableAndUnsupported() async throws {
        let dead = try makeFixture(agent: .devin, providerID: .devin)
        let deadController = try await installLiveController(dead)
        await deadController.shutdown()
        let deadSupport = await dead.viewModel.agentSessionLinkCompactSupport(for: dead.session)
        XCTAssertEqual(
            deadSupport,
            .noProviderSession,
            "A closed controller leaves no live provider session; the next turn reopens one"
        )

        let silent = try makeFixture(agent: .devin, providerID: .devin, environment: [:])
        try await installLiveController(silent, waitForAdvertisement: false)
        let silentSupport = await silent.viewModel.agentSessionLinkCompactSupport(for: silent.session)
        XCTAssertEqual(
            silentSupport,
            .noProviderSession,
            "A live session whose command list was never observed is unproven, not incapable"
        )
    }

    func testAnAcceptedCompactionRecordsTheRequestAndRunsOnlyOnTheLiveSession() async throws {
        let fixture = try makeFixture()
        let controller = try await installLiveController(fixture)
        let before = fixture.session.items.count

        let outcome = try await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertTrue(
            delivery.compactionRunsInBackground,
            "The ACP path is fire-and-forget, so the overseer must be told not to send early"
        )
        // The command run may append its own rows concurrently; the request row is found by
        // identity rather than position.
        let row = try XCTUnwrap(
            fixture.session.items.first(where: { $0.id == delivery.targetItemID })
        )
        XCTAssertEqual(row.kind, .system, "RepoPrompt issued the command, not the target's user")
        XCTAssertEqual(row.text, AgentChatItem.overseerCompactionRequestText)
        XCTAssertEqual(row.crossSessionAttribution?.sourceName, "Planning")
        await fixture.session.agentTask?.value

        // The view model's MCP bootstrap lease cannot be satisfied in this suite (no routing server),
        // so whether the command reaches the wire here is environmental; the exact bytes are pinned
        // by `AgentSessionLinkACPCompactRunnerTests`. What is pinned here: the run ran on the live
        // controller, nothing but the bare command can ever be written, the provider's prompt
        // builder was never consulted, and a pre-send stop keeps the warm session.
        XCTAssertTrue(
            try ACPCompactFixtures.loggedPrompts(at: fixture.promptLog)
                .allSatisfy { $0 == ACPCompactFixtures.bareCompactPrompt }
        )
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        XCTAssertTrue(fixture.session.acpController === controller)
        let reusable = await controller.hasReusableSession
        XCTAssertTrue(reusable)
        XCTAssertFalse(fixture.session.contextCountVouchAwaitsOccupancyReport)
    }

    func testAVouchWithdrawnForAnUnsentCompactionIsRestoredOnlyWhileStillCurrent() throws {
        let fixture = try makeFixture()
        reportOccupancy(fixture, used: 900, window: 1000)

        let withdrawn = fixture.session.beginCompactionContextCountSuspension()
        XCTAssertNil(fixture.session.vouchedContextCount)
        fixture.session.restoreContextCountVouchAfterUnsentCompaction(withdrawn)
        fixture.session.endCompactionContextCountSuspension()
        XCTAssertEqual(fixture.session.vouchedContextCount?.tokens, 900, "Nothing was sent, so the count still stands")

        let second = fixture.session.beginCompactionContextCountSuspension()
        reportOccupancy(fixture, used: 300, window: 1000)
        fixture.session.restoreContextCountVouchAfterUnsentCompaction(second)
        XCTAssertEqual(fixture.session.vouchedContextCount?.tokens, 300, "A newer vouch is never overwritten")
        fixture.session.endCompactionContextCountSuspension()

        let withdrawnAgain = fixture.session.beginCompactionContextCountSuspension()
        // A conflicting report withdraws the (already withdrawn) count while the stored figure stays 300.
        fixture.session.noteLiveContextUsageReport(contextUsedTokens: 1200, promptTokens: nil, modelContextWindow: nil)
        XCTAssertEqual(fixture.session.contextUsageSnapshot?.used, 300)
        fixture.session.restoreContextCountVouchAfterUnsentCompaction(withdrawnAgain)
        XCTAssertNil(fixture.session.vouchedContextCount, "A report that touched the count since the withdrawal wins")
        fixture.session.endCompactionContextCountSuspension()

        reportOccupancy(fixture, used: 300, window: 1000)
        let third = fixture.session.beginCompactionContextCountSuspension()
        fixture.session.contextUsageSnapshot = ContextUsageSnapshot(
            used: 450,
            window: 1000,
            confidence: .bestEffort,
            source: .turnFinalization,
            compactedAt: nil
        )
        fixture.session.restoreContextCountVouchAfterUnsentCompaction(third)
        XCTAssertNil(fixture.session.vouchedContextCount, "A vouch for a figure no longer stored is not restored")
        fixture.session.endCompactionContextCountSuspension()
    }

    /// Exercises the view model's own usage ingestion across one compaction turn, in the order an ACP
    /// turn delivers it: dispatch, optional `usage_update`, then the prompt response's billed usage.
    func testDuringACompactionTurnOnlyAnOccupancyReportVouchesForTheCount() throws {
        let fixture = try makeFixture()
        fixture.session.acpController = nil
        reportOccupancy(fixture, used: 900, window: 1000)

        // The run's own turn accounting (what `startRun` calls) opens the turn.
        fixture.viewModel.startNonCodexTurnAccountingIfNeeded(for: fixture.session, initialMessage: "/compact")
        fixture.session.beginCompactionContextCountSuspension()
        XCTAssertNil(fixture.session.vouchedContextCount, "Invalidated at dispatch")
        XCTAssertEqual(fixture.session.vouchedContextWindow?.tokens, 1000, "The window is unchanged")

        _ = fixture.viewModel.ingestNonCodexUsageReport(
            promptTokens: 850,
            completionTokens: nil,
            contextUsedTokens: nil,
            modelContextWindow: nil,
            session: fixture.session
        )
        XCTAssertNil(fixture.session.vouchedContextCount, "A billed prompt count is not occupancy")

        fixture.viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 870,
            completionTokens: 12,
            contextUsedTokens: 870,
            modelContextWindow: nil,
            session: fixture.session
        )
        XCTAssertNil(
            fixture.session.vouchedContextCount,
            "The /compact turn's billed count describes the pre-compaction context"
        )
        fixture.session.endCompactionContextCountSuspension()

        // A later turn: the provider's occupancy report vouches again, as it always does.
        fixture.viewModel.startNonCodexTurnAccountingIfNeeded(for: fixture.session, initialMessage: "/compact")
        fixture.session.beginCompactionContextCountSuspension()
        reportOccupancy(fixture, used: 120, window: 1000)
        fixture.viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 870,
            completionTokens: 12,
            contextUsedTokens: 870,
            modelContextWindow: nil,
            session: fixture.session
        )
        XCTAssertEqual(fixture.session.vouchedContextCount?.tokens, 120, "The in-turn usage_update stands")
        fixture.session.endCompactionContextCountSuspension()
        XCTAssertFalse(fixture.session.contextCountVouchAwaitsOccupancyReport)
    }
}

/// A fire-and-forget ACP compaction keeps running in the provider's background, where the session's
/// next prompt cancels it. These prove the settle hold is enforced — not merely advised — on every
/// admission surface that could start that cancelling turn, that `poll` names it, and that it lifts
/// on its own (publishing the change parked work waits for) or when the session's own turn begins.
@MainActor
final class AgentSessionLinkACPBackgroundCompactionSettleTests: XCTestCase {
    private func candidate(tabID: UUID) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: 1,
            workspaceID: UUID(),
            tabID: tabID,
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Worker",
            providerDisplayName: "Devin",
            locationLabel: nil
        )
    }

    private func idleSession() -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.hasLoadedPersistedState = true
        return session
    }

    private func admission(_ session: AgentModeViewModel.TabSession) -> AgentSessionLinkDeliveryReadiness.Decision {
        AgentSessionLinkDeliveryReadiness.evaluate(
            snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
                session: session,
                endpointMatchesGrant: true,
                isClosing: false
            )
        )
    }

    func testTheSettleBlockerIsATargetNotIdleFactInThePureMatrix() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot), .ready)
        snapshot.backgroundCompactionSettling = true
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot), .blocked(.targetNotIdle))

        typealias Inputs = AgentModeViewModel.SendReadinessInputs
        let session = idleSession()
        var input: Inputs = AgentModeViewModel.sendReadinessInputs(
            session: session,
            candidate: candidate(tabID: session.tabID),
            status: .idle
        )
        XCTAssertTrue(AgentModeViewModel.sendBlockers(input).isEmpty)
        input.backgroundCompactionSettling = true
        XCTAssertEqual(AgentModeViewModel.sendBlockers(input).map(\.rawValue), ["background_compaction_settling"])
    }

    func testASettlingSessionRefusesDeliveryAndWakesAndPollNamesTheHold() {
        let session = idleSession()
        let target = candidate(tabID: session.tabID)
        XCTAssertEqual(admission(session), .ready)
        XCTAssertTrue(AgentModeViewModel.agentSessionLinkPeriodicWakeSessionIsIdle(session))

        session.beginACPBackgroundCompactionSettle(duration: 60)

        XCTAssertTrue(session.isSettlingACPBackgroundCompaction)
        XCTAssertEqual(
            admission(session),
            .blocked(.targetNotIdle),
            "send, compact, and every parked when_sendable drain share this admission"
        )
        XCTAssertFalse(
            AgentModeViewModel.agentSessionLinkPeriodicWakeSessionIsIdle(session),
            "A periodic wake would start the very turn that cancels the compaction"
        )
        let observed = AgentModeViewModel.observationSnapshot(for: session, candidate: target, subagentCounts: (0, 0))
        XCTAssertEqual(observed.status, .idle, "The run itself is over; only delivery is held")
        XCTAssertFalse(observed.idleForSend, "until: sendable must not release a waiter into a refusal")
        XCTAssertEqual(observed.board.sendBlockers, ["background_compaction_settling"])

        session.endACPBackgroundCompactionSettle()
        XCTAssertFalse(session.isSettlingACPBackgroundCompaction)
        XCTAssertEqual(admission(session), .ready)
        XCTAssertTrue(
            AgentModeViewModel.observationSnapshot(for: session, candidate: target, subagentCounts: (0, 0)).idleForSend
        )
    }

    func testTheHoldLiftsItselfAndPublishesTheReadinessChangeParkedWorkWaitsFor() async {
        let session = idleSession()
        var transitions: [Bool] = []
        let lifted = expectation(description: "the expiry publishes a readiness change")
        let subscription = session.monitorReadinessChangePublisher.sink { [weak session] in
            guard let session else { return }
            transitions.append(session.isSettlingACPBackgroundCompaction)
            if session.acpBackgroundCompactionSettlesAt == nil { lifted.fulfill() }
        }
        defer { subscription.cancel() }

        session.beginACPBackgroundCompactionSettle(duration: 0.05)
        XCTAssertEqual(admission(session), .blocked(.targetNotIdle))

        await fulfillment(of: [lifted], timeout: 5)
        XCTAssertEqual(transitions, [true, false], "Both edges publish; the expiry edge is the one a parked drain needs")
        XCTAssertFalse(session.isSettlingACPBackgroundCompaction)
        XCTAssertEqual(admission(session), .ready)
    }

    func testANewerHoldReplacesAnOlderOneAndAnEarlyLiftCancelsTheExpiry() async throws {
        let session = idleSession()
        session.beginACPBackgroundCompactionSettle(duration: 0.05)
        session.beginACPBackgroundCompactionSettle(duration: 60)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(session.isSettlingACPBackgroundCompaction, "The superseded short hold must not lift the newer one")

        var signals = 0
        let subscription = session.monitorReadinessChangePublisher.sink { signals += 1 }
        defer { subscription.cancel() }
        session.endACPBackgroundCompactionSettle()
        session.endACPBackgroundCompactionSettle()
        XCTAssertEqual(signals, 1, "Only the real transition publishes")
        XCTAssertFalse(session.isSettlingACPBackgroundCompaction)
    }
}
