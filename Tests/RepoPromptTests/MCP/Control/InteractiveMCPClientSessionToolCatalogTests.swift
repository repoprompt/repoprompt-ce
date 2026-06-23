import Foundation
import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveMCPClientSessionToolCatalogTests: XCTestCase {
        func testCachedToolsOrRefreshReusesCatalogUntilDirty() async throws {
            let fixture = try await makeToolCatalogFixture()
            addTeardownBlock { await fixture.cleanup() }

            let first = try await fixture.session.cachedToolsOrRefresh()
            let second = try await fixture.session.cachedToolsOrRefresh()

            XCTAssertEqual(first.map(\.name), ["tool_1"])
            XCTAssertEqual(second.map(\.name), ["tool_1"])
            let callCountAfterCachedRead = await fixture.listCounter.count()
            XCTAssertEqual(callCountAfterCachedRead, 1)

            await fixture.session.test_markToolsDirty()
            await fixture.session.acknowledgeToolsChanged()
            let noticePending = await fixture.session.toolsChangeNoticePending
            let toolsStillDirty = await fixture.session.toolsDirty
            XCTAssertFalse(noticePending)
            XCTAssertTrue(toolsStillDirty)

            let refreshed = try await fixture.session.cachedToolsOrRefresh()

            XCTAssertEqual(refreshed.map(\.name), ["tool_2"])
            let callCountAfterDirtyRefresh = await fixture.listCounter.count()
            XCTAssertEqual(callCountAfterDirtyRefresh, 2)
        }

        func testRefreshToolsRetriesWhenInvalidatedDuringListRequest() async throws {
            let controller = CLIToolListRaceController()
            let fixture = try await makeToolCatalogRaceFixture(controller: controller)
            addTeardownBlock { await fixture.cleanup() }

            let refresh = Task {
                try await fixture.session.refreshTools()
            }
            await controller.waitUntilFirstRequestStarted()
            await fixture.session.test_markToolsDirty()
            await controller.releaseFirstRequest()

            let tools = try await refresh.value

            XCTAssertEqual(tools.map(\.name), ["tool_2"])
            let cachedToolNames = await fixture.session.tools().map(\.name)
            let toolsDirty = await fixture.session.toolsDirty
            let noticePending = await fixture.session.toolsChangeNoticePending
            let requestCount = await controller.count()
            XCTAssertEqual(cachedToolNames, ["tool_2"])
            XCTAssertFalse(toolsDirty)
            XCTAssertFalse(noticePending)
            XCTAssertEqual(requestCount, 2)
        }

        func testOverlappingRefreshesCoalesceOntoNewestSuccessfulCatalog() async throws {
            let controller = CLIToolListRaceController()
            let awaitCounter = CLIAsyncCounter()
            let fixture = try await makeToolCatalogRaceFixture(
                controller: controller,
                toolListRefreshWillAwait: { await awaitCounter.record() }
            )
            addTeardownBlock { await fixture.cleanup() }

            let olderRefresh = Task {
                try await fixture.session.refreshTools()
            }
            await controller.waitUntilFirstRequestStarted()
            let newerRefresh = Task {
                try await fixture.session.refreshTools()
            }
            await awaitCounter.wait(until: 2)

            var requestCount = await controller.count()
            XCTAssertEqual(requestCount, 1)
            await controller.releaseFirstRequest()
            let olderTools = try await olderRefresh.value
            let newerTools = try await newerRefresh.value

            XCTAssertEqual(olderTools.map(\.name), ["tool_1"])
            XCTAssertEqual(newerTools.map(\.name), ["tool_1"])
            let cachedToolNames = await fixture.session.tools().map(\.name)
            let toolsDirty = await fixture.session.toolsDirty
            XCTAssertEqual(cachedToolNames, ["tool_1"])
            XCTAssertFalse(toolsDirty)
            requestCount = await controller.count()
            XCTAssertEqual(requestCount, 1)
        }

        func testCancelledRefreshWaiterLeavesSharedFlightRunning() async throws {
            let controller = CLIToolListRaceController()
            let awaitCounter = CLIAsyncCounter()
            let fixture = try await makeToolCatalogRaceFixture(
                controller: controller,
                toolListRefreshWillAwait: { await awaitCounter.record() }
            )
            addTeardownBlock { await fixture.cleanup() }

            let survivingRefresh = Task {
                try await fixture.session.refreshTools()
            }
            await controller.waitUntilFirstRequestStarted()
            let cancelledRefresh = Task {
                try await fixture.session.refreshTools()
            }
            await awaitCounter.wait(until: 2)
            cancelledRefresh.cancel()

            do {
                _ = try await cancelledRefresh.value
                XCTFail("Expected cancelled refresh waiter")
            } catch is CancellationError {
                // Expected. The shared request must remain available to the other waiter.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }

            var requestCount = await controller.count()
            XCTAssertEqual(requestCount, 1)
            await controller.releaseFirstRequest()
            let tools = try await survivingRefresh.value
            XCTAssertEqual(tools.map(\.name), ["tool_1"])
            requestCount = await controller.count()
            XCTAssertEqual(requestCount, 1)
        }

        func testRefreshToolsIgnoresResponseFromPreviousConnectionEpoch() async throws {
            let oldController = CLIToolListRaceController(toolPrefix: "old_tool")
            let oldFixture = try await makeToolCatalogRaceFixture(controller: oldController)
            let newController = CLIToolListRaceController(toolPrefix: "new_tool", blocksFirstRequest: false)
            let newFixture = try await makeToolCatalogRaceFixture(controller: newController)
            addTeardownBlock {
                await oldFixture.cleanup()
                await newFixture.cleanup()
            }

            let oldRefresh = Task {
                try await oldFixture.session.refreshTools()
            }
            await oldController.waitUntilFirstRequestStarted()
            await oldFixture.session.test_replaceConnectedClient(
                newFixture.client,
                requestSendBarrier: newFixture.requestSendBarrier
            )

            let newTools = try await oldFixture.session.refreshTools()
            await oldController.releaseFirstRequest()
            let oldTools = try await oldRefresh.value

            XCTAssertEqual(newTools.map(\.name), ["new_tool_1"])
            XCTAssertEqual(oldTools.map(\.name), ["new_tool_1"])
            let cachedToolNames = await oldFixture.session.tools().map(\.name)
            let oldRequestCount = await oldController.count()
            let newRequestCount = await newController.count()
            XCTAssertEqual(cachedToolNames, ["new_tool_1"])
            XCTAssertEqual(oldRequestCount, 1)
            XCTAssertEqual(newRequestCount, 1)
        }

        private func makeToolCatalogRaceFixture(
            controller: CLIToolListRaceController,
            toolListRefreshWillAwait: (@Sendable () async -> Void)? = nil
        ) async throws -> CLIToolCatalogRaceFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let server = Server(
                name: "CLI tool catalog race test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(ListTools.self) { _ in
                await ListTools.Result(tools: controller.toolsForNextRequest())
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI tool catalog race test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier,
                toolListRefreshWillAwait: toolListRefreshWillAwait
            )
            return CLIToolCatalogRaceFixture(
                client: client,
                server: server,
                session: session,
                requestSendBarrier: requestSendBarrier,
                controller: controller
            )
        }

        private func makeToolCatalogFixture() async throws -> CLIToolCatalogFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let listCounter = CLIToolListCounter()
            let server = Server(
                name: "CLI tool catalog cache test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(ListTools.self) { _ in
                let callNumber = await listCounter.record()
                return ListTools.Result(tools: [
                    Tool(name: "tool_\(callNumber)", description: nil, inputSchema: [:])
                ])
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI tool catalog cache test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier
            )
            return CLIToolCatalogFixture(
                client: client,
                server: server,
                session: session,
                listCounter: listCounter
            )
        }
    }

    private struct CLIToolCatalogFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let listCounter: CLIToolListCounter

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }

    private struct CLIToolCatalogRaceFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let requestSendBarrier: MCPRequestSendBarrier
        let controller: CLIToolListRaceController

        func cleanup() async {
            await controller.releaseFirstRequest()
            await client.disconnect()
            await server.stop()
        }
    }

    private actor CLIAsyncCounter {
        private var value = 0
        private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record() {
            value += 1
            let ready = waiters.filter { value >= $0.target }
            waiters.removeAll { value >= $0.target }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }

        func wait(until target: Int) async {
            guard value < target else { return }
            await withCheckedContinuation { continuation in
                waiters.append((target, continuation))
            }
        }
    }

    private actor CLIToolListCounter {
        private var value = 0

        func record() -> Int {
            value += 1
            return value
        }

        func count() -> Int {
            value
        }
    }

    private actor CLIToolListRaceController {
        private let toolPrefix: String
        private let blocksFirstRequest: Bool
        private var value = 0
        private var firstRequestStarted = false
        private var firstRequestReleased = false
        private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(toolPrefix: String = "tool", blocksFirstRequest: Bool = true) {
            self.toolPrefix = toolPrefix
            self.blocksFirstRequest = blocksFirstRequest
        }

        func toolsForNextRequest() async -> [Tool] {
            value += 1
            let requestNumber = value
            if requestNumber == 1 {
                firstRequestStarted = true
                let startWaiters = firstStartWaiters
                firstStartWaiters.removeAll()
                for waiter in startWaiters {
                    waiter.resume()
                }
                if blocksFirstRequest, !firstRequestReleased {
                    await withCheckedContinuation { continuation in
                        firstReleaseWaiters.append(continuation)
                    }
                }
            }
            return [Tool(name: "\(toolPrefix)_\(requestNumber)", description: nil, inputSchema: [:])]
        }

        func waitUntilFirstRequestStarted() async {
            guard !firstRequestStarted else { return }
            await withCheckedContinuation { continuation in
                firstStartWaiters.append(continuation)
            }
        }

        func releaseFirstRequest() {
            guard !firstRequestReleased else { return }
            firstRequestReleased = true
            let releaseWaiters = firstReleaseWaiters
            firstReleaseWaiters.removeAll()
            for waiter in releaseWaiters {
                waiter.resume()
            }
        }

        func count() -> Int {
            value
        }
    }

#endif
