#if DEBUG
    import Foundation
    @_spi(TestSupport) @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class AgentRetentionCompactionTests: XCTestCase {
        func testFullReconciliationPreservesPayloadsAndMeasuresRetentionScan() {
            for resultCount in [128, 1000, 4000, 16000] {
                let viewModel = makeViewModel()
                let session = AgentModeViewModel.TabSession(tabID: id(900000))
                let sourceItems = fixture(resultCount: resultCount)
                session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
                session.runState = .idle
                let payloads = session.ephemeralToolResultPayloadByItemID
                let revisions = session.ephemeralToolResultPayloadRevisionByItemID
                let sourceRevision = session.sourceItemsRevision
                let scannedBefore = session.test_fullRetentionPayloadMapScannedItemCount
                let start = ContinuousClock.now

                viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)

                let duration = start.duration(to: .now)
                let scanned = session.test_fullRetentionPayloadMapScannedItemCount - scannedBefore
                print("RETENTION_COMPACTION_MEASUREMENT results=\(resultCount) source_items=\(sourceItems.count) duration=\(duration) scanned=\(scanned)")
                XCTAssertEqual(payloads.count, resultCount)
                XCTAssertNotEqual(session.items, sourceItems, "Fixture must reconcile, not take a no-op path")
                XCTAssertEqual(session.sourceItemsRevision, sourceRevision + 1)
                XCTAssertEqual(session.test_incrementalRetentionCompactionCount, 0)
                XCTAssertEqual(scanned, session.items.count, "Baseline discarded rebuild scans every reconciled item")
                let retainedIDs = Set(session.items.map(\.id))
                XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, payloads.filter { retainedIDs.contains($0.key) })
                XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisions.filter { retainedIDs.contains($0.key) })
                XCTAssertEqual(session.liveItemIDs, retainedIDs)
                XCTAssertEqual(session.nextSequenceIndex, sourceItems.count)
                XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        private func fixture(resultCount: Int) -> [AgentChatItem] {
            let timestamp = Date(timeIntervalSince1970: 1000)
            var items = [AgentChatItem(id: id(1), timestamp: timestamp, kind: .user, text: "Synthetic request", sequenceIndex: 0)]
            for index in 0 ..< resultCount {
                let raw = "{\"status\":\"success\",\"output\":\"synthetic retained payload \(index)\",\"exit_code\":0}"
                items.append(AgentChatItem(
                    id: id(index + 2), timestamp: timestamp, kind: .toolResult, text: raw,
                    toolName: "read_file", toolInvocationID: id(index + 200000),
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
