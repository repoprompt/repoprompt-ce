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
            let runID = UUID()
            let invocationID = UUID()

            await controller.startTracking(
                runID: runID,
                clientNameHint: nil,
                onCalled: { _, _, _ in
                    recorder.append("call-start")
                    Thread.sleep(forTimeInterval: 0.3)
                    recorder.append("call-end")
                },
                onCompleted: { _, _, _, _, _ in
                    recorder.append("completion")
                }
            )
            addTeardownBlock {
                await controller.stopTracking()
                await manager.unregisterToolObservers(for: runID)
            }

            let durations = await Task.detached {
                let callStartedAt = DispatchTime.now().uptimeNanoseconds
                let calledCount = await manager.debugFireToolCalledObservers(
                    runID: runID,
                    invocationID: invocationID,
                    toolName: "read_file"
                )
                let callDurationMS = Self.elapsedMilliseconds(since: callStartedAt)

                while !recorder.contains("call-start") {
                    try? await Task.sleep(for: .milliseconds(1))
                }

                let completionStartedAt = DispatchTime.now().uptimeNanoseconds
                let completedCount = await manager.debugFireToolCompletedObservers(
                    runID: runID,
                    invocationID: invocationID,
                    toolName: "read_file",
                    resultJSON: #"{"content":"ok"}"#,
                    isError: false
                )
                let completionDurationMS = Self.elapsedMilliseconds(since: completionStartedAt)
                return (calledCount, completedCount, callDurationMS, completionDurationMS)
            }.value

            XCTAssertEqual(durations.0, 1)
            XCTAssertEqual(durations.1, 1)
            XCTAssertLessThan(durations.2, 100)
            XCTAssertLessThan(durations.3, 100)

            await controller.waitForPendingEventDeliveriesForTesting()
            XCTAssertEqual(recorder.snapshot(), ["call-start", "call-end", "completion"])
        }

        func testStopWaitsForCapturedObserverToEnterMailboxAndDrain() async throws {
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

            let stopTask = Task { @MainActor in
                await controller.stopTracking()
                recorder.append("stopped")
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(recorder.contains("stopped"))
            XCTAssertFalse(recorder.contains("call"))

            await deliveryGate.release()
            let firedCount = await fireTask.value
            await stopTask.value
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)

            XCTAssertEqual(firedCount, 1)
            XCTAssertEqual(recorder.snapshot(), ["call", "stopped"])
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(recorder.snapshot(), ["call", "stopped"])
        }

        func testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier() async throws {
            let manager = ServerNetworkManager.shared
            let controller = AgentToolTrackingController()
            let recorder = LockedEventRecorder()
            let deliveryGate = AsyncDeliveryGate()
            let runID = UUID()

            await controller.startTracking(
                runID: runID,
                clientNameHint: nil,
                onCalled: { _, _, _ in
                    recorder.append("call-start")
                    Thread.sleep(forTimeInterval: 0.1)
                    recorder.append("call-drained")
                },
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

            let rawUnregisterTask = Task {
                await manager.unregisterToolEventObservers(for: runID)
            }
            for _ in 0 ..< 100 {
                if await manager.toolEventObserverCount(for: runID) == 0 {
                    break
                }
                await Task.yield()
            }
            let observerCountAfterRawUnregister = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(observerCountAfterRawUnregister, 0)

            _ = await manager.registerToolEventObserver(
                for: runID,
                observer: ServerNetworkManager.ToolEventObserver(onCalled: { _, _, _ in }, onCompleted: nil)
            )
            let laterEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(laterEventObserverCount, 1)

            let stopTask = Task { @MainActor in
                await controller.stopTracking()
                recorder.append("stopped")
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(recorder.contains("stopped"))
            XCTAssertFalse(recorder.contains("call-start"))

            await deliveryGate.release()
            let firedCount = await fireTask.value
            await rawUnregisterTask.value
            await stopTask.value
            await manager.debugSetBeforeToolEventObserverDeliveryForTesting(nil)

            XCTAssertEqual(firedCount, 1)
            let retainedEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(retainedEventObserverCount, 1)
            await manager.unregisterToolEventObservers(for: runID)
            let finalEventObserverCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(finalEventObserverCount, 0)
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
