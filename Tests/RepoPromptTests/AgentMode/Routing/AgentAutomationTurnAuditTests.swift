import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentAutomationTurnAuditTests: XCTestCase {
    func testSessionRoundTripJoinsAuditToExistingUsageTurnID() throws {
        let turnID = UUID()
        let audit = AgentAutomationTurnAudit(
            turnID: turnID,
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true,
                eligible: true,
                judgmentRequested: true,
                decision: .selected,
                chosenModelRaw: "gpt-6-sol",
                chosenEffortRaw: "medium",
                application: .turnAccepted
            ),
            autoEffort: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
            acceptedProviderRaw: "codexExec",
            acceptedModelRaw: "gpt-6-sol",
            acceptedEffortRaw: "low",
            providerTurnAccepted: true
        )
        let usage = AgentTokenUsagePersist(turnID: turnID, promptTokens: 12, completionTokens: 3)
        let session = AgentSession(
            providerTokenUsageByTurn: [usage],
            automationTurnAudit: [audit]
        )
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.automationTurnAudit, [audit])
        XCTAssertEqual(decoded.automationTurnAudit.first?.router.chosenEffortRaw, "medium")
        XCTAssertEqual(decoded.automationTurnAudit.first?.acceptedEffortRaw, "low")
        XCTAssertEqual(decoded.providerTokenUsageByTurn.first?.turnID, turnID)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("promptExcerpt"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("providerEffective"))
    }

    func testVersionOneAuditWithoutCodexDeliveryStillDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSelectedAudit())) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "codexDelivery")
        let decoded = try JSONDecoder().decode(
            AgentAutomationTurnAudit.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.codexDelivery)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testLegacySessionWithoutAuditDecodesAsEmpty() throws {
        let encoded = try JSONEncoder().encode(AgentSession())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automationTurnAudit")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertTrue(decoded.automationTurnAudit.isEmpty)
    }

    func testCodexSteerAndQueuedFallbackSeparateLocalAndProviderAcceptance() {
        var audit = makeSelectedAudit()
        audit.recordCodexQueuedFallback()
        XCTAssertEqual(audit.codexDelivery, .queuedFallback)
        XCTAssertFalse(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)

        audit.recordCodexDispatch(.fallbackStart)
        XCTAssertTrue(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)
        audit.recordCodexStartAccepted(effortRaw: "high", autoEffortApplied: false)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "high")
        XCTAssertEqual(audit.autoEffort.application, .fallbackToManual)

        var steer = makeSelectedAudit()
        steer.recordCodexDispatch(.steer)
        steer.recordCodexSteerAccepted()
        XCTAssertEqual(steer.codexDelivery, .steer)
        XCTAssertTrue(steer.providerTurnAccepted)
        XCTAssertEqual(steer.router.application, .notObserved)
        XCTAssertEqual(steer.autoEffort.application, .notObserved)
    }

    func testManagedAuthReplayUpdatesPhysicalDispatchWithoutInventingEffectiveEffort() {
        var audit = makeSelectedAudit()
        audit.recordCodexDispatch(.start)
        audit.recordCodexDispatch(.managedAuthReplay)
        audit.recordCodexStartAccepted(effortRaw: "medium", autoEffortApplied: true)
        XCTAssertEqual(audit.codexDelivery, .managedAuthReplay)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "medium")
        XCTAssertEqual(audit.autoEffort.application, .turnAccepted)
    }

    func testClaudeAcceptedEffortFollowsAppliedControlOrManualFallback() {
        var applied = makeSelectedAudit()
        applied.autoEffort.application = .controlAccepted
        applied.recordClaudeTurnAccepted(autoEffortRaw: "high", manualEffortRaw: "low")
        XCTAssertEqual(applied.acceptedEffortRaw, "high")
        XCTAssertEqual(applied.autoEffort.application, .turnAccepted)

        var fallback = makeSelectedAudit()
        fallback.autoEffort.application = .controlAccepted
        fallback.recordClaudeTurnAccepted(autoEffortRaw: nil, manualEffortRaw: "low")
        XCTAssertEqual(fallback.acceptedEffortRaw, "low")
        XCTAssertEqual(fallback.autoEffort.application, .fallbackToManual)
        XCTAssertTrue(fallback.autoEffort.fallbackApplied)
    }

    func testDiscardedMCPJudgmentRetainsCallAndChoice() {
        let original = makeSelectedAudit().autoEffort
        let discarded = original.discardedAfterMCPReclassification()
        XCTAssertTrue(discarded.judgmentRequested)
        XCTAssertEqual(discarded.chosenEffortRaw, "high")
        XCTAssertTrue(discarded.fallbackApplied)
        XCTAssertEqual(discarded.application, .fallbackToManual)
    }

    @MainActor
    func testRemovingRejectedOptimisticUserTurnRemovesOnlyItsAudit() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let rejected = AgentChatItem.user("rejected", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(rejected)
        var audit = makeSelectedAudit()
        audit = AgentAutomationTurnAudit(
            turnID: rejected.id,
            createdAt: rejected.timestamp,
            router: audit.router,
            autoEffort: audit.autoEffort
        )
        session.appendAutomationAudit(audit)
        XCTAssertNotNil(session.removeItem(at: 0))
        XCTAssertTrue(session.automationTurnAudit.isEmpty)
    }

    private func makeSelectedAudit() -> AgentAutomationTurnAudit {
        AgentAutomationTurnAudit(
            turnID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "medium"
            ),
            autoEffort: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "high"
            ),
            acceptedEffortRaw: "low"
        )
    }

    func testAuditRetentionIsBoundedWithoutFabricatingUsage() {
        let records = (0 ..< 140).map { index in
            AgentAutomationTurnAudit(
                turnID: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                router: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
                autoEffort: .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible)
            )
        }
        let retained = AgentAutomationTurnAudit.retain(records)
        XCTAssertEqual(retained.count, AgentAutomationTurnAudit.retainedTurnLimit)
        XCTAssertEqual(retained.first?.turnID, records[12].turnID)
        XCTAssertFalse(retained.last?.providerTurnAccepted ?? true)
    }
}
