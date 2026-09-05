import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

@_silgen_name("sigaction")
private func posixSigaction(
    _ signal: Int32,
    _ action: UnsafePointer<sigaction>?,
    _ previousAction: UnsafeMutablePointer<sigaction>?
) -> Int32

final class AppTerminationSignalRoutingTests: XCTestCase {
    func testSpawnResetsInheritedIgnoredRoutedSignalDispositions() throws {
        for routedSignal in AppTerminationSignalRouter.routedSignals {
            var previousAction = sigaction()
            guard posixSigaction(routedSignal, nil, &previousAction) == 0 else {
                XCTFail("Could not capture signal \(routedSignal) disposition: errno \(errno)")
                return
            }

            var ignoredAction = sigaction()
            ignoredAction.__sigaction_u.__sa_handler = SIG_IGN
            sigemptyset(&ignoredAction.sa_mask)
            ignoredAction.sa_flags = 0
            guard posixSigaction(routedSignal, &ignoredAction, nil) == 0 else {
                XCTFail("Could not ignore signal \(routedSignal): errno \(errno)")
                return
            }

            // Restore the complete disposition before waiting so this process-wide test state
            // cannot leak beyond the child launch boundary under test.
            var needsDispositionRestore = true
            defer {
                if needsDispositionRestore {
                    var action = previousAction
                    _ = posixSigaction(routedSignal, &action, nil)
                }
            }

            let sentinel = "SIGNAL_\(routedSignal)_WAS_IGNORED"
            let spawned = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", "kill -\(routedSignal) $$; printf \(sentinel)"],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil
            )
            spawned.stdin?.closeFile()

            var action = previousAction
            guard posixSigaction(routedSignal, &action, nil) == 0 else {
                XCTFail("Could not restore signal \(routedSignal) disposition: errno \(errno)")
                return
            }
            needsDispositionRestore = false

            var rawStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(spawned.pid, &rawStatus, 0)
            } while waitResult == -1 && errno == EINTR

            let stdout = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)

            XCTAssertEqual(waitResult, spawned.pid, "signal \(routedSignal)")
            XCTAssertEqual(
                ProcessTermination.decodeWaitStatus(rawStatus),
                .uncaughtSignal(signal: routedSignal),
                "signal \(routedSignal)"
            )
            XCTAssertFalse(stdout.contains(sentinel), "signal \(routedSignal)")
        }
    }

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
