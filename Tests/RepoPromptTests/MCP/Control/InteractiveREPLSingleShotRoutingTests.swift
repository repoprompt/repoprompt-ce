import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveREPLSingleShotRoutingTests: XCTestCase {
        func testContextIDRoutesSingleShotTargetCallToSelectedContext() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            let contextID = "C72119FC-64CD-42E4-B14A-0E6A28DD4DC1"
            var options = InteractiveOptions()
            options.contextID = contextID
            options.callTool = "workspace_context"

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.map(\.name), ["bind_context", "workspace_context"])
            XCTAssertEqual(calls[0].arguments?["context_id"], .string(contextID))
            XCTAssertEqual(calls[0].arguments?["_rawJSON"], .bool(true))
            XCTAssertEqual(calls[1].arguments?["context_id"], .string(contextID))
        }

        func testTabSelectorResolvesAndBindsBeforeSingleShotTargetCall() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            var options = InteractiveOptions()
            options.tabID = "Review Tab"
            options.callTool = "workspace_context"

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.map(\.name), ["bind_context", "bind_context", "workspace_context"])
            XCTAssertEqual(calls[0].arguments?["op"], .string("list"))
            XCTAssertEqual(calls[0].arguments?["_rawJSON"], .bool(true))
            XCTAssertEqual(calls[1].arguments?["context_id"], .string(fixture.namedTabContextID))
            XCTAssertEqual(calls[1].arguments?["_rawJSON"], .bool(true))
            XCTAssertEqual(calls[2].arguments?["context_id"], .string(fixture.namedTabContextID))
        }

        func testContextIDTakesPrecedenceWithoutAttemptingTabResolution() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            let contextID = "8FC92199-2D4B-4324-9790-98155550F0BF"
            var options = InteractiveOptions()
            options.contextID = contextID
            options.tabID = "Review Tab"
            options.callTool = "workspace_context"

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.map(\.name), ["bind_context", "workspace_context"])
            XCTAssertEqual(calls[0].arguments?["op"], .string("bind"))
            XCTAssertEqual(calls[0].arguments?["context_id"], .string(contextID))
            XCTAssertEqual(calls[0].arguments?["_rawJSON"], .bool(true))
            XCTAssertEqual(calls[1].arguments?["context_id"], .string(contextID))
        }

        func testWindowOnlySingleShotInjectsHiddenWindowWithoutBinding() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            var options = InteractiveOptions()
            options.initialWindowID = 7
            options.callTool = "workspace_context"

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.name, "workspace_context")
            XCTAssertEqual(calls.first?.arguments?["_windowID"], .int(7))
            XCTAssertNil(calls.first?.arguments?["context_id"])
        }

        private func makeFixture() async throws -> InteractiveREPLSingleShotRoutingFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = InteractiveREPLToolCallRecorder()
            let namedTabContextID = "EC558D4B-0292-4935-AD42-CEFC6121A31A"
            let server = Server(
                name: "CLI single-shot routing test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params)
                let text = if params.name == "bind_context",
                              params.arguments?["_rawJSON"] != .bool(true)
                {
                    """
                    ## Context Binding

                    Bound to the requested context.
                    """
                } else if params.name == "bind_context", params.arguments?["op"] == .string("list") {
                    """
                    {"windows":[{"window_id":7,"workspace":null,"tabs":[{"context_id":"\(namedTabContextID)","name":"Review Tab"}]}],"binding":{"binding_kind":"unbound","window_id":null,"context_id":null,"workspace_name":null}}
                    """
                } else if params.name == "bind_context",
                          case let .string(contextID)? = params.arguments?["context_id"]
                {
                    """
                    {"binding":{"binding_kind":"tab","window_id":7,"context_id":"\(contextID)","workspace_name":"Test Workspace"}}
                    """
                } else {
                    "ok"
                }
                return .init(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
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
                namedTabContextID: namedTabContextID
            )
        }
    }

    private struct InteractiveREPLRecordedToolCall {
        let name: String
        let arguments: [String: Value]?
    }

    private actor InteractiveREPLToolCallRecorder {
        private var calls: [InteractiveREPLRecordedToolCall] = []

        func record(_ params: CallTool.Parameters) {
            calls.append(.init(name: params.name, arguments: params.arguments))
        }

        func recordedCalls() -> [InteractiveREPLRecordedToolCall] {
            calls
        }
    }

    private struct InteractiveREPLSingleShotRoutingFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let recorder: InteractiveREPLToolCallRecorder
        let namedTabContextID: String

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }
#endif
