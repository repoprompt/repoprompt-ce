import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLaneMCPToolServiceTests: XCTestCase {
    func testCreationReceiptIsFlatAndAllocationRefusalHasNoSessionID() {
        let sessionID = UUID()
        let receipt = AgentSessionLaneCreateReceipt(
            result: .created,
            sessionID: sessionID,
            sessionName: "Review",
            linked: true,
            reason: nil,
            firstTask: .queued,
            laneCount: 3,
            duplicate: true,
            workspaceName: "Café \"QA\""
        )
        let payload = AgentSessionLaneMCPToolService.render(receipt).objectValue
        XCTAssertEqual(payload?["result"]?.stringValue, "created")
        XCTAssertEqual(payload?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(payload?["first_task"]?.stringValue, "queued")
        XCTAssertEqual(payload?["lanes"]?.stringValue, "3/8")
        XCTAssertEqual(payload?["duplicate"], .bool(true))
        XCTAssertNil(payload?["link_reason"])
        XCTAssertEqual(payload?["workspace"]?.stringValue, "Café \"QA\"")

        let refused = AgentSessionLaneMCPToolService.render(
            AgentSessionLaneCreateReceipt.refused(.laneLimitReached, laneCount: 8)
        ).objectValue
        XCTAssertEqual(refused?["result"]?.stringValue, "lane_limit_reached")
        XCTAssertEqual(refused?["lanes"]?.stringValue, "8/8")
        XCTAssertNil(refused?["session_id"])
        for reason in [AgentSessionLaneCreateReceipt.Reason.denied, .modelUnavailable, .laneLimitReached] {
            var receipt = AgentSessionLaneCreateReceipt.refused(reason, laneCount: 8)
            receipt.workspaceName = "Must not leak"
            XCTAssertNil(AgentSessionLaneMCPToolService.render(receipt).objectValue?["workspace"])
        }
    }

    func testRetirementReceiptsRemainNonDestructiveAndExplainPartialOutcome() {
        let sessionID = UUID()
        let partial = AgentSessionLaneMCPToolService.render(
            .unlinkedNotStashed(sessionID: sessionID)
        ).objectValue
        XCTAssertEqual(partial?["result"]?.stringValue, "unlinked_not_stashed")
        XCTAssertEqual(partial?["session_id"]?.stringValue, sessionID.uuidString)
        let denied = AgentSessionLaneMCPToolService.render(
            .notRetired(sessionID: sessionID, reason: .laneInUse)
        ).objectValue
        XCTAssertEqual(denied?["reason"]?.stringValue, "lane_in_use")
    }

    func testPromptInventoryCarriesCreatedByYouWithoutChangingGrantCapabilities() {
        let observerID = UUID()
        let targetID = UUID()
        let inventory = DomainAgentSessionLinkInventory(
            sessionID: observerID,
            linkSetRevision: 1,
            authorityRevision: 1,
            items: [DomainAgentSessionLinkInventoryItem(
                linkID: UUID(),
                generation: 1,
                observerSessionID: observerID,
                targetSessionID: targetID,
                displayName: "Lane",
                capabilities: DomainAgentSessionLinkCapability.version1
            )]
        )
        let annotated = AgentSessionLinkPromptInventory(inventory) { $0 == targetID }
        XCTAssertEqual(annotated.items.first?.createdByYou, true)
        XCTAssertEqual(annotated.items.first?.capabilityNames, inventory.items.first?.capabilityNames)
        XCTAssertEqual(AgentSessionLinkPromptInventory(inventory).items.first?.createdByYou, false)
    }
}
