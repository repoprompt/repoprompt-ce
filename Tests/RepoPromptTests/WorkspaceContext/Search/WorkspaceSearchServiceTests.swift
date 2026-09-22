@testable import RepoPromptApp
import XCTest

final class WorkspaceSearchServiceTests: XCTestCase {
    func testHeldRootLoadEventMakesOldReadyIndexStaleFromStoreGeneration() async throws {
        let rootA = try makeTemporaryRoot(name: "HeldCatalogEventRootA")
        let rootB = try makeTemporaryRoot(name: "HeldCatalogEventRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.indexedGeneration, snapshotA.generation)
        XCTAssertEqual(result.snapshotGeneration, snapshotA.generation)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })
    }

    func testReleasingRootLoadEventConvergesToReadyNonStaleIndex() async throws {
        let rootA = try makeTemporaryRoot(name: "ReleasedCatalogEventRootA")
        let rootB = try makeTemporaryRoot(name: "ReleasedCatalogEventRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == currentGeneration else { return }
            await commitSignal.signal()
        }
        await eventGate.open()
        await commitSignal.wait()

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, currentGeneration)
        XCTAssertEqual(result.snapshotGeneration, currentGeneration)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(Set(result.results.map(\.rootID)), [recordA.id, recordB.id])
    }

    func testManagedOnlyMaterializationConvergesFreshnessWithoutBecomingSearchable() async throws {
        let root = try makeTemporaryRoot(name: "ManagedOnlySearchFreshness")
        let visibleURL = root.appendingPathComponent("Sources/VisibleTarget.swift")
        let ignoredURL = root.appendingPathComponent("HiddenIgnoredTarget.ignored")
        let secondIgnoredURL = root.appendingPathComponent("SecondHiddenTarget.ignored")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        try write("visible", to: visibleURL)
        try write("hidden", to: ignoredURL)
        try write("second hidden", to: secondIgnoredURL)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        var initialSnapshot: WorkspaceSearchCatalogSnapshot? = await store.searchCatalogSnapshot(
            rootScope: .visibleWorkspace
        )
        let initialGeneration = try XCTUnwrap(initialSnapshot).generation
        XCTAssertFalse(try XCTUnwrap(initialSnapshot).files.contains { $0.standardizedFullPath == ignoredURL.path })
        let initialStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let initialRootShard = try XCTUnwrap(
            initialStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        let appliedIndexStream = await store.appliedIndexEvents()
        var appliedIndexIterator = appliedIndexStream.makeAsyncIterator()

        let service = WorkspaceSearchService()
        let generationCommitted = expectation(description: "projection-neutral catalog generation committed")
        let neutralEventGate = TestAsyncGate()
        let finalRebuildCommitted = TestAsyncSignal()
        addTeardownBlock {
            await service.setProjectionNeutralGenerationDidCommitHandler(nil)
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await neutralEventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        try await service.rebuildIndex(from: XCTUnwrap(initialSnapshot))
        initialSnapshot = nil
        let initialSearchWork = await service.workDiagnosticsSnapshot()
        await service.setProjectionNeutralGenerationDidCommitHandler { _ in
            generationCommitted.fulfill()
        }

        let materialization = try await store.materializeExplicitlyRequestedFile(
            ignoredURL.path,
            rootScope: .visibleWorkspace
        )
        guard case let .materialized(file) = materialization else {
            return XCTFail("Expected ignored file to materialize as a managed-only record")
        }
        XCTAssertEqual(file.standardizedFullPath, ignoredURL.path)
        let materializedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(materializedGeneration, initialGeneration)

        await fulfillment(of: [generationCommitted], timeout: 2)
        await service.setProjectionNeutralGenerationDidCommitHandler(nil)

        let visibleResult = await service.search("VisibleTarget", limit: 10)
        XCTAssertTrue(visibleResult.isIndexReady)
        XCTAssertFalse(visibleResult.isStale)
        XCTAssertEqual(visibleResult.indexedGeneration, materializedGeneration)
        XCTAssertEqual(visibleResult.snapshotGeneration, materializedGeneration)
        XCTAssertNil(visibleResult.pendingGeneration)
        XCTAssertEqual(visibleResult.observedGeneration, materializedGeneration)
        XCTAssertEqual(visibleResult.results.map(\.standardizedFullPath), [visibleURL.path])

        let ignoredResult = await service.search("HiddenIgnoredTarget", limit: 10)
        XCTAssertTrue(ignoredResult.isIndexReady)
        XCTAssertFalse(ignoredResult.isStale)
        XCTAssertEqual(ignoredResult.indexedGeneration, materializedGeneration)
        XCTAssertTrue(ignoredResult.results.isEmpty)
        let searchDiagnostics = await service.diagnostics
        XCTAssertEqual(searchDiagnostics?.generation, materializedGeneration)

        let finalSearchWork = await service.workDiagnosticsSnapshot()
        XCTAssertEqual(finalSearchWork.rebuildCount, initialSearchWork.rebuildCount)
        let finalStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let finalRootShard = try XCTUnwrap(
            finalStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        XCTAssertEqual(finalRootShard.buildCount, initialRootShard.buildCount)
        XCTAssertEqual(finalRootShard.authoritativeRebuildCount, initialRootShard.authoritativeRebuildCount)
        XCTAssertEqual(finalRootShard.lastAppliedIndexGeneration, initialRootShard.lastAppliedIndexGeneration)
        XCTAssertEqual(
            finalRootShard.fallbackReasonCounts[.fullResync, default: 0],
            initialRootShard.fallbackReasonCounts[.fullResync, default: 0]
        )

        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .generationAdvancedWithoutProjectionChange else { return }
            await neutralEventGate.wait()
        }
        let secondMaterialization = try await store.materializeExplicitlyRequestedFile(
            secondIgnoredURL.path,
            rootScope: .visibleWorkspace
        )
        guard case .materialized = secondMaterialization else {
            return XCTFail("Expected second ignored file to materialize as a managed-only record")
        }
        await neutralEventGate.waitUntilEntered()

        let sentinelRelativePath = "AppliedIndexSentinel.swift"
        try write("sentinel", to: root.appendingPathComponent(sentinelRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: rootRecord.id,
            deltas: [.fileAdded(sentinelRelativePath)]
        )
        let finalGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == finalGeneration else { return }
            await finalRebuildCommitted.signal()
        }

        let firstAppliedIndexValue = await appliedIndexIterator.next()
        let firstAppliedIndexEvent = try XCTUnwrap(firstAppliedIndexValue)
        XCTAssertFalse(firstAppliedIndexEvent.requiresFullResync)
        XCTAssertEqual(
            firstAppliedIndexEvent.upsertedFiles.map(\.standardizedRelativePath),
            [sentinelRelativePath]
        )

        await neutralEventGate.open()
        await finalRebuildCommitted.wait()

        let sentinelResult = await service.search("AppliedIndexSentinel", limit: 10)
        XCTAssertTrue(sentinelResult.isIndexReady)
        XCTAssertFalse(sentinelResult.isStale)
        XCTAssertEqual(sentinelResult.indexedGeneration, finalGeneration)
        XCTAssertEqual(sentinelResult.results.map(\.standardizedRelativePath), [sentinelRelativePath])
        let secondIgnoredResult = await service.search("SecondHiddenTarget", limit: 10)
        XCTAssertTrue(secondIgnoredResult.results.isEmpty)

        let postAppliedStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let postAppliedRootShard = try XCTUnwrap(
            postAppliedStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        XCTAssertEqual(postAppliedRootShard.buildCount, finalRootShard.buildCount + 1)
        XCTAssertEqual(postAppliedRootShard.patchCount, finalRootShard.patchCount + 1)
        XCTAssertEqual(postAppliedRootShard.authoritativeRebuildCount, finalRootShard.authoritativeRebuildCount)
        XCTAssertEqual(postAppliedRootShard.fallbackCount, finalRootShard.fallbackCount)
        XCTAssertEqual(postAppliedRootShard.fallbackReasonCounts, finalRootShard.fallbackReasonCounts)
        XCTAssertEqual(postAppliedRootShard.lastAppliedIndexGeneration, firstAppliedIndexEvent.generation)
        XCTAssertFalse(postAppliedRootShard.deltaStateDirty)
    }

    func testRemovedRootCannotBeResurrectedByDelayedLoadRefresh() async throws {
        let rootA = try makeTemporaryRoot(name: "DelayedLoadRemovalRootA")
        let rootB = try makeTemporaryRoot(name: "DelayedLoadRemovalRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        await store.unloadRoot(id: recordB.id)
        let finalGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == finalGeneration else { return }
            await commitSignal.signal()
        }
        await eventGate.open()
        await commitSignal.wait()

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, finalGeneration)
        XCTAssertEqual(result.snapshotGeneration, finalGeneration)
        XCTAssertEqual(result.observedGeneration, finalGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedPathCount, 1)
    }

    func testExpiredRootLifetimeCannotCommitAfterSamePathReload() async throws {
        let root = try makeTemporaryRoot(name: "ExpiredLifetimeReloadRoot")
        let oldOnlyFile = root.appendingPathComponent("Sources/OldOnly.swift")
        let refreshTriggerFile = root.appendingPathComponent("Sources/RefreshTrigger.swift")
        try write("old", to: oldOnlyFile)

        let store = WorkspaceFileContextStore()
        let oldRoot = try await store.loadRoot(path: root.path)
        let oldSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let oldFileIDs = Set(oldSnapshot.entries.map(\.id))
        let service = WorkspaceSearchService()
        let triggerEventGate = TestAsyncGate()
        let staleRebuildGate = TestAsyncGate()
        let unloadEventGate = TestAsyncGate()
        let reloadEventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidStartHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await triggerEventGate.open()
            await staleRebuildGate.open()
            await unloadEventGate.open()
            await reloadEventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: oldSnapshot)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .appliedIndex, event.rootID == oldRoot.id else { return }
            await triggerEventGate.wait()
        }

        try write("trigger", to: refreshTriggerFile)
        await store.replayObservedFileSystemDeltas(
            rootID: oldRoot.id,
            deltas: [.fileAdded("Sources/RefreshTrigger.swift")]
        )
        await triggerEventGate.waitUntilEntered()
        let staleGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidStartHandler { generation in
            guard generation == staleGeneration else { return }
            await staleRebuildGate.wait()
        }
        await triggerEventGate.open()
        await staleRebuildGate.waitUntilEntered()

        await service.setCatalogChangeWillHandleHandler { event in
            if event.kind == .rootUnloaded, event.rootID == oldRoot.id {
                await unloadEventGate.wait()
            } else if event.kind == .rootLoaded, event.rootPath == root.path {
                await reloadEventGate.wait()
            }
        }
        await store.unloadRoot(id: oldRoot.id)
        await unloadEventGate.waitUntilEntered()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        try write("new", to: root.appendingPathComponent("Sources/NewOnly.swift"))
        let newRoot = try await store.loadRoot(path: root.path)
        let newGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == newGeneration else { return }
            await commitSignal.signal()
        }

        await staleRebuildGate.open()
        await commitSignal.wait()
        await unloadEventGate.open()
        await reloadEventGate.waitUntilEntered()

        let result = await service.search("Only", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, newGeneration)
        XCTAssertEqual(result.snapshotGeneration, newGeneration)
        XCTAssertEqual(result.observedGeneration, newGeneration)
        XCTAssertNotEqual(newRoot.id, oldRoot.id)
        XCTAssertEqual(result.results.map(\.rootID), [newRoot.id])
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["Sources/NewOnly.swift"])
        XCTAssertTrue(Set(result.results.map(\.id)).isDisjoint(with: oldFileIDs))
        XCTAssertFalse(result.results.contains { $0.standardizedRelativePath == "Sources/OldOnly.swift" })
    }

    func testVisibleWorkspaceFreshnessIgnoresOutOfScopeRootTopology() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "VisibleScopePrimaryRoot")
        let gitDataRoot = try makeTemporaryRoot(name: "VisibleScopeGitDataRoot")
        let sessionRoot = try makeTemporaryRoot(name: "VisibleScopeSessionRoot")
        let supplementalRoot = try makeTemporaryRoot(name: "VisibleScopeSupplementalRoot")
        let barrierRoot = try makeTemporaryRoot(name: "VisibleScopeBarrierRoot")
        try write("visible", to: visibleRoot.appendingPathComponent("Sources/VisibleScopeTarget.swift"))
        try write("git", to: gitDataRoot.appendingPathComponent("GitScopeTarget.swift"))
        try write("session", to: sessionRoot.appendingPathComponent("SessionScopeTarget.swift"))
        try write("supplemental", to: supplementalRoot.appendingPathComponent("SupplementalScopeTarget.swift"))
        try write("barrier", to: barrierRoot.appendingPathComponent("BarrierScopeTarget.swift"))

        let store = WorkspaceFileContextStore()
        let visibleRecord = try await store.loadRoot(path: visibleRoot.path)
        let visibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let barrierGate = TestAsyncGate()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await barrierGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: visibleSnapshot)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == barrierRoot.path else { return }
            await barrierGate.wait()
        }

        let gitDataRecord = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let sessionRecord = try await store.loadRoot(path: sessionRoot.path, kind: .sessionWorktree)
        let supplementalRecord = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)
        let barrierRecord = try await store.loadRoot(path: barrierRoot.path, kind: .supplementalSystem)
        await barrierGate.waitUntilEntered()

        let visibleGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let result = await service.search("ScopeTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(visibleGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.indexedGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.snapshotGeneration, visibleSnapshot.generation)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.results.map(\.rootID), [visibleRecord.id])
        let excludedRootIDs = Set([
            gitDataRecord.id,
            sessionRecord.id,
            supplementalRecord.id,
            barrierRecord.id
        ])
        XCTAssertTrue(Set(result.results.map(\.rootID)).isDisjoint(with: excludedRootIDs))
    }

    func testSearchCatalogChangeEventsFollowCatalogAuthorityChanges() async throws {
        let rootA = try makeTemporaryRoot(name: "CatalogChangeRootA")
        let rootB = try makeTemporaryRoot(name: "CatalogChangeRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/Beta.swift"))

        let store = WorkspaceFileContextStore()
        let stream = await store.searchCatalogChangeEvents()
        var iterator = stream.makeAsyncIterator()

        let recordA = try await store.loadRoot(path: rootA.path)
        let loadedAValue = await iterator.next()
        let loadedA = try XCTUnwrap(loadedAValue)
        XCTAssertEqual(loadedA.kind, .rootLoaded)
        XCTAssertEqual(loadedA.rootID, recordA.id)
        XCTAssertEqual(loadedA.rootPath, recordA.standardizedFullPath)
        XCTAssertNotNil(loadedA.rootLifetimeID)
        XCTAssertEqual(loadedA.rootAppliedIndexGeneration, 0)

        try write("delta", to: rootA.appendingPathComponent("Sources/Delta.swift"))
        await store.replayObservedFileSystemDeltas(
            rootID: recordA.id,
            deltas: [.fileAdded("Sources/Delta.swift")]
        )
        let appliedValue = await iterator.next()
        let applied = try XCTUnwrap(appliedValue)
        XCTAssertEqual(applied.kind, .appliedIndex)
        XCTAssertEqual(applied.rootID, recordA.id)
        XCTAssertEqual(applied.rootLifetimeID, loadedA.rootLifetimeID)
        XCTAssertEqual(applied.rootAppliedIndexGeneration, 1)

        await store.unloadRoot(id: recordA.id)
        let unloadedAValue = await iterator.next()
        let unloadedA = try XCTUnwrap(unloadedAValue)
        XCTAssertEqual(unloadedA.kind, .rootUnloaded)
        XCTAssertEqual(unloadedA.rootID, recordA.id)
        XCTAssertEqual(unloadedA.rootLifetimeID, loadedA.rootLifetimeID)

        let recordB = try await store.loadRoot(path: rootB.path)
        let loadedBValue = await iterator.next()
        let loadedB = try XCTUnwrap(loadedBValue)
        XCTAssertEqual(loadedB.kind, .rootLoaded)
        XCTAssertEqual(loadedB.rootID, recordB.id)
    }

    func testCanceledRootLoadPublishesNoRootLoadedEvent() async throws {
        let canceledRoot = try makeTemporaryRoot(name: "CanceledCatalogChangeRoot")
        let sentinelRoot = try makeTemporaryRoot(name: "CatalogChangeSentinelRoot")
        try write("canceled", to: canceledRoot.appendingPathComponent("Sources/Canceled.swift"))
        try write("sentinel", to: sentinelRoot.appendingPathComponent("Sources/Sentinel.swift"))

        let store = WorkspaceFileContextStore()
        let stream = await store.searchCatalogChangeEvents()
        var iterator = stream.makeAsyncIterator()
        let loadGate = TestAsyncGate()
        let loadEntered = expectation(description: "root load entered")
        await store.setRootLoadWillStartHandler { _ in
            loadEntered.fulfill()
            await loadGate.wait()
        }

        let loadTask = Task {
            try await store.loadRoot(
                path: canceledRoot.path,
                cancelUnderlyingLoadOnCallerCancellation: true
            )
        }
        await fulfillment(of: [loadEntered], timeout: 2)
        loadTask.cancel()
        await store.cancelRootLoad(path: canceledRoot.path)
        await loadGate.open()
        do {
            _ = try await loadTask.value
            XCTFail("Expected the root load to be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await store.setRootLoadWillStartHandler(nil)

        let sentinel = try await store.loadRoot(path: sentinelRoot.path)
        let firstEventValue = await iterator.next()
        let firstEvent = try XCTUnwrap(firstEventValue)
        XCTAssertEqual(firstEvent.kind, .rootLoaded)
        XCTAssertEqual(firstEvent.rootID, sentinel.id)
    }

    func testStoppedFreshnessBindingMarksOldReadyIndexStaleAtQueryTime() async throws {
        let rootA = try makeTemporaryRoot(name: "StoppedFreshnessRootA")
        let rootB = try makeTemporaryRoot(name: "StoppedFreshnessRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.stopKeepingFresh()

        let recordB = try await store.loadRoot(path: rootB.path)
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(currentGeneration, snapshotA.generation)

        let result = await service.search("Target", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.indexedGeneration, snapshotA.generation)
        XCTAssertEqual(result.snapshotGeneration, snapshotA.generation)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })

        let zeroLimitResult = await service.search("Target", limit: 0)
        XCTAssertTrue(zeroLimitResult.isIndexReady)
        XCTAssertTrue(zeroLimitResult.isStale)
        XCTAssertEqual(zeroLimitResult.observedGeneration, currentGeneration)
        XCTAssertTrue(zeroLimitResult.results.isEmpty)
    }

    func testManualRebuildReconcilesNewerBoundCatalogDemand() async throws {
        let rootA = try makeTemporaryRoot(name: "ManualRebuildRootA")
        let rootB = try makeTemporaryRoot(name: "ManualRebuildRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/Beta.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        await service.startKeepingFresh(
            with: store,
            rootScope: .visibleWorkspace,
            debounceNanoseconds: 10_000_000_000
        )
        await service.rebuildIndex(from: snapshotA)

        _ = try await store.loadRoot(path: rootB.path)
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)

        let indexedGeneration = await service.indexedGeneration
        let pendingGeneration = await service.pendingGeneration
        XCTAssertTrue(
            indexedGeneration == currentGeneration || pendingGeneration == currentGeneration,
            "The stale manual snapshot must not erase demand for the authoritative generation"
        )
        await service.stopKeepingFresh()
    }

    func testWorkspaceSearchServiceSearchesSingleRootCatalog() async throws {
        let root = try makeTemporaryRoot(name: "SingleRootSearch")
        try write("view model", to: root.appendingPathComponent("Sources/App/Search/SearchViewModel.swift"))
        try write("tests", to: root.appendingPathComponent("Tests/SearchViewModelTests.swift"))
        try write("readme", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        let service = WorkspaceSearchService()
        let indexedGeneration = await service.rebuildIndex(from: snapshot)
        let serviceIndexedGeneration = await service.indexedGeneration
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedGeneration, snapshot.generation)
        XCTAssertEqual(serviceIndexedGeneration, snapshot.generation)
        XCTAssertEqual(indexedPathCount, 3)

        let filenameResult = await service.search("SearchViewModel", limit: 10)
        XCTAssertTrue(filenameResult.isIndexReady)
        XCTAssertEqual(filenameResult.indexedGeneration, snapshot.generation)
        XCTAssertEqual(Set(filenameResult.results.map(\.standardizedRelativePath)), [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathResult = await service.search("App SearchViewModel", limit: 10)
        XCTAssertEqual(subpathResult.results.map(\.standardizedRelativePath), ["Sources/App/Search/SearchViewModel.swift"])
    }

    func testWorkspaceSearchServiceSearchesMultiRootCatalog() async throws {
        let rootA = try makeTemporaryRoot(name: "AlphaRootSearch")
        let rootB = try makeTemporaryRoot(name: "BetaRootSearch")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("shared alpha", to: rootA.appendingPathComponent("Shared/SharedTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))
        try write("shared beta", to: rootB.appendingPathComponent("Shared/SharedTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.diagnostics.rootCount, 2)
        XCTAssertEqual(snapshot.diagnostics.fileCount, 4)

        let service = WorkspaceSearchService()
        await service.prepareIndex(from: snapshot)

        let sharedResult = await service.search("SharedTarget", limit: 10)
        XCTAssertEqual(Set(sharedResult.results.map(\.rootID)), [recordA.id, recordB.id])
        XCTAssertEqual(sharedResult.results.count(where: { $0.standardizedRelativePath == "Shared/SharedTarget.swift" }), 2)

        let rootQualifiedResult = await service.search("\(rootB.lastPathComponent) BetaTarget", limit: 10)
        XCTAssertEqual(rootQualifiedResult.results.map(\.rootID), [recordB.id])
        XCTAssertEqual(rootQualifiedResult.results.map(\.standardizedRelativePath), ["Sources/BetaTarget.swift"])
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor TestAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TestAsyncGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                openContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }
}
