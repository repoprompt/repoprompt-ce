#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPrompt
    import XCTest

    final class AgentToolTrackingControllerTests: XCTestCase {
        func testToolObserverCallbacksReturnBeforeFIFOTranscriptDeliveryCompletes() async {
            let manager = ServerNetworkManager.shared
            let controller = AgentToolTrackingController()
            let recorder = LockedEventRecorder()
            let callbackGate = SynchronousCallbackGate()
            let runID = UUID()
            let invocationID = UUID()

            await controller.startTracking(
                runID: runID,
                clientNameHint: nil,
                onCalled: { _, _, _ in
                    recorder.append("call-start")
                    callbackGate.enterAndBlockUntilReleased()
                    recorder.append("call-end")
                },
                onCompleted: { _, _, _, _, _ in
                    recorder.append("completion")
                }
            )
            addTeardownBlock {
                callbackGate.release()
                await controller.stopTracking()
                await manager.unregisterToolObservers(for: runID)
            }

            let callReturned = SynchronousCheckpoint()
            let callTask = Task.detached {
                let callStartedAt = DispatchTime.now().uptimeNanoseconds
                let calledCount = await manager.debugFireToolCalledObservers(
                    runID: runID,
                    invocationID: invocationID,
                    toolName: "read_file"
                )
                let callDurationMS = Self.elapsedMilliseconds(since: callStartedAt)
                callReturned.signal()
                return (calledCount, callDurationMS)
            }

            await callbackGate.waitUntilEntered()
            let callReturnedBeforeCallbackRelease = await waitForCheckpoint(callReturned)
            XCTAssertTrue(callReturnedBeforeCallbackRelease)
            guard callReturnedBeforeCallbackRelease else {
                callbackGate.release()
                _ = await callTask.value
                return
            }
            let callResult = await callTask.value

            let completionReturned = SynchronousCheckpoint()
            let completionTask = Task.detached {
                let completionStartedAt = DispatchTime.now().uptimeNanoseconds
                let completedCount = await manager.debugFireToolCompletedObservers(
                    runID: runID,
                    invocationID: invocationID,
                    toolName: "read_file",
                    resultJSON: #"{"content":"ok"}"#,
                    isError: false
                )
                let completionDurationMS = Self.elapsedMilliseconds(since: completionStartedAt)
                completionReturned.signal()
                return (completedCount, completionDurationMS)
            }

            let completionReturnedBeforeCallbackRelease = await waitForCheckpoint(completionReturned)
            XCTAssertTrue(completionReturnedBeforeCallbackRelease)
            callbackGate.release()
            guard completionReturnedBeforeCallbackRelease else {
                _ = await completionTask.value
                return
            }
            let completionResult = await completionTask.value

            XCTAssertEqual(callResult.0, 1)
            XCTAssertEqual(completionResult.0, 1)
            XCTAssertLessThan(callResult.1, 100)
            XCTAssertLessThan(completionResult.1, 100)

            await controller.waitForPendingEventDeliveriesForTesting()
            XCTAssertEqual(recorder.snapshot(), ["call-start", "call-end", "completion"])
        }

        func testStopWaitsForCapturedObserverToEnterMailboxAndDrain() async {
            let manager = ServerNetworkManager.shared
            let controller = AgentToolTrackingController()
            let recorder = LockedEventRecorder()
            let deliveryGate = AsyncDeliveryGate()
            let runID = UUID()

            await controller.startTracking(
                runID: runID,
                clientNameHint: nil,
                onCalled: { _, _, _ in recorder.append("call") },
                onCompleted: { _, _, _, _, _ in }
            )
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting {
                await deliveryGate.pause()
            }
            addTeardownBlock {
                await deliveryGate.release()
                await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)
                await controller.stopTracking()
                await manager.unregisterToolObservers(for: runID)
            }

            let fireTask = Task {
                await manager.debugFireToolCalledObservers(
                    runID: runID,
                    invocationID: UUID(),
                    toolName: "read_file"
                )
            }
            await deliveryGate.waitUntilPaused()

            let stopStarted = SynchronousCheckpoint()
            let stopTask = Task { @MainActor in
                stopStarted.signal()
                await controller.stopTracking()
                recorder.append("stopped")
            }
            await stopStarted.wait()
            let observerWasRemoved = await waitForToolObserverCount(0, for: runID, manager: manager)
            XCTAssertTrue(observerWasRemoved)
            XCTAssertFalse(recorder.contains("stopped"))
            XCTAssertFalse(recorder.contains("call"))

            await deliveryGate.release()
            let firedCount = await fireTask.value
            await stopTask.value
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)

            XCTAssertEqual(firedCount, 1)
            await controller.waitForPendingEventDeliveriesForTesting()
            XCTAssertEqual(recorder.snapshot(), ["call", "stopped"])
        }

        func testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier() async {
            let manager = ServerNetworkManager.shared
            let controller = AgentToolTrackingController()
            let recorder = LockedEventRecorder()
            let deliveryGate = AsyncDeliveryGate()
            let callbackGate = SynchronousCallbackGate()
            let runID = UUID()

            await controller.startTracking(
                runID: runID,
                clientNameHint: nil,
                onCalled: { _, _, _ in
                    recorder.append("call-start")
                    callbackGate.enterAndBlockUntilReleased()
                    recorder.append("call-drained")
                },
                onCompleted: { _, _, _, _, _ in }
            )
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting {
                await deliveryGate.pause()
            }
            addTeardownBlock {
                await deliveryGate.release()
                callbackGate.release()
                await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)
                await controller.stopTracking()
                await manager.unregisterToolObservers(for: runID)
            }

            let fireReturned = SynchronousCheckpoint()
            let fireTask = Task {
                let firedCount = await manager.debugFireToolCalledObservers(
                    runID: runID,
                    invocationID: UUID(),
                    toolName: "read_file"
                )
                fireReturned.signal()
                return firedCount
            }
            await deliveryGate.waitUntilPaused()

            let rawUnregisterReturned = SynchronousCheckpoint()
            let rawUnregisterTask = Task {
                await manager.unregisterToolEventObservers(for: runID)
                rawUnregisterReturned.signal()
            }
            let rawUnregisterRemovedObserver = await waitForToolObserverCount(0, for: runID, manager: manager)
            XCTAssertTrue(rawUnregisterRemovedObserver)

            _ = await manager.registerToolEventObserver(
                for: runID,
                observer: ServerNetworkManager.ToolEventObserver(onCalled: { _, _, _ in }, onCompleted: nil)
            )
            let laterEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(laterEventObserverCount, 1)

            let stopStarted = SynchronousCheckpoint()
            let stopTask = Task { @MainActor in
                stopStarted.signal()
                await controller.stopTracking()
                recorder.append("stopped")
            }
            await stopStarted.wait()
            await yieldCooperativeTurns()
            XCTAssertFalse(recorder.contains("stopped"))
            XCTAssertFalse(recorder.contains("call-start"))

            await deliveryGate.release()
            await callbackGate.waitUntilEntered()
            let fireReturnedBeforeCallbackDrain = await waitForCheckpoint(fireReturned)
            let rawUnregisterReturnedBeforeCallbackDrain = await waitForCheckpoint(rawUnregisterReturned)
            XCTAssertTrue(fireReturnedBeforeCallbackDrain)
            XCTAssertTrue(rawUnregisterReturnedBeforeCallbackDrain)
            XCTAssertFalse(recorder.contains("stopped"))
            callbackGate.release()
            let firedCount = await fireTask.value
            await rawUnregisterTask.value
            await stopTask.value
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)

            guard fireReturnedBeforeCallbackDrain, rawUnregisterReturnedBeforeCallbackDrain else { return }
            XCTAssertEqual(firedCount, 1)
            let retainedEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(retainedEventObserverCount, 1)
            await manager.unregisterToolEventObservers(for: runID)
            let finalEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(finalEventObserverCount, 0)
            await controller.waitForPendingEventDeliveriesForTesting()
            let events = recorder.snapshot()
            XCTAssertEqual(events, ["call-start", "call-drained", "stopped"])
        }

        func testOverlappingStopAndStartUnregistersOldObserverAndReleasesCallbacks() async {
            let manager = ServerNetworkManager.shared
            let controller = AgentToolTrackingController()
            let firstRunID = UUID()
            let secondRunID = UUID()
            let recorder = LockedEventRecorder()
            var probe: CallbackLifetimeProbe? = CallbackLifetimeProbe()
            weak var weakProbe = probe
            var firstOnCalled: @MainActor (UUID, String, [String: Value]?) -> Void = { [probe] _, _, _ in
                probe?.record()
                recorder.append("first")
            }
            var firstOnCompleted: @MainActor (UUID, String, [String: Value]?, String, Bool) -> Void = { [probe] _, _, _, _, _ in
                probe?.record()
                recorder.append("first-completion")
            }

            await controller.startTracking(
                runID: firstRunID,
                clientNameHint: nil,
                onCalled: firstOnCalled,
                onCompleted: firstOnCompleted
            )
            let initialFirstObserverCount = await manager.toolEventObserverCount(for: firstRunID)
            XCTAssertEqual(initialFirstObserverCount, 1)
            probe = nil
            firstOnCalled = { _, _, _ in }
            firstOnCompleted = { _, _, _, _, _ in }
            XCTAssertNotNil(weakProbe)

            let stopTask = Task { @MainActor in
                await controller.stopTracking()
            }
            await Task.yield()
            let startTask = Task { @MainActor in
                await controller.startTracking(
                    runID: secondRunID,
                    clientNameHint: nil,
                    onCalled: { _, _, _ in recorder.append("second") },
                    onCompleted: { _, _, _, _, _ in recorder.append("second-completion") }
                )
            }
            await stopTask.value
            await startTask.value

            let finalFirstObserverCount = await manager.toolEventObserverCount(for: firstRunID)
            let activeSecondObserverCount = await manager.toolEventObserverCount(for: secondRunID)
            XCTAssertEqual(finalFirstObserverCount, 0)
            XCTAssertEqual(activeSecondObserverCount, 1)
            XCTAssertNil(weakProbe)

            let firstFireCount = await manager.debugFireToolCalledObservers(
                runID: firstRunID,
                invocationID: UUID(),
                toolName: "read_file"
            )
            let secondFireCount = await manager.debugFireToolCalledObservers(
                runID: secondRunID,
                invocationID: UUID(),
                toolName: "read_file"
            )
            await controller.waitForPendingEventDeliveriesForTesting()

            XCTAssertEqual(firstFireCount, 0)
            XCTAssertEqual(secondFireCount, 1)
            XCTAssertEqual(recorder.snapshot(), ["second"])

            await controller.stopTracking()
            let finalSecondObserverCount = await manager.toolEventObserverCount(for: secondRunID)
            XCTAssertEqual(finalSecondObserverCount, 0)
        }

        private nonisolated static func elapsedMilliseconds(since startedAt: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        }

        private func waitForToolObserverCount(
            _ expectedCount: Int,
            for runID: UUID,
            manager: ServerNetworkManager,
            maxYields: Int = 10000
        ) async -> Bool {
            for _ in 0 ..< maxYields {
                if await manager.toolEventObserverCount(for: runID) == expectedCount {
                    return true
                }
                await Task.yield()
            }
            return await manager.toolEventObserverCount(for: runID) == expectedCount
        }

        private func yieldCooperativeTurns(_ count: Int = 10) async {
            for _ in 0 ..< count {
                await Task.yield()
            }
        }

        private func waitForCheckpoint(_ checkpoint: SynchronousCheckpoint, maxYields: Int = 10000) async -> Bool {
            for _ in 0 ..< maxYields {
                if checkpoint.hasSignaled() {
                    return true
                }
                await Task.yield()
            }
            return checkpoint.hasSignaled()
        }
    }

    private final class SynchronousCheckpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignaled = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func signal() {
            let continuationsToResume: [CheckedContinuation<Void, Never>]
            lock.lock()
            guard !isSignaled else {
                lock.unlock()
                return
            }
            isSignaled = true
            continuationsToResume = continuations
            continuations.removeAll()
            lock.unlock()
            continuationsToResume.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately: Bool
                lock.lock()
                if isSignaled {
                    shouldResumeImmediately = true
                } else {
                    shouldResumeImmediately = false
                    continuations.append(continuation)
                }
                lock.unlock()
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }

        func hasSignaled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isSignaled
        }
    }

    private final class SynchronousCallbackGate: @unchecked Sendable {
        private let entered = SynchronousCheckpoint()
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var isReleased = false

        func enterAndBlockUntilReleased() {
            entered.signal()
            lock.lock()
            let released = isReleased
            lock.unlock()
            guard !released else { return }
            releaseSemaphore.wait()
        }

        func waitUntilEntered() async {
            await entered.wait()
        }

        func release() {
            lock.lock()
            guard !isReleased else {
                lock.unlock()
                return
            }
            isReleased = true
            lock.unlock()
            releaseSemaphore.signal()
        }
    }

    private final class LockedEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func contains(_ event: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return events.contains(event)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private final class CallbackLifetimeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private actor AsyncDeliveryGate {
        private var isPaused = false
        private var isReleased = false
        private var pausedContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        func pause() async {
            isPaused = true
            let paused = pausedContinuations
            pausedContinuations.removeAll()
            paused.forEach { $0.resume() }
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        func waitUntilPaused() async {
            guard !isPaused else { return }
            await withCheckedContinuation { continuation in
                pausedContinuations.append(continuation)
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            let releases = releaseContinuations
            releaseContinuations.removeAll()
            releases.forEach { $0.resume() }
        }
    }

#endif
