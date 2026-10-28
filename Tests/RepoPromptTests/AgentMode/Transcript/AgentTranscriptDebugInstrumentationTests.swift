#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class AgentTranscriptDebugInstrumentationTests: XCTestCase {
        override func tearDown() {
            AgentTranscriptDebugInstrumentation.reset()
            super.tearDown()
        }

        func testRequestedProjectionIdentityMetricsPreserveDigestsAndDrift() throws {
            let rows = [AgentChatItem.user("request", sequenceIndex: 0), .assistant("answer", sequenceIndex: 1)]
            let transcript = AgentTranscriptIO.buildTranscript(from: rows, terminalState: .completed)
            let first = AgentModeViewModel.buildTranscriptPresentation(
                from: transcript, sourceItems: rows, selectedAgent: .claudeCode, previousPerformanceSnapshot: .empty
            )
            var previous = first.baseProjection
            previous.workingRows[0] = previous.workingRows[0].replacingID(UUID())
            let block = try XCTUnwrap(previous.workingBlocks.first)
            previous.workingBlocks[0] = .init(
                id: "prior-block-identity", kind: block.kind, turnID: block.turnID, spanID: block.spanID,
                retentionTier: block.retentionTier, rows: block.rows, isArchived: block.isArchived,
                primaryAnchor: block.primaryAnchor, anchorActivityID: block.anchorActivityID,
                activityIDs: block.activityIDs, clusterSummary: block.clusterSummary, groupedHistory: block.groupedHistory,
                collapsedHistoryRange: block.collapsedHistoryRange, defaultPresentation: block.defaultPresentation
            )
            var received: [AgentTranscriptProjectionIdentityMetrics] = []
            AgentTranscriptDebugInstrumentation.configure(.init(projectionIdentityHandler: { received.append($0) }))
            let next = AgentModeViewModel.buildTranscriptPresentation(
                from: transcript, sourceItems: rows, selectedAgent: .claudeCode, previousPerformanceSnapshot: .empty,
                previousBaseProjection: previous
            )
            let previousRows = previous.archivedRows + previous.workingRows
            let newRows = next.baseProjection.archivedRows + next.baseProjection.workingRows
            let previousBlocks = previous.archivedBlocks + previous.workingBlocks
            let newBlocks = next.baseProjection.archivedBlocks + next.baseProjection.workingBlocks
            XCTAssertEqual(received, [.init(
                previousRowCount: previousRows.count, newRowCount: newRows.count,
                previousBlockCount: previousBlocks.count, newBlockCount: newBlocks.count,
                rowSemanticDigest: AgentTranscriptDebugInstrumentation.itemSemanticSignature(newRows),
                previousRowSemanticDigest: AgentTranscriptDebugInstrumentation.itemSemanticSignature(previousRows),
                rowIdentityDigest: AgentTranscriptDebugInstrumentation.itemIdentitySignature(newRows),
                previousRowIdentityDigest: AgentTranscriptDebugInstrumentation.itemIdentitySignature(previousRows),
                blockSemanticDigest: AgentTranscriptDebugInstrumentation.blockSemanticSignature(newBlocks),
                previousBlockSemanticDigest: AgentTranscriptDebugInstrumentation.blockSemanticSignature(previousBlocks),
                blockIdentityDigest: AgentTranscriptDebugInstrumentation.blockIdentitySignature(newBlocks),
                previousBlockIdentityDigest: AgentTranscriptDebugInstrumentation.blockIdentitySignature(previousBlocks),
                rowIdentityDrift: true, blockIdentityDrift: true
            )])
            XCTAssertEqual(next.baseProjection, first.baseProjection)
        }

        func testMetricsRemainLazyUntilAHandlerIsConfigured() {
            var evaluationCount = 0

            func metrics() -> AgentTranscriptWorkingSourceItemsMetrics {
                evaluationCount += 1
                return .init(transcriptTurnCount: 1, fullTurnCount: 1, itemCount: 1, durationMS: 0)
            }

            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            AgentTranscriptDebugInstrumentation.configure(.init())
            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            XCTAssertEqual(evaluationCount, 0)

            AgentTranscriptDebugInstrumentation.configure(.init(workingSourceItemsHandler: { _ in }))
            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            XCTAssertEqual(evaluationCount, 1)
        }
    }
#endif
