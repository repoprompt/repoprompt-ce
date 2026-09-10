import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class DispatchTerminationSignalObserverTests: XCTestCase {
    func testHandlerDeliveryLetsANestedModalPanelRunLoopDrainMainActorJobs() {
        XCTAssertTrue(Thread.isMainThread)
        CFRunLoopAddCommonMode(
            CFRunLoopGetMain(),
            CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString)
        )

        let observer = DispatchTerminationSignalObserver()
        var invocationCount = 0
        var handlerRanOnMainThread = false
        var mainActorJobRanInsideNestedLoop = false

        observer.ignoreDefaultDisposition(for: SIGUSR2)
        observer.observe(SIGUSR2) {
            invocationCount += 1
            handlerRanOnMainThread = Thread.isMainThread

            let shutdownJob = MainActorJobFlag()
            Task { @MainActor in shutdownJob.value = true }

            let jobDeadline = Date().addingTimeInterval(2)
            while !shutdownJob.value, Date() < jobDeadline {
                if !RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05)) {
                    usleep(5000)
                }
            }
            mainActorJobRanInsideNestedLoop = shutdownJob.value
        }

        let deliveryDeadline = Date().addingTimeInterval(5)
        while invocationCount == 0, Date() < deliveryDeadline {
            XCTAssertEqual(kill(getpid(), SIGUSR2), 0)
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertGreaterThanOrEqual(invocationCount, 1)
        XCTAssertTrue(handlerRanOnMainThread)
        XCTAssertTrue(
            mainActorJobRanInsideNestedLoop,
            """
            The handler ran inside a main-dispatch-queue callout, so the nested run loop could not \
            drain the main queue and the main-actor job never started. In the app this is the \
            signal-initiated quit deadlock: AppKit waits in its nested loop for a reply that only \
            the starved shutdown task can send.
            """
        )
    }
}

private final class MainActorJobFlag: @unchecked Sendable {
    var value = false
}
