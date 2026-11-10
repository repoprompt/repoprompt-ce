import Foundation
import RepoPromptCodexProvider
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CodexNativeShutdownTests: XCTestCase {
    private enum Observation: Equatable {
        case phase(CodexNativeSessionController.ShutdownPhase)
        case handlerReleased
        case callerReturned
    }

    func testConcurrentAndCancelledRetirementsJoinOneEventDrain() async throws {
        let controller = makeController()
        try await controller.test_beginBindingSession()
        let observations = AsyncStream<Observation>.makeStream()
        let releaseHandler = AsyncStream<Void>.makeStream()
        let handlerEntered = expectation(description: "event handler owns mutex")
        let shutdownJoined = expectation(description: "both retirement callers joined")
        shutdownJoined.expectedFulfillmentCount = 2
        let drainStarted = expectation(description: "shutdown reaches event drain")
        controller.test_shutdownObserver = { phase in
            observations.continuation.yield(.phase(phase))
            switch phase {
            case .joined: shutdownJoined.fulfill()
            case .waitingForEventDrain: drainStarted.fulfill()
            default: break
            }
        }
        let handler = Task {
            await controller.test_withEventHandlingLock {
                handlerEntered.fulfill()
                for await _ in releaseHandler.stream {
                    break
                }
                observations.continuation.yield(.handlerReleased)
            }
        }
        await fulfillment(of: [handlerEntered], timeout: 2)
        let first = Task {
            await controller.shutdown()
            observations.continuation.yield(.callerReturned)
        }
        let second = Task {
            await controller.shutdown()
            observations.continuation.yield(.callerReturned)
        }
        // Cancellation must not skip joining or cancel the shared teardown.
        first.cancel()
        second.cancel()
        await fulfillment(of: [shutdownJoined, drainStarted], timeout: 2)
        do {
            try await controller.test_ensureInboundStreamsStarted()
            XCTFail("Shutdown-time recovery must refuse, not report successful installation")
        } catch let error as CodexSessionControllerError {
            if case .invalidLifecycleState = error {} else {
                XCTFail("Unexpected lifecycle refusal: \(error)")
            }
        } catch {
            XCTFail("Expected lifecycle refusal, not transport failure: \(error)")
        }
        let streamFinished = expectation(description: "event delivery closes before handler drain")
        let eventReader = Task {
            var events = controller.events.makeAsyncIterator()
            let next = await events.next()
            XCTAssertNil(next)
            streamFinished.fulfill()
        }
        await fulfillment(of: [streamFinished], timeout: 2)
        releaseHandler.continuation.yield(())
        releaseHandler.continuation.finish()
        await handler.value
        await first.value
        await second.value
        await eventReader.value
        observations.continuation.finish()
        var recorded: [Observation] = []
        for await event in observations.stream {
            recorded.append(event)
        }
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.joined(isOwner: true)) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.joined(isOwner: false)) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.eventStateCleared) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.finished) }), 1)
        let released = try XCTUnwrap(recorded.firstIndex(of: .handlerReleased))
        let cleared = try XCTUnwrap(recorded.firstIndex(of: .phase(.eventStateCleared)))
        let finished = try XCTUnwrap(recorded.firstIndex(of: .phase(.finished)))
        XCTAssertLessThan(released, cleared)
        XCTAssertLessThan(cleared, finished)
        XCTAssertEqual(recorded.count(where: { $0 == .callerReturned }), 2)
        for index in recorded.indices where recorded[index] == .callerReturned {
            XCTAssertLessThan(finished, index)
        }
    }

    func testTerminatedControllerStillCleansUpOnceAndReleasesItsShutdownTaskCapture() async throws {
        weak var releasedController: CodexNativeSessionController?
        let observations = AsyncStream<CodexNativeSessionController.ShutdownPhase>.makeStream()
        let client = CodexAppServerClient(writeFrameHandler: { _, _ in }, livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let originalGeneration = await client.healthyTransportGeneration()
        XCTAssertNotNil(originalGeneration)
        do {
            let controller = CodexNativeSessionController(
                client: client, runID: UUID(), tabID: UUID(), windowID: 1,
                workspacePaths: .uniform(nil), clientShutdownBehavior: .stopOnShutdown
            )
            releasedController = controller
            controller.test_shutdownObserver = { observations.continuation.yield($0) }
            try await controller.test_beginBindingSession()
            await controller.test_simulateTransportStreamEnded(source: "shutdown-owner-test")
            await controller.shutdown()
            await controller.shutdown()
        }
        XCTAssertNil(releasedController, "The stored completed task must not retain its controller")
        let stoppedGeneration = await client.healthyTransportGeneration()
        XCTAssertNil(stoppedGeneration, "A transport-ended controller still owns explicit client cleanup")
        observations.continuation.finish()
        var recorded: [CodexNativeSessionController.ShutdownPhase] = []
        for await phase in observations.stream {
            recorded.append(phase)
        }
        XCTAssertEqual(recorded.count(where: { $0 == .joined(isOwner: true) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .joined(isOwner: false) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .eventStateCleared }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .finished }), 1)
    }

    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(nil)
        )
    }
}
