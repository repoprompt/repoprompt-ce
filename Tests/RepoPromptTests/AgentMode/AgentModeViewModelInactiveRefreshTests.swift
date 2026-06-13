import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeViewModelInactiveRefreshTests: XCTestCase {
    func testActiveRefreshCompactsSummaryOnlyToolResultSourceWhilePreservingRawRenderPayload() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        let invocationID = UUID()
        let marker = "RAW_PAYLOAD_MARKER_\(UUID().uuidString)"
        let rawResult = jsonString([
            "status": "success",
            "edits_requested": 1,
            "edits_applied": 1,
            "review_status": "approved",
            "raw_output": String(repeating: marker, count: 4),
            "diffs": [["path": "File.swift", "diff": String(repeating: marker, count: 4)]]
        ])
        let toolResult = AgentChatItem.toolResult(
            name: "apply_edits",
            invocationID: invocationID,
            resultJSON: rawResult,
            sequenceIndex: 2
        )
        session.replaceItems([
            .user("Start", sequenceIndex: 0),
            .toolCall(name: "apply_edits", invocationID: invocationID, argsJSON: #"{"path":"File.swift"}"#, sequenceIndex: 1),
            toolResult,
            .assistant("Done", sequenceIndex: 3)
        ])

        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)

        let compactedSourceResult = try XCTUnwrap(session.items.first(where: { $0.id == toolResult.id }))
        XCTAssertFalse(compactedSourceResult.toolResultJSON?.contains(marker) ?? false)
        XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: compactedSourceResult.toolResultJSON ?? ""))

        let projectedResult = try XCTUnwrap(session.workingTranscriptProjection.workingRows.first(where: { $0.id == toolResult.id }))
        XCTAssertFalse(projectedResult.toolResultJSON?.contains(marker) ?? false)
        XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: projectedResult.toolResultJSON ?? ""))

        let retainedRawPayload = try XCTUnwrap(viewModel.rawToolResultPayloadForRendering(tabID: tabID, itemID: toolResult.id))
        XCTAssertTrue(retainedRawPayload.contains(marker))
        XCTAssertGreaterThan(session.ephemeralToolResultPayloadRevisionByItemID[toolResult.id] ?? 0, 0)
        XCTAssertGreaterThan(viewModel.activeTranscriptPresentation.rawToolResultPayloadRenderRevision, 0)
    }

    func testRefreshingInactiveSessionDoesNotClobberActivePresentation() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let activeSession = await viewModel.ensureSessionReady(tabID: activeTabID)
        let inactiveSession = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        activeSession.replaceItems(makeTranscriptItems(prefix: "active", turnCount: 2))
        inactiveSession.replaceItems(makeTranscriptItems(prefix: "inactive", turnCount: 2))

        viewModel.refreshDerivedTranscriptState(for: activeSession)
        viewModel.applySessionToBindings(activeSession)
        viewModel.refreshDerivedTranscriptState(for: inactiveSession)

        let activeSnapshot = viewModel.activeTranscriptPresentation
        let inactiveBuildCount = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount

        inactiveSession.appendItem(.user("background mutation", sequenceIndex: inactiveSession.nextSequenceIndex))
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: inactiveTabID)

        XCTAssertEqual(viewModel.activeTranscriptPresentation.tabID, activeTabID)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows, activeSnapshot.visibleRows)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.workingRows, activeSnapshot.workingRows)
        XCTAssertGreaterThan(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, inactiveBuildCount)
        XCTAssertEqual(inactiveSession.workingTranscriptProjection.workingRows.last?.text, "background mutation")
        XCTAssertEqual(inactiveSession.derivedTranscriptSyncState?.sourceItemsRevision, inactiveSession.sourceItemsRevision)
        XCTAssertTrue(inactiveSession.isDirty)

        let buildCountAfterBackgroundRefresh = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount
        viewModel.test_setCurrentTabIDOverride(inactiveTabID)
        viewModel.applySessionToBindings(inactiveSession)

        XCTAssertEqual(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterBackgroundRefresh)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.tabID, inactiveTabID)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows, inactiveSession.workingTranscriptProjection.workingRows)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "background mutation")
    }

    func testScheduledLiveRefreshBuildsWhenSessionTurnsInactive() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let otherTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: activeTabID)
        session.setItemsSilently([.user("Initial", sequenceIndex: 0)], reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        let activeSnapshot = viewModel.activeTranscriptPresentation
        let buildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

        session.appendItem(.assistant("Scheduled assistant", sequenceIndex: session.nextSequenceIndex))
        XCTAssertNotNil(session.derivedTranscriptRefreshTask)

        viewModel.test_setCurrentTabIDOverride(otherTabID)
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: activeTabID)

        XCTAssertNil(session.derivedTranscriptRefreshTask)
        XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)
        XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.text, "Scheduled assistant")
        XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(viewModel.activeTranscriptPresentation, activeSnapshot)
        XCTAssertTrue(session.isDirty)

        let buildCountAfterDrain = session.transcriptPerformanceSnapshot.projectionBuildCount
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        viewModel.applySessionToBindings(session)

        XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterDrain)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "Scheduled assistant")
    }

    func testCoalescedScheduledRefreshBuildsOnceWithLatestSourceItems() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let otherTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: activeTabID)
        session.setItemsSilently([.user("Initial", sequenceIndex: 0)], reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        let activeSnapshot = viewModel.activeTranscriptPresentation
        let buildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

        session.appendItem(.assistant("First scheduled", sequenceIndex: session.nextSequenceIndex))
        XCTAssertNotNil(session.derivedTranscriptRefreshTask)
        viewModel.test_setCurrentTabIDOverride(otherTabID)
        session.appendItem(.assistant("Latest inactive mutation", sequenceIndex: session.nextSequenceIndex))
        XCTAssertNotNil(session.derivedTranscriptRefreshTask)

        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: activeTabID)

        let buildCountAfterDrain = session.transcriptPerformanceSnapshot.projectionBuildCount
        XCTAssertEqual(buildCountAfterDrain, buildCount + 1)
        XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.text, "Latest inactive mutation")
        XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(viewModel.activeTranscriptPresentation, activeSnapshot)

        viewModel.test_setCurrentTabIDOverride(activeTabID)
        viewModel.applySessionToBindings(session)

        XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterDrain)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "Latest inactive mutation")
    }

    func testSilentReplacementInvalidatesDerivedStateAndActivationCatchUpRebuilds() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let activeSession = await viewModel.ensureSessionReady(tabID: activeTabID)
        let inactiveSession = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        activeSession.setItemsSilently([.user("Active", sequenceIndex: 0)], reason: .testOverride)
        inactiveSession.setItemsSilently([.user("Inactive initial", sequenceIndex: 0)], reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: activeSession)
        viewModel.refreshDerivedTranscriptState(for: inactiveSession)
        viewModel.applySessionToBindings(activeSession)
        let buildCount = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount

        inactiveSession.setItemsSilently(
            [.user("Replacement source", sequenceIndex: 0), .assistant("Replacement answer", sequenceIndex: 1)],
            reason: .retentionCompaction
        )
        XCTAssertNil(inactiveSession.derivedTranscriptSyncState)
        XCTAssertEqual(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)

        viewModel.test_setCurrentTabIDOverride(inactiveTabID)
        viewModel.applySessionToBindings(inactiveSession)

        XCTAssertGreaterThan(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)
        XCTAssertEqual(inactiveSession.derivedTranscriptSyncState?.sourceItemsRevision, inactiveSession.sourceItemsRevision)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.map(\.text), ["Replacement source", "Replacement answer"])
    }

    func testInactiveAssistantDeltaIsRejectedBeforeQueueAdmission() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let activeSession = await viewModel.ensureSessionReady(tabID: activeTabID)
        let inactiveSession = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        activeSession.replaceItems([.user("active", sequenceIndex: 0)])
        inactiveSession.replaceItems([.user("inactive", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: activeSession)
        viewModel.applySessionToBindings(activeSession)
        let activeSnapshot = viewModel.activeTranscriptPresentation

        viewModel.enqueueAssistantDelta(" background delta", session: inactiveSession)
        viewModel.flushPendingAssistantDelta(inactiveSession)

        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 0)
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation, activeSnapshot)
        XCTAssertEqual(inactiveSession.items.last?.text, " background delta")
    }

    func testActiveGenericAssistantDeltaPublishesTranscriptWithoutFullBindingSync() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.replaceItems([.user("start", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        viewModel.enqueueAssistantDelta("streamed answer", session: session)
        viewModel.flushPendingAssistantDelta(session)

        let updateBindingsCount = viewModel.test_updateBindingsCallCount
        let composerSyncCount = viewModel.test_syncComposerCallCount
        let runtimeSyncCount = viewModel.test_syncRuntimeMetricsCallCount
        let runInteractionSyncCount = viewModel.test_syncRunInteractionCallCount
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)
        viewModel.test_flushPendingUIRefresh()

        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "streamed answer")
        XCTAssertEqual(viewModel.test_updateBindingsCallCount, updateBindingsCount)
        XCTAssertEqual(viewModel.test_syncComposerCallCount, composerSyncCount)
        XCTAssertEqual(viewModel.test_syncRuntimeMetricsCallCount, runtimeSyncCount)
        XCTAssertEqual(viewModel.test_syncRunInteractionCallCount, runInteractionSyncCount)
    }

    func testActiveCodexAssistantDeltaUsesPresentationOnlyRefresh() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .codexExec
        session.replaceItems([.user("start", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        let updateBindingsCount = viewModel.test_updateBindingsCallCount

        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("codex answer", session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)

        viewModel.test_flushPendingUIRefresh()

        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "codex answer")
        XCTAssertEqual(viewModel.test_updateBindingsCallCount, updateBindingsCount)
    }

    func testFullRefreshSupersedesPendingAssistantPresentation() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.replaceItems([.user("start", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        session.appendItem(.assistant("full refresh wins", sequenceIndex: session.nextSequenceIndex))
        session.assistantDeltaFlushGeneration &+= 1
        viewModel.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)

        viewModel.requestUIRefresh(tabID: tabID, scope: .full)

        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 0)
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "full refresh wins")
    }

    func testAssistantPresentationRejectsStaleRevisionGenerationAndTabOwnership() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let otherTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.replaceItems([.user("start", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        let baseline = viewModel.activeTranscriptPresentation

        session.appendItem(.assistant("revision request", sequenceIndex: session.nextSequenceIndex))
        session.assistantDeltaFlushGeneration &+= 1
        viewModel.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
        session.appendItem(.assistant("newer revision", sequenceIndex: session.nextSequenceIndex))
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation, baseline)

        viewModel.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
        session.assistantDeltaFlushGeneration &+= 1
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation, baseline)

        viewModel.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)
        viewModel.test_setCurrentTabIDOverride(otherTabID)
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation, baseline)

        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.last?.text, "newer revision")
    }

    func testAssistantPresentationRequiresAuthoritativeHydratedBindingGeneration() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let firstBinding = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(),
            on: session
        ))
        session.replaceItems([.user("start", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.hydratedPersistentBinding, firstBinding)
        XCTAssertEqual(
            viewModel.activeTranscriptPresentation.hydratedBindingTransitionGeneration,
            session.bindingTransitionGeneration
        )

        let rebound = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(),
            on: session
        ))
        XCTAssertNotEqual(rebound.generation, firstBinding.generation)

        viewModel.enqueueAssistantDelta(" stale binding delta", session: session)
        viewModel.flushPendingAssistantDelta(session)
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 0)

        viewModel.applySessionToBindings(session)
        XCTAssertEqual(viewModel.activeTranscriptPresentation.hydratedPersistentBinding, rebound)
        viewModel.enqueueAssistantDelta(" current binding delta", session: session)
        viewModel.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items.last?.text, " stale binding delta current binding delta")
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.test_flushPendingUIRefresh()

        let transitionGeneration = session.beginPersistentBindingTransition()
        viewModel.enqueueAssistantDelta(" transition delta", session: session)
        viewModel.flushPendingAssistantDelta(session)
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 0)
        session.finishPersistentBindingTransition(generation: transitionGeneration)
    }

    func testActivationRepublishesRunInteractionRuntimeAndLiveBashState() async {
        let viewModel = makeViewModel()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let activeSession = await viewModel.ensureSessionReady(tabID: activeTabID)
        let inactiveSession = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        activeSession.replaceItems([.user("active", sequenceIndex: 0)])
        inactiveSession.replaceItems([.user("inactive", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: activeSession)
        viewModel.applySessionToBindings(activeSession)

        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1234)
        let bashItem = AgentChatItem.toolCall(
            name: "bash",
            invocationID: UUID(),
            argsJSON: #"{"cmd":"sleep 1"}"#,
            sequenceIndex: inactiveSession.nextSequenceIndex
        )
        inactiveSession.appendItem(bashItem)
        inactiveSession.runID = runID
        inactiveSession.runState = .running
        inactiveSession.runningStatusText = "Background work"
        inactiveSession.activeAgentRunStartedAt = startedAt
        inactiveSession.codexContextUsage = AgentContextUsage(
            modelContextWindow: 200,
            lastTotalTokens: 15,
            totalTotalTokens: 15
        )
        inactiveSession.setBashLiveExecution(.init(
            executionKey: "invocation:\(bashItem.toolInvocationID!.uuidString)",
            transcriptItemID: bashItem.id,
            toolName: "bash",
            invocationID: bashItem.toolInvocationID,
            fallbackSignature: "bash",
            processID: "activation-123",
            command: "sleep 1",
            statusWord: "running",
            exitCode: nil,
            output: "live output",
            isSummaryOnly: false,
            lastSignalAt: Date(timeIntervalSince1970: 1235)
        ))

        XCTAssertEqual(viewModel.ui.runInteraction.snapshot.currentTabID, activeTabID)
        XCTAssertTrue(viewModel.activeBashLiveExecutionByItemID.isEmpty)

        viewModel.test_setCurrentTabIDOverride(inactiveTabID)
        viewModel.applySessionToBindings(inactiveSession)

        let runSnapshot = viewModel.ui.runInteraction.snapshot
        XCTAssertEqual(runSnapshot.currentTabID, inactiveTabID)
        XCTAssertEqual(runSnapshot.runState, .running)
        XCTAssertEqual(runSnapshot.runningStatusText, "Background work")
        XCTAssertEqual(runSnapshot.activeAgentRunStartedAt, startedAt)
        XCTAssertEqual(runSnapshot.activeRunID, runID)
        XCTAssertEqual(viewModel.contextUsage, inactiveSession.codexContextUsage)
        XCTAssertEqual(viewModel.activeBashLiveExecutionByItemID[bashItem.id]?.output, "live output")
    }

    func testPersistentBindingSameIDIsIdempotentAndSameTabRebindRotatesGeneration() async {
        let viewModel = makeViewModel()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        let firstID = UUID()
        let secondID = UUID()

        let first = viewModel.test_installPersistentSessionBinding(sessionID: firstID, on: session)
        let same = viewModel.test_installPersistentSessionBinding(sessionID: firstID, on: session)
        XCTAssertEqual(first, same)

        let rebound = viewModel.test_installPersistentSessionBinding(sessionID: secondID, on: session)
        XCTAssertNotEqual(rebound?.generation, first?.generation)
        XCTAssertEqual(session.activeAgentSessionID, secondID)
    }

    func testAmbiguousPersistentBindingFailsRoutingWithoutLeakingCandidates() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let first = await viewModel.ensureSessionReady(tabID: UUID())
        let second = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: first)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: second)

        guard case let .ambiguous(tabIDs) = viewModel.test_bindingResolution(sessionID: sessionID) else {
            return XCTFail("Expected ambiguous binding")
        }
        XCTAssertEqual(Set(tabIDs), Set([first.tabID, second.tabID]))

        do {
            _ = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: false,
                sessionName: nil
            )
            XCTFail("Expected ambiguous routing error")
        } catch {
            let description = String(describing: error)
            XCTAssertTrue(description.contains("ambiguous_agent_session"))
            XCTAssertFalse(description.contains(first.tabID.uuidString))
            XCTAssertFalse(description.contains(second.tabID.uuidString))
        }
    }

    func testPersistentBindingMoveIsBlockedByRunOwnershipAndStoreRegistration() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let source = await viewModel.ensureSessionReady(tabID: UUID())
        let target = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: source)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: target)

        source.runState = .running
        do {
            _ = try await viewModel.test_rebindPersistentSession(sessionID, to: target)
            XCTFail("Expected active source ownership to block move")
        } catch let error as AgentModeViewModel.PersistentBindingMutationError {
            XCTAssertEqual(error, .blockedByOwnership)
        }

        source.runState = .idle
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        do {
            _ = try await viewModel.test_rebindPersistentSession(sessionID, to: target)
            XCTFail("Expected active store registration to block move")
        } catch let error as AgentModeViewModel.PersistentBindingMutationError {
            XCTAssertEqual(error, .blockedByOwnership)
        }
        await AgentRunSessionStore.cleanup(registration: registration)
    }

    func testMCPActivationRejectsReservedBindingTransition() async {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let transitionGeneration = session.beginPersistentBindingTransition()
        defer { session.finishPersistentBindingTransition(generation: transitionGeneration) }

        do {
            try await viewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil
            )
            XCTFail("Expected binding transition to block MCP activation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("binding changed"))
        }
        let registration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNil(registration)
    }

    func testHydrationAndPresentationRejectStaleBindingGeneration() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let firstID = UUID()
        let secondID = UUID()
        _ = viewModel.test_installPersistentSessionBinding(sessionID: firstID, on: session)

        let hydrationToken = AgentModeViewModel.PersistedHydrationCommitToken(
            transition: viewModel.test_bindingTransitionToken(for: session),
            requestedSessionID: firstID
        )
        XCTAssertTrue(viewModel.test_canCommitHydration(payloadSessionID: firstID, token: hydrationToken))
        XCTAssertFalse(viewModel.test_canCommitHydration(payloadSessionID: secondID, token: hydrationToken))

        session.replaceItems([.user("before rebind", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        let presentation = viewModel.activeTranscriptPresentation
        viewModel.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
        XCTAssertEqual(viewModel.test_pendingAssistantPresentationCount, 1)

        session.testInstallPersistentSessionBinding(sessionID: secondID)
        XCTAssertFalse(viewModel.test_isBindingTransitionCurrent(hydrationToken.transition))
        XCTAssertFalse(viewModel.test_canCommitHydration(payloadSessionID: firstID, token: hydrationToken))
        viewModel.test_flushPendingUIRefresh()
        XCTAssertEqual(viewModel.activeTranscriptPresentation, presentation)
    }

    func testSaveCommitTokenRejectsMutationAndRebindGenerations() async throws {
        let viewModel = makeViewModel()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        session.saveRequestGeneration = 7
        let token = try XCTUnwrap(viewModel.test_saveCommitToken(for: session, workspaceID: UUID()))
        XCTAssertTrue(viewModel.test_isSaveCommitTokenCurrent(token))

        session.isDirty = true
        XCTAssertFalse(viewModel.test_isSaveCommitTokenCurrent(token))

        let reboundToken = try XCTUnwrap(viewModel.test_saveCommitToken(for: session, workspaceID: token.workspaceID))
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        XCTAssertFalse(viewModel.test_isSaveCommitTokenCurrent(reboundToken))
    }

    func testSidebarIndexRejectsStaleAndAmbiguousBindings() async {
        let viewModel = makeViewModel()
        let currentID = UUID()
        let staleID = UUID()
        let tabID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: currentID, on: session)

        XCTAssertFalse(viewModel.test_shouldAcceptSidebarIndexEntry(makeIndexEntry(id: staleID, tabID: tabID)))
        XCTAssertTrue(viewModel.test_shouldAcceptSidebarIndexEntry(makeIndexEntry(id: currentID, tabID: tabID)))

        let duplicate = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: currentID, on: duplicate)
        XCTAssertFalse(viewModel.test_shouldAcceptSidebarIndexEntry(makeIndexEntry(id: currentID, tabID: tabID)))
    }

    private func makeIndexEntry(id: UUID, tabID: UUID) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: "Agent",
            lastUserMessageAt: nil,
            savedAt: Date(),
            lastRunStateRaw: nil,
            itemCount: 0,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in InactiveRefreshFakeCodexController() }
        )
        viewModel.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
        return viewModel
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeTranscriptItems(prefix: String, turnCount: Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        var sequenceIndex = 0
        for turn in 0 ..< turnCount {
            items.append(.user("\(prefix) user \(turn)", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            items.append(.assistant("\(prefix) assistant \(turn)", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
        }
        return items
    }
}

private final class InactiveRefreshFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
