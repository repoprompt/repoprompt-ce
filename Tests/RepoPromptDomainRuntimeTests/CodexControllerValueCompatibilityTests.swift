import Foundation
import RepoPromptDomainRuntime
import XCTest

final class CodexControllerValueCompatibilityTests: XCTestCase {
    func testLegacyUsageDecodesWithoutPendingCompactionKey() throws {
        let usage = try JSONDecoder().decode(
            AgentContextUsage.self,
            from: Data(#"{"modelContextWindow":128000,"lastTotalTokens":1200,"totalTotalTokens":2400}"#.utf8)
        )
        XCTAssertEqual(usage.modelContextWindow, 128_000)
        XCTAssertEqual(usage.lastTotalTokens, 1200)
        XCTAssertEqual(usage.totalTotalTokens, 2400)
        XCTAssertNil(usage.awaitingPostCompactionUsage)
        XCTAssertEqual(try JSONDecoder().decode(AgentContextUsage.self, from: Data("{}".utf8)), AgentContextUsage())
    }

    func testUsageEncodingRetainsExistingPersistenceKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AgentContextUsage(
            modelContextWindow: 128_000,
            lastTotalTokens: 1200,
            totalTotalTokens: 2400,
            awaitingPostCompactionUsage: true
        ))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"awaitingPostCompactionUsage":true,"lastTotalTokens":1200,"modelContextWindow":128000,"totalTotalTokens":2400}"#
        )
    }

    func testRequestIdentityGoldensAndExplicitIdentityOverride() throws {
        let askedAt = Date(timeIntervalSince1970: 123)
        let question = AgentRequestUserInputQuestion(
            id: "question", header: "Header", question: "Choose", isOther: true, isSecret: false,
            options: [AgentRequestUserInputOption(label: "Allow", description: "Once")]
        )
        let input = AgentRequestUserInputRequest(
            requestID: .int(42), method: "item/tool/requestUserInput", threadID: "thread", turnID: "turn", itemID: "item",
            askedAt: askedAt, questions: [question]
        )
        let elicitation = AgentMCPElicitationRequest(
            requestID: .int(42), method: "mcpServer/elicitation/request", threadID: "thread", turnID: "turn", itemID: "item",
            rawParamsJSON: #"{"message":"Choose"}"#
        )
        let permissions = AgentPermissionsRequest(
            requestID: .int(42), method: "item/permissions/requestApproval", threadID: "thread", turnID: "turn", itemID: "item",
            cwd: "/workspace", permissionsJSON: #"{"network":true}"#
        )
        XCTAssertEqual(input.id.uuidString, "C18761C1-C079-F23C-0041-0F7A2834DB52")
        XCTAssertEqual(elicitation.id.uuidString, "39BB7521-9C1B-5AB2-87C5-FCBDA6FD9D6A")
        XCTAssertEqual(permissions.id.uuidString, "EAFECB52-BC76-8DC7-6631-BA4D6501EC86")
        XCTAssertEqual(input.askedAt, askedAt)
        XCTAssertEqual(input.questions, [question])
        XCTAssertFalse(input.repoPromptAutoApprovalVerified)
        XCTAssertFalse(input.computerUseCompanionVerified)
        XCTAssertEqual(elicitation.rawParamsJSON, #"{"message":"Choose"}"#)
        XCTAssertEqual(permissions.permissionsJSON, #"{"network":true}"#)

        let explicitID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(AgentRequestUserInputRequest(
            id: explicitID, requestID: .string("42"), method: input.method,
            threadID: "thread", turnID: "turn", itemID: "item", questions: [],
            repoPromptAutoApprovalVerified: true, computerUseCompanionVerified: true
        ).id, explicitID)
        XCTAssertEqual(AgentMCPElicitationRequest(
            id: explicitID, requestID: .string("42"), method: elicitation.method,
            threadID: "thread", turnID: "turn", itemID: "item", rawParamsJSON: "{}"
        ).id, explicitID)
        XCTAssertEqual(AgentPermissionsRequest(
            id: explicitID, requestID: .string("42"), method: permissions.method,
            threadID: "thread", turnID: "turn", itemID: "item", cwd: "/workspace", permissionsJSON: "{}"
        ).id, explicitID)
    }
}
