import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

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

    func testLiveToolResultRefreshUsesIncrementalRetentionCompaction() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        var items = makeTranscriptItems(prefix: "history", turnCount: 40)
        items.append(.user("Run a live tool", sequenceIndex: items.count))
        let invocationID = UUID()
        let toolCall = AgentChatItem.toolCall(
            name: "apply_edits",
            invocationID: invocationID,
            argsJSON: #"{"path":"File.swift"}"#,
            sequenceIndex: items.count
        )
        items.append(toolCall)
        session.setItemsSilently(items, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        XCTAssertNotNil(session.transcript.compactionFrontier)
        let marker = "INCREMENTAL_RAW_PAYLOAD_\(UUID().uuidString)"
        let rawResult = jsonString([
            "status": "success",
            "edits_requested": 1,
            "edits_applied": 1,
            "raw_output": String(repeating: marker, count: 8)
        ])
        var toolResult = toolCall
        toolResult.kind = .toolResult
        toolResult.text = rawResult
        toolResult.toolResultJSON = rawResult
        toolResult.toolIsError = false

        let previousIncrementalImportSuccessCount =
            session.transcriptPerformanceSnapshot.incrementalImportSuccessCount
        session.replaceItem(at: session.items.count - 1, with: toolResult)
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        XCTAssertGreaterThan(
            session.transcriptPerformanceSnapshot.incrementalImportSuccessCount,
            previousIncrementalImportSuccessCount
        )
        XCTAssertEqual(session.test_incrementalRetentionCompactionCount, 1)
        let compactedResult = try XCTUnwrap(session.items.last)
        XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: compactedResult.toolResultJSON ?? ""))
        XCTAssertFalse(compactedResult.toolResultJSON?.contains(marker) ?? false)
        XCTAssertTrue(session.ephemeralToolResultPayloadByItemID[toolCall.id]?.contains(marker) == true)
        XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
    }

    func testIncrementalRefreshReconcilesOlderTurnWhenCompactionChangesFullEnvelope() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        let initialItems = makeTranscriptItems(prefix: "boundary", turnCount: 32)
        let oldestItemID = initialItems[0].id
        session.setItemsSilently(initialItems, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        XCTAssertFalse(session.transcript.turns.contains(where: { $0.retentionTier != .full }))
        let previousFullTurnIDs = session.transcript.turns.map(\.id)

        for _ in 0 ..< 4 {
            let invocationID = UUID()
            session.appendItem(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"/tmp/file.swift"}"#,
                sequenceIndex: session.nextSequenceIndex
            ))
            session.appendItem(.toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: #"{"content":"ok"}"#,
                sequenceIndex: session.nextSequenceIndex
            ))
        }
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        let updatedFullTurnIDs = session.transcript.turns
            .filter { $0.retentionTier == .full }
            .map(\.id)
        XCTAssertNotEqual(updatedFullTurnIDs, previousFullTurnIDs)
        XCTAssertTrue(session.transcript.turns.contains(where: { $0.retentionTier != .full }))
        XCTAssertFalse(session.items.contains(where: { $0.id == oldestItemID }))
        XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.incrementalImportSuccessCount, 0)
    }

    func testIncrementalRefreshStillRemovesImportPolicyExcludedItems() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        session.setItemsSilently(
            makeTranscriptItems(prefix: "history", turnCount: 40),
            reason: .testOverride
        )
        viewModel.refreshDerivedTranscriptState(for: session)
        XCTAssertNotNil(session.transcript.compactionFrontier)

        let excludedItem = AgentChatItem.toolCall(
            name: "set_status",
            invocationID: UUID(),
            argsJSON: #"{"session_name":"hidden"}"#,
            sequenceIndex: session.nextSequenceIndex
        )
        let previousIncrementalImportSuccessCount =
            session.transcriptPerformanceSnapshot.incrementalImportSuccessCount
        session.appendItem(excludedItem)
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        XCTAssertGreaterThan(
            session.transcriptPerformanceSnapshot.incrementalImportSuccessCount,
            previousIncrementalImportSuccessCount
        )
        XCTAssertFalse(session.items.contains(where: { $0.id == excludedItem.id }))
        XCTAssertFalse(
            AgentTranscriptIO.flattenFullTranscript(session.transcript)
                .contains(where: { $0.id == excludedItem.id })
        )
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

    func testPersistentBindingSameIDIsIdempotentAndSameTabRebindRotatesGeneration() async throws {
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

        let authoritativeTabID = UUID()
        let authoritativeSessionID = UUID()
        let installableTabID = UUID()
        let manager = makeWorkspaceManager(workspaces: [
            makeWorkspace(
                name: "Binding authority",
                tabs: [
                    ComposeTabState(
                        id: authoritativeTabID,
                        activeAgentSessionID: authoritativeSessionID
                    ),
                    ComposeTabState(id: installableTabID)
                ],
                activeTabID: authoritativeTabID
            )
        ])
        viewModel.workspaceManager = manager

        let conflictingSession = AgentModeViewModel.TabSession(tabID: authoritativeTabID)
        XCTAssertNil(viewModel.test_ensureSessionBoundToTab(conflictingSession))
        XCTAssertNil(conflictingSession.activeAgentSessionID)
        XCTAssertEqual(
            manager.activeAgentSessionID(forTabID: authoritativeTabID),
            authoritativeSessionID
        )

        let missingTabSession = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertNil(viewModel.test_ensureSessionBoundToTab(missingTabSession))
        XCTAssertNil(missingTabSession.activeAgentSessionID)

        let installableSession = AgentModeViewModel.TabSession(tabID: installableTabID)
        let installedSessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(installableSession)
        )
        XCTAssertEqual(installableSession.activeAgentSessionID, installedSessionID)
        XCTAssertEqual(
            manager.activeAgentSessionID(forTabID: installableTabID),
            installedSessionID
        )
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

    func testDelayedStaleSystemWorkspaceHandlerCannotReplaceRealOwner() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let sessionID = UUID()
        let harness = SidebarIndexStreamHarness(plans: [
            .init(batches: [makeBatch([makeIndexEntry(id: sessionID, tabID: tabID)])])
        ])
        installSidebarIndexHarness(harness, on: viewModel)

        let systemWorkspace = WorkspaceModel(
            name: "System",
            repoPaths: [],
            isSystemWorkspace: true,
            ephemeralFlag: true
        )
        let realWorkspace = makeWorkspace(
            name: "Real",
            tabs: [ComposeTabState(id: tabID, name: "Root", activeAgentSessionID: sessionID)],
            activeTabID: tabID
        )
        let staleSystemOwner = viewModel.test_receiveWorkspaceSwitchNotification(systemWorkspace)
        let realOwner = viewModel.test_receiveWorkspaceSwitchNotification(realWorkspace)

        await viewModel.test_handleWorkspaceSwitch(realWorkspace, owner: realOwner)
        await viewModel.test_waitForSessionListCacheRefresh()
        let requestCountBeforeStaleHandler = await harness.currentRequestCount()

        await viewModel.test_handleWorkspaceSwitch(systemWorkspace, owner: staleSystemOwner)
        await Task.yield()

        XCTAssertEqual(viewModel.test_sessionIndexOwner, realOwner)
        XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), [sessionID])
        XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        let requestCountAfterStaleHandler = await harness.currentRequestCount()
        XCTAssertEqual(requestCountAfterStaleHandler, requestCountBeforeStaleHandler)
    }

    func testAutoArchiveSkipsMutationAfterSameWorkspaceReactivation() async {
        let tabs = (0 ... AgentModeViewModel.sessionSidebarPageSize + 10).map { offset in
            ComposeTabState(
                id: UUID(),
                name: "Inactive \(offset)",
                lastModified: Date(timeIntervalSince1970: 1),
                activeAgentSessionID: UUID()
            )
        }
        let activeTabID = tabs.last?.id
        let workspace = makeWorkspace(
            name: "Same workspace reactivation",
            tabs: tabs,
            activeTabID: activeTabID
        )
        let fixture = makeWorkspaceFixture(workspaces: [workspace])
        fixture.manager.activeWorkspace = workspace
        fixture.prompt.loadComposeTabsFromWorkspace(workspace)
        let viewModel = makeViewModel()
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: fixture.prompt,
            workspaceManager: fixture.manager
        )
        viewModel.test_setSidebarAutoArchiveActive(true)

        let initialOwner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            [:],
            owner: initialOwner,
            latestOwner: initialOwner,
            activeWorkspace: workspace
        )

        let closeGate = SidebarIndexStreamGate()
        let closeListenerToken = fixture.prompt.addComposeTabsWillCloseListener { _, reason in
            guard reason == .stash else { return }
            await closeGate.wait()
        }
        defer {
            fixture.prompt.removeComposeTabsWillCloseListener(closeListenerToken)
        }
        let archiveTask = Task {
            await viewModel.performSidebarAutoArchiveIfNeeded(
                reason: .explicitTest,
                now: Date()
            )
        }
        await closeGate.waitForWaiter()

        let reactivatedOwner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            [:],
            owner: reactivatedOwner,
            latestOwner: reactivatedOwner,
            activeWorkspace: workspace
        )
        await closeGate.release()
        let archivedTabIDs = await archiveTask.value

        XCTAssertTrue(archivedTabIDs.isEmpty)
        XCTAssertEqual(Set(fixture.manager.activeWorkspace?.composeTabs.map(\.id) ?? []), Set(tabs.map(\.id)))
        XCTAssertTrue(fixture.manager.activeWorkspace?.stashedTabs.isEmpty == true)
    }

    func testRestoredMatchingBindingPreservesRefreshAndRestoresIndexOnlyHierarchy() async throws {
        let viewModel = makeViewModel()
        let rootTabID = UUID()
        let childTabID = UUID()
        let grandchildTabID = UUID()
        let rootSessionID = UUID()
        let childSessionID = UUID()
        let grandchildSessionID = UUID()
        let gate = SidebarIndexStreamGate()
        let entries = [
            makeIndexEntry(id: rootSessionID, tabID: rootTabID),
            makeIndexEntry(id: childSessionID, tabID: childTabID, parentSessionID: rootSessionID),
            makeIndexEntry(id: grandchildSessionID, tabID: grandchildTabID, parentSessionID: childSessionID)
        ]
        let harness = SidebarIndexStreamHarness(plans: [
            .init(batches: [makeBatch(entries)], gate: gate)
        ])
        installSidebarIndexHarness(harness, on: viewModel)
        let tabs = [
            ComposeTabState(id: rootTabID, name: "Root", activeAgentSessionID: rootSessionID),
            ComposeTabState(id: childTabID, name: "Child", activeAgentSessionID: childSessionID),
            ComposeTabState(id: grandchildTabID, name: "Grandchild", activeAgentSessionID: grandchildSessionID)
        ]
        let workspace = makeWorkspace(name: "Hierarchy", tabs: tabs, activeTabID: rootTabID)
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)

        await viewModel.test_handleWorkspaceSwitch(workspace, owner: owner)
        await harness.waitForRequestCount(1)
        let generationWhileBindingIsInstalled = try XCTUnwrap(viewModel.test_activeSessionIndexRefreshGeneration)
        let restoredSession = try XCTUnwrap(viewModel.session(for: rootTabID, createIfNeeded: true))
        XCTAssertEqual(restoredSession.activeAgentSessionID, rootSessionID)
        XCTAssertEqual(viewModel.test_activeSessionIndexRefreshGeneration, generationWhileBindingIsInstalled)

        await gate.release()
        await viewModel.test_waitForSessionListCacheRefresh()

        XCTAssertNil(viewModel.test_activeSessionIndexRefreshGeneration)
        XCTAssertGreaterThan(generationWhileBindingIsInstalled, 0)
        XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreFrozenOrderCount, 0)
        let matchingBindingRequestCount = await harness.currentRequestCount()
        XCTAssertEqual(matchingBindingRequestCount, 1)
        let rows = viewModel.sidebarSessions(for: tabs)
        XCTAssertEqual(rows.map(\.tabID), [rootTabID, childTabID, grandchildTabID])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    func testConflictingBindingStartsSuccessorRefresh() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let originalSessionID = UUID()
        let replacementSessionID = UUID()
        let firstGate = SidebarIndexStreamGate()
        let successorGate = SidebarIndexStreamGate()
        let harness = SidebarIndexStreamHarness(plans: [
            .init(
                batches: [makeBatch([makeIndexEntry(id: originalSessionID, tabID: tabID)])],
                gateAfterBatches: firstGate
            ),
            .init(
                batches: [makeBatch([makeIndexEntry(id: replacementSessionID, tabID: tabID)])],
                gate: successorGate
            )
        ])
        installSidebarIndexHarness(harness, on: viewModel)
        let workspace = makeWorkspace(
            name: "Binding successor",
            tabs: [ComposeTabState(id: tabID, name: "Agent", activeAgentSessionID: originalSessionID)],
            activeTabID: tabID
        )
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)

        await viewModel.test_handleWorkspaceSwitch(workspace, owner: owner)
        await harness.waitForRequestCount(1)
        let originalGeneration = try XCTUnwrap(viewModel.test_activeSessionIndexRefreshGeneration)
        try await waitUntil {
            viewModel.test_ownerValidatedSessionIndex[originalSessionID] != nil
        }
        let session = try XCTUnwrap(viewModel.session(for: tabID, createIfNeeded: true))
        XCTAssertEqual(session.activeAgentSessionID, originalSessionID)
        XCTAssertEqual(viewModel.test_activeSessionIndexRefreshGeneration, originalGeneration)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: replacementSessionID, on: session)
        let successorGeneration = try XCTUnwrap(viewModel.test_activeSessionIndexRefreshGeneration)
        XCTAssertGreaterThan(successorGeneration, originalGeneration)
        await harness.waitForRequestCount(2)
        XCTAssertTrue(viewModel.test_ownerValidatedSessionIndex.isEmpty)

        await firstGate.release()
        await successorGate.release()
        await viewModel.test_waitForSessionListCacheRefresh()

        let successorRequestCount = await harness.currentRequestCount()
        XCTAssertEqual(successorRequestCount, 2)
        let successorBinding = await harness.boundSessionID(requestIndex: 1, tabID: tabID)
        XCTAssertEqual(successorBinding, replacementSessionID)
        XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), [replacementSessionID])
        XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreFrozenOrderCount, 0)
    }

    func testFullRefreshReplacesOmittedEntries() async throws {
        let viewModel = makeViewModel()
        let rootTabID = UUID()
        let childTabID = UUID()
        let rootSessionID = UUID()
        let childSessionID = UUID()
        let rootEntry = makeIndexEntry(
            id: rootSessionID,
            tabID: rootTabID,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let updatedRootEntry = makeIndexEntry(
            id: rootSessionID,
            tabID: rootTabID,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let childEntry = makeIndexEntry(
            id: childSessionID,
            tabID: childTabID,
            parentSessionID: rootSessionID,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let completionGate = SidebarIndexStreamGate()
        let harness = SidebarIndexStreamHarness(plans: [
            .init(batches: [makeBatch([rootEntry, childEntry])]),
            .init(
                batches: [makeBatch([updatedRootEntry])],
                gateAfterBatches: completionGate
            )
        ])
        installSidebarIndexHarness(harness, on: viewModel)
        let workspace = makeWorkspace(
            name: "Replacement",
            tabs: [
                ComposeTabState(id: rootTabID, activeAgentSessionID: rootSessionID),
                ComposeTabState(id: childTabID, activeAgentSessionID: childSessionID)
            ],
            activeTabID: rootTabID
        )

        await viewModel.handleWorkspaceSwitch(workspace)
        await viewModel.test_waitForSessionListCacheRefresh()
        XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), [rootSessionID, childSessionID])

        viewModel.test_refreshSessionListCache(for: workspace)
        await harness.waitForRequestCount(2)
        try await waitUntil {
            viewModel.test_ownerValidatedSessionIndex[rootSessionID]?.savedAt == updatedRootEntry.savedAt
        }
        XCTAssertEqual(
            Set(viewModel.test_ownerValidatedSessionIndex.keys),
            [rootSessionID, childSessionID]
        )
        XCTAssertFalse(viewModel.test_ownerValidatedSessionListCacheReady)

        await completionGate.release()
        await viewModel.test_waitForSessionListCacheRefresh()

        XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), [rootSessionID])
        XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        let replacementRequestCount = await harness.currentRequestCount()
        XCTAssertEqual(replacementRequestCount, 2)
    }

    func testSidebarIndexStreamRetriesTransientFailureAndBecomesReady() async {
        let viewModel = makeViewModel()
        let rootTabID = UUID()
        let partialChildTabID = UUID()
        let rootSessionID = UUID()
        let partialChildSessionID = UUID()
        let rootEntry = makeIndexEntry(id: rootSessionID, tabID: rootTabID)
        let partialChildEntry = makeIndexEntry(
            id: partialChildSessionID,
            tabID: partialChildTabID,
            parentSessionID: rootSessionID
        )
        let harness = SidebarIndexStreamHarness(plans: [
            .init(
                batches: [makeBatch([partialChildEntry])],
                failsAfterBatches: true
            ),
            .init(batches: [makeBatch([rootEntry])])
        ])
        installSidebarIndexHarness(harness, on: viewModel)
        let workspace = makeWorkspace(
            name: "Transient stream failure",
            tabs: [
                ComposeTabState(id: rootTabID, activeAgentSessionID: rootSessionID),
                ComposeTabState(id: partialChildTabID, activeAgentSessionID: partialChildSessionID)
            ],
            activeTabID: rootTabID
        )

        await viewModel.handleWorkspaceSwitch(workspace)
        await viewModel.test_waitForSessionListCacheRefresh()

        let requestCount = await harness.currentRequestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), [rootSessionID])
        XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreFrozenOrderCount, 0)
    }

    func testLocalRemovalTombstoneWinsOverLaterFullBatch() async {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let sessionID = UUID()
        let entry = makeIndexEntry(id: sessionID, tabID: tabID)
        let harness = SidebarIndexStreamHarness(plans: [
            .init(batches: []),
            .init(batches: [makeBatch([entry])])
        ])
        installSidebarIndexHarness(harness, on: viewModel)
        let workspace = makeWorkspace(
            name: "Tombstone",
            tabs: [ComposeTabState(id: tabID, activeAgentSessionID: sessionID)],
            activeTabID: tabID
        )

        await viewModel.handleWorkspaceSwitch(workspace)
        await viewModel.test_waitForSessionListCacheRefresh()
        viewModel.upsertSessionIndex(
            sessionID: entry.id,
            tabID: entry.tabID,
            name: entry.name,
            lastUserMessageAt: entry.lastUserMessageAt,
            savedAt: entry.savedAt,
            lastRunStateRaw: entry.lastRunStateRaw,
            itemCount: entry.itemCount,
            agentKindRaw: entry.agentKindRaw,
            agentModelRaw: entry.agentModelRaw,
            agentReasoningEffortRaw: entry.agentReasoningEffortRaw,
            autoEditEnabled: entry.autoEditEnabled
        )
        viewModel.removeSessionIndex(sessionID: sessionID)

        viewModel.test_refreshSessionListCache(for: workspace)
        await viewModel.test_waitForSessionListCacheRefresh()

        XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[sessionID])
    }

    func testSidebarFallsBackWhenPreferredIndexEntryIsExplicitlyBoundToAnotherTab() throws {
        let viewModel = makeViewModel()
        let targetTabID = UUID()
        let boundTabID = UUID()
        let fallbackSessionID = UUID()
        let conflictingSessionID = UUID()
        let workspace = makeWorkspace(
            name: "Conflicting sidebar binding",
            tabs: [
                ComposeTabState(id: targetTabID, name: "Target"),
                ComposeTabState(id: boundTabID, name: "Bound", activeAgentSessionID: conflictingSessionID)
            ],
            activeTabID: targetTabID
        )
        let owner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        let fallbackEntry = makeIndexEntry(
            id: fallbackSessionID,
            tabID: targetTabID,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let conflictingPreferredEntry = makeIndexEntry(
            id: conflictingSessionID,
            tabID: targetTabID,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        viewModel.test_installSessionIndexSnapshot(
            [
                fallbackEntry.id: fallbackEntry,
                conflictingPreferredEntry.id: conflictingPreferredEntry
            ],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )

        let rows = viewModel.sidebarSessions(for: workspace.composeTabs)

        let targetRow = try XCTUnwrap(rows.first(where: { $0.tabID == targetTabID }))
        XCTAssertEqual(targetRow.sessionID, fallbackSessionID)

        let rootTabID = UUID()
        let staleRootTabID = UUID()
        let newerChildTabID = UUID()
        let activeOlderChildTabID = UUID()
        let rootSessionID = UUID()
        let staleRootSessionID = UUID()
        let newerChildSessionID = UUID()
        let staleOlderChildSessionID = UUID()
        let liveOlderChildSessionID = UUID()
        let mergeSummary = AgentSessionWorktreeMergeSummary(
            id: "sidebar_merge",
            status: .conflicted,
            sourceWorktreeID: "source",
            sourceLabel: "feature",
            sourceBranch: "feature",
            sourcePath: "/tmp/source",
            targetWorktreeID: "target",
            targetLabel: "main",
            targetBranch: "main",
            targetPath: "/tmp/target",
            repositoryID: "repo",
            repoKey: "repo",
            conflictFileCount: 1,
            updatedAt: Date(timeIntervalSince1970: 5)
        )
        let transitionWorkspace = makeWorkspace(
            name: "Live binding transition",
            tabs: [
                ComposeTabState(id: rootTabID, name: "Root", activeAgentSessionID: rootSessionID),
                ComposeTabState(
                    id: staleRootTabID,
                    name: "Stale root",
                    activeAgentSessionID: staleRootSessionID
                ),
                ComposeTabState(
                    id: newerChildTabID,
                    name: "Newer child",
                    activeAgentSessionID: newerChildSessionID
                ),
                ComposeTabState(
                    id: activeOlderChildTabID,
                    name: "Active older child",
                    activeAgentSessionID: staleOlderChildSessionID
                )
            ],
            activeTabID: newerChildTabID
        )
        let transitionOwner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: transitionWorkspace.id,
            activationEpoch: 2
        )
        let transitionEntries = [
            makeIndexEntry(
                id: rootSessionID,
                tabID: rootTabID,
                savedAt: Date(timeIntervalSince1970: 10)
            ),
            makeIndexEntry(
                id: staleRootSessionID,
                tabID: staleRootTabID,
                savedAt: Date(timeIntervalSince1970: 20)
            ),
            makeIndexEntry(
                id: newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: rootSessionID,
                savedAt: Date(timeIntervalSince1970: 300)
            ),
            makeIndexEntry(
                id: staleOlderChildSessionID,
                tabID: activeOlderChildTabID,
                parentSessionID: staleRootSessionID,
                lastUserMessageAt: Date(timeIntervalSince1970: 400),
                savedAt: Date(timeIntervalSince1970: 400)
            ),
            makeIndexEntry(
                id: liveOlderChildSessionID,
                tabID: activeOlderChildTabID,
                parentSessionID: rootSessionID,
                lastUserMessageAt: Date(timeIntervalSince1970: 100),
                savedAt: Date(timeIntervalSince1970: 100),
                activeWorktreeMergeSummaries: [mergeSummary]
            )
        ]
        viewModel.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: transitionEntries.map { ($0.id, $0) }),
            owner: transitionOwner,
            latestOwner: transitionOwner,
            activeWorkspace: transitionWorkspace
        )
        let liveOlderChild = viewModel.session(for: activeOlderChildTabID)
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: liveOlderChildSessionID,
            on: liveOlderChild
        )
        viewModel.test_setCurrentTabIDOverride(newerChildTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let transitionRows = viewModel.filteredSidebarSessions(
            for: transitionWorkspace.composeTabs,
            currentTabID: activeOlderChildTabID,
            searchText: ""
        )

        XCTAssertEqual(Set(transitionRows.map(\.tabID)), Set(transitionWorkspace.composeTabs.map(\.id)))
        let rootRowIndex = try XCTUnwrap(transitionRows.firstIndex(where: { $0.tabID == rootTabID }))
        let activeChildRowIndex = try XCTUnwrap(
            transitionRows.firstIndex(where: { $0.tabID == activeOlderChildTabID })
        )
        let newerChildRowIndex = try XCTUnwrap(
            transitionRows.firstIndex(where: { $0.tabID == newerChildTabID })
        )
        XCTAssertLessThan(rootRowIndex, newerChildRowIndex)
        XCTAssertLessThan(newerChildRowIndex, activeChildRowIndex)
        let activeOlderChildRow = try XCTUnwrap(
            transitionRows.first(where: { $0.tabID == activeOlderChildTabID })
        )
        XCTAssertEqual(activeOlderChildRow.sessionID, liveOlderChildSessionID)
        XCTAssertEqual(activeOlderChildRow.parentSessionID, rootSessionID)
        XCTAssertEqual(activeOlderChildRow.activityDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(activeOlderChildRow.worktreeMergeAttention?.operationID, mergeSummary.id)

        let newerActiveRows = viewModel.filteredSidebarSessions(
            for: transitionWorkspace.composeTabs,
            currentTabID: newerChildTabID,
            searchText: ""
        )
        XCTAssertEqual(transitionRows.map(\.tabID), newerActiveRows.map(\.tabID))

        let searchRowsWithoutActivePromotion = viewModel.filteredSidebarSessions(
            for: transitionWorkspace.composeTabs,
            currentTabID: nil,
            searchText: "root"
        )
        let searchRowsWithStaleRootActive = viewModel.filteredSidebarSessions(
            for: transitionWorkspace.composeTabs,
            currentTabID: staleRootTabID,
            searchText: "root"
        )
        XCTAssertEqual(
            searchRowsWithStaleRootActive.map(\.tabID),
            searchRowsWithoutActivePromotion.map(\.tabID)
        )

        let currentCascade = viewModel.test_sessionTreeCascadePlan(
            forComposeTabIDs: [rootTabID],
            reason: .close
        )
        XCTAssertEqual(
            currentCascade.composeTabIDs,
            Set([newerChildTabID, activeOlderChildTabID])
        )
        let staleCascade = viewModel.test_sessionTreeCascadePlan(
            forComposeTabIDs: [staleRootTabID],
            reason: .close
        )
        XCTAssertTrue(staleCascade.composeTabIDs.isEmpty)
    }

    func testForeignOwnerIndexCannotAffectSidebarOrCloseCascade() {
        let viewModel = makeViewModel()
        let rootTabID = UUID()
        let childTabID = UUID()
        let rootSessionID = UUID()
        let childSessionID = UUID()
        let tabs = [
            ComposeTabState(id: rootTabID, name: "Root", activeAgentSessionID: rootSessionID),
            ComposeTabState(id: childTabID, name: "Child", activeAgentSessionID: childSessionID)
        ]
        let workspace = makeWorkspace(name: "Current", tabs: tabs, activeTabID: rootTabID)
        let foreignOwner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: UUID(),
            activationEpoch: 1
        )
        let currentOwner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 2
        )
        let foreignEntry = makeIndexEntry(
            id: childSessionID,
            tabID: childTabID,
            parentSessionID: rootSessionID
        )
        viewModel.test_installSessionIndexSnapshot(
            [foreignEntry.id: foreignEntry],
            owner: foreignOwner,
            latestOwner: currentOwner,
            activeWorkspace: workspace
        )

        XCTAssertTrue(viewModel.test_ownerValidatedSessionIndex.isEmpty)
        XCTAssertNil(viewModel.preferredSidebarEntry(for: childTabID))
        XCTAssertEqual(viewModel.sidebarSessions(for: tabs).map(\.depth), [0, 0])
        let cascade = viewModel.test_sessionTreeCascadePlan(
            forComposeTabIDs: [rootTabID],
            reason: .close
        )
        XCTAssertTrue(cascade.composeTabIDs.isEmpty)
        XCTAssertTrue(cascade.stashedTabIDs.isEmpty)
    }

    private func makeIndexEntry(
        id: UUID,
        tabID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date? = nil,
        savedAt: Date = Date(),
        activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = []
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: "Agent",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt,
            lastRunStateRaw: nil,
            itemCount: lastUserMessageAt == nil ? 0 : 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries
        )
    }

    private func makeBatch(
        _ entries: [AgentSessionIndexEntry]
    ) -> AgentSessionSidebarBuildBatch {
        AgentSessionSidebarBuildBatch(
            entriesBySessionID: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            preferredSessionIDByTabID: Dictionary(uniqueKeysWithValues: entries.map { ($0.tabID, $0.id) })
        )
    }

    private func makeWorkspace(
        name: String,
        tabs: [ComposeTabState],
        activeTabID: UUID?
    ) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: activeTabID
        )
    }

    private func installSidebarIndexHarness(
        _ harness: SidebarIndexStreamHarness,
        on viewModel: AgentModeViewModel
    ) {
        viewModel.test_setSidebarIndexBuilders(
            prioritized: { _ in
                AgentSessionSidebarBuildResult(
                    entriesBySessionID: [:],
                    preferredSessionIDByTabID: [:]
                )
            },
            stream: { request, batchSize in
                await harness.stream(request: request, batchSize: batchSize)
            }
        )
    }

    private func makeWorkspaceManager(
        workspaces: [WorkspaceModel]
    ) -> WorkspaceManagerViewModel {
        makeWorkspaceFixture(workspaces: workspaces).manager
    }

    private func makeWorkspaceFixture(
        workspaces: [WorkspaceModel]
    ) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
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
        manager.workspaces = workspaces
        return (manager, prompt)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for condition")
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

private actor SidebarIndexStreamGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForWaiter() async {
        while waiters.isEmpty, !released {
            await Task.yield()
        }
    }

    func release() {
        released = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private enum SidebarIndexStreamHarnessError: Error {
    case expectedFailure
}

private actor SidebarIndexStreamHarness {
    struct Plan: @unchecked Sendable {
        let batches: [AgentSessionSidebarBuildBatch]
        let gate: SidebarIndexStreamGate?
        let gateAfterBatches: SidebarIndexStreamGate?
        let failsAfterBatches: Bool

        init(
            batches: [AgentSessionSidebarBuildBatch],
            gate: SidebarIndexStreamGate? = nil,
            gateAfterBatches: SidebarIndexStreamGate? = nil,
            failsAfterBatches: Bool = false
        ) {
            self.batches = batches
            self.gate = gate
            self.gateAfterBatches = gateAfterBatches
            self.failsAfterBatches = failsAfterBatches
        }
    }

    private var plans: [Plan]
    private var boundSessionIDByTabIDByRequest: [[UUID: UUID]] = []
    private(set) var requestCount = 0

    init(plans: [Plan]) {
        self.plans = plans
    }

    func stream(
        request: AgentSessionSidebarBuildRequest,
        batchSize _: Int
    ) -> AsyncThrowingStream<AgentSessionSidebarBuildBatch, Error> {
        boundSessionIDByTabIDByRequest.append(request.boundSessionIDByTabID)
        requestCount += 1
        let plan = plans.isEmpty ? Plan(batches: []) : plans.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let gate = plan.gate {
                    await gate.wait()
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                for batch in plan.batches {
                    guard !Task.isCancelled else { break }
                    continuation.yield(batch)
                }
                if let gateAfterBatches = plan.gateAfterBatches {
                    await gateAfterBatches.wait()
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                if plan.failsAfterBatches {
                    continuation.finish(throwing: SidebarIndexStreamHarnessError.expectedFailure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func currentRequestCount() -> Int {
        requestCount
    }

    func boundSessionID(requestIndex: Int, tabID: UUID) -> UUID? {
        guard boundSessionIDByTabIDByRequest.indices.contains(requestIndex) else { return nil }
        return boundSessionIDByTabIDByRequest[requestIndex][tabID]
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
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
