import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptPersistence
@testable import RepoPromptWorkspaceContext
@testable import RepoPromptWorkspaceContextTestSupport
import XCTest

/// Regression coverage for #1082: graph-index publication and graph commits must scale with the
/// published batch, not with the resident graph, while producing the same deterministic graph.
final class WorkspaceCodemapGraphIncrementalIndexTests: XCTestCase {
    // MARK: - Live layer

    func testPathScopedReconcileWorkIsIndependentOfLiveLayerSize() async throws {
        let liveCount = 384
        let repository = try ReviewGitRepositoryFixture(name: #function)
        var repositoryFiles: [String: String] = [:]
        for index in 0 ..< liveCount {
            repositoryFiles["Live/File\(index).swift"] = "struct Live\(index) {}\n"
        }
        let rootURL = try repository.makeRepository(named: "root", files: repositoryFiles)
        addTeardownBlock { repository.cleanup() }
        let service = WorkspaceCodemapRootCapabilityService(
            namespaceSalt: Data(repeating: 0x6C, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: .none
        )
        let request = WorkspaceCodemapRootCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL
        )
        guard case let .eligible(rootCapability) = await service.resolve(root: request),
              case let .git(capability) = rootCapability
        else {
            return XCTFail("The fixture repository must be Git codemap eligible")
        }

        var maximumVisits: [WorkspaceCodemapGraphReconcileMode: [Int: UInt64]] = [:]
        var checkpoints: [WorkspaceCodemapGraphCheckpointDisposition] = []
        for mode in [WorkspaceCodemapGraphReconcileMode.incremental, .alwaysFull] {
            for seededLiveCount in [0, liveCount] {
                let overlay = WorkspaceCodemapLiveOverlay(graphReconcileMode: mode)
                let harness = try await CodemapGraphIndexHarness(
                    seed: 0x91,
                    overlay: overlay,
                    capability: capability
                )
                let livePaths = (0 ..< seededLiveCount).map { "Live/File\($0).swift" }
                let authorities = await service.makeSourceAuthorities(
                    capability: rootCapability,
                    observedRootEpoch: capability.rootEpoch,
                    observedRootAuthority: rootCapability.rootAuthority,
                    candidates: livePaths.map {
                        WorkspaceCodemapSourceAuthorityRequest(
                            candidateRootRelativePath: $0,
                            observedPathGeneration: 1,
                            currentPathGeneration: 1,
                            observedIngressGeneration: 1,
                            currentIngressGeneration: 1
                        )
                    }
                )
                let locator = try GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: capability.repositoryNamespace,
                    objectFormat: capability.objectFormat,
                    blobOID: String(repeating: "a", count: 40),
                    pipelineIdentity: harness.pipeline
                )
                for (index, path) in livePaths.enumerated() {
                    let identity = try harness.makeIdentity(fileID: harness.fileID(index, lane: 0x50), path: path)
                    let authority = try XCTUnwrap(authorities[index])
                    let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.cleanGitBlob(
                        bindingIdentity: identity,
                        locatorIdentity: locator,
                        sourceAuthority: authority
                    ))
                    let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
                        identity: identity,
                        requestGeneration: 1,
                        catalogGeneration: 3,
                        sourceExpectation: expectation
                    ))
                    guard case .started = await overlay.beginDemand(owner: WorkspaceCodemapLiveDemandOwner(), token: token) else {
                        return XCTFail("Live demand \(path) did not start")
                    }
                }
                let seeded = try await harness.ledger()
                XCTAssertTrue(seeded.liveEntriesIndexedByPath)
                XCTAssertEqual(seeded.slotCount, seededLiveCount)

                // Index slots for 64 of the live paths (same file IDs: live state wins) and for
                // unrelated paths, in batches.
                let overlapping = try (0 ..< min(64, seededLiveCount)).map { index in
                    try harness.makeSlot(
                        fileID: harness.fileID(index, lane: 0x50),
                        path: "Live/File\(index).swift",
                        definitions: ["Live\(index)"],
                        references: ["Type0"]
                    )
                }
                let files = try harness.makeFiles(count: 1024)
                var visits: [UInt64] = []
                for start in stride(from: 0, to: files.count, by: 64) {
                    let published = await harness.publish(
                        files[start ..< start + 64].map(\.contributed),
                        projectedTotal: UInt64(files.count + seededLiveCount)
                    )
                    XCTAssertTrue(published)
                    let ledger = try await harness.ledger()
                    visits.append(ledger.lastReconcileVisitCount)
                }
                if !overlapping.isEmpty {
                    let published = await harness.publish(
                        overlapping,
                        projectedTotal: UInt64(files.count + seededLiveCount)
                    )
                    XCTAssertTrue(published)
                }
                maximumVisits[mode, default: [:]][seededLiveCount] = visits.max() ?? 0
                if seededLiveCount == liveCount {
                    let checkpoint = await overlay.graphCheckpoint(rootEpoch: harness.rootEpoch)
                    checkpoints.append(checkpoint)
                    let ledger = try await harness.ledger()
                    if mode == .incremental {
                        XCTAssertEqual(ledger.incrementalFallbackCount, 0)
                    }
                }
            }
        }
        // Path-scoped reconciliation resolves live state through the path index: its work does
        // not depend on how many live entries exist. Full reconciliation walks every layer.
        let incremental = try XCTUnwrap(maximumVisits[.incremental])
        XCTAssertEqual(incremental[0], incremental[liveCount])
        XCTAssertLessThanOrEqual(incremental[liveCount] ?? .max, 8 * 64)
        let full = try XCTUnwrap(maximumVisits[.alwaysFull])
        XCTAssertGreaterThan(full[liveCount] ?? 0, full[0] ?? 0)
        // Live precedence is identical in both modes.
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints.first, checkpoints.last)
    }

    // MARK: - Engine diagnostics and warm relaunch

    func testGraphIndexReportsBatchTimingAndWarmRelaunchReusesArtifacts() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First { let second: Second }\n",
                "Sources/Second.swift": "struct Second {}\n",
                "Sources/Third.swift": "struct Third { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }

        let firstLoad = try await store.loadRoot(path: rootURL.path)
        let engine = try fixture.runtime().bindingEngine()
        let firstRun = try await waitForGraphCompletion(engine: engine, rootID: firstLoad.id)
        XCTAssertGreaterThan(firstRun.batchTiming.batchCount, 0)
        XCTAssertGreaterThanOrEqual(firstRun.batchTiming.publishedSlotCount, 3)
        XCTAssertGreaterThan(firstRun.batchTiming.totalBatchDurationNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(
            firstRun.batchTiming.totalBatchDurationNanoseconds,
            firstRun.batchTiming.maximumBatchDurationNanoseconds
        )
        let afterFirst = await engine.accounting()
        XCTAssertGreaterThanOrEqual(afterFirst.counters.graphIndexPublishedSlots, 3)
        XCTAssertGreaterThan(afterFirst.counters.graphIndexBatchNanoseconds, 0)
        let buildsAfterFirst = fixture.builtSourceTexts.values.count
        XCTAssertGreaterThan(buildsAfterFirst, 0)

        // A warm relaunch of the unchanged root rebuilds the in-memory graph from durable
        // artifacts; it must not parse any source again.
        await store.unloadRoot(id: firstLoad.id)
        let secondLoad = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: secondLoad.id) }
        let secondRun = try await waitForGraphCompletion(
            engine: engine,
            rootID: secondLoad.id,
            excluding: firstRun.rootEpoch
        )
        XCTAssertEqual(secondRun.progress.counts.processedCandidateCount, 3)
        XCTAssertEqual(fixture.builtSourceTexts.values.count, buildsAfterFirst)
        let afterSecond = await engine.accounting()
        XCTAssertEqual(
            afterSecond.counters.graphIndexArtifactBuildsStarted,
            afterFirst.counters.graphIndexArtifactBuildsStarted
        )
    }

    /// Completion is observable: once the engine reports a root complete, the selection graph must
    /// already expose full coverage, even while the pull loop is paused between commits (#1085).
    func testGraphIndexCompletionImpliesGraphCoverageWhilePullLoopIsPaused() async throws {
        let fileCount = 6
        var sources: [String: String] = [:]
        for index in 0 ..< fileCount {
            sources["Sources/File\(index).swift"] = "struct File\(index) { let next: File\((index + 1) % fileCount) }\n"
        }
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(named: "root", files: sources)
        // The gate never opens on its own: a pause ends only through a flush or cancellation.
        let gate = CodemapGraphIndexGate()
        await gate.close()
        let pauses = CodemapLockedValues<UInt64>()
        let fixture = try CodemapStoreFixture(
            name: #function,
            enginePolicy: WorkspaceCodemapBindingEnginePolicy(
                maximumGraphIndexCatalogPageEntryCount: 1,
                maximumGraphIndexBatchCandidateCount: 1
            ),
            graphPullPause: WorkspaceCodemapGraphPullPause { applyNanoseconds in
                pauses.append(applyNanoseconds)
                await gate.pass()
            }
        )
        let store = fixture.makeStore()
        addTeardownBlock {
            await gate.open()
            await fixture.shutdown()
            repository.cleanup()
        }

        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: loaded.id) }
        let engine = try fixture.runtime().bindingEngine()
        let rootEpoch = try await waitForGraphIndexRoot(engine: engine, rootID: loaded.id)

        // Hold further pages until the pull loop has committed and entered the gated pause, so
        // the completing publication provably arrives while the loop is paused.
        let hold = await engine.debugAcquireGraphIndexAdmissionHold(
            rootEpoch: rootEpoch,
            expiresAfterMilliseconds: 600_000
        )
        let holdID = try XCTUnwrap(hold?.holdID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while pauses.values.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(pauses.values.isEmpty, "The pull loop must be paused before indexing completes")
        let completedBeforePause = await engine.accounting().graphIndexRoots
            .first { $0.rootEpoch == rootEpoch }?.phase == .complete
        XCTAssertFalse(completedBeforePause, "The admission hold must keep indexing incomplete")
        _ = await engine.debugReleaseGraphIndexAdmissionHold(holdID, rootEpoch: rootEpoch)

        let completed = try await waitForGraphCompletion(engine: engine, rootID: loaded.id)
        XCTAssertEqual(completed.progress.counts.processedCandidateCount, UInt64(fileCount))
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        guard case let .ready(pinned) = await graph.latestSnapshot() else {
            return XCTFail("A completed root must publish a graph snapshot")
        }
        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(pinned.snapshot.nodesByFileID.count, fileCount)
    }

    // MARK: - Helpers

    private func waitForGraphIndexRoot(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID
    ) async throws -> WorkspaceCodemapRootEpoch {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: { $0.rootEpoch.rootID == rootID }) {
                return root.rootEpoch
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CodemapGraphIndexHarnessError.timedOut
    }

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID,
        excluding excludedRootEpoch: WorkspaceCodemapRootEpoch? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: {
                $0.rootEpoch.rootID == rootID && $0.rootEpoch != excludedRootEpoch
            }),
                root.phase == .complete
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CodemapGraphIndexHarnessError.timedOut
    }
}
