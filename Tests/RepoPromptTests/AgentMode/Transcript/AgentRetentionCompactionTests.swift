#if DEBUG
    import Foundation
    @_spi(TestSupport) @testable import RepoPromptApp
    import XCTest

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

    // MARK: - Transcript pipeline timing (diagnostic)

    /// Transcript pipeline timing diagnostic — not an acceptance gate.
    ///
    /// Measures, per synthetic session size: legacy-item import (`AgentTranscriptIO.buildTranscript`
    /// with `compact: false`), compaction/retention (`AgentTranscriptCompactor.compact`), full
    /// projection (`AgentTranscriptProjectionBuilder.build`), the default tail window
    /// (`tailWindowedProjection`), and the persistence pipeline
    /// (`AgentTranscriptPolicyPipeline.persistedTranscript`). Each stage is one wall-clock sample
    /// (monotonic `DispatchTime`), no warmup, in whatever build configuration the test bundle uses
    /// (debug/unoptimized for `make dev-test`), so numbers are only comparable on the same machine,
    /// configuration and fixture parameters. Results are printed as machine-readable
    /// `TRANSCRIPT_TIMING` and `TRANSCRIPT_BYTES` lines that carry the fixture parameters.
    ///
    /// Opt-in through the existing scale-test flag; see
    /// docs/testing.md#agent-transcript-pipeline-timing-diagnostics for the exact command.
    /// When enabled it measures 50, 150, 300 and 1000 turns. There is deliberately no wall-clock
    /// threshold yet: import
    /// and compaction are currently super-linear in turn count, so any bound would only restate
    /// today's numbers. Transcript PR 3 (removing display compaction) is expected to make the
    /// pipeline near-linear and will add a real acceptance threshold.
    ///
    /// Self-contained: depends only on pre-existing transcript APIs, so it can be copied onto
    /// another revision for a controlled before/after comparison.
    final class AgentTranscriptProjectionTimingDiagnostics: XCTestCase {
        private static let turnCounts = [50, 150, 300, 1000]
        private static let toolCallsPerTurn = 4
        /// User request + assistant opener + call/result per tool + assistant conclusion.
        private static let itemsPerTurn = 3 + toolCallsPerTurn * 2
        private static let toolResultLineCount = 24

        func testTranscriptPipelineTimingAcrossSessionSizes() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1",
                "Opt-in diagnostic: see docs/testing.md#agent-transcript-pipeline-timing-diagnostics"
            )
            for turnCount in Self.turnCounts {
                try measurePipeline(turnCount: turnCount)
            }
        }

        private func measurePipeline(turnCount: Int) throws {
            let fixture = Self.makeFixture(turnCount: turnCount)

            var raw: AgentTranscript!
            let importSeconds = Self.measure {
                raw = AgentTranscriptIO.buildTranscript(
                    from: fixture.items,
                    terminalState: .completed,
                    nextSequenceIndex: fixture.nextSequenceIndex,
                    compact: false
                )
            }
            var compacted: AgentTranscript!
            let compactSeconds = Self.measure {
                compacted = AgentTranscriptCompactor.compact(raw)
            }
            var projection: AgentTranscriptProjection!
            let projectionSeconds = Self.measure {
                projection = AgentTranscriptProjectionBuilder.build(from: compacted)
            }
            var window: AgentTranscriptProjection!
            let windowSeconds = Self.measure {
                window = AgentTranscriptProjectionBuilder.tailWindowedProjection(
                    from: projection,
                    transcript: compacted,
                    isExpanded: false
                )
            }
            var persisted: AgentTranscriptPolicyPipeline.Result!
            let persistSeconds = Self.measure {
                persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: compacted)
            }

            let encodedRawBytes = try JSONEncoder().encode(raw).count
            let encodedCompactedBytes = try JSONEncoder().encode(compacted).count
            let encodedPersistedBytes = try JSONEncoder().encode(persisted.transcript).count
            let tierCounts = Dictionary(grouping: compacted.turns, by: { "\($0.retentionTier)" }).mapValues(\.count)
            let tierSummary = tierCounts.keys.sorted().map { "\($0):\(tierCounts[$0] ?? 0)" }.joined(separator: ",")
            let fixtureFields = "turns=\(turnCount) itemsPerTurn=\(Self.itemsPerTurn)"
                + " toolCallsPerTurn=\(Self.toolCallsPerTurn) toolResultPayloadBytes=\(fixture.averageToolResultBytes)"
                + " items=\(fixture.items.count)"
            print(
                "TRANSCRIPT_TIMING \(fixtureFields)"
                    + " importMS=\(Self.ms(importSeconds)) compactMS=\(Self.ms(compactSeconds))"
                    + " projectionMS=\(Self.ms(projectionSeconds)) windowMS=\(Self.ms(windowSeconds))"
                    + " persistMS=\(Self.ms(persistSeconds))"
                    + " workingUnits=\(projection.workingUnitCount) visibleBlocks=\(window.workingBlocks.count)"
                    + " fullBlocks=\(projection.workingBlocks.count) archivedBlocks=\(projection.archivedBlocks.count)"
                    + " tiers=\(tierSummary)"
            )
            print(
                "TRANSCRIPT_BYTES \(fixtureFields)"
                    + " rawFullDetailBytes=\(AgentTranscriptCompactor.retainedFullDetailBytes(for: raw))"
                    + " retainedFullDetailBytes=\(AgentTranscriptCompactor.retainedFullDetailBytes(for: compacted))"
                    + " encodedRawBytes=\(encodedRawBytes) encodedCompactedBytes=\(encodedCompactedBytes)"
                    + " encodedPersistedBytes=\(encodedPersistedBytes)"
            )

            // Fixture contracts: every synthetic user request becomes a turn, compaction keeps every
            // turn addressable, and both projections render something.
            XCTAssertEqual(raw.turns.count, turnCount)
            XCTAssertEqual(compacted.turns.count, turnCount)
            XCTAssertFalse(projection.workingBlocks.isEmpty)
            XCTAssertFalse(window.workingBlocks.isEmpty)
        }

        // MARK: Synthetic fixture

        private struct Fixture {
            let items: [AgentChatItem]
            let nextSequenceIndex: Int
            let averageToolResultBytes: Int
        }

        /// Each turn: user request, assistant opener, `toolCallsPerTurn` tool call/result pairs with
        /// ~1.5 KB JSON results, and a markdown assistant conclusion.
        private static func makeFixture(turnCount: Int) -> Fixture {
            var items: [AgentChatItem] = []
            items.reserveCapacity(turnCount * itemsPerTurn)
            var sequenceIndex = 0
            var toolResultBytes = 0
            func append(_ item: AgentChatItem) {
                items.append(item)
                sequenceIndex += 1
            }
            let toolNames = ["read_file", "file_search", "apply_edits", "bash"]
            for turn in 0 ..< turnCount {
                append(.user(
                    "Turn \(turn): investigate the transcript scroll regression in module \(turn % 17) and propose a fix.",
                    sequenceIndex: sequenceIndex
                ))
                append(.assistant(
                    "I'll start by reading the relevant files for turn \(turn) and searching for the scroll anchor code paths.",
                    sequenceIndex: sequenceIndex
                ))
                for call in 0 ..< toolCallsPerTurn {
                    let toolName = toolNames[call % toolNames.count]
                    let invocationID = UUID()
                    let resultJSON = toolResultJSON(turn: turn, call: call)
                    toolResultBytes += resultJSON.utf8.count
                    append(.toolCall(
                        name: toolName,
                        invocationID: invocationID,
                        argsJSON: "{\"path\":\"Sources/Module\(turn % 17)/File\(call).swift\",\"start_line\":\(call * 40 + 1),\"limit\":40}",
                        sequenceIndex: sequenceIndex
                    ))
                    append(.toolResult(
                        name: toolName,
                        invocationID: invocationID,
                        resultJSON: resultJSON,
                        isError: false,
                        sequenceIndex: sequenceIndex
                    ))
                }
                append(.assistant(
                    """
                    ## Turn \(turn) conclusion

                    The anchor drift comes from height changes above the viewport in module \(turn % 17).
                    - Preserve the anchor row offset across relayout.
                    - Keep following only within the bottom threshold.

                    ```swift
                    let adjustment = model.layoutDidChange(from: old, to: new, clipOriginY: origin)
                    ```
                    """,
                    sequenceIndex: sequenceIndex
                ))
            }
            let toolResultCount = max(1, turnCount * toolCallsPerTurn)
            return Fixture(
                items: items,
                nextSequenceIndex: sequenceIndex,
                averageToolResultBytes: toolResultBytes / toolResultCount
            )
        }

        private static func toolResultJSON(turn: Int, call: Int) -> String {
            let lines = (0 ..< toolResultLineCount).map { line in
                "\(call * 40 + line + 1): let value\(line) = compute(turn: \(turn), call: \(call), line: \(line))"
            }
            let content = lines.joined(separator: "\\n")
            return "{\"path\":\"Sources/Module\(turn % 17)/File\(call).swift\",\"content\":\"\(content)\",\"total_lines\":400}"
        }

        private static func measure(_ work: () -> Void) -> TimeInterval {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }

        private static func ms(_ seconds: TimeInterval) -> String {
            String(format: "%.1f", seconds * 1000)
        }
    }
#endif
