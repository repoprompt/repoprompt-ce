import Foundation
@testable import RepoPromptApp
import XCTest

final class AppTerminationSignalRoutingTests: XCTestCase {
    func testInstallSuppressesDefaultDispositionBeforeObservationAndRoutesDeliveryExactlyOnce() {
        let observer = RecordingTerminationSignalObserver()
        var terminationRequestCount = 0
        let router = AppTerminationSignalRouter(observer: observer) {
            terminationRequestCount += 1
        }

        router.install()
        router.install()

        XCTAssertEqual(observer.events, [
            .ignoredDefaultDisposition(SIGTERM),
            .observed(SIGTERM)
        ])
        XCTAssertEqual(terminationRequestCount, 0)

        observer.recordedHandler?()
        observer.recordedHandler?()

        XCTAssertEqual(terminationRequestCount, 1)
    }
}

private final class RecordingTerminationSignalObserver: TerminationSignalObserving {
    enum Event: Equatable {
        case ignoredDefaultDisposition(Int32)
        case observed(Int32)
    }

    private(set) var events: [Event] = []
    private(set) var recordedHandler: (() -> Void)?

    func ignoreDefaultDisposition(for signal: Int32) {
        events.append(.ignoredDefaultDisposition(signal))
    }

    func observe(_ signal: Int32, handler: @escaping () -> Void) {
        events.append(.observed(signal))
        recordedHandler = handler
    }
}

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    func testNoncooperativeShutdownStillRepliesAndLateCompletionDoesNotReplyAgain() async {
        let coordinator = AppTerminationCoordinator()
        let gate = ShutdownGate()
        let replied = expectation(description: "quit reply")
        var events: [String] = []
        var replies = 0
        let start = ContinuousClock.now
        coordinator.start(gracefulDeadline: .milliseconds(30), cleanupAllowance: .milliseconds(30), operation: {
            events.append("persist")
            events.append("shutdown")
            await gate.wait()
        }, emergencyCleanup: {
            events.append("cleanup")
        }, reply: {
            replies += 1
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        // Deadlines total 60ms; the generous bound only proves the reply never waits on the gate.
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(events, ["persist", "shutdown", "cleanup"])
        XCTAssertEqual(replies, 1)
        gate.release()
        await Task.yield()
        XCTAssertEqual(replies, 1)
    }

    func testStuckPersistenceAndEmergencyCleanupCannotPreventReply() async {
        let coordinator = AppTerminationCoordinator()
        let persistenceGate = ShutdownGate()
        let cleanupGate = ShutdownGate()
        let replied = expectation(description: "hard deadline reply")
        var shutdownStarted = false
        var cleanupStarted = false
        let start = ContinuousClock.now
        coordinator.start(gracefulDeadline: .milliseconds(30), cleanupAllowance: .milliseconds(30), operation: {
            await persistenceGate.wait()
            shutdownStarted = true
        }, emergencyCleanup: {
            cleanupStarted = true
            await cleanupGate.wait()
        }, reply: {
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertTrue(cleanupStarted)
        XCTAssertFalse(shutdownStarted)
        persistenceGate.release()
        cleanupGate.release()
        await Task.yield()
    }

    func testRepeatedQuitStartsOnlyOneSequenceAndGracefulCompletionSkipsEmergencyCleanup() async {
        let coordinator = AppTerminationCoordinator()
        let replied = expectation(description: "normal quit reply")
        var operations = 0
        var cleanups = 0
        var replies = 0
        for _ in 0 ..< 2 {
            coordinator.start(gracefulDeadline: .milliseconds(100), operation: {
                operations += 1
            }, emergencyCleanup: {
                cleanups += 1
            }, reply: {
                replies += 1
                replied.fulfill()
            })
        }
        await fulfillment(of: [replied], timeout: 5)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(cleanups, 0)
    }
}

@MainActor
private final class ShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
