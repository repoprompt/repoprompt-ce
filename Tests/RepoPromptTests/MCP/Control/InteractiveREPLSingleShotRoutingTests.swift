import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveREPLSingleShotRoutingTests: XCTestCase {
        func testSingleShotCallWithInitialWindowInjectsHiddenWindowWithoutBinding() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            let contextID = "C72119FC-64CD-42E4-B14A-0E6A28DD4DC1"
            var options = InteractiveOptions()
            options.initialWindowID = 7
            options.callTool = "agent_run"
            options.callArgs = """
            {"window_id":42,"context_id":"\(contextID)"}
            """

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.name, "agent_run")
            XCTAssertEqual(calls.first?.arguments?["_windowID"], .int(7))
            XCTAssertEqual(calls.first?.arguments?["window_id"], .int(42))
            XCTAssertEqual(calls.first?.arguments?["context_id"], .string(contextID))
        }

        func testSingleShotCallWithoutInitialWindowPreservesPublicRoutingArgumentsOnly() async throws {
            let fixture = try await makeFixture()
            addTeardownBlock { await fixture.cleanup() }

            let contextID = "8FC92199-2D4B-4324-9790-98155550F0BF"
            var options = InteractiveOptions()
            options.callTool = "agent_run"
            options.callArgs = """
            {"window_id":42,"context_id":"\(contextID)"}
            """

            try await InteractiveREPL(session: fixture.session, options: options).run()

            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.name, "agent_run")
            XCTAssertNil(calls.first?.arguments?["_windowID"])
            XCTAssertEqual(calls.first?.arguments?["window_id"], .int(42))
            XCTAssertEqual(calls.first?.arguments?["context_id"], .string(contextID))
        }

        private func makeFixture() async throws -> InteractiveREPLSingleShotRoutingFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = InteractiveREPLToolCallRecorder()
            let server = Server(
                name: "CLI single-shot routing test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params)
                return .init(
                    content: [.text(text: "ok", annotations: nil, _meta: nil)],
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
                recorder: recorder
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

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }
#endif
