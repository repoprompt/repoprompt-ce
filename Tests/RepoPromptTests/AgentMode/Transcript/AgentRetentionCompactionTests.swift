#if DEBUG
    import Foundation
    import MCP
    import RepoPromptSettingsCore
    @_spi(TestSupport) @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class AgentRetentionCompactionTests: XCTestCase {
        func testFullReconciliationPreservesPayloadsAndMeasuresRetentionScan() {
            // Keep the larger timing workloads opt-in without changing the correctness oracle.
            let resultCounts = ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1"
                ? [128, 1000, 4000, 16000]
                : [128]
            for resultCount in resultCounts {
                assertFullReconciliation(resultCount: resultCount, runState: .idle)
            }
        }

        func testActiveFullReconciliationPreservesPayloadsAndSynchronization() {
            assertFullReconciliation(resultCount: 128, runState: .running)
        }

        func testCompactionPrunesPayloadsAndRepairsDuplicateOwnershipWithoutChangingSurvivingRevisions() throws {
            for isActive in [false, true] {
                let session = AgentModeViewModel.TabSession(tabID: id(900_000))
                let sourceItems = fixture(resultCount: 3)
                session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
                session.runState = isActive ? .running : .idle
                session.appendItem(.user("Synthetic steering", sequenceIndex: session.nextSequenceIndex))
                let pendingInvocationID = id(600_000)
                session.appendItem(.toolCall(
                    name: "read_file", invocationID: pendingInvocationID,
                    argsJSON: #"{"path":"synthetic.swift"}"#, sequenceIndex: session.nextSequenceIndex
                ))
                let steeringItem = session.items[5]
                let pendingCall = session.items[6]
                let keptItem = try compacted(sourceItems[1])
                var duplicate = keptItem
                duplicate.sequenceIndex = 2
                duplicate.toolInvocationID = id(600_001)
                let retainedPayload = try XCTUnwrap(session.ephemeralToolResultPayloadByItemID[keptItem.id])
                let retainedRevision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID[keptItem.id])
                let sourceRevision = session.sourceItemsRevision
                let scannedBefore = session.test_fullRetentionPayloadMapScannedItemCount
                let refreshGeneration = session.derivedTranscriptRefreshGeneration
                let refreshTask = Task<Void, Never> {}
                session.derivedTranscriptRefreshTask = refreshTask
                session.pendingDerivedTranscriptRefreshReason = .liveMutation
                session.nextSequenceIndex = 100
                var sourceNotifications = 0
                session.onSourceItemsChanged = { _, _ in sourceNotifications += 1 }

                session.setItemsSilentlyForRetentionCompaction([
                    sourceItems[0], keptItem, keptItem, duplicate, steeringItem, pendingCall
                ])

                XCTAssertEqual(session.items.count, 5, "Exact duplicate must be dropped, distinct duplicate rekeyed")
                XCTAssertEqual(session.items[1], keptItem)
                let repairedDuplicate = session.items[2]
                XCTAssertNotEqual(repairedDuplicate.id, keptItem.id)
                XCTAssertEqual(repairedDuplicate, duplicate.replacingID(repairedDuplicate.id))
                XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))
                XCTAssertEqual(session.liveItemIDs.count, session.items.count)
                XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, [keptItem.id: retainedPayload])
                XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, [keptItem.id: retainedRevision])
                XCTAssertNil(session.ephemeralToolResultPayloadByItemID[repairedDuplicate.id])
                XCTAssertEqual(session.sourceItemsRevision, sourceRevision + 1)
                XCTAssertEqual(session.nextSequenceIndex, 100, "Pruning must not rewind the sequence allocator")
                XCTAssertEqual(session.test_fullRetentionPayloadMapScannedItemCount, scannedBefore)
                XCTAssertEqual(sourceNotifications, 0)
                XCTAssertNil(session.derivedTranscriptSyncState)
                XCTAssertEqual(session.derivedTranscriptRefreshGeneration, refreshGeneration + 1)
                XCTAssertNil(session.pendingDerivedTranscriptRefreshReason)
                XCTAssertNil(session.derivedTranscriptRefreshTask)
                XCTAssertTrue(refreshTask.isCancelled)
                XCTAssertEqual(session.indexedToolItemIndices(invocationID: id(200_000)), isActive ? [1] : [])
                XCTAssertEqual(session.indexedToolItemIndices(invocationID: id(600_001)), isActive ? [2] : [])
                XCTAssertEqual(session.indexedToolItemIndices(invocationID: pendingInvocationID), [4])
                let signature = AgentModeViewModel.TabSession.canonicalToolInvocationSignature(
                    toolName: pendingCall.toolName, argsJSON: pendingCall.toolArgsJSON
                )
                XCTAssertEqual(session.indexedToolItemIndices(signature: signature, pendingCallsOnly: true), [4])
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        func testOrdinaryReplacementStillRebuildsPayloadsAndAdvancesTheirRevisions() throws {
            let reasons: [AgentModeViewModel.TabSession.SilentItemReplacementReason] = [
                .persistedSessionHydration, .routeActivation, .testOverride
            ]
            for reason in reasons {
                let session = AgentModeViewModel.TabSession(tabID: id(900_000))
                let sourceItems = fixture(resultCount: 2)
                session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
                let nextPayloadRevision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID.values.max()) + 1
                let keptRevision = session.ephemeralToolResultPayloadRevisionByItemID[sourceItems[1].id]
                try session.setItemsSilentlyForRetentionCompaction([sourceItems[0], compacted(sourceItems[1])])
                XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[sourceItems[1].id], keptRevision)
                var replacement = sourceItems[1]
                let raw = #"{"status":"success","output":"synthetic replacement payload","exit_code":0}"#
                replacement.text = raw
                replacement.toolResultJSON = raw
                let scannedBefore = session.test_fullRetentionPayloadMapScannedItemCount
                let sourceRevision = session.sourceItemsRevision

                session.setItemsSilently([sourceItems[0], replacement, replacement], reason: reason)

                XCTAssertEqual(session.items, [sourceItems[0], replacement])
                XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, [replacement.id: raw])
                XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, [replacement.id: nextPayloadRevision])
                XCTAssertEqual(session.test_fullRetentionPayloadMapScannedItemCount - scannedBefore, 2)
                XCTAssertEqual(session.sourceItemsRevision, sourceRevision + 1)
                XCTAssertEqual(session.nextSequenceIndex, sourceItems.count)
                XCTAssertNil(session.derivedTranscriptSyncState)
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        func testAssistantToolBoundaryPreservesCompactedPayload() throws {
            let viewModel = makeViewModel()
            let session = try compactedSession(in: viewModel)
            let result = session.items[1]
            let payload = try XCTUnwrap(viewModel.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: result.id))
            let revision = session.ephemeralToolResultPayloadRevisionByItemID[result.id]
            XCTAssertTrue(viewModel.applyAssistantDelta("Synthetic next-tool preamble", session: session))
            XCTAssertEqual(session.items.last?.isStreaming, true)

            viewModel.endActiveAssistantSegment(session)

            XCTAssertEqual(session.items.last?.isStreaming, false)
            XCTAssertEqual(viewModel.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: result.id), payload)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[result.id], revision)
        }

        func testTerminalCommitBarrierPreservesCompactedPayload() async throws {
            let viewModel = makeViewModel()
            let session = try compactedSession(in: viewModel)
            session.selectedAgent = .claudeCode
            session.installRunID(UUID())
            let ownership = session.beginRunAttempt(source: "retained-payload-terminal-test")
            let result = session.items[1]
            let payload = try XCTUnwrap(viewModel.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: result.id))
            let revision = session.ephemeralToolResultPayloadRevisionByItemID[result.id]
            XCTAssertTrue(viewModel.applyAssistantDelta("Synthetic final response", session: session))
            session.appendItem(.toolCall(
                name: "read_file", invocationID: id(700_001),
                argsJSON: #"{"path":"synthetic.swift"}"#, sequenceIndex: session.nextSequenceIndex
            ))
            defer { session.saveDebounceTask?.cancel() }

            await viewModel.test_publishNaturalCompletion(session)

            let commit = try XCTUnwrap(session.lastTerminalCommitRevision)
            XCTAssertEqual(commit.ownership, ownership)
            XCTAssertEqual(commit.terminalState, .completed)
            XCTAssertEqual(session.runState, .completed)
            XCTAssertFalse(session.items.contains { $0.isStreaming || $0.kind == .toolCall })
            XCTAssertEqual(viewModel.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: result.id), payload)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[result.id], revision)
        }

        func testSilentRepairReasonsPreserveCompactedPayloads() throws {
            for reason in [
                AgentModeViewModel.TabSession.SilentItemReplacementReason.pendingToolFinalizationRepair,
                .codexCommandStatusReconciliation, .retentionCompaction
            ] {
                let session = try compactedSession(in: makeViewModel())
                let payloads = session.ephemeralToolResultPayloadByItemID
                let revisions = session.ephemeralToolResultPayloadRevisionByItemID

                session.setItemsSilently(session.items, reason: reason)

                XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, payloads, reason.rawValue)
                XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisions, reason.rawValue)
            }
        }

        private func compactedSession(in viewModel: AgentModeViewModel) throws -> AgentModeViewModel.TabSession {
            let session = AgentModeViewModel.TabSession(tabID: id(900_000))
            session.runState = .running
            let sourceItems = fixture(resultCount: 2)
            session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
            let compactedItems = try sourceItems.map { item in
                item.kind == .toolResult ? try compacted(item) : item
            }
            session.setItemsSilentlyForRetentionCompaction(compactedItems)
            viewModel.test_installLiveSession(session)
            return session
        }

        func testPendingToolRepairRefreshesChangedPayloadsAndPrunesRemovedRows() throws {
            try assertRepairRefreshesChangedPayloadsAndPrunesRemovedRows(reason: .pendingToolFinalizationRepair)
        }

        func testBatchAndCodexRepairsRefreshChangedPayloadsAndPruneRemovedRows() throws {
            try assertRepairRefreshesChangedPayloadsAndPrunesRemovedRows(reason: nil)
            try assertRepairRefreshesChangedPayloadsAndPrunesRemovedRows(reason: .codexCommandStatusReconciliation)
        }

        private func assertRepairRefreshesChangedPayloadsAndPrunesRemovedRows(
            reason: AgentModeViewModel.TabSession.SilentItemReplacementReason?
        ) throws {
            let session = AgentModeViewModel.TabSession(tabID: id(900_000))
            var sourceItems = fixture(resultCount: 3)
            let runningPayload = #"{"status":"running","output":"synthetic partial output"}"#
            sourceItems[2].text = runningPayload
            sourceItems[2].toolResultJSON = runningPayload
            session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
            var workingItems = sourceItems
            workingItems[1] = try compacted(sourceItems[1])
            session.setItemsSilentlyForRetentionCompaction(workingItems)
            let keptID = sourceItems[1].id
            let runningID = sourceItems[2].id
            let removedID = sourceItems[3].id
            let keptPayload = try XCTUnwrap(session.ephemeralToolResultPayloadByItemID[keptID])
            let keptRevision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID[keptID])
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[runningID], runningPayload)
            XCTAssertNotNil(session.ephemeralToolResultPayloadByItemID[removedID])
            workingItems.removeAll { $0.id == removedID }
            XCTAssertEqual(AgentTranscriptIO.finalizePendingToolCalls(
                in: &workingItems, terminalState: .cancelled,
                includeExplicitRepoPromptToolCalls: true, nonToolBoundary: 8
            ), 1)
            let repairedResult = try XCTUnwrap(workingItems.first { $0.id == runningID })

            if let reason {
                session.setItemsSilently(workingItems, reason: reason)
            } else {
                XCTAssertTrue(session.mutateItemsBatch { $0 = workingItems })
            }

            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[keptID], keptPayload)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[keptID], keptRevision)
            XCTAssertNotEqual(session.ephemeralToolResultPayloadByItemID[runningID], runningPayload)
            XCTAssertEqual(
                session.ephemeralToolResultPayloadByItemID[runningID],
                AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: repairedResult)
            )
            XCTAssertNil(session.ephemeralToolResultPayloadByItemID[removedID])
            XCTAssertNil(session.ephemeralToolResultPayloadRevisionByItemID[removedID])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testSaveReconciliationPreservesCompletedToolPayload() async throws {
            try await assertSavePreservesCompletedToolPayload(repairPendingTool: false)
        }

        func testSavePendingToolRepairPreservesOtherCompletedToolPayload() async throws {
            try await assertSavePreservesCompletedToolPayload(repairPendingTool: true)
        }

        private func assertSavePreservesCompletedToolPayload(repairPendingTool: Bool) async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            defer {
                WindowStatesManager.shared.unregisterWindowState(window)
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            }
            let workspace = window.workspaceManager.createWorkspace(
                name: "Retained tool save", repoPaths: [], ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "retainedToolSaveTests")
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
            let viewModel = window.agentModeViewModel
            let session = await viewModel.ensureSessionReady(tabID: tabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
                sessionID: UUID(), on: session, updateWorkspaceMetadata: true
            ))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.hasLoadedPersistedState = true
            viewModel.test_setCurrentTabIDOverride(tabID)
            defer {
                viewModel.test_setCurrentTabIDOverride(nil)
                session.saveDebounceTask?.cancel()
                session.derivedTranscriptRefreshTask?.cancel()
            }
            var saves = 0
            viewModel.test_setAgentSessionSaver { _, _, _ in
                saves += 1
                return FileManager.default.temporaryDirectory.appendingPathComponent("retained-tool-save.json")
            }
            session.selectedAgent = .codexExec
            session.runState = .completed
            let sourceItems = fixture(resultCount: 2)
            session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
            let completedItem = try compacted(sourceItems[1])
            let payload = try XCTUnwrap(session.ephemeralToolResultPayloadByItemID[completedItem.id])
            let revision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID[completedItem.id])
            let secondResultID = sourceItems[2].id
            let secondPayload = try XCTUnwrap(session.ephemeralToolResultPayloadByItemID[secondResultID])
            let secondRevision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID[secondResultID])
            if repairPendingTool {
                let compactedItems = try sourceItems.map { item in
                    item.kind == .toolResult ? try compacted(item) : item
                }
                session.setItemsSilentlyForRetentionCompaction(compactedItems)
                viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                var pendingItems = session.items
                pendingItems.append(.toolCall(
                    name: "read_file", invocationID: id(700_000),
                    argsJSON: #"{"path":"synthetic.swift"}"#, sequenceIndex: session.nextSequenceIndex
                ))
                // Do not notify live refresh: save itself must own the pending-tool repair.
                session.setItemsSilentlyForRetentionCompaction(pendingItems)
                XCTAssertTrue(session.items.contains { $0.kind == .toolCall })
            } else {
                // One result is already summary-only; the other forces save-time sanitization.
                var mixedItems = sourceItems
                mixedItems[1] = completedItem
                session.setItemsSilentlyForRetentionCompaction(mixedItems)
            }
            XCTAssertEqual(viewModel.rawToolResultPayloadForRendering(tabID: tabID, itemID: completedItem.id), payload)
            let itemsBeforeSave = session.items
            session.isDirty = true

            await viewModel.flushSave(for: tabID)

            XCTAssertEqual(saves, 1, "The regression must exercise the real save boundary")
            XCTAssertNotEqual(session.items, itemsBeforeSave, "Save must repair or reconcile the fixture")
            XCTAssertFalse(session.items.contains { $0.kind == .toolCall })
            XCTAssertEqual(viewModel.rawToolResultPayloadForRendering(tabID: tabID, itemID: completedItem.id), payload)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[completedItem.id], revision)
            XCTAssertEqual(viewModel.rawToolResultPayloadForRendering(tabID: tabID, itemID: secondResultID), secondPayload)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[secondResultID], secondRevision)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        private func assertFullReconciliation(resultCount: Int, runState: AgentSessionRunState) {
            let viewModel = makeViewModel()
            let session = AgentModeViewModel.TabSession(tabID: id(900_000))
            let sourceItems = fixture(resultCount: resultCount)
            session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
            session.runState = runState
            let payloads = session.ephemeralToolResultPayloadByItemID
            let revisions = session.ephemeralToolResultPayloadRevisionByItemID
            let sourceRevision = session.sourceItemsRevision
            let scannedBefore = session.test_fullRetentionPayloadMapScannedItemCount
            let start = ContinuousClock.now

            viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)

            let duration = start.duration(to: .now)
            let scanned = session.test_fullRetentionPayloadMapScannedItemCount - scannedBefore
            print("RETENTION_COMPACTION_MEASUREMENT results=\(resultCount) source_items=\(sourceItems.count) run_state=\(runState.rawValue) duration=\(duration) scanned=\(scanned)")
            XCTAssertEqual(payloads.count, resultCount)
            XCTAssertNotEqual(session.items, sourceItems, "Fixture must reconcile, not take a no-op path")
            XCTAssertEqual(session.sourceItemsRevision, sourceRevision + 1)
            XCTAssertEqual(session.test_incrementalRetentionCompactionCount, 0)
            XCTAssertEqual(scanned, 0, "Full retention reconciliation must not rebuild a payload map it discards")
            let retainedIDs = Set(session.items.map(\.id))
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, payloads.filter { retainedIDs.contains($0.key) })
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisions.filter { retainedIDs.contains($0.key) })
            XCTAssertEqual(session.liveItemIDs, retainedIDs)
            XCTAssertEqual(session.nextSequenceIndex, sourceItems.count)
            XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        private func compacted(_ item: AgentChatItem) throws -> AgentChatItem {
            let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
            var result = item
            result.text = sanitized.text
            result.toolResultJSON = sanitized.resultJSON
            result.toolIsError = sanitized.toolIsError
            return result
        }

        private func fixture(resultCount: Int) -> [AgentChatItem] {
            let timestamp = Date(timeIntervalSince1970: 1000)
            var items = [AgentChatItem(id: id(1), timestamp: timestamp, kind: .user, text: "Synthetic request", sequenceIndex: 0)]
            for index in 0 ..< resultCount {
                let raw = "{\"status\":\"success\",\"output\":\"synthetic retained payload \(index)\",\"exit_code\":0}"
                items.append(AgentChatItem(
                    id: id(index + 2), timestamp: timestamp, kind: .toolResult, text: raw,
                    toolName: "read_file", toolInvocationID: id(index + 200_000),
                    toolResultJSON: raw, toolIsError: false, sequenceIndex: index + 1
                ))
            }
            items.append(AgentChatItem(
                id: id(resultCount + 2), timestamp: timestamp, kind: .assistant,
                text: "Synthetic completed response. This fixture contains no production transcript or personal data.",
                sequenceIndex: resultCount + 1
            ))
            return items
        }

        private func makeViewModel() -> AgentModeViewModel {
            AgentModeViewModel(
                testWindowID: -992,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in
                    preconditionFailure("Retention tests must not start a provider")
                },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpServerEnabler: { true }
            )
        }

        private func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
    }

    /// The Codex fresh-thread recovery notice is an ordinary `.system` row that retention
    /// demotion discards. These tests pin the typed `recoveryDiagnostics` summary carrier:
    /// the notice must be captured before trimming, survive every tier transition and
    /// Codable round-trip, and render exactly once through the compacted projections,
    /// `get_log`, and history.
    final class AgentTranscriptRecoveryDiagnosticTests: XCTestCase {
        private let noticeText =
            "Codex couldn't resume the previous thread because its history was too large to load. Started a fresh thread."

        // MARK: - Defect A: summary-carried diagnostic survives demotion

        func testZeroToolTurnDiagnosticSurvivesDemotionAcrossSerialization() throws {
            try assertDiagnosticSurvivesDemotion(includeTools: false)
        }

        func testToolBearingTurnDiagnosticSurvivesDemotionAcrossSerialization() throws {
            try assertDiagnosticSurvivesDemotion(includeTools: true)
        }

        /// A demoted turn that keeps its conclusion activity is *not* structurally
        /// compacted; the notice must still project exactly once.
        private func assertDiagnosticSurvivesDemotion(includeTools: Bool) throws {
            let transcript = recoveryTranscript(includeTools: includeTools)
            let fullTurn = try XCTUnwrap(transcript.turns.first)
            let diagnosticActivity = try XCTUnwrap(fullTurn.allActivities.first { $0.itemKind == .system })
            let expectedDiagnostic = try XCTUnwrap(diagnosticActivity.recoveryDiagnostic)
            XCTAssertEqual(expectedDiagnostic.id, diagnosticActivity.id)
            XCTAssertEqual(expectedDiagnostic.sequenceIndex, diagnosticActivity.sequenceIndex)

            var current = transcript
            for tier in [AgentTranscriptRetentionTier.condensed, .summary, .archived] {
                current.turns[0].retentionTier = tier
                current = AgentTranscriptCompactor.compact(current)
                let turn = try XCTUnwrap(current.turns.first)

                // The conclusion row is retained, so the structurally-compacted predicate
                // stays false at every tier.
                XCTAssertFalse(turn.isStructurallyCompacted, "tier \(tier)")
                let conclusionID = try XCTUnwrap(turn.conclusionActivityID)
                XCTAssertTrue(turn.allActivities.contains { $0.id == conclusionID }, "tier \(tier)")

                // The notice row itself is trimmed; only the typed record remains.
                XCTAssertFalse(turn.allActivities.contains { $0.id == diagnosticActivity.id }, "tier \(tier)")
                XCTAssertEqual(
                    turn.summary?.recoveryDiagnostics,
                    [expectedDiagnostic],
                    "tier \(tier)"
                )

                let decoded = try JSONDecoder().decode(
                    AgentTranscript.self,
                    from: JSONEncoder().encode(current)
                )
                XCTAssertEqual(
                    decoded.turns.first?.summary?.recoveryDiagnostics,
                    [expectedDiagnostic],
                    "tier \(tier) round-trip"
                )

                let projection = AgentTranscriptProjectionBuilder.build(from: current)
                let noticeRows = (projection.workingRows + projection.archivedRows)
                    .filter { $0.text == noticeText }
                XCTAssertEqual(noticeRows.count, 1, "tier \(tier) projection")
                XCTAssertEqual(noticeRows.first?.kind, .system)
                XCTAssertEqual(noticeRows.first?.id, expectedDiagnostic.id)
                XCTAssertEqual(noticeRows.first?.recoveryDiagnostic, expectedDiagnostic)

                let xml = AgentTranscriptIO.buildSpartanLogXML(from: current)
                XCTAssertEqual(
                    xml.components(separatedBy: noticeText).count - 1,
                    1,
                    "tier \(tier) get_log"
                )
            }
        }

        /// A fully collapsed turn (no retained activities at all) still renders the notice
        /// exactly once through both the block projection and the spartan log.
        func testStructurallyCompactedTurnEmitsDiagnosticExactlyOnce() throws {
            var transcript = recoveryTranscript(includeTools: false)
            transcript.turns[0].retentionTier = .summary
            var compacted = AgentTranscriptCompactor.compact(transcript)
            var turn = try XCTUnwrap(compacted.turns.first)
            // Simulate the fully-collapsed edge: no activities, no conclusion.
            turn.responseSpans[0].activities = []
            turn.conclusionActivityID = nil
            compacted.turns[0] = turn
            XCTAssertTrue(turn.isStructurallyCompacted)

            let projection = AgentTranscriptProjectionBuilder.build(from: compacted)
            let allRows = projection.workingRows + projection.archivedRows
            let noticeRows = allRows.filter { $0.text == noticeText }
            XCTAssertEqual(noticeRows.count, 1)

            // Fixed placement contract: request → diagnostics → conclusion, shared by the
            // row projection, block builders, and history get_session.
            let requestIndex = allRows.firstIndex { $0.kind == .user }
            let noticeIndex = allRows.firstIndex { $0.id == turn.summary?.recoveryDiagnostics?.first?.id }
            let conclusionIndex = allRows.lastIndex { $0.kind == .assistant }
            XCTAssertTrue(try XCTUnwrap(requestIndex) < XCTUnwrap(noticeIndex))
            XCTAssertTrue(try XCTUnwrap(noticeIndex) < XCTUnwrap(conclusionIndex))

            let xml = AgentTranscriptIO.buildSpartanLogXML(from: compacted)
            XCTAssertEqual(xml.components(separatedBy: noticeText).count - 1, 1)
        }

        // MARK: - Defect B: export rewrites only the generated summary row

        /// The same transcript carries a full-tier turn (genuine `.system` notice in the
        /// working rows) and an archived turn (generated middle-summary row plus the same
        /// notice rebuilt from the diagnostic). Export must leave the notice text untouched
        /// on both while still rewriting the synthetic summary row.
        func testExportRewritesSyntheticSummaryRowButNotRecoveryDiagnostic() throws {
            var transcript = recoveryTranscript(includeTools: true)
            // Second turn: archived demotion of the same shape.
            let archivedSource = recoveryTranscript(includeTools: true)
            var archivedTranscript = archivedSource
            archivedTranscript.turns[0].retentionTier = .archived
            var archivedTurn = try XCTUnwrap(
                AgentTranscriptCompactor.compact(archivedTranscript).turns.first
            )
            // Re-seat the archived turn after the full turn so both survive in one export.
            let sequenceBase = transcript.nextSequenceIndex
            archivedTurn.request?.sequenceIndex += sequenceBase
            for spanIndex in archivedTurn.responseSpans.indices {
                for activityIndex in archivedTurn.responseSpans[spanIndex].activities.indices {
                    archivedTurn.responseSpans[spanIndex].activities[activityIndex].sequenceIndex += sequenceBase
                }
            }
            if var diagnostics = archivedTurn.summary?.recoveryDiagnostics {
                for index in diagnostics.indices {
                    diagnostics[index].sequenceIndex += sequenceBase
                }
                archivedTurn.summary?.recoveryDiagnostics = diagnostics
            }
            transcript.turns.append(archivedTurn)

            // buildForkTranscriptXML exports with no cutoff, covering both turns' rows.
            let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

            // The genuine notice rows keep their verbatim text in both turns.
            XCTAssertEqual(xml.components(separatedBy: noticeText).count - 1, 2)
            // The archived turn's generated middle-summary row is rewritten to handoff
            // summary text: its verbatim "1 tool called" form must not appear, while the
            // handoff rendering still names the tool.
            let summary = try XCTUnwrap(archivedTurn.summary)
            XCTAssertEqual(summary.middleSummaryText?.contains("tool called"), true)
            XCTAssertFalse(xml.contains("tool called"))
            XCTAssertTrue(xml.contains("read_file"))
        }

        // MARK: - Defect A: history get_session and search

        /// `get_session`'s default roles exclude `system` rows and its summary entry is gated
        /// on `isStructurallyCompacted`. The diagnostic must still surface — under the
        /// "summary" role — for a demoted turn that retains its conclusion, and it must stay
        /// searchable through the summary contract.
        func testHistoryExposesDiagnosticForDemotedTurnThatRetainedConclusion() async throws {
            var transcript = recoveryTranscript(includeTools: false)
            transcript.turns[0].retentionTier = .summary
            let compacted = AgentTranscriptCompactor.compact(transcript)
            let turn = try XCTUnwrap(compacted.turns.first)
            XCTAssertFalse(turn.isStructurallyCompacted)

            let sessionID = UUID()
            let scanner = try seededScanner(sessionID: sessionID, transcript: compacted)

            let reply = try await HistoryMCPToolService.execute(
                args: [
                    "op": .string("get_session"),
                    "session_id": .string(sessionID.uuidString),
                    "turn_start": .int(0),
                    "turn_end": .int(0)
                ],
                scanner: scanner
            )
            guard case let .getSession(getSession) = reply else {
                return XCTFail("Expected get_session reply, got \(reply)")
            }
            let noticeEntries = getSession.turns
                .flatMap(\.entries)
                .filter { $0.text.contains("too large to load") }
            XCTAssertEqual(noticeEntries.count, 1)
            XCTAssertEqual(noticeEntries.first?.role, "summary")

            let searchReply = try await HistoryMCPToolService.execute(
                args: [
                    "op": .string("search"),
                    "query": .string("too large to load")
                ],
                scanner: scanner
            )
            guard case let .search(search) = searchReply else {
                return XCTFail("Expected search reply, got \(searchReply)")
            }
            let matches = search.results.filter { $0.snippet.contains("too large to load") }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.source, "summary")
            XCTAssertEqual(matches.first?.role, "system")
        }

        /// A full-tier turn keeps its live `.system` row *and* carries the summary record;
        /// search must match the live row once, not once per carrier.
        func testFullTierSearchMatchesLiveRowWithoutSummaryDuplicate() async throws {
            let transcript = recoveryTranscript(includeTools: false)
            let turn = try XCTUnwrap(transcript.turns.first)
            XCTAssertEqual(turn.retentionTier, .full)
            XCTAssertNotNil(turn.summary?.recoveryDiagnostics)

            let sessionID = UUID()
            let scanner = try seededScanner(sessionID: sessionID, transcript: transcript)

            let searchReply = try await HistoryMCPToolService.execute(
                args: [
                    "op": .string("search"),
                    "query": .string("too large to load")
                ],
                scanner: scanner
            )
            guard case let .search(search) = searchReply else {
                return XCTFail("Expected search reply, got \(searchReply)")
            }
            let matches = search.results.filter { $0.snippet.contains("too large to load") }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.source, "activity")
            XCTAssertEqual(matches.first?.role, "system")
        }

        /// A fully collapsed turn (no activities at all) takes the pre-existing summary-entry
        /// path as well; the diagnostic is still emitted exactly once.
        func testHistoryExposesDiagnosticForStructurallyCompactedTurn() async throws {
            var transcript = recoveryTranscript(includeTools: false)
            transcript.turns[0].retentionTier = .summary
            var compacted = AgentTranscriptCompactor.compact(transcript)
            var turn = try XCTUnwrap(compacted.turns.first)
            turn.responseSpans[0].activities = []
            turn.conclusionActivityID = nil
            compacted.turns[0] = turn
            XCTAssertTrue(turn.isStructurallyCompacted)

            let sessionID = UUID()
            let scanner = try seededScanner(sessionID: sessionID, transcript: compacted)

            let reply = try await HistoryMCPToolService.execute(
                args: [
                    "op": .string("get_session"),
                    "session_id": .string(sessionID.uuidString),
                    "turn_start": .int(0),
                    "turn_end": .int(0)
                ],
                scanner: scanner
            )
            guard case let .getSession(getSession) = reply else {
                return XCTFail("Expected get_session reply, got \(reply)")
            }
            let noticeEntries = getSession.turns
                .flatMap(\.entries)
                .filter { $0.text.contains("too large to load") }
            XCTAssertEqual(noticeEntries.count, 1)
            XCTAssertEqual(noticeEntries.first?.role, "summary")
        }

        /// Recovery diagnostics must not displace the conclusion within the per-turn cap.
        func testGetSessionCapsCompactedDiagnosticsAndSummaryAtPerTurnEntryLimit() async throws {
            try await assertGetSessionPreservesConclusionAtEntryLimit(structurallyCompacted: true)
        }

        func testGetSessionCapsDemotedDiagnosticsAndConclusionAtPerTurnEntryLimit() async throws {
            try await assertGetSessionPreservesConclusionAtEntryLimit(structurallyCompacted: false)
        }

        private func assertGetSessionPreservesConclusionAtEntryLimit(structurallyCompacted: Bool) async throws {
            var transcript = recoveryTranscript(includeTools: false)
            transcript.turns[0].retentionTier = .summary
            var compacted = AgentTranscriptCompactor.compact(transcript)
            var turn = try XCTUnwrap(compacted.turns.first)
            if structurallyCompacted {
                turn.responseSpans[0].activities = []
                turn.conclusionActivityID = nil
            }
            var summary = try XCTUnwrap(turn.summary)
            summary.compactConclusionText = "Compacted conclusion."
            summary.recoveryDiagnostics = (0 ..< AgentTranscriptRecoveryDiagnostic.maximumPerTurn).map { index in
                AgentTranscriptRecoveryDiagnostic(
                    sequenceIndex: index,
                    reason: "resumeFrameTooLarge",
                    outcome: AgentTranscriptRecoveryDiagnostic.freshThreadStartedOutcome,
                    text: noticeText
                )
            }
            turn.summary = summary
            compacted.turns[0] = turn
            XCTAssertEqual(turn.isStructurallyCompacted, structurallyCompacted)
            XCTAssertEqual(turn.summary?.normalizedRecoveryDiagnostics.count, 20)

            let sessionID = UUID()
            let scanner = try seededScanner(sessionID: sessionID, transcript: compacted)

            let reply = try await HistoryMCPToolService.execute(
                args: [
                    "op": .string("get_session"),
                    "session_id": .string(sessionID.uuidString),
                    "turn_start": .int(0),
                    "turn_end": .int(0)
                ],
                scanner: scanner
            )
            guard case let .getSession(getSession) = reply else {
                return XCTFail("Expected get_session reply, got \(reply)")
            }
            let rendered = try XCTUnwrap(getSession.turns.first)
            XCTAssertEqual(rendered.entries.count, 20)
            XCTAssertEqual(
                rendered.entries.count(where: { $0.text.contains("too large to load") }),
                19
            )
            XCTAssertEqual(rendered.entries.last?.role, structurallyCompacted ? "summary" : "assistant")
            XCTAssertEqual(rendered.entries.last?.text, structurallyCompacted ? "Compacted conclusion." : "Done.")
            XCTAssertEqual(rendered.entriesOmitted, 1)
            XCTAssertTrue(rendered.truncated)
        }

        // MARK: - Helpers

        private func makeDiagnostic() -> AgentTranscriptRecoveryDiagnostic {
            AgentTranscriptRecoveryDiagnostic(
                reason: "resumeFrameTooLarge",
                outcome: AgentTranscriptRecoveryDiagnostic.freshThreadStartedOutcome,
                previousConversationID: "01936F84-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                replacementConversationID: "01936F85-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                text: noticeText
            )
        }

        /// user → [tool call/result] → system recovery notice → assistant conclusion.
        private func recoveryTranscript(includeTools: Bool) -> AgentTranscript {
            var items: [AgentChatItem] = [
                .user("ship the fix", sequenceIndex: 0)
            ]
            var sequence = 1
            if includeTools {
                let invocation = UUID()
                items.append(.toolCall(
                    name: "read_file",
                    invocationID: invocation,
                    argsJSON: #"{"path":"a.swift"}"#,
                    sequenceIndex: sequence
                ))
                sequence += 1
                items.append(.toolResult(
                    name: "read_file",
                    invocationID: invocation,
                    resultJSON: #"{"ok":true}"#,
                    isError: false,
                    sequenceIndex: sequence
                ))
                sequence += 1
            }
            items.append(.system(
                noticeText,
                sequenceIndex: sequence,
                recoveryDiagnostic: makeDiagnostic()
            ))
            sequence += 1
            items.append(.assistant("Done.", sequenceIndex: sequence))
            return AgentTranscriptIO.importLegacyItems(items, terminalState: .completed)
        }

        /// Writes a workspace + session file + metadata index under a fresh temp
        /// `applicationSupport` root and returns a scanner pointed at it.
        private func seededScanner(
            sessionID: UUID,
            transcript: AgentTranscript
        ) throws -> HistorySessionScanner {
            let appSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("RecoveryDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
            let workspaceDir = appSupport
                .appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent("Workspace-Recovery", isDirectory: true)
            let agentSessionsDir = workspaceDir
                .appendingPathComponent("AgentSessions", isDirectory: true)
            try FileManager.default.createDirectory(
                at: agentSessionsDir,
                withIntermediateDirectories: true
            )
            let session = AgentSession(id: sessionID, name: "Recovery session", transcript: transcript)
            try JSONEncoder().encode(session).write(
                to: agentSessionsDir.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
            )
            let date = Date(timeIntervalSinceReferenceDate: 1000)
            let index = AgentSessionMetadataIndex(entries: [
                AgentSessionMetadataRecord(
                    id: sessionID,
                    filename: "AgentSession-\(sessionID.uuidString).json",
                    workspaceID: nil,
                    composeTabID: nil,
                    name: "Recovery session",
                    savedAt: date,
                    lastUserMessageAt: nil,
                    itemCount: 0,
                    transcriptProjectionCounts: nil,
                    hasUnknownConversationContent: false,
                    agentKindRaw: nil,
                    agentModelRaw: nil,
                    agentReasoningEffortRaw: nil,
                    lastRunStateRaw: nil,
                    autoEditEnabled: true,
                    parentSessionID: nil,
                    isMCPOriginated: true,
                    serializationVersion: nil,
                    observedFileSize: nil,
                    observedFileModificationDate: date,
                    lastIndexedAt: date
                )
            ])
            try JSONEncoder().encode(index).write(
                to: agentSessionsDir.appendingPathComponent("AgentSessionIndex.json")
            )
            return HistorySessionScanner(applicationSupportRoot: appSupport, scanCacheTTL: 0)
        }
    }
#endif
