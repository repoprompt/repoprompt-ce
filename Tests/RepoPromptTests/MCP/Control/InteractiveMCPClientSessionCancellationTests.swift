import Foundation
import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveMCPClientSessionCancellationTests: XCTestCase {
        func testImmediateTimeoutRegistersAndSendsBeforeCancellationWithoutWaitingForHandlerStartup() async throws {
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                timeoutSleep: { _ in }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .seconds(42)
                    )
                }
                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "slow_tool")
                    XCTAssertEqual(seconds, 42)
                }

                await fixture.handlerCancelled.wait()
                await fixture.ignoredCancellationRelease.signal()
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testCallerCancellationBeforeRequestTaskStartupStillSendsThenCancels() async throws {
            let requestStartGate = CLIAsyncGate()
            let fixture = try await makeFixture(
                requestSendWillStart: {
                    await requestStartGate.arriveAndWait()
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .none
                    )
                }
                await requestStartGate.waitUntilArrived()
                call.cancel()
                await requestStartGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected caller cancellation")
                } catch is CancellationError {
                    // Expected.
                }

                await fixture.handlerCancelled.wait()
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        private func makeFixture(
            cancellationBehavior: CLICancellationBehavior = .cooperative,
            requestSendWillStart: (@Sendable () async -> Void)? = nil,
            timeoutSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        ) async throws -> CLISessionCancellationFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let handlerCancelled = CLIAsyncSignal()
            let ignoredCancellationRelease = CLIAsyncSignal()
            let cancellationSuspension = CLICancellationSuspension()
            let server = Server(
                name: "CLI cancellation test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { _ in
                do {
                    try await cancellationSuspension.wait()
                    return .init(
                        content: [.text(text: "unexpected", annotations: nil, _meta: nil)],
                        isError: false
                    )
                } catch is CancellationError {
                    await handlerCancelled.signal()
                    switch cancellationBehavior {
                    case .cooperative:
                        throw CancellationError()
                    case .ignoreUntilReleased:
                        await ignoredCancellationRelease.wait()
                        return .init(
                            content: [.text(text: "late result", annotations: nil, _meta: nil)],
                            isError: false
                        )
                    }
                }
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI cancellation test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier,
                requestSendWillStart: requestSendWillStart,
                timeoutSleep: timeoutSleep
            )
            return CLISessionCancellationFixture(
                client: client,
                server: server,
                session: session,
                handlerCancelled: handlerCancelled,
                ignoredCancellationRelease: ignoredCancellationRelease
            )
        }
    }

    private enum CLICancellationBehavior {
        case cooperative
        case ignoreUntilReleased
    }

    private struct CLISessionCancellationFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let handlerCancelled: CLIAsyncSignal
        let ignoredCancellationRelease: CLIAsyncSignal

        func cleanup() async {
            await ignoredCancellationRelease.signal()
            await client.disconnect()
            await server.stop()
        }
    }

    private actor CLIAsyncGate {
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            arrived = true
            let arrivalWaiters = arrivalWaiters
            self.arrivalWaiters.removeAll()
            for waiter in arrivalWaiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilArrived() async {
            guard !arrived else { return }
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }

        func release() {
            guard !released else { return }
            released = true
            let releaseWaiters = releaseWaiters
            self.releaseWaiters.removeAll()
            for waiter in releaseWaiters {
                waiter.resume()
            }
        }
    }

    private actor CLIAsyncSignal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !signalled else { return }
            signalled = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private actor CLICancellationSuspension {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var waiter: Waiter?
        private var cancelledWaiterIDs: Set<UUID> = []

        func wait() async throws {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiter = Waiter(id: waiterID, continuation: continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancel(waiterID) }
            }
        }

        private func cancel(_ waiterID: UUID) {
            guard let waiter, waiter.id == waiterID else {
                cancelledWaiterIDs.insert(waiterID)
                return
            }
            self.waiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
#endif
