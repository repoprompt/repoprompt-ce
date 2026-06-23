@testable import RepoPromptCore
import XCTest

#if DEBUG
    final class ReplayEvidenceHarnessTests: XCTestCase {
        func testFocusedLargeBurstRoutesImmediateWithCappedDefaultChunks() async {
            let rootKey = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReplayEvidenceHarnessTests-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL.path
            let buffer = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 10000)
            let rootGeneration: UInt64 = 1
            await buffer.registerActiveRootGeneration(rootGeneration, forRootKey: rootKey)
            await buffer.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 1)

            let deltas = (0 ..< 600).map { FileSystemDelta.fileAdded("file-\($0).swift") }
            let ingress = await buffer.ingestLiveDeltas(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
            let immediate: PreparedImmediateReplay
            switch ingress {
            case let .preparedImmediate(prepared): immediate = prepared
            case .queued, .overflowRequiresRefresh, .droppedWhileOverflowed, .droppedStaleGeneration:
                XCTFail("Expected focused burst to prepare immediate replay work")
                return
            }

            XCTAssertEqual(immediate.rootKey, rootKey)
            XCTAssertEqual(immediate.rootGeneration, rootGeneration)
            XCTAssertEqual(immediate.sourceDeltas.count, 600)
            XCTAssertEqual(immediate.preparedBatch.queuedDeltaCount, 600)
            XCTAssertEqual(immediate.preparedBatch.coalescedDeltaCount, 600)
            XCTAssertEqual(immediate.preparedBatch.preparedDeltas.count, 600)
            XCTAssertEqual(immediate.preparedBatch.chunks.map(\.deltaCount), [100, 100, 100, 100, 100, 100])
            XCTAssertEqual(immediate.preparedBatch.chunks.reduce(0) { $0 + $1.summary.fileAddedCount }, 600)

            var diagnostics = await buffer.diagnosticsSnapshot()
            XCTAssertTrue(diagnostics.immediatePreparedIngressInFlight)
            XCTAssertEqual(diagnostics.immediateIngressCount, 1)
            XCTAssertEqual(diagnostics.deferredIngressCount, 0)
            XCTAssertEqual(diagnostics.pendingDeltaCount, 0)

            await buffer.finishPreparedImmediateIngress(immediate)
            diagnostics = await buffer.diagnosticsSnapshot()
            XCTAssertFalse(diagnostics.immediatePreparedIngressInFlight)
        }
    }
#endif
