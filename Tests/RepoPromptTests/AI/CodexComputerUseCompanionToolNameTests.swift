import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CodexComputerUseCompanionToolNameTests: XCTestCase {
    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(nil)
        )
    }

    private func emittedToolCallName(
        serverFields: [String: CodexJSONValue],
        tool: String
    ) async -> String? {
        let controller = makeController()
        await controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )
        var invocation: [String: CodexJSONValue] = serverFields
        invocation["tool"] = .string(tool)
        invocation["arguments"] = .object(["x": .number(10)])
        await controller.test_handleNotification(
            method: "codex/event/mcp_tool_call_begin",
            params: [
                "turn_id": .string("turn-1"),
                "msg": .object([
                    "call_id": .string("call-1"),
                    "invocation": .object(invocation)
                ])
            ]
        )
        // Bounded wait: a regression in event emission must fail, not hang the suite.
        let stream = controller.events
        let event = await withTaskGroup(of: CodexNativeSessionController.Event?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await controller.shutdown()
        guard case let .toolCall(name, _, _) = event else { return nil }
        return name
    }

    func testCompanionServerToolCallEmitsQualifiedName() async {
        // Real Codex parse path: mcp_tool_call_begin with the reserved companion
        // server must keep its provenance so transcript clustering can recognize it.
        let name = await emittedToolCallName(serverFields: ["server": .string("computer-use")], tool: "click")
        XCTAssertEqual(name, "mcp__computer-use__click")
    }

    func testForeignServerToolCallKeepsBareName() async {
        let name = await emittedToolCallName(serverFields: ["server": .string("other-server")], tool: "click")
        XCTAssertEqual(name, "click")
    }

    func testCompanionActionResemblingShellKeepsProvenance() async {
        // Server attestation outranks the generic "shell" -> "bash" alias.
        let name = await emittedToolCallName(serverFields: ["server": .string("computer-use")], tool: "shell")
        XCTAssertEqual(name, "mcp__computer-use__shell")
    }

    func testForeignServerWithCompanionLookingNameFailsClosed() async {
        // A foreign-attested payload carrying a spoofed companion prefix never groups.
        let name = await emittedToolCallName(
            serverFields: ["server": .string("other-server")],
            tool: "mcp__computer-use__click"
        )
        XCTAssertEqual(name, "click")
    }

    func testMissingAttestationWithCompanionLookingNameFailsClosed() async {
        // No server fields at all: the claimed prefix is stripped rather than trusted.
        let name = await emittedToolCallName(serverFields: [:], tool: "mcp__computer-use__click")
        XCTAssertEqual(name, "click")
    }

    func testConflictingServerAliasesFailClosed() async {
        let name = await emittedToolCallName(
            serverFields: ["server": .string("computer-use"), "mcp_server": .string("other-server")],
            tool: "click"
        )
        XCTAssertEqual(name, "click")
    }

    func testCompanionToolNameIdentityForms() {
        XCTAssertTrue(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer-use__click"))
        // normalizedToolNameForComparison rewrites `-` to `_`; tolerate that form.
        XCTAssertTrue(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer_use__click"))
        XCTAssertEqual(
            MCPIntegrationHelper.computerUseCompanionToolName("mcp__computer-use__press_key"),
            "press_key"
        )
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__other__click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer-use__"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("functions.mcp__computer-use__click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName(nil))
    }
}
