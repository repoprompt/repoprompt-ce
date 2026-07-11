import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ClaudeContextUsageEstimatorTests: XCTestCase {
    func testUnknownWindowAcceptsFinalizesAndPersistsThreeHundredFiftyK() throws {
        let estimator = makeEstimator()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.claudeConfiguredContextWindow = 400_000

        _ = estimator.ingestUsageSignal(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: 350_000,
            modelContextWindow: nil,
            session: session
        )

        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 350_000)
        XCTAssertEqual(session.codexContextUsage?.configuredContextWindow, 400_000)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 350_000)
        XCTAssertEqual(session.activeNonCodexTurnTokenAccumulator?.observedContextUsedTokens, 350_000)

        XCTAssertTrue(estimator.finalizeTurn(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: 350_000,
            session: session
        ))
        XCTAssertEqual(try XCTUnwrap(session.providerTokenUsageByTurn.last).contextUsedTokens, 350_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 350_000)
        XCTAssertEqual(session.codexContextUsage?.configuredContextWindow, 400_000)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 350_000)
    }

    func testKnownTwoHundredKRejectsThreeHundredFiftyKAndPreservesPriorState() {
        let estimator = makeEstimator()
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        _ = estimator.ingestUsageSignal(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: 150_000,
            modelContextWindow: 200_000,
            session: session
        )
        _ = estimator.ingestUsageSignal(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: 350_000,
            modelContextWindow: nil,
            session: session
        )

        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 150_000)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 150_000)
        XCTAssertEqual(session.activeNonCodexTurnTokenAccumulator?.observedContextUsedTokens, 150_000)
    }

    func testTerminalOneMillionWindowPreservesEarlierUnknownWindowReadingThroughFinalization() throws {
        let estimator = makeEstimator()
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        _ = estimator.ingestUsageSignal(
            promptTokens: nil,
            completionTokens: nil,
            contextUsedTokens: 350_000,
            modelContextWindow: nil,
            session: session
        )
        _ = estimator.ingestTurnFinalizationSignal(
            contextUsedTokens: nil,
            modelContextWindow: 1_000_000,
            session: session
        )

        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 1_000_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 350_000)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 350_000)

        XCTAssertTrue(estimator.finalizeTurn(
            promptTokens: 1,
            completionTokens: nil,
            contextUsedTokens: nil,
            session: session
        ))
        XCTAssertEqual(try XCTUnwrap(session.providerTokenUsageByTurn.last).contextUsedTokens, 350_000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 1_000_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 350_000)
    }

    private func makeEstimator() -> ClaudeContextUsageEstimator {
        ClaudeContextUsageEstimator(
            tokenEstimator: { $0.count / 4 },
            contextUsageBuilder: { turns, modelContextWindow, configuredContextWindow in
                AgentModeViewModel.contextUsageFromClaudeProviderTokens(
                    turns,
                    modelContextWindow: modelContextWindow,
                    configuredContextWindow: configuredContextWindow
                )
            }
        )
    }
}
