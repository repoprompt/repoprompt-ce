@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptInstrumentation
import XCTest

final class WorkspaceRootCatalogAdmissibilityTests: XCTestCase {
    func testCatalogAdmissionPrecedesSearchAdmissionOnlyAfterCatalogCompletion() {
        let workspaceID = UUID()
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: 1,
            rootScope: .visibleWorkspace,
            rootCount: 1,
            folderCount: 0,
            fileCount: 0
        )
        let cases: [(WorkspaceSearchReadinessState, Bool, Bool)] = [
            (.idle, false, false),
            (.activating(workspaceID: workspaceID, generation: 1), false, false),
            (.loadingCatalog(
                workspaceID: workspaceID,
                generation: 1,
                loadedRootCount: 0,
                expectedRootCount: 1,
                failures: []
            ), false, false),
            (.buildingIndexes(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                failures: []
            ), true, false),
            (.ready(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: 1,
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: nil,
                failures: [],
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: nil,
                indexedGeneration: nil,
                failures: [],
                diagnostics: nil
            ), false, true)
        ]

        for (state, expectedCatalog, expectedSearch) in cases {
            XCTAssertEqual(state.isRootCatalogAdmissible, expectedCatalog, "state: \(state)")
            XCTAssertEqual(state.isSearchAdmissible, expectedSearch, "state: \(state)")
        }
    }
}

#if DEBUG
    final class WorkspaceStartupPolicyTests: XCTestCase {
        func testStandaloneAdmissionFollowsPolicyWithOrWithoutRecorder() async throws {
            let originalRecorder = WorkspaceContextStartupInstrumentation.currentRecorder()
            defer { WorkspaceContextStartupInstrumentation.install(originalRecorder) }
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            defer { fixture.cleanup() }

            let enabled = WorktreeStartupFeatureFlags(
                observeDiffSeededWorktreeStartup: true,
                serveDiffSeededWorktreeStartup: true
            )
            let disabled = WorktreeStartupFeatureFlags(
                observeDiffSeededWorktreeStartup: false,
                serveDiffSeededWorktreeStartup: false
            )
            let cases: [(name: String, recorderPresent: Bool, policy: WorktreeStartupFeatureFlags?, admitted: Bool)] = [
                ("default-absent", false, nil, true),
                ("default-present", true, nil, true),
                ("enabled-absent", false, enabled, true),
                ("enabled-present", true, enabled, true),
                ("disabled-absent", false, disabled, false),
                ("disabled-present", true, disabled, false)
            ]

            for testCase in cases {
                WorkspaceContextStartupInstrumentation.install(
                    testCase.recorderPresent ? AppWorkspaceStartupEventRecorder() : nil
                )
                XCTAssertEqual(
                    WorkspaceContextStartupInstrumentation.currentRecorder() != nil,
                    testCase.recorderPresent,
                    testCase.name
                )
                let rootURL = try fixture.makeRepository(
                    named: testCase.name,
                    files: ["Source.swift": "struct PolicyFixture {}\n"]
                )
                let store = if let policy = testCase.policy {
                    WorkspaceFileContextStore(
                        startupFeatureFlags: policy,
                        codemapGraphIndexBuildLaunchPolicyForTesting: .disabled
                    )
                } else {
                    WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
                }
                let root = try await store.loadRoot(path: rootURL.path, kind: .sessionWorktree)
                let result = await store.automaticReusableSnapshotAdmissionResultForTesting(rootID: root.id)
                if testCase.admitted {
                    guard case .some(.admitted) = result else {
                        XCTFail("\(testCase.name): expected admitted automatic observation, got \(String(describing: result))")
                        continue
                    }
                } else {
                    XCTAssertNil(result, "\(testCase.name): disabled policy must skip automatic admission")
                }
                await store.unloadRoot(id: root.id)
            }
        }
    }
#endif

final class WorkspaceContextRootSnapshotTests: XCTestCase {
    func testSnapshotIsSendableRootScopedAndFencedByRootChanges() async throws {
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let store = WorkspaceFileContextStore()
        let first = try await store.loadRoot(path: firstURL.path)
        let firstSnapshot = await store.rootContextSnapshot(scope: .visibleWorkspace)
        let captured = try XCTUnwrap(firstSnapshot)
        assertSendable(captured)
        XCTAssertEqual(captured.rootRefs.map(\.id), [first.id])
        let capturedIsCurrent = await store.isRootContextSnapshotCurrent(captured)
        XCTAssertTrue(capturedIsCurrent)

        let second = try await store.loadRoot(path: secondURL.path)
        let secondSnapshot = await store.rootContextSnapshot(scope: .visibleWorkspace)
        let updated = try XCTUnwrap(secondSnapshot)
        XCTAssertEqual(Set(updated.rootRefs.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(captured.rootRefs.map(\.id), [first.id])
        let oldIsCurrent = await store.isRootContextSnapshotCurrent(captured)
        let updatedIsCurrent = await store.isRootContextSnapshotCurrent(updated)
        XCTAssertFalse(oldIsCurrent)
        XCTAssertTrue(updatedIsCurrent)

        await store.unloadRoot(id: second.id)
        let unloadedIsCurrent = await store.isRootContextSnapshotCurrent(updated)
        XCTAssertFalse(unloadedIsCurrent)
    }

    private func assertSendable(_: some Sendable) {}

    func testPrimaryUnloadAndReloadRevokesDetachedSnapshotLifetime() async throws {
        let url = try makeRoot(fileName: "First.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let first = try await store.loadRoot(path: url.path)
        let snapshotValue = await store.rootContextSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertTrue(snapshot.lifetimeIsCurrent())
        await store.unloadRoot(id: first.id)
        XCTAssertFalse(snapshot.lifetimeIsCurrent())
        let reloaded = try await store.loadRoot(path: url.path)
        XCTAssertNotEqual(first.id, reloaded.id)
        XCTAssertFalse(snapshot.lifetimeIsCurrent())
        let reloadedValue = await store.rootContextSnapshot()
        XCTAssertTrue(try XCTUnwrap(reloadedValue).lifetimeIsCurrent())
    }

    func testStoreTeardownRevokesDetachedSnapshotLifetime() async throws {
        let url = try makeRoot(fileName: "Teardown.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        var store: WorkspaceFileContextStore? = WorkspaceFileContextStore(
            codemapGraphIndexBuildLaunchPolicyForTesting: .disabled
        )
        weak var weakStore = store
        do {
            let (cleanupTasks, continuation) = AsyncStream<Task<Void, Never>>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            defer { continuation.finish() }
            await store?.setRootLoadCleanupTaskDidLaunchHandlerForTesting { continuation.yield($0) }
            _ = try await store?.loadRoot(path: url.path)
            var iterator = cleanupTasks.makeAsyncIterator()
            let cleanupValue = await iterator.next()
            let cleanupTask = try XCTUnwrap(cleanupValue)
            // loadRoot returns independently of its cleanup's temporary strong actor reference.
            await cleanupTask.value
            await store?.setRootLoadCleanupTaskDidLaunchHandlerForTesting(nil)
        }
        let snapshotValue = await store?.rootContextSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertTrue(snapshot.lifetimeIsCurrent())

        store = nil
        XCTAssertNil(weakStore)
        XCTAssertFalse(snapshot.lifetimeIsCurrent())
        XCTAssertEqual(snapshot.catalog.files.map(\.name), ["Teardown.swift"])
    }

    func testUnrelatedSessionWorktreeChurnDoesNotRevokePrimarySnapshot() async throws {
        let primaryURL = try makeRoot(fileName: "Primary.swift")
        let sessionURL = try makeRoot(fileName: "Session.swift")
        defer {
            try? FileManager.default.removeItem(at: primaryURL)
            try? FileManager.default.removeItem(at: sessionURL)
        }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: primaryURL.path)
        let snapshotValue = await store.rootContextSnapshot(scope: .visibleWorkspace)
        let snapshot = try XCTUnwrap(snapshotValue)
        let session = try await store.loadRoot(path: sessionURL.path, kind: .sessionWorktree)
        XCTAssertTrue(snapshot.lifetimeIsCurrent())
        await store.unloadRoot(id: session.id)
        XCTAssertTrue(snapshot.lifetimeIsCurrent())
    }

    func testReplacingCapturedRootLifetimeRevokesDetachedSnapshot() async throws {
        let url = try makeRoot(fileName: "Replacement.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: url.path)
        let snapshotValue = await store.rootContextSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        try await store.replaceRootLifetimeForTesting(rootID: root.id)
        XCTAssertFalse(snapshot.lifetimeIsCurrent())
    }

    func testColdRootCaptureProvidesCompleteCatalogRead() async throws {
        let url = try makeRoot(fileName: "Cold.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: url.path)
        let snapshotValue = await store.rootContextSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.catalog.roots.map(\.id), [root.id])
        XCTAssertEqual(snapshot.catalog.files.map(\.name), ["Cold.swift"])
        XCTAssertEqual(snapshot.catalog.rootPathIndexes.map(\.identity.rootID), [root.id])
    }

    func testEvictedCatalogShardIsRebuiltBeforeCapture() async throws {
        let url = try makeRoot(fileName: "Evicted.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: url.path)
        let initialValue = await store.rootContextSnapshot()
        _ = try XCTUnwrap(initialValue)
        await store.evictPublishedRootCatalogShardForTesting(rootID: root.id)
        let snapshotValue = await store.rootContextSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.catalog.files.map(\.name), ["Evicted.swift"])
        XCTAssertEqual(snapshot.catalog.rootPathIndexes[0].identity.topologyGeneration, snapshot.roots[0].catalogGeneration)
    }

    func testGenerationAdvanceRetagsCatalogAndPreservesOldRead() async throws {
        let url = try makeRoot(fileName: "Generation.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: url.path)
        let oldValue = await store.rootContextSnapshot()
        let old = try XCTUnwrap(oldValue)
        await store.advanceRootCatalogGenerationWithoutRetagForTesting(rootID: root.id)
        let currentValue = await store.rootContextSnapshot()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.roots[0].catalogGeneration, old.roots[0].catalogGeneration + 1)
        XCTAssertEqual(current.catalog.rootPathIndexes[0].identity.topologyGeneration, current.roots[0].catalogGeneration)
        XCTAssertEqual(old.catalog.rootPathIndexes[0].identity.topologyGeneration, old.roots[0].catalogGeneration)
        XCTAssertEqual(old.catalog.files.map(\.name), ["Generation.swift"])
        let oldIsCurrent = await store.isRootContextSnapshotCurrent(old)
        XCTAssertFalse(oldIsCurrent)
    }

    func testRetagFailureAtRetentionBoundaryFallsBackToCompleteImmutableCatalog() async throws {
        let url = try makeRoot(fileName: "Fallback.swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: url.path)
        let oldValue = await store.rootContextSnapshot()
        let old = try XCTUnwrap(oldValue)
        var heldSnapshots = [old]
        for _ in 1 ..< 8 {
            await store.advanceRootCatalogGenerationWithoutRetagForTesting(rootID: root.id)
            let heldValue = await store.rootContextSnapshot()
            try heldSnapshots.append(XCTUnwrap(heldValue))
        }
        await store.advanceRootCatalogGenerationWithoutRetagForTesting(rootID: root.id)
        let before = await store.storeWorkDiagnosticsSnapshot()
        let fallbackValue = await store.rootContextSnapshot()
        let fallback = try XCTUnwrap(fallbackValue)
        let after = await store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(heldSnapshots.count, 8)
        XCTAssertGreaterThan(after.rootCatalogShards.totalBackstopCount, before.rootCatalogShards.totalBackstopCount)
        XCTAssertEqual(fallback.catalog.files.map(\.name), ["Fallback.swift"])
        XCTAssertEqual(fallback.catalog.rootPathIndexes[0].identity.topologyGeneration, fallback.roots[0].catalogGeneration)
        XCTAssertEqual(old.catalog.files.map(\.name), ["Fallback.swift"])
        XCTAssertTrue(fallback.lifetimeIsCurrent())
    }

    private func makeRoot(fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "struct SnapshotFixture {}\n".write(to: url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        return url
    }
}

final class WorkspaceRootCatalogRetentionTests: XCTestCase {
    func testModificationOnlyScopeCachePinsAreReclaimedBeforeBackstop() async throws {
        try await assertCachePinReclamation(externalReaderCount: 0)
    }

    func testCachePinsAreReclaimedWithoutRevokingExternalSnapshots() async throws {
        try await assertCachePinReclamation(externalReaderCount: 4)
    }

    func testExternalReadersStillEnforceCapAndPublicationRecoversAfterRelease() async throws {
        let fixture = try await makeFixture(rootCount: 1)
        var held: [WorkspaceContextRootSnapshot] = []
        var fileBuffers: [UInt] = []
        var entryBuffers: [UInt] = []
        var modificationDates: [Date?] = []
        for sequence in 1 ... 8 {
            try await modifyRoot(fixture, sequence: sequence)
            let value = await fixture.store.rootContextSnapshot()
            let snapshot = try XCTUnwrap(value)
            held.append(snapshot)
            fileBuffers.append(bufferIdentity(snapshot.catalog.files))
            entryBuffers.append(bufferIdentity(snapshot.catalog.entries))
            modificationDates.append(snapshot.catalog.files[0].modificationDate)
        }
        let before = try await rootDiagnostics(fixture)
        XCTAssertEqual(before.liveTopologyGenerations.count, 8)
        try await modifyRoot(fixture, sequence: 9)
        let blocked = try await rootDiagnostics(fixture)
        XCTAssertGreaterThan(blocked.backstopCount, before.backstopCount)
        XCTAssertNil(blocked.publishedTopologyGeneration)
        XCTAssertTrue(blocked.deltaStateDirty)
        for (index, snapshot) in held.enumerated() {
            XCTAssertEqual(snapshot.catalog.files.map(\.name), ["Root0.swift"])
            XCTAssertEqual(snapshot.catalog.files[0].modificationDate, modificationDates[index])
            XCTAssertEqual(bufferIdentity(snapshot.catalog.files), fileBuffers[index])
            XCTAssertEqual(bufferIdentity(snapshot.catalog.entries), entryBuffers[index])
            XCTAssertTrue(snapshot.lifetimeIsCurrent())
        }
        held.removeAll()
        let recoveredValue = await fixture.store.rootContextSnapshot()
        let recovered = try XCTUnwrap(recoveredValue)
        let currentFiles = await fixture.store.files(inRoot: fixture.roots[0].id)
        XCTAssertEqual(recovered.catalog.files, currentFiles)
        let after = try await rootDiagnostics(fixture)
        XCTAssertNotNil(after.publishedTopologyGeneration)
        XCTAssertFalse(after.deltaStateDirty)
    }

    func testCurrentShardCacheEntrySurvivesRepeatedAdmissionFailures() async throws {
        let fixture = try await makeFixture()
        let scopes = cachedScopes(fixture)
        let held = try await populateScopeCache(fixture, scopes: scopes, externalReaderCount: 8)
        let before = try await rootDiagnostics(fixture)
        XCTAssertEqual(before.liveTopologyGenerations.count, 8)

        // Promotion cannot publish while all eight records-only shards have external readers.
        // Unlike a patch failure, promotion leaves the current publication installed.
        _ = await fixture.store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let first = await fixture.store.storeWorkDiagnosticsSnapshot()
        let firstCacheCount = await fixture.store.searchCatalogSnapshotCacheCountForTesting()
        XCTAssertEqual(firstCacheCount, 1, "Only the cache entry leasing the current publication should survive")
        let firstReclaims = first.invalidations.filter { $0.reasons.contains("shard_retention_reclaim") }
        XCTAssertEqual(firstReclaims.count, 1)
        let firstReclaim = try XCTUnwrap(firstReclaims.first)
        XCTAssertEqual(firstReclaim.evictedScopes.count, 7)

        for _ in 0 ..< 3 {
            _ = await fixture.store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        }
        let afterAttempts = await fixture.store.storeWorkDiagnosticsSnapshot()
        let cacheCount = await fixture.store.searchCatalogSnapshotCacheCountForTesting()
        XCTAssertEqual(cacheCount, firstCacheCount)
        XCTAssertEqual(
            afterAttempts.invalidations.count(where: { $0.reasons.contains("shard_retention_reclaim") }),
            firstReclaims.count,
            "Genuine reader pressure must not repeatedly evict the current-shard cache entry"
        )
        let current = await fixture.store.searchCatalogSnapshot(rootScope: scopes[7], requirement: .recordsOnly)
        let afterRead = await fixture.store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(afterRead.catalogRebuild.rebuildCount, afterAttempts.catalogRebuild.rebuildCount)
        XCTAssertEqual(bufferIdentity(current.files), bufferIdentity(held[7].files))
        XCTAssertEqual(bufferIdentity(current.entries), bufferIdentity(held[7].entries))
        let root = try await rootDiagnostics(fixture)
        XCTAssertNotNil(root.publishedTopologyGeneration)
        XCTAssertGreaterThan(root.backstopCount, before.backstopCount)
        withExtendedLifetime(held) {}
    }

    private func assertCachePinReclamation(externalReaderCount: Int) async throws {
        let fixture = try await makeFixture()
        let siblingScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [fixture.urls[1].path], physicalRootPaths: []
        )
        let sibling = await fixture.store.searchCatalogSnapshot(rootScope: siblingScope, requirement: .recordsOnly)
        let siblingBefore = try await rootDiagnostics(fixture, index: 1)
        let scopes = cachedScopes(fixture)
        let held = try await populateScopeCache(
            fixture, scopes: scopes, externalReaderCount: externalReaderCount
        )
        let before = try await rootDiagnostics(fixture)
        XCTAssertEqual(before.liveTopologyGenerations.count, 8)
        let externalBuffers = held.map { bufferIdentity($0.files) }
        let externalDates = held.map { snapshot in
            snapshot.files.first { $0.rootID == fixture.roots[0].id }?.modificationDate
        }
        let firstGeneration = await fixture.store.catalogGeneration(rootScope: scopes[0])
        try await modifyRoot(fixture, sequence: 9)
        let after = try await rootDiagnostics(fixture)
        XCTAssertEqual(after.backstopCount, before.backstopCount)
        XCTAssertNotNil(after.publishedTopologyGeneration)
        XCTAssertFalse(after.deltaStateDirty)
        XCTAssertEqual(after.patchCount, before.patchCount + 1)
        XCTAssertEqual(after.lastAppliedIndexGeneration, try XCTUnwrap(before.lastAppliedIndexGeneration) + 1)
        XCTAssertLessThan(after.liveTopologyGenerations.count, 8)
        let cacheCount = await fixture.store.searchCatalogSnapshotCacheCountForTesting()
        XCTAssertEqual(cacheCount, 2, "Keep the sibling-only scope and the previous current-shard scope")

        let first = await fixture.store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
        let firstWork = await fixture.store.storeWorkDiagnosticsSnapshot()
        let second = await fixture.store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
        let secondWork = await fixture.store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(bufferIdentity(first.files), bufferIdentity(second.files))
        XCTAssertEqual(bufferIdentity(first.entries), bufferIdentity(second.entries))
        XCTAssertEqual(firstWork.catalogRebuild.rebuildCount, secondWork.catalogRebuild.rebuildCount)
        let currentFiles = await fixture.store.files(inRoot: fixture.roots[0].id)
        let currentFile = try XCTUnwrap(currentFiles.first)
        XCTAssertEqual(first.files.first { $0.rootID == fixture.roots[0].id }, currentFile)

        let rebuilt = await fixture.store.searchCatalogSnapshot(rootScope: scopes[0], requirement: .recordsOnly)
        XCTAssertEqual(rebuilt.generation, firstGeneration, "Reclaim does not manufacture a new authority generation")
        XCTAssertEqual(rebuilt.files.first { $0.rootID == fixture.roots[0].id }, currentFile)
        let siblingAgain = await fixture.store.searchCatalogSnapshot(rootScope: siblingScope, requirement: .recordsOnly)
        XCTAssertEqual(bufferIdentity(sibling.files), bufferIdentity(siblingAgain.files))
        let siblingAfter = try await rootDiagnostics(fixture, index: 1)
        XCTAssertEqual(siblingAfter.buildCount, siblingBefore.buildCount)
        for (index, snapshot) in held.enumerated() {
            XCTAssertEqual(snapshot.files.first { $0.rootID == fixture.roots[0].id }?.modificationDate, externalDates[index])
            XCTAssertEqual(bufferIdentity(snapshot.files), externalBuffers[index])
        }
        withExtendedLifetime(held) {}
    }

    private struct Fixture {
        let store: WorkspaceFileContextStore
        let urls: [URL]
        let roots: [WorkspaceRootRecord]
    }

    private func makeFixture(rootCount: Int = 4) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        var urls: [URL] = []
        var roots: [WorkspaceRootRecord] = []
        addTeardownBlock {
            for root in await store.roots() {
                await store.unloadRoot(id: root.id)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 0 ..< rootCount {
            let url = directory.appendingPathComponent("root-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "struct Root\(index) {}\n".write(
                to: url.appendingPathComponent("Root\(index).swift"), atomically: true, encoding: .utf8
            )
            urls.append(url)
            let root = try await store.loadRoot(path: url.path)
            roots.append(root)
        }
        return Fixture(store: store, urls: urls, roots: roots)
    }

    private func cachedScopes(_ fixture: Fixture) -> [WorkspaceLookupRootScope] {
        (0 ..< 8).map { subset in
            var paths: Set<String> = [fixture.urls[0].path]
            for index in 1 ... 3 where subset & (1 << (index - 1)) != 0 {
                paths.insert(fixture.urls[index].path)
            }
            return .sessionBoundWorkspace(canonicalRootPaths: paths, physicalRootPaths: [])
        }
    }

    private func populateScopeCache(
        _ fixture: Fixture,
        scopes: [WorkspaceLookupRootScope],
        externalReaderCount: Int
    ) async throws -> [WorkspaceSearchCatalogSnapshot] {
        var held: [WorkspaceSearchCatalogSnapshot] = []
        for (index, scope) in scopes.enumerated() {
            let generation = await fixture.store.catalogGeneration(rootScope: scope)
            try await modifyRoot(fixture, sequence: index + 1)
            let afterGeneration = await fixture.store.catalogGeneration(rootScope: scope)
            XCTAssertEqual(afterGeneration, generation, "Modification-only events leave scope tokens valid")
            let snapshot = await fixture.store.searchCatalogSnapshot(rootScope: scope, requirement: .recordsOnly)
            XCTAssertEqual(snapshot.generation, generation)
            if index < externalReaderCount {
                held.append(snapshot)
            }
        }
        return held
    }

    private func modifyRoot(_ fixture: Fixture, sequence: Int) async throws {
        let date = modificationDate(sequence)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: fixture.urls[0].appendingPathComponent("Root0.swift").path
        )
        await fixture.store.replayObservedFileSystemDeltas(
            rootID: fixture.roots[0].id, deltas: [.fileModified("Root0.swift", date)]
        )
    }

    private func rootDiagnostics(
        _ fixture: Fixture,
        index: Int = 0
    ) async throws -> WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot {
        let work = await fixture.store.storeWorkDiagnosticsSnapshot()
        return try XCTUnwrap(work.rootCatalogShards.roots.first { $0.rootID == fixture.roots[index].id })
    }

    private func modificationDate(_ sequence: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + sequence))
    }

    private func bufferIdentity(_ values: [some Any]) -> UInt {
        values.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) } ?? 0
        }
    }
}

#if DEBUG
    final class WorkspaceRootCatalogDeltaTests: XCTestCase {
        func testSmallCanonicalMixedBatchMatchesAuthority() async throws {
            var fixture = CatalogDeltaFixture(fileCount: 12)
            let old = fixture.authoritative()
            let recordsOnly = fixture.authoritative(requiresPathIndexes: false)
            let snapshot = try await WorkspaceRootSeedTestSupport.snapshot(paths: old.entries.map { ($0.standardizedRelativePath, "100644") })
            let projectedIndex = try XCTUnwrap(WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(rootID: old.root.id, lifetimeID: old.lifetimeID, topologyGeneration: old.topologyGeneration),
                root: old.root, projectedSnapshot: snapshot,
                changedRelativeFilePaths: [], tombstonedBaseRelativeFilePaths: [], entries: old.entries
            ))
            let projected = WorkspaceFileContextStore.RootCatalogShardComparisonView(
                lifetimeID: old.lifetimeID, topologyGeneration: old.topologyGeneration, root: old.root,
                files: old.files, folders: old.folders, entries: old.entries,
                projectionFiles: old.projectionFiles, projectionLanguages: old.projectionLanguages,
                projectionFileIndexByID: old.projectionFileIndexByID,
                pathSearchIndex: projectedIndex, appliedIndexGeneration: old.appliedIndexGeneration
            )
            let heldBytes = old.files.map(catalogFileBytes)
            let first = fixture.addFile(number: 100, name: "Added.swift")
            let second = fixture.addFile(number: 101, name: "Added.md")
            let ancestor = try XCTUnwrap(fixture.folders[fixture.parentID])
            let add = fixture.event(upsertedFiles: [first, second], upsertedFolders: [ancestor, ancestor])
            let candidate = try XCTUnwrap(fixture.patch(old, event: add))
            XCTAssertEqual(candidate.logicalMutationCount, 3, "Repeated ancestors count once, but still consume budget")
            XCTAssertEqual(candidate.changedFileIDs, [first.id, second.id])
            assertCatalogParity(candidate.shard, fixture.authoritative(generation: 1))
            let projectedCandidate = try XCTUnwrap(fixture.patch(projected, event: add))
            XCTAssertEqual(projectedCandidate.shard.pathSearchIndex?.buildKind, .projectedReuse)
            assertCatalogParity(projectedCandidate.shard, fixture.authoritative(generation: 1))
            let recordsOnlyCandidate = try XCTUnwrap(fixture.patch(recordsOnly, event: add))
            XCTAssertNil(recordsOnlyCandidate.shard.pathSearchIndex)
            assertCatalogParity(recordsOnlyCandidate.shard, fixture.authoritative(generation: 1, requiresPathIndexes: false))
            XCTAssertEqual(old.files.map(catalogFileBytes), heldBytes)

            let removed = try XCTUnwrap(fixture.files[CatalogDeltaFixture.id(1000)])
            fixture.removeFile(removed)
            let replacement = fixture.addFile(number: 102, name: removed.name)
            let next = fixture.event(generation: 2, upsertedFiles: [replacement], removedFileIDs: [removed.id])
            let replaced = try XCTUnwrap(fixture.patch(candidate.shard, event: next))
            XCTAssertEqual(replaced.changedFileIDs, [removed.id, replacement.id])
            assertCatalogParity(replaced.shard, fixture.authoritative(generation: 2))

            let newParent = fixture.addFolder(number: 30, name: "Nested")
            let nested = fixture.addFile(number: 300, name: "Nested.swift", parentID: newParent.id)
            let nestedEvent = fixture.event(generation: 3, upsertedFiles: [nested], upsertedFolders: [newParent, ancestor, ancestor])
            let nestedResult = try XCTUnwrap(fixture.patch(replaced.shard, event: nestedEvent))
            XCTAssertEqual(nestedResult.logicalMutationCount, 3)
            assertCatalogParity(nestedResult.shard, fixture.authoritative(generation: 3))

            // Production cap remains one: a real multi-record publication must still rebuild,
            // advance once, complete before replay returns, and leave the other root untouched.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let a = directory.appendingPathComponent("a")
            let b = directory.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            try "value".write(to: a.appendingPathComponent("Sources/Old.swift"), atomically: false, encoding: .utf8)
            try "other".write(to: b.appendingPathComponent("Other.md"), atomically: false, encoding: .utf8)
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false, codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
            addTeardownBlock {
                for root in await store.roots() {
                    await store.unloadRoot(id: root.id)
                }
                try? FileManager.default.removeItem(at: directory)
            }
            let rootA = try await store.loadRoot(path: a.path)
            let rootB = try await store.loadRoot(path: b.path)
            _ = await store.rootContextSnapshot()
            let before = await store.storeWorkDiagnosticsSnapshot()
            let beforeA = try XCTUnwrap(before.rootCatalogShards.roots.first { $0.rootID == rootA.id })
            let beforeB = try XCTUnwrap(before.rootCatalogShards.roots.first { $0.rootID == rootB.id })
            let otherValue = await store.rootCatalogShardComparisonViewForTesting(rootID: rootB.id)
            let other = try XCTUnwrap(otherValue)
            let stream = await store.appliedIndexEvents()
            var iterator = stream.makeAsyncIterator()
            try FileManager.default.createDirectory(at: a.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
            for name in ["Nested/One.swift", "Two.md"] {
                try "added".write(to: a.appendingPathComponent("Sources/" + name), atomically: false, encoding: .utf8)
            }
            let attached = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: rootA.id)
            XCTAssertTrue(attached)
            let ingressBefore = await store.publisherIngressDebugSnapshotForTesting(rootID: rootA.id)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootA.id, deltas: [.fileAdded("Sources/Nested/One.swift"), .fileAdded("Sources/Two.md")]
            )
            let accepted = await store.publisherIngressDebugSnapshotForTesting(rootID: rootA.id)
            XCTAssertGreaterThan(accepted.acceptedServicePublicationSequence, ingressBefore.acceptedServicePublicationSequence)
            await store.waitUntilPublisherIngressAppliedForTesting(
                rootID: rootA.id, servicePublicationSequence: accepted.acceptedServicePublicationSequence
            )
            let completed = await store.publisherIngressDebugSnapshotForTesting(rootID: rootA.id)
            XCTAssertEqual(completed.appliedServicePublicationSequence, completed.acceptedServicePublicationSequence)
            XCTAssertEqual(completed.acceptedAppliedSequenceGap, 0)
            XCTAssertEqual(completed.outstandingPublicationCount, 0)
            let appliedValue = await iterator.next()
            let applied = try XCTUnwrap(appliedValue)
            XCTAssertEqual(applied.rootID, rootA.id)
            XCTAssertEqual(applied.upsertedFiles.count, 2)
            XCTAssertGreaterThan(
                applied.upsertedFolders.count,
                Set(applied.upsertedFolders.map(\.id)).count,
                "Keep subscriber identity-reconciliation payload unchanged"
            )
            let after = await store.storeWorkDiagnosticsSnapshot()
            let afterA = try XCTUnwrap(after.rootCatalogShards.roots.first { $0.rootID == rootA.id })
            let afterB = try XCTUnwrap(after.rootCatalogShards.roots.first { $0.rootID == rootB.id })
            XCTAssertEqual(afterA.patchCount, beforeA.patchCount)
            XCTAssertEqual(afterA.authoritativeRebuildCount, beforeA.authoritativeRebuildCount + 1)
            XCTAssertEqual(afterA.fallbackReasonCounts[.patchThresholdExceeded, default: 0], beforeA.fallbackReasonCounts[.patchThresholdExceeded, default: 0] + 1)
            XCTAssertEqual(afterA.fallbackReasonCounts[.patchApplicationBackstop, default: 0], beforeA.fallbackReasonCounts[.patchApplicationBackstop, default: 0])
            XCTAssertEqual(afterA.lastAppliedIndexGeneration, applied.generation)
            XCTAssertEqual(applied.generation, try XCTUnwrap(beforeA.lastAppliedIndexGeneration) + 1)
            XCTAssertEqual(afterB.patchCount, beforeB.patchCount)
            XCTAssertEqual(afterB.authoritativeRebuildCount, beforeB.authoritativeRebuildCount)
            let otherAfterValue = await store.rootCatalogShardComparisonViewForTesting(rootID: rootB.id)
            try assertCatalogParity(XCTUnwrap(otherAfterValue), other)
        }

        func testUnicodeIdentityAndOrderingMatchAuthoritativeBytes() throws {
            var fixture = CatalogDeltaFixture(fileCount: 9)
            let old = fixture.authoritative()
            let names = ["caf\u{00E9}.swift", "cafe\u{0301}.md", "\u{212A}.swift", "K.md", "\u{0315}\u{0300}.txt"]
            let additions = names.enumerated().map { fixture.addFile(number: 100 + $0.offset, name: $0.element) }
            let result = try XCTUnwrap(fixture.patch(old, event: fixture.event(upsertedFiles: additions)))
            assertCatalogParity(result.shard, fixture.authoritative(generation: 1))
            XCTAssertEqual(result.changedFileIDs, Set(additions.map(\.id)))

            let unicodeFolders = ["\u{212A}elvin", "Latin"].enumerated().map {
                fixture.addFolder(number: 30 + $0.offset, name: $0.element)
            }
            let folderResult = try XCTUnwrap(fixture.patch(result.shard, event: fixture.event(generation: 2, upsertedFolders: unicodeFolders)))
            assertCatalogParity(folderResult.shard, fixture.authoritative(generation: 2))

            let original = additions[0]
            let contradictory = WorkspaceFileRecord(
                id: original.id, rootID: original.rootID, name: "cafe\u{0301}.swift",
                relativePath: original.relativePath, fullPath: original.fullPath,
                parentFolderID: original.parentFolderID, modificationDate: original.modificationDate
            )
            XCTAssertNil(
                fixture.patch(old, event: fixture.event(upsertedFiles: [original, contradictory])),
                "Canonical String equality must not admit conflicting source bytes"
            )
            // A true canonical alias in another ID cannot displace a still-authoritative record.
            let alias = fixture.addFile(number: 200, name: "cafe\u{0301}.swift")
            XCTAssertNil(fixture.patch(result.shard, event: fixture.event(upsertedFiles: [alias])))
        }

        func testUnsafeOrOversizedBatchKeepsAuthoritativeFallback() async throws {
            var fixture = CatalogDeltaFixture(fileCount: 3)
            let old = fixture.authoritative()
            let added = fixture.addFile(number: 100, name: "new.swift")
            let missingParent = WorkspaceFileRecord(
                id: added.id, rootID: added.rootID, name: added.name,
                relativePath: added.relativePath, fullPath: added.fullPath,
                parentFolderID: CatalogDeltaFixture.id(999), modificationDate: nil
            )
            fixture.files[added.id] = missingParent
            XCTAssertNil(fixture.patch(old, event: fixture.event(upsertedFiles: [missingParent])))
            fixture.files[added.id] = added
            XCTAssertNil(fixture.patch(old, event: fixture.event(upsertedFiles: [added], removedFileIDs: [added.id])))
            XCTAssertNil(fixture.patch(old, event: fixture.event(modifiedFileIDs: [added.id])), "A modification must have an old row")
            XCTAssertNil(fixture.patch(old, event: fixture.event(removedFileIDs: [CatalogDeltaFixture.id(999)])))
            let parent = try XCTUnwrap(fixture.folders.removeValue(forKey: fixture.parentID))
            fixture.folderIDsByPath.removeValue(forKey: parent.standardizedRelativePath)
            XCTAssertNil(
                fixture.patch(old, event: fixture.event(removedFolderIDs: [parent.id])),
                "Retained children of removed parents require authoritative fallback"
            )

            let rejected: [(String, (inout CatalogDeltaFixture) throws -> WorkspaceAppliedIndexBatchEvent)] = [
                ("unreported new ancestor", { value in
                    let folder = value.addFolder(number: 30, name: "New")
                    let file = value.addFile(number: 100, name: "New.swift", parentID: folder.id)
                    return value.event(upsertedFiles: [file])
                }),
                ("live removed file", { value in
                    value.event(removedFileIDs: [CatalogDeltaFixture.id(1000)])
                }),
                ("live removed folder", { value in
                    value.event(removedFolderIDs: [value.parentID])
                }),
                ("missing removed path", { value in
                    value.event(removedFilePaths: ["Sources/missing.swift"])
                }),
                ("root removal by path", { value in
                    value.event(removedFolderPaths: [""])
                }),
                ("root removal by ID", { value in
                    value.event(removedFolderIDs: [value.root.id])
                }),
                ("managed-only upsert", { value in
                    let file = value.addFile(number: 100, name: "Managed.swift")
                    value.managedOnlyFileIDs.insert(file.id)
                    return value.event(upsertedFiles: [file])
                }),
                ("wrong path owner", { value in
                    let file = value.addFile(number: 100, name: "Wrong.swift")
                    value.fileIDsByPath[file.standardizedRelativePath] = CatalogDeltaFixture.id(999)
                    return value.event(upsertedFiles: [file])
                }),
                ("folder path change", { value in
                    let folder = try XCTUnwrap(value.folders[value.parentID])
                    let moved = WorkspaceFolderRecord(
                        id: folder.id, rootID: folder.rootID, name: "Moved",
                        relativePath: "Moved", fullPath: value.root.fullPath + "/Moved",
                        parentFolderID: folder.parentFolderID
                    )
                    value.folders[folder.id] = moved
                    value.folderIDsByPath.removeValue(forKey: folder.standardizedRelativePath)
                    value.folderIDsByPath[moved.standardizedRelativePath] = folder.id
                    return value.event(modifiedFolderIDs: [folder.id])
                }),
                ("self-parent cycle", { value in
                    let folder = try XCTUnwrap(value.folders[value.parentID])
                    let changed = WorkspaceFolderRecord(
                        id: folder.id, rootID: folder.rootID, name: folder.name,
                        relativePath: folder.relativePath, fullPath: folder.fullPath,
                        parentFolderID: folder.id
                    )
                    value.folders[folder.id] = changed
                    return value.event(modifiedFolderIDs: [folder.id])
                })
            ]
            for (name, mutate) in rejected {
                var value = CatalogDeltaFixture(fileCount: 3)
                let previous = value.authoritative()
                let event = try mutate(&value)
                XCTAssertNil(value.patch(previous, event: event), name)
            }
            var byPath = CatalogDeltaFixture(fileCount: 3)
            let beforePathRemoval = byPath.authoritative()
            let pathRemoved = try XCTUnwrap(byPath.files[CatalogDeltaFixture.id(1000)])
            byPath.removeFile(pathRemoved)
            let pathResult = try XCTUnwrap(byPath.patch(beforePathRemoval, event: byPath.event(removedFilePaths: [pathRemoved.standardizedRelativePath])))
            XCTAssertEqual(pathResult.changedFileIDs, [pathRemoved.id])
            assertCatalogParity(pathResult.shard, byPath.authoritative(generation: 1))
            let folder = try XCTUnwrap(byPath.folders[byPath.parentID])
            let folderResult = try XCTUnwrap(byPath.patch(pathResult.shard, event: byPath.event(generation: 2, modifiedFolderIDs: [folder.id])))
            assertCatalogParity(folderResult.shard, byPath.authoritative(generation: 2))

            // Exercise the actual actor's pre-merge recovery fences at both capabilities.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "value".write(to: directory.appendingPathComponent("Old.swift"), atomically: false, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cases: [(name: String, offset: UInt64, resync: Bool, missingID: Bool, reason: WorkspaceFileContextStore.RootCatalogShardFallbackReason)] = [
                ("resync", 1, true, false, .fullResync),
                ("gap", 2, false, false, .generationGap),
                ("zero", 0, false, false, .generationGap),
                ("maximum", UInt64.max, false, false, .generationGap),
                ("invalid", 1, false, true, .patchApplicationBackstop)
            ]
            for indexed in [false, true] {
                for testCase in cases {
                    let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false, codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
                    let root = try await store.loadRoot(path: directory.path)
                    _ = await store.searchCatalogSnapshot(requirement: indexed ? .recordsAndPathIndexes : .recordsOnly)
                    let originalValue = await store.rootCatalogShardComparisonViewForTesting(rootID: root.id)
                    let original = try XCTUnwrap(originalValue)
                    XCTAssertEqual(original.pathSearchIndex != nil, indexed, testCase.name)
                    let before = await store.storeWorkDiagnosticsSnapshot()
                    let beforeRoot = try XCTUnwrap(before.rootCatalogShards.roots.first { $0.rootID == root.id })
                    let generation = testCase.offset == 1 || testCase.offset == 2
                        ? original.appliedIndexGeneration + testCase.offset : testCase.offset
                    await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                        rootID: root.id, rootPath: root.standardizedFullPath, generation: generation,
                        modifiedFileIDs: testCase.missingID ? [CatalogDeltaFixture.id(999)] : [],
                        requiresFullResync: testCase.resync
                    ))
                    let after = await store.storeWorkDiagnosticsSnapshot()
                    let afterRoot = try XCTUnwrap(after.rootCatalogShards.roots.first { $0.rootID == root.id })
                    XCTAssertEqual(afterRoot.patchCount, beforeRoot.patchCount, testCase.name)
                    XCTAssertEqual(afterRoot.authoritativeRebuildCount, beforeRoot.authoritativeRebuildCount + 1, testCase.name)
                    XCTAssertEqual(afterRoot.fallbackReasonCounts[testCase.reason, default: 0], beforeRoot.fallbackReasonCounts[testCase.reason, default: 0] + 1, testCase.name)
                    XCTAssertFalse(afterRoot.deltaStateDirty, testCase.name)
                    let rebuiltValue = await store.rootCatalogShardComparisonViewForTesting(rootID: root.id)
                    let rebuilt = try XCTUnwrap(rebuiltValue)
                    XCTAssertEqual(rebuilt.pathSearchIndex != nil, indexed, testCase.name)
                    XCTAssertEqual(rebuilt.appliedIndexGeneration, generation, testCase.name)
                    XCTAssertEqual(rebuilt.files.map(catalogFileBytes), original.files.map(catalogFileBytes), testCase.name)
                    XCTAssertEqual(rebuilt.folders.map(catalogFolderBytes), original.folders.map(catalogFolderBytes), testCase.name)
                    XCTAssertEqual(rebuilt.entries.map(catalogEntryBytes), original.entries.map(catalogEntryBytes), testCase.name)
                    if generation == UInt64.max {
                        // The next event must not overflow lastApplied + 1.
                        await store.applyAppliedIndexEventToRootCatalogShardForTesting(WorkspaceAppliedIndexBatchEvent(
                            rootID: root.id, rootPath: root.standardizedFullPath, generation: 1
                        ))
                        let overflow = await store.storeWorkDiagnosticsSnapshot()
                        let overflowRoot = try XCTUnwrap(overflow.rootCatalogShards.roots.first { $0.rootID == root.id })
                        XCTAssertEqual(overflowRoot.fallbackReasonCounts[.generationGap, default: 0], afterRoot.fallbackReasonCounts[.generationGap, default: 0] + 1)
                        XCTAssertEqual(overflowRoot.lastAppliedIndexGeneration, 1)
                        XCTAssertEqual(overflowRoot.patchCount, beforeRoot.patchCount)
                    }
                    await store.unloadRoot(id: root.id)
                }
            }
        }

        func testRepeatedMultiRecordOverlaysMatchFreshIndex() throws {
            var fixture = CatalogDeltaFixture(fileCount: 8)
            let held = fixture.authoritative()
            var current = held
            for sequence in 0 ..< 36 {
                let added = fixture.addFile(number: 100 + sequence, name: "Overlay-\(sequence).swift")
                let oldFile = try XCTUnwrap(fixture.files[CatalogDeltaFixture.id(1000)])
                let renamed = WorkspaceFileRecord(
                    id: oldFile.id, rootID: oldFile.rootID, name: sequence.isMultiple(of: 2) ? "Match.swift" : "Gone.md",
                    relativePath: "Sources/" + (sequence.isMultiple(of: 2) ? "Match.swift" : "Gone.md"),
                    fullPath: fixture.root.fullPath + "/Sources/" + (sequence.isMultiple(of: 2) ? "Match.swift" : "Gone.md"),
                    parentFolderID: oldFile.parentFolderID, modificationDate: oldFile.modificationDate
                )
                fixture.removeFile(oldFile)
                fixture.files[renamed.id] = renamed
                fixture.fileIDsByPath[renamed.standardizedRelativePath] = renamed.id
                let event = fixture.event(generation: UInt64(sequence + 1), upsertedFiles: [added], modifiedFileIDs: [renamed.id])
                let result = try XCTUnwrap(fixture.patch(current, event: event))
                XCTAssertEqual(result.shard.pathSearchIndex?.buildKind, .overlay)
                current = result.shard
                if [0, 16, 33, 35].contains(sequence) {
                    assertCatalogParity(current, fixture.authoritative(generation: UInt64(sequence + 1)))
                }
            }
            let metrics = try XCTUnwrap(current.pathSearchIndex?.overlayHistoryMetricsForTesting)
            XCTAssertEqual(metrics.compactedPageCount, 0)
            XCTAssertEqual(metrics.compactedPayloadCount, 0)
            XCTAssertLessThanOrEqual(metrics.totalPayloadCount, 1)
            XCTAssertEqual(held.files.count, 8)
            XCTAssertEqual(held.pathSearchIndex?.search("Overlay", limit: 100).count, 0)
        }

        func testMaterializedDeltaParityAt200001Files() throws {
            var fixture = CatalogDeltaFixture(fileCount: 200_001)
            fixture.managedOnlyFileIDs = [CatalogDeltaFixture.id(201_000)]
            let held = fixture.authoritative()
            XCTAssertEqual(fixture.files.count, 200_001)
            XCTAssertEqual(held.files.count, 200_000)
            var current = held
            var candidateSeconds = 0.0
            var referenceSeconds = 0.0
            let heldFirst = try catalogFileBytes(XCTUnwrap(held.files.first))
            // Four fixed checkpoints. Setup and byte/query assertions are outside construction timing.
            for checkpoint in 0 ..< 4 {
                var changed: [WorkspaceFileRecord] = []
                var upsertedFolders: [WorkspaceFolderRecord] = []
                var removed: [UUID] = []
                var modified: [UUID] = []
                if checkpoint == 0 {
                    let newParent = fixture.addFolder(number: 30, name: "Nested")
                    let shared = try XCTUnwrap(fixture.folders[fixture.parentID])
                    upsertedFolders = [newParent, shared, shared]
                    changed = [
                        fixture.addFile(number: 300_000, name: "New.swift", parentID: newParent.id),
                        fixture.addFile(number: 300_001, name: "New.md")
                    ]
                } else if checkpoint == 1 {
                    for number in [1000, 1100] {
                        let file = try XCTUnwrap(fixture.files[CatalogDeltaFixture.id(number)])
                        let replacement = WorkspaceFileRecord(
                            id: file.id, rootID: file.rootID, name: file.name,
                            relativePath: file.relativePath, fullPath: file.fullPath,
                            parentFolderID: file.parentFolderID,
                            modificationDate: Date(timeIntervalSinceReferenceDate: 2)
                        )
                        fixture.files[file.id] = replacement
                        modified.append(file.id)
                    }
                } else if checkpoint == 2 {
                    let file = try XCTUnwrap(fixture.files[CatalogDeltaFixture.id(1200)])
                    fixture.removeFile(file)
                    removed = [file.id]
                    changed = [fixture.addFile(number: 300_002, name: file.name)]
                } else {
                    // Actual overlay history crosses two page transitions, retaining the same base.
                    for sequence in 0 ..< 34 {
                        let additions = [
                            fixture.addFile(number: 400_000 + sequence * 2, name: "Overlay-\(sequence).swift"),
                            fixture.addFile(number: 400_001 + sequence * 2, name: "Overlay-\(sequence).md")
                        ]
                        let event = fixture.event(generation: UInt64(4 + sequence), upsertedFiles: additions)
                        current = try XCTUnwrap(fixture.patch(current, event: event)).shard
                    }
                    changed = [
                        fixture.addFile(number: 400_068, name: "Overlay-34.swift"),
                        fixture.addFile(number: 400_069, name: "Overlay-34.md")
                    ]
                }
                let generation = UInt64(checkpoint == 3 ? 38 : checkpoint + 1)
                let event = fixture.event(
                    generation: generation,
                    upsertedFiles: changed,
                    upsertedFolders: upsertedFolders,
                    removedFileIDs: removed,
                    modifiedFileIDs: modified
                )
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try XCTUnwrap(fixture.patch(current, event: event))
                candidateSeconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                current = result.shard
                let referenceStart = DispatchTime.now().uptimeNanoseconds
                let reference = fixture.authoritative(generation: generation)
                referenceSeconds += Double(DispatchTime.now().uptimeNanoseconds - referenceStart) / 1e9
                assertCatalogParity(current, reference)
                XCTAssertEqual(try catalogFileBytes(XCTUnwrap(held.files.first)), heldFirst)
            }
            print("CATALOG_DELTA_200001 candidate_checkpoints_seconds=\(candidateSeconds) authoritative_checkpoints_seconds=\(referenceSeconds)")
            // Calibrated debug construction totals: 1.912–1.928 s versus 30.247–30.325 s.
            // Fourfold local runner headroom; parity/oracle/setup work is outside this budget.
            XCTAssertLessThan(candidateSeconds, 8)
            XCTAssertLessThan(candidateSeconds, referenceSeconds * 0.5)
        }
    }

    private struct CatalogDeltaFixture {
        static func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
        }

        let root = WorkspaceRootRecord(id: id(1), name: "Root", fullPath: "/catalog-delta")
        let lifetimeID = id(2)
        let parentID = id(10)
        var files: [UUID: WorkspaceFileRecord] = [:]
        var folders: [UUID: WorkspaceFolderRecord] = [:]
        var managedOnlyFileIDs = Set<UUID>()
        var fileIDsByPath: [String: UUID] = [:]
        var folderIDsByPath: [String: UUID] = [:]

        init(fileCount: Int) {
            let sentinel = WorkspaceFolderRecord(
                id: root.id,
                rootID: root.id,
                name: root.name,
                relativePath: "",
                fullPath: root.fullPath,
                parentFolderID: nil
            )
            let parent = WorkspaceFolderRecord(
                id: parentID,
                rootID: root.id,
                name: "Sources",
                relativePath: "Sources",
                fullPath: root.fullPath + "/Sources",
                parentFolderID: root.id
            )
            folders = [sentinel.id: sentinel, parent.id: parent]
            folderIDsByPath = ["": sentinel.id, "Sources": parent.id]
            for index in 0 ..< fileCount {
                let suffix = index.isMultiple(of: 3) ? "swift" : "md"
                let accent = index.isMultiple(of: 5) ? "caf\u{00E9}-" : ""
                _ = addFile(number: index, name: String(format: "File-%@%06d.%@", accent, index, suffix))
            }
        }

        mutating func addFolder(number: Int, name: String) -> WorkspaceFolderRecord {
            let folder = WorkspaceFolderRecord(
                id: Self.id(number),
                rootID: root.id,
                name: name,
                relativePath: "Sources/" + name,
                fullPath: root.fullPath + "/Sources/" + name,
                parentFolderID: parentID
            )
            folders[folder.id] = folder
            folderIDsByPath[folder.standardizedRelativePath] = folder.id
            return folder
        }

        mutating func addFile(number: Int, name: String, parentID: UUID? = nil) -> WorkspaceFileRecord {
            let parent = folders[parentID ?? self.parentID]!
            let file = WorkspaceFileRecord(
                id: Self.id(1000 + number),
                rootID: root.id,
                name: name,
                relativePath: parent.standardizedRelativePath + "/" + name,
                fullPath: parent.fullPath + "/" + name,
                parentFolderID: parent.id,
                modificationDate: Date(timeIntervalSinceReferenceDate: 1)
            )
            files[file.id] = file
            fileIDsByPath[file.standardizedRelativePath] = file.id
            return file
        }

        mutating func removeFile(_ file: WorkspaceFileRecord) {
            files.removeValue(forKey: file.id)
            fileIDsByPath.removeValue(forKey: file.standardizedRelativePath)
        }

        func event(
            generation: UInt64 = 1,
            upsertedFiles: [WorkspaceFileRecord] = [],
            upsertedFolders: [WorkspaceFolderRecord] = [],
            removedFileIDs: [UUID] = [],
            removedFolderIDs: [UUID] = [],
            removedFilePaths: [String] = [],
            removedFolderPaths: [String] = [],
            modifiedFileIDs: [UUID] = [],
            modifiedFolderIDs: [UUID] = []
        ) -> WorkspaceAppliedIndexBatchEvent {
            WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: generation,
                upsertedFiles: upsertedFiles,
                upsertedFolders: upsertedFolders,
                removedFileIDs: removedFileIDs,
                removedFolderIDs: removedFolderIDs,
                removedFilePaths: removedFilePaths,
                removedFolderPaths: removedFolderPaths,
                modifiedFileIDs: modifiedFileIDs,
                modifiedFolderIDs: modifiedFolderIDs
            )
        }

        func authoritative(generation: UInt64 = 0, requiresPathIndexes: Bool = true) -> WorkspaceFileContextStore.RootCatalogShardComparisonView {
            WorkspaceFileContextStore.authoritativeRootCatalogShardForTesting(
                root: root, lifetimeID: lifetimeID, topologyGeneration: 1, appliedIndexGeneration: generation,
                filesByID: files, foldersByID: folders, managedOnlyFileIDs: managedOnlyFileIDs,
                requiresPathIndexes: requiresPathIndexes
            )
        }

        func patch(_ old: WorkspaceFileContextStore.RootCatalogShardComparisonView, event: WorkspaceAppliedIndexBatchEvent)
            -> (shard: WorkspaceFileContextStore.RootCatalogShardComparisonView, logicalMutationCount: Int, changedFileIDs: Set<UUID>)?
        {
            WorkspaceFileContextStore.patchedRootCatalogShardForTesting(
                previous: old, root: root, event: event, filesByID: files, foldersByID: folders,
                fileIDsByPath: fileIDsByPath, folderIDsByPath: folderIDsByPath,
                managedOnlyFileIDs: managedOnlyFileIDs
            )
        }
    }

    private func catalogFileBytes(_ file: WorkspaceFileRecord) -> [[UInt8]] {
        [
            file.id.uuidString,
            file.rootID.uuidString,
            file.name,
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath,
            file.parentFolderID?.uuidString ?? "nil",
            file.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"
        ].map { Array($0.utf8) }
    }

    private func catalogFolderBytes(_ folder: WorkspaceFolderRecord) -> [[UInt8]] {
        [
            folder.id.uuidString,
            folder.rootID.uuidString,
            folder.name,
            folder.relativePath,
            folder.standardizedRelativePath,
            folder.fullPath,
            folder.standardizedFullPath,
            folder.parentFolderID?.uuidString ?? "nil",
            folder.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"
        ].map { Array($0.utf8) }
    }

    private func catalogEntryBytes(_ entry: WorkspaceSearchCatalogEntry) -> [[UInt8]] {
        [
            entry.id.uuidString,
            entry.rootID.uuidString,
            entry.rootName,
            entry.rootPath,
            entry.name,
            entry.relativePath,
            entry.standardizedRelativePath,
            entry.fullPath,
            entry.standardizedFullPath,
            entry.displayPath
        ].map { Array($0.utf8) }
    }

    private func assertCatalogParity(
        _ actual: WorkspaceFileContextStore.RootCatalogShardComparisonView,
        _ expected: WorkspaceFileContextStore.RootCatalogShardComparisonView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.files.count, expected.files.count, file: file, line: line)
        for (lhs, rhs) in zip(actual.files, expected.files) {
            XCTAssertEqual(catalogFileBytes(lhs), catalogFileBytes(rhs), file: file, line: line)
        }
        XCTAssertEqual(actual.folders.count, expected.folders.count, file: file, line: line)
        for (lhs, rhs) in zip(actual.folders, expected.folders) {
            XCTAssertEqual(catalogFolderBytes(lhs), catalogFolderBytes(rhs), file: file, line: line)
        }
        XCTAssertEqual(actual.entries.count, expected.entries.count, file: file, line: line)
        for (lhs, rhs) in zip(actual.entries, expected.entries) {
            XCTAssertEqual(catalogEntryBytes(lhs), catalogEntryBytes(rhs), file: file, line: line)
        }
        XCTAssertEqual(actual.projectionFiles.count, expected.projectionFiles.count, file: file, line: line)
        for (lhs, rhs) in zip(actual.projectionFiles, expected.projectionFiles) {
            XCTAssertEqual(catalogFileBytes(lhs), catalogFileBytes(rhs), file: file, line: line)
        }
        XCTAssertEqual(actual.projectionLanguages.map { Array($0.utf8) }, expected.projectionLanguages.map { Array($0.utf8) }, file: file, line: line)
        XCTAssertEqual(actual.projectionFileIndexByID, expected.projectionFileIndexByID, file: file, line: line)
        XCTAssertEqual(actual.appliedIndexGeneration, expected.appliedIndexGeneration, file: file, line: line)
        for query in ["File", "Sources File", "caf\u{00E9}", "cafe\u{0301}", "*.swift", "New", "Overlay", "Match", "Gone", "/catalog-delta/Sources", "missing", ""] {
            for limit in [0, 1, 7, actual.files.count + 1] {
                let lhs = actual.pathSearchIndex?.search(query, limit: limit) ?? []
                let rhs = expected.pathSearchIndex?.search(query, limit: limit) ?? []
                XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
                for (a, b) in zip(lhs, rhs) {
                    XCTAssertEqual(catalogEntryBytes(a.entry), catalogEntryBytes(b.entry), file: file, line: line)
                    XCTAssertEqual(a.score, b.score, file: file, line: line)
                    XCTAssertEqual(Array(a.tieBreakKey.utf8), Array(b.tieBreakKey.utf8), file: file, line: line)
                }
            }
        }
    }
#endif
