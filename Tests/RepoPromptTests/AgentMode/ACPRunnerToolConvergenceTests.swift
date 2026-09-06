import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class ACPRunnerToolConvergenceTests: XCTestCase {
    private let provider = DevinACPAgentProvider(config: .init(includeRepoPromptMCPServer: false))
    private let toolName = "mcp__RepoPromptCE__get_file_tree"
    private let rich = #"{"status":"success","content":"fixture tree"}"#

    func testBothCompletionOrdersPreserveOneTrackerOwnedExecution() throws {
        for trackerFirst in [true, false] {
            for input in [nil, [:], ["type": "different"]] as [[String: String]?] {
                let vm = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in fatalError("Unused") })
                let runner = vm.testACPRunner
                let session = AgentTabSession(tabID: UUID())
                session.appendItem(.user("fixture", sequenceIndex: 0))
                session.runState = .running
                let tracker = UUID()
                try emit("tool_call", id: "one", input: ["type": "roots"], runner: runner, session: session)
                runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
                let itemID = try XCTUnwrap(session.items.last?.id)
                if !trackerFirst { try emit("tool_call_update", id: "one", status: "completed", input: input, runner: runner, session: session) }
                runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: rich, isError: false, session: session)
                try emit("tool_call_update", id: "one", status: "in_progress", runner: runner, session: session)
                try emit("tool_call_update", id: "one", status: "completed", input: input, runner: runner, session: session)
                let tools = session.items.filter { $0.kind == .toolResult || $0.kind == .toolCall }
                XCTAssertEqual(tools.count, 1)
                XCTAssertEqual(tools.first?.id, itemID)
                XCTAssertEqual(tools.first?.toolResultJSON, rich)
                XCTAssertEqual(tools.first?.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "one"))
                let transcript = AgentTranscriptIO.importLegacyItems(session.items, terminalState: .completed)
                let roundTrip = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(transcript))
                let executions = roundTrip.turns.flatMap(\.responseSpans).flatMap(\.activities).compactMap(\.toolExecution)
                XCTAssertEqual(executions.count, 1)
                XCTAssertEqual(executions.first?.status, .success)
                XCTAssertEqual(executions.first?.stableExecutionID, tools.first?.toolInvocationID?.uuidString.lowercased())
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }
    }

    func testParallelSameSourceCallsRemainDistinct() throws {
        let vm = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in fatalError("Unused") })
        let session = AgentTabSession(tabID: UUID())
        session.appendItem(.user("fixture", sequenceIndex: 0))
        session.runState = .running
        for id in ["one", "two"] {
            try emit("tool_call", id: id, input: ["type": "roots"], runner: vm.testACPRunner, session: session)
        }
        XCTAssertEqual(session.items.count(where: { $0.kind == .toolCall }), 2)
    }

    func testTrackerErrorsAndContradictoryProviderFailuresRemainTruthful() throws {
        for trackerError in [true, false] {
            let vm = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in fatalError("Unused") })
            let runner = vm.testACPRunner
            let session = AgentTabSession(tabID: UUID())
            session.appendItem(.user("fixture", sequenceIndex: 0))
            session.runState = .running
            let tracker = UUID()
            try emit("tool_call", id: "failure", input: ["type": "roots"], runner: runner, session: session)
            runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
            let payload = trackerError ? #"{"status":"failed","error":"fixture failure"}"# : rich
            runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: payload, isError: trackerError, session: session)
            for _ in 0 ..< 2 {
                try emit("tool_call_update", id: "failure", status: trackerError ? "completed" : "failed", runner: runner, session: session)
            }
            let tools = session.items.filter { $0.kind == .toolResult }
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual(tools.first?.toolResultJSON, payload)
            XCTAssertEqual(tools.first?.toolIsError, trackerError)
            XCTAssertEqual(session.items.count(where: { $0.kind == .error }), trackerError ? 0 : 1)
        }
    }

    func testResultFirstAssociationRetainsAliasForInputlessUpdates() throws {
        let vm = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in fatalError("Unused") })
        let session = AgentTabSession(tabID: UUID())
        session.appendItem(.user("fixture", sequenceIndex: 0))
        session.runState = .running
        let tracker = UUID()
        vm.testACPRunner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        vm.testACPRunner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: rich, isError: false, session: session)
        try emit("tool_call_update", id: "result-first", status: "completed", input: ["type": "roots"], runner: vm.testACPRunner, session: session)
        try emit("tool_call_update", id: "result-first", status: "completed", runner: vm.testACPRunner, session: session)
        let tools = session.items.filter { $0.kind == .toolResult }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "result-first"))
        XCTAssertEqual(tools.first?.toolResultJSON, rich)
    }

    func testInitiallyAppendedProviderFailureSurvivesTrackerSuccessAsSeparateFailure() throws {
        let vm = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in fatalError("Unused") })
        let session = AgentTabSession(tabID: UUID())
        session.appendItem(.user("fixture", sequenceIndex: 0))
        session.runState = .running
        try emit("tool_call_update", id: "failure-first", status: "failed", input: ["type": "roots"], runner: vm.testACPRunner, session: session)
        let tracker = UUID()
        vm.testACPRunner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        vm.testACPRunner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: rich, isError: false, session: session)
        XCTAssertEqual(session.items.count(where: { $0.kind == .toolResult }), 1)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
    }

    private func emit(_ kind: String, id: String, status: String? = nil, input: [String: String]? = nil, runner: ACPIntegratedAgentModeRunner, session: AgentTabSession) throws {
        var payload: [String: Any] = ["sessionUpdate": kind, "toolCallId": id, "_meta": ["cognition.ai/toolName": toolName]]
        payload["status"] = status
        payload["rawInput"] = input
        for event in provider.normalizeSessionUpdate(payload, sessionID: "fixture") {
            if case let .stream(stream) = event, let tool = AgentToolStreamEvent.from(stream) {
                XCTAssertTrue(runner.handleToolStreamEvent(tool, session: session))
            }
        }
    }
}
