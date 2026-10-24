import Foundation
@testable import RepoPromptInstrumentation
import XCTest

final class WorktreeStartupPhaseEventContractTests: XCTestCase {
    func testServingRequiresObservation() {
        let flags = WorktreeStartupFeatureFlags(
            observeDiffSeededWorktreeStartup: false,
            serveDiffSeededWorktreeStartup: true
        )
        XCTAssertFalse(flags.observeDiffSeededWorktreeStartup)
        XCTAssertFalse(flags.serveDiffSeededWorktreeStartup)
    }

    func testNoopSinkAcceptsBoundedPhaseEvent() {
        let sessionID = UUID()
        let correlationID = UUID()
        let context = WorktreeStartupContext(
            rawAgentSessionID: sessionID,
            correlationID: correlationID,
            flags: WorktreeStartupFeatureFlags(
                observeDiffSeededWorktreeStartup: true,
                serveDiffSeededWorktreeStartup: true
            ),
            servingControl: .automatic
        )
        let event = WorktreeStartupPhaseEvent(
            phase: .seedFallback,
            context: context,
            route: .fullCrawl,
            fallback: .witnessGap
        )
        let sink: any WorktreeStartupPhaseEventSink = NoopWorktreeStartupPhaseEventSink()
        sink.record(event)

        XCTAssertEqual(event.phase, .seedFallback)
        XCTAssertEqual(event.context.agentSessionID, sessionID)
        XCTAssertEqual(event.context.correlationID, correlationID)
        XCTAssertEqual(event.route, .fullCrawl)
        XCTAssertEqual(event.fallback, .witnessGap)
    }
}
