import Foundation
@testable import RepoPromptApp
import XCTest

final class ACPHeadlessProviderLifecycleTests: XCTestCase {
    func testDisposeKeepsLifecycleClosedUntilClaimedControllerTeardownCompletes() async throws {
        let (waiterRegistrations, waiterRegistrationContinuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .unbounded
        )
        var waiterRegistrationIterator = waiterRegistrations.makeAsyncIterator()
        let lifecycle = ACPHeadlessProviderLifecycle {
            waiterRegistrationContinuation.yield(1)
        }

        let (teardownStarts, teardownStartContinuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .unbounded
        )
        var teardownStartIterator = teardownStarts.makeAsyncIterator()
        let (teardownInvocations, teardownInvocationContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .unbounded
        )
        let teardownInvocationCountTask = Task {
            var count = 0
            for await _ in teardownInvocations {
                count += 1
            }
            return count
        }
        let (teardownRelease, teardownReleaseContinuation) = AsyncStream<Void>.makeStream()

        defer {
            teardownReleaseContinuation.finish()
            teardownInvocationContinuation.finish()
            teardownStartContinuation.finish()
            waiterRegistrationContinuation.finish()
        }

        let initialGeneration = try XCTUnwrap(lifecycle.startStreamTask { _ in Task {} })
        let controllerID = UUID()
        XCTAssertTrue(lifecycle.setActiveController(
            ACPHeadlessProviderLifecycle.ControllerHandle(id: controllerID) {
                teardownInvocationContinuation.yield(())
                teardownStartContinuation.yield(1)
                for await _ in teardownRelease {}
            },
            generation: initialGeneration
        ))

        let disposingTask = Task {
            await lifecycle.dispose()
        }
        let teardownStarted = await teardownStartIterator.next()
        XCTAssertEqual(teardownStarted, 1)

        let disposeJoiner = Task {
            await lifecycle.dispose()
        }
        let disposalWaiter = Task {
            await lifecycle.waitForDisposalIfNeeded()
        }
        let firstWaiterRegistration = await waiterRegistrationIterator.next()
        let secondWaiterRegistration = await waiterRegistrationIterator.next()
        XCTAssertEqual(firstWaiterRegistration, 1)
        XCTAssertEqual(secondWaiterRegistration, 1)

        var didCreateLateTask = false
        let lateGeneration = lifecycle.startStreamTask { _ in
            didCreateLateTask = true
            return Task {}
        }
        XCTAssertNil(lateGeneration)
        XCTAssertFalse(didCreateLateTask)

        teardownReleaseContinuation.finish()
        await disposingTask.value
        await disposeJoiner.value
        await disposalWaiter.value

        teardownInvocationContinuation.finish()
        let teardownInvocationCount = await teardownInvocationCountTask.value
        XCTAssertEqual(teardownInvocationCount, 1)

        let reopenedGeneration = try XCTUnwrap(lifecycle.startStreamTask { _ in Task {} })
        XCTAssertGreaterThan(reopenedGeneration, initialGeneration)
        lifecycle.clearStreamTask(generation: reopenedGeneration)
        await lifecycle.dispose()
    }
}
