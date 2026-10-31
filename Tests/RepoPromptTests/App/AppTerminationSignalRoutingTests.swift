import AppKit
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
    func testRepeatedQuitJoinsCleanupAndRepliesOnce() async {
        var freezes = 0
        var cleanups = 0
        var replies = 0
        let finished = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            freeze: { freezes += 1 },
            cleanup: { cleanups += 1 },
            requestTermination: { XCTFail("Unexpected independent quit") }
        )
        let reply = { replies += 1
            finished.fulfill()
        }
        XCTAssertEqual(coordinator.shouldTerminate(reply: reply), .terminateLater)
        XCTAssertEqual(coordinator.shouldTerminate(reply: reply), .terminateLater)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(freezes, 1)
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(coordinator.shouldTerminate(reply: reply), .terminateNow)
    }

    func testSparkleResumesAfterCleanupAndDoesNotDeferActualQuit() async {
        var cleaned = false
        let resumed = expectation(description: "installation resumed")
        let coordinator = AppTerminationCoordinator(
            freeze: {}, cleanup: { cleaned = true },
            requestTermination: { XCTFail("Sparkle owns termination") }
        )
        XCTAssertTrue(coordinator.postponeInstallation {
            XCTAssertTrue(cleaned)
            XCTAssertEqual(coordinator.shouldTerminate(reply: { XCTFail("Must not defer") }), .terminateNow)
            resumed.fulfill()
        })
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertFalse(coordinator.postponeInstallation { XCTFail("Already ready") })
    }

    func testQuitDuringSparklePreparationPreservesInstallationContinuation() async {
        let resumed = expectation(description: "installation still resumed")
        let coordinator = AppTerminationCoordinator(
            freeze: {}, cleanup: {}, requestTermination: { XCTFail("Must not race installation") }
        )
        XCTAssertTrue(coordinator.postponeInstallation {
            XCTAssertEqual(coordinator.shouldTerminate(reply: {}), .terminateNow)
            resumed.fulfill()
        })
        XCTAssertEqual(coordinator.shouldTerminate(reply: { XCTFail("Must resume installer first") }), .terminateLater)
        await fulfillment(of: [resumed], timeout: 2)
    }

    func testRunLoopDeadlineProgressesWithoutMainActorTaskProgress() async {
        let finished = expectation(description: "main-dispatch termination callout completed")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var replied = false
                var cleaned = false
                let coordinator = AppTerminationCoordinator(
                    timeout: 0.02, freeze: {}, cleanup: { cleaned = true },
                    requestTermination: { XCTFail("AppKit reply is pending") }
                )
                XCTAssertEqual(coordinator.shouldTerminate(reply: { replied = true }), .terminateLater)
                // Hold an actual main-dispatch callout, as an updater can do. A nested
                // run loop must deliver the deadline without re-entering the main queue.
                let deadline = Date().addingTimeInterval(1)
                while !replied, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                XCTAssertTrue(replied)
                XCTAssertFalse(cleaned)
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testDeadlineDoesNotWaitForUncooperativeCleanupOrReplyTwice() async {
        var continuation: CheckedContinuation<Void, Never>?
        var replies = 0
        let replied = expectation(description: "deadline reply")
        let started = expectation(description: "cleanup started")
        let coordinator = AppTerminationCoordinator(
            timeout: 0.05, freeze: {},
            cleanup: {
                await withCheckedContinuation { continuation = $0
                    started.fulfill()
                }
            },
            requestTermination: { XCTFail("Already replied to AppKit") }
        )
        XCTAssertEqual(coordinator.shouldTerminate {
            replies += 1
            replied.fulfill()
        }, .terminateLater)
        await fulfillment(of: [started, replied], timeout: 2)
        XCTAssertTrue(coordinator.isReady)
        continuation?.resume()
        await Task.yield()
        XCTAssertEqual(replies, 1)
    }
}
