import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentApprovalContractTests: XCTestCase {
    func testRequestIDPreservesRawWireKindsAndStableIdentity() throws {
        let numeric = try XCTUnwrap(CodexAppServerRequestID(raw: 42))
        let textual = try XCTUnwrap(CodexAppServerRequestID(raw: "42"))
        XCTAssertNotEqual(numeric, textual)
        XCTAssertEqual(numeric.jsonValue as? Int, 42)
        XCTAssertEqual(textual.jsonValue as? String, "42")
        let id = AgentApprovalRequest.stableID(requestID: .codex(numeric), method: "approve", kind: .commandExecution, threadID: "thread", turnID: "turn", itemID: "item")
        XCTAssertEqual(id.uuidString.lowercased(), "d04d7e83-9e01-82ee-b8e7-7133d9499ff9")
        XCTAssertEqual(id, AgentApprovalRequest.stableID(requestID: .codex(textual), method: "approve", kind: .commandExecution, threadID: "thread", turnID: "turn", itemID: "item"))
        XCTAssertEqual(AgentApprovalDetail.stableID(requestSeed: "seed", index: 0, label: "Command", value: "ls", isCode: true).uuidString.lowercased(), "4d77a1e9-364f-c94e-f473-1d673d1a949d")
    }

    func testACPPlainAndSessionApprovalRemainFailClosed() {
        let request = AgentApprovalRequest(requestID: .acp("id"), method: "permission", kind: .commandExecution, threadID: "t", turnID: "u", itemID: "i", plainApproveAvailable: false, sessionApprovalScope: .oneTime)
        XCTAssertFalse(request.allows(.accept))
        XCTAssertFalse(request.allows(.acceptForSession))
        XCTAssertTrue(request.allows(.decline))
        XCTAssertNil(request.rememberedDecision)
    }

    func testCodexAdvertisedAmendmentMustMatchExactly() {
        let request = AgentApprovalRequest(requestID: .codex(.int(1)), method: "approve", kind: .commandExecution, threadID: "t", turnID: "u", itemID: "i", availableDecisions: [.acceptWithExecpolicyAmendment("[\"swift\",\"test\"]")])
        XCTAssertTrue(request.allows(.acceptWithExecpolicyAmendment("[\"swift\", \"test\"]")))
        XCTAssertFalse(request.allows(.acceptWithExecpolicyAmendment("[\"swift\",\"build\"]")))
        XCTAssertFalse(request.allows(.accept))
    }

    func testJSONAndRunStateValuesRetainTheirMeaning() {
        let value = AgentJSONValue.object(["items": .array([.int(3), .string("x"), .null])])
        let object = value.toAny() as? [String: Any]
        let items = object?["items"] as? [Any]
        XCTAssertEqual(items?[0] as? Int, 3)
        XCTAssertEqual(items?[1] as? String, "x")
        XCTAssertTrue(items?[2] is NSNull)
        XCTAssertTrue(AgentSessionRunState.waitingForApproval.isActive)
        XCTAssertFalse(AgentSessionRunState.failed.isActive)
    }
}
