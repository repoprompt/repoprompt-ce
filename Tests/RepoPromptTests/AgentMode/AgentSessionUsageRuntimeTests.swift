@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionUsageRuntimeTests: XCTestCase {
    func testRunHooksRetainAccountingWithoutPresentationAndSaveOnlyAppendedTurn() throws {
        var runtime: AgentSessionUsageRuntime? = AgentSessionUsageRuntime()
        weak var retained = runtime
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
