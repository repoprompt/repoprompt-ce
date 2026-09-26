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

    func testLegacySessionWithoutAuditDecodesAsEmpty() throws {
        let encoded = try JSONEncoder().encode(AgentSession())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automationTurnAudit")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertTrue(decoded.automationTurnAudit.isEmpty)
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
