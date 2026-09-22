import Foundation
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class ContextBuilderRunStateContractTests: XCTestCase {
    func testFinalCommitAndTerminalClaimsAreExactlyOnce() {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let record = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "claim-contract")
        )

        XCTAssertTrue(record.claimFinalContextCommit())
        XCTAssertTrue(record.finalContextCommitClaimed)
        XCTAssertFalse(record.claimFinalContextCommit())
        XCTAssertTrue(record.claimTerminal(.completed))
        XCTAssertFalse(record.claimTerminal(.cancelled))
    }

    func testRouteSettlementCoordinatorRejectsEventsAfterSettlement() {
        let coordinator = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 100,
            maxBufferedEventCount: 10
        )
        coordinator.appendWhilePending(
            AIStreamResult(type: "content", text: "before")
        )

        XCTAssertTrue(coordinator.settle(.routed))
        XCTAssertFalse(coordinator.isPending)
        XCTAssertTrue(coordinator.isRouted)

        coordinator.appendWhilePending(
            AIStreamResult(type: "content", text: "after")
        )
        XCTAssertEqual(
            coordinator.drainBufferedEvents().events.map(\.text),
            ["before"]
        )
    }

    private func makeRecord(
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership
    ) -> ContextBuilderRunRecord {
        ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: ownership,
            origin: .ui,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue
        )
    }
}
