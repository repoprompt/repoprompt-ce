import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CodexResumeWedgeCommitTests: XCTestCase {
    private static let oldThreadID = "old-committed-thread"
    private static let oldRolloutPath = "/tmp/old-committed-rollout.jsonl"
    private static let missingRolloutMessage =
        "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist"

    @MainActor
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let session: AgentTabSession
        let factory: WedgeControllerFactory

        var coordinator: CodexAgentModeCoordinator {
            viewModel.test_codexCoordinator
        }
    }

    private func makeFixture(
        _ plans: [[WedgeFakeCodexController.Response]],
        routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator = { _, _, _, _ in true }
    ) -> Fixture {
        let factory = WedgeControllerFactory(plans: plans)
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: true,
            codexControllerFactory: { runID, _, _, _, _, _ in factory.make(runID: runID) },
            mcpServerEnabler: { true },
            testCodexLeaseRoutingTimeoutMs: 5000,
            testCodexRouteOwnerValidator: routeOwnerValidator
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Codex resume wedge test"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.codexConversationID = Self.oldThreadID
        session.codexRolloutPath = Self.oldRolloutPath
        session.providerCleanupHandle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: Self.oldThreadID,
            rolloutPath: Self.oldRolloutPath
        )
        session.codexNeedsReconnect = true
        session.runState = .running
        session.beginRunAttempt(source: "codex-resume-wedge-test")
        return Fixture(
            viewModel: viewModel,
            workspaceManager: workspaceManager,
            session: session,
            factory: factory
        )
    }

    private func waitForPendingStart(_ fixture: Fixture) async throws {
        try await AsyncTestWait.waitUntil("Codex start staged", timeout: 4) {
            fixture.coordinator.test_hasPendingCodexStart(for: fixture.session)
        }
    }

    private func assertOldTuple(_ session: AgentTabSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.codexConversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.codexRolloutPath, Self.oldRolloutPath, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.conversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.rolloutPath, Self.oldRolloutPath, file: file, line: line)
    }

    func testTwoResumeTimeoutsThenFreshRoutingFailureRetainsPersistedTupleAndLaterSend() async throws {
        let fixture = makeFixture([
            [.timeout],
            [.timeout],
            [.success("failed-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)
        assertOldTuple(fixture.session)

        let second = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { second.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        let failedRunID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyFailed(runID: failedRunID)
        await second.value

        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)

        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            saved = agentSession
            return FileManager.default.temporaryDirectory.appendingPathComponent("codex-wedge-\(UUID().uuidString).json")
        }
        await fixture.viewModel.flushSave(for: fixture.session.tabID)
        XCTAssertEqual(saved?.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(saved?.codexRolloutPath, Self.oldRolloutPath)
        XCTAssertEqual(saved?.providerCleanupHandle?.conversationID, Self.oldThreadID)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "codex-resume-wedge-later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[3].receivedExistingIDs, [nil])
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[3].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testRepeatedTimeoutReplacementRenewsAdmissionAndDiscardsOldRoutingSignal() async throws {
        let responseGate = TestReleaseFence(name: "replacement response")
        let fixture = makeFixture([
            [.timeout],
            [.routedTimeout],
            [.suspendedSuccess("replacement-thread", responseGate)]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            responseGate.release()
            startup.cancel()
        }
        let entered = await responseGate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let runID = try XCTUnwrap(fixture.session.runID)
        let clientName = try XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint)
        let staleOutcome = await MCPRoutingWaiter.shared.currentTerminalOutcome(runID: runID)
        XCTAssertNil(staleOutcome, "the retired process's routed signal must not satisfy the replacement wait")
        let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(pendingPolicies.contains { $0.runID == runID }, "replacement needs fresh admission after the old permit expired")
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[1].shutdownCount, 1)
        XCTAssertEqual(fixture.factory.controllers[2].runID, runID)

        responseGate.release()
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, "replacement-thread")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "replacement-thread")
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
        let retainedPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(retainedPolicies.contains { $0.runID == runID }, "old lease cleanup must not revoke successor admission")
        await ServerNetworkManager.shared.revokeClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
        await MCPRoutingWaiter.shared.cleanup(runID: runID)
    }

    func testSettledOldLeaseCannotRevokeSameRunSuccessor() async {
        let runID = UUID()
        let tabID = UUID()
        let clearGate = TestReleaseFence(name: "old permit revocation")
        let oldLease = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: 1, agent: .codexExec),
            policyClearer: { spec in
                await clearGate.enterAndWait()
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: spec.windowID,
                    runID: spec.runID
                )
            }
        )
        let acquired = await oldLease.acquire()
        XCTAssertTrue(acquired)
        let firstCleanup = Task { await oldLease.cancelAndCleanup() }
        defer { clearGate.release() }
        let entered = await clearGate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let secondCleanup = Task { await oldLease.cancelAndCleanup() }
        _ = await oldLease.debugWaitForPolicyClearJoiner()
        clearGate.release()
        await firstCleanup.value
        await secondCleanup.value

        let successor = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: 1, agent: .codexExec)
        )
        let successorAcquired = await successor.acquire()
        XCTAssertTrue(successorAcquired)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await oldLease.cancelAndCleanup()
        let pending = await hasPendingPolicy(for: runID)
        XCTAssertTrue(pending, "settled predecessor must not clear the successor permit")
        let outcome = await MCPRoutingWaiter.shared.currentTerminalOutcome(runID: runID)
        XCTAssertEqual(outcome, .routed, "settled predecessor must not fail or remove the successor waiter")
        await successor.cancelAndCleanup()
    }

    func testRoutingSuccessCommitsFreshFallbackExactlyOnce() async throws {
        let fixture = makeFixture([[.missingRollout, .success("ready-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value

        XCTAssertEqual(fixture.session.codexConversationID, "ready-fresh-thread")
        XCTAssertNil(fixture.session.codexRolloutPath, "a pre-turn fresh thread may not have a rollout yet")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "ready-fresh-thread")
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))

        fixture.session.runState = .idle
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID, nil])
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
    }

    func testSecondCallerCannotBypassUnpublishedStartup() async throws {
        let gate = TestReleaseFence(name: "first Codex start response")
        let fixture = makeFixture([[.suspendedSuccess("claimed-thread", gate)]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        let secondSend = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "duplicate",
            attachments: []
        )
        if case .preDispatchRejected = secondSend {} else {
            XCTFail("a second send must be rejected before turn dispatch")
        }
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)

        gate.release()
        try await waitForPendingStart(fixture)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, "claimed-thread")
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testCancellationAndSuccessorCannotPublishStagedThread() async throws {
        let cancelled = makeFixture([[.success("cancelled-fresh")]])
        let cancelledTask = Task { await cancelled.coordinator.ensureCodexNativeSession(session: cancelled.session) }
        try await waitForPendingStart(cancelled)
        cancelledTask.cancel()
        await cancelledTask.value
        assertOldTuple(cancelled.session)
        XCTAssertFalse(cancelled.coordinator.test_hasPendingCodexStart(for: cancelled.session))
        XCTAssertFalse(cancelled.session.items.contains { $0.text.contains("Started a fresh thread") })

        let successor = makeFixture([[.success("stale-fresh")]])
        let staleTask = Task { await successor.coordinator.ensureCodexNativeSession(session: successor.session) }
        defer { staleTask.cancel() }
        try await waitForPendingStart(successor)
        let staleRunID = try XCTUnwrap(successor.session.runID)
        successor.session.installRunID(UUID())
        await MCPRoutingWaiter.shared.notifyRouted(runID: staleRunID)
        await staleTask.value
        assertOldTuple(successor.session)
        XCTAssertFalse(successor.coordinator.test_hasPendingCodexStart(for: successor.session))
        XCTAssertFalse(successor.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(successor.factory.controllers[0].startedTurnCount, 0)
    }

    func testInheritedRoutedOutcomeCannotCommitWithoutCurrentControllerRoute() async throws {
        let fixture = makeFixture(
            [[.success("unrouted-fresh-thread")]],
            routeOwnerValidator: { _, _, _, _ in false }
        )
        fixture.session.codexNativeStartupDisposition = .resumed
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        let policyWasInstalled = await hasPendingPolicy(for: runID)
        XCTAssertTrue(policyWasInstalled)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexNativeStartupDisposition)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testCancellationDuringRouteOwnerCheckCleansPolicyAndUncommittedController() async throws {
        let gate = TestReleaseFence(name: "Codex route owner check")
        let fixture = makeFixture(
            [[.success("cancelled-owner-thread")]],
            routeOwnerValidator: { _, _, _, _ in
                await gate.enterAndWait()
                return true
            }
        )
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        let ownerCheckEntered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(ownerCheckEntered)
        startup.cancel()
        gate.release()
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    private func hasPendingPolicy(for runID: UUID) async -> Bool {
        guard let clientName = AgentProviderKind.codexExec.mcpClientNameHint else { return false }
        let policies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        return policies.contains { $0.runID == runID }
    }

    func testAlreadyInstalledPolicyRecoveryStillStagesUntilRouting() async throws {
        let fixture = makeFixture([[.success("event-recovery-thread")]])
        let startup = Task {
            await fixture.coordinator.ensureCodexNativeSession(
                session: fixture.session,
                policyAlreadyInstalled: true,
                preserveExistingRunID: true
            )
        }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testSameRunAttemptDriftRetiresOnlyUncommittedControllerBeforeLaterSend() async throws {
        let fixture = makeFixture([
            [.success("drifted-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        fixture.session.appendItem(.system("Earlier Codex history", sequenceIndex: fixture.session.nextSequenceIndex))
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "same-run-successor")
        XCTAssertEqual(fixture.session.runID, runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        try await AsyncTestWait.waitUntil("uncommitted Codex controller retired", timeout: 4) {
            fixture.factory.controllers[0].shutdownCount == 1
        }
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [Self.oldThreadID])
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[1].startedTurnCount, 0)
    }

    func testAttemptDriftDoesNotRetireSuccessorController() async throws {
        let fixture = makeFixture([[.success("stale-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "successor-controller")
        let successor = WedgeFakeCodexController(runID: runID, responses: [])
        fixture.session.codexController = successor
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
        XCTAssertEqual(successor.shutdownCount, 0)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testResolveRolloutPathClassifierIsNarrow() {
        let ref = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: Self.oldRolloutPath,
            model: nil,
            reasoningEffort: nil
        )
        let classifier: (CodexNativeSessionController.SessionRef?, String) -> Bool = { reference, message in
            CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                existingRef: reference,
                errorDescription: message
            )
        }
        XCTAssertTrue(classifier(ref, Self.missingRolloutMessage))
        XCTAssertTrue(classifier(ref, "  FAILED TO RESOLVE ROLLOUT PATH /tmp/old-committed-rollout.jsonl: FILE DOES NOT EXIST.  "))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"))
        let mixedCaseRef = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: "/tmp/CaseSensitive.jsonl",
            model: nil,
            reasoningEffort: nil
        )
        XCTAssertTrue(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"))
        XCTAssertFalse(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"))
        XCTAssertTrue(classifier(
            .init(conversationID: Self.oldThreadID, rolloutPath: nil, model: nil, reasoningEffort: nil),
            "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertTrue(classifier(ref, "no rollout found for thread id old-committed-thread"))
        XCTAssertFalse(classifier(nil, Self.missingRolloutMessage))
        XCTAssertFalse(classifier(ref, "failed to resolve workspace path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: permission denied"))
        XCTAssertFalse(classifier(ref, "warning: failed to resolve rollout path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: file does not exist; check permissions"))
        XCTAssertTrue(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "config/read",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32602,
            message: Self.missingRolloutMessage
        ))
    }
}

private final class WedgeControllerFactory {
    private var plans: [[WedgeFakeCodexController.Response]]
    private(set) var controllers: [WedgeFakeCodexController] = []

    init(plans: [[WedgeFakeCodexController.Response]]) {
        self.plans = plans
    }

    func make(runID: UUID) -> WedgeFakeCodexController {
        let controller = WedgeFakeCodexController(
            runID: runID,
            responses: plans.isEmpty ? [] : plans.removeFirst()
        )
        controllers.append(controller)
        return controller
    }
}

private final class WedgeFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    enum Response {
        case timeout
        case routedTimeout
        case missingRollout
        case suspendedSuccess(String, TestReleaseFence)
        case success(String)
    }

    let runID: UUID
    private let lock = NSLock()
    private var responses: [Response]
    private var existingIDs: [String?] = []
    private var active = false
    private var turnCount = 0
    private var shutdowns = 0
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    let events: AsyncStream<CodexNativeSessionController.Event>

    init(runID: UUID, responses: [Response]) {
        self.runID = runID
        self.responses = responses
        var storedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation!
        events = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    var hasActiveThread: Bool {
        lock.withLock { active }
    }

    var receivedExistingIDs: [String?] {
        lock.withLock { existingIDs }
    }

    var startedTurnCount: Int {
        lock.withLock { turnCount }
    }

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        let response = lock.withLock { () -> Response? in
            existingIDs.append(existing?.conversationID)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        switch response {
        case .routedTimeout:
            // Model a permit pruned during the slow resume, with readiness already cached
            // from the retired process. Neither may authorize the replacement process.
            await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                for: AgentProviderKind.codexMCPClientID,
                windowID: 1,
                runID: runID
            )
            await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
        case .timeout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
        case .missingRollout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32600,
                message: "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist",
                data: nil
            ))
        case let .suspendedSuccess(threadID, gate):
            await gate.enterAndWait()
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case let .success(threadID):
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case nil:
            throw CodexAppServerClient.ClientError.invalidResponse
        }
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        let count = lock.withLock { () -> Int in
            turnCount += 1
            return turnCount
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "fake-turn-\(count)")
    }

    func shutdown() async {
        lock.withLock {
            active = false
            shutdowns += 1
        }
        continuation.finish()
    }
}
