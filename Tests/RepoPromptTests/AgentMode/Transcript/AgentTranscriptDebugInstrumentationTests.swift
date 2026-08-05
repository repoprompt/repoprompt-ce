#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class AgentTranscriptDebugInstrumentationTests: XCTestCase {
        override func tearDown() {
            AgentTranscriptDebugInstrumentation.reset()
            super.tearDown()
        }

        func testConcurrentConfigureResetAndEmissionUseUnlockedHandlerSnapshots() {
            let recorder = InstrumentationValueRecorder<String>()
            let firstHandlerStarted = DispatchSemaphore(value: 0)
            let releaseFirstHandler = DispatchSemaphore(value: 0)
            let firstEmissionFinished = DispatchSemaphore(value: 0)
            let reconfigurationFinished = DispatchSemaphore(value: 0)

            AgentTranscriptDebugInstrumentation.configure(.init(
                workingSourceItemsHandler: { metrics in
                    firstHandlerStarted.signal()
                    releaseFirstHandler.wait()
                    recorder.record("first:\(metrics.itemCount)")
                }
            ))

            DispatchQueue.global().async {
                AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(.init(
                    transcriptTurnCount: 1,
                    fullTurnCount: 1,
                    itemCount: 1,
                    durationMS: 0
                ))
                firstEmissionFinished.signal()
            }

            guard firstHandlerStarted.wait(timeout: .now() + 5) == .success else {
                releaseFirstHandler.signal()
                _ = firstEmissionFinished.wait(timeout: .now() + 5)
                XCTFail("The first instrumentation handler did not start")
                return
            }
            DispatchQueue.global().async {
                AgentTranscriptDebugInstrumentation.configure(.init(
                    workingSourceItemsHandler: { metrics in
                        recorder.record("second:\(metrics.itemCount)")
                    }
                ))
                reconfigurationFinished.signal()
            }

            let reconfigurationResult = reconfigurationFinished.wait(timeout: .now() + 5)
            if reconfigurationResult != .success {
                releaseFirstHandler.signal()
                _ = firstEmissionFinished.wait(timeout: .now() + 5)
                XCTFail("Configuring instrumentation blocked while an earlier handler was running")
                return
            }

            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(.init(
                transcriptTurnCount: 2,
                fullTurnCount: 2,
                itemCount: 2,
                durationMS: 0
            ))
            AgentTranscriptDebugInstrumentation.reset()
            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(.init(
                transcriptTurnCount: -1,
                fullTurnCount: -1,
                itemCount: -1,
                durationMS: 0
            ))
            releaseFirstHandler.signal()

            XCTAssertEqual(firstEmissionFinished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(Set(recorder.values), Set(["first:1", "second:2"]))
            XCTAssertFalse(AgentTranscriptDebugInstrumentation.isEnabled)
        }

        func testMetricsRemainLazyUntilAHandlerIsConfigured() {
            var evaluationCount = 0

            func metrics() -> AgentTranscriptWorkingSourceItemsMetrics {
                evaluationCount += 1
                return .init(transcriptTurnCount: 1, fullTurnCount: 1, itemCount: 1, durationMS: 0)
            }

            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            AgentTranscriptDebugInstrumentation.configure(.init())
            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            XCTAssertEqual(evaluationCount, 0)

            AgentTranscriptDebugInstrumentation.configure(.init(workingSourceItemsHandler: { _ in }))
            AgentTranscriptDebugInstrumentation.emitWorkingSourceItems(metrics())
            XCTAssertEqual(evaluationCount, 1)
        }
    }

    private final class InstrumentationValueRecorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ value: Value) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }
#endif
