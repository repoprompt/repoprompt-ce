import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

private actor AutoWakeCatalogAuthorityGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Bool, Never>] = []

    func requirement() async -> Bool {
        if !entered {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if isOpen {
            return true
        }
        return await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }
}

/// Orchestration, identity, and provenance for the one automatic lane-update follow-up.
///
/// Deliberately driven through the same publication hook and claim seam the runtime bridge and every
/// provider family use, rather than by calling the coordinator's internals: what has to be true is
/// that a wake reserves exactly one turn, that the reservation is visible to other observers, and
/// that the acceptance boundary is the provider's own signal.
@MainActor
final class AgentSessionLinkAutoWakeTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        for viewModel in retained {
            for session in viewModel.sessions.values {
                session.oversight.retireSnoozeState()
                session.oversight.retirePeriodicScheduling()
                session.oversight.pendingAutoWake?.task?.cancel()
            }
        }
        retained.removeAll()
        super.tearDown()
    }

    func testScheduledWakeDuringWorktreeCommitAdmissionCannotDispatchOrChangeBinding() async throws {
        let fixture = try makeFixture(fenceProviderLaunch: true)
        try publishInventory(fixture, revision: 1)
        fixture.session.runState = .idle
        fixture.session.oversight.autoWakeOnUpdates = true
        let original = AgentSessionWorktreeBinding(
            id: "primary", repositoryID: "repo", repoKey: "repo", logicalRootPath: "/tmp/wake-logical",
            logicalRootName: "Project", worktreeID: "wt", worktreeRootPath: "/tmp/wake-physical", source: "test"
        )
        fixture.session.worktreeBindings = [original]
        var wake: AgentSessionLinkAutoWakeAttempt?
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: {
                    XCTAssertTrue(fixture.session.isChangingExecutionLocation)
                    try self.publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
                    wake = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
                    XCTAssertEqual(wake?.phase, .scheduled)
                    XCTAssertEqual(wake?.physicalOutcome, .notAttempted)
                    wake?.task?.cancel()
                }
            )
            XCTFail("A competing wake reservation must fail closed, not migrate its provider turn")
        } catch {
            XCTAssertNotNil(wake, "The test must reach the deterministic reservation boundary")
            XCTAssertTrue(error.localizedDescription.contains("queued work"))
            XCTAssertEqual(fixture.session.worktreeBindings, [original])
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            XCTAssertEqual(wake?.physicalOutcome, .notAttempted)
        }
    }

    func testRepeatedCancellationKeepsRawProviderDispatchFenced() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        attempt.task?.cancel()
        attempt.phase = .preparingDispatch
        fixture.session.oversight.pendingAutoWake = attempt
        let dispatchID = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        let gate = AutoWakeCatalogAuthorityGate()
        let itemCount = fixture.session.items.count
        let producer = Task { @MainActor in
            _ = await gate.requirement()
            let decorated = fixture.viewModel.agentSessionLinkDecoratedProviderText(
                "", session: fixture.session, dispatchID: dispatchID
            )
            let acquired = fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
                for: fixture.session, dispatchID: dispatchID
            )
            return !decorated.mustAbortDispatch && acquired
        }
        await gate.waitUntilEntered()
        for reason: AgentSessionLinkAutoWakeCancellationReason in [.localUserWon, .localUserWon, .endpointInvalidated] {
            fixture.viewModel.cancelAgentSessionLinkAutoWake(for: attempt.observerEndpoint, reason: reason)
        }
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, attempt.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertEqual(fixture.viewModel.agentSessionLinkEffectiveDispatchID(
            for: fixture.session, dispatchID: dispatchID
        ).autoWakeID, attempt.wakeID)
        await gate.open()
        let wouldCallTransport = await producer.value
        XCTAssertFalse(wouldCallTransport)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: fixture.session, dispatchID: dispatchID)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemCount)
        XCTAssertNotNil(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID])
    }

    func testRoutineAndAttentionWakeCarryVerifiedParkedNoteBeforeUpdatesOnce() async throws {
        for basis in ["routine", "attention", "manual"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = basis == "routine"
            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID, prompt: "What next?", timeoutSeconds: 5
                )
            }
            try await AsyncTestWait.waitUntil("instruction continuation installed") {
                fixture.session.instructionContinuation != nil
            }
            let noteID = try installVerifiedParkedNote(fixture)
            XCTAssertFalse(fixture.viewModel.agentSelfCompactBlocksNotificationWake(fixture.session))
            XCTAssertFalse(fixture.viewModel.agentSessionLinkPeriodicPreparationIsUnblocked(fixture.session))
            let attention = Self.attentionRequest(0)
            try publishLane(
                fixture, linkSetRevision: 1, queueRevision: 1,
                targetIndices: basis == "attention" ? [] : [0], laneIndices: [0],
                attentionRequests: basis == "attention" ? [attention] : []
            )
            if basis == "manual" {
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
                XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
            }
            let response = try await waiting.value
            guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
                return XCTFail("expected an event-driven wake")
            }
            let text = try XCTUnwrap(response.text)
            XCTAssertTrue(text.hasPrefix(AgentSelfCompactNoteEnvelope.frame("continue safely") + "\n\n"))
            XCTAssertTrue(text.contains("<repoprompt_session_oversight_status_changes"))
            XCTAssertEqual(text.components(separatedBy: "<note>").count - 1, 1)
            XCTAssertEqual(fixture.session.selfCompactState.latest?.requestID, noteID.requestID)
            XCTAssertEqual(fixture.session.selfCompactState.latest?.noteDelivery, .prepended)
            XCTAssertEqual(fixture.session.selfCompactState.latest?.completionVerified, true)
            XCTAssertNil(fixture.session.selfCompactState.active)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID }), 1)
            let next = AgentSelfCompactParkedPrefix.prepare("next", session: fixture.session, scheduleSave: {})
            XCTAssertEqual(next.text, "next")
            XCTAssertNil(next.dispatchID)
        }
    }

    func testClaudeVerifiedCompactPreSendExitReparksAndPendingWakeCarriesNote() async throws {
        for exit in ["entryStop", "leaseFailure", "leaseCancellation"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            let session = fixture.session
            session.selectedAgent = .claudeCode
            session.claudeController = fixture.nativeController
            let harness = AgentSessionLinkRunnerHarness(
                headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: fixture.viewModel
            )
            let runner = ClaudeIntegratedAgentModeRunner(
                claudeCoordinator: fixture.viewModel.test_claudeCoordinator, hooks: harness.hooks,
                terminalCommitBarrier: AgentRunTerminalCommitBarrier()
            )
            let noteID = try installVerifiedParkedNote(fixture)
            session.selfCompactState.active?.phase = .dispatchingCompact
            session.selfCompactState.active?.compactTurnSucceeded = nil
            session.selfCompactState.active?.admittedSupport = .claudeCode
            let compactRunID = try XCTUnwrap(session.runID)
            let compactAttemptID = UUID()
            let leaseGate = TestReleaseFence(name: "dedicated Claude note bootstrap")
            defer { leaseGate.release() }
            let completion = AgentSelfCompactNativeCompletionCoordinator(
                load: { session.selfCompactState }, store: { session.selfCompactState = $0 },
                isCurrentOwner: { _ in true },
                dispatchNote: { requestID, admissible in
                    guard admissible() else { return false }
                    session.selfCompactState.active?.phase = .dispatchingNote
                    let fence = AgentRunStartStopFence(session: session)
                    if exit == "entryStop" { session.stopState.invalidateScheduledStarts() }
                    await runner.startRun(
                        tabID: fixture.tabID, session: session,
                        initialUserMessage: "", initialMessageForRun: AgentSelfCompactNoteEnvelope.frame("continue safely"),
                        attachments: [], makeLease: { runID in
                            MCPBootstrapLease(
                                spec: .agentMode(tabID: fixture.tabID, runID: runID, gateID: UUID(), windowID: 1, agent: .claudeCode),
                                mcpServerEnabler: { await leaseGate.enterAndWait()
                                    return exit == "leaseCancellation"
                                },
                                policyInstaller: { spec in await MCPRoutingWaiter.notifyRouted(runID: spec.runID) },
                                policyClearer: { _ in }
                            )
                        },
                        selfCompactDispatchID: .init(requestID: requestID, stage: .note), stopFence: fence
                    )
                    return true
                }
            )
            session.selfCompactNativeCompletion = completion
            defer { completion.cancelRuntimeWork() }
            XCTAssertTrue(completion.bindCompact(
                .init(requestID: noteID.requestID, stage: .compact), runID: compactRunID, runAttemptID: compactAttemptID
            ))
            var publishedParked = false
            let observation = session.monitorReadinessChangePublisher.sink { _ in
                MainActor.assumeIsolated {
                    if session.selfCompactState.active?.phase == .parked { publishedParked = true }
                }
            }
            defer { observation.cancel() }
            // Keep the wake behind an independent gate until the instruction carrier is installed.
            session.isChangingExecutionLocation = true
            session.oversight.autoWakeOnUpdates = true
            try publishInventory(fixture, revision: 1)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            try await AsyncTestWait.waitUntil("pending lane edge awaits readiness") {
                session.oversight.pendingAutoWake?.phase == .awaitingSettlement
            }
            completion.compactTurnSettled(
                revision: AgentRunTerminalCommitRevision(
                    commitID: UUID(), ownership: .init(attemptID: compactAttemptID, binding: .init(tabID: fixture.tabID, persistentSessionID: fixture.sessionID)),
                    terminalState: .completed, failureReason: nil, expectedRunID: compactRunID,
                    sourceItemsRevision: 0, assistantDeltaFlushGeneration: 0, providerDrainGeneration: 0,
                    mcpPublicationEnvelope: nil, successorKind: nil, providerSuccessorID: nil
                ),
                publication: .accepted(successorEpoch: nil), teardownSettled: { true }
            )
            if exit != "entryStop" {
                guard await leaseGate.waitUntilEntered(timeout: 3, failOnTimeout: false) else {
                    XCTFail("Dedicated note never entered the lease gate: \(exit)")
                    continue
                }
                let task = try XCTUnwrap(session.agentTask)
                if exit == "leaseCancellation" { task.cancel() }
                leaseGate.release()
                await task.value
            }
            try await AsyncTestWait.waitUntil("verified unattempted note reparks and publishes readiness") {
                session.selfCompactState.active?.phase == .parked && publishedParked
            }
            XCTAssertEqual(session.selfCompactState.active?.id, noteID.requestID)
            XCTAssertEqual(session.selfCompactState.active?.compactTurnSucceeded, true)
            XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, false)
            let sentCount = await fixture.nativeController.sentCount
            XCTAssertEqual(sentCount, 0)
            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID, prompt: "What next?", timeoutSeconds: 5)
            }
            try await AsyncTestWait.waitUntil("instruction carrier installed") { session.instructionContinuation != nil }
            session.isChangingExecutionLocation = false
            let response = try await waiting.value
            guard case .laneUpdateAutoWake = response.origin else { return XCTFail("Expected the pending edge to wake") }
            let text = try XCTUnwrap(response.text)
            XCTAssertTrue(text.hasPrefix(AgentSelfCompactNoteEnvelope.frame("continue safely") + "\n\n"))
            XCTAssertTrue(text.contains("<repoprompt_session_oversight_status_changes"))
            XCTAssertEqual(text.components(separatedBy: "<note>").count - 1, 1)
            XCTAssertEqual(session.selfCompactState.latest?.requestID, noteID.requestID)
            XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
            XCTAssertEqual(session.selfCompactState.latest?.completionVerified, true)
            XCTAssertNil(session.selfCompactState.active)
            XCTAssertNil(session.oversight.pendingAutoWake)
        }
    }

    func testClaudeCompactBindRefusalNeverReachesProviderTransport() async throws {
        for refusal in ["staleDispatch", "bindRejected", "missingCoordinator"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            let session = fixture.session
            session.selectedAgent = .claudeCode
            session.claudeController = fixture.nativeController
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let runner = ClaudeIntegratedAgentModeRunner(
                claudeCoordinator: fixture.viewModel.test_claudeCoordinator, hooks: harness.hooks,
                terminalCommitBarrier: AgentRunTerminalCommitBarrier()
            )
            let noteID = try installVerifiedParkedNote(fixture)
            session.selfCompactState.active?.phase = .dispatchingCompact
            session.selfCompactState.active?.compactTurnSucceeded = nil
            session.selfCompactState.active?.admittedSupport = .claudeCode
            session.selfCompactDispatchIsCurrent = { refusal != "staleDispatch" }
            let completion = AgentSelfCompactNativeCompletionCoordinator(
                load: { session.selfCompactState }, store: { session.selfCompactState = $0 },
                isCurrentOwner: { _ in true }, dispatchNote: { _, _ in XCTFail("No note may dispatch")
                    return false
                }
            )
            defer { completion.cancelRuntimeWork() }
            session.selfCompactNativeCompletion = refusal == "missingCoordinator" ? nil : completion
            let dispatchID = AgentSelfCompactionDispatchID(requestID: refusal == "bindRejected" ? UUID() : noteID.requestID, stage: .compact)
            try await runner.startRun(
                tabID: fixture.tabID, session: session, initialUserMessage: "", initialMessageForRun: "/compact",
                attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) },
                providerControlCommand: .compact(
                    expectedBinding: XCTUnwrap(session.persistentSessionBindingIdentity),
                    expectedProviderConversation: "monitor-native-session", selfCompactDispatchID: dispatchID
                ),
                selfCompactDispatchID: dispatchID
            )
            // Drain any task created by a broken runner so the zero-transport oracle is meaningful.
            if let task = session.agentTask {
                XCTFail("Bind refusal installed a transport task: \(refusal)")
                task.cancel()
                await task.value
            }
            let sentCount = await fixture.nativeController.sentCount
            XCTAssertEqual(sentCount, 0, refusal)
            XCTAssertEqual(session.runState, .failed, refusal)
            XCTAssertNil(session.activeRunOwnership)
            XCTAssertNil(session.selfCompactState.active?.compactRunAttemptID)
        }
    }

    func testCodexDedicatedNoteEarlyExitReparksWithoutProviderTransport() async throws {
        for exit in ["entryStop", "mcpFailure", "stopAfterMCP"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            let session = fixture.session
            session.selectedAgent = .codexExec
            let noteID = try installVerifiedParkedNote(fixture)
            session.selfCompactState.active?.phase = .dispatchingNote
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let fence = AgentRunStartStopFence(session: session)
            if exit == "entryStop" { session.stopState.invalidateScheduledStarts() }
            var mcpCalls = 0
            let runner = CodexIntegratedAgentModeRunner(
                mcpServerEnabler: {
                    mcpCalls += 1
                    if exit == "stopAfterMCP" { session.stopState.invalidateScheduledStarts() }
                    return exit != "mcpFailure"
                },
                codexCoordinator: fixture.viewModel.test_codexCoordinator, hooks: harness.hooks
            )
            let outcome = await runner.startRun(
                tabID: fixture.tabID, session: session, initialMessageForRun: AgentSelfCompactNoteEnvelope.frame("continue safely"),
                attachments: [], fallbackContext: nil, selfCompactDispatchID: noteID, stopFence: fence
            )
            XCTAssertFalse(outcome.didSend)
            XCTAssertEqual(mcpCalls, exit == "entryStop" ? 0 : 1)
            XCTAssertNil(session.codexController)
            XCTAssertEqual(session.selfCompactState.active?.id, noteID.requestID)
            XCTAssertEqual(session.selfCompactState.active?.phase, .parked)
            XCTAssertEqual(session.selfCompactState.active?.compactTurnSucceeded, true)
            XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, false)
        }
    }

    func testNotificationWakeRetainsUnverifiedAttemptedAndOwnerlessCompactGates() throws {
        let fixture = try makeFixture(fenceProviderLaunch: true)
        _ = try installVerifiedParkedNote(fixture)
        let verified = fixture.session.selfCompactState
        for phase in AgentSelfCompactAttempt.Phase.allCases where phase != .parked {
            var state = verified
            state.active?.phase = phase
            fixture.session.selfCompactState = state
            XCTAssertTrue(fixture.viewModel.agentSelfCompactBlocksNotificationWake(fixture.session), phase.rawValue)
        }
        for invalid in 0 ..< 4 {
            var state = verified
            switch invalid {
            case 0: state.active?.acpCompletionUnverified = true
            case 1: state.active?.compactTurnSucceeded = nil
            case 2: state.active?.noteDispatchStarted = true
            default: state.active = AgentSelfCompactAttempt(idempotencyKey: "ownerless", note: "note", phase: .parked)
            }
            fixture.session.selfCompactState = state
            XCTAssertTrue(fixture.viewModel.agentSelfCompactBlocksNotificationWake(fixture.session))
        }
    }

    func testWakeEvaluationSettlesStaleParkedNoteWithoutSend() throws {
        for loss in ["localGeneration", "windowIncarnation", "competingWriter", "currentOwner", "attemptedForeign"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            _ = try installVerifiedParkedNote(fixture)
            let original = try XCTUnwrap(fixture.session.selfCompactState.active)
            let currentOwner = try XCTUnwrap(original.owner)
            let owner = AgentSelfCompactOwner(
                windowID: loss == "windowIncarnation" || loss == "attemptedForeign" ? currentOwner.windowID + 1 : currentOwner.windowID,
                workspaceID: currentOwner.workspaceID, tabID: currentOwner.tabID,
                sessionID: currentOwner.sessionID,
                persistentBindingGeneration: loss == "localGeneration" ? UUID() : currentOwner.persistentBindingGeneration,
                bindingTransitionGeneration: currentOwner.bindingTransitionGeneration,
                runID: currentOwner.runID, runAttemptID: currentOwner.runAttemptID
            )
            var attempt = AgentSelfCompactAttempt(idempotencyKey: "owner-loss", note: original.note, owner: owner, phase: .parked)
            attempt.compactTurnSucceeded = true
            attempt.noteDispatchStarted = loss == "attemptedForeign"
            fixture.session.selfCompactState = AgentSelfCompactState(active: attempt)
            let competingWriter = loss == "competingWriter" ? fixture.viewModel.session(for: UUID()) : nil
            competingWriter?.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
            defer { competingWriter?.testInstallPersistentSessionBinding(sessionID: nil) }
            XCTAssertEqual(owner.matchesLocalBinding(fixture.session), loss != "localGeneration", loss)
            XCTAssertEqual(fixture.viewModel.agentSelfCompactBlocksNotificationWake(fixture.session), loss != "currentOwner", loss)
            try publishInventory(fixture, revision: 1)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            if loss == "currentOwner" || loss == "attemptedForeign" {
                XCTAssertEqual(fixture.session.selfCompactState.active, attempt, loss)
                XCTAssertNil(fixture.session.selfCompactState.latest, loss)
            } else {
                XCTAssertNil(fixture.session.selfCompactState.active, loss)
                XCTAssertEqual(fixture.session.selfCompactState.latest?.requestID, attempt.id, loss)
                XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .cancelled, loss)
                XCTAssertEqual(fixture.session.selfCompactState.latest?.noteDelivery, .notSent, loss)
                let settled = fixture.session.selfCompactState
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
                fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
                XCTAssertEqual(fixture.session.selfCompactState, settled, "Repeated evaluation must be inert")
            }
            XCTAssertNil(fixture.session.oversight.pendingAutoWake, loss)
            XCTAssertNotNil(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID], loss)
        }
    }

    private func installVerifiedParkedNote(_ fixture: Fixture) throws -> AgentSelfCompactionDispatchID {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        let owner = try AgentSelfCompactOwner(
            windowID: endpoint.windowID, workspaceID: endpoint.workspaceID, tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: XCTUnwrap(endpoint.persistentBindingGeneration),
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
            runID: XCTUnwrap(fixture.session.runID), runAttemptID: UUID()
        )
        var state = AgentSelfCompactState()
        _ = state.reserve(note: "continue safely", idempotencyKey: "parked-wake", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes, owner: owner)
        state.active?.compactTurnSucceeded = true
        state.active?.phase = .parked
        fixture.session.selfCompactState = state
        return try AgentSelfCompactionDispatchID(requestID: XCTUnwrap(state.active?.id), stage: .note)
    }

    // MARK: - Dispatch identity

    /// The wake ID survives a round trip through the opaque dispatch ID.
    ///
    /// This is what makes acceptance decidable from the claim alone: the provider hands back a claim,
    /// and the wake it settles is read out of that claim rather than out of whatever the session
    /// happens to hold at the time.
    func testAutoWakeDispatchIDRoundTripsItsWakeAndNothingElseClaimsToBeOne() {
        let wakeID = UUID()
        XCTAssertEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID).autoWakeID,
            wakeID
        )
        XCTAssertNotEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID),
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: UUID())
        )
        for ordinary: AgentSessionLinkPromptDispatchID in [
            .claudeNativeSend(wakeID),
            .codexNativeSend(wakeID),
            .codexFallback(queueID: wakeID),
            .headlessRun(runID: wakeID),
            .acpPromptTurn(runAttemptID: wakeID),
            .acpActiveSteering(runAttemptID: wakeID),
            .waitingContinuation(waitID: wakeID)
        ] {
            XCTAssertNil(
                ordinary.autoWakeID,
                "an ordinary provider dispatch must never be mistaken for a wake"
            )
        }
        XCTAssertNil(AgentSessionLinkPromptDispatchID(rawValue: "lane.autowake:nope").autoWakeID)

        // The historical two-component form named a fence that no longer exists. It must read as
        // *malformed reserved family*, never as an ordinary dispatch: the physical seam classifies by
        // family first precisely so a stale identity cannot slip through the ordinary pass-through.
        let legacy = AgentSessionLinkPromptDispatchID(rawValue: "lane.autowake:\(wakeID.uuidString):3")
        XCTAssertNil(legacy.autoWakeID)
        XCTAssertTrue(legacy.isAutoWakeFamily)
    }

    /// A wake's claim is refused outright unless the lane batch it exists to deliver is present.
    ///
    /// The requirement is a property of the dispatch identity, not a caller-supplied flag, so it
    /// cannot be forgotten by one provider family and honoured by another. An ordinary dispatch in
    /// the same state is still allowed to carry membership alone.
    func testAWakeClaimRequiresTheLaneBatchWhileAnOrdinaryDispatchDoesNot() {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)

        let store = AgentSessionLinkOutboundPromptClaimStore()
        let ordinary = store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: nil,
            render: AgentSessionLinkPrompts.rendered
        )
        XCTAssertNotNil(ordinary, "membership alone is a perfectly good ordinary dispatch")
        XCTAssertNil(ordinary?.passive)

        let wakeStore = AgentSessionLinkOutboundPromptClaimStore()
        XCTAssertNil(
            wakeStore.claim(
                dispatchID: .autoWake(wakeID: UUID()),
                epoch: epoch,
                inventory: inventory,
                passiveNotices: nil,
                render: AgentSessionLinkPrompts.rendered
            ),
            "a wake must not start a turn carrying membership alone"
        )
    }

    // MARK: - Guidance revision

    /// A context that accepted either parallel revision-11 branch is re-owed revision 12 in full.
    /// Merely rendering or abandoning revision 12 does not advance the acknowledgement; only physical
    /// acceptance earns the reminder, and a rebuilt context owes the full block again.
    func testRevisionTwelveReOwesCombinedGuidanceAndReminderIsAcceptanceGated() throws {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)
        let store = AgentSessionLinkOutboundPromptClaimStore()

        let first = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 1),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(first.laneGuidanceMode, .full)

        // Seed the only state an upgrade has that a fresh context cannot produce: this exact epoch
        // physically accepted the prior guidance revision. The memberwise copy preserves all claim
        // authority; only the revision the provider is treated as having seen is historical.
        let passive = try XCTUnwrap(first.passive)
        let priorRevisionClaim = AgentSessionLinkOutboundPromptClaim(
            observerSessionID: first.observerSessionID,
            dispatchID: first.dispatchID,
            epochToken: first.epochToken,
            membership: first.membership,
            passiveQueue: first.passiveQueue,
            passive: AgentSessionLinkOutboundPromptClaim.PassiveStatusComponent(
                observerEndpoint: passive.observerEndpoint,
                receipt: passive.receipt,
                includesUnattributedOverflow: passive.includesUnattributedOverflow,
                guidanceRevision: 11,
                displayAttribution: passive.displayAttribution
            ),
            laneGuidanceMode: first.laneGuidanceMode,
            inventoryGuidanceRevision: 6,
            fragment: first.fragment
        )
        store.accept(priorRevisionClaim)
        XCTAssertEqual(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID),
            11
        )

        let reOwed = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 2),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(reOwed.laneGuidanceMode, .full)
        XCTAssertTrue(reOwed.fragment.contains("Guidance revision 14 supersedes"))
        XCTAssertEqual(reOwed.inventoryGuidanceRevision, AgentSessionLinkPrompts.currentInventoryGuidanceRevision)
        XCTAssertTrue(reOwed.fragment.contains("`compact`"))
        XCTAssertTrue(reOwed.fragment.contains("`stop`"))
        XCTAssertTrue(reOwed.fragment.contains("`create_lane`"))
        XCTAssertTrue(reOwed.fragment.contains("`retire_lane`"))
        // The rule revision 10 restates: a context taught it may only observe — and that may have
        // refused its own user on that basis — is told outright what replaced it.
        XCTAssertTrue(reOwed.fragment.contains("including anything said earlier in this conversation"))
        XCTAssertTrue(reOwed.fragment.contains("by RepoPrompt or by you"))
        XCTAssertTrue(reOwed.fragment.contains("being unable to steer it"))
        XCTAssertTrue(reOwed.fragment.contains("direct it with `steer`"))
        XCTAssertTrue(reOwed.fragment.contains("attributed attention request"))
        XCTAssertTrue(reOwed.fragment.contains("master Auto-wake"))
        XCTAssertTrue(reOwed.fragment.contains("lane&apos;s own toggle"))
        XCTAssertTrue(reOwed.fragment.contains("exact lane&apos;s status Auto-wake snooze"))
        XCTAssertTrue(reOwed.fragment.contains("status and overflow"))
        XCTAssertTrue(reOwed.fragment.contains("selection and snooze"))
        XCTAssertTrue(reOwed.fragment.contains("without changing any of them"))
        XCTAssertTrue(reOwed.fragment.contains("Unlink, revocation, exact authority, readiness"))
        XCTAssertFalse(reOwed.fragment.contains("It cannot select a lane"))
        XCTAssertTrue(reOwed.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // Rendering is not acceptance: an abandoned batch leaves the wording still owed.
        store.abandon(reOwed)
        let retried = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 3),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(retried.laneGuidanceMode, .full)

        store.accept(retried)
        XCTAssertEqual(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID),
            AgentSessionLinkPrompts.currentLaneGuidanceRevision
        )

        let later = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 4),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(later.laneGuidanceMode, .reminder)
        XCTAssertTrue(later.fragment.contains("Lane update or attributed attention:"))
        XCTAssertTrue(later.fragment.contains("still-applicable standing instruction"))
        XCTAssertTrue(later.fragment.contains("attention supplies no task"))
        XCTAssertTrue(later.fragment.contains("Never invent work"))
        XCTAssertTrue(later.fragment.contains("bypass a prompt (answer or steer only where `manage` is granted)"))
        XCTAssertTrue(later.fragment.contains("Surface ambiguity or surprises"))
        XCTAssertFalse(later.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // A rebuilt provider conversation never saw the wording, so it is owed in full again.
        store.invalidateAcknowledgedContext(observerSessionID: observerSessionID)
        XCTAssertNil(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID)
        )
        let rebuilt = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 5),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(rebuilt.laneGuidanceMode, .full)
    }

    // MARK: - Readiness

    /// A reserved wake makes the observer busy for every other observer's `send`.
    ///
    /// Without this the wake and an inbound delivery race for the same terminal boundary, and the
    /// loser is silently dropped.
    func testAReservedWakeMakesTheObserverUnsendable() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot), .ready)
        snapshot.pendingOversightAutoWake = true
        XCTAssertEqual(
            AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot).blockReason,
            .targetNotIdle
        )
    }

    // MARK: - Provenance

    /// The visible row is keyed by the wake, stamped at physical acceptance, and says nothing about
    /// which sessions changed.
    func testLaneUpdateSystemRowIsKeyedByWakeAndCarriesNoTargetDetail() {
        let wakeID = UUID()
        let acceptedAt = Date(timeIntervalSince1970: 1234)
        let row = AgentChatItem.laneUpdateAutoWake(wakeID: wakeID, acceptedAt: acceptedAt)
        XCTAssertEqual(row.id, wakeID, "duplicate acceptance callbacks dedupe by identity")
        XCTAssertEqual(row.timestamp, acceptedAt)
        XCTAssertEqual(row.kind, .system, "RepoPrompt started this turn and must not claim authorship")
        XCTAssertTrue(row.text.hasPrefix("[lane-update]"))
        for forbidden in [wakeID.uuidString, "preview", "session_id", "/Users/"] {
            XCTAssertFalse(row.text.contains(forbidden))
        }
    }

    // MARK: - Coordinator

    /// Enabling is what arms the wake, and the reservation is visible where readiness is computed.
    ///
    /// Driven through `agentSessionLinkPublishPassiveStatusNotices` — the same endpoint-addressed
    /// hook the bridge publishes through — so this exercises the real scheduling gate rather than a
    /// test-only entry point.
    func testDeliverableContentReservesExactlyOneWakeOnlyWhenTheSettingIsOn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        // Setting off: content is collected and delivered naturally, but nothing is reserved.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(reserved.queueRevision, 2)

        // A newer revision raises the high-water mark of the one attempt rather than starting a
        // second: an observer reserves at most one automatic follow-up.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        let absorbed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(absorbed.wakeID, reserved.wakeID)
        XCTAssertEqual(absorbed.queueRevision, 3)
    }

    func testPostCompositionAttentionIsNotRecordedAsAttemptedAndIsNotSuppressed() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertTrue(try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.isEmpty)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            attentionRequests: [attention]
        )

        let absorbed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(absorbed.wakeID, reserved.wakeID)
        XCTAssertEqual(absorbed.wakeFingerprint?.attentionOccurrences, [attention.occurrence])
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        let dispatching = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(
            try XCTUnwrap(dispatching.attemptedFingerprint).attentionOccurrences.isEmpty,
            "only attention present in the immutable rendered claim may count as attempted"
        )

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )

        XCTAssertTrue(
            try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
                .attentionOccurrences.isEmpty,
            "post-composition attention may not be failure-suppressed"
        )
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "ambiguous settlement must drain the one owed reevaluation"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.wakeFingerprint?.attentionOccurrences, [attention.occurrence])
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
    }

    func testMetadataRefreshDoesNotInvalidateRenderedStatusAcquisitionBasis() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.first?.changeSequence, 1)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            metadataSequenceOffset: 10,
            latestVisibleAssistantPreview: "Fresher metadata."
        )
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeFingerprint,
            reserved.wakeFingerprint,
            "presentation-only refresh must not change the status occurrence fingerprint"
        )

        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testCrowdedAutoWakeClaimCarriesItsRequiredFirstAttentionOccurrence() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let required = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0, 1],
            latestVisibleAssistantPreview: String(repeating: "<&🙂", count: 8000),
            attentionRequests: [required]
        )

        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, required.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        XCTAssertLessThanOrEqual(
            claim.fragment.utf8.count,
            AgentSessionLinkPrompts.maximumRenderedBytes
        )
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.first,
            required.occurrence
        )
    }

    /// Acceptance of a budgeted subset republishes the reduced authoritative queue immediately. The
    /// remaining rows must therefore reserve their own wake without waiting for another target edge.
    func testAcceptedPartialBatchReceiptRepublicationReservesSuccessorWakeWithoutAnotherEdge() throws {
        let fixture = try makeFixture()
        let targetIndices = Array(0 ..< 9)
        try publishInventory(fixture, revision: 1, targetCount: targetIndices.count)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let queueEpoch = UUID()
        let richText = String(repeating: "<&é🙂\"'", count: 180)
        let waitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: richText,
            declaredAt: Date(timeIntervalSince1970: 50)
        ))
        func samples(_ status: AgentSessionLinkPassiveStatusNotices.Status) ->
            [AgentSessionLinkPassiveStatusNotices.Sample]
        {
            targetIndices.map { index in
                AgentSessionLinkPassiveStatusNotices.Sample(
                    reference: Self.laneReference(index),
                    targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index),
                    displayName: richText,
                    status: status,
                    idleForSend: status == .idle,
                    waitingOn: waitingOn,
                    latestVisibleAssistantPreview: richText
                )
            }
        }

        var notices = AgentSessionLinkPassiveStatusNotices(
            observerEndpoint: endpoint,
            queueEpoch: queueEpoch
        )
        notices.enable(samples: samples(.running), linkSetRevision: 1)
        notices.setAutoWakeLanes(targetIndices.map { index in
            AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                reference: Self.laneReference(index),
                targetEndpoint: Self.laneTargetEndpoint(index),
                targetSessionID: Self.targetID(index),
                isEffectivelySelected: true
            )
        })
        for index in targetIndices {
            XCTAssertEqual(
                notices.requestAttention(
                    reference: Self.laneReference(index),
                    targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index),
                    linkSetRevision: 1,
                    requestedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                ),
                .accepted
            )
        }
        notices.reconcile(
            samples: samples(.idle),
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let offeredCount = notices.snapshot.entries.count + notices.snapshot.attentionRequests.count
        XCTAssertEqual(offeredCount, targetIndices.count * 2)
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            notices.snapshot,
            to: endpoint
        )

        let firstAttempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        firstAttempt.task?.cancel()
        let firstClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: firstAttempt.wakeID)
        ))
        let firstReceipt = try XCTUnwrap(firstClaim.passive).receipt
        let firstDeliveredCount = firstReceipt.deliveredStatuses.count
            + firstReceipt.deliveredAttentionOccurrences.count
        XCTAssertGreaterThan(firstDeliveredCount, 0)
        XCTAssertLessThan(firstDeliveredCount, offeredCount, "the rich queue must be budgeted")

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(firstClaim)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // `publishLane` fixtures intentionally inject already-reduced snapshots, so mirror only the
        // runtime bridge's synchronous receipt body here: apply the accepted exact-subset receipt and
        // republish that reducer's resulting snapshot. This is receipt settlement, not a new target
        // activity publication.
        notices.apply(firstReceipt)
        let remaining = notices.snapshot
        XCTAssertEqual(
            remaining.entries.count + remaining.attentionRequests.count,
            offeredCount - firstDeliveredCount
        )
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(remaining, to: endpoint)

        let successor = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "receipt republication must re-admit the deferred rows without another target edge"
        )
        successor.task?.cancel()
        XCTAssertNotEqual(successor.wakeID, firstAttempt.wakeID)
        XCTAssertEqual(successor.queueRevision, remaining.queueRevision)
        let successorClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: successor.wakeID)
        ))
        let successorReceipt = try XCTUnwrap(successorClaim.passive).receipt
        XCTAssertTrue(Set(firstReceipt.deliveredAttentionOccurrences).isDisjoint(
            with: successorReceipt.deliveredAttentionOccurrences
        ))
        XCTAssertTrue(Set(firstReceipt.deliveredStatuses).isDisjoint(
            with: successorReceipt.deliveredStatuses
        ))
    }

    func testSuppressedStatusCannotSaveAttentionThatEscapedSuppressionButWasOmitted() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressWake(failedStatus.wakeFingerprint, producerWakeID: UUID())

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "exact purposeful attention may re-arm an otherwise suppressed status shape"
        )
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)

        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
            dispatchID: .autoWake(wakeID: reserved.wakeID),
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            render: { request in
                AgentSessionLinkPromptRenderResult(
                    fragment: "[attention omitted]",
                    passiveBatch: .init(
                        entries: request.passiveNotices?.entries ?? [],
                        attentionRequests: [],
                        overflowProducedThrough: request.passiveNotices?.overflowProduced ?? 0,
                        includesUnattributedOverflow: false
                    )
                )
            }
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint,
            failedStatus.wakeFingerprint
        )
    }

    func testPurposefulAttentionIgnoresRoutineSelectionWhenRearmingSuppressedStatus() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0],
            laneIndices: [0, 1],
            selectedTargetIndices: [0]
        )
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressWake(failedStatus.wakeFingerprint, producerWakeID: UUID())

        let attention = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0],
            laneIndices: [0, 1],
            selectedTargetIndices: [0],
            attentionRequests: [attention]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "purposeful attention must bypass lane-one's routine deselection"
        )
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
    }

    func testRenderedAttentionThatFailedIsSuppressedAndRemainsOwedForNaturalTurn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )

        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint?.attentionOccurrences,
            [attention.occurrence]
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the same failed attention occurrence must not loop automatically"
        )
        let naturalClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .claudeNativeSend(UUID())
        ))
        XCTAssertEqual(
            try XCTUnwrap(naturalClaim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence],
            "failure suppression never discards natural-turn delivery"
        )
    }

    func testNewAttentionRearmsFailedAttentionAndIsTheExactRequiredBasis() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let failedAttention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention]
        )
        let failed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failed.task?.cancel()
        let failedClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: failed.wakeID)
        ))
        var failedPreparing = failed
        failedPreparing.phase = .preparingDispatch
        failedPreparing.task = nil
        fixture.session.oversight.pendingAutoWake = failedPreparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: failedClaim.dispatchID
        ))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: failedClaim.dispatchID
        )

        let successor = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention, successor]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a new exact occurrence may re-arm an older failed occurrence"
        )
        reserved.task?.cancel()
        XCTAssertEqual(
            reserved.requiredAttentionOccurrence,
            successor.occurrence,
            "the newly admitting occurrence, not the older pending failure, owns the bypass"
        )

        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let incompleteClaim = try XCTUnwrap(
            fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
                dispatchID: .autoWake(wakeID: reserved.wakeID),
                epoch: context.epoch,
                inventory: context.inventory,
                passiveNotices: context.passiveNotices,
                render: { _ in
                    AgentSessionLinkPromptRenderResult(
                        fragment: "[only the failed occurrence fit]",
                        passiveBatch: .init(
                            entries: [],
                            attentionRequests: [failedAttention],
                            overflowProducedThrough: 0,
                            includesUnattributedOverflow: false
                        )
                    )
                }
            )
        )
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: incompleteClaim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
    }

    func testNewPurposefulAttentionIgnoresRoutineSelectionWhenRearmingOlderFailure() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let failedAttention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention]
        )
        let failed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failed.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failed.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressWake(failed.wakeFingerprint, producerWakeID: UUID())

        fixture.session.oversight.autoWakeOnUpdates = false
        let successor = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0],
            attentionRequests: [failedAttention, successor]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a new purposeful occurrence may re-arm an older failure despite routine deselection"
        )
        reserved.task?.cancel()
        XCTAssertEqual(
            reserved.requiredAttentionOccurrence,
            successor.occurrence,
            "the newly admitting exact occurrence owns the routine-policy bypass"
        )
    }

    func testAttentionSuppressionDoesNotChangeTheMutableStatusAcquisitionRace() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressWake(failedStatus.wakeFingerprint, producerWakeID: UUID())

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertNil(reserved.requiredAttentionOccurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testPurposefulAttentionBypassesOnlyItsExactLaneSnooze() throws {
        let bypass = try makeFixture()
        installSnoozeClock(bypass)
        try publishInventory(bypass, revision: 1)
        bypass.session.oversight.autoWakeOnUpdates = true
        bypass.session.runState = .running
        let bypassEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            bypass.viewModel,
            tabID: bypass.tabID
        )
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        for laneIndex in [0, 1] {
            _ = try requireSnoozeSuccess(mutateSnooze(
                bypass,
                endpoint: bypassEndpoint,
                laneIndex: laneIndex,
                command: .set(durationSeconds: 600)
            ))
        }

        let attention = Self.attentionRequest(0)
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [1],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1],
            attentionRequests: [attention]
        )
        let attentionDriven = try XCTUnwrap(
            bypass.session.oversight.pendingAutoWake,
            "purposeful attention may bypass its exact lane's snooze"
        )
        attentionDriven.task?.cancel()
        XCTAssertEqual(attentionDriven.requiredAttentionOccurrence, attention.occurrence)
        XCTAssertEqual(bypass.session.oversight.autoWakeSnoozes.count, 2)

        bypass.viewModel.cancelAgentSessionLinkAutoWake(
            for: bypassEndpoint,
            reason: .settingDisabled
        )
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 3,
            targetIndices: [1],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        XCTAssertNil(
            bypass.session.oversight.pendingAutoWake,
            "attention for lane zero must not broadly unsnooze routine status on lane one"
        )
    }

    func testPurposefulAttentionIgnoresRoutineSelectionThroughPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)

        // Master and per-lane routine selection are now both off, with no republication. The real
        // master mutator must route through the shared live fence, retain the exact attention attempt,
        // and let physical acquisition apply the same exception rather than trusting the stale
        // routine-selection projection.
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpoint
        ))
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )
    }

    func testPurposefulAttentionSelectionBypassStillRequiresExactLaneGeneration() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let staleAttention = Self.attentionRequest(0)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            referenceGeneration: 2,
            attentionRequests: [staleAttention]
        )

        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "ignoring routine selection must not ignore the generation-qualified lane authority"
        )
    }

    func testPostClaimUnlinkRefusesAttentionAndOldOccurrenceCannotReplayThroughRelinkedGeneration() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence]
        )

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        // Unlink generation 1 while its exact attention-backed claim is already reserved. Preparation
        // must become a transport tombstone rather than trusting the immutable claim's stale grant.
        try publishLane(
            fixture,
            linkSetRevision: 2,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [1],
            selectedTargetIndices: []
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // A relinked generation is a different authority. Even if a later projection still carries
        // the retired occurrence, releasing the tombstone must not replay it through generation 2.
        try publishLane(
            fixture,
            linkSetRevision: 3,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            referenceGeneration: 2,
            attentionRequests: [attention]
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        XCTAssertNil(fixture.viewModel.agentSessionLinkPromptClaimStore.pendingClaim(
            dispatchID: claim.dispatchID,
            observerSessionID: fixture.sessionID
        ))
    }

    func testBudgetOmissionOfRequiredAttentionBasisIsADefiniteNoCall() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0]
        )
        _ = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 600)
        ))
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpoint
        ))
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
            dispatchID: .autoWake(wakeID: reserved.wakeID),
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            render: { request in
                let renderedStatuses = request.passiveNotices?.entries ?? []
                return AgentSessionLinkPromptRenderResult(
                    fragment: "[lane-update omitted by budget]",
                    passiveBatch: .init(
                        entries: renderedStatuses,
                        attentionRequests: [],
                        overflowProducedThrough: request.passiveNotices?.overflowProduced ?? 0,
                        includesUnattributedOverflow: false
                    )
                )
            }
        ))
        XCTAssertTrue(try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.isEmpty)
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.count, 1)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testAttentionDrivenWakeRequiresItsReservedOccurrenceAtPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let first = Self.attentionRequest(0, sequence: 1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [first]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [first.occurrence]
        )

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        let successor = Self.attentionRequest(0, sequence: 2)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [successor]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "refusing the stale basis must replay the successor occurrence"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.requiredAttentionOccurrence, successor.occurrence)
        XCTAssertEqual(replayed.wakeFingerprint?.attentionOccurrences, [successor.occurrence])
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testOwedReevaluationIsDrainedByNotAttemptedSettlement() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let absorbedFingerprint = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake
        ).wakeFingerprint
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a definite no-call settlement must replay the absorbed publication"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.wakeFingerprint, absorbedFingerprint)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testUnreadyCatalogDoesNotDelayOrDuplicateOwedWake() async throws {
        let fixture = try makeFixture(catalogReady: false)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        try await AsyncTestWait.waitUntil("the owed wake without a tool-list refresh") {
            await MainActor.run {
                fixture.session.oversight.pendingAutoWake?.phase == .awaitingSettlement
            }
        }
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)

        let projection = try publishCatalogProjection(fixture, revision: 1, hasAgentSessionLink: true)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        // Discovery catching up must not reserve a second wake for the same pending batch.
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            projection,
            to: reserved.observerEndpoint
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testColdRestoredObserverSchedulesPurposefulAttentionWithoutPriorRunCatalog() throws {
        let fixture = try makeFixture(catalogReady: false)
        let priorRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(fixture.session.clearRunID(ifCurrent: priorRunID))
        try publishInventory(fixture, revision: 1)
        XCTAssertEqual(fixture.session.runState, .idle)

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a cold-restored observer must be able to bootstrap the run that creates its catalog"
        )
        reserved.task?.cancel()
        XCTAssertNil(fixture.session.runID)
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence]
        )
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testColdRestoredRoutineWakeStillRequiresSelection() throws {
        let fixture = try makeFixture(catalogReady: false)
        let priorRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(fixture.session.clearRunID(ifCurrent: priorRunID))
        try publishInventory(fixture, revision: 1)
        XCTAssertEqual(fixture.session.runState, .idle)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "cold restoration must not broaden routine Auto-wake admission"
        )

        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a selected routine update must bootstrap a cold-restored observer"
        )
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.count, 1)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testParkedAttentionWakePreparesAfterExecutionLocationCancellation() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.runState = .running
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture, linkSetRevision: 1, queueRevision: 1,
            targetIndices: [], laneIndices: [0], attentionRequests: [attention]
        )
        try await AsyncTestWait.waitUntil("the attention wake to park behind the active run") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake?.phase == .awaitingSettlement }
        }
        let parked = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        // Exercise the production preparation seam without launching a provider after settlement.
        parked.task?.cancel()
        let reservationFence = AgentRunStartStopFence(session: fixture.session)
        fixture.session.isChangingExecutionLocation = true
        fixture.viewModel.prepareAgentRunCancellation(
            session: fixture.session, intent: .executionLocationChange, origin: .internalLifecycle
        )
        fixture.session.runState = .idle
        let runID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(fixture.session.clearRunID(ifCurrent: runID))
        fixture.session.isChangingExecutionLocation = false

        XCTAssertFalse(reservationFence.permitsStart(of: fixture.session))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, parked.wakeID)
        XCTAssertEqual(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID), parked.observerEndpoint)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .autoWake(wakeID: parked.wakeID)
        ))
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences, [attention.occurrence])
        let options = try XCTUnwrap(fixture.viewModel.agentSessionLinkPrepareAutoWakeDispatch(
            wakeID: parked.wakeID, endpoint: parked.observerEndpoint
        ))
        let dispatchFence = try XCTUnwrap(options.stopFence)
        XCTAssertEqual(options.laneUpdateWakeID, parked.wakeID)
        XCTAssertTrue(dispatchFence.permitsStart(of: fixture.session))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .preparingDispatch)

        // A cancellation after preparation must still invalidate the producer, never re-stamp it.
        fixture.viewModel.prepareAgentRunCancellation(
            session: fixture.session, intent: .executionLocationChange, origin: .internalLifecycle
        )
        XCTAssertFalse(dispatchFence.permitsStart(of: fixture.session))
        XCTAssertNil(fixture.viewModel.agentSessionLinkPrepareAutoWakeDispatch(
            wakeID: parked.wakeID, endpoint: parked.observerEndpoint
        ))
    }

    func testExplicitStopCannotPrepareAParkedAttentionWake() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.runState = .running
        try publishLane(
            fixture, linkSetRevision: 1, queueRevision: 1,
            targetIndices: [], laneIndices: [0], attentionRequests: [Self.attentionRequest(0)]
        )
        try await AsyncTestWait.waitUntil("the attention wake to park before Stop") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake?.phase == .awaitingSettlement }
        }
        let parked = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        fixture.viewModel.prepareAgentRunCancellation(
            session: fixture.session, intent: .userStop, origin: .explicitStop
        )
        fixture.session.runState = .idle
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(fixture.viewModel.agentSessionLinkPrepareAutoWakeDispatch(
            wakeID: parked.wakeID, endpoint: parked.observerEndpoint
        ))
    }

    func testUserStopRetractsOnlyPreDispatchAutoWakePhases() throws {
        for phase: AgentSessionLinkAutoWakeAttempt.Phase in [
            .scheduled, .awaitingSettlement, .preparingDispatch,
            .cancelledBeforeDispatch, .dispatching
        ] {
            let fixture = try makeFixture()
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            fixture.session.runState = .running
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            var reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
            reserved.task?.cancel()
            reserved.phase = phase
            fixture.session.oversight.pendingAutoWake = reserved

            fixture.viewModel.agentSessionLinkRetractAutoWakeForUserStop(fixture.session)
            XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, reserved.wakeFingerprint)
            switch phase {
            case .scheduled, .awaitingSettlement:
                XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            case .preparingDispatch, .cancelledBeforeDispatch:
                XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
                fixture.viewModel.agentSessionLinkRetractAutoWakeForUserStop(fixture.session)
                XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
            case .dispatching:
                XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
            }
        }
    }

    func testObserverAdmitsOneWakeForCancelledTargetStatusEdge() throws {
        // This fixture is the observer side of Stop: the target's accepted cancelled publication
        // appears here as one running -> idle status edge, not as a target-side wake retraction.
        let observer = try makeFixture()
        try publishInventory(observer, revision: 1)
        observer.session.oversight.autoWakeOnUpdates = true
        observer.session.runState = .running
        XCTAssertNil(observer.session.oversight.suppressedWakeFingerprint)
        try publishLane(
            observer, linkSetRevision: 1, queueRevision: 0,
            targetIndices: [], laneIndices: [0]
        )
        XCTAssertNil(observer.session.oversight.pendingAutoWake)
        try publishLane(observer, linkSetRevision: 1, queueRevision: 1)
        let first = try XCTUnwrap(observer.session.oversight.pendingAutoWake)
        first.task?.cancel()
        try publishLane(observer, linkSetRevision: 1, queueRevision: 1)
        XCTAssertEqual(observer.session.oversight.pendingAutoWake?.wakeID, first.wakeID)
        XCTAssertEqual(observer.session.oversight.pendingAutoWake?.wakeFingerprint, first.wakeFingerprint)
        observer.viewModel.cancelAgentSessionLinkAutoWake(
            for: first.observerEndpoint, reason: .settingDisabled
        )
    }

    func testBusyWakeAwaitsOneCancellableObservationSubscription() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let parked = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(parked.phase, .awaitingSettlement)
        XCTAssertNotNil(parked.task, "busy reevaluation must own the awaited readiness subscription")
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: parked.observerEndpoint,
            reason: .settingDisabled
        )
        XCTAssertTrue(parked.task?.isCancelled == true)
    }

    func testQueueSideCompetitionCannotEraseDispatchingWakeIdentity() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            admissionBasis: reserved.admissionBasis,
            attemptedFingerprint: reserved.wakeFingerprint,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])

        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint,
            reserved.wakeFingerprint
        )
    }

    /// The pipeline the product ruling exists to allow: wake, accept, new edge, wake again — with no
    /// local user turn anywhere in between.
    ///
    /// Each accepted wake used to leave the observer on a non-local origin that only a fresh human
    /// utterance could clear, so a delegated multi-stage pipeline stalled at the *second* Auto-wake
    /// even though the user had already granted and selected the lane. Admission is now decided by
    /// selection, snooze, and whether a genuinely new edge exists.
    func testRepeatedAutonomousWakesAdmitWithoutAnyInterveningLocalUserTurn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true

        var queueRevision: UInt64 = 0
        var edgeOffset: UInt64 = 0
        var acceptedWakeIDs: [UUID] = []
        for wakeNumber in 1 ... 3 {
            queueRevision += 1
            edgeOffset += 10
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: queueRevision,
                edgeSequenceOffset: edgeOffset
            )
            let attempt = try XCTUnwrap(
                fixture.session.oversight.pendingAutoWake,
                "wake \(wakeNumber) must be admitted by its own new edge"
            )

            // Accepted exactly as a provider would, through the claim that carries its identity.
            let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
                for: fixture.session,
                dispatchID: .autoWake(wakeID: attempt.wakeID)
            ))
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
            acceptedWakeIDs.append(attempt.wakeID)
            XCTAssertNil(
                fixture.session.oversight.pendingAutoWake,
                "wake \(wakeNumber) must settle on acceptance"
            )
        }

        XCTAssertEqual(Set(acceptedWakeIDs).count, 3, "each wake has its own identity")
        for wakeID in acceptedWakeIDs {
            XCTAssertEqual(
                fixture.session.items.count(where: { $0.id == wakeID }),
                1,
                "each accepted wake leaves exactly one visible provenance row"
            )
        }
    }

    /// Two independently granted, independently selected directions each keep waking on their own
    /// new routine status edges — and routine selection is what stops one of them.
    ///
    /// This is the accepted product consequence of the deletion, pinned rather than papered over.
    /// Neither grant implies the other; the user created both. The transport deliberately encodes no
    /// reciprocal detector, cycle counter, or cooldown. Per-lane snooze and Auto-wake deselection stop
    /// this routine status churn; exact purposeful attention may bypass both, while unlink remains the
    /// hard control for that signal. This test exercises only the routine-status half.
    func testReciprocalRoutineStatusEdgesStopWhenOneDirectionIsDeselected() throws {
        let observerA = try makeFixture()
        let observerB = try makeFixture()
        for fixture in [observerA, observerB] {
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
        }

        // Round 1: each direction's own new edge admits its own wake.
        try publishLane(observerA, linkSetRevision: 1, queueRevision: 1, edgeSequenceOffset: 10)
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 1, edgeSequenceOffset: 10)
        let wakeA1 = try XCTUnwrap(observerA.session.oversight.pendingAutoWake).wakeID
        let wakeB1 = try XCTUnwrap(observerB.session.oversight.pendingAutoWake).wakeID
        try acceptWake(observerA, wakeID: wakeA1)
        try acceptWake(observerB, wakeID: wakeB1)

        // Round 2: each accepted wake is itself a lifecycle change the *other* side observes, and
        // that genuinely new edge admits again. No local user turn happened anywhere.
        try publishLane(observerA, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 20)
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 20)
        let wakeA2 = try XCTUnwrap(
            observerA.session.oversight.pendingAutoWake,
            "reciprocal churn is an accepted consequence, not something the transport damps"
        ).wakeID
        XCTAssertNotEqual(wakeA2, wakeA1)
        XCTAssertNotNil(observerB.session.oversight.pendingAutoWake)
        try acceptWake(observerA, wakeID: wakeA2)
        let wakeB2 = try XCTUnwrap(observerB.session.oversight.pendingAutoWake).wakeID
        try acceptWake(observerB, wakeID: wakeB2)

        // The user applies a control to one direction only.
        let endpointA = try AgentSessionLinkEndpointTestSupport.endpoint(
            observerA.viewModel,
            tabID: observerA.tabID
        )
        XCTAssertTrue(observerA.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpointA
        ))
        observerA.session.oversight.autoWakeTargetSessionIDs = []

        try publishLane(
            observerA,
            linkSetRevision: 1,
            queueRevision: 3,
            edgeSequenceOffset: 30,
            selectedTargetIndices: []
        )
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 3, edgeSequenceOffset: 30)

        XCTAssertNil(
            observerA.session.oversight.pendingAutoWake,
            "deselecting Auto-wake must stop later admission for that direction"
        )
        XCTAssertNotNil(
            observerB.session.oversight.pendingAutoWake,
            "a control on one direction must not silence the other"
        )
    }

    /// Accepts one wake through the real claim path, exactly as a provider's acceptance signal does.
    private func acceptWake(_ fixture: Fixture, wakeID: UUID) throws {
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID)
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "an accepted wake settles")
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == wakeID }),
            1,
            "each accepted wake leaves exactly one visible provenance row"
        )
    }

    /// Master off plus an unselected lane is the combination that must stay silent, and selecting
    /// that same lane is what makes its next update wake-eligible.
    func testMasterOffLeavesAnUnselectedLaneSilentUntilThatLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "an unselected lane must not reserve a turn while the master switch is off"
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(
            fixture.session.oversight.pendingAutoWake,
            "a granular selection is sufficient on its own"
        )
    }

    /// Overflow is a whole-queue count, never attributed to the lane that produced it.
    ///
    /// Regression: "some lane is selected" was enough for overflow to reserve a wake, so dropped
    /// edges belonging to an excluded target started an autonomous turn — the selected lane's only
    /// contribution being that it existed.
    func testOverflowFromAnUnselectedLaneCannotWakeMerelyBecauseAnotherLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)

        // No entries at all, so the unattributed overflow is the only thing that could trigger a
        // wake — and one of the two live lanes is excluded from Auto-wake.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )

        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "overflow that may have come from an excluded lane must not reserve a turn"
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "refusing to wake is not discarding the queue: the overflow stays owed to a natural turn"
        )
    }

    /// The conservative rule is not "overflow never wakes": once every live lane is selected, the
    /// dropped edges provably belong to lanes the user opted in to.
    ///
    /// Scheduling and the acceptance fence must apply the identical predicate, so an attempt admitted
    /// under "every lane selected" stops qualifying the moment one of them is excluded.
    func testOverflowWakesOnlyWhenEveryLiveLaneIsSelectedAndTheFenceAppliesTheSameRule() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0, 1]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "overflow across a fully selected lane set is wake-eligible"
        )

        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        fixture.session.oversight.autoWakeTargetSessionIDs = [Self.targetID(0)]

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // Master-on satisfies the rule by construction, so the whole-observer case keeps waking on
        // overflow alone even while the granular set is a strict subset.
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)
    }

    /// Selection is live session state; the lane flag in a published snapshot is only the projection
    /// of it that publication froze, and the two disagree for exactly as long as a refresh takes.
    ///
    /// Regression: the acceptance fence read that projection, so a lane the user deselected while a
    /// wake was already preparing could still cross the provider transport boundary and start a turn
    /// nobody asked for.
    func testDeselectingALaneRefusesItsWakeAtTheAcceptanceFenceBeforeAnyRepublication() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        // Deselected with no republication: the snapshot the fence used to consult still reports the
        // lane as selected, so only a live read can refuse this.
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?
                .autoWakeLanes.map(\.isEffectivelySelected),
            [true],
            "precondition: the published projection has not caught up with the deselection"
        )

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// The same live selection is what makes the mutation itself retract an attempt, rather than
    /// leaving a deselected lane's wake alive until something else happens to re-evaluate it.
    func testDeselectingALaneRetractsAScheduledWakeSynchronously() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([], for: endpoint))

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "deselecting stops scheduling; it does not discard the queue"
        )
    }

    /// Once selection retracts a preparing attempt, later selection writes cannot release its transport
    /// tombstone. Only a path that proves the provider call did not occur may retire that identity.
    func testRepeatedSelectionChangesDoNotClearPreDispatchTombstone() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0],
            laneIndices: [0],
            selectedTargetIndices: []
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [Self.targetID(0)],
            for: endpoint
        ))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([], for: endpoint))
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeID,
            reserved.wakeID,
            "repeated selection loss must not clear the dispatch-ID fence"
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the refused physical boundary safely releases the tombstone"
        )
    }

    /// Selecting a lane makes its *next* update wake-eligible and changes nothing retroactively.
    ///
    /// Selection is read live rather than from the lane's frozen projection, so a freshly selected
    /// lane does not have to wait for an authoritative republication to become eligible — and an
    /// already-published edge that predates the selection does not manufacture a turn either.
    func testSelectingALaneMakesItsNextUpdateEligibleWithoutRetroactiveWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        // The lane is live and unselected, with no queued edge yet.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: []
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [Self.targetID(0)],
            for: endpoint
        ))
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "selecting a lane must not retroactively wake on state that already existed"
        )

        // The lane's next genuine edge is eligible under the new selection.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)
    }

    /// This cancellation test owns wake scheduling; positive exact-Read/frontier and physical
    /// waiting-resume coverage uses the shared real-authority fixture in the adapter suite.
    func testLocalInputCancelledWaitingAutoWakeDuringReadProofDoesNotResumeOrConsume() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let gate = TestReleaseFence(name: "waiting Auto-wake optional Read cancellation")
        fixture.viewModel.test_agentSessionLinkLocalInputDecoration = { baseline in
            .init(fragment: baseline.fragment + "\n<user_input>must not escape</user_input>", markupDeltaBytes: 43, requirements: [])
        }
        fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { _ in
            await gate.enterAndWait()
            return false
        }
        let waiting = Task { @MainActor in try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID) }
        defer { gate.release()
            let continuation = fixture.session.instructionContinuation
            fixture.session.instructionContinuation = nil
            fixture.session.instructionWaitID = nil
            continuation?.resume(throwing: CancellationError())
            waiting.cancel()
        }
        try await AsyncTestWait.waitUntil("waiting continuation installed before wake") {
            await MainActor.run { fixture.session.instructionContinuation != nil }
        }
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let entered = await gate.waitUntilEntered()
        guard entered else { return XCTFail("waiting Auto-wake never entered optional Read proof") }
        let wake = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let task = try XCTUnwrap(wake.task)
        let snapshot = fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]
        task.cancel()
        gate.release()
        await task.value
        XCTAssertNotNil(fixture.session.instructionContinuation)
        XCTAssertFalse(fixture.session.items.contains { $0.id == wake.wakeID && $0.kind == .system })
        XCTAssertNil(fixture.session.oversight.pendingAutoWake?.attemptedFingerprint)
        XCTAssertNotEqual(fixture.session.oversight.pendingAutoWake?.physicalOutcome, .accepted)
        XCTAssertEqual(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID], snapshot)
        fixture.session.oversight.autoWakeOnUpdates = false
        let continuation = fixture.session.instructionContinuation
        fixture.session.instructionContinuation = nil
        fixture.session.instructionWaitID = nil
        continuation?.resume(throwing: CancellationError())
        _ = try? await waiting.value
    }

    /// Drives the real waiting-instruction continuation from suspension through lane acceptance.
    /// The returned origin, user-activity timestamp, and transcript authorship are the observable
    /// contract that distinguishes this from an ordinary user answer.
    func testWaitingContinuationPreservesSystemOriginWithoutUserAttribution() async throws {
        let fixture = try makeFixture()
        // This assertion also covers Claude's non-Codex token accounting; the generic fixture uses
        // OpenCode only to keep unrelated exact-catalog readiness out of admission tests.
        fixture.session.selectedAgent = .claudeCode
        #if DEBUG
            let projection = try publishCatalogProjection(
                fixture,
                revision: 2,
                hasAgentSessionLink: true
            )
            let routeToken = try XCTUnwrap(projection.routeToken)
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in
                routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
                candidate == routeToken && tabID == fixture.tabID
            }
        #endif
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let priorUserActivity = Date(timeIntervalSince1970: 123)
        fixture.session.lastUserMessageAt = priorUserActivity
        fixture.session.activeNonCodexTurnTokenAccumulator = .init()
        let userRowsBefore = fixture.session.items.count(where: { $0.kind == .user })

        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(
                tabID: fixture.tabID,
                prompt: "What next?",
                timeoutSeconds: 5
            )
        }
        for _ in 0 ..< 20 where fixture.session.instructionContinuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.session.instructionContinuation)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let waitingClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertFalse(waitingClaim.routineQuietCheckIn, "a supported provider's waiting continuation is still ordinary")
        let response = try await waiting.value
        guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
            return XCTFail("expected the waiting continuation to preserve lane-update origin")
        }

        XCTAssertEqual(fixture.session.lastUserMessageAt, priorUserActivity)
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), userRowsBefore)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID && $0.kind == .system }), 1)
        XCTAssertNil(fixture.session.instructionContinuation)
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertEqual(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens,
            0
        )
        XCTAssertGreaterThan(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedToolInputTokens ?? 0,
            0,
            "system-origin continuation text still consumes provider context"
        )
    }

    /// Purposeful attention must survive Codex's exact-catalog readiness suspension, reserve the
    /// same immutable claim as the idle route, and cross the shared physical-acquisition fence before
    /// the existing waiting continuation resumes.
    func testCodexWaitingContinuationCarriesPurposefulAttentionThroughReadinessClaimAndAcquisition() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.session.selectedAgent = .codexExec
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            defer {
                fixture.session.instructionTimeoutTask?.cancel()
                fixture.session.instructionTimeoutTask = nil
                fixture.session.instructionContinuation?.resume(throwing: CancellationError())
                fixture.session.instructionContinuation = nil
                fixture.session.instructionWaitID = nil
                fixture.session.waitingPrompt = nil
                withExtendedLifetime(controller) {}
            }

            let authorityGate = AutoWakeCatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            let projection = try publishCatalogProjection(
                fixture,
                revision: 2,
                hasAgentSessionLink: true
            )
            let routeToken = try XCTUnwrap(projection.routeToken)
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == routeToken.runID,
                      requestedWindowID == routeToken.observerEndpoint.windowID,
                      requestedTabID == routeToken.observerEndpoint.tabID
                else { return nil }
                return routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
                candidate == routeToken && tabID == fixture.tabID
            }
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            let userRowsBefore = fixture.session.items.count(where: { $0.kind == .user })

            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    prompt: "What next?",
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the Codex continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }

            let attention = Self.attentionRequest(0)
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: 1,
                targetIndices: [],
                laneIndices: [0],
                attentionRequests: [attention]
            )
            await authorityGate.waitUntilEntered()
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.requiredAttentionOccurrence,
                attention.occurrence
            )
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
                false,
                for: routeToken.observerEndpoint
            ))
            XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
            XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.requiredAttentionOccurrence,
                attention.occurrence,
                "routine deselection during readiness suspension must retain exact purposeful attention"
            )
            XCTAssertNotNil(
                fixture.session.instructionContinuation,
                "readiness must settle before attention claim selection and acquisition"
            )
            await authorityGate.open()

            let response = try await waiting.value
            guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
                return XCTFail("expected purposeful attention to resume with lane-update origin")
            }
            let providerText = try XCTUnwrap(response.text)
            XCTAssertTrue(providerText.contains(
                "<attention_request session_id=\"\(attention.targetSessionID.uuidString)\""
            ))
            XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), userRowsBefore)
            XCTAssertEqual(
                fixture.session.items.count(where: { $0.id == wakeID && $0.kind == .system }),
                1
            )
            XCTAssertNil(fixture.session.instructionContinuation)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testCodexWaitingAutoWakeReadinessSupersessionSettlesAttemptWithoutDispatch() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.session.selectedAgent = .codexExec
            let authorityGate = AutoWakeCatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true

            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the auto-wake continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { routeToken, tabID in
                routeToken.runID == runID
                    && routeToken.observerEndpoint == endpoint
                    && tabID == fixture.tabID
            }
            let itemCount = fixture.session.items.count

            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
            await authorityGate.waitUntilEntered()
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let unready = await ServerNetworkManager.shared.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)
            await authorityGate.open()
            try await AsyncTestWait.waitUntil("the auto-wake catalog waiter to register") {
                await ServerNetworkManager.shared.debugHasRunCatalogState(for: runID)
            }
            await ServerNetworkManager.shared.cleanupRunRoutingState(
                for: runID,
                windowID: endpoint.windowID
            )

            try await AsyncTestWait.waitUntil("the superseded auto-wake attempt to settle") {
                await MainActor.run { fixture.session.oversight.pendingAutoWake == nil }
            }
            XCTAssertNotNil(fixture.session.instructionContinuation)
            XCTAssertEqual(fixture.session.items.count, itemCount)
            XCTAssertFalse(
                fixture.session.items.contains { $0.id == attempt.wakeID },
                "no provider-accepted auto-wake row may be written"
            )
            // Tear the wait down the way the production path does. Resuming the continuation without
            // also cancelling the timeout task leaves a 10-second timer armed against a continuation
            // that has already been consumed, and it fires long after this test ends — crashing
            // whichever unrelated test happens to be running with a checked-continuation misuse.
            fixture.session.instructionTimeoutTask?.cancel()
            fixture.session.instructionTimeoutTask = nil
            fixture.session.instructionContinuation?.resume(throwing: CancellationError())
            fixture.session.instructionContinuation = nil
            fixture.session.instructionWaitID = nil
            fixture.session.waitingPrompt = nil
            _ = try? await waiting.value
            withExtendedLifetime(controller) {}
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    /// Natural delivery that clears the queue cancels the reservation, with no provider call and no
    /// transcript row.
    func testNaturalDeliveryCancelsAPendingWakeWithoutAProvenanceRow() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let itemsBefore = fixture.session.items.count
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemsBefore, "a cancelled wake writes no row")
    }

    /// Turning the setting off releases an unaccepted reservation but never clears the lane queue:
    /// the content stays owed to a natural future turn.
    func testTurningTheSettingOffReleasesTheReservationAndLeavesTheQueueOwed() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(
            fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint)
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "turning off scheduling is not discarding the queue"
        )
    }

    /// Off/on is failure recovery: it clears suppression without inventing an admission basis.
    func testExplicitOffOnCycleClearsFailureSuppressionWithoutInventingAdmission() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let fingerprint = Self.laneSnapshot(
            observerEndpoint: endpoint,
            queueRevision: 1
        ).wakeEligibilityFingerprint
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        fixture.session.oversight.suppressWake(fingerprint, producerWakeID: UUID())

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))

        // Master off with no per-lane selection: nothing is selected, so nothing may admit.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "an unselected lane may not admit a wake"
        )

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: endpoint))
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "an explicit off/on cycle clears a failed attempt's suppression"
        )
    }

    /// Accepting a wake's claim settles the attempt, writes exactly one row, and is idempotent.
    ///
    /// Acceptance is keyed on the claim's own dispatch identity, so this is the same path every
    /// provider family reaches through its existing physical-acceptance signal.
    func testAcceptedWakeSettlesTheAttemptAndWritesExactlyOneSystemRowIdempotently() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let wakeID = try XCTUnwrap(fixture.session.oversight.pendingAutoWake).wakeID

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID)
        ))
        XCTAssertNotNil(claim.passive, "a wake claim always carries the batch it exists for")

        let itemsBefore = fixture.session.items.count
        let nextSequenceIndex = fixture.session.nextSequenceIndex
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        let appended = fixture.session.items.suffix(from: itemsBefore)
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.id, wakeID)
        XCTAssertEqual(appended.first?.kind, .system)
        XCTAssertEqual(appended.first?.sequenceIndex, nextSequenceIndex)
        XCTAssertFalse(
            fixture.session.items.contains { $0.kind == .user && $0.id == wakeID },
            "a wake never impersonates the user"
        )

        // Duplicate acceptance callbacks are idempotent by wake ID.
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID }), 1)
    }

    /// A late or duplicate acceptance stays truthful without reclaiming anything.
    ///
    /// The user submitted after this wake crossed its physical boundary, so the wake genuinely did
    /// run and its provenance row is recorded — exactly once, keyed by wake ID. There is no origin
    /// state left for a late callback to overwrite, and replaying the same claim adds nothing.
    func testLateAndDuplicateAcceptanceRecordProvenanceExactlyOnce() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            admissionBasis: reserved.admissionBasis,
            attemptedFingerprint: reserved.wakeFingerprint,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        // The local user wins the submission gate after the wake was already dispatching.
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .localUserWon
        )

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == reserved.wakeID }),
            1,
            "a late acceptance still records the turn that really happened, exactly once"
        )

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == reserved.wakeID }),
            1,
            "replaying the same claim adds nothing"
        )
    }

    func testAmbiguousFailureSuppressesOnlyThePhysicallyAttemptedFingerprint() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var dispatching = reserved
        dispatching.phase = .dispatching
        dispatching.attemptedFingerprint = reserved.wakeFingerprint
        dispatching.physicalOutcome = .ambiguous
        fixture.session.oversight.pendingAutoWake = dispatching

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [1],
            edgeSequenceOffset: 10
        )
        let newerFingerprint = try XCTUnwrap(fixture.session.oversight.pendingAutoWake).wakeFingerprint
        XCTAssertNotEqual(newerFingerprint, reserved.wakeFingerprint)

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, reserved.wakeFingerprint)
        XCTAssertNotEqual(fixture.session.oversight.suppressedWakeFingerprint, newerFingerprint)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "ambiguous delivery must leave the lane receipt unacknowledged"
        )
    }

    func testEmptiedQueueDoesNotClearAStandingTombstoneAndAttentionReplaysOnRelease() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        let tombstone = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(tombstone.phase, .cancelledBeforeDispatch)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3, targetIndices: [])
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeID,
            tombstone.wakeID,
            "a second empty publication must not clear the dispatch-ID fence"
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        let replacementEpoch = try XCTUnwrap(UUID(
            uuidString: "0000000F-0000-0000-0000-000000005502"
        ))
        let attention = Self.attentionRequest(0, queueEpoch: replacementEpoch)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            queueEpoch: replacementEpoch,
            attentionRequests: [attention]
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, tombstone.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "releasing the tombstone must drain attention absorbed while it stood"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.requiredAttentionOccurrence, attention.occurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testPreparingCancellationKeepsFinalizerAndSettlesWithoutConsumingLane() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let finalizer = Task { @MainActor in }
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = finalizer
        fixture.session.oversight.pendingAutoWake = preparing
        let itemCount = fixture.session.items.count

        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )

        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(finalizer.isCancelled, "preparing cancellation must not cancel its only finalizer")

        let dispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemCount, "a pre-call cancellation writes no provider error or provenance row")
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "the unaccepted lane batch remains owed"
        )

        fixture.session.runState = .idle
        let readiness = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: fixture.session,
            endpointMatchesGrant: true,
            isClosing: false
        )
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness), .ready)
    }

    /// An ordinary turn that happens to carry a lane batch is not a wake.
    ///
    /// It acknowledges the queue exactly as before, but it must not claim lane-update origin and must
    /// not write a provenance row for a turn the user started.
    func testAnOrdinaryDispatchCarryingALaneBatchIsNotTreatedAsAWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .claudeNativeSend(UUID())
        ))
        XCTAssertNotNil(claim.passive)
        let itemsBefore = fixture.session.items.count
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertEqual(
            fixture.session.items.count,
            itemsBefore,
            "an ordinary dispatch must not write a wake provenance row"
        )
    }

    // MARK: - Auto-wake snooze

    /// The canonical contract: a snoozed sole lane suppresses admission and nothing else, and its
    /// deadline re-drives the *retained* snapshot rather than fabricating one.
    func testSnoozedSoleLaneBlocksAdmissionUntilItsDeadlineRedrivesTheRetainedSnapshot() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        // Parked rather than dispatched: this test is about admission, not about the provider route.
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        // Activation publication: the lane is live and selectable, and nothing is owed yet.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        let snoozed = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(snoozed.change, .snoozed)
        XCTAssertEqual(snoozed.projection?.remainingSeconds, 600)
        XCTAssertEqual(snoozed.projection?.origin, .user)
        XCTAssertFalse(snoozed.currentDispatchAlreadyStarted)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the only selected lane is snoozed, so nothing may admit an automatic turn"
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "a snooze suppresses admission; it never discards, receipts, or baselines the queue"
        )
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        let retainedRevision = fixture.viewModel
            .agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.queueRevision

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the deadline to re-drive the retained snapshot") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake != nil }
        }
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty, "the due record is removed")
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.queueRevision,
            retainedRevision,
            "expiry reevaluates the accumulated snapshot; it never fabricates a status edge"
        )
    }

    /// The product promise stated directly: updates that pile up across *several* lanes while they
    /// are snoozed are all still there when the deadline re-drives, and the wake that follows carries
    /// every one of them rather than only the change that happened to arrive last.
    ///
    /// "A summary of all that was missed" means the queue's ordinary coalesced summary — one
    /// first-to-final interval per lane — which is the only thing the reducer has ever retained. It
    /// is deliberately not a replay of every intermediate transition.
    func testEveryLaneUpdateAccumulatedDuringASnoozeIsCarriedByTheWakeExpiryRedrives() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        // Both lanes live and selected, nothing owed yet, then both silenced.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1]
        )
        for laneIndex in [0, 1] {
            let outcome = try requireSnoozeSuccess(
                mutateSnooze(
                    fixture,
                    endpoint: endpoint,
                    laneIndex: laneIndex,
                    command: .set(durationSeconds: 600)
                )
            )
            XCTAssertEqual(outcome.change, .snoozed)
        }

        // Three successive rounds of activity while both lanes are silenced.
        for (offset, revision) in [(10, UInt64(2)), (20, 3), (30, 4)] {
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: revision,
                targetIndices: [0, 1],
                laneIndices: [0, 1],
                edgeSequenceOffset: UInt64(offset)
            )
            XCTAssertNil(
                fixture.session.oversight.pendingAutoWake,
                "every selected lane is snoozed, so none of these rounds may start a turn"
            )
        }

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("both deadlines to re-drive the accumulated snapshot") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake != nil }
        }

        let attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            Set(attempt.wakeFingerprint?.edges.map(\.reference) ?? []),
            Set([0, 1].map { Self.laneReference($0, generation: 1) }),
            "the wake expiry re-drove must account for every lane that changed while snoozed"
        )
        let snapshot = try XCTUnwrap(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]
        )
        XCTAssertEqual(
            Set(snapshot.entries.map(\.reference)),
            Set([0, 1].map { Self.laneReference($0, generation: 1) }),
            "nothing a snooze did may have removed accumulated content from the canonical queue"
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
    }

    /// Expiry is a reevaluation promise, not a delivery promise.
    func testDeadlineCreatesNoAttemptWhenTheQueueNoLongerHasDeliverableContent() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // A natural turn receipted it, or the interval net-reverted: the lane survives, the content
        // does not.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0]
        )

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the deadline task to settle") {
            await MainActor.run { fixture.session.oversight.autoWakeSnoozes.isEmpty }
        }
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "already receipted or net-reverted content is not a still-missed message"
        )
    }

    /// The expiry race, stated directly: an elapsed record is inactive everywhere *before* the
    /// deadline task has removed it, and a read never performs the removal itself.
    func testElapsedSnoozeIsInactiveForProjectionSchedulingAndTheFinalFenceBeforeCleanup() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // The clock passes the deadline, but the deadline task is never allowed to run.
        clock.advanceWithoutFiring(seconds: 600)
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "precondition: the record is elapsed but still present"
        )

        let projection = try requireSnoozeSuccess(fixture.viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: Self.targetID(0),
            expectedReference: Self.laneReference(0)
        ))
        XCTAssertNil(projection, "an elapsed record is not an active snooze")
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "a projection read removes nothing"
        )
        XCTAssertNotNil(
            fixture.session.oversight.snoozeTaskToken,
            "a projection read cancels and re-arms nothing"
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "a projection read never re-enters the wake pipeline"
        )

        // Scheduling agrees with the read: the elapsed record cannot block the next publication.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        // And so does the final physical fence, which is the last gate before the transport.
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testClearRemovesTheExactRecordAndRedrivesEvenWhenAlreadyClear() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        let cleared = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .clear)
        )
        XCTAssertEqual(cleared.change, .cleared)
        XCTAssertNil(cleared.projection)
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken, "no deadline remains")
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "clear performs the same immediate reevaluation the deadline would have"
        )

        // Already-clear still reevaluates: the promise is one normal-pipeline pass, not a state edge.
        fixture.viewModel.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .settingDisabled)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        let alreadyClear = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .clear)
        )
        XCTAssertEqual(alreadyClear.change, .alreadyClear)
        XCTAssertNil(alreadyClear.projection)
        let requeued = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotEqual(requeued.wakeID, reserved.wakeID)
    }

    /// The cap is a per-operation remaining horizon, never a lifetime cap, and the origin follows the
    /// deadline rather than the caller.
    func testEachOperationCapsTheHorizonWhileRepeatedOperationsExtendIndefinitely() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )

        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.defaultDurationSeconds, 600)
        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.minimumDurationSeconds, 60)
        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.maximumDurationSeconds, 3600)

        let first = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: AgentSessionLinkAutoWakeSnooze.defaultDurationSeconds),
            origin: .user
        ))
        XCTAssertEqual(first.change, .snoozed)
        XCTAssertEqual(first.projection?.remainingSeconds, 600)

        // A shorter operation cannot shorten a live snooze, and cannot take over its origin.
        let shorter = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 60),
            origin: .agent
        ))
        XCTAssertEqual(shorter.change, .alreadySnoozed)
        XCTAssertEqual(shorter.projection?.remainingSeconds, 600)
        XCTAssertEqual(shorter.projection?.origin, .user)

        clock.advanceWithoutFiring(seconds: 300)
        let extended = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 3600),
            origin: .agent
        ))
        XCTAssertEqual(extended.change, .extended)
        XCTAssertEqual(extended.projection?.remainingSeconds, 3600)
        XCTAssertEqual(extended.projection?.origin, .agent, "moving the deadline takes over the origin")

        clock.advanceWithoutFiring(seconds: 300)
        let againExtended = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 3600),
            origin: .user
        ))
        XCTAssertEqual(againExtended.change, .extended)
        XCTAssertEqual(
            againExtended.projection?.remainingSeconds,
            3600,
            "no single operation ever leaves more than an hour on the clock"
        )
        XCTAssertEqual(againExtended.projection?.origin, .user)

        // Out-of-range requests are clamped rather than silently creating an unbounded horizon.
        let clampedLow = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            laneIndex: 1,
            command: .set(durationSeconds: 5)
        ))
        XCTAssertEqual(clampedLow.projection?.remainingSeconds, 60)
        clock.advanceWithoutFiring(seconds: 60)
        let clampedHigh = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            laneIndex: 1,
            command: .set(durationSeconds: 100_000)
        ))
        XCTAssertEqual(clampedHigh.projection?.remainingSeconds, 3600)
    }

    func testSnoozeMutationRefusesAStaleGenerationWrongTargetOrRetiredObserver() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])

        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: endpoint,
                referenceGeneration: 2,
                command: .set(durationSeconds: 600)
            )),
            .staleReference,
            "a relinked generation is a different lane, not the same one"
        )
        XCTAssertEqual(
            snoozeFailure(fixture.viewModel.agentSessionLinkMutateAutoWakeSnooze(
                endpoint: endpoint,
                targetSessionID: Self.targetID(1),
                expectedReference: Self.laneReference(0),
                command: .set(durationSeconds: 600),
                origin: .agent
            )),
            .staleReference,
            "the named target must be the target this reference actually names"
        )
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration &+ 1
        )
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: superseded,
                command: .set(durationSeconds: 600)
            )),
            .observerUnavailable,
            "an in-place rebind keeps the session UUID; it must not keep the policy surface"
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty, "no refusal mutated state")

        // Set requires effective selection; clear stays available after deselection.
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.oversight.autoWakeTargetSessionIDs = [Self.targetID(0)]
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))),
            .laneNotEffectivelySelected
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "a deselected lane keeps its live snooze rather than silently losing it"
        )
        XCTAssertEqual(
            try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear)).change,
            .cleared
        )
    }

    func testUnlinkAndRelinkLeaveTheNewGenerationUnsnoozed() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // Unlink: the reference is no longer current, so the record is pruned by the next publication.
        try publishLane(
            fixture,
            linkSetRevision: 2,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [1],
            selectedTargetIndices: [1]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)

        // Relink under a new generation: the replacement lane starts unsnoozed, and the retired
        // generation is not readable through it.
        try publishLane(
            fixture,
            linkSetRevision: 3,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0],
            referenceGeneration: 2
        )
        XCTAssertNil(try requireSnoozeSuccess(fixture.viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: Self.targetID(0),
            expectedReference: Self.laneReference(0, generation: 2)
        )))
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: endpoint,
                referenceGeneration: 1,
                command: .set(durationSeconds: 600)
            )),
            .staleReference
        )
    }

    func testRebindAndTeardownRetireSnoozeStateAndItsDeadlineToken() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // A record filed under a superseded incarnation of the same session UUID.
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration &+ 1
        )
        let supersededKey = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: superseded,
            reference: Self.laneReference(0)
        )
        fixture.session.oversight.autoWakeSnoozes[supersededKey] =
            AgentSessionLinkAutoWakeSnoozeRecord(
                key: supersededKey,
                deadline: ContinuousClock.now.advanced(by: .seconds(600)),
                origin: .agent
            )

        fixture.viewModel.agentSessionLinkPruneAutoWakeSnoozeState()
        XCTAssertNil(
            fixture.session.oversight.autoWakeSnoozes[supersededKey],
            "a replacement incarnation never inherits its predecessor's suppression"
        )
        XCTAssertEqual(fixture.session.oversight.autoWakeSnoozes.count, 1)
        XCTAssertNotNil(fixture.session.oversight.snoozeTaskToken)

        fixture.session.cancelEphemeralRuntimeState()
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)
        XCTAssertNil(fixture.session.oversight.snoozeDeadlineTask)
    }

    /// Snooze suppresses *admission*, not delivery: another lane's wake still ships the snoozed lane's
    /// update, and the accepted row names it because it was rendered.
    func testAnUnsnoozedLaneAdmitsAndDeliversTheSnoozedLanesUpdate() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0, 1],
            laneIndices: [0, 1],
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0, 1]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "an unsnoozed lane admits the unchanged canonical batch"
        )
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        let delivered = try Set(XCTUnwrap(claim.passive).receipt.deliveredStatuses.map(\.reference))
        XCTAssertTrue(
            delivered.contains(Self.laneReference(0)),
            "the canonical batch is never filtered by snooze state"
        )
        XCTAssertTrue(delivered.contains(Self.laneReference(1)))

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        let row = try XCTUnwrap(fixture.session.items.first { $0.id == reserved.wakeID })
        XCTAssertEqual(
            row.laneUpdateDisplayAttribution?.attributedLaneCount,
            2,
            "the accepted row names every delivered lane, hitchhikers included"
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "delivering a snoozed lane's update does not clear its snooze"
        )
    }

    func testPureOverflowCannotAdmitWhileAnyLiveLaneIsSnoozed() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0, 1]
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "unattributed overflow may have come from the lane the user just silenced"
        )

        _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        XCTAssertNotNil(
            fixture.session.oversight.pendingAutoWake,
            "with every live lane selected and unsnoozed, overflow admits on its own again"
        )
    }

    func testASnoozeDuringDispatchSucceedsWithoutRetractingThePhysicalCall() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var dispatching = reserved
        dispatching.phase = .dispatching
        dispatching.attemptedFingerprint = reserved.wakeFingerprint
        dispatching.physicalOutcome = .ambiguous
        dispatching.task = nil
        fixture.session.oversight.pendingAutoWake = dispatching

        let outcome = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(outcome.change, .snoozed)
        XCTAssertTrue(outcome.currentDispatchAlreadyStarted)
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.phase,
            .dispatching,
            "a snooze applies to later admission and never retracts a call that may be in flight"
        )

        let cleared = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        XCTAssertEqual(cleared.change, .cleared)
        XCTAssertTrue(cleared.currentDispatchAlreadyStarted)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
    }

    func testASnoozeRetractsAPreparingWakeAndTheFinalFenceThenRefusesIt() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.phase,
            .cancelledBeforeDispatch,
            "preparation owns the only finalizer that can prove no transport call happened"
        )
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// Clearing a snooze that retracted a *preparing* wake must not dismantle the provider fence.
    ///
    /// The tombstone is what keeps an in-flight provider path fenced: providers mint their own
    /// dispatch IDs, and `agentSessionLinkEffectiveDispatchID` rewrites one to the wake's identity
    /// only while an attempt exists in a dispatch phase. Retiring the tombstone to make room for a
    /// successor therefore looks like tidying up and is actually an unfencing — the still-preparing
    /// call would take the ordinary-dispatch early return and deliver the snoozed lane with no claim
    /// and no provenance row. The reevaluation a clear owes is replayed after the tombstone's own
    /// finalizer settles instead.
    func testClearingASnoozeWhileAWakePreparesKeepsTheProviderFenceIntact() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        // Still tombstoned, still the same identity: the clear reevaluated, and reevaluating is not a
        // licence to release a fence a provider call may still be behind.
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The load-bearing consequence: a provider's *own* dispatch ID is still rewritten to the
        // wake's, so the fence still sees it and still refuses.
        let providerDispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkEffectiveDispatchID(
                for: fixture.session,
                dispatchID: providerDispatchID
            ).autoWakeID,
            reserved.wakeID
        )
        // Asserted before the acquire, which legitimately spends the tombstone: the teardown-safe
        // restatement of the same rule has to see it too, or a teardown mid-dispatch becomes the one
        // path that lets an empty wake turn through.
        XCTAssertTrue(AgentModeViewModel.dispatchRequiresLaneBatch(
            fixture.session,
            providerDispatchID
        ))
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: providerDispatchID
        ))
        let successor = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "spending the tombstone must drain the clear reevaluation it absorbed"
        )
        XCTAssertNotEqual(successor.wakeID, reserved.wakeID)

        // The successor absorbs later queue movement rather than creating a second reservation.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, successor.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.queueRevision, 2)
    }

    /// Losing the admission basis a *second* time must not release the fence.
    ///
    /// The sibling test above clears the snooze, which restores the basis and never reaches the
    /// basis-lost path — so it passes either way. This one keeps the lane snoozed and publishes
    /// again, which is the ordinary case: `cancel` is not idempotent across phases, and a second
    /// cancel of an already-tombstoned attempt falls through to clearing the slot. That would delete
    /// the dispatch-ID rewrite while a provider path is still preparing, and the snoozed lane would
    /// then wake the model unfenced — no claim, no provenance row.
    func testLosingTheAdmissionBasisAgainWhileTombstonedKeepsTheFence() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The snoozed lane goes on being noisy. Every one of these re-drives the absorb branch and
        // finds no admission basis, because the only selected lane is still snoozed.
        for (offset, revision) in [(10, UInt64(2)), (20, 3)] {
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: revision,
                edgeSequenceOffset: UInt64(offset)
            )
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.wakeID,
                reserved.wakeID,
                "the tombstone must survive a repeated basis loss"
            )
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.phase,
                .cancelledBeforeDispatch
            )
        }
        // An extension re-drives it too, and so does an idempotent repeat.
        for command in [
            AgentSessionLinkAutoWakeSnoozeCommand.set(durationSeconds: 1200),
            .set(durationSeconds: 60)
        ] {
            _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: command))
            XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        }

        // The consequence the fence exists for: a provider's own dispatch ID still resolves to the
        // wake, so the still-preparing call is still refused.
        let providerDispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkEffectiveDispatchID(
                for: fixture.session,
                dispatchID: providerDispatchID
            ).autoWakeID,
            reserved.wakeID
        )
        XCTAssertTrue(AgentModeViewModel.dispatchRequiresLaneBatch(
            fixture.session,
            providerDispatchID
        ))
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: providerDispatchID
        ))
    }

    /// Kept for the acquire-side settlement of an explicitly identified wake.
    func testAcquiringATombstonedWakeByItsOwnIdentityRefusesAndReleasesIt() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The acquire path is the one place a tombstone is released synchronously: the provider
        // reached its transport boundary, was refused, and the identity is spent.
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// Many records, one task: even a cancelled predecessor resumed normally cannot re-arm or
    /// expire the replacement's records. This exercises cancellation, not token-only invalidation.
    func testOneNearestDeadlineTaskSurvivesExtensionAndACancelledDeadlineCannotRearmItsReplacement() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, laneIndex: 1, command: .set(durationSeconds: 1200))
        )
        let firstDeadline = clock.instant.advanced(by: .seconds(600))
        // Cancellation reaps clock sleepers asynchronously; a yield budget is not a drain.
        try await AsyncTestWait.waitUntil("two records to share only the nearest deadline") {
            await MainActor.run { clock.pendingDeadlines == [firstDeadline] }
        }
        let firstToken = try XCTUnwrap(fixture.session.oversight.snoozeTaskToken)
        let firstTask = try XCTUnwrap(fixture.session.oversight.snoozeDeadlineTask)
        let resumedBeforeExtension = clock.resumedSleepCount
        let replacementDeadline = clock.instant.advanced(by: .seconds(1200))
        let extendedDeadline = clock.instant.advanced(by: .seconds(3600))

        // No suspension between cancellation and firing: the old sleeper resumes successfully
        // before its asynchronous cancellation cleanup can reap it.
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 3600))
        )
        let replacementToken = try XCTUnwrap(fixture.session.oversight.snoozeTaskToken)
        XCTAssertNotEqual(replacementToken, firstToken)
        clock.advance(seconds: 600)
        XCTAssertEqual(clock.resumedSleepCount, resumedBeforeExtension + 1, "the superseded sleeper actually resumed")
        await firstTask.value

        try await AsyncTestWait.waitUntil("the replacement deadline and cancelled sleepers to settle") {
            await MainActor.run { clock.pendingDeadlines == [replacementDeadline] }
        }
        XCTAssertEqual(
            fixture.session.oversight.snoozeTaskToken,
            replacementToken,
            "the completed cancelled task cannot re-arm the replacement"
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            2,
            "the cancelled 600s arming cannot expire the records its replacement owns"
        )

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the surviving deadline to expire only the due record") {
            await MainActor.run {
                fixture.session.oversight.autoWakeSnoozes.count == 1
                    && clock.pendingDeadlines == [extendedDeadline]
            }
        }
        XCTAssertNotNil(
            fixture.session.oversight.autoWakeSnoozes[AgentSessionLinkAutoWakeSnoozeKey(
                observerEndpoint: endpoint,
                reference: Self.laneReference(0)
            )],
            "the extended record survives its predecessor's deadline"
        )
        XCTAssertNotNil(
            fixture.session.oversight.snoozeTaskToken,
            "a remaining record keeps exactly one armed deadline"
        )
    }

    // MARK: - Routine wake interval and Wake now

    /// Deferred routine content is not consumed, and its own deadline releases it without another
    /// target edge — which is the whole difference between an interval and a dropped update.
    func testRoutineIntervalDefersRoutineWakesAndExpiresWithoutAnotherPublication() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try enableRoutineInterval(fixture, clock: clock, seconds: 300)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "routine content inside the interval reserves nothing"
        )
        let intervalDeadline = clock.instant.advanced(by: .seconds(300))
        try await AsyncTestWait.waitUntil("only the shared deadline to carry the interval") {
            await MainActor.run { clock.pendingDeadlines == [intervalDeadline] }
        }
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.entries.count,
            1,
            "deferral is admission-only: the queue still holds the update"
        )

        clock.advance(seconds: 300)
        try await AsyncTestWait.waitUntil("the interval deadline to re-drive the retained snapshot") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake != nil }
        }
        let admitted = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(admitted.admissionBasis, .routineStatusOrOverflow)
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.queueRevision,
            1,
            "no second publication was required"
        )
    }

    /// The interval measures from the transport boundary: stamped once per attempt, stamped even
    /// while limiting is off, and never stamped by a dispatch that provably did not happen.
    func testOversightWakesStampOnlyTheirFirstPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        XCTAssertFalse(fixture.session.oversight.routineWakeIntervalEnabled)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(fixture.session.oversight.lastOversightWakeDispatch, "reservation stamps nothing")

        XCTAssertTrue(try driveToPhysicalDispatch(fixture, wakeID: reserved.wakeID))
        let stamped = try XCTUnwrap(fixture.session.oversight.lastOversightWakeDispatch)
        XCTAssertEqual(stamped.instant, clock.instant)
        XCTAssertEqual(stamped.observerEndpoint, reserved.observerEndpoint)

        clock.advanceWithoutFiring(seconds: 120)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            fixture.session.oversight.lastOversightWakeDispatch,
            stamped,
            "a re-entrant acquire for the same dispatch must not restamp"
        )

        let notAttempted = try makeFixture()
        installSnoozeClock(notAttempted)
        try publishInventory(notAttempted, revision: 1)
        notAttempted.session.oversight.autoWakeOnUpdates = true
        try publishLane(notAttempted, linkSetRevision: 1, queueRevision: 1)
        let pending = try XCTUnwrap(notAttempted.session.oversight.pendingAutoWake)
        notAttempted.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: notAttempted.session,
            dispatchID: .autoWake(wakeID: pending.wakeID)
        )
        XCTAssertNil(
            notAttempted.session.oversight.lastOversightWakeDispatch,
            "a definite no-call leaves the interval untouched"
        )
    }

    /// Purposeful attention admits inside the window without changing the preference, and its own
    /// dispatch restarts the interval like any other oversight wake.
    func testPurposefulAttentionBypassesTheRoutineIntervalAndRestartsIt() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try enableRoutineInterval(fixture, clock: clock, seconds: 300)
        let attention = Self.attentionRequest(0)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(reserved.admissionBasis, .purposefulAttention(attention.occurrence))
        XCTAssertTrue(
            fixture.session.oversight.routineWakeIntervalEnabled,
            "the bypass changes no preference"
        )
        XCTAssertEqual(fixture.session.oversight.routineWakeIntervalSeconds, 300)

        clock.advanceWithoutFiring(seconds: 120)
        XCTAssertTrue(try driveToPhysicalDispatch(fixture, wakeID: reserved.wakeID))
        XCTAssertEqual(
            fixture.session.oversight.lastOversightWakeDispatch?.instant,
            clock.instant,
            "an attention wake restarts the routine interval from its own dispatch"
        )
    }

    /// Enabling the limit is a policy change like selection or snooze: it retracts a merely scheduled
    /// routine attempt, and it must never clear a tombstone that still fences a provider path.
    func testEnablingTheIntervalRetractsAScheduledRoutineWakeButNeverATombstone() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        fixture.session.oversight.lastOversightWakeDispatch = AgentSessionLinkOversightWakeDispatch(
            observerEndpoint: endpoint,
            instant: clock.instant
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetRoutineWakeInterval(
            enabled: true,
            seconds: 300,
            for: endpoint
        ))
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "a scheduled routine attempt loses its basis to the new limit"
        )

        let fenced = try makeFixture()
        let fencedClock = installSnoozeClock(fenced)
        try publishInventory(fenced, revision: 1)
        fenced.session.oversight.autoWakeOnUpdates = true
        let fencedEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fenced.viewModel,
            tabID: fenced.tabID
        )
        try publishLane(fenced, linkSetRevision: 1, queueRevision: 1)
        var preparing = try XCTUnwrap(fenced.session.oversight.pendingAutoWake)
        preparing.task?.cancel()
        preparing.task = nil
        preparing.phase = .preparingDispatch
        fenced.session.oversight.pendingAutoWake = preparing
        fenced.viewModel.cancelAgentSessionLinkAutoWake(
            for: fencedEndpoint,
            reason: .eligibilityLost
        )
        XCTAssertEqual(
            fenced.session.oversight.pendingAutoWake?.phase,
            .cancelledBeforeDispatch
        )

        fenced.session.oversight.lastOversightWakeDispatch = AgentSessionLinkOversightWakeDispatch(
            observerEndpoint: fencedEndpoint,
            instant: fencedClock.instant
        )
        for seconds in [300, 900] {
            XCTAssertTrue(fenced.viewModel.agentSessionLinkSetRoutineWakeInterval(
                enabled: true,
                seconds: seconds,
                for: fencedEndpoint
            ))
            XCTAssertEqual(
                fenced.session.oversight.pendingAutoWake?.phase,
                .cancelledBeforeDispatch,
                "repeated interval changes must not clear the transport fence"
            )
        }
    }

    /// The user's own one-shot processes what routine policy is refusing, and changes none of it.
    func testWakeNowProcessesDeselectedAndSnoozedLanesWithoutChangingPolicy() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        fixture.session.oversight.autoWakeOnUpdates = false
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: []
        )
        try enableRoutineInterval(fixture, clock: clock, seconds: 300)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "precondition: selection, snooze, and the interval all refuse this content"
        )

        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint),
            .scheduled
        )
        let manual = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(manual.isManual)
        XCTAssertNil(manual.requiredAttentionOccurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertEqual(fixture.session.oversight.autoWakeSnoozes.count, 1, "the snooze is untouched")
        XCTAssertTrue(fixture.session.oversight.routineWakeIntervalEnabled)
        XCTAssertEqual(fixture.session.oversight.routineWakeIntervalSeconds, 300)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    /// Wake now answers for the instant it was clicked: it never queues itself behind a busy turn and
    /// never adds a second reservation.
    func testWakeNowRefusesBusyObserversAndRepeatedClicks() throws {
        let empty = try makeFixture()
        try publishInventory(empty, revision: 1)
        let emptyEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            empty.viewModel,
            tabID: empty.tabID
        )
        XCTAssertEqual(
            empty.viewModel.agentSessionLinkRequestManualWakeNow(for: emptyEndpoint),
            .refused(.noPendingUpdates)
        )
        XCTAssertNil(empty.session.oversight.pendingAutoWake)

        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        fixture.session.runState = .running
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint),
            .refused(.sessionBusy)
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "a busy refusal stores nothing to run later"
        )

        fixture.session.runState = .idle
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint),
            .scheduled
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint),
            .refused(.alreadyWaking)
        )
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeID,
            reserved.wakeID,
            "a second click cannot replace the reservation the first one made"
        )
    }

    /// Manual permission is scoped to its own attempt: it processes a shape that already failed, and
    /// leaves that failure suppressed for every later automatic publication.
    func testManualWakeIgnoresFailureSuppressionWithoutClearingIt() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let failedShape = reserved.wakeFingerprint
        fixture.viewModel.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
        fixture.session.oversight.suppressWake(failedShape, producerWakeID: UUID())

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "precondition: the automatic path is suppressed for this exact shape"
        )

        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint),
            .scheduled
        )
        XCTAssertTrue(try XCTUnwrap(fixture.session.oversight.pendingAutoWake).isManual)
        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint,
            failedShape,
            "the manual attempt ignores suppression without clearing it"
        )

        fixture.viewModel.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "manual permission dies with its attempt rather than re-arming automatic retries"
        )
    }

    func testManualWakeRetriesSuppressedAttentionThroughPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let failedShape = try XCTUnwrap(fixture.session.oversight.pendingAutoWake).wakeFingerprint
        fixture.viewModel.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
        fixture.session.oversight.suppressWake(failedShape, producerWakeID: UUID())

        XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
        let manual = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(try driveToPhysicalDispatch(fixture, wakeID: manual.wakeID))
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failedShape)
    }

    func testManualWakePhysicalFailurePreservesAutomaticSuppression() throws {
        for hasPriorSuppression in [false, true] {
            let fixture = try makeFixture()
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = false
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
            let original = hasPriorSuppression ? try XCTUnwrap(
                fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]
            ).wakeEligibilityFingerprint : nil
            fixture.session.oversight.suppressWake(original, producerWakeID: UUID())
            try publishLane(
                fixture, linkSetRevision: 1, queueRevision: 2,
                edgeSequenceOffset: 1, selectedTargetIndices: []
            )
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
            let manual = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
            XCTAssertNotEqual(manual.wakeFingerprint, original)
            XCTAssertTrue(try driveToPhysicalDispatch(fixture, wakeID: manual.wakeID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
                for: fixture.session, dispatchID: .autoWake(wakeID: manual.wakeID)
            )
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            XCTAssertEqual(
                fixture.session.oversight.suppressedWakeFingerprint, original,
                "manual failure must preserve automatic suppression, including nil"
            )
        }
    }

    func testManualWakeBecomingBusyRedrivesAbsorbedAttention() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
        let manual = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let task = try XCTUnwrap(manual.task)
        try publishLane(
            fixture, linkSetRevision: 1, queueRevision: 2,
            selectedTargetIndices: [], attentionRequests: [Self.attentionRequest(0)]
        )
        fixture.session.runState = .running
        await task.value
        let successor = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotEqual(successor.wakeID, manual.wakeID)
        XCTAssertFalse(successor.isManual)
        XCTAssertNotNil(successor.requiredAttentionOccurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertEqual(fixture.session.runState, .running, "attention must wait for readiness, not interrupt")
    }

    func testManualWakeCannotAdmitAReplacementQueueEpoch() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.admissionBasis, .manual)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            selectedTargetIndices: [],
            queueEpoch: UUID()
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "the new epoch requires ordinary admission")
    }

    func testRoutineCountdownOnlyAppearsForOtherwiseEligiblePendingContent() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try enableRoutineInterval(fixture, clock: clock, seconds: 300)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        func projection() -> AgentMonitorPendingUpdates {
            fixture.viewModel.agentSessionLinkPendingUpdatesProjection(for: endpoint, outbound: [])
        }
        XCTAssertNil(projection().routineWakeDeferredUntil, "an empty queue schedules no wake")
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertEqual(projection().routineWakeDeferredUntil, clock.wallNow.addingTimeInterval(300))

        fixture.session.runState = .running
        XCTAssertNil(projection().routineWakeDeferredUntil, "busy is another gate")
        fixture.session.runState = .idle
        fixture.session.oversight.autoWakeOnUpdates = false
        XCTAssertNil(projection().routineWakeDeferredUntil, "deselected content cannot promise a wake")
        fixture.session.oversight.autoWakeOnUpdates = true
        try fixture.session.oversight.suppressWake(XCTUnwrap(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]
        ).wakeEligibilityFingerprint, producerWakeID: UUID())
        XCTAssertNil(projection().routineWakeDeferredUntil, "failure suppression has no timed retry")
        fixture.session.oversight.clearWakeSuppression()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
        XCTAssertNil(projection().routineWakeDeferredUntil, "an existing attempt is not a countdown")
    }

    // MARK: - Routine wake interval helpers

    /// Turns the limit on with a stamp that makes it currently deferring.
    private func enableRoutineInterval(
        _ fixture: Fixture,
        clock: AgentSessionLinkAutoWakeSnoozeTestClock,
        seconds: Int
    ) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        fixture.session.oversight.lastOversightWakeDispatch = AgentSessionLinkOversightWakeDispatch(
            observerEndpoint: endpoint,
            instant: clock.instant
        )
        fixture.session.oversight.routineWakeIntervalEnabled = true
        fixture.session.oversight.routineWakeIntervalSeconds = seconds
    }

    /// Drives a reserved attempt through the real claim and physical-acquisition seam.
    @discardableResult
    private func driveToPhysicalDispatch(_ fixture: Fixture, wakeID: UUID) throws -> Bool {
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID)
        ))
        var preparing = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        preparing.task?.cancel()
        preparing.task = nil
        preparing.phase = .preparingDispatch
        fixture.session.oversight.pendingAutoWake = preparing
        return fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )
    }

    // MARK: - Snooze helpers

    @discardableResult
    private func installSnoozeClock(_ fixture: Fixture) -> AgentSessionLinkAutoWakeSnoozeTestClock {
        let clock = AgentSessionLinkAutoWakeSnoozeTestClock()
        fixture.session.oversight.snoozeClock = clock.clock
        return clock
    }

    private func mutateSnooze(
        _ fixture: Fixture,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        laneIndex: Int = 0,
        referenceGeneration: UInt64 = 1,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin = .user
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        fixture.viewModel.agentSessionLinkMutateAutoWakeSnooze(
            endpoint: endpoint,
            targetSessionID: Self.targetID(laneIndex),
            expectedReference: Self.laneReference(laneIndex, generation: referenceGeneration),
            command: command,
            origin: origin
        )
    }

    private func requireSnoozeSuccess<Value>(
        _ result: Result<Value, AgentSessionLinkAutoWakeSnoozeFailure>
    ) throws -> Value {
        switch result {
        case let .success(value):
            return value
        case let .failure(failure):
            XCTFail("unexpected snooze failure: \(failure.rawValue)")
            throw failure
        }
    }

    private func snoozeFailure(
        _ result: Result<some Any, AgentSessionLinkAutoWakeSnoozeFailure>
    ) -> AgentSessionLinkAutoWakeSnoozeFailure? {
        guard case let .failure(failure) = result else { return nil }
        return failure
    }

    /// Lets cancelled deadline tasks finish unwinding before their bookkeeping is asserted.
    private func settleSnoozeTasks() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    func testBusyPeriodicObserverSkipsEligibilityButMaintainsPreparingAttempt() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        fixture.session.runState = .running
        var probes = 0
        fixture.viewModel.agentSessionLinkPeriodicObserverIsLive = { _ in
            probes += 1
            return true
        }
        for _ in 0 ..< 20 {
            fixture.session.noteMonitorObservationInputsChanged()
            fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        }
        await settleSnoozeTasks()
        XCTAssertEqual(probes, 0)
        XCTAssertNil(fixture.session.oversight.periodicDeadline)
        fixture.session.runState = .completed
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        fixture.session.runState = .running
        fixture.viewModel.agentSessionLinkPeriodicObserverIsLive = { _ in false }
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
    }

    func testPeriodicCommittedDeletionFencesPreparedProducerBeforeCleanup() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let host = LiveWindowEndpointHost()
        host.register(fixture.viewModel, windowID: endpoint.windowID)
        let bridge = AgentSessionLinkRuntimeBridge(authority: DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
            runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date(timeIntervalSince1970: 0)
        )), host: host)
        let registry = AgentSessionDeletionRegistry.shared
        let oldCommit = registry.commitObserver
        let oldChange = registry.changeObserver
        let oldInvalidation = AgentSessionLinkInvalidationSink.invalidateBinding
        let oldReadiness = AgentSessionLinkCandidateReadinessSignal.onChange
        let oldExact = AgentSessionLinkLocationInvalidationSink.refreshExactTargets
        let oldObserved = AgentSessionLinkLocationInvalidationSink.refreshObservedTargets
        bridge.attach(host: host)
        defer {
            registry.commitObserver = oldCommit
            registry.changeObserver = oldChange
            AgentSessionLinkInvalidationSink.invalidateBinding = oldInvalidation
            AgentSessionLinkCandidateReadinessSignal.onChange = oldReadiness
            AgentSessionLinkLocationInvalidationSink.refreshExactTargets = oldExact
            AgentSessionLinkLocationInvalidationSink.refreshObservedTargets = oldObserved
            fixture.session.oversight.retirePeriodicScheduling()
        }
        fixture.viewModel.agentSessionLinkPeriodicObserverIsLive = { bridge.isPeriodicWakeObserverLive(for: $0) }
        let failed = try registry.beginDurableDeletion(sessionID: fixture.sessionID)
        registry.didFailDurableDeletion(failed)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkPeriodicWakeIsEligible(fixture.session, endpoint: endpoint))
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let rawID = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        _ = fixture.viewModel.agentSessionLinkDecoratedProviderText(
            "periodic", session: fixture.session, dispatchID: rawID
        )
        let gate = AutoWakeCatalogAuthorityGate()
        let cleanup = registry.commitObserver
        registry.commitObserver = { sessionID, origin, fileRemoved in
            _ = await gate.requirement()
            await cleanup?(sessionID, origin, fileRemoved)
        }
        let token = try registry.beginDurableDeletion(sessionID: fixture.sessionID)
        let deletion = Task { @MainActor in await registry.didCommitDurableDeletion(token) }
        await gate.waitUntilEntered()
        // Assert the contested state, so an unrelated inventory withdrawal cannot make this pass.
        XCTAssertTrue(registry.isPermanentlyDeleted(sessionID: fixture.sessionID))
        XCTAssertEqual(host.agentSessionLinkCandidates().first { $0.domainEndpoint == endpoint }?.isClosing, true)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkPromptInventoryBySessionID[fixture.sessionID]?.inventory.isEmpty ?? true)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .preparingDispatch)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: rawID))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: fixture.session, dispatchID: rawID)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertNil(fixture.session.oversight.periodicDeadline)
        await gate.open()
        await deletion.value
    }

    // MARK: - Periodic idle scheduling and shared dispatch ownership

    private func periodicFixture() throws -> (Fixture, AgentSessionLinkAutoWakeSnoozeTestClock, DomainAgentSessionLinkEndpointIdentity) {
        let fixture = try makeFixture()
        fixture.viewModel.agentSessionLinkPeriodicObserverIsLive = { _ in true }
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        fixture.session.oversight.periodicIdleWakeEnabled = true
        fixture.session.oversight.periodicIdleWakeIntervalSeconds = 600
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        return (fixture, clock, endpoint)
    }

    @discardableResult
    private func reservePeriodic(
        _ fixture: Fixture,
        clock: AgentSessionLinkAutoWakeSnoozeTestClock,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) throws -> UUID {
        let token = try XCTUnwrap(fixture.session.oversight.periodicDeadlineToken)
        let deadline = try XCTUnwrap(fixture.session.oversight.periodicDeadline)
        clock.advanceWithoutFiring(seconds: 600)
        fixture.viewModel.agentSessionLinkPeriodicWakeDeadline(endpoint: endpoint, token: token, deadline: deadline)
        let attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        attempt.task?.cancel() // This suite drives the real physical seam without launching a provider.
        fixture.session.oversight.pendingAutoWake?.task = nil
        return attempt.wakeID
    }

    func testPeriodicScheduledCancellationRedrivesPendingAttention() throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture, linkSetRevision: 1, queueRevision: 1,
            targetIndices: [], laneIndices: [0], attentionRequests: [attention]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetPeriodicIdleWake(enabled: false, seconds: 600, for: endpoint))
        let successor = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(successor.isPeriodic)
        XCTAssertNotNil(successor.requiredAttentionOccurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
    }

    func testPeriodicEarlyAdmissionRefusalRedrivesPendingAttention() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let periodic = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture, linkSetRevision: 1, queueRevision: 1,
            targetIndices: [], laneIndices: [0], attentionRequests: [attention]
        )
        fixture.session.runState = .running
        await fixture.viewModel.agentSessionLinkRunPeriodicAttempt(periodic, session: fixture.session)
        let successor = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(successor.isPeriodic)
        XCTAssertNotNil(successor.requiredAttentionOccurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertEqual(fixture.session.runState, .running, "attention admission must not interrupt the active turn")
    }

    func testPeriodicEmptyQueueAcquiresAndAcceptsWithoutAClaimOrRoutineStamp() throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let natural = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .headlessRun(runID: UUID())
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(natural)
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake?.queue)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let rawID = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        let monitoring = fixture.viewModel.agentSessionLinkDecoratedProviderText(
            AgentModeViewModel.periodicWakeMessage, session: fixture.session, dispatchID: rawID
        )
        XCTAssertNil(monitoring.claim)
        XCTAssertFalse(monitoring.mustAbortDispatch)
        XCTAssertEqual(monitoring.dispatchContext?.dispatchID.autoWakeID, wakeID)
        XCTAssertEqual(monitoring.text, AgentModeViewModel.periodicWakeMessage)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: rawID))
        XCTAssertNil(fixture.session.oversight.lastOversightWakeDispatch)
        fixture.viewModel.acceptAgentSessionLinkDispatch(session: fixture.session, context: monitoring.dispatchContext, claim: nil)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(fixture.session.items.isEmpty)
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.periodicDeadline, clock.instant.advanced(by: .seconds(600)))
    }

    func testPeriodicIdleBaselineDoesNotSlideAndBusyExpiryHasNoBacklog() throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let original = try XCTUnwrap(fixture.session.oversight.periodicDeadline)
        let token = try XCTUnwrap(fixture.session.oversight.periodicDeadlineToken)
        clock.advanceWithoutFiring(seconds: 300)
        fixture.session.noteMonitorObservationInputsChanged()
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.periodicDeadline, original)
        fixture.session.runState = .running
        fixture.session.runState = .completed // Both edges occur before deferred Combine delivery.
        XCTAssertNil(fixture.session.oversight.periodicDeadlineToken)
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.periodicDeadline, clock.instant.advanced(by: .seconds(600)))
        clock.advanceWithoutFiring(seconds: 300)
        fixture.viewModel.agentSessionLinkPeriodicWakeDeadline(endpoint: endpoint, token: token, deadline: original)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
    }

    func testPeriodicTombstoneRejectsLateProducerAndForeignRefusalCannotRetireIt() throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let producer = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        _ = fixture.viewModel.agentSessionLinkDecoratedProviderText("periodic", session: fixture.session, dispatchID: producer)
        fixture.session.oversight.periodicIdleWakeEnabled = false
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        let foreign = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: fixture.session, dispatchID: foreign)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, wakeID)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: producer))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: fixture.session, dispatchID: producer)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
    }

    func testPeriodicAcceptanceReleasesWaitingContinuationBeforeNotificationReevaluation() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let natural = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .headlessRun(runID: UUID())
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(natural)
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let raw = AgentSessionLinkPromptDispatchID.claudeNativeSend(UUID())
        let monitoring = fixture.viewModel.agentSessionLinkDecoratedProviderText("periodic", session: fixture.session, dispatchID: raw)
        XCTAssertNil(monitoring.claim)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: raw))
        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID, prompt: "What next?", timeoutSeconds: 5)
        }
        for _ in 0 ..< 20 where fixture.session.instructionContinuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.session.instructionContinuation)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.admissionBasis, .periodic)
        fixture.viewModel.acceptAgentSessionLinkDispatch(session: fixture.session, context: monitoring.dispatchContext, claim: nil)
        let notification = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(notification.isPeriodic)
        let response = try await waiting.value
        guard case .laneUpdateAutoWake = response.origin else { return XCTFail("notification must resume the waiting continuation") }
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertNil(fixture.session.oversight.periodicDeadlineToken)
        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
    }

    func testPeriodicFinalizerWaitsForDelayedProducerBeforeRetiringTombstone() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let raw = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
        _ = fixture.viewModel.agentSessionLinkDecoratedProviderText("periodic", session: fixture.session, dispatchID: raw)
        let gate = AutoWakeCatalogAuthorityGate()
        let producer = Task { @MainActor in
            _ = await gate.requirement()
            XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: raw))
        }
        fixture.session.oversight.pendingAutoWake?.periodicProducerTask = producer
        fixture.session.oversight.pendingAutoWake?.periodicStartReturned = true
        fixture.session.oversight.periodicIdleWakeEnabled = false
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        let finalizer = Task { @MainActor in
            await fixture.viewModel.agentSessionLinkAwaitPhysicalDispatchSettlement(wakeID: wakeID, endpoint: endpoint)
        }
        await gate.waitUntilEntered()
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertTrue(AgentModeViewModel.dispatchRequiresLaneBatch(fixture.session, raw), "lost VM must still fail closed")
        await gate.open()
        await finalizer.value
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(fixture.session.oversight.periodicDeadline)
    }

    func testPeriodicACPResumeFailurePreservesIdentityAndHandoffWithoutPrompting() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let (harness, provider, responseGate, directory) = try makePeriodicACPHarness(
            fixture, holdMethod: "unused", failLoad: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = responseGate
        fixture.session.selectedAgent = .openCode
        fixture.session.providerSessionID = "missing-original-session"
        fixture.session.pendingHandoff.payload = "Preserve user handoff"
        let handoff = fixture.session.pendingHandoff
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let startup = try startPeriodicACP(fixture, harness: harness, wakeID: wakeID, endpoint: endpoint)
        await startup.value
        XCTAssertEqual(fixture.session.providerSessionID, "missing-original-session")
        XCTAssertEqual(fixture.session.pendingHandoff, handoff)
        XCTAssertTrue(provider.promptedMessages.isEmpty)
        XCTAssertEqual(harness.acceptedDispatchCount, 0)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertNil(fixture.session.acpController)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
    }

    func testPeriodicClaudeResumeFailureDoesNotStartFreshButUserRecoveryStillWorks() async throws {
        for periodic in [true, false] {
            let (fixture, clock, endpoint) = try periodicFixture()
            if periodic { _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint) }
            else { fixture.session.oversight.retirePeriodicScheduling() }
            let session = AgentTabSession(tabID: fixture.tabID)
            session.hasLoadedPersistedState = true
            session.testInstallPersistentSessionBinding(sessionID: UUID())
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            XCTAssertNil(session.operationAdmissionFailureMessage)
            session.oversight.pendingAutoWake = fixture.session.oversight.pendingAutoWake
            session.selectedAgent = .claudeCode
            session.providerSessionID = "missing-original-session"
            let controller = MonitorFakeNativeController()
            await controller.setRejectResume(true)
            var creations = 0
            let coordinator = ClaudeAgentModeCoordinator(
                windowID: 1, workspacePathProvider: { _ in nil },
                claudeControllerFactory: { _, _, _, _ in
                    creations += 1
                    return controller
                }
            )
            let runID = UUID()
            session.installRunID(runID)
            let ownership = session.beginRunAttempt(source: "test.periodic.resume")
            let result = await coordinator.ensureClaudeNativeSession(
                session: session, intent: .runAttempt(ownership: ownership, runID: runID)
            )
            let attempts = await controller.startOrResumeExistingSessionIDs
            if periodic {
                guard case .failed = result else { return XCTFail("periodic resume must fail closed: \(result)") }
                XCTAssertEqual(attempts, ["missing-original-session"])
                XCTAssertEqual(creations, 1)
                XCTAssertEqual(session.providerSessionID, "missing-original-session")
            } else {
                XCTAssertEqual(result, .ready)
                XCTAssertEqual(attempts, ["missing-original-session", nil])
                XCTAssertEqual(creations, 2)
            }
            await controller.shutdown()
        }
    }

    func testPeriodicACPCancelledStartupLatchesLateProducerAndPreservesHandoff() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let factoryGate = AutoWakeCatalogAuthorityGate()
        let (harness, provider, responseGate, directory) = try makePeriodicACPHarness(
            fixture, holdMethod: "session/new", factoryGate: factoryGate
        )
        defer {
            responseGate.release()
            try? FileManager.default.removeItem(at: directory)
        }
        fixture.session.pendingHandoff.payload = "User handoff must remain untouched"
        let handoff = fixture.session.pendingHandoff
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let startup = try startPeriodicACP(fixture, harness: harness, wakeID: wakeID, endpoint: endpoint)
        await factoryGate.waitUntilEntered()
        XCTAssertNil(fixture.session.agentTask, "ACP startup is suspended before producer installation")
        fixture.session.oversight.periodicIdleWakeEnabled = false
        fixture.viewModel.agentSessionLinkReconcilePeriodicWake(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        await factoryGate.open()
        try await responseGate.waitUntilEntered()
        try await AsyncTestWait.waitUntil("ACP startup to return while its producer remains gated") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake?.periodicStartReturned == true }
        }
        XCTAssertNotNil(
            fixture.session.oversight.pendingAutoWake?.periodicProducerTask,
            "the exact composer owner must latch a producer installed after cancellation"
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertEqual(fixture.session.pendingHandoff, handoff)
        XCTAssertTrue(provider.promptedMessages.isEmpty)
        responseGate.release()
        await startup.value
        await fixture.session.agentTask?.value
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(provider.promptedMessages.isEmpty, "disabled periodic text must never reach controller.prompt")
        XCTAssertEqual(harness.acceptedDispatchCount, 0)
        XCTAssertEqual(fixture.session.pendingHandoff, handoff)
        await fixture.session.acpController?.shutdown()
    }

    func testPeriodicACPInstructionWaitDeliversAttentionBeforePromptResponse() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let (harness, provider, responseGate, directory) = try makePeriodicACPHarness(fixture, holdMethod: "session/prompt")
        defer {
            responseGate.release()
            try? FileManager.default.removeItem(at: directory)
        }
        // Consume membership first: this periodic physical call has genuinely no optional claim.
        let membership = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .headlessRun(runID: UUID())
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(membership)
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let startup = try startPeriodicACP(fixture, harness: harness, wakeID: wakeID, endpoint: endpoint)
        try await responseGate.waitUntilEntered()
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.periodicProducerDispatchID,
            try .acpPromptTurn(runAttemptID: XCTUnwrap(fixture.session.activeRunAttemptID))
        )
        XCTAssertEqual(harness.acceptedDispatchCount, 0, "ACP callback cannot run until the held prompt response returns")
        // Attention arrives before the wait is installed, exercising the existing reevaluation debt.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [Self.attentionRequest(0)]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates, "attention must not depend on routine wake selection")
        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID, prompt: "What next?", timeoutSeconds: 5)
        }
        let response = try await waiting.value
        XCTAssertFalse(response.timedOut)
        guard case .laneUpdateAutoWake = response.origin else {
            responseGate.release()
            await fixture.session.agentTask?.value
            await fixture.session.acpController?.shutdown()
            return XCTFail("exact attention must resume the ordinary wait before ACP completes")
        }
        XCTAssertEqual(harness.acceptedDispatchCount, 0, "yielding the execution slot must not manufacture an acceptance receipt")
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
        XCTAssertEqual(provider.promptedMessages.count, 1, "attention resumes the existing run, not another ACP prompt")
        try MonitorSupplementAssertions.assertCarriesNoSupplement(XCTUnwrap(provider.promptedMessages.first).userMessage)
        responseGate.release()
        await fixture.session.agentTask?.value
        await startup.value
        XCTAssertEqual(harness.acceptedDispatchCount, 1, "the original transport callback still settles after its response")
        XCTAssertTrue(harness.acceptedClaims.isEmpty, "the original periodic turn was claimless")
        await fixture.session.acpController?.shutdown()
    }

    func testPeriodicACPContinuationReleaseRejectsUnacquiredCancelledAndForeignRuns() async throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        let runAttemptID = fixture.session.beginRunAttempt(source: "test.periodic.acp.wait-fences").attemptID
        let raw = AgentSessionLinkPromptDispatchID.acpPromptTurn(runAttemptID: runAttemptID)
        var acquired = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        acquired.phase = .dispatching
        acquired.physicalOutcome = .ambiguous
        acquired.periodicProducerDispatchID = raw
        fixture.session.runState = .waitingForUser
        fixture.session.instructionWaitID = UUID()
        let _: UserInstructionResponse = try await withCheckedThrowingContinuation { continuation in
            fixture.session.instructionContinuation = continuation
            for phase: AgentSessionLinkAutoWakeAttempt.Phase in [.preparingDispatch, .cancelledBeforeDispatch, .dispatching] {
                var attempt = acquired
                attempt.phase = phase
                if phase == .dispatching { attempt.physicalOutcome = .notAttempted }
                fixture.session.oversight.pendingAutoWake = attempt
                fixture.viewModel.agentSessionLinkReleasePeriodicACPContinuationSlot(for: fixture.session)
                XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, wakeID)
            }
            for foreign: AgentSessionLinkPromptDispatchID in [.acpPromptTurn(runAttemptID: UUID()), .acpActiveSteering(runAttemptID: runAttemptID)] {
                var attempt = acquired
                attempt.periodicProducerDispatchID = foreign
                fixture.session.oversight.pendingAutoWake = attempt
                fixture.viewModel.agentSessionLinkReleasePeriodicACPContinuationSlot(for: fixture.session)
                XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, wakeID)
            }
            fixture.session.oversight.pendingAutoWake = acquired
            fixture.session.codexHookGateAttemptToken = UUID()
            fixture.viewModel.agentSessionLinkReleasePeriodicACPContinuationSlot(for: fixture.session)
            XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, wakeID, "a hook approval is not an ordinary wait")
            fixture.session.instructionContinuation = nil
            fixture.session.instructionWaitID = nil
            fixture.session.codexHookGateAttemptToken = nil
            continuation.resume(returning: UserInstructionResponse(text: nil, timedOut: false, elapsedSeconds: 0))
        }
        fixture.session.oversight.pendingAutoWake = nil
    }

    private func makePeriodicACPHarness(
        _ fixture: Fixture, holdMethod: String, factoryGate: AutoWakeCatalogAuthorityGate? = nil, failLoad: Bool = false
    ) throws -> (AgentSessionLinkRunnerHarness, AgentSessionLinkCapturingACPProvider, AgentSessionLinkACPResponseGate, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeriodicACP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gate = try AgentSessionLinkACPResponseGate(directory: directory)
        let script = try AgentSessionLinkACPServerScript.write(to: directory)
        let provider = AgentSessionLinkCapturingACPProvider(providerID: .openCode, commandPath: script.path, environment: [
            "ACP_HOLD_METHOD": holdMethod, "ACP_RESPONSE_GATE": gate.path, "ACP_FAIL_LOAD": failLoad ? "1" : ""
        ])
        let harness = AgentSessionLinkRunnerHarness(
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acpProviderFactory: { _, _ in
                _ = await factoryGate?.requirement()
                return provider
            },
            workspacePath: directory.path, sessionLinkHost: fixture.viewModel
        )
        harness.onHeadlessMessageBuilt = { [weak self] in
            // Fresh ACP startup owns a new process run; publish its exact ready catalog as the host would.
            _ = try? self?.publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true)
        }
        return (harness, provider, gate, directory)
    }

    /// Hold the real composer claim across real run-service/ACP startup, then use the production
    /// periodic finalizer. Only the app-host preparation is bypassed; no producer handle is injected.
    private func startPeriodicACP(
        _ fixture: Fixture, harness: AgentSessionLinkRunnerHarness, wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) throws -> Task<Void, Never> {
        let target = try XCTUnwrap(fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.tabID, session: fixture.session))
        let submission = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "")
        guard case let .claimed(claim) = fixture.viewModel.claimComposerSubmitAttempt(submission, requireActiveTabOwnership: false) else {
            throw NSError(domain: "PeriodicACP", code: 1)
        }
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        fixture.session.oversight.pendingAutoWake?.periodicComposerAttemptID = submission.id
        return Task { @MainActor in
            _ = await harness.service.startRun(
                tabID: fixture.tabID, session: fixture.session,
                initialUserMessage: AgentModeViewModel.periodicWakeMessage,
                initialMessageForRun: AgentModeViewModel.periodicWakeMessage, attachments: []
            )
            if fixture.session.oversight.pendingAutoWake?.wakeID == wakeID {
                fixture.session.oversight.pendingAutoWake?.periodicStartReturned = true
            }
            fixture.viewModel.releaseComposerSubmitClaim(claim)
            await fixture.viewModel.agentSessionLinkAwaitPhysicalDispatchSettlement(wakeID: wakeID, endpoint: endpoint)
        }
    }

    func testPeriodicWithheldInventoryAndHostRetirementFailClosed() throws {
        let (fixture, clock, endpoint) = try periodicFixture()
        _ = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
        fixture.session.oversight.pendingAutoWake?.phase = .preparingDispatch
        let raw = AgentSessionLinkPromptDispatchID.codexFallback(queueID: UUID())
        _ = fixture.viewModel.agentSessionLinkDecoratedProviderText("periodic", session: fixture.session, dispatchID: raw)
        _ = fixture.viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: raw))
        fixture.viewModel.agentSessionLinkPeriodicObserverIsLive = { _ in false }
        XCTAssertFalse(fixture.viewModel.agentSessionLinkPeriodicWakeIsEligible(fixture.session, endpoint: endpoint))
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
        let nativeController: MonitorFakeNativeController
    }

    private func makeFixture(catalogReady: Bool = true, fenceProviderLaunch: Bool = false, windowID: Int = 1, codexController: MonitorFakeCodexController? = nil) throws -> Fixture {
        let tabID = UUID()
        let nativeController = MonitorFakeNativeController()
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                if let codexController { return codexController }
                return LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in
                if fenceProviderLaunch { XCTFail("This fixture must not initialize a Claude provider") }
                return nativeController
            },
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acpProviderFactory: { _, _ in
                AgentSessionLinkCapturingACPProvider(providerID: .openCode, commandPath: "/usr/bin/false")
            },
            acpControllerFactory: { provider, request in
                if fenceProviderLaunch {
                    XCTFail("Parked-note wake fixtures must not launch even a fake ACP process")
                    throw CancellationError()
                }
                return try ACPAgentSessionController(provider: provider, runRequest: request)
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee auto-wake seam"
        )
        let session = viewModel.session(for: tabID)
        // This suite owns provider-neutral admission and settlement. Exact Claude/Codex catalog
        // readiness has dedicated adapter coverage and would add an unrelated async gate here.
        session.selectedAgent = .openCode
        // Most tests establish their own explicit policy. Keep the shared fixture off so changing
        // the product's fresh-session default cannot silently change their preconditions.
        session.oversight.autoWakeOnUpdates = false
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        // Wake admission begins with a restored session, not an unfinished fresh creation.
        // Keep the proof attached to this binding; competing-writer fixtures remain unready.
        let sessionID = UUID()
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: session, updateWorkspaceMetadata: true
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertNil(session.operationAdmissionFailureMessage)
        let fixture = Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            workspaceManager: workspaceManager,
            nativeController: nativeController
        )
        if catalogReady {
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
            let runID = try XCTUnwrap(session.runID)
            viewModel.agentSessionLinkPublishRunCatalogProjection(
                AgentSessionLinkRunCatalogProjection(
                    runID: runID,
                    routeToken: AgentSessionLinkRunCatalogRouteToken(
                        runID: runID,
                        observerEndpoint: endpoint,
                        connectionID: UUID(),
                        routingAuthorityGeneration: 1,
                        connectionLifecycleGeneration: 1
                    ),
                    projectionRevision: 1,
                    hasAgentSessionLink: true,
                    hasAnyActiveLink: true
                ),
                to: endpoint
            )
        }
        return fixture
    }

    private func publishInventory(
        _ fixture: Fixture,
        revision: UInt64,
        targetCount: Int = 2
    ) throws {
        try fixture.viewModel.agentSessionLinkPublishPromptInventory(
            Self.inventory(
                observerSessionID: fixture.sessionID,
                revision: revision,
                targetCount: targetCount
            ),
            to: AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
        )
    }

    @discardableResult
    private func publishCatalogProjection(
        _ fixture: Fixture,
        revision: UInt64,
        hasAgentSessionLink: Bool
    ) throws -> AgentSessionLinkRunCatalogProjection {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let runID = try XCTUnwrap(fixture.session.runID)
        let projection = AgentSessionLinkRunCatalogProjection(
            runID: runID,
            routeToken: AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            ),
            projectionRevision: revision,
            hasAgentSessionLink: hasAgentSessionLink,
            hasAnyActiveLink: true
        )
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
        return projection
    }

    private func publishLane(
        _ fixture: Fixture,
        linkSetRevision: UInt64,
        queueRevision: UInt64,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        metadataSequenceOffset: UInt64 = 0,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil,
        referenceGeneration: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch,
        latestVisibleAssistantPreview: String = "Done.",
        attentionRequests: [AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest] = []
    ) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        if let selectedTargetIndices {
            // Routine selection is live session state; the lane flag is only the projection of it
            // that this publication froze. Writing both keeps status/overflow fixtures from
            // advertising a selection the coordinator's live fence would (correctly) refuse.
            fixture.session.oversight.autoWakeTargetSessionIDs = Set(
                selectedTargetIndices.map(Self.targetID)
            )
        }
        let effectiveSelectedIndices = Set((laneIndices ?? targetIndices).filter {
            fixture.session.oversight.autoWakeOnUpdates
                || fixture.session.oversight.autoWakeTargetSessionIDs.contains(Self.targetID($0))
        })
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            Self.laneSnapshot(
                observerEndpoint: endpoint,
                linkSetRevision: linkSetRevision,
                queueRevision: queueRevision,
                targetIndices: targetIndices,
                laneIndices: laneIndices,
                edgeSequenceOffset: edgeSequenceOffset,
                metadataSequenceOffset: metadataSequenceOffset,
                overflow: overflow,
                selectedTargetIndices: effectiveSelectedIndices,
                referenceGeneration: referenceGeneration,
                queueEpoch: queueEpoch,
                latestVisibleAssistantPreview: latestVisibleAssistantPreview,
                attentionRequests: attentionRequests
            ),
            to: endpoint
        )
    }

    // MARK: - Values

    private static func targetID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0000000%d-0000-0000-0000-000000005501", index))!
    }

    private static func inventory(
        observerSessionID: UUID,
        revision: UInt64,
        targetCount: Int = 2
    ) -> AgentSessionLinkPromptInventory {
        AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: (0 ..< targetCount).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: targetID(index),
                    displayName: index == 0 ? "Build API" : "Review API",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"],
                    reference: laneReference(index)
                )
            }
        )
    }

    private static func epoch(observerSessionID: UUID) -> AgentSessionLinkPromptEpoch {
        AgentSessionLinkPromptEpoch(
            endpoint: DomainAgentSessionLinkEndpointIdentity(
                windowID: 1,
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: observerSessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: 1
            ),
            allowsSupplement: true
        )
    }

    static func laneReference(
        _ index: Int,
        generation: UInt64 = 1
    ) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(
            linkID: UUID(uuidString: String(format: "0000000F-0000-0000-0000-%012d", index + 1))!,
            generation: generation
        )
    }

    private static func laneTargetEndpoint(_ index: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(
                uuidString: String(format: "1000000%d-0000-0000-0000-000000005501", index)
            )!,
            tabID: UUID(
                uuidString: String(format: "2000000%d-0000-0000-0000-000000005501", index)
            )!,
            sessionID: targetID(index),
            persistentBindingGeneration: UUID(
                uuidString: String(format: "3000000%d-0000-0000-0000-000000005501", index)
            )!,
            bindingTransitionGeneration: 1
        )
    }

    private static let laneQueueEpoch = UUID(
        uuidString: "0000000F-0000-0000-0000-000000005501"
    )!

    private static func attentionRequest(
        _ index: Int,
        sequence: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch
    ) -> AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest {
        AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest(
            occurrence: .init(
                queueEpoch: queueEpoch,
                reference: laneReference(index),
                attentionSequence: sequence
            ),
            targetEndpoint: laneTargetEndpoint(index),
            targetSessionID: targetID(index),
            requestedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            status: .idle
        )
    }

    /// `laneIndices` defaults to the entry set, but is separable so a test can reproduce the
    /// activation publication: lanes exist and carry a target epoch while no status edge has been
    /// queued for them yet.
    private static func laneSnapshot(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        linkSetRevision: UInt64 = 1,
        queueRevision: UInt64 = 1,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        metadataSequenceOffset: UInt64 = 0,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil,
        referenceGeneration: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch,
        latestVisibleAssistantPreview: String = "Done.",
        attentionRequests: [AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest] = []
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        let entries = targetIndices.map { index in
            AgentSessionLinkPassiveStatusNotices.PendingEntry(
                reference: laneReference(index, generation: referenceGeneration),
                targetEndpoint: laneTargetEndpoint(index),
                targetSessionID: targetID(index),
                displayName: "Build API",
                fromStatus: .running,
                toStatus: .idle,
                observedAt: Date(timeIntervalSince1970: 0),
                idleForSend: true,
                latestVisibleAssistantPreview: latestVisibleAssistantPreview,
                changeSequence: UInt64(index + 1) + edgeSequenceOffset + metadataSequenceOffset,
                edgeSequence: UInt64(index + 1) + edgeSequenceOffset
            )
        }
        return AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: queueEpoch,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: true,
            isDeliverable: true,
            entries: entries,
            attentionRequests: attentionRequests,
            unacknowledgedOverflowCount: overflow,
            overflowProduced: overflow,
            autoWakeLanes: (laneIndices ?? targetIndices).map { index in
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: laneReference(index, generation: referenceGeneration),
                    targetEndpoint: laneTargetEndpoint(index),
                    targetSessionID: targetID(index),
                    isEffectivelySelected: selectedTargetIndices?.contains(index) ?? true
                )
            }
        )
    }
}

// C3: real claim reservation, preparation and physical fences; no provider process is launched.
extension AgentSessionLinkAutoWakeTests {
    private func reserveQuietWake(_ fixture: Fixture) throws -> AgentSessionLinkOutboundPromptClaim {
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session, dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNotNil(fixture.viewModel.agentSessionLinkPrepareAutoWakeDispatch(
            wakeID: reserved.wakeID, endpoint: reserved.observerEndpoint
        ))
        return claim
    }

    private func beginAndAcquireQuietWake(_ fixture: Fixture, claim: AgentSessionLinkOutboundPromptClaim) throws -> AgentRunOwnership {
        let owner = fixture.session.beginRunAttempt(source: "test.quiet.physical")
        fixture.session.runState = .running
        // The adapter sees a running session, but must reuse the qualification frozen while idle.
        XCTAssertEqual(fixture.viewModel.agentSessionLinkPromptClaim(for: fixture.session, dispatchID: .codexNativeSend(UUID())), claim)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: claim.dispatchID))
        return owner
    }

    func testRoutinePhysicalOriginIsFrozenAndReentryDoesNotQualifyANewOwner() throws {
        for provider in [AgentProviderKind.codexExec, .claudeCode] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            fixture.session.selectedAgent = provider
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let claim = try reserveQuietWake(fixture)
            XCTAssertTrue(claim.routineQuietCheckIn)
            XCTAssertEqual(claim.fragment.contains("Nothing needed? Reply [ack]."), provider == .claudeCode)
            let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: claim.dispatchID))
            fixture.session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
            XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: owner, source: "test.quiet.complete"))
            let replacement = fixture.session.beginRunAttempt(source: "test.quiet.replay")
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: claim.dispatchID))
            fixture.session.sealQuietCheckIn(owner: replacement, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 2, ordinaryThrough: 2))
        }
    }

    func testManualAttentionAndUnqualifiedProviderClaimsStayOrdinary() throws {
        for mode in ["manual", "attention", "devin", "otherACP"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            fixture.session.selectedAgent = mode == "devin" ? .devin : mode == "otherACP" ? .openCode : .codexExec
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: 1,
                attentionRequests: mode == "attention" ? [Self.attentionRequest(0)] : []
            )
            if mode == "manual" {
                var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
                attempt.admissionBasis = .manual
                fixture.session.oversight.pendingAutoWake = attempt
            }
            let claim = try reserveQuietWake(fixture)
            XCTAssertFalse(claim.routineQuietCheckIn, mode)
            let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
            fixture.session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1), mode)
        }
    }

    func testClearPreservesPendingQuietMarkerButManualMarkerRemainsVisibleInSuccessor() async throws {
        for manual in [false, true] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            fixture.session.selectedAgent = .codexExec
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            if manual {
                var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
                attempt.admissionBasis = .manual
                fixture.session.oversight.pendingAutoWake = attempt
            }
            let old = try reserveQuietWake(fixture)
            let oldBinding = fixture.session.currentRestorationBindingToken
            let oldOwner = try beginAndAcquireQuietWake(fixture, claim: old)
            let oldWake = try XCTUnwrap(old.dispatchID.autoWakeID)
            fixture.session.sealQuietCheckIn(owner: oldOwner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: oldOwner, source: "test.old.complete"))
            fixture.session.runState = .completed
            // Ambiguous coordinator settlement is NOT physical producer completion.
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: old.dispatchID)
            fixture.viewModel.clearChat(tabID: fixture.tabID)
            XCTAssertEqual(fixture.session.currentRestorationBindingToken, oldBinding)
            XCTAssertEqual(fixture.session.quietLedger.hiddenSourceIDs.contains(oldWake), !manual)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
            let successor = try reserveQuietWake(fixture)
            XCTAssertTrue(successor.routineQuietCheckIn)
            let newOwner = try beginAndAcquireQuietWake(fixture, claim: successor)
            // Queued MainActor acceptance retains the pending ID until its own final completion.
            let callback = Task { @MainActor [lifetime = fixture.session.retainQuietMarkerProducer(for: old)] in
                fixture.viewModel.acceptAgentSessionLinkPromptClaim(old)
                withExtendedLifetime(lifetime) {}
            }
            XCTAssertEqual(fixture.session.quietLedger.hiddenSourceIDs.contains(oldWake), !manual)
            await callback.value
            XCTAssertEqual(fixture.session.items.first?.id, oldWake)
            XCTAssertTrue(fixture.session.quietLedger.hostMarkerIDs.contains(oldWake))
            fixture.session.sealQuietCheckIn(owner: newOwner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertEqual(fixture.session.quietLedger.facts?.ordinaryThrough, manual ? 1 : 0)
            XCTAssertEqual(fixture.session.quietLedger.hiddenSourceIDs.contains(oldWake), !manual)
            // A materialized verdict is lost on reload; the successor's unmaterialized ID is not.
            let rows = fixture.session.items
            fixture.session.setItemsSilently(rows, reason: .persistedSessionHydration)
            XCTAssertFalse(fixture.session.quietLedger.hiddenSourceIDs.contains(oldWake))
            XCTAssertTrue(try fixture.session.quietLedger.hiddenSourceIDs.contains(XCTUnwrap(successor.dispatchID.autoWakeID)))
        }
    }

    func testLateW1AcceptanceCannotClearSameFingerprintW2StopOrFailure() throws {
        for stop in [false, true] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let first = try reserveQuietWake(fixture)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: first.dispatchID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: first.dispatchID)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: endpoint))
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let second = try reserveQuietWake(fixture)
            XCTAssertNotEqual(first.dispatchID, second.dispatchID)
            XCTAssertEqual(first.passiveQueue, second.passiveQueue)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: second.dispatchID))
            if stop { fixture.viewModel.agentSessionLinkRetractAutoWakeForUserStop(fixture.session) }
            else { fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: second.dispatchID) }
            let suppression = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(first)
            XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, suppression)
            XCTAssertTrue(try fixture.session.liveItemIDs.contains(XCTUnwrap(first.dispatchID.autoWakeID)))
            if stop { fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: second.dispatchID) }
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake, "same failed shape must not call again")
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(second)
            XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint, "only W2 can clear its slot")
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 3, edgeSequenceOffset: 10)
            XCTAssertNotNil(fixture.session.oversight.pendingAutoWake, "genuinely new edge remains admissible")
        }
    }
}

private actor QuietMarkerProducerHolder {
    private var lifetime: AgentQuietMarkerProducerLifetime?
    init(_ lifetime: AgentQuietMarkerProducerLifetime?) {
        self.lifetime = lifetime
    }

    func release() {
        lifetime = nil
    }
}

extension AgentSessionLinkAutoWakeTests {
    private func sealedPendingMarker() throws -> (Fixture, AgentSessionLinkOutboundPromptClaim) {
        let fixture = try makeFixture(fenceProviderLaunch: true)
        fixture.session.selectedAgent = .codexExec
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let claim = try reserveQuietWake(fixture)
        let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
        fixture.session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: owner, source: "test.pending.sealed"))
        fixture.session.runState = .completed
        return (fixture, claim)
    }

    func testLastProducerReleaseOnAndOffMainActorRetiresOnlyUnmaterializedMarker() async throws {
        for offActor in [false, true] {
            let (fixture, claim) = try sealedPendingMarker()
            let wakeID = try XCTUnwrap(claim.dispatchID.autoWakeID)
            var producer = fixture.session.retainQuietMarkerProducer(for: claim)
            weak var lifetime = producer
            XCTAssertNotNil(lifetime)
            XCTAssertTrue(producer === fixture.session.retainQuietMarkerProducer(for: claim))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: claim.dispatchID)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
            if offActor {
                let holder = QuietMarkerProducerHolder(producer)
                producer = nil
                XCTAssertNotNil(lifetime)
                await holder.release()
            } else { producer = nil }
            try await AsyncTestWait.waitUntil("final release cleans pending ID on MainActor") {
                await MainActor.run { !fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID) }
            }
            XCTAssertNil(lifetime)
            XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
        }
    }

    func testQueuedMainActorCallbackStronglyRetainsSharedLifetimeAcrossClearAndSlotRetirement() async throws {
        let (fixture, claim) = try sealedPendingMarker()
        let wakeID = try XCTUnwrap(claim.dispatchID.autoWakeID)
        var producer = fixture.session.retainQuietMarkerProducer(for: claim)
        weak var lifetime = producer
        let gate = AutoWakeCatalogAuthorityGate()
        let callback = Task { @MainActor [producer] in
            _ = await gate.requirement()
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
            withExtendedLifetime(producer) {}
        }
        await gate.waitUntilEntered()
        producer = nil
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: claim.dispatchID)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        fixture.viewModel.clearChat(tabID: fixture.tabID)
        XCTAssertNotNil(lifetime)
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        await gate.open()
        await callback.value
        try await AsyncTestWait.waitUntil("queued callback releases its producer lifetime") {
            await MainActor.run { lifetime == nil }
        }
        XCTAssertTrue(fixture.session.liveItemIDs.contains(wakeID))
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID), "materialized marker retains its own verdict")
        // Retain an actual source anchor after the working suffix no longer contains the row.
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session, publishActivePresentation: false)
        XCTAssertNotNil(fixture.session.fullTranscriptProjection.rowAnchorIndex[wakeID])
        fixture.session.setItemsSilentlyForRetentionCompaction([])
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        fixture.session.clearDerivedTranscriptCaches()
        XCTAssertFalse(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID), "both row and source anchor really retired")
    }

    func testLateFinalReleaseCannotPruneReplacementBindingAndRestartHasNoVerdict() async throws {
        let (fixture, claim) = try sealedPendingMarker()
        let wakeID = try XCTUnwrap(claim.dispatchID.autoWakeID)
        var producer = fixture.session.retainQuietMarkerProducer(for: claim)
        weak var lifetime = producer
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: claim.dispatchID)
        let old = fixture.session.currentRestorationBindingToken
        _ = try XCTUnwrap(fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(), on: fixture.session, updateWorkspaceMetadata: true
        ))
        XCTAssertNotEqual(fixture.session.currentRestorationBindingToken, old)
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.isEmpty)
        // Reuse the same test wake ID deliberately: even then old cleanup must be binding-fenced.
        let successor = fixture.session.beginRunAttempt(source: "test.rebound")
        fixture.session.quietLedger.recordPhysicalDispatch(owner: successor, wakeID: wakeID, routineQuietCheckIn: true, alreadyAcquired: false)
        fixture.session.sealQuietCheckIn(owner: successor, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        producer = nil
        try await AsyncTestWait.waitUntil("old producer reference releases") { await MainActor.run { lifetime == nil } }
        // A MainActor round trip drains final-release work queued before it.
        await Task { @MainActor in }.value
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        let restored = AgentModeViewModel.TabSession(tabID: fixture.tabID)
        restored.setItemsSilently(fixture.session.items, reason: .persistedSessionHydration)
        XCTAssertTrue(restored.quietLedger.hiddenSourceIDs.isEmpty)
        XCTAssertEqual(restored.quietLedger.facts, .zero)
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testNativeClaudeSuspendedAcceptanceRetainsQuietMarkerAcrossClearAndSuccessor() async throws {
        let fixture = try makeFixture()
        fixture.session.selectedAgent = .claudeCode
        let projection = try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true)
        let routeToken = try XCTUnwrap(projection.routeToken)
        fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in routeToken }
        fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
            candidate == routeToken && tabID == fixture.tabID
        }
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let claim = try reserveQuietWake(fixture)
        XCTAssertTrue(claim.routineQuietCheckIn)
        let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
        let gate = AutoWakeCatalogAuthorityGate()
        await fixture.nativeController.setSendSuspension { _ = await gate.requirement() }
        addTeardownBlock { await gate.open() }
        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
        let producer = Task { @MainActor in
            await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
        }
        await gate.waitUntilEntered()
        let wakeID = try XCTUnwrap(claim.dispatchID.autoWakeID)
        fixture.session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
        XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: owner, source: "test.claude.sealed"))
        fixture.session.runState = .completed
        fixture.viewModel.clearChat(tabID: fixture.tabID)
        weak var cohort = fixture.session.oversight.pendingAutoWake?.quietMarkerProducerLifetime
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: claim.dispatchID)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotNil(cohort, "only the suspended native local, not the retired reservation, owns this lifetime")
        let successor = fixture.session.beginRunAttempt(source: "test.claude.successor")
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        await gate.open()
        _ = await producer.value
        XCTAssertTrue(fixture.session.liveItemIDs.contains(wakeID))
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        XCTAssertEqual(fixture.session.activeRunOwnership, successor)
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testAnchoredQuietRowsRetireAtProjectionInstallAndCannotBecomePendingOnReload() throws {
        let fixture = try makeFixture(fenceProviderLaunch: true)
        fixture.session.selectedAgent = .codexExec
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let claim = try reserveQuietWake(fixture)
        let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
        let producer = try XCTUnwrap(fixture.session.retainQuietMarkerProducer(for: claim))
        defer { withExtendedLifetime(producer) {} }
        let thinking = AgentChatItem.thinking("private reasoning", sequenceIndex: fixture.session.nextSequenceIndex)
        fixture.session.appendItem(thinking)
        let assistant = AgentChatItem.assistant("[ack]", sequenceIndex: fixture.session.nextSequenceIndex)
        fixture.session.appendItem(assistant)
        fixture.session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: owner, source: "test.rows.sealed"))
        fixture.session.runState = .completed
        let wakeID = try XCTUnwrap(claim.dispatchID.autoWakeID)
        let rows = [thinking, assistant]
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session, publishActivePresentation: false)
        for row in rows {
            XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(row.id))
            XCTAssertNotNil(fixture.session.fullTranscriptProjection.rowAnchorIndex[row.id])
        }
        _ = fixture.session.removeItem(at: 1)
        _ = fixture.session.removeItem(at: 0)
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session, publishActivePresentation: false)
        for row in rows {
            XCTAssertEqual(
                fixture.session.quietLedger.hiddenSourceIDs.contains(row.id),
                fixture.session.fullTranscriptProjection.rowAnchorIndex[row.id] != nil,
                "incremental removal may still retain a canonical prefix anchor; only actual retirement prunes it"
            )
        }
        // Retire any canonical prefix anchors through their actual cache owner, then install the
        // empty presentation before hydration. Neither retired assistant nor thinking may become pending.
        fixture.session.clearDerivedTranscriptCaches()
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session, publishActivePresentation: false)
        for row in rows {
            XCTAssertNil(fixture.session.fullTranscriptProjection.rowAnchorIndex[row.id])
            XCTAssertFalse(fixture.session.quietLedger.hiddenSourceIDs.contains(row.id))
        }
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID))
        fixture.session.setItemsSilently(rows, reason: .persistedSessionHydration)
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session, publishActivePresentation: false)
        for row in rows {
            XCTAssertFalse(fixture.session.quietLedger.hiddenSourceIDs.contains(row.id), "rehydrated assistant/thinking cannot masquerade as pending markers")
        }
        XCTAssertTrue(fixture.session.quietLedger.hiddenSourceIDs.contains(wakeID), "a genuinely capable unmaterialized marker stays pending")
        XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testPeriodicActualReservationWithPendingRowsFreezesOrdinaryClaimAndZeroQuietSentence() throws {
        for provider in [AgentProviderKind.claudeCode, .codexExec] {
            let (fixture, clock, endpoint) = try periodicFixture()
            fixture.session.selectedAgent = provider
            try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true)
            let wakeID = try reservePeriodic(fixture, clock: clock, endpoint: endpoint)
            XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.admissionBasis, .periodic)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
                for: fixture.session, dispatchID: .autoWake(wakeID: wakeID)
            ))
            XCTAssertFalse(claim.routineQuietCheckIn)
            XCTAssertFalse(claim.fragment.contains("Nothing needed? Reply [ack]."))
            XCTAssertFalse(
                try XCTUnwrap(claim.passive).receipt.deliveredStatuses.isEmpty,
                "negative control carries real pending content, not an absent claim"
            )
            fixture.session.oversight.retirePeriodicScheduling()
        }
    }
}

private actor QuietWakeSendOrder {
    private var count = 0
    func advance() -> Int {
        count += 1
        return count
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testW1CutoffNineAcceptanceDuringW2FailureAtTenPaysOnlyNineAndCannotRearmPhysicalWake() async throws {
        let fixture = try makeFixture()
        fixture.session.selectedAgent = .claudeCode
        let projection = try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true)
        let routeToken = try XCTUnwrap(projection.routeToken)
        fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in routeToken }
        fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
            candidate == routeToken && tabID == fixture.tabID
        }
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        typealias Notices = AgentSessionLinkPassiveStatusNotices
        var reducer = Notices(observerEndpoint: endpoint, queueEpoch: Self.laneQueueEpoch)
        func sample(_ status: Notices.Status, _ settled: UInt64, _ ordinary: UInt64) -> Notices.Sample {
            .init(
                reference: Self.laneReference(0),
                targetEndpoint: Self.laneTargetEndpoint(0),
                targetSessionID: Self.targetID(0),
                displayName: "Build API",
                status: status,
                idleForSend: status == .idle,
                runFacts: .init(settledThrough: settled, ordinaryThrough: ordinary)
            )
        }
        func publish() {
            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
        }
        reducer.enable(samples: [sample(.idle, 8, 8)], linkSetRevision: 1)
        reducer.setAutoWakeLanes([.init(
            reference: Self.laneReference(0),
            targetEndpoint: Self.laneTargetEndpoint(0),
            targetSessionID: Self.targetID(0),
            isEffectivelySelected: true
        )])
        reducer.reconcile(samples: [sample(.idle, 9, 9)], linkSetRevision: 1, deliverable: true)
        publish()
        let first = try reserveQuietWake(fixture)
        let firstOwner = try beginAndAcquireQuietWake(fixture, claim: first)
        let firstGate = AutoWakeCatalogAuthorityGate()
        let secondGate = AutoWakeCatalogAuthorityGate()
        let order = QuietWakeSendOrder()
        await fixture.nativeController.setSendSuspension {
            switch await order.advance() {
            case 1: _ = await firstGate.requirement()
            case 2: _ = await secondGate.requirement()
            default: break
            }
        }
        addTeardownBlock { await firstGate.open()
            await secondGate.open()
        }
        let firstIntent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: firstOwner, runID: XCTUnwrap(fixture.session.runID))
        let w1 = Task { @MainActor in
            await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "", attachments: [], intent: firstIntent, allowsCatalogRouteControllerRecovery: false
            )
        }
        await firstGate.waitUntilEntered()
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: first.dispatchID)
        XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: firstOwner, source: "test.w1.local-finished"))
        fixture.session.runState = .completed
        reducer.reconcile(samples: [sample(.idle, 10, 10)], linkSetRevision: 1, deliverable: true)
        publish()
        let second = try reserveQuietWake(fixture)
        XCTAssertNotEqual(first.dispatchID, second.dispatchID)
        let secondOwner = try beginAndAcquireQuietWake(fixture, claim: second)
        let secondIntent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: secondOwner, runID: XCTUnwrap(fixture.session.runID))
        let w2 = Task { @MainActor in
            await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "", attachments: [], intent: secondIntent, allowsCatalogRouteControllerRecovery: false
            )
        }
        await secondGate.waitUntilEntered()
        fixture.viewModel.agentSessionLinkRetractAutoWakeForUserStop(fixture.session)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: second.dispatchID)
        let failedTen = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
        XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: secondOwner, source: "test.w2.stopped"))
        fixture.session.runState = .completed
        await firstGate.open()
        _ = await w1.value
        XCTAssertTrue(try fixture.session.liveItemIDs.contains(XCTUnwrap(first.dispatchID.autoWakeID)))
        // The fixture routes this production-created frozen receipt to its own reducer, exactly as
        // the shared bridge does in the app; never synthesize a newer payment from current facts.
        let firstReceipt = try XCTUnwrap(first.passive?.receipt)
        XCTAssertEqual(firstReceipt.deliveredStatuses.first?.settledThrough, 9)
        reducer.apply(firstReceipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: Self.laneReference(0)), 9)
        XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 10)
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failedTen)
        let calls = await fixture.nativeController.sentCount
        XCTAssertEqual(calls, 2)
        for index in 0 ..< 5 {
            reducer.reconcile(samples: [sample(.running, UInt64(10 + index), 10)], linkSetRevision: 1, deliverable: true)
            reducer.reconcile(samples: [sample(.idle, UInt64(11 + index), 10)], linkSetRevision: 1, deliverable: true)
            publish()
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        }
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failedTen)
        let after = await fixture.nativeController.sentCount
        XCTAssertEqual(after, calls, "quiet round trips/metadata cannot produce another physical call")
        await secondGate.open()
        _ = await w2.value
        try reducer.apply(XCTUnwrap(second.passive?.receipt))
        XCTAssertEqual(reducer.deliveredRunThrough(for: Self.laneReference(0)), 10)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        reducer.reconcile(samples: [sample(.idle, 16, 16)], linkSetRevision: 1, deliverable: true)
        publish()
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake, "new ordinary work may admit under unchanged controls")
        fixture.session.oversight.pendingAutoWake?.task?.cancel()
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testLateUnknownW1AcceptanceRebasesDebtWithoutClearingW2AndFreshProofRedisclosesOnlyWithoutFailure() throws {
        for storedFailure in [false, true] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            typealias Notices = AgentSessionLinkPassiveStatusNotices
            var reducer = Notices(observerEndpoint: endpoint, queueEpoch: Self.laneQueueEpoch)
            func sample(_ status: Notices.Status, _ proof: AgentRunQuietFacts?) -> Notices.Sample {
                .init(
                    reference: Self.laneReference(0),
                    targetEndpoint: Self.laneTargetEndpoint(0),
                    targetSessionID: Self.targetID(0),
                    displayName: "Build API",
                    status: status,
                    runFacts: proof
                )
            }
            func publish() {
                fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
            }
            reducer.enable(samples: [sample(.running, .init(settledThrough: 8, ordinaryThrough: 8))], linkSetRevision: 1)
            reducer.setAutoWakeLanes([.init(reference: Self.laneReference(0), targetEndpoint: Self.laneTargetEndpoint(0), targetSessionID: Self.targetID(0), isEffectivelySelected: true)])
            reducer.reconcile(samples: [sample(.running, .init(settledThrough: 10, ordinaryThrough: 10))], linkSetRevision: 1, deliverable: true)
            reducer.reconcile(samples: [sample(.idle, nil)], linkSetRevision: 1, deliverable: true)
            publish()
            let first = try reserveQuietWake(fixture)
            XCTAssertNil(first.passive?.receipt.deliveredStatuses.first?.settledThrough)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: first.dispatchID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: first.dispatchID)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: endpoint))
            publish()
            let second = try reserveQuietWake(fixture)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: second.dispatchID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: second.dispatchID)
            let failure = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(first)
            try reducer.apply(XCTUnwrap(first.passive?.receipt))
            XCTAssertEqual(reducer.deliveredRunThrough(for: Self.laneReference(0)), 8)
            XCTAssertEqual(reducer.snapshot.entries.first?.fromStatus, .idle)
            XCTAssertFalse(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
            XCTAssertEqual(reducer.snapshot.wakeEligibilityFingerprint, failure)
            XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failure)
            if !storedFailure { fixture.session.oversight.clearWakeSuppression() }
            for _ in 0 ..< 5 {
                reducer.reconcile(samples: [sample(.idle, nil)], linkSetRevision: 1, deliverable: true)
                publish()
                XCTAssertNil(fixture.session.oversight.pendingAutoWake, "unpaired debt cannot independently repeat at each interval")
            }
            if storedFailure {
                // Manual retry is still permitted on an unpaired inert hitchhiker. It changes no
                // routine failure identity and its physical failure pays nothing.
                XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
                let manual = try reserveQuietWake(fixture)
                XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: manual.dispatchID))
                fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: manual.dispatchID)
                XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failure)
                XCTAssertEqual(reducer.deliveredRunThrough(for: Self.laneReference(0)), 8)
            }
            reducer.reconcile(samples: [sample(.idle, .init(settledThrough: 10, ordinaryThrough: 10))], linkSetRevision: 1, deliverable: true)
            publish()
            if storedFailure {
                XCTAssertNil(fixture.session.oversight.pendingAutoWake, "fresh proof does not invent a new failed occurrence")
                XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failure)
                XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
            } else {
                XCTAssertNotNil(fixture.session.oversight.pendingAutoWake, "one fresh-proof redisclosure is owed without failure")
            }
            let retry = try reserveQuietWake(fixture)
            XCTAssertEqual(retry.passive?.receipt.deliveredStatuses.first?.settledThrough, 10)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: retry.dispatchID))
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(retry)
            try reducer.apply(XCTUnwrap(retry.passive?.receipt))
            publish()
            XCTAssertEqual(reducer.deliveredRunThrough(for: Self.laneReference(0)), 10)
            XCTAssertTrue(reducer.snapshot.entries.isEmpty)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        }
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testF1QuietCloseThenControllerRunReplacementAndAcceptedLocalSuccessorReachActualObserverPhysicalWake() async throws {
        let observer = try makeFixture()
        let target = try makeFixture(windowID: 2)
        observer.session.selectedAgent = .claudeCode
        target.session.selectedAgent = .claudeCode
        observer.session.runState = .running // park wake admission until this test supplies its physical producer
        let catalog = try publishCatalogProjection(observer, revision: 2, hasAgentSessionLink: true)
        let token = try XCTUnwrap(catalog.routeToken)
        observer.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        observer.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in token }
        observer.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
            candidate == token && tabID == observer.tabID
        }
        let host = LiveWindowEndpointHost()
        host.register(observer.viewModel, windowID: 1)
        host.register(target.viewModel, windowID: 2)
        let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
            runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date(timeIntervalSince1970: 0)
        ))
        let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
        guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: target.sessionID.uuidString) else {
            return XCTFail("grant failed")
        }
        let observerEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(observer.viewModel, tabID: observer.tabID)
        XCTAssertTrue(observer.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([target.sessionID], for: observerEndpoint))
        let terminal = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        func finish(_ owner: AgentRunOwnership) async throws {
            let candidate = try XCTUnwrap(target.viewModel.agentSessionLinkCandidates(isWindowClosing: false).first)
            let opening = target.session.quietLedger.facts
            var preparingFacts: AgentRunQuietFacts?
            var inlineIdleFacts: AgentRunQuietFacts?
            var idleStillOwned = false
            let previous = target.session.onRunStateChanged
            target.session.onRunStateChanged = { session in
                previous?(session)
                guard session.runState == .completed else { return }
                let captured = host.agentSessionLinkObservationSnapshot(for: candidate)
                inlineIdleFacts = host.agentSessionLinkRunFacts(for: candidate, capturedStatus: captured.status)
                idleStillOwned = session.activeRunOwnership == owner
            }
            defer { target.session.onRunStateChanged = previous }
            let revision = await AgentRunTerminalCommitBarrier().commit(.init(
                binding: terminal.hooks.bindTerminalSession(target.session), ownership: owner,
                expectedRunID: target.session.runID, terminalState: .completed, source: "test.F1",
                attachmentDisposition: .deleteFiles, finalizeNonCodexUsage: false, supportsFollowUp: false,
                notifyTurnComplete: false, classifiesQuietCheckIn: true,
                prepareProviderState: {
                    let captured = host.agentSessionLinkObservationSnapshot(for: candidate)
                    preparingFacts = host.agentSessionLinkRunFacts(for: candidate, capturedStatus: captured.status)
                    return nil
                }
            ))
            XCTAssertNotNil(revision)
            XCTAssertEqual(preparingFacts, opening, "real host accessor uses the captured active status after seal")
            XCTAssertEqual(inlineIdleFacts, target.session.quietLedger.facts)
            XCTAssertTrue(idleStillOwned, "first captured idle facts do not wait for ownership release")
            // Source publishers coalesce on the main queue. Wait for their existing signal, then
            // drain the owning serial publication and ordinary authoritative observer projection.
            await bridge.test_settleProjections()
            await bridge.test_settleTargetPublications()
            await bridge.test_settleProjections()
        }
        await bridge.test_settleTargetPublications()
        let old = target.session.beginRunAttempt(source: "test.F1.quiet")
        target.session.runState = .running
        let targetEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(target.viewModel, tabID: target.tabID)
        try await AsyncTestWait.waitUntil("F1 running frame accepted", timeout: 4) {
            bridge.test_pairedRunStatus(for: targetEndpoint) == .running
        }
        await bridge.test_settleTargetPublications()
        // Seed the precondition through the same ledger physical-origin seam as the shared native
        // replay family. This test's outcome is the downstream real claim/physical provider handoff.
        target.session.quietLedger.markRoutineWake(owner: old, wakeID: UUID())
        try await finish(old)
        let oldVerdict = target.session.quietLedger.hiddenSourceIDs
        XCTAssertEqual(target.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
        XCTAssertNil(observer.session.oversight.pendingAutoWake, "quiet close must not wake the observer")
        target.session.installRunID(UUID())
        target.session.claudeController = MonitorFakeNativeController()
        let successor = target.session.beginRunAttempt(source: "test.F1.local-successor")
        target.session.runState = .running
        // Use the real accepted pre-row composer boundary on an open owner. waitingForUser by
        // itself is neutral (no interaction); without a continuation it uses the existing follow-up
        // queue, so this fixture does not invent a second provider callback during terminal replay.
        target.session.runState = .waitingForUser
        let result = target.viewModel.submitUserTurn(text: "local successor work", tabID: target.tabID)
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(target.session.items.contains { $0.kind == .user && $0.text == "local successor work" })
        target.session.runState = .running
        target.session.appendItem(.assistant("ordinary successor finished"))
        try await finish(successor)
        XCTAssertEqual(target.session.quietLedger.facts, .init(settledThrough: 2, ordinaryThrough: 2))
        XCTAssertEqual(target.session.quietLedger.hiddenSourceIDs, oldVerdict)
        let notices = try XCTUnwrap(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID])
        XCTAssertEqual(notices.entries.first?.ordinaryThrough, 2)
        XCTAssertEqual(notices.entries.first?.latestVisibleAssistantPreview, "ordinary successor finished")
        observer.session.runState = .completed
        let claim = try reserveQuietWake(observer)
        let owner = try beginAndAcquireQuietWake(observer, claim: claim)
        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(observer.session.runID))
        _ = await observer.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: observer.session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false
        )
        let physical = await observer.nativeController.sentMessages
        XCTAssertEqual(physical.count, 1)
        XCTAssertTrue(try XCTUnwrap(physical.first).contains("ordinary successor finished"))
        XCTAssertEqual(claim.passive?.receipt.deliveredStatuses.first?.settledThrough, 2)
        try bridge.applyPassiveMonitorNoticeReceipt(XCTUnwrap(claim.passive?.receipt), observerEndpoint: observerEndpoint)
        XCTAssertTrue(try XCTUnwrap(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID]).entries.isEmpty)
        target.session.pendingInstructions.removeAll()
        observer.session.oversight.pendingAutoWake?.task?.cancel()
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testQuietBatchReorderingKeepsFailureSuppressedWithoutBlockingFreshAdmissionBases() throws {
        typealias Notices = AgentSessionLinkPassiveStatusNotices
        for freshBasis in ["ordinary", "status", "attention", "overflow", "manual"] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            var reducer = Notices(observerEndpoint: endpoint, queueEpoch: Self.laneQueueEpoch)
            func sample(_ index: Int, _ settled: UInt64, _ ordinary: UInt64, status: Notices.Status = .idle) -> Notices.Sample {
                .init(
                    reference: Self.laneReference(index), targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index), displayName: "Lane \(index)", status: status,
                    idleForSend: status == .idle, runFacts: .init(settledThrough: settled, ordinaryThrough: ordinary)
                )
            }
            func publish(_ snapshot: Notices.Snapshot) {
                fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
            }
            reducer.enable(samples: [sample(0, 8, 8), sample(1, 8, 8)], linkSetRevision: 1)
            reducer.setAutoWakeLanes((0 ..< 2).map { .init(
                reference: Self.laneReference($0), targetEndpoint: Self.laneTargetEndpoint($0),
                targetSessionID: Self.targetID($0), isEffectivelySelected: true
            ) })
            reducer.reconcile(samples: [sample(0, 9, 9), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            let original = reducer.snapshot
            XCTAssertEqual(original.entries.map(\.reference), [Self.laneReference(0), Self.laneReference(1)])
            publish(original)
            let first = try reserveQuietWake(fixture)
            let frozen = try XCTUnwrap(first.passive?.receipt)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: first.dispatchID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: first.dispatchID)
            let failed = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)

            // Only A's quiet cutoff/metadata advances: display order becomes B,A, not a new failure.
            reducer.reconcile(samples: [sample(0, 10, 9), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            let quiet = reducer.snapshot
            XCTAssertEqual(quiet.entries.map(\.reference), [Self.laneReference(1), Self.laneReference(0)])
            XCTAssertEqual(quiet.entries.last?.edgeSequence, original.entries.first?.edgeSequence)
            XCTAssertEqual(quiet.entries.last?.ordinaryThrough, 9)
            XCTAssertEqual(quiet.entries.last?.receiptSettledThrough, 10)
            XCTAssertGreaterThan(try XCTUnwrap(quiet.entries.last?.changeSequence), try XCTUnwrap(original.entries.first?.changeSequence))
            XCTAssertEqual(frozen.deliveredStatuses.map(\.reference), [Self.laneReference(0), Self.laneReference(1)])
            XCTAssertEqual(frozen.deliveredStatuses.map(\.settledThrough), [9, 9])
            for _ in 0 ..< 3 {
                publish(quiet)
            }
            XCTAssertNil(fixture.session.oversight.pendingAutoWake, "\(freshBasis): quiet-only reordering must not rearm the failed batch")
            guard fixture.session.oversight.pendingAutoWake == nil else {
                fixture.session.oversight.pendingAutoWake?.task?.cancel()
                continue
            }
            XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, failed)

            switch freshBasis {
            case "ordinary":
                reducer.reconcile(samples: [sample(0, 11, 11), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            case "status":
                reducer.reconcile(samples: [sample(0, 10, 9, status: .waiting), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            case "attention":
                XCTAssertEqual(reducer.requestAttention(
                    reference: Self.laneReference(1), targetEndpoint: Self.laneTargetEndpoint(1),
                    targetSessionID: Self.targetID(1), linkSetRevision: 1
                ), .accepted)
            case "overflow", "manual": break
            default: return XCTFail("Unknown admission control")
            }
            var successor = reducer.snapshot
            if freshBasis == "overflow" {
                // Existing anonymous overflow producer shape; retain the reducer's exact row order.
                successor = .init(
                    observerEndpoint: successor.observerEndpoint, queueEpoch: successor.queueEpoch,
                    queueRevision: successor.queueRevision + 1, linkSetRevision: successor.linkSetRevision,
                    isEnabled: successor.isEnabled, isDeliverable: successor.isDeliverable,
                    entries: successor.entries, attentionRequests: successor.attentionRequests,
                    unacknowledgedOverflowCount: 1, overflowProduced: successor.overflowProduced + 1,
                    autoWakeLanes: successor.autoWakeLanes
                )
            }
            publish(successor)
            if freshBasis == "manual" {
                XCTAssertNil(fixture.session.oversight.pendingAutoWake)
                XCTAssertEqual(fixture.viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint), .scheduled)
            }
            let next = try reserveQuietWake(fixture)
            XCTAssertEqual(next.passive?.receipt.deliveredStatuses.map(\.reference), successor.entries.map(\.reference))
            XCTAssertEqual(next.passive?.receipt.deliveredStatuses.map(\.settledThrough), successor.entries.map(\.receiptSettledThrough))
            XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.isManual, freshBasis == "manual")
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: next.dispatchID), freshBasis)
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: next.dispatchID)
            XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, freshBasis == "manual" ? failed : successor.wakeEligibilityFingerprint)
            for _ in 0 ..< 3 {
                publish(successor)
            }
            XCTAssertNil(fixture.session.oversight.pendingAutoWake, "\(freshBasis): one attempt, not a retry loop")
        }
    }

    func testF3QuietLaneNewOrdinaryCoverageRearmsFailureBeforeClaimAndWhenBudgetOmitted() throws {
        for omitted in [false, true] {
            let fixture = try makeFixture(fenceProviderLaunch: true)
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            if omitted {
                let live = Self.inventory(observerSessionID: fixture.sessionID, revision: 1)
                fixture.viewModel.agentSessionLinkPublishPromptInventory(.init(
                    observerSessionID: fixture.sessionID, linkSetRevision: 1,
                    items: live.items + (2 ..< 200).map { index in
                        .init(
                            targetSessionID: UUID(uuidString: String(format: "F3000000-0000-0000-0000-%012d", index))!,
                            displayName: String(repeating: "inventory & lane", count: 8),
                            capabilityNames: ["poll", "read", "wait"]
                        )
                    }
                ), to: endpoint)
            }
            typealias Notices = AgentSessionLinkPassiveStatusNotices
            var reducer = Notices(observerEndpoint: endpoint, queueEpoch: Self.laneQueueEpoch)
            func sample(_ index: Int, _ settled: UInt64, _ ordinary: UInt64) -> Notices.Sample {
                .init(
                    reference: Self.laneReference(index),
                    targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index),
                    displayName: index == 0 && omitted ? String(repeating: "&", count: 120) : "Lane \(index)",
                    status: .idle,
                    latestVisibleAssistantPreview: index == 0 && omitted ? String(repeating: "&", count: 280) : "finished",
                    runFacts: .init(settledThrough: settled, ordinaryThrough: ordinary)
                )
            }
            reducer.enable(samples: [sample(0, 8, 8), sample(1, 8, 8)], linkSetRevision: 1)
            reducer.setAutoWakeLanes((0 ..< 2).map { .init(reference: Self.laneReference($0), targetEndpoint: Self.laneTargetEndpoint($0), targetSessionID: Self.targetID($0), isEffectivelySelected: true) })
            // C precedes B in the real detail order, so the existing budget reserves small C and
            // can omit large B. B's quiet close preserves its earlier unpaid ordinary contribution.
            reducer.reconcile(samples: [sample(0, 8, 8), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            reducer.reconcile(samples: [sample(0, 9, 9), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            reducer.reconcile(samples: [sample(0, 10, 9), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
            if omitted {
                let claim = try reserveQuietWake(fixture)
                let rendered = try XCTUnwrap(claim.passive?.receipt.deliveredStatuses)
                XCTAssertTrue(rendered.contains { $0.reference == Self.laneReference(1) })
                XCTAssertFalse(rendered.contains { $0.reference == Self.laneReference(0) }, "B truly did not fit, not a fabricated receipt")
                XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: claim.dispatchID))
                fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: claim.dispatchID)
            } else {
                let wake = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
                XCTAssertNil(fixture.viewModel.agentSessionLinkPromptClaimStore.pendingClaim(dispatchID: .autoWake(wakeID: wake.wakeID), observerSessionID: fixture.sessionID))
                fixture.viewModel.agentSessionLinkRetractAutoWakeForUserStop(fixture.session)
            }
            let failed = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
            for _ in 0 ..< 3 {
                fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
            }
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            reducer.reconcile(samples: [sample(0, 11, 11), sample(1, 9, 9)], linkSetRevision: 1, deliverable: true)
            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
            XCTAssertNotEqual(reducer.snapshot.wakeEligibilityFingerprint, failed)
            let next = try reserveQuietWake(fixture)
            XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(for: fixture.session, dispatchID: next.dispatchID))
            fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: next.dispatchID)
            for _ in 0 ..< 3 {
                fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(reducer.snapshot, to: endpoint)
            }
            XCTAssertNil(fixture.session.oversight.pendingAutoWake, "one rearm for new ordinary coverage, never a metadata retry loop")
        }
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testClaudeQuietGuidanceWholePhysicalNativeEnvelopesBeforeAfterFullReminderAndNearCap() async throws {
        for reminder in [false, true] {
            for nearCap in [false, true] {
                for basis in ["routine", "overflow"] {
                    var texts: [String] = []
                    var fragmentBytes: [Int] = []
                    var renderedRows: [[String]] = []
                    for routine in [false, true] {
                        let fixture = try makeFixture()
                        fixture.session.selectedAgent = .claudeCode
                        let catalog = try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true)
                        let token = try XCTUnwrap(catalog.routeToken)
                        fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
                        fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in token }
                        fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in candidate == token && tabID == fixture.tabID }
                        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
                        func publish(_ revision: UInt64) {
                            let small = Self.inventory(observerSessionID: fixture.sessionID, revision: revision)
                            let extra: [AgentSessionLinkPromptInventoryItem] = nearCap ? (2 ..< 200).map { index in
                                .init(
                                    targetSessionID: UUID(uuidString: String(format: "C4000000-0000-0000-0000-%012d", index))!,
                                    displayName: String(repeating: "inventory & lane", count: 8),
                                    capabilityNames: ["poll", "read", "wait"]
                                )
                            } : []
                            fixture.viewModel.agentSessionLinkPublishPromptInventory(.init(
                                observerSessionID: fixture.sessionID,
                                linkSetRevision: revision,
                                items: small.items + extra
                            ), to: endpoint)
                            let offered = Self.laneSnapshot(observerEndpoint: endpoint, linkSetRevision: revision, queueRevision: revision)
                            let snapshot = AgentSessionLinkPassiveStatusNotices.Snapshot(
                                observerEndpoint: endpoint, queueEpoch: offered.queueEpoch, queueRevision: revision,
                                linkSetRevision: revision, isEnabled: true, isDeliverable: true,
                                entries: (basis == "overflow" ? [] : offered.entries).map { row in
                                    .init(
                                        reference: row.reference,
                                        targetEndpoint: row.targetEndpoint,
                                        targetSessionID: row.targetSessionID,
                                        displayName: nearCap ? String(repeating: "&", count: 120) : row.displayName,
                                        fromStatus: row.fromStatus,
                                        toStatus: row.toStatus,
                                        observedAt: row.observedAt,
                                        latestVisibleAssistantPreview: nearCap ? String(repeating: "&", count: 280) : "finished",
                                        changeSequence: row.changeSequence,
                                        edgeSequence: row.edgeSequence
                                    )
                                }, unacknowledgedOverflowCount: basis == "overflow" ? 1 : 0,
                                overflowProduced: basis == "overflow" ? 1 : 0, autoWakeLanes: offered.autoWakeLanes
                            )
                            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
                        }
                        publish(1)
                        if reminder {
                            let owner = fixture.session.beginRunAttempt(source: "test.copy.primer")
                            fixture.session.runState = .running
                            let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
                            _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                                session: fixture.session, text: "primer", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false
                            )
                            XCTAssertTrue(fixture.session.endRunAttempt(ifCurrent: owner, source: "test.copy.primer.finished"))
                            fixture.session.runState = .completed
                        }
                        fixture.session.oversight.autoWakeOnUpdates = true
                        publish(reminder ? 2 : 1)
                        if !routine {
                            var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
                            attempt.admissionBasis = .manual
                            fixture.session.oversight.pendingAutoWake = attempt
                        }
                        let claim = try reserveQuietWake(fixture)
                        XCTAssertEqual(claim.routineQuietCheckIn, routine)
                        let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
                        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
                        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                            session: fixture.session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false
                        )
                        let sent = await fixture.nativeController.sentMessages
                        let physical = try XCTUnwrap(sent.last)
                        XCTAssertEqual(physical.contains("Nothing needed? Reply [ack]."), routine)
                        XCTAssertTrue(physical.contains(claim.fragment), "measure the physical provider bytes, not only a render handed to the test")
                        texts.append(physical)
                        fragmentBytes.append(claim.fragment.utf8.count)
                        try renderedRows.append(XCTUnwrap(claim.passive?.receipt.deliveredStatuses).map(\.targetEndpoint.sessionID.uuidString))
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "provider": "claudeCode", "adapter": "physical-native", "basis": basis, "guidance": reminder ? "reminder" : "full",
                        "budget": nearCap ? "near-cap" : "generous", "before": texts[0], "after": texts[1],
                        "beforeFragmentBytes": fragmentBytes[0], "afterFragmentBytes": fragmentBytes[1],
                        "beforeRows": renderedRows[0], "renderedRows": renderedRows[1]
                    ], options: [.sortedKeys])
                    print("QUIET_C4_ENVELOPE " + data.base64EncodedString())
                }
            }
        }
    }
}

extension AgentSessionLinkAutoWakeTests {
    private func installQuietNativeRoute(_ fixture: Fixture) throws {
        let token = try XCTUnwrap(publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: true).routeToken)
        fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in token }
        fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { value, tabID in value == token && tabID == fixture.tabID }
    }

    func testEClaudeCodexRingDrainsAtMostTwoRealNativeFakeWakesAndDoesNotEchoQuietClosures() async throws {
        try await exerciseNativeRing(failing: false)
    }

    func testEPersistentFailingTwoWayNativeRingAdvancesOrdinaryWatermarksAtExistingInterval() async throws {
        try await exerciseNativeRing(failing: true)
    }

    private func exerciseNativeRing(failing: Bool) async throws {
        let codex = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder())
        let a = try makeFixture(windowID: 1)
        let b = try makeFixture(windowID: 2, codexController: codex)
        a.session.selectedAgent = .claudeCode
        b.session.selectedAgent = .codexExec
        try installQuietNativeRoute(a)
        let codexCatalog = MonitorInventoryPublisher(viewModel: b.viewModel, observerSessionID: b.sessionID, tabID: b.tabID)
        await codexCatalog.publishCodex(revision: 1, targetCount: 1)
        codex.setStartOrResumeHook { await codexCatalog.republishCurrentCodexCatalog() }
        addTeardownBlock { await codexCatalog.cleanupCodexCatalogPublications() }
        let host = LiveWindowEndpointHost()
        host.register(a.viewModel, windowID: 1)
        host.register(b.viewModel, windowID: 2)
        let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: .distantPast))
        let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
        let terminal = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        for (observer, target) in [(a, b), (b, a)] {
            guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: target.sessionID.uuidString) else { return XCTFail("ring grant failed") }
            observer.session.isPreparingInitialWorktree = true
            observer.session.oversight.autoWakeOnUpdates = false
        }
        func finish(_ fixture: Fixture, _ owner: AgentRunOwnership) async throws {
            _ = await AgentRunTerminalCommitBarrier().commit(.init(
                binding: terminal.hooks.bindTerminalSession(fixture.session), ownership: owner, expectedRunID: fixture.session.runID,
                terminalState: .completed, source: "test.E.ring", attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false, classifiesQuietCheckIn: true
            ))
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            try await AsyncTestWait.waitUntil("ring source idle frame accepted") { bridge.test_pairedRunStatus(for: endpoint) == .idle }
            await bridge.test_settleTargetPublications()
            await bridge.test_refreshStatus(sessionIDs: [a.sessionID, b.sessionID])
        }
        for fixture in [a, b] {
            fixture.session.runState = .running
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            try await AsyncTestWait.waitUntil("ring ordinary running frame accepted") { bridge.test_pairedRunStatus(for: endpoint) == .running }
            let owner = fixture.session.beginRunAttempt(source: "test.E.ordinary")
            fixture.session.noteAcceptedTaskInput()
            try await finish(fixture, owner)
        }
        if failing {
            b.viewModel.test_codexCoordinator.installTerminalCommitBarrier(AgentRunTerminalCommitBarrier(), terminalSessionBinder: terminal.hooks.bindTerminalSession)
            // One shared deterministic instant; timestamps are recorded INSIDE the actual fake
            // send/start boundary, not at reservation or by inferring that an adapter was called.
            let clock = AgentSessionLinkAutoWakeSnoozeTestClock()
            let start = clock.wallNow
            var calls: [(provider: String, seconds: TimeInterval)] = []
            await a.nativeController.setFailSendAfterRecord(true)
            await a.nativeController.setSendSuspension {
                await MainActor.run { calls.append(("Claude", clock.wallNow.timeIntervalSince(start))) }
            }
            codex.setStartFailure(true) {
                await MainActor.run { calls.append(("Codex", clock.wallNow.timeIntervalSince(start))) }
            }
            for fixture in [a, b] {
                fixture.session.oversight.snoozeClock = clock.clock
                fixture.session.oversight.routineWakeIntervalEnabled = true
                fixture.session.oversight.routineWakeIntervalSeconds = 300
                fixture.session.isPreparingInitialWorktree = true
            }
            func freshNotices(for observer: Fixture) async throws -> AgentSessionLinkPassiveStatusNotices.Snapshot {
                let target = observer.session === a.session ? b : a
                try await AsyncTestWait.waitUntil("failing ring observer has the peer's exact fresh ordinary facts") {
                    await bridge.test_settleTargetPublications()
                    await bridge.test_refreshStatus(sessionIDs: [observer.sessionID])
                    return observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID]?.entries.first?.runFacts == target.session.quietLedger.facts
                }
                return try XCTUnwrap(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID])
            }
            var maxQueueRows = 0
            // A real failure pays no receipt. Each failed ordinary closure advances a NEW source
            // watermark, so the peer can keep waking. The contract bounds cadence/queue, NOT an
            // invented universal cycle dampener or a new retry/backoff rule.
            for round in 0 ..< 8 {
                if round > 0 {
                    clock.advanceWithoutFiring(seconds: 299)
                    for fixture in [a, b] {
                        fixture.session.oversight.autoWakeOnUpdates = true
                        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
                        let notices = try await freshNotices(for: fixture)
                        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(notices, to: endpoint)
                        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "Fresh ordinary debt must still respect the existing interval")
                    }
                    XCTAssertEqual(calls.count, round * 2)
                    clock.advanceWithoutFiring(seconds: 1)
                }
                for fixture in [a, b] {
                    fixture.session.oversight.autoWakeOnUpdates = true
                    let notices = try await freshNotices(for: fixture)
                    let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
                    // Owner publication is an admission hint even when its bounded display value
                    // is unchanged. Existing timer expiry/readiness tests separately exercise the
                    // automatic re-drive; this fixture cancels its task to control physical sends.
                    fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(notices, to: endpoint)
                    // The peer may already have an interval-expiry readiness waiter. Hold both
                    // providers at the existing worktree hard gate, then cancel this exact task
                    // before releasing only this side for its controlled native transport call.
                    fixture.session.oversight.pendingAutoWake?.task?.cancel()
                    fixture.session.isPreparingInitialWorktree = false
                    guard fixture.session.oversight.pendingAutoWake != nil else {
                        return XCTFail("Failing ring has no reserved attempt at round=\(round) provider=\(fixture.session.selectedAgent) freshOrdinary=\(String(describing: notices.entries.first?.ordinaryThrough))")
                    }
                    let claim = try reserveQuietWake(fixture)
                    let before = try XCTUnwrap(fixture.session.quietLedger.facts)
                    let callCount = calls.count
                    let owner = fixture.session.selectedAgent == .codexExec
                        ? fixture.session.beginRunAttempt(source: "test.E.failing.codex")
                        : try beginAndAcquireQuietWake(fixture, claim: claim)
                    fixture.session.runState = .running
                    try await AsyncTestWait.waitUntil("failing ring running frame accepted") { bridge.test_pairedRunStatus(for: endpoint) == .running }
                    if fixture.session.selectedAgent == .claudeCode {
                        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
                        let outcome = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(session: fixture.session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false)
                        guard case .failed = outcome else { return XCTFail("Expected physical Claude failure, got \(outcome)") }
                        _ = await AgentRunTerminalCommitBarrier().commit(.init(
                            binding: terminal.hooks.bindTerminalSession(fixture.session), ownership: owner, expectedRunID: fixture.session.runID,
                            terminalState: .failed, source: "test.E.claude.sendFailure", attachmentDisposition: .restoreToPending,
                            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false
                        ))
                    } else {
                        // The real Codex error path owns failed terminalization; do not insert a
                        // final row or mint a second completion on behalf of the fake provider.
                        fixture.session.runState = .completed
                        let outcome = await fixture.viewModel.test_codexCoordinator.sendCodexNativeMessage(session: fixture.session, text: "", attachments: [])
                        guard case .failed = outcome else { return XCTFail("Expected physical Codex failure, got \(outcome)") }
                    }
                    XCTAssertEqual(calls.count, callCount + 1, "Exactly one physical fake call per failed producer in this no-retry scenario")
                    let after = try XCTUnwrap(fixture.session.quietLedger.facts)
                    XCTAssertEqual(after.settledThrough, before.settledThrough + 1)
                    XCTAssertEqual(after.ordinaryThrough, after.settledThrough)
                    XCTAssertNil(fixture.session.activeRunOwnership)
                    try await AsyncTestWait.waitUntil("failing ring exact new paired ordinary closure accepted") {
                        bridge.test_pairedRunStatus(for: endpoint) == .idle && bridge.test_pairedRunFacts(for: endpoint) == after
                    }
                    await bridge.test_settleTargetPublications()
                    await bridge.test_refreshStatus(sessionIDs: [a.sessionID, b.sessionID])
                    // Disable this side's automatic reservation while its peer's NEW ordinary
                    // closure arrives. It is re-enabled at the next controlled interval boundary.
                    fixture.session.oversight.autoWakeOnUpdates = false
                    fixture.session.isPreparingInitialWorktree = true
                    for observer in [a, b] {
                        let queue = try XCTUnwrap(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID])
                        maxQueueRows = max(maxQueueRows, queue.entries.count)
                        XCTAssertLessThanOrEqual(queue.entries.count, 1, "One linked target keeps one coalesced row, not one row per failure")
                        XCTAssertEqual(queue.unacknowledgedOverflowCount, 0)
                        XCTAssertFalse(queue.entries.isEmpty, "No acceptance means no invented delivery/payment")
                    }
                }
            }
            for provider in ["Claude", "Codex"] {
                let times = calls.filter { $0.provider == provider }.map(\.seconds)
                XCTAssertEqual(times, (0 ..< 8).map { TimeInterval($0 * 300) })
                for (prior, next) in zip(times, times.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(next - prior, 300)
                }
            }
            for fixture in [a, b] {
                XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 9, ordinaryThrough: 9))
                XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            }
            print("QUIET_C5_FAILING_RING rounds=8 physicalFailures=\(calls.count) providerCallSeconds=\(calls.map { "\($0.provider):\(Int($0.seconds))" }.joined(separator: ",")) minSameProviderIntervalSeconds=300 maxQueueRows=\(maxQueueRows) overflow=0 finalOrdinaryThrough=9,9 policy=existing-no-universal-damping")
            return
        }
        for fixture in [a, b] {
            fixture.session.isPreparingInitialWorktree = false
            fixture.session.oversight.autoWakeOnUpdates = true
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            try fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(XCTUnwrap(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]), to: endpoint)
            let claim = try reserveQuietWake(fixture)
            XCTAssertTrue(claim.routineQuietCheckIn)
            // Codex chooses start-vs-steer from the current run state. Let its real start adapter
            // acquire the first physical fence while the observer is idle, not a fabricated active
            // turn lacking an authoritative provider turn identity.
            let owner = fixture.session.selectedAgent == .codexExec
                ? fixture.session.beginRunAttempt(source: "test.E.codex.physical")
                : try beginAndAcquireQuietWake(fixture, claim: claim)
            if fixture.session.selectedAgent == .claudeCode {
                let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
                _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(session: fixture.session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false)
            } else {
                let outcome = await fixture.viewModel.test_codexCoordinator.sendCodexNativeMessage(session: fixture.session, text: "", attachments: [])
                guard outcome == .sent else { return XCTFail("Ring Codex fake did not accept: \(outcome)") }
            }
            guard let wakeID = claim.dispatchID.autoWakeID, fixture.session.liveItemIDs.contains(wakeID) else {
                return XCTFail("Ring cannot pay a receipt without actual native acceptance")
            }
            try await AsyncTestWait.waitUntil("ring quiet running frame accepted") { bridge.test_pairedRunStatus(for: endpoint) == .running }
            try bridge.applyPassiveMonitorNoticeReceipt(XCTUnwrap(claim.passive?.receipt), observerEndpoint: endpoint)
            try await finish(fixture, owner)
        }
        let claudeMessages = await a.nativeController.sentMessages
        XCTAssertEqual(claudeMessages.count, 1)
        XCTAssertEqual(codex.startedTurns.count, 1)
        XCTAssertTrue(try XCTUnwrap(claudeMessages.first).contains("Nothing needed? Reply [ack]."))
        XCTAssertFalse(try XCTUnwrap(codex.startedTurns.first).contains("Nothing needed? Reply [ack]."))
        for _ in 0 ..< 16 {
            await bridge.test_refreshStatus(sessionIDs: [a.sessionID, b.sessionID])
        }
        for fixture in [a, b] {
            XCTAssertEqual(fixture.session.quietLedger.facts, .init(settledThrough: 2, ordinaryThrough: 1))
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
            XCTAssertTrue(try XCTUnwrap(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]).entries.isEmpty)
        }
        print("QUIET_C5_RING providers=Claude,Codex ordinarySeedAttempts=2 acceptedPhysical=2 repeatedPasses=16 finalQueues=0")
    }

    func testEPersistentNativeFailureKeepsQueueAndIntervalAndHardGatesWithoutNewBackoff() async throws {
        let fixture = try makeFixture()
        fixture.session.selectedAgent = .claudeCode
        try installQuietNativeRoute(fixture)
        let clock = installSnoozeClock(fixture)
        fixture.session.oversight.routineWakeIntervalEnabled = true
        fixture.session.oversight.routineWakeIntervalSeconds = 300
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let claim = try reserveQuietWake(fixture)
        let owner = try beginAndAcquireQuietWake(fixture, claim: claim)
        await fixture.nativeController.setFailSendAfterRecord(true)
        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(fixture.session.runID))
        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(session: fixture.session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false)
        let sendsAfterFailure = await fixture.nativeController.sentMessages.count
        XCTAssertGreaterThan(sendsAfterFailure, 0)
        let suppressed = try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
        fixture.session.runState = .completed
        for _ in 0 ..< 100 {
            clock.advanceWithoutFiring(seconds: 6)
            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        }
        let afterTicks = await fixture.nativeController.sentMessages.count
        XCTAssertEqual(afterTicks, sendsAfterFailure)
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, suppressed)
        XCTAssertFalse(try XCTUnwrap(fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]).entries.isEmpty, "Failure pays nothing and expiry does not erase queued work")
        fixture.session.isPreparingInitialWorktree = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 1, metadataSequenceOffset: 1)
        try await AsyncTestWait.waitUntil("new edge waits on the existing hard readiness gate") {
            fixture.session.oversight.pendingAutoWake?.phase == .awaitingSettlement
        }
        let sendsWhileHardBlocked = await fixture.nativeController.sentMessages.count
        XCTAssertEqual(sendsWhileHardBlocked, sendsAfterFailure)
        fixture.session.oversight.pendingAutoWake?.task?.cancel()
        fixture.session.isPreparingInitialWorktree = false
        let successor = try reserveQuietWake(fixture)
        XCTAssertNotEqual(successor.dispatchID, claim.dispatchID)
        XCTAssertEqual(fixture.session.oversight.routineWakeIntervalSeconds, 300)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(for: fixture.session, dispatchID: successor.dispatchID)
        print("QUIET_C5_FAILURE_CADENCE ticks=100 advancedSeconds=600 extraPhysicalRetries=0 queuePreserved=true existingIntervalSeconds=300 hardGatePreserved=true")
    }
}

extension AgentSessionLinkAutoWakeTests {
    func testSameValuedAuthoritativeQueueStillRedrivesObserverReadinessAfterHardGate() async throws {
        let observer = try makeFixture()
        observer.session.selectedAgent = .claudeCode
        try installQuietNativeRoute(observer)
        let target = try makeFixture(fenceProviderLaunch: true, windowID: 2)
        let host = LiveWindowEndpointHost()
        host.register(observer.viewModel, windowID: 1)
        host.register(target.viewModel, windowID: 2)
        let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: .distantPast))
        let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
        guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: target.sessionID.uuidString) else { return XCTFail("readiness grant failed") }
        // The link-time seed carries no paired proof, and first paired facts baseline a new lane.
        // Settle the lane's paired resting baseline before the target runs; otherwise whether the
        // owed run is visible depends on whether a refresh happened to sample it mid-run.
        var targetSamples: [AgentSessionLinkPassiveStatusNotices.Sample] = []
        bridge.test_onPassiveSample = { sample in
            if sample.targetSessionID == target.sessionID { targetSamples.append(sample) }
        }
        await bridge.test_settleTargetPublications()
        await bridge.test_refreshStatus(sessionIDs: [observer.sessionID])
        XCTAssertEqual(targetSamples.last?.status, .idle)
        XCTAssertEqual(targetSamples.last?.runFacts, .zero, "the observer must hold the lane's paired resting baseline")
        observer.session.oversight.autoWakeOnUpdates = true
        observer.session.isPreparingInitialWorktree = true
        let replay = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        _ = await AgentQuietCheckInReplay.settle(target.session, harness: replay, form: 3, wakeID: UUID())
        await bridge.test_settleTargetPublications()
        await bridge.test_refreshStatus(sessionIDs: [observer.sessionID])
        let owed = try XCTUnwrap(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID])
        XCTAssertTrue(owed.entries.contains(where: \.isRoutineWakeEligible))
        try await AsyncTestWait.waitUntil("owned readiness waiter is subscribed") {
            observer.session.oversight.pendingAutoWake?.phase == .awaitingSettlement
        }
        let reserved = try XCTUnwrap(observer.session.oversight.pendingAutoWake)
        let beforeReady = await observer.nativeController.sentMessages.count
        XCTAssertEqual(beforeReady, 0)
        observer.session.isPreparingInitialWorktree = false
        // No passive publication from the test. The ordinary indexed authoritative refresh used to
        // provide the admission hint even when the target's queue/display value remained identical.
        await bridge.test_refreshStatus(sessionIDs: [observer.sessionID])
        XCTAssertEqual(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID], owed)
        try await AsyncTestWait.waitUntil("same-valued queue's owned readiness waiter admits provider preparation") {
            observer.session.oversight.pendingAutoWake?.phase == .preparingDispatch
        }
        XCTAssertEqual(observer.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(observer.viewModel.agentSessionLinkPassiveNoticesBySessionID[observer.sessionID], owed)
        // Preparation admission is the assertion, not fabricated transport acceptance/payment.
        // The shared native adapter ring separately proves actual accepted physical handoffs.
        observer.session.oversight.pendingAutoWake?.task?.cancel()
        observer.viewModel.cancelAgentSessionLinkAutoWake(for: reserved.observerEndpoint, reason: .settingDisabled)
    }
}
