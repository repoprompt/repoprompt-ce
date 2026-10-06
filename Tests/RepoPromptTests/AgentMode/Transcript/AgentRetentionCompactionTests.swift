#if DEBUG
    import Foundation
    @_spi(TestSupport) @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class AgentRetentionCompactionTests: XCTestCase {
        func testFullReconciliationPreservesPayloadsAndMeasuresRetentionScan() {
            for resultCount in [128, 1000, 4000, 16000] {
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
                .persistedSessionHydration, .routeActivation, .testOverride, .retentionCompaction
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
#endif
