import Foundation
import MCP
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class InteractiveMCPClientSessionConnectTimeoutTests: XCTestCase {
        func testInitializationReturnsConnectResultAndDrainsCancelledTimeoutTask() async throws {
            let fixture = try await makeFixture()
            let timeoutCancelled = CLIConnectSignal()
            do {
                let result = try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: UInt64.max,
                    timeoutSleep: { _ in
                        do {
                            try await Task.sleep(nanoseconds: UInt64.max)
                        } catch {
                            await timeoutCancelled.signal()
                            throw error
                        }
                    }
                ) {
                    try await fixture.client.connect(transport: fixture.clientTransport)
                }

                XCTAssertEqual(result.serverInfo.name, "CLI connect timeout test server")
                let didCancelTimeout = await timeoutCancelled.isSignalled()
                XCTAssertTrue(didCancelTimeout)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testInitializationTimeoutCancelsConnectOperation() async throws {
            let operationStarted = CLIConnectSignal()
            let operationCancelled = CLIConnectSignal()

            do {
                _ = try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: 1,
                    timeoutSleep: { _ in
                        await operationStarted.wait()
                    }
                ) {
                    await operationStarted.signal()
                    do {
                        try await Task.sleep(nanoseconds: UInt64.max)
                    } catch {
                        await operationCancelled.signal()
                        throw error
                    }
                    fatalError("Cancelled initialization operation unexpectedly returned")
                }
                XCTFail("Expected initialization timeout")
            } catch let error as InteractiveSessionError {
                guard case .bootstrapResponseTimeout = error else {
                    XCTFail("Expected bootstrap response timeout, got \(error)")
                    return
                }
            }

            let didStartOperation = await operationStarted.isSignalled()
            let didCancelOperation = await operationCancelled.isSignalled()
            XCTAssertTrue(didStartOperation)
            XCTAssertTrue(didCancelOperation)
        }

        func testCallerCancellationCancelsConnectAndTimeoutTasks() async throws {
            let operationStarted = CLIConnectSignal()
            let operationCancelled = CLIConnectSignal()
            let timeoutCancelled = CLIConnectSignal()

            let initialization = Task {
                try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: UInt64.max,
                    timeoutSleep: { _ in
                        do {
                            try await Task.sleep(nanoseconds: UInt64.max)
                        } catch {
                            await timeoutCancelled.signal()
                            throw error
                        }
                    }
                ) {
                    await operationStarted.signal()
                    do {
                        try await Task.sleep(nanoseconds: UInt64.max)
                    } catch {
                        await operationCancelled.signal()
                        throw error
                    }
                    fatalError("Cancelled initialization operation unexpectedly returned")
                }
            }

            await operationStarted.wait()
            initialization.cancel()

            do {
                _ = try await initialization.value
                XCTFail("Expected caller cancellation")
            } catch is CancellationError {
                // Expected.
            }

            let didCancelOperation = await operationCancelled.isSignalled()
            let didCancelTimeout = await timeoutCancelled.isSignalled()
            XCTAssertTrue(didCancelOperation)
            XCTAssertTrue(didCancelTimeout)
        }

        private func makeFixture() async throws -> CLIConnectFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let server = Server(
                name: "CLI connect timeout test server",
                version: "1.0",
                capabilities: .init()
            )
            try await server.start(transport: transports.server)
            let client = Client(name: "CLI connect timeout test client", version: "1.0")
            return CLIConnectFixture(
                client: client,
                server: server,
                clientTransport: transports.client
            )
        }
    }

    private struct CLIConnectFixture {
        let client: Client
        let server: Server
        let clientTransport: InMemoryTransport

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }

    private actor CLIConnectSignal {
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

        func isSignalled() -> Bool {
            signalled
        }
    }
#endif
