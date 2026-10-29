#if os(Linux) && DEBUG
    import MCP
    @testable import RepoPromptMCPCore
    import XCTest

    final class LinuxHeadlessCommandLifetimeTests: XCTestCase {
        func testSingleCommandRejectsDetachedStartBeforeSendingAnyToolCall() async throws {
            let fixture = try await makeFixture(status: "running")
            addTeardownBlock { await fixture.cleanup() }
            await fixture.session.setLocalHeadlessSingleCommandMode(true)
            let argumentSets: [[String: Value]] = [
                ["op": .string("start"), "detach": .bool(true)],
                ["detach": .bool(true)]
            ]
            for arguments in argumentSets {
                do {
                    _ = try await fixture.session.callTool(name: "agent_run", arguments: arguments, timeout: .none)
                    XCTFail("A short-lived command must not start detached provider work")
                } catch {
                    XCTAssertTrue(String(describing: error).contains("long-lived MCP connection"))
                }
            }
            let calls = await fixture.recorder.count
            XCTAssertEqual(calls, 0)
        }

        func testUnfinishedWaitReturnsAnErrorWithTheOriginalAgentSnapshot() async throws {
            let fixture = try await makeFixture(status: "running")
            addTeardownBlock { await fixture.cleanup() }
            await fixture.session.setLocalHeadlessSingleCommandMode(true)
            let result = try await fixture.session.callTool(
                name: "agent_run",
                arguments: ["op": .string("start"), "detach": .bool(false), "timeout": .int(0)],
                timeout: .none
            )
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(result.structuredContent?.objectValue?["status"], .string("running"))
            XCTAssertEqual(result.content.count, 2)
            guard case let .text(diagnostic, _, _) = result.content[1] else {
                return XCTFail("Expected an explanation of local runtime shutdown")
            }
            XCTAssertTrue(diagnostic.contains("will cancel remaining providers"))
            let calls = await fixture.recorder.count
            XCTAssertEqual(calls, 1)
        }

        func testInteractiveLifetimeAllowsDetachedWorkWhileTheSessionStaysOpen() async throws {
            let fixture = try await makeFixture(status: "running")
            addTeardownBlock { await fixture.cleanup() }
            let result = try await fixture.session.callTool(
                name: "agent_run",
                arguments: ["op": .string("start"), "detach": .bool(true)],
                timeout: .none
            )
            XCTAssertEqual(result.isError, false)
            let calls = await fixture.recorder.count
            XCTAssertEqual(calls, 1)
        }

        func testCompletedAgentRemainsSuccessfulForSingleCommand() async throws {
            let fixture = try await makeFixture(status: "completed")
            addTeardownBlock { await fixture.cleanup() }
            await fixture.session.setLocalHeadlessSingleCommandMode(true)
            let result = try await fixture.session.callTool(
                name: "agent_run",
                arguments: ["op": .string("start"), "detach": .bool(false)],
                timeout: .none
            )
            XCTAssertEqual(result.isError, false)
            XCTAssertEqual(result.structuredContent?.objectValue?["status"], .string("completed"))
            XCTAssertEqual(result.content.count, 1)
        }

        private func makeFixture(status: String) async throws -> LinuxCommandLifetimeFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = LinuxCommandLifetimeRecorder()
            let server = Server(name: "Linux CLI lifetime fixture", version: "1.0", capabilities: .init(tools: .init()))
            await server.withMethodHandler(CallTool.self) { _ in
                await recorder.record()
                return .init(
                    content: [.text(text: "{\"status\":\"\(status)\"}", annotations: nil, _meta: nil)],
                    structuredContent: .object(["status": .string(status)]),
                    isError: false
                )
            }
            try await server.start(transport: transports.server)
            let barrier = MCPRequestSendBarrier()
            let transport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: barrier,
                logger: transports.client.logger
            )
            let client = Client(name: "Linux CLI lifetime test", version: "1.0")
            _ = try await client.connect(transport: transport)
            return LinuxCommandLifetimeFixture(
                server: server,
                session: InteractiveMCPClientSession(connectedClientForTesting: client, requestSendBarrier: barrier),
                recorder: recorder
            )
        }
    }

    private actor LinuxCommandLifetimeRecorder {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    private struct LinuxCommandLifetimeFixture {
        let server: Server
        let session: InteractiveMCPClientSession
        let recorder: LinuxCommandLifetimeRecorder

        func cleanup() async {
            await session.disconnect()
            await server.stop()
        }
    }
#endif
