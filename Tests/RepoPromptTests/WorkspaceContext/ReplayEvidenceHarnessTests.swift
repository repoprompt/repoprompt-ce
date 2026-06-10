@testable import RepoPrompt
import XCTest

#if DEBUG
    final class ReplayEvidenceHarnessTests: XCTestCase {
        @MainActor
        func testFocusedLargeBurstRoutesImmediateWithCappedDefaultChunks() async {
            let rootKey = makeRootFolder(name: "ImmediateRoute").standardizedFullPath
            let buffer = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 10000)
            let rootGeneration: UInt64 = 1
            await buffer.registerActiveRootGeneration(rootGeneration, forRootKey: rootKey)
            await buffer.updateRoutingState(
                isWindowFocused: true,
                isReplayActive: false,
                routingVersion: 1
            )

            let deltas = (0 ..< 600).map { FileSystemDelta.fileAdded("file-\($0).swift") }
            let ingress = await buffer.ingestLiveDeltas(
                deltas,
                forRootKey: rootKey,
                rootGeneration: rootGeneration
            )
            let immediate: PreparedImmediateReplay
            switch ingress {
            case let .preparedImmediate(prepared):
                immediate = prepared
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

        @MainActor
        func testUnfocusedBurstQueuesAndDeferredDrainUsesConfiguredChunks() async {
            let root = makeRootFolder(name: "DeferredRoute")
            let vm = WorkspaceFilesViewModel()
            vm.registerRootFolderForTesting(root)
            _ = await vm.ensureReplayIngressRegistrationForTesting(forRootFolder: root)
            vm.setWindowFocused(false)

            let deltas = (0 ..< 250).map { FileSystemDelta.fileAdded("queued-\($0).swift") }
            await vm.receiveLiveFileSystemDeltasForTesting(deltas, forRootFolder: root)

            var diagnostics = await vm.deferredReplayBufferDiagnosticsForTesting()
            XCTAssertEqual(diagnostics.immediateIngressCount, 0)
            XCTAssertEqual(diagnostics.deferredIngressCount, 1)
            let pendingDeltaCount = await vm.pendingDeltaCountForTesting(forRootFolder: root)
            XCTAssertEqual(pendingDeltaCount, 250)

            vm.resetReplayPerfSamplesForTesting()
            vm.setDeltaReplayTuningForTesting(chunkSize: 100, interChunkDelayNanoseconds: 0)
            vm.setWindowFocused(true)
            await vm.flushPendingDeltas(aggressive: false)
            await vm.waitForDeltaReplayCompletionForTesting()

            diagnostics = await vm.deferredReplayBufferDiagnosticsForTesting()
            let sample = vm.latestDeltaReplayPerfSampleForTesting()
            XCTAssertEqual(diagnostics.preparedDrainCount, 1)
            XCTAssertEqual(sample?.pendingDeltaCountAtStart, 250)
            XCTAssertEqual(sample?.totalCoalescedDeltaCount, 250)
            XCTAssertEqual(sample?.totalChunkCount, 3)
            XCTAssertEqual(sample?.replayedRoots.map(\.chunkDeltaCount), [100, 100, 50])
            XCTAssertEqual(sample?.replayedRoots.reduce(0) { $0 + $1.fileAddedCount }, 250)
        }

        @MainActor
        func testRemovedFolderBurstUsesOneBatchedDescendantLookup() async throws {
            let root = makeRootFolder(name: "RemovedFolders")
            let vm = WorkspaceFilesViewModel()
            vm.registerRootFolderForTesting(root)

            let folderAdds = (0 ..< 60).map { FileSystemDelta.folderAdded("folder-\($0)") }
            await vm.applyFileSystemDeltasForTesting(folderAdds, forRootFolder: root)
            vm.resetReplayPerfSamplesForTesting()

            let folderRemoves = (0 ..< 60).map { FileSystemDelta.folderRemoved("folder-\($0)") }
            await vm.applyFileSystemDeltasForTesting(folderRemoves, forRootFolder: root)

            let sample = vm.latestImmediateReplayPerfSampleForTesting()
            let chunk = try XCTUnwrap(sample?.replayedChunks.first)
            XCTAssertEqual(sample?.queuedDeltaCount, 60)
            XCTAssertEqual(sample?.coalescedDeltaCount, 60)
            XCTAssertEqual(sample?.chunkCount, 1)
            XCTAssertEqual(chunk.folderRemovedCount, 60)
            XCTAssertEqual(chunk.incrementalRemovedFolderCount, 60)
            XCTAssertEqual(chunk.removedSubtreeDescendantLookupCount, 1)
            XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
        }

        @MainActor
        func testRemovedFolderCleanupFlushesBeforeSamePathFileAdd() async throws {
            let root = makeRootFolder(name: "RemovedFolderReplacement")
            let vm = WorkspaceFilesViewModel()
            vm.registerRootFolderForTesting(root)

            await vm.applyFileSystemDeltasForTesting([.folderAdded("replacement")], forRootFolder: root)
            vm.resetReplayPerfSamplesForTesting()

            await vm.applyFileSystemDeltasForTesting([
                .folderRemoved("replacement"),
                .fileAdded("replacement")
            ], forRootFolder: root)

            let sample = vm.latestImmediateReplayPerfSampleForTesting()
            let chunk = try XCTUnwrap(sample?.replayedChunks.first)
            XCTAssertEqual(sample?.queuedDeltaCount, 2)
            XCTAssertEqual(sample?.coalescedDeltaCount, 2)
            XCTAssertEqual(chunk.folderRemovedCount, 1)
            XCTAssertEqual(chunk.fileAddedCount, 1)
            XCTAssertEqual(chunk.removedSubtreeDescendantLookupCount, 1)
            XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
        }

        @MainActor
        private func makeRootFolder(name: String) -> FolderViewModel {
            let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ReplayEvidenceHarnessTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            let rootPath = rootURL.path
            return FolderViewModel(
                folder: Folder(name: rootURL.lastPathComponent, path: rootPath, modificationDate: Date(timeIntervalSince1970: 1000)),
                rootPath: rootPath
            )
        }
    }
#endif
