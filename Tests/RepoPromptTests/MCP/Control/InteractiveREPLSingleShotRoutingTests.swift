import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveREPLSingleShotRoutingTests: XCTestCase {
        func testParserPreservesContextIDForSingleShotCall() {
            let contextID = "C72119FC-64CD-42E4-B14A-0E6A28DD4DC1"

            guard case let .interactive(options) = parseCLIMode(arguments: [
                "--context-id", contextID,
                "-c", "bind_context",
                "-j", #"{"op":"status"}"#
            ]) else {
                XCTFail("Expected interactive mode")
                return
            }

            XCTAssertEqual(options.initialContextID, contextID)
            XCTAssertNil(options.initialWindowID)
            XCTAssertNil(options.initialTabID)
        }

        func testParserPreservesWindowAndTabForSingleShotCall() {
            guard case let .interactive(options) = parseCLIMode(arguments: [
                "-w", "1",
                "-t", "T2",
                "-c", "bind_context",
                "-j", #"{"op":"status"}"#
            ]) else {
                XCTFail("Expected interactive mode")
                return
            }

            XCTAssertEqual(options.initialWindowID, 1)
            XCTAssertEqual(options.initialTabID, "T2")
            XCTAssertNil(options.initialContextID)
        }

        func testSingleShotStatusObservesBoundTabAffinity() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            var options = InteractiveOptions()
            options.initialWindowID = 1
            options.initialTabID = "T2"
            options.callTool = "bind_context"
            options.callArgs = #"{"op":"status"}"#

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 3)
            XCTAssertEqual(calls[0].name, "bind_context")
            XCTAssertEqual(calls[0].arguments?["op"], .string("list"))
            XCTAssertEqual(calls[0].arguments?["window_id"], .int(1))
            XCTAssertEqual(calls[1].name, "bind_context")
            XCTAssertEqual(calls[1].arguments?["op"], .string("bind"))
            XCTAssertEqual(calls[1].arguments?["window_id"], .int(1))
            XCTAssertEqual(calls[1].arguments?["context_id"], .string(fixture.contextID))
            XCTAssertEqual(calls[2].name, "bind_context")
            XCTAssertEqual(calls[2].arguments?["op"], .string("status"))
            let observedContextID = await fixture.recorder.statusObservedContextID()
            XCTAssertEqual(observedContextID, fixture.contextID)
        }

        func testSingleShotCallStopsWhenStartupBindingFails() async throws {
            let fixture = try await makeFixture(failBinding: true)
            addTeardownBlock { await fixture.cleanup() }

            var options = InteractiveOptions()
            options.initialContextID = fixture.contextID
            options.callTool = "agent_run"
            options.callArgs = #"{"op":"start"}"#

            do {
                try await InteractiveREPL(session: fixture.session, options: options).run()
                XCTFail("Expected startup binding to fail")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Startup binding failed"))
            }

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.name, "bind_context")
            XCTAssertEqual(calls.first?.arguments?["op"], .string("bind"))
        }

        private func makeFixture(failBinding: Bool = false) async throws -> InteractiveREPLSingleShotRoutingFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = InteractiveREPLToolCallRecorder(failBinding: failBinding)
            let server = Server(
                name: "CLI single-shot routing test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.respond(to: params)
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI single-shot routing test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier
            )
            return InteractiveREPLSingleShotRoutingFixture(
                client: client,
                server: server,
                session: session,
                recorder: recorder,
                contextID: recorder.contextID
            )
        }
    }

    private struct InteractiveREPLRecordedToolCall {
        let name: String
        let arguments: [String: Value]?
    }

    private actor InteractiveREPLToolCallRecorder {
        let contextID = "8FC92199-2D4B-4324-9790-98155550F0BF"
        private let failBinding: Bool
        private var calls: [InteractiveREPLRecordedToolCall] = []
        private var boundContextID: String?
        private var observedStatusContextID: String?

        init(failBinding: Bool) {
            self.failBinding = failBinding
        }

        func respond(to params: CallTool.Parameters) -> CallTool.Result {
            calls.append(.init(name: params.name, arguments: params.arguments))

            guard params.name == "bind_context" else {
                return .init(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
            }

            switch params.arguments?["op"]?.stringValue {
            case "list":
                return jsonResult("""
                {"windows":[{"window_id":1,"workspace":null,"tabs":[{"context_id":"\(contextID)","name":"T2"}]}],"binding":{"binding_kind":"window","window_id":1,"context_id":null,"workspace_name":null}}
                """)

            case "bind":
                if failBinding {
                    return .init(
                        content: [.text(text: "unknown context", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                boundContextID = params.arguments?["context_id"]?.stringValue
                return jsonResult("""
                {"binding":{"binding_kind":"tab","window_id":1,"context_id":"\(boundContextID ?? "")","workspace_name":null}}
                """)

            case "status":
                observedStatusContextID = boundContextID
                return jsonResult("""
                {"binding":{"binding_kind":"tab","window_id":1,"context_id":"\(boundContextID ?? "")","workspace_name":null}}
                """)

            default:
                return .init(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
            }
        }

        func recordedCalls() -> [InteractiveREPLRecordedToolCall] {
            calls
        }

        func statusObservedContextID() -> String? {
            observedStatusContextID
        }

        private func jsonResult(_ json: String) -> CallTool.Result {
            .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
        }
    }

    private struct InteractiveREPLSingleShotRoutingFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let recorder: InteractiveREPLToolCallRecorder
        let contextID: String

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }
#endif
