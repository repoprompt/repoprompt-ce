@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionUsageRuntimeTests: XCTestCase {
    func testRunHooksRetainAccountingWithoutPresentationAndSaveOnlyAppendedTurn() throws {
        var runtime: AgentSessionUsageRuntime? = AgentSessionUsageRuntime()
        weak let retained = runtime
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "sonnet"
        var savedObjects: [ObjectIdentifier] = []
        let hooks = try XCTUnwrap(runtime).makeRunHooks { savedObjects.append(ObjectIdentifier($0)) }
        runtime = nil
        XCTAssertNotNil(retained, "Run hooks own the service, not a presentation lifetime")
        hooks.startNonCodexTurnAccountingIfNeeded(session, "A user request")
        XCTAssertTrue(savedObjects.isEmpty)
        hooks.addUserInputTokensToActiveNonCodexTurn(7, session)
        hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
        XCTAssertEqual(savedObjects, [ObjectIdentifier(session)])
        XCTAssertEqual(session.providerTokenUsageByTurn.count, 1)
        XCTAssertNil(session.activeNonCodexTurnTokenAccumulator)
        hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
        XCTAssertEqual(savedObjects.count, 1, "No new report must not schedule another save")
    }

    func testOccupancyAndBilledUsageRemainDistinctWithoutViewModel() {
        let runtime = AgentSessionUsageRuntime()
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .devin
        _ = runtime.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "one")
        XCTAssertTrue(runtime.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 1000,
            modelContextWindow: 10000, session: session
        ))
        XCTAssertFalse(runtime.ingestNonCodexTurnFinalization(
            promptTokens: 3000, completionTokens: 20, contextUsedTokens: 3000,
            modelContextWindow: 10000, session: session
        ))
        XCTAssertEqual(session.contextUsageSnapshot?.used, 1000)
        XCTAssertEqual(session.contextUsageSnapshot?.source, .acpUsageEvent)
        _ = runtime.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "two")
        _ = runtime.ingestNonCodexTurnFinalization(
            promptTokens: 4000, completionTokens: 20, contextUsedTokens: 4000,
            modelContextWindow: 10000, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.source, .turnFinalization)
        XCTAssertTrue(session.providerTokenUsageByTurn.isEmpty, "ACP billing does not append Claude turn accounting")
    }
}

@MainActor
final class ClaudeWakeContextPressureTests: XCTestCase {
    func testUsesTheReportedWindowAndReservesWakePlusOutput() {
        func load(_ used: Int, _ capacity: Int, effectiveWindow: Int? = nil) -> ClaudeWakeContextPressure {
            .init(used: used, capacity: capacity, effectiveWindow: effectiveWindow ?? capacity)
        }
        XCTAssertFalse(load(450_000, 900_000).isHigh(thresholdPercent: 80))
        XCTAssertTrue(load(720_000, 900_000).isHigh(thresholdPercent: 80))
        XCTAssertTrue(load(450_000, 900_000, effectiveWindow: 550_000).isHigh(thresholdPercent: 80))
        XCTAssertTrue(load(121_000, 170_000).isHigh(thresholdPercent: 90), "Reserve can trigger below the setting")
        XCTAssertFalse(load(160_000, 170_000).isHigh(thresholdPercent: 0))
        XCTAssertFalse(load(170_001, 170_000).isHigh(thresholdPercent: 80))
        XCTAssertFalse(load(640_000, 900_000).hasRearmHeadroom)
        XCTAssertTrue(load(500_000, 900_000).hasRearmHeadroom)
    }

    func testBilledOrRestoredUseAndUnreportedWindowAreNotPolicyEvidence() {
        let session = makeSession()
        let usage = AgentSessionUsageRuntime()
        _ = usage.ingestNonCodexUsageReport(
            promptTokens: 800_000, completionTokens: 50, contextUsedTokens: nil,
            modelContextWindow: 900_000, session: session
        )
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        session.invalidateClaudeWakeUsage(includingWindow: true)
        _ = usage.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 800_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session), "Stored capacity is not a live window vouch")
        _ = usage.ingestNonCodexTurnFinalization(
            promptTokens: 1_200_000, completionTokens: 50, contextUsedTokens: nil,
            modelContextWindow: 900_000, session: session
        )
        XCTAssertEqual(ClaudeWakeContextPressure.current(for: session)?.used, 800_000)
    }

    func testControllerConversationAndModelChangeInvalidateLiveEvidenceButNotTheBudget() {
        let session = makeSession()
        let usage = AgentSessionUsageRuntime()
        func measure() {
            _ = usage.ingestNonCodexUsageReport(
                promptTokens: nil, completionTokens: nil, contextUsedTokens: 800_000,
                modelContextWindow: 900_000, session: session
            )
            XCTAssertNotNil(ClaudeWakeContextPressure.current(for: session))
        }
        session.claudeWakeCompactionSpentConversation = session.providerSessionID
        measure()
        session.claudeController = MonitorFakeNativeController()
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        XCTAssertEqual(session.claudeWakeCompactionSpentConversation, session.providerSessionID)
        measure()
        session.selectedModelRaw = "opus[1m]"
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        measure()
        session.providerSessionID = "fresh-conversation"
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        XCTAssertNotEqual(session.claudeWakeCompactionSpentConversation, session.providerSessionID)
    }

    func testOnlyMeasuredHeadroomRearmsAfterNativeCompaction() {
        let session = makeSession()
        let usage = AgentSessionUsageRuntime()
        let estimator = ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { _, _ in nil })
        estimator.ingestStatusSignal("Compacting context", session: session)
        XCTAssertNil(session.claudeCompactBoundaryID)
        estimator.ingestSystemSignal("Context compacted — trigger: auto", session: session)
        XCTAssertNotNil(session.claudeCompactBoundaryID)
        XCTAssertEqual(session.claudeWakeCompactionSpentConversation, session.providerSessionID)
        func finish(_ used: Int?) {
            _ = usage.ingestNonCodexTurnFinalization(
                promptTokens: 250_000, completionTokens: 500, contextUsedTokens: used,
                modelContextWindow: 900_000, session: session
            )
        }
        finish(nil)
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        XCTAssertEqual(session.claudeWakeCompactionSpentConversation, session.providerSessionID)
        finish(800_000)
        XCTAssertEqual(session.claudeWakeCompactionSpentConversation, session.providerSessionID)
        session.invalidateClaudeWakeUsage()
        XCTAssertNil(ClaudeWakeContextPressure.current(for: session))
        finish(150_000)
        XCTAssertNil(session.claudeWakeCompactionSpentConversation)
    }

    private func makeSession() -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "sonnet"
        session.providerSessionID = "monitor-native-session"
        session.claudeController = MonitorFakeNativeController()
        return session
    }
}
