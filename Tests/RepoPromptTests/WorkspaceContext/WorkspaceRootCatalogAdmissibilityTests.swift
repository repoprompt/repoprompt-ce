@testable import RepoPromptApp
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
