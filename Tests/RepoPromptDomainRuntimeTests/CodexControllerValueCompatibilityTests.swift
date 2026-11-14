import Foundation
import RepoPromptDomainRuntime
import XCTest

extension CodexServerRequestReceipt {
    static func fixture(_ requestID: CodexAppServerRequestID, generation: UInt64 = 1, clientID: UUID? = nil) -> Self {
        .init(
            clientInstanceID: clientID ?? UUID(uuidString: "F05339D5-F0BA-4C36-943C-028A4FBE89BA")!,
            transportGeneration: generation,
            requestID: requestID
        )
    }
}

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
            receipt: .fixture(.int(42)), method: "item/tool/requestUserInput", threadID: "thread", turnID: "turn", itemID: "item",
            askedAt: askedAt, questions: [question]
        )
        let elicitation = AgentMCPElicitationRequest(
            receipt: .fixture(.int(42)), method: "mcpServer/elicitation/request", threadID: "thread", turnID: "turn", itemID: "item",
            rawParamsJSON: #"{"message":"Choose"}"#
        )
        let permissions = AgentPermissionsRequest(
            receipt: .fixture(.int(42)), method: "item/permissions/requestApproval", threadID: "thread", turnID: "turn", itemID: "item",
            cwd: "/workspace", permissionsJSON: #"{"network":true}"#
        )
        XCTAssertEqual(input.id.uuidString, "7240C9EE-1EF9-4C1C-76F7-FFF7176BC033")
        XCTAssertEqual(elicitation.id.uuidString, "E4ECB518-A550-31FA-3E93-95E1D200AFE1")
        XCTAssertEqual(permissions.id.uuidString, "4DF0079C-44ED-1BB8-622E-13C32F8188A2")
        let original = CodexServerRequestReceipt.fixture(.int(42))
        func identities(_ receipt: CodexServerRequestReceipt) -> [UUID] {
            [
                AgentRequestUserInputRequest.stableID(receipt: receipt, method: input.method, threadID: "thread", turnID: "turn", itemID: "item"),
                AgentMCPElicitationRequest.stableID(receipt: receipt, method: elicitation.method, threadID: "thread", turnID: "turn", itemID: "item"),
                AgentPermissionsRequest.stableID(receipt: receipt, method: permissions.method, threadID: "thread", turnID: "turn", itemID: "item"),
                AgentApprovalRequest.stableID(requestID: .codex(receipt), method: "approve", kind: .commandExecution, threadID: "thread", turnID: "turn", itemID: "item")
            ]
        }
        XCTAssertEqual(identities(original), identities(.fixture(.int(42))), "Duplicate ingress retains identity")
        for changed in [CodexServerRequestReceipt.fixture(.int(42), generation: 2), .fixture(.int(42), clientID: UUID()), .fixture(.string("42"))] {
            for (before, after) in zip(identities(original), identities(changed)) {
                XCTAssertNotEqual(before, after, "Raw request reuse cannot preserve UI identity across origins or ID kinds")
            }
        }
        XCTAssertEqual(input.askedAt, askedAt)
        XCTAssertEqual(input.questions, [question])
        XCTAssertFalse(input.repoPromptAutoApprovalVerified)
        XCTAssertFalse(input.computerUseCompanionVerified)
        XCTAssertEqual(elicitation.rawParamsJSON, #"{"message":"Choose"}"#)
        XCTAssertEqual(permissions.permissionsJSON, #"{"network":true}"#)

        let explicitID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(AgentRequestUserInputRequest(
            id: explicitID, receipt: .fixture(.string("42")), method: input.method,
            threadID: "thread", turnID: "turn", itemID: "item", questions: [],
            repoPromptAutoApprovalVerified: true, computerUseCompanionVerified: true
        ).id, explicitID)
        XCTAssertEqual(AgentMCPElicitationRequest(
            id: explicitID, receipt: .fixture(.string("42")), method: elicitation.method,
            threadID: "thread", turnID: "turn", itemID: "item", rawParamsJSON: "{}"
        ).id, explicitID)
        XCTAssertEqual(AgentPermissionsRequest(
            id: explicitID, receipt: .fixture(.string("42")), method: permissions.method,
            threadID: "thread", turnID: "turn", itemID: "item", cwd: "/workspace", permissionsJSON: "{}"
        ).id, explicitID)
    }
}
