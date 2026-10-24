#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class AgentTranscriptDebugInstrumentationTests: XCTestCase {
        override func tearDown() {
            AgentTranscriptDebugInstrumentation.reset()
            super.tearDown()
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
