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
