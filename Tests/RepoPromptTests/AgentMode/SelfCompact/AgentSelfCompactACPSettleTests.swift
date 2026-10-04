@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfCompactACPSettleTests: XCTestCase {
    private let note = "alpha\nβeta"

    func testInstantReturnAndVouchedDropAreShapeChecksOnly() {
        XCTAssertTrue(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: 0))
        XCTAssertTrue(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .milliseconds(1999), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .seconds(2), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .seconds(-1), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: nil, assistantOrToolRowCount: 0))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: nil))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: 1))

        XCTAssertTrue(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 99))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 100))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 101))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: nil, current: 1))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: nil))
    }

    func testInstantEmptyTurnEntersNinetySecondSettleAndTimeoutParksUnverified() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(50))
        fake.settle(coordinator, rows: 0, vouch: nil)
        await drain()
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertNil(fake.state.status?.outcome)
        XCTAssertNil(fake.state.status?.completionVerified)
        XCTAssertTrue(fake.state.blocksOverseerDelivery)
        XCTAssertTrue(fake.state.blocksAutomaticWake)
        XCTAssertTrue(fake.slept.contains(.seconds(90)))
        XCTAssertEqual(fake.dispatchCount, 0)

        await fake.finish()
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.state.parkedNote?.frame, frame)
        XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
        XCTAssertEqual(fake.state.status?.completionVerified, false)
        XCTAssertEqual(fake.state.status?.noteDelivery, .parked)
        XCTAssertEqual(fake.state.status?.recoveryNote, note)
        XCTAssertFalse(fake.state.blocksOverseerDelivery)
        XCTAssertTrue(fake.state.blocksAutomaticWake)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertEqual(fake.providerBoundTexts, [])
    }

    func testVouchedDropDuringHoldSendsTheFramedNoteOnce() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(20))
        fake.settle(coordinator, rows: 0, vouch: nil)
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)

        coordinator.noteVouchedContextCount(40)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 1)
        XCTAssertEqual(fake.providerBoundTexts, [AgentSelfCompactNoteEnvelope.frame(note)])
        XCTAssertEqual(fake.state.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fake.state.latest?.completionVerified, true)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .accepted)
        XCTAssertNil(fake.state.active)

        coordinator.noteVouchedContextCount(1)
        await fake.finish()
        XCTAssertEqual(fake.dispatchCount, 1)
    }

    func testVouchedDropAlreadyPresentSkipsTheHold() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(20))
        fake.settle(coordinator, rows: 0, vouch: 99)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 1)
        XCTAssertEqual(fake.providerBoundTexts, [AgentSelfCompactNoteEnvelope.frame(note)])
        XCTAssertFalse(fake.slept.contains(.seconds(90)))
        XCTAssertEqual(fake.state.latest?.completionVerified, true)
        await fake.finish()
    }

    func testEqualOrHigherVouchDoesNotLeaveTheHold() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(10))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.noteVouchedContextCount(100)
        coordinator.noteVouchedContextCount(150)
        coordinator.noteVouchedContextCount(nil)
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.dispatchCount, 0)
    }

    func testCompletedTurnWithoutInstantShapeParksUnverifiedImmediately() async {
        let cases: [(Duration, Int?)] = [
            (.seconds(2), 0),
            (.milliseconds(1999), 1),
            (.milliseconds(10), nil),
            (.seconds(-1), 0)
        ]
        for (elapsed, rows) in cases {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator, tokensBefore: 100)
            fake.advance(elapsed)
            fake.settle(coordinator, rows: rows, vouch: 100)
            await drain()
            XCTAssertEqual(fake.state.active?.phase, .parked, "elapsed \(elapsed) rows \(String(describing: rows))")
            XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
            XCTAssertFalse(fake.slept.contains(.seconds(90)))
            XCTAssertEqual(fake.dispatchCount, 0)
            XCTAssertNotEqual(fake.state.status?.completionVerified, true)
            XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
            await fake.finish()
        }
    }

    func testMissingBindInstantIsNotVerified() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        let id = fake.arm(tokensBefore: 80)
        fake.state.active?.compactRunID = fake.compactRunID
        fake.state.active?.compactRunAttemptID = fake.compactAttemptID
        _ = id
        fake.settle(coordinator, rows: 0, vouch: nil)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertFalse(fake.state.latest?.completionVerified == true)
        await fake.finish()
    }

    func testLateVouchOrCompletionAfterTimeoutDoesNotSend() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        coordinator.noteVouchedContextCount(1)
        fake.settle(coordinator, rows: 0, vouch: 1)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
    }

    func testSupersedeDuringHoldParksWithoutUnverifiedAndCanCarryTheNote() async throws {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.supersedeForOrdinaryInput()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertNil(fake.state.active?.acpCompletionUnverified)
        XCTAssertEqual(fake.dispatchCount, 0)
        let parked = try XCTUnwrap(fake.state.parkedNote)
        XCTAssertEqual(parked.frame, AgentSelfCompactNoteEnvelope.frame(note))
        XCTAssertTrue(fake.state.noteWillAttempt(parked.dispatchID))
        XCTAssertTrue(fake.state.noteAccepted(parked.dispatchID))
        XCTAssertEqual(fake.state.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .prepended)
        XCTAssertEqual(fake.state.latest?.completionVerified, false)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
    }

    func testOrdinarySendAfterUnverifiedParkCarriesTheFrameAndStaysUnverified() async throws {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.seconds(3))
        fake.settle(coordinator, rows: 2, vouch: nil)
        let parked = try XCTUnwrap(fake.state.parkedNote)
        XCTAssertTrue(fake.state.noteWillAttempt(parked.dispatchID))
        XCTAssertTrue(fake.state.noteAccepted(parked.dispatchID))
        XCTAssertEqual(fake.state.latest?.outcome, .completionUnverified)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .prepended)
        XCTAssertEqual(fake.state.latest?.completionVerified, false)
        XCTAssertEqual(fake.state.latest?.recoveryNote, note)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
    }

    func testFailedOrCancelledACPTurnDoesNotSendOrPark() async {
        for status in [AgentSessionRunState.failed, .cancelled] {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator)
            fake.advance(.milliseconds(1))
            fake.settle(coordinator, status: status, rows: 0, vouch: 1)
            XCTAssertNil(fake.state.active)
            XCTAssertEqual(fake.state.latest?.outcome, .failed)
            XCTAssertEqual(fake.state.latest?.noteDelivery, .notSent)
            XCTAssertEqual(fake.state.latest?.completionVerified, false)
            XCTAssertEqual(fake.dispatchCount, 0)
            await fake.finish()
        }
    }

    func testOnlyAcceptedCorrelatedCompactTerminalMayConsumeACPRowBaseline() {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        let matched = fake.revision()
        XCTAssertTrue(coordinator.acceptsCompactTerminal(matched, publication: .accepted(successorEpoch: nil)))
        XCTAssertFalse(coordinator.acceptsCompactTerminal(
            fake.revision(runAttemptID: UUID()), publication: .accepted(successorEpoch: nil)
        ))
        XCTAssertFalse(coordinator.acceptsCompactTerminal(matched, publication: .rejected(reason: "not accepted")))
        XCTAssertFalse(coordinator.acceptsCompactTerminal(matched, publication: .stale))
        XCTAssertNotNil(fake.state.active)
        coordinator.cancelRuntimeWork()
    }

    func testStalePublicationAndSuccessorDoNotManufactureAPrompt() async {
        let stale = Fake()
        let staleCoordinator = stale.coordinator()
        stale.bind(staleCoordinator)
        stale.settle(staleCoordinator, publication: .stale)
        XCTAssertNil(stale.state.active)
        XCTAssertEqual(stale.state.latest?.outcome, .completionUnverified)
        XCTAssertEqual(stale.state.latest?.noteDelivery, .notSent)
        XCTAssertEqual(stale.dispatchCount, 0)
        await stale.finish()

        let successor = Fake()
        let successorCoordinator = successor.coordinator()
        successor.bind(successorCoordinator)
        successor.settle(successorCoordinator, rows: 0, vouch: 1, successor: .steering)
        XCTAssertEqual(successor.state.active?.phase, .parked)
        XCTAssertNil(successor.state.active?.acpCompletionUnverified)
        XCTAssertEqual(successor.dispatchCount, 0)
        await successor.finish()
    }

    func testCancelDuringHoldDoesNotParkOrDispatchWhenTheSleeperResumes() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.cancelRuntimeWork()
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertNil(fake.state.active?.acpCompletionUnverified)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertNil(fake.state.latest)
    }

    func testEveryRestoredPhaseIsRecoveryRequired() {
        for phase in AgentSelfCompactAttempt.Phase.allCases {
            var state = AgentSelfCompactState()
            _ = state.reserve(note: note, idempotencyKey: "key-\(phase.rawValue)")
            state.active?.phase = phase
            state.active?.acpCompletionUnverified = true
            XCTAssertTrue(state.reconcileDecodedRecord(), phase.rawValue)
            XCTAssertNil(state.active)
            XCTAssertEqual(state.latest?.outcome, .recoveryRequired)
            XCTAssertEqual(state.latest?.completionVerified, false)
            XCTAssertEqual(state.latest?.recoveryNote, note)
            XCTAssertFalse(state.blocksOverseerDelivery)
            XCTAssertFalse(state.blocksAutomaticWake)
        }
    }

    func testParkedPrefixCarriesTheFrameOnceAndExactNoteIsUnmodified() throws {
        let session = AgentTabSession(tabID: UUID())
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "carry")
        state.active?.phase = .parked
        state.active?.acpCompletionUnverified = true
        session.selfCompactState = state

        let ordinary = AgentSelfCompactParkedPrefix.prepare("next turn", session: session, scheduleSave: {})
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        XCTAssertEqual(ordinary.text, frame + "\n\nnext turn")
        XCTAssertFalse(ordinary.exactNote)
        let dispatchID = try XCTUnwrap(ordinary.dispatchID)
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAttempted(dispatchID, session: session))
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session))
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .completionUnverified)
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
        XCTAssertEqual(session.selfCompactState.latest?.completionVerified, false)
        XCTAssertTrue(session.items.contains { $0.kind == .system && !$0.text.contains(note) && !$0.text.contains("<note>") })

        var exactState = AgentSelfCompactState()
        _ = exactState.reserve(note: note, idempotencyKey: "exact")
        exactState.active?.phase = .dispatchingNote
        session.selfCompactState = exactState
        let exact = AgentSelfCompactParkedPrefix.prepare(frame, session: session, scheduleSave: {})
        XCTAssertTrue(exact.exactNote)
        XCTAssertEqual(exact.text, frame)
    }

    func testSupersededDedicatedACPNoteDoesNotSendItsFrameAfterLocalAcceptance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfCompactACPRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: directory)
        let gate = try AgentSessionLinkACPResponseGate(directory: directory)
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .openCode,
            commandPath: scriptURL.path,
            environment: ["ACP_HOLD_METHOD": "session/set_config_option", "ACP_RESPONSE_GATE": gate.path]
        )
        let harness = AgentSessionLinkRunnerHarness(
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acpProviderFactory: { _, _ in provider },
            workspacePath: directory.path
        )
        let session = harness.makeSession(agent: .openCode)
        let runner = ACPIntegratedAgentModeRunner(
            hooks: harness.hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
            toolTrackingHooks: .noOp,
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            }
        )
        let initialRequest = ACPRunRequest(
            agentKind: .openCode, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        await runner.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: "prime", initialMessageForRun: "prime", attachments: [],
            runRequest: initialRequest,
            makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
        )
        await session.agentTask?.value
        XCTAssertEqual(provider.promptedMessages.map(\.userMessage), ["prime"])

        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "raced-note")
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        let noteID = try XCTUnwrap(AgentSelfCompactParkedPrefix.preparedDedicatedNoteID(frame, session: session))
        session.runState = .idle
        let noteRequest = ACPRunRequest(
            agentKind: .openCode, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil,
            sessionModeID: "auto_edit"
        )
        await runner.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: frame, initialMessageForRun: frame, attachments: [],
            runRequest: noteRequest,
            makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
        )
        // The config RPC suspends after this run captured its dedicated note ID but before
        // runPromptTurn re-reads the carry. Model an ordinary local send that has accepted the note.
        try await gate.waitUntilEntered()
        XCTAssertTrue(AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
            noteID, session: session, scheduleSave: {}
        ))
        let local = AgentSelfCompactParkedPrefix.prepare("accepted local turn", session: session, scheduleSave: {})
        XCTAssertEqual(local.text, frame + "\n\naccepted local turn")
        let localDispatchID = try XCTUnwrap(local.dispatchID)
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAttempted(localDispatchID, session: session))
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAccepted(localDispatchID, session: session))
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)

        gate.release()
        await session.agentTask?.value
        XCTAssertEqual(provider.promptedMessages.map(\.userMessage), ["prime"])
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
    }

    func testOnlyAVerifiedOwnContinuationNotePassesTheACPBackgroundCompactionHold() {
        let session = AgentTabSession(tabID: UUID())
        session.hasLoadedPersistedState = true
        session.beginACPBackgroundCompactionSettle(duration: 90)
        defer { session.endACPBackgroundCompactionSettle() }
        var attempt = AgentSelfCompactAttempt(
            idempotencyKey: "background-hold", note: "Continue the current task.", phase: .noteDispatchPending
        )
        func noteSnapshot(for requestID: UUID) -> AgentSessionLinkDeliveryReadiness.Snapshot {
            session.selfCompactState = AgentSelfCompactState(active: attempt)
            return AgentModeViewModel.agentSelfCompactNoteReadinessSnapshot(session: session, requestID: requestID)
        }

        // Unverified completion: the provider may still be compacting, so the note waits too.
        XCTAssertTrue(noteSnapshot(for: attempt.id).backgroundCompactionSettling)
        attempt.compactTurnSucceeded = true
        attempt.acpCompletionUnverified = true
        XCTAssertTrue(noteSnapshot(for: attempt.id).backgroundCompactionSettling)

        // Verified completion (vouched drop): this request's own note may start the next turn.
        attempt.acpCompletionUnverified = nil
        let verified = noteSnapshot(for: attempt.id)
        XCTAssertFalse(verified.backgroundCompactionSettling)
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: verified), .ready)

        // Nobody else inherits the exemption: another request's note and ordinary overseer delivery.
        XCTAssertTrue(noteSnapshot(for: UUID()).backgroundCompactionSettling)
        let overseer = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        XCTAssertTrue(overseer.backgroundCompactionSettling)
        XCTAssertNotEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: overseer), .ready)
    }

    func testStaleDedicatedACPNoteCannotReparkAnOrdinarySendInFlight() throws {
        let session = AgentTabSession(tabID: UUID())
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "ordinary-in-flight")
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        let dedicatedID = try XCTUnwrap(AgentSelfCompactParkedPrefix.preparedDedicatedNoteID(frame, session: session))
        XCTAssertTrue(AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
            dedicatedID, session: session, scheduleSave: {}
        ))
        let ordinary = AgentSelfCompactParkedPrefix.prepare("next turn", session: session, scheduleSave: {})
        XCTAssertEqual(ordinary.text, frame + "\n\nnext turn")
        let ordinaryID = try XCTUnwrap(ordinary.dispatchID)
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAttempted(ordinaryID, session: session))

        // The dedicated sender resumed after the ordinary sender entered transport. Its stale
        // pre-transport cleanup must not clear the ordinary sender's one-shot marker.
        AgentSelfCompactParkedPrefix.markNotAttempted(dedicatedID, session: session)
        XCTAssertEqual(session.selfCompactState.active?.phase, .dispatchingNote)
        XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, true)
        XCTAssertNil(session.selfCompactState.parkedNote)
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAccepted(ordinaryID, session: session))
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
    }

    func testUnverifiedACPNoteTransportFailureDoesNotClaimVerifiedCompaction() throws {
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "unverified-failure")
        let attempt = try XCTUnwrap(state.active)
        state.active?.phase = .parked
        state.active?.acpCompletionUnverified = true
        let dispatchID = AgentSelfCompactionDispatchID(requestID: attempt.id, stage: .note)
        XCTAssertTrue(state.noteWillAttempt(dispatchID))
        XCTAssertTrue(state.noteTransportFailed(dispatchID))
        XCTAssertEqual(state.latest?.outcome, .deliveryUnknown)
        XCTAssertEqual(state.latest?.noteDelivery, .deliveryUnknown)
        XCTAssertEqual(state.latest?.completionVerified, false)
        XCTAssertEqual(state.latest?.recoveryNote, note)
    }

    func testUnattemptedACPNoteStartupReparksAndSaves() throws {
        let session = AgentTabSession(tabID: UUID())
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "startup")
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        session.isDirty = false
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        let dispatchID = try XCTUnwrap(AgentSelfCompactParkedPrefix.preparedDedicatedNoteID(frame, session: session))
        var saves = 0
        XCTAssertTrue(AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
            dispatchID, session: session, scheduleSave: { saves += 1 }
        ))
        XCTAssertEqual(session.selfCompactState.active?.phase, .parked)
        XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, false)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
            dispatchID, session: session, scheduleSave: { saves += 1 }
        ))
        XCTAssertEqual(saves, 1)

        state = session.selfCompactState
        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        _ = state.reserve(note: "newer", idempotencyKey: "newer")
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        XCTAssertFalse(AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
            dispatchID, session: session, scheduleSave: { saves += 1 }
        ))
        XCTAssertEqual(session.selfCompactState.active?.phase, .dispatchingNote)
        XCTAssertEqual(saves, 1)
    }

    func testStaleParkedNoteCancellationSchedulesPersistence() {
        let session = AgentTabSession(tabID: UUID())
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "stale", owner: Fake().owner)
        state.active?.phase = .parked
        session.selfCompactState = state
        session.isDirty = false
        var saves = 0
        let carry = AgentSelfCompactParkedPrefix.prepare("next turn", session: session) { saves += 1 }
        XCTAssertEqual(carry.text, "next turn")
        XCTAssertNil(carry.dispatchID)
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .cancelled)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(saves, 1)
    }

    func testEightKilobyteNoteSurvivesRepeatedInstantReturnsInsideTheWallBudget() async {
        let body = String(repeating: "n", count: 8190) + "\nZ"
        XCTAssertEqual(body.utf8.count, 8192)
        let frame = AgentSelfCompactNoteEnvelope.frame(body)
        let started = ContinuousClock.now
        for index in 0 ..< 16 {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator, note: body, tokensBefore: 500)
            fake.advance(.milliseconds(25))
            fake.settle(coordinator, rows: 0, vouch: nil)
            await drain()
            XCTAssertEqual(fake.state.active?.phase, .acpSettling)
            XCTAssertTrue(fake.slept.contains(.seconds(90)))
            await fake.finish()
            XCTAssertEqual(fake.state.parkedNote?.frame, frame)
            XCTAssertEqual(fake.dispatchCount, 0)
            XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
            XCTAssertEqual(fake.state.status?.completionVerified, false)
            let same = fake.state.reserve(note: body, idempotencyKey: "key", owner: fake.owner)
            guard case .duplicate = same else {
                XCTFail("iteration \(index) expected duplicate, got \(same)")
                return
            }
            XCTAssertEqual(
                fake.state.reserve(note: body, idempotencyKey: "other-key", owner: fake.owner),
                .alreadyPending
            )
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
    }

    private func drain() async {
        for _ in 0 ..< 30 {
            await Task.yield()
        }
    }

    @MainActor private final class Fake {
        var state = AgentSelfCompactState()
        var dispatchCount = 0
        var providerBoundTexts: [String] = []
        var pendingSleeps: [CheckedContinuation<Void, Never>] = []
        var slept: [Duration] = []
        var instant = ContinuousClock.now
        let owner = AgentSelfCompactOwner(
            windowID: 1, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1,
            runID: UUID(), runAttemptID: UUID()
        )
        let compactRunID = UUID()
        let compactAttemptID = UUID()

        func arm(note: String = "alpha\nβeta", tokensBefore: Int? = 100) -> UUID {
            _ = state.reserve(note: note, idempotencyKey: "key", owner: owner)
            state.active?.admittedSupport = .acpAdvertisedCommand
            state.active?.phase = .dispatchingCompact
            state.active?.usedTokensBeforeCompact = tokensBefore
            return state.active!.id
        }

        func coordinator() -> AgentSelfCompactNativeCompletionCoordinator {
            AgentSelfCompactNativeCompletionCoordinator(
                load: { self.state },
                store: { self.state = $0 },
                isCurrentOwner: { _ in true },
                dispatchNote: { requestID, admissible in
                    guard admissible(), let note = self.state.active?.note else { return false }
                    self.dispatchCount += 1
                    self.providerBoundTexts.append(AgentSelfCompactNoteEnvelope.frame(note))
                    self.state.active?.phase = .dispatchingNote
                    let dispatchID = AgentSelfCompactionDispatchID(requestID: requestID, stage: .note)
                    XCTAssertTrue(self.state.noteWillAttempt(dispatchID))
                    XCTAssertTrue(self.state.noteAccepted(dispatchID))
                    return true
                },
                sleep: { duration in
                    self.slept.append(duration)
                    await withCheckedContinuation { continuation in
                        self.pendingSleeps.append(continuation)
                    }
                },
                now: { self.instant }
            )
        }

        func bind(
            _ coordinator: AgentSelfCompactNativeCompletionCoordinator,
            note: String = "alpha\nβeta",
            tokensBefore: Int? = 100
        ) {
            let id = arm(note: note, tokensBefore: tokensBefore)
            XCTAssertTrue(coordinator.bindCompact(
                .init(requestID: id, stage: .compact),
                runID: compactRunID,
                runAttemptID: compactAttemptID
            ))
        }

        func advance(_ duration: Duration) {
            instant = instant.advanced(by: duration)
        }

        func revision(
            status: AgentSessionRunState = .completed,
            successor: AgentRunEpochTransitionKind? = nil,
            runAttemptID: UUID? = nil
        ) -> AgentRunTerminalCommitRevision {
            AgentRunTerminalCommitRevision(
                commitID: UUID(),
                ownership: AgentRunOwnership(
                    attemptID: runAttemptID ?? compactAttemptID,
                    binding: AgentRunBindingIdentity(tabID: owner.tabID, persistentSessionID: owner.sessionID)
                ),
                terminalState: status,
                failureReason: nil,
                expectedRunID: compactRunID,
                sourceItemsRevision: 0,
                assistantDeltaFlushGeneration: 0,
                providerDrainGeneration: 0,
                mcpPublicationEnvelope: nil,
                successorKind: successor,
                providerSuccessorID: nil
            )
        }

        func settle(
            _ coordinator: AgentSelfCompactNativeCompletionCoordinator,
            status: AgentSessionRunState = .completed,
            rows: Int? = 0,
            vouch: Int? = nil,
            successor: AgentRunEpochTransitionKind? = nil,
            publication: AgentRunTerminalPublicationResult = .accepted(successorEpoch: nil)
        ) {
            coordinator.compactTurnSettled(
                revision: revision(status: status, successor: successor),
                publication: publication,
                teardownSettled: { true },
                assistantOrToolRowCount: rows,
                vouchedTokenCount: vouch
            )
        }

        func finish() async {
            for _ in 0 ..< 30 {
                await Task.yield()
            }
            let sleepers = pendingSleeps
            pendingSleeps.removeAll()
            sleepers.forEach { $0.resume() }
            for _ in 0 ..< 30 {
                await Task.yield()
            }
        }
    }
}
