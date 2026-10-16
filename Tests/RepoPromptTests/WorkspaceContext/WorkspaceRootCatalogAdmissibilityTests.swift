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
        _ = try await store?.loadRoot(path: url.path)
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
