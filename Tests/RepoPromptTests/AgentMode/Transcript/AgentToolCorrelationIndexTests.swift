#if DEBUG
    import Foundation
    import XCTest
    @_spi(TestSupport) @testable import RepoPrompt

    @MainActor
    final class AgentToolCorrelationIndexTests: XCTestCase {
        func testIncrementalMutationAndFullReplacementKeepCorrelationIndexesAligned() throws {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            let priorInvocationID = UUID()
            let activeInvocationID = UUID()
            let pendingArgs = #"{"path":"Sources/Active.swift"}"#
            let pendingSignature = AgentModeViewModel.TabSession.canonicalToolInvocationSignature(
                toolName: "read_file",
                argsJSON: pendingArgs
            )
            session.setItemsSilently([
                .user("prior", sequenceIndex: 0),
                .toolResult(
                    name: "read_file",
                    invocationID: priorInvocationID,
                    resultJSON: "prior",
                    isError: false,
                    sequenceIndex: 1
                ),
                .user("active", sequenceIndex: 2),
                .toolCall(
                    name: "read_file",
                    invocationID: activeInvocationID,
                    argsJSON: pendingArgs,
                    sequenceIndex: 3
                )
            ], reason: .persistedSessionHydration)

            XCTAssertTrue(session.indexedToolItemIndices(invocationID: priorInvocationID).isEmpty)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: activeInvocationID), [3])
            XCTAssertEqual(session.indexedToolItemIndices(signature: pendingSignature, pendingCallsOnly: true), [3])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))

            let activeItemID = session.items[3].id
            var completed = session.items[3]
            completed.kind = .toolResult
            completed.toolResultJSON = #"{"status":"success"}"#
            completed.text = completed.toolResultJSON ?? ""
            session.replaceItem(at: 3, with: completed)

            XCTAssertEqual(session.items[3].id, activeItemID)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: activeInvocationID), [3])
            XCTAssertTrue(session.indexedToolItemIndices(signature: pendingSignature, pendingCallsOnly: true).isEmpty)
            XCTAssertEqual(session.indexedToolItemIndices(signature: pendingSignature), [3])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))

            _ = try XCTUnwrap(session.removeItem(at: 3))
            XCTAssertTrue(session.indexedToolItemIndices(invocationID: activeInvocationID).isEmpty)
            XCTAssertFalse(session.liveItemIDs.contains(activeItemID))

            let replacementInvocationID = UUID()
            session.setItemsSilently([
                .user("replacement", sequenceIndex: 10),
                .toolCall(
                    name: "file_search",
                    invocationID: replacementInvocationID,
                    argsJSON: #"{"pattern":"needle"}"#,
                    sequenceIndex: 11
                )
            ], reason: .retentionCompaction)

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: replacementInvocationID), [1])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testActiveTurnPrefixRetentionPreservesToolCorrelationBoundary() {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            let firstActiveInvocationID = UUID()
            let secondActiveInvocationID = UUID()
            session.setItemsSilently([
                .user("historical", sequenceIndex: 0),
                .assistant("historical response", sequenceIndex: 1),
                .user("active", sequenceIndex: 2),
                .toolCall(
                    name: "read_file",
                    invocationID: firstActiveInvocationID,
                    argsJSON: #"{"path":"Sources/First.swift"}"#,
                    sequenceIndex: 3
                )
            ], reason: .testOverride)
            session.runState = .running
            session.appendItem(.user("steering", sequenceIndex: session.nextSequenceIndex))
            session.appendItem(.toolCall(
                name: "file_search",
                invocationID: secondActiveInvocationID,
                argsJSON: #"{"pattern":"needle"}"#,
                sequenceIndex: session.nextSequenceIndex
            ))

            session.setItemsSilently(Array(session.items.dropFirst(2)), reason: .retentionCompaction)

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: firstActiveInvocationID), [1])
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: secondActiveInvocationID), [3])
            let activeCalls = session.activeTurnToolItemIndices { $0.kind == .toolCall }
            XCTAssertEqual(activeCalls.indices, [1, 3])
            XCTAssertEqual(activeCalls.scannedItemCount, 3)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testClaudeCompletionObserverUsesConstantWorkInvocationIndex() throws {
            let handler = ClaudeAgentToolTrackingHandler()
            let short = makeSession(priorTurnCount: 1)
            let long = makeSession(priorTurnCount: 2000)

            let shortAttribution = try claudeCompletionAttribution(
                handler: handler,
                session: short.session,
                invocationID: short.invocationID
            )
            let longAttribution = try claudeCompletionAttribution(
                handler: handler,
                session: long.session,
                invocationID: long.invocationID
            )

            XCTAssertEqual(shortAttribution.correlationPath, "invocation_id")
            XCTAssertEqual(longAttribution.correlationPath, "invocation_id")
            XCTAssertEqual(shortAttribution.scannedItemCount, 1)
            XCTAssertEqual(longAttribution.scannedItemCount, 1)
        }

        func testRunningSteeringUserItemPreservesInFlightToolCorrelation() {
            let handler = ClaudeAgentToolTrackingHandler()
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            let invocationID = UUID()
            session.setItemsSilently([
                .user("active", sequenceIndex: 0),
                .toolCall(
                    name: "read_file",
                    invocationID: invocationID,
                    argsJSON: #"{"path":"Sources/Active.swift"}"#,
                    sequenceIndex: 1
                )
            ], reason: .testOverride)
            session.runState = .running

            session.appendItem(.user("steering", sequenceIndex: session.nextSequenceIndex))

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocationID), [1])

            handler.handleTrackerToolResult(
                invocationID: invocationID,
                toolName: "read_file",
                args: nil,
                resultJSON: #"{"content":"ok"}"#,
                isError: false,
                session: session
            )

            XCTAssertEqual(session.items.count, 3)
            XCTAssertEqual(session.items[1].kind, .toolResult)
            XCTAssertEqual(session.items[1].toolInvocationID, invocationID)
            XCTAssertEqual(session.items[2].kind, .user)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        private func claudeCompletionAttribution(
            handler: ClaudeAgentToolTrackingHandler,
            session: AgentModeViewModel.TabSession,
            invocationID: UUID
        ) throws -> MCPToolObserverAttribution {
            let recorder = MCPToolObserverAttributionRecorder()
            MCPToolObserverAttributionContext.$recorder.withValue(recorder) {
                handler.handleTrackerToolResult(
                    invocationID: invocationID,
                    toolName: "read_file",
                    args: nil,
                    resultJSON: #"{"content":"ok"}"#,
                    isError: false,
                    session: session
                )
            }
            XCTAssertEqual(session.items.last?.kind, .toolResult)
            return try XCTUnwrap(recorder.snapshot())
        }

        func testActiveTurnFallbackScanCostDoesNotScaleWithHistoricalTranscriptLength() {
            let short = makeSession(priorTurnCount: 1)
            let long = makeSession(priorTurnCount: 2000)

            let shortScan = short.session.activeTurnToolItemIndices(where: { $0.toolName == "missing" })
            let longScan = long.session.activeTurnToolItemIndices(where: { $0.toolName == "missing" })

            XCTAssertEqual(shortScan.scannedItemCount, 1)
            XCTAssertEqual(longScan.scannedItemCount, 1)
            XCTAssertEqual(short.session.indexedToolItemIndices(invocationID: short.invocationID).count, 1)
            XCTAssertEqual(long.session.indexedToolItemIndices(invocationID: long.invocationID).count, 1)
        }

        private func makeSession(priorTurnCount: Int) -> (
            session: AgentModeViewModel.TabSession,
            invocationID: UUID
        ) {
            var items: [AgentChatItem] = []
            items.reserveCapacity(priorTurnCount * 2 + 2)
            var sequenceIndex = 0
            for turn in 0 ..< priorTurnCount {
                items.append(.user("historical user \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
                items.append(.assistant("historical assistant \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
            }
            items.append(.user("active user", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            let invocationID = UUID()
            items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"Sources/Active.swift"}"#,
                sequenceIndex: sequenceIndex
            ))
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.setItemsSilently(items, reason: .testOverride)
            return (session, invocationID)
        }
    }
#endif
