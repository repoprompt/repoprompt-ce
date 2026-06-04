@testable import RepoPrompt
import XCTest

final class WorkspaceFileContextStoreTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testRootLoadIndexesFilesFoldersReadsContentAndLooksUpPaths() async throws {
        let rootA = try makeTemporaryRoot(name: "RootA")
        let rootB = try makeTemporaryRoot(name: "RootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/A.swift"))
        try write("beta", to: rootA.appendingPathComponent("Sources/Nested/B.swift"))
        try write("from A", to: rootA.appendingPathComponent("shared/file.txt"))
        try write("from B", to: rootB.appendingPathComponent("shared/file.txt"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)

        let files = await store.files(inRoot: recordA.id)
        let folders = await store.folders(inRoot: recordA.id)

        XCTAssertEqual(Set(files.map(\.standardizedRelativePath)), [
            "Sources/A.swift",
            "Sources/Nested/B.swift",
            "shared/file.txt"
        ])
        XCTAssertTrue(folders.contains { $0.standardizedRelativePath == "Sources" })
        XCTAssertTrue(folders.contains { $0.standardizedRelativePath == "Sources/Nested" })

        let content = try await store.readContent(rootID: recordA.id, relativePath: "Sources/../Sources/A.swift")
        XCTAssertEqual(content, "alpha")

        let absoluteB = rootB.appendingPathComponent("shared/file.txt").path
        let lookupB = await store.lookupPath(absoluteB)
        XCTAssertEqual(lookupB?.file?.rootID, recordB.id)
        XCTAssertEqual(lookupB?.file?.standardizedRelativePath, "shared/file.txt")

        let scopedA = await store.lookupPath(rootID: recordA.id, relativePath: "./shared/file.txt")
        XCTAssertEqual(scopedA?.file?.rootID, recordA.id)
        XCTAssertEqual(scopedA?.location.absolutePath, rootA.appendingPathComponent("shared/file.txt").path)
    }

    func testResolvedClipboardPackagingRendersStoreCodemaps() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedClipboard")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A { func fullContent() {} }", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileURL.path))
        ])

        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileURL.path],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )
        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .selected)
        let codemapSnapshots = await store.codemapSnapshotDictionary()

        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Summarize",
            files: resolution.entries,
            fileTreeContent: nil,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .relative,
            codemapSnapshots: codemapSnapshots,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        XCTAssertTrue(clipboard.contains("<file_map>"))
        XCTAssertTrue(clipboard.contains("File: A.swift"))
        XCTAssertTrue(clipboard.contains("codemapOnlySymbol"))
        XCTAssertFalse(clipboard.contains("<file_contents>"))
        XCTAssertFalse(clipboard.contains("fullContent"))
    }

    func testWatcherReplayAppliesAddRemoveModifyAndFolderRemoveEvents() async throws {
        let root = try makeTemporaryRoot(name: "WatcherReplay")
        try write("old", to: root.appendingPathComponent("Existing.swift"))
        try write("nested", to: root.appendingPathComponent("Gone/Nested.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        var events = await store.appliedIndexEvents().makeAsyncIterator()

        try write("new", to: root.appendingPathComponent("Added.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Added.swift")])
        var event = await events.next()
        XCTAssertEqual(event?.upsertedFiles.map(\.standardizedRelativePath), ["Added.swift"])
        let addedFile = await store.file(rootID: record.id, relativePath: "Added.swift")
        XCTAssertNotNil(addedFile)

        let existingURL = root.appendingPathComponent("Existing.swift")
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: existingURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: existingURL.path))
        ])
        let initialCodemap = await store.codemapSnapshot(rootID: record.id, relativePath: "Existing.swift")
        XCTAssertNotNil(initialCodemap)
        try write("new", to: existingURL)
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileModified("Existing.swift", Date())])
        event = await events.next()
        XCTAssertEqual(event?.modifiedFileIDs.count, 1)
        let invalidatedCodemap = await store.codemapSnapshot(rootID: record.id, relativePath: "Existing.swift")
        XCTAssertNil(invalidatedCodemap)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Added.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileRemoved("Added.swift")])
        event = await events.next()
        XCTAssertEqual(event?.removedFilePaths, ["Added.swift"])
        let removedFile = await store.file(rootID: record.id, relativePath: "Added.swift")
        XCTAssertNil(removedFile)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderRemoved("Gone")])
        event = await events.next()
        XCTAssertEqual(event?.removedFolderPaths, ["Gone"])
        XCTAssertEqual(event?.removedFilePaths, ["Gone/Nested.swift"])
        let removedFolder = await store.folder(rootID: record.id, relativePath: "Gone")
        let removedNestedFile = await store.file(rootID: record.id, relativePath: "Gone/Nested.swift")
        XCTAssertNil(removedFolder)
        XCTAssertNil(removedNestedFile)
    }

    func testWatcherReplayDuplicateDeltasAreIdempotent() async throws {
        let root = try makeTemporaryRoot(name: "DuplicateDeltas")
        try write("content", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("A.swift"), .fileAdded("A.swift")])
        let files = await store.files(inRoot: record.id)
        XCTAssertEqual(files.count(where: { $0.standardizedRelativePath == "A.swift" }), 1)
    }

    #if DEBUG
        func testSearchCatalogSnapshotCacheReusesUnchangedScopeAndPreservesOrderingDiagnostics() async throws {
            let rootA = try makeTemporaryRoot(name: "SearchSnapshotReuseA")
            let rootB = try makeTemporaryRoot(name: "SearchSnapshotReuseB")
            try write("b", to: rootA.appendingPathComponent("Nested/B.swift"))
            try write("a", to: rootA.appendingPathComponent("A.swift"))
            try write("c", to: rootB.appendingPathComponent("C.swift"))

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: rootA.path)
            _ = try await store.loadRoot(path: rootB.path)
            startSearchCatalogSnapshotCapture(label: "snapshot-reuse")
            defer { EditFlowPerf.resetDebugCaptureForTesting() }

            let cold = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let warm = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let buckets = searchCatalogSnapshotBuckets(capture)

            XCTAssertEqual(warm, cold)
            XCTAssertEqual(cold.entries.map(\.standardizedFullPath), cold.entries.map(\.standardizedFullPath).sorted())
            XCTAssertEqual(cold.diagnostics.rootScope, .visibleWorkspace)
            XCTAssertEqual(cold.diagnostics.rootCount, 2)
            XCTAssertEqual(cold.diagnostics.folderCount, 3)
            XCTAssertEqual(cold.diagnostics.fileCount, 3)
            XCTAssertEqual(buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=false") })?.sampleCount, 1)
            XCTAssertEqual(buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=true") })?.sampleCount, 1)
            XCTAssertEqual(capture.droppedSampleCount, 0)
        }
    #endif

    func testSearchCatalogSnapshotCacheInvalidatesAcrossAddRemoveMoveAndRootLifecycle() async throws {
        let rootA = try makeTemporaryRoot(name: "SearchSnapshotLifecycleA")
        let rootB = try makeTemporaryRoot(name: "SearchSnapshotLifecycleB")
        try write("seed", to: rootA.appendingPathComponent("Seed.swift"))
        try write("other", to: rootB.appendingPathComponent("Other.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        try write("added", to: rootA.appendingPathComponent("Added.swift"))
        await store.replayObservedFileSystemDeltas(rootID: recordA.id, deltas: [.fileAdded("Added.swift")])
        var snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["Added.swift", "Seed.swift"])

        try await store.moveFile(rootID: recordA.id, from: "Added.swift", to: "Moved.swift")
        snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["Moved.swift", "Seed.swift"])

        try FileManager.default.removeItem(at: rootA.appendingPathComponent("Moved.swift"))
        await store.replayObservedFileSystemDeltas(rootID: recordA.id, deltas: [.fileRemoved("Moved.swift")])
        snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Seed.swift"])

        let recordB = try await store.loadRoot(path: rootB.path)
        snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["Other.swift", "Seed.swift"])

        await store.unloadRoot(id: recordB.id)
        snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Seed.swift"])
    }

    #if DEBUG
        func testSearchCatalogSnapshotCacheClearsImmediatelyWhenRootUnloadDetachesBeforeAwaitedTeardown() async throws {
            let retainedRoot = try makeTemporaryRoot(name: "SearchSnapshotRetainedDuringUnload")
            let detachedRoot = try makeTemporaryRoot(name: "SearchSnapshotDetachedDuringUnload")
            try write("retained", to: retainedRoot.appendingPathComponent("Retained.swift"))
            try write("detached", to: detachedRoot.appendingPathComponent("Detached.swift"))

            let store = WorkspaceFileContextStore()
            let retainedRecord = try await store.loadRoot(path: retainedRoot.path)
            let detachedRecord = try await store.loadRoot(path: detachedRoot.path)
            let warm = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(Set(warm.roots.map(\.id)), [retainedRecord.id, detachedRecord.id])
            XCTAssertEqual(Set(warm.files.map(\.standardizedRelativePath)), ["Detached.swift", "Retained.swift"])

            let unloadGate = AsyncGate()
            await store.setRootUnloadDidDetachHandler { _ in
                await unloadGate.markStartedAndWaitForRelease()
            }
            let unloadTask = Task {
                await store.unloadRoot(id: detachedRecord.id)
            }
            await unloadGate.waitUntilStarted()

            let suspended = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(suspended.roots.map(\.id), [retainedRecord.id])
            XCTAssertEqual(suspended.files.map(\.standardizedRelativePath), ["Retained.swift"])

            await unloadGate.release()
            await unloadTask.value
            await store.setRootUnloadDidDetachHandler(nil)
            let completed = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(completed.roots.map(\.id), suspended.roots.map(\.id))
            XCTAssertEqual(completed.files.map(\.standardizedFullPath), suspended.files.map(\.standardizedFullPath))
        }
    #endif

    func testEnsureIndexedFilesClearsWarmSearchSnapshotAcrossMultipleLateFiles() async throws {
        let root = try makeTemporaryRoot(name: "SearchSnapshotEnsureIndexedMultiple")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        let lateA = root.appendingPathComponent("LateA.swift")
        let lateB = root.appendingPathComponent("Nested/LateB.swift")
        try write("a", to: lateA)
        try write("b", to: lateB)
        let indexed = await store.ensureIndexedFiles(paths: [lateA.path, lateB.path])
        XCTAssertEqual(indexed, [lateA.path, lateB.path])

        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["LateA.swift", "Nested/LateB.swift", "Seed.swift"])
    }

    #if DEBUG
        func testEnsureIndexedFilesSkipsEligibleFileWhenRootUnloadsDuringEligibilitySuspension() async throws {
            let root = try makeTemporaryRoot(name: "EnsureIndexedUnloadDuringEligibility")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let lateURL = root.appendingPathComponent("Late.swift")
            try write("late", to: lateURL)

            let eligibilityGate = AsyncGate()
            let recordID = record.id
            let latePath = lateURL.path
            await store.setEnsureIndexedFilesEligibilityDidResolveHandler { rootID, fullPath in
                guard rootID == recordID, fullPath == latePath else { return }
                await eligibilityGate.markStartedAndWaitForRelease()
            }
            let ensureTask = Task {
                await store.ensureIndexedFiles(paths: [latePath])
            }
            await eligibilityGate.waitUntilStarted()

            await store.unloadRoot(id: recordID)
            await eligibilityGate.release()
            let indexed = await ensureTask.value
            await store.setEnsureIndexedFilesEligibilityDidResolveHandler(nil)

            XCTAssertTrue(indexed.isEmpty)
            let roots = await store.roots()
            XCTAssertTrue(roots.isEmpty)
            let rootRecords = await store.rootRecords(forRootFolderPaths: [root.path])
            XCTAssertTrue(rootRecords.isEmpty)
            let lateFile = await store.file(rootID: recordID, relativePath: "Late.swift")
            XCTAssertNil(lateFile)
            let exactLookup = await store.lookupPath(rootID: recordID, relativePath: "Late.swift")
            XCTAssertNil(exactLookup)
            let snapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertFalse(snapshot.roots.contains { $0.id == recordID })
            XCTAssertFalse(snapshot.files.contains { $0.standardizedFullPath == latePath })
        }

        func testEnsureIndexedFilesPreservesConcurrentRootLocalMutationDuringEligibilitySuspension() async throws {
            let root = try makeTemporaryRoot(name: "EnsureIndexedConcurrentMutation")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let targetURL = root.appendingPathComponent("Target.swift")
            let concurrentURL = root.appendingPathComponent("Nested/Concurrent.swift")
            try write("target", to: targetURL)
            try write("concurrent", to: concurrentURL)

            let eligibilityGate = AsyncGate()
            let recordID = record.id
            let targetPath = targetURL.path
            await store.setEnsureIndexedFilesEligibilityDidResolveHandler { rootID, fullPath in
                guard rootID == recordID, fullPath == targetPath else { return }
                await eligibilityGate.markStartedAndWaitForRelease()
            }
            let targetTask = Task {
                await store.ensureIndexedFiles(paths: [targetPath])
            }
            await eligibilityGate.waitUntilStarted()

            let concurrentIndexed = await store.ensureIndexedFiles(paths: [concurrentURL.path])
            XCTAssertEqual(concurrentIndexed, [concurrentURL.path])
            await eligibilityGate.release()
            let targetIndexed = await targetTask.value
            await store.setEnsureIndexedFilesEligibilityDidResolveHandler(nil)

            XCTAssertEqual(targetIndexed, [targetPath])
            let targetFile = await store.file(rootID: recordID, relativePath: "Target.swift")
            XCTAssertNotNil(targetFile)
            let concurrentFile = await store.file(rootID: recordID, relativePath: "Nested/Concurrent.swift")
            XCTAssertNotNil(concurrentFile)
            let files = await store.files(inRoot: recordID)
            XCTAssertEqual(files.map(\.standardizedRelativePath), ["Nested/Concurrent.swift", "Seed.swift", "Target.swift"])
            let snapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["Nested/Concurrent.swift", "Seed.swift", "Target.swift"])

            let rootChildrenSnapshot = await store.directFolderChildren(rootID: recordID)
            let rootChildren = try XCTUnwrap(rootChildrenSnapshot)
            XCTAssertEqual(rootChildren.childFolders.map(\.standardizedRelativePath), ["Nested"])
            XCTAssertEqual(rootChildren.childFiles.map(\.standardizedRelativePath), ["Seed.swift", "Target.swift"])
            let nestedChildrenSnapshot = await store.directFolderChildren(rootID: recordID, relativePath: "Nested")
            let nestedChildren = try XCTUnwrap(nestedChildrenSnapshot)
            XCTAssertEqual(nestedChildren.childFiles.map(\.standardizedRelativePath), ["Nested/Concurrent.swift"])
        }
    #endif

    func testSearchCatalogSnapshotCacheKeepsManagedOnlyIgnoredFileHiddenAndReflectsPromotion() async throws {
        let root = try makeTemporaryRoot(name: "SearchSnapshotManagedOnlyPromotion")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        try await host.writeText(path: "Hidden.ignored", content: "hidden", overwrite: false)
        var snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let hiddenRecord = await store.file(rootID: record.id, relativePath: "Hidden.ignored")
        XCTAssertNotNil(hiddenRecord)
        XCTAssertFalse(snapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" })
        let warmHiddenSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(warmHiddenSnapshot, snapshot)

        try await store.moveFile(rootID: record.id, from: "Hidden.ignored", to: "Visible.md")
        snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertTrue(snapshot.files.contains { $0.standardizedRelativePath == "Visible.md" })
        XCTAssertFalse(snapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" })
    }

    func testSearchCatalogSnapshotCacheSeparatesStaticScopes() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "SearchSnapshotVisible")
        let gitDataRoot = try makeTemporaryRoot(name: "SearchSnapshotGitData")
        let supplementalRoot = try makeTemporaryRoot(name: "SearchSnapshotSupplemental")
        try write("visible", to: visibleRoot.appendingPathComponent("Visible.swift"))
        try write("git", to: gitDataRoot.appendingPathComponent("GitData.swift"))
        try write("system", to: supplementalRoot.appendingPathComponent("System.swift"))

        let store = WorkspaceFileContextStore()
        let visible = try await store.loadRoot(path: visibleRoot.path)
        let gitData = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let supplemental = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)

        let visibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let gitDataSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
        let allLoadedSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
        XCTAssertEqual(visibleSnapshot.roots.map(\.id), [visible.id])
        XCTAssertEqual(gitDataSnapshot.roots.map(\.id), [visible.id, gitData.id])
        XCTAssertEqual(allLoadedSnapshot.roots.map(\.id), [visible.id, gitData.id, supplemental.id])
        let warmVisibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let warmGitDataSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
        let warmAllLoadedSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
        XCTAssertEqual(warmVisibleSnapshot, visibleSnapshot)
        XCTAssertEqual(warmGitDataSnapshot, gitDataSnapshot)
        XCTAssertEqual(warmAllLoadedSnapshot, allLoadedSnapshot)
    }

    func testSearchCatalogSnapshotCacheSeparatesSessionBoundScopesAndInvalidatesWorktreeChanges() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "SearchSnapshotLogical")
        let worktreeA = try makeTemporaryRoot(name: "SearchSnapshotWorktreeA")
        let worktreeB = try makeTemporaryRoot(name: "SearchSnapshotWorktreeB")
        try write("logical", to: logicalRoot.appendingPathComponent("Logical.swift"))
        try write("a", to: worktreeA.appendingPathComponent("A.swift"))
        try write("b", to: worktreeB.appendingPathComponent("B.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let recordA = try await store.loadRoot(path: worktreeA.path, kind: .sessionWorktree)
        let recordB = try await store.loadRoot(path: worktreeB.path, kind: .sessionWorktree)
        let scopeA = WorkspaceLookupRootScope.sessionBoundWorkspace(logicalRootPaths: [logicalRoot.path], physicalRootPaths: [worktreeA.path])
        let scopeB = WorkspaceLookupRootScope.sessionBoundWorkspace(logicalRootPaths: [logicalRoot.path], physicalRootPaths: [worktreeB.path])

        let initialA = await store.searchCatalogSnapshot(rootScope: scopeA)
        let initialB = await store.searchCatalogSnapshot(rootScope: scopeB)
        XCTAssertEqual(initialA.roots.map(\.id), [recordA.id])
        XCTAssertEqual(initialB.roots.map(\.id), [recordB.id])
        let warmA = await store.searchCatalogSnapshot(rootScope: scopeA)
        let warmB = await store.searchCatalogSnapshot(rootScope: scopeB)
        XCTAssertEqual(warmA, initialA)
        XCTAssertEqual(warmB, initialB)

        try write("added", to: worktreeA.appendingPathComponent("Added.swift"))
        await store.replayObservedFileSystemDeltas(rootID: recordA.id, deltas: [.fileAdded("Added.swift")])
        let changedA = await store.searchCatalogSnapshot(rootScope: scopeA)
        let unchangedB = await store.searchCatalogSnapshot(rootScope: scopeB)
        XCTAssertEqual(changedA.generation, initialA.generation)
        XCTAssertEqual(Set(changedA.files.map(\.standardizedRelativePath)), ["A.swift", "Added.swift"])
        XCTAssertEqual(unchangedB.files.map(\.standardizedRelativePath), ["B.swift"])
    }

    #if DEBUG
        func testSearchCatalogSnapshotCacheClearsBeforeSeventeenthScopeInsert() async {
            let store = WorkspaceFileContextStore()
            let scopes = (0 ... 16).map { index in
                WorkspaceLookupRootScope.sessionBoundWorkspace(
                    logicalRootPaths: ["/logical/\(index)"],
                    physicalRootPaths: ["/physical/\(index)"]
                )
            }
            startSearchCatalogSnapshotCapture(label: "snapshot-cap")
            defer { EditFlowPerf.resetDebugCaptureForTesting() }

            for scope in scopes.prefix(16) {
                _ = await store.searchCatalogSnapshot(rootScope: scope)
            }
            _ = await store.searchCatalogSnapshot(rootScope: scopes[0])
            _ = await store.searchCatalogSnapshot(rootScope: scopes[16])
            _ = await store.searchCatalogSnapshot(rootScope: scopes[0])

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let buckets = searchCatalogSnapshotBuckets(capture)
            XCTAssertEqual(buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=false") })?.sampleCount, 18)
            XCTAssertEqual(buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=true") })?.sampleCount, 1)
            XCTAssertEqual(capture.retainedSampleCount, 19)
            XCTAssertEqual(capture.droppedSampleCount, 0)
        }
    #endif

    func testFileTreeSnapshotSupportsFoldersOnlyMode() async throws {
        let root = try makeTemporaryRoot(name: "FoldersOnlyTree")
        let selectedURL = root.appendingPathComponent("Sources/Selected.swift")
        try write("selected", to: selectedURL)
        try write("other", to: root.appendingPathComponent("Sources/Other.swift"))
        try write("readme", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)

        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(selectedPaths: [selectedURL.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: false),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .folders,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        let tree = CodeMapExtractor.generateFileTree(using: snapshot)

        XCTAssertTrue(tree.contains("Sources"))
        XCTAssertTrue(tree.contains("Selected.swift *"))
        XCTAssertFalse(tree.contains("Other.swift"))
        XCTAssertFalse(tree.contains("README.md"))
    }

    func testFileTreeSnapshotHonorsExplicitMaxDepth() async throws {
        let root = try makeTemporaryRoot(name: "MaxDepthTree")
        try write("deep", to: root.appendingPathComponent("Sources/Deep/Deep.swift"))
        try write("top", to: root.appendingPathComponent("Top.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)

        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace,
                maxDepth: 1
            ),
            profile: .mcpRead
        )
        let tree = CodeMapExtractor.generateFileTree(using: snapshot)

        XCTAssertTrue(tree.contains("Sources"))
        XCTAssertTrue(tree.contains("Top.swift"))
        XCTAssertTrue(tree.contains("..."))
        XCTAssertFalse(tree.contains("Deep.swift"))
    }

    func testFileTreeSnapshotCanStartAtResolvedSubtree() async throws {
        let root = try makeTemporaryRoot(name: "SubtreeTree")
        try write("a", to: root.appendingPathComponent("Sources/A.swift"))
        try write("b", to: root.appendingPathComponent("Sources/Nested/B.swift"))
        try write("other", to: root.appendingPathComponent("Other.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)

        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace,
                startPath: "Sources"
            ),
            profile: .mcpRead
        )
        let tree = CodeMapExtractor.generateFileTree(using: snapshot)

        XCTAssertEqual(snapshot.roots.count, 1)
        XCTAssertTrue(tree.contains("Sources"))
        XCTAssertTrue(tree.contains("A.swift"))
        XCTAssertTrue(tree.contains("Nested"))
        XCTAssertTrue(tree.contains("B.swift"))
        XCTAssertFalse(tree.contains("Other.swift"))
    }

    func testValuePathResolutionReportsAmbiguousRelativePathWithExistingRendererMessage() async throws {
        let parentA = try makeTemporaryRoot(name: "AmbiguousParentA")
        let parentB = try makeTemporaryRoot(name: "AmbiguousParentB")
        let rootA = parentA.appendingPathComponent("SharedRoot", isDirectory: true)
        let rootB = parentB.appendingPathComponent("SharedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try write("a", to: rootA.appendingPathComponent("Sources/A.swift"))
        try write("b", to: rootB.appendingPathComponent("Sources/A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)

        let maybeIssue = await store.exactPathResolutionIssue(for: "Sources/A.swift", kind: .file, rootScope: .visibleWorkspace)
        let issue = try XCTUnwrap(maybeIssue)
        let message = PathResolutionIssueRenderer.message(for: issue)
        XCTAssertTrue(message.contains("matches multiple workspace roots"))
        XCTAssertTrue(message.contains("SharedRoot"))
    }

    func testFolderExpansionAndSelectionMutationServiceAreDeterministicByRelativePath() async throws {
        let root = try makeTemporaryRoot(name: "SelectionMutation")
        try write("b", to: root.appendingPathComponent("Sources/B.swift"))
        try write("a", to: root.appendingPathComponent("Sources/Nested/A.swift"))
        try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)

        let expansion = await store.expandFolderInputToFiles("Sources", rootScope: .visibleWorkspace)
        XCTAssertTrue(expansion.handled)
        XCTAssertEqual(expansion.files.map(\.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])

        let addResult = await service.addPaths(
            existing: StoredSelection(),
            paths: ["Sources"],
            rawPaths: ["Sources"],
            mode: "full",
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(addResult.mutated)
        XCTAssertEqual(addResult.selection.selectedPaths, expansion.files.map(\.standardizedFullPath))
        XCTAssertEqual(addResult.resolvedMap["Sources"], "Sources")
    }

    func testCodemapOnlyCandidateFilteringPreservesUnsupportedMessages() async throws {
        let root = try makeTemporaryRoot(name: "CodemapFiltering")
        try write("struct A {}", to: root.appendingPathComponent("Sources/A.swift"))
        try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)

        let fileOnly = await service.resolveCodemapOnlyCandidates(
            paths: ["Sources/notes.txt"],
            rawPaths: ["Sources/notes.txt"],
            expandFolders: true,
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(fileOnly.candidates.isEmpty)
        XCTAssertEqual(fileOnly.codemapUnavailable, ["codemap unavailable: Sources/notes.txt"])

        let folder = await service.resolveCodemapOnlyCandidates(
            paths: ["Sources"],
            rawPaths: ["Sources"],
            expandFolders: true,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(folder.candidates.map(\.standardizedRelativePath), ["Sources/A.swift"])
        XCTAssertEqual(folder.codemapUnavailable, ["codemap unavailable: 1 file(s) in Sources skipped (unsupported)"])
    }

    func testSelectionMutationPromoteDemoteAndRemoveOperateOnStoredSelectionValues() async throws {
        let root = try makeTemporaryRoot(name: "PromoteDemote")
        let swiftURL = root.appendingPathComponent("A.swift")
        let textURL = root.appendingPathComponent("notes.txt")
        try write("struct A {}", to: swiftURL)
        try write("notes", to: textURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(
            selectedPaths: [swiftURL.path, textURL.path],
            autoCodemapPaths: [],
            slices: [swiftURL.path: [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: true
        )

        let demoted = await service.demotePaths(existing: initial, paths: [swiftURL.path, textURL.path], rawPaths: [swiftURL.path, textURL.path])
        XCTAssertTrue(demoted.mutated)
        XCTAssertEqual(demoted.selection.selectedPaths, [textURL.path])
        XCTAssertEqual(demoted.selection.autoCodemapPaths, [swiftURL.path])
        XCTAssertTrue(demoted.selection.slices.isEmpty)
        XCTAssertEqual(demoted.codemapUnavailable, ["codemap unavailable: notes.txt"])
        XCTAssertFalse(demoted.selection.codemapAutoEnabled)

        let promoted = await service.promotePaths(existing: demoted.selection, paths: [swiftURL.path], rawPaths: [swiftURL.path])
        XCTAssertTrue(promoted.mutated)
        XCTAssertEqual(Set(promoted.selection.selectedPaths), Set([swiftURL.path, textURL.path]))
        XCTAssertTrue(promoted.selection.autoCodemapPaths.isEmpty)
        XCTAssertFalse(promoted.selection.codemapAutoEnabled)

        let removed = await service.removePaths(existing: promoted.selection, paths: [swiftURL.path], rawPaths: [swiftURL.path])
        XCTAssertTrue(removed.mutated)
        XCTAssertEqual(removed.selection.selectedPaths, [textURL.path])
    }

    func testManageSelectionSliceSetPreservesFullFilesAndReplacesOnlySpecifiedSlices() async throws {
        let root = try makeTemporaryRoot(name: "SliceSetFileScoped")
        let fullURL = root.appendingPathComponent("Full.swift")
        let firstURL = root.appendingPathComponent("A.swift")
        let secondURL = root.appendingPathComponent("B.swift")
        try write("struct Full {}", to: fullURL)
        try write("a1\na2\na3\na4", to: firstURL)
        try write("b1\nb2\nb3\nb4\nb5\nb6", to: secondURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(
            selectedPaths: [fullURL.path],
            autoCodemapPaths: [],
            slices: [:],
            codemapAutoEnabled: false
        )

        let added = await service.buildManageSelectionSet(
            paths: [],
            slices: [
                WorkspaceSelectionSliceInput(path: firstURL.path, ranges: [LineRange(start: 1, end: 2)]),
                WorkspaceSelectionSliceInput(path: secondURL.path, ranges: [LineRange(start: 5, end: 6)])
            ],
            mode: "slices",
            existing: initial
        )

        XCTAssertTrue(added.invalidPaths.isEmpty)
        XCTAssertEqual(Set(added.selection.selectedPaths), Set([fullURL.path, firstURL.path, secondURL.path]))
        XCTAssertEqual(added.selection.slices[firstURL.path], [LineRange(start: 1, end: 2)])
        XCTAssertEqual(added.selection.slices[secondURL.path], [LineRange(start: 5, end: 6)])

        let replaced = await service.buildManageSelectionSet(
            paths: [],
            slices: [WorkspaceSelectionSliceInput(path: firstURL.path, ranges: [LineRange(start: 3, end: 4)])],
            mode: "slices",
            existing: added.selection
        )

        XCTAssertTrue(replaced.invalidPaths.isEmpty)
        XCTAssertEqual(Set(replaced.selection.selectedPaths), Set([fullURL.path, firstURL.path, secondURL.path]))
        XCTAssertNil(replaced.selection.slices[fullURL.path])
        XCTAssertEqual(replaced.selection.slices[firstURL.path], [LineRange(start: 3, end: 4)])
        XCTAssertEqual(replaced.selection.slices[secondURL.path], [LineRange(start: 5, end: 6)])
    }

    func testManageSelectionSliceSetRejectsInvalidRequestsWithoutMutation() async throws {
        let root = try makeTemporaryRoot(name: "SliceSetRejectsInvalid")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A {}", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(selectedPaths: [fileURL.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: false)

        let barePath = await service.buildManageSelectionSet(
            paths: [fileURL.path],
            slices: [],
            mode: "slices",
            existing: initial
        )
        XCTAssertEqual(barePath.selection, initial)
        XCTAssertEqual(barePath.invalidPaths, ["mode 'slices' requires line ranges for paths: \(fileURL.path). Use #L ranges, the slices array, or op='add' mode='full' for whole files."])

        let empty = await service.buildManageSelectionSet(
            paths: [],
            slices: [],
            mode: "slices",
            existing: initial
        )
        XCTAssertEqual(empty.selection, initial)
        XCTAssertEqual(empty.invalidPaths, ["mode 'slices' requires a non-empty slices array or #L line ranges on paths."])

        let parseFailure = await service.buildManageSelectionSet(
            paths: [],
            slices: [],
            sliceErrors: ["Invalid slice 'abc' for path 'A.swift#Labc'"],
            mode: "slices",
            existing: initial
        )
        XCTAssertEqual(parseFailure.selection, initial)
        XCTAssertEqual(parseFailure.invalidPaths, ["Invalid slice 'abc' for path 'A.swift#Labc'"])
    }

    func testManageSelectionMixedAddPreservesExistingFullFilesAndAddsSlices() async throws {
        let root = try makeTemporaryRoot(name: "MixedAddSafe")
        let existingURL = root.appendingPathComponent("A.swift")
        let addedFullURL = root.appendingPathComponent("B.swift")
        let addedSliceURL = root.appendingPathComponent("C.swift")
        try write("struct A {}", to: existingURL)
        try write("struct B {}", to: addedFullURL)
        try write("c1\nc2\nc3", to: addedSliceURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(selectedPaths: [existingURL.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: false)

        let addFull = await service.addPaths(
            existing: initial,
            paths: [addedFullURL.path],
            rawPaths: [addedFullURL.path],
            mode: "full"
        )
        let addSlice = await service.mutateSlices(
            base: addFull.selection,
            entries: [WorkspaceSelectionSliceInput(path: addedSliceURL.path, ranges: [LineRange(start: 1, end: 2)])],
            mode: .add
        )

        XCTAssertTrue(addFull.invalidPaths.isEmpty)
        XCTAssertTrue(addSlice.invalidPaths.isEmpty)
        XCTAssertEqual(addSlice.selection.selectedPaths, [existingURL.path, addedFullURL.path, addedSliceURL.path])
        XCTAssertEqual(addSlice.selection.slices[addedSliceURL.path], [LineRange(start: 1, end: 2)])
    }

    func testManageSelectionCodemapOnlySetRejectsSlices() async throws {
        let root = try makeTemporaryRoot(name: "CodemapOnlyRejectsSlices")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A {}", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(selectedPaths: [fileURL.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: false)

        let result = await service.buildManageSelectionSet(
            paths: [],
            slices: [WorkspaceSelectionSliceInput(path: fileURL.path, ranges: [LineRange(start: 1, end: 1)])],
            mode: "codemap_only",
            existing: initial
        )

        XCTAssertEqual(result.selection, initial)
        XCTAssertEqual(result.invalidPaths, ["mode 'codemap_only' cannot be used with slices"])
    }

    func testManageSelectionFullSetWithSlicesRemainsDestructive() async throws {
        let root = try makeTemporaryRoot(name: "FullSetDestructive")
        let oldFullURL = root.appendingPathComponent("OldFull.swift")
        let oldSliceURL = root.appendingPathComponent("OldSlice.swift")
        let newFullURL = root.appendingPathComponent("NewFull.swift")
        let newSliceURL = root.appendingPathComponent("NewSlice.swift")
        try write("old full", to: oldFullURL)
        try write("old1\nold2", to: oldSliceURL)
        try write("new full", to: newFullURL)
        try write("new1\nnew2\nnew3", to: newSliceURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(
            selectedPaths: [oldFullURL.path, oldSliceURL.path],
            autoCodemapPaths: [],
            slices: [oldSliceURL.path: [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: false
        )

        let result = await service.buildManageSelectionSet(
            paths: [newFullURL.path],
            slices: [WorkspaceSelectionSliceInput(path: newSliceURL.path, ranges: [LineRange(start: 2, end: 3)])],
            mode: "full",
            existing: initial
        )

        XCTAssertTrue(result.invalidPaths.isEmpty)
        XCTAssertEqual(result.selection.selectedPaths, [newFullURL.path, newSliceURL.path])
        XCTAssertEqual(result.selection.slices, [newSliceURL.path: [LineRange(start: 2, end: 3)]])
        XCTAssertFalse(result.selection.selectedPaths.contains(oldFullURL.path))
        XCTAssertNil(result.selection.slices[oldSliceURL.path])
    }

    func testCRUDAndRootUnloadPublishAppliedIndexEvents() async throws {
        let root = try makeTemporaryRoot(name: "CRUDEvents")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))
        try write("nested", to: root.appendingPathComponent("Folder/Nested.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        var events = await store.appliedIndexEvents().makeAsyncIterator()

        try await store.createFile(rootID: record.id, relativePath: "Created.swift", content: "created")
        var event = await events.next()
        XCTAssertEqual(event?.upsertedFiles.map(\.standardizedRelativePath), ["Created.swift"])

        try await store.editFile(rootID: record.id, relativePath: "Created.swift", newContent: "edited")
        event = await events.next()
        XCTAssertEqual(event?.modifiedFileIDs.count, 1)

        try await store.moveFile(rootID: record.id, from: "Created.swift", to: "Moved.swift")
        event = await events.next()
        XCTAssertEqual(event?.removedFilePaths, ["Created.swift"])
        XCTAssertEqual(event?.upsertedFiles.map(\.standardizedRelativePath), ["Moved.swift"])

        try await store.deleteFile(rootID: record.id, relativePath: "Moved.swift")
        event = await events.next()
        XCTAssertEqual(event?.removedFilePaths, ["Moved.swift"])

        try await store.moveItemToTrash(rootID: record.id, relativePath: "Folder")
        event = await events.next()
        XCTAssertEqual(event?.removedFolderPaths, ["Folder"])
        XCTAssertEqual(event?.removedFilePaths, ["Folder/Nested.swift"])

        await store.unloadRoot(id: record.id)
        event = await events.next()
        XCTAssertEqual(event?.rootID, record.id)
        XCTAssertEqual(event?.isRootUnload, true)
        XCTAssertEqual(event?.requiresFullResync, true)
    }

    func testBatchRootUnloadDeduplicatesIDsPublishesEventsAndClearsLoadedRoots() async throws {
        let rootA = try makeTemporaryRoot(name: "BatchUnloadDedupA")
        let rootB = try makeTemporaryRoot(name: "BatchUnloadDedupB")
        let rootC = try makeTemporaryRoot(name: "BatchUnloadDedupC")
        try write("a", to: rootA.appendingPathComponent("A.swift"))
        try write("b", to: rootB.appendingPathComponent("B.swift"))
        try write("c", to: rootC.appendingPathComponent("C.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let recordC = try await store.loadRoot(path: rootC.path)
        var events = await store.appliedIndexEvents().makeAsyncIterator()

        await store.unloadRoots(ids: [recordB.id, recordB.id, recordA.id])

        let maybeFirstEvent = await events.next()
        let maybeSecondEvent = await events.next()
        let firstEvent = try XCTUnwrap(maybeFirstEvent)
        let secondEvent = try XCTUnwrap(maybeSecondEvent)
        XCTAssertEqual([firstEvent.rootID, secondEvent.rootID], [recordB.id, recordA.id])
        XCTAssertTrue([firstEvent, secondEvent].allSatisfy(\.isRootUnload))
        XCTAssertTrue([firstEvent, secondEvent].allSatisfy(\.requiresFullResync))
        let remainingRoots = await store.roots()
        let fileAAfterUnload = await store.file(rootID: recordA.id, relativePath: "A.swift")
        let fileBAfterUnload = await store.file(rootID: recordB.id, relativePath: "B.swift")
        let fileCAfterUnload = await store.file(rootID: recordC.id, relativePath: "C.swift")
        XCTAssertEqual(remainingRoots.map(\.id), [recordC.id])
        XCTAssertNil(fileAAfterUnload)
        XCTAssertNil(fileBAfterUnload)
        XCTAssertNotNil(fileCAfterUnload)

        await store.unloadRoots(ids: [recordC.id])

        let maybeFinalEvent = await events.next()
        let finalEvent = try XCTUnwrap(maybeFinalEvent)
        XCTAssertEqual(finalEvent.rootID, recordC.id)
        XCTAssertTrue(finalEvent.isRootUnload)
        XCTAssertTrue(finalEvent.requiresFullResync)
        let rootsAfterFinalUnload = await store.roots()
        let fileCAfterFinalUnload = await store.file(rootID: recordC.id, relativePath: "C.swift")
        XCTAssertTrue(rootsAfterFinalUnload.isEmpty)
        XCTAssertNil(fileCAfterFinalUnload)
    }

    func testWorkspaceFileMutationServiceCreatesReadsAndOverwritesThroughStore() async throws {
        let root = try makeTemporaryRoot(name: "MutationService")
        try write("old", to: root.appendingPathComponent("Existing.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceFileMutationService(store: store)

        let created = try await service.createFile(
            userPath: "Created.swift",
            content: "created",
            rootScope: .visibleWorkspace,
            pathResolutionPolicy: .canonicalAliasFirst
        )
        XCTAssertEqual(created.standardizedRelativePath, "Created.swift")
        let createdStoreContent = try await store.readContent(rootID: record.id, relativePath: "Created.swift")
        XCTAssertEqual(createdStoreContent, "created")
        let createdServiceContent = try await service.readText(file: created)
        XCTAssertEqual(createdServiceContent, "created")

        let existing = try await service.resolveExactExistingFileForMutation("Existing.swift", rootScope: .visibleWorkspace)
        try await service.overwrite(file: existing, content: "new")
        let overwrittenContent = try await store.readContent(rootID: record.id, relativePath: "Existing.swift")
        XCTAssertEqual(overwrittenContent, "new")
        let exactExisting = await service.exactExistingFile("Existing.swift", rootScope: .visibleWorkspace)
        XCTAssertNotNil(exactExisting)
    }

    func testWorkspaceFileEditHostOverwriteCreatesMissingAndReplacesExisting() async throws {
        let root = try makeTemporaryRoot(name: "EditHostOverwrite")
        try write("old", to: root.appendingPathComponent("Existing.swift"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )

        try await host.writeText(path: "Missing.swift", content: "created", overwrite: true)
        let createdContent = try await store.readContent(rootID: record.id, relativePath: "Missing.swift")
        XCTAssertEqual(createdContent, "created")

        try await host.writeText(path: "Existing.swift", content: "new", overwrite: true)
        let overwrittenContent = try await store.readContent(rootID: record.id, relativePath: "Existing.swift")
        XCTAssertEqual(overwrittenContent, "new")
    }

    func testApplyEditsRewriteCreateImmediatelyMaterializesForStoreLookupAndRead() async throws {
        let root = try makeTemporaryRoot(name: "ApplyEditsCreatePostcondition")
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let service = ApplyEditsService(engine: .default, host: host)

        let request = ApplyEditsRequest(
            path: "Created.swift",
            mode: .rewrite(newText: "struct Created {}\n", onMissing: .create),
            verbose: false
        )
        let result = try await service.run(request)

        XCTAssertTrue(result.fileCreated)
        let createdFile = await store.file(rootID: record.id, relativePath: "Created.swift")
        let recordFromStore = try XCTUnwrap(createdFile)
        XCTAssertEqual(recordFromStore.standardizedRelativePath, "Created.swift")
        let createdContent = try await store.readContent(rootID: record.id, relativePath: "Created.swift")
        XCTAssertEqual(createdContent, "struct Created {}\n")
        let createdLookup = await store.lookupPath("Created.swift", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        XCTAssertNotNil(createdLookup)
        let lookupFiles = await store.lookupFiles(atPaths: ["Created.swift"], profile: .mcpRead, rootScope: .visibleWorkspace)
        XCTAssertEqual(lookupFiles["Created.swift"]?.id, recordFromStore.id)
    }

    func testIgnoredCreateRemainsExactlyManageableWithoutDiscoveryExposure() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredCreatePostcondition")
        try write("*.ignored\nignored/\n", to: root.appendingPathComponent(".gitignore"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )

        try await host.writeText(path: "secret.ignored", content: "ignored token", overwrite: false)
        try await host.writeText(path: "ignored/report.md", content: "nested ignored", overwrite: false)

        let ignoredURL = root.appendingPathComponent("secret.ignored")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredURL.path))
        let storedIgnoredFile = await store.file(rootID: record.id, relativePath: "secret.ignored")
        let ignoredFile = try XCTUnwrap(storedIgnoredFile)
        XCTAssertEqual(ignoredFile.standardizedFullPath, ignoredURL.path)

        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(readableFile) = readable else {
            return XCTFail("Ignored exact path should resolve as a workspace file")
        }
        XCTAssertEqual(readableFile.id, ignoredFile.id)

        let editService = ApplyEditsService(engine: .default, host: host)
        _ = try await editService.run(ApplyEditsRequest(
            path: "secret.ignored",
            mode: .single(search: "token", replace: "edited", replaceAll: false),
            verbose: false
        ))
        let editedContent = try await store.readContent(rootID: record.id, relativePath: "secret.ignored")
        XCTAssertEqual(editedContent, "ignored edited")

        let ignoredFuzzyLookup = await store.lookupPath("secret.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        let discoverableFiles = await store.files(inRoot: record.id)
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let rootChildren = await store.directFolderChildren(rootID: record.id)
        XCTAssertNil(ignoredFuzzyLookup)
        XCTAssertFalse(discoverableFiles.contains { $0.standardizedRelativePath == "secret.ignored" })
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "secret.ignored" })
        XCTAssertFalse(rootChildren?.childFiles.contains { $0.standardizedRelativePath == "secret.ignored" } ?? true)
        let ignoredFolderChildrenBeforeReplay = await store.directFolderChildren(rootID: record.id, relativePath: "ignored")
        XCTAssertNil(ignoredFolderChildrenBeforeReplay)
        let ignoredFolderExpansion = await store.expandFolderInputToFiles("ignored", rootScope: .visibleWorkspace)
        XCTAssertFalse(ignoredFolderExpansion.handled)
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderAdded("ignored")])
        let ignoredFolderChildrenAfterReplay = await store.directFolderChildren(rootID: record.id, relativePath: "ignored")
        XCTAssertNil(ignoredFolderChildrenAfterReplay)

        let treeSnapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        let tree = CodeMapExtractor.generateFileTree(using: treeSnapshot)
        XCTAssertFalse(tree.contains("secret.ignored"), tree)
        XCTAssertFalse(tree.contains("ignored"), tree)
        XCTAssertFalse(tree.contains("report.md"), tree)

        let selectedTreeSnapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(selectedPaths: [ignoredURL.path]),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .selected,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        let selectedTree = CodeMapExtractor.generateFileTree(using: selectedTreeSnapshot)
        XCTAssertTrue(selectedTree.contains("secret.ignored"), selectedTree)
        XCTAssertFalse(selectedTree.contains("report.md"), selectedTree)

        let ignoredSubtree = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace,
                startPath: "ignored"
            ),
            profile: .mcpRead
        )
        XCTAssertTrue(ignoredSubtree.roots.isEmpty)
    }

    func testVisibleSiblingPromotesManagedOnlyParentWithoutExposingIgnoredSibling() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredParentPromotion")
        try write("private/*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

        try await host.writeText(path: "private/secret.ignored", content: "hidden", overwrite: false)
        let hiddenParentChildren = await store.directFolderChildren(rootID: record.id, relativePath: "private")
        XCTAssertNil(hiddenParentChildren)
        try await host.writeText(path: "private/public.md", content: "visible", overwrite: false)

        let children = await store.directFolderChildren(rootID: record.id, relativePath: "private")
        XCTAssertEqual(children?.childFiles.map(\.standardizedRelativePath), ["private/public.md"])
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertTrue(searchSnapshot.files.contains { $0.standardizedRelativePath == "private/public.md" })
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "private/secret.ignored" })
    }

    func testExistingIgnoredFileMaterializesOnlyForExactReadAndEdit() async throws {
        let root = try makeTemporaryRoot(name: "ExistingIgnoredExact")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let ignoredURL = root.appendingPathComponent("existing.ignored")
        try write("old", to: ignoredURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let ignoredBeforeExactRead = await store.file(rootID: record.id, relativePath: "existing.ignored")
        XCTAssertNil(ignoredBeforeExactRead)

        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(file) = readable else {
            return XCTFail("Existing ignored exact path should materialize for read_file semantics")
        }
        XCTAssertEqual(file.standardizedFullPath, ignoredURL.path)

        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
        try await host.writeText(path: ignoredURL.path, content: "new", overwrite: true)
        let editedContent = try await store.readContent(rootID: record.id, relativePath: "existing.ignored")
        let fuzzyLookup = await store.lookupPath("existing.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(editedContent, "new")
        XCTAssertNil(fuzzyLookup)
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "existing.ignored" })
    }

    func testIgnoredManagedFileDeleteRemovesCatalogWithoutRediscovery() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredDelete")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
        let ignoredURL = root.appendingPathComponent("delete.ignored")
        try await host.writeText(path: ignoredURL.path, content: "delete me", overwrite: false)

        try await store.deleteFile(rootID: record.id, relativePath: "delete.ignored")
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileRemoved("delete.ignored"), .fileAdded("delete.ignored")])

        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoredURL.path))
        let deletedFile = await store.file(rootID: record.id, relativePath: "delete.ignored")
        XCTAssertNil(deletedFile)
    }

    func testMoveTransitionsBetweenDiscoverableAndManagedOnlyIgnoredFiles() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredMove")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        try write("visible", to: root.appendingPathComponent("Visible.md"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        try await store.moveFile(rootID: record.id, from: "Visible.md", to: "Hidden.ignored")
        let hiddenFile = await store.file(rootID: record.id, relativePath: "Hidden.ignored")
        let hiddenLookup = await store.lookupPath("Hidden.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        XCTAssertNotNil(hiddenFile)
        XCTAssertNil(hiddenLookup)
        var searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" })

        try await store.moveFile(rootID: record.id, from: "Hidden.ignored", to: "VisibleAgain.md")
        let visibleAgainLookup = await store.lookupPath("VisibleAgain.md", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        XCTAssertNotNil(visibleAgainLookup)
        searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertTrue(searchSnapshot.files.contains { $0.standardizedRelativePath == "VisibleAgain.md" })
    }

    func testExplicitCatalogLookupFastPathsSingleInterpretation() async throws {
        let root = try makeTemporaryRoot(name: "CatalogFastPath")
        let fileURL = root.appendingPathComponent("Sources/Visible.swift")
        try write("visible", to: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        let relativeLookup = await store.lookupCatalogFileForExplicitRequest("Sources/Visible.swift", rootScope: .visibleWorkspace)
        guard case let .matched(relativeFile) = relativeLookup else {
            return XCTFail("Expected a single-root relative catalog hit")
        }
        XCTAssertEqual(relativeFile.rootID, record.id)
        XCTAssertEqual(relativeFile.standardizedFullPath, fileURL.path)

        let absoluteLookup = await store.lookupCatalogFileForExplicitRequest(fileURL.path, rootScope: .visibleWorkspace)
        guard case let .matched(absoluteFile) = absoluteLookup else {
            return XCTFail("Expected an absolute catalog hit")
        }
        XCTAssertEqual(absoluteFile.id, relativeFile.id)
    }

    func testExplicitCatalogLookupDoesNotProbeIgnoredShadowForRelativeMultiRootPath() async throws {
        let rootA = try makeTemporaryRoot(name: "CatalogFastPathVisible")
        let rootB = try makeTemporaryRoot(name: "CatalogFastPathIgnored")
        let visibleURL = rootA.appendingPathComponent("same.md")
        let ignoredURL = rootB.appendingPathComponent("same.md")
        try write("visible", to: visibleURL)
        try write("same.md\n", to: rootB.appendingPathComponent(".gitignore"))
        try write("ignored", to: ignoredURL)

        let store = WorkspaceFileContextStore()
        let visibleRoot = try await store.loadRoot(path: rootA.path)
        let ignoredRoot = try await store.loadRoot(path: rootB.path)

        let catalogLookup = await store.lookupCatalogFileForExplicitRequest("same.md", rootScope: .visibleWorkspace)
        guard case let .matched(catalogFile) = catalogLookup else {
            return XCTFail("Expected relative catalog hit without probing ignored disk siblings")
        }
        XCTAssertEqual(catalogFile.rootID, visibleRoot.id)

        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile("same.md", profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(readableFile) = readable else {
            return XCTFail("Expected visible cataloged file to resolve")
        }
        XCTAssertEqual(readableFile.rootID, visibleRoot.id)
        let ignoredRecord = await store.file(rootID: ignoredRoot.id, relativePath: "same.md")
        XCTAssertNil(ignoredRecord)
    }

    func testAmbiguousRelativeIgnoredFileDoesNotMaterializeEitherRoot() async throws {
        let rootA = try makeTemporaryRoot(name: "IgnoredAmbiguousA")
        let rootB = try makeTemporaryRoot(name: "IgnoredAmbiguousB")
        for root in [rootA, rootB] {
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            try write("ignored", to: root.appendingPathComponent("same.ignored"))
        }

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile("same.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)

        let storedA = await store.file(rootID: recordA.id, relativePath: "same.ignored")
        let storedB = await store.file(rootID: recordB.id, relativePath: "same.ignored")
        XCTAssertNil(readable)
        XCTAssertNil(storedA)
        XCTAssertNil(storedB)

        do {
            _ = try await WorkspaceFileMutationService(store: store).resolveExactExistingFileForMutation("same.ignored", rootScope: .visibleWorkspace)
            XCTFail("Expected ambiguous ignored mutation target to fail")
        } catch let error as FileManagerError {
            guard case let .fileSystemServiceNotFoundWithContext(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Unknown or unloaded path"), message)
        }
    }

    func testAmbiguousAliasIsTerminalForExplicitReadAndSelectionLookup() async throws {
        let parentA = try makeTemporaryRoot(name: "AmbiguousAliasParentA")
        let parentB = try makeTemporaryRoot(name: "AmbiguousAliasParentB")
        let rootA = parentA.appendingPathComponent("App", isDirectory: true)
        let rootB = parentB.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try write("*.ignored\n", to: rootA.appendingPathComponent(".gitignore"))
        try write("hidden", to: rootA.appendingPathComponent("secret.ignored"))
        try write("visible fallback", to: rootB.appendingPathComponent("App/secret.ignored"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)

        let catalogLookup = await store.lookupCatalogFileForExplicitRequest("App/secret.ignored", rootScope: .visibleWorkspace)
        XCTAssertEqual(catalogLookup, .ambiguous)
        let explicit = try await store.materializeExplicitlyRequestedFile("App/secret.ignored", rootScope: .visibleWorkspace)
        XCTAssertEqual(explicit, .noCandidate)
        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile("App/secret.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)
        XCTAssertNil(readable)

        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(selectedPaths: ["App/secret.ignored"]),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .selected,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        XCTAssertTrue(snapshot.selectedFileIDs.isEmpty)
    }

    func testMissingManagedIgnoredRecordIsPrunedByAbsoluteMutationRecovery() async throws {
        let rootA = try makeTemporaryRoot(name: "StaleIgnoredA")
        let rootB = try makeTemporaryRoot(name: "StaleIgnoredB")
        try write("*.ignored\n", to: rootA.appendingPathComponent(".gitignore"))
        let staleURL = rootA.appendingPathComponent("same.ignored")
        let visibleURL = rootB.appendingPathComponent("same.ignored")
        try write("stale", to: staleURL)
        try write("visible", to: visibleURL)

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let initiallyReadable = await WorkspaceReadableFileService(store: store).resolveReadableFile(staleURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case .workspace = initiallyReadable else {
            return XCTFail("Expected ignored file to materialize before stale-record pruning")
        }
        try FileManager.default.removeItem(at: staleURL)

        do {
            _ = try await WorkspaceFileMutationService(store: store).resolveExactExistingFileForMutation(staleURL.path, rootScope: .visibleWorkspace)
            XCTFail("Expected removed absolute mutation target to fail")
        } catch {}
        let resolved = await WorkspaceReadableFileService(store: store).resolveReadableFile("same.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(file) = resolved else {
            return XCTFail("Expected remaining visible file to resolve after stale ignored record pruning")
        }
        XCTAssertEqual(file.rootID, recordB.id)
        XCTAssertEqual(file.standardizedFullPath, visibleURL.path)
        let staleRecord = await store.file(rootID: recordA.id, relativePath: "same.ignored")
        XCTAssertNil(staleRecord)
    }

    func testIgnoredFolderReplayStaysHiddenWhenHierarchicalIgnoresAreDisabled() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredFolderReplaySimple")
        try write("ignored/\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path, enableHierarchicalIgnores: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)

        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderAdded("ignored")])

        let ignoredFolder = await store.folder(rootID: record.id, relativePath: "ignored")
        XCTAssertNil(ignoredFolder)
    }

    func testEnsureIndexedFilesDoesNotExposeIgnoredDiskFile() async throws {
        let root = try makeTemporaryRoot(name: "EnsureIndexedIgnored")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let ignoredURL = root.appendingPathComponent("late.ignored")
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        try write("hidden", to: ignoredURL)

        let indexed = await store.ensureIndexedFiles(paths: [ignoredURL.path])

        XCTAssertTrue(indexed.isEmpty)
        let indexedIgnoredFile = await store.file(rootID: record.id, relativePath: "late.ignored")
        XCTAssertNil(indexedIgnoredFile)
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedFullPath == ignoredURL.path })
    }

    func testIgnoredCreateRejectsSymlinkedParentWithoutWritingOutsideRoot() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredCreateSymlink")
        let outside = try makeTemporaryRoot(name: "IgnoredCreateSymlinkOutside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ignored"), withDestinationURL: outside)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

        do {
            try await host.writeText(path: "ignored/report.md", content: "must not escape", overwrite: false)
            XCTFail("Expected symlinked parent create to fail")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("report.md").path))
    }

    func testIgnoredCreateRejectsDanglingLeafSymlinkWithoutWritingOutsideRoot() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredCreateDanglingSymlink")
        let outside = try makeTemporaryRoot(name: "IgnoredCreateDanglingSymlinkOutside")
        let outsideTarget = outside.appendingPathComponent("missing-report.md")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("report.ignored"), withDestinationURL: outsideTarget)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

        do {
            try await host.writeText(path: "report.ignored", content: "must not escape", overwrite: false)
            XCTFail("Expected dangling symlink create to fail")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    func testFileOnlyDeleteAndMoveRejectDirectoryReplacement() async throws {
        let root = try makeTemporaryRoot(name: "MutationDirectoryReplacement")
        let replacedURL = root.appendingPathComponent("Replace.swift")
        try write("file", to: replacedURL)
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        try FileManager.default.removeItem(at: replacedURL)
        try FileManager.default.createDirectory(at: replacedURL, withIntermediateDirectories: true)
        try write("keep", to: replacedURL.appendingPathComponent("Nested.txt"))

        do {
            try await store.deleteFile(rootID: record.id, relativePath: "Replace.swift")
            XCTFail("Expected file-only delete to reject a replacement directory")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacedURL.appendingPathComponent("Nested.txt").path))

        do {
            try await store.moveFile(rootID: record.id, from: "Replace.swift", to: "Moved.swift")
            XCTFail("Expected file-only move to reject a replacement directory")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacedURL.appendingPathComponent("Nested.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Moved.swift").path))
    }

    func testTrashRejectsSymlinkedParentWithoutMovingOutsideRootFile() async throws {
        let root = try makeTemporaryRoot(name: "TrashSymlink")
        let outside = try makeTemporaryRoot(name: "TrashSymlinkOutside")
        let outsideFile = outside.appendingPathComponent("report.md")
        try write("keep", to: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        do {
            try await store.moveItemToTrash(rootID: record.id, relativePath: "linked/report.md")
            XCTFail("Expected symlinked parent trash to fail")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testUnknownSymlinkedFolderReplayDoesNotIndexFolder() async throws {
        let root = try makeTemporaryRoot(name: "ReplaySymlinkFolder")
        let outside = try makeTemporaryRoot(name: "ReplaySymlinkFolderOutside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderAdded("linked")])

        let replayedFolder = await store.folder(rootID: record.id, relativePath: "linked")
        XCTAssertNil(replayedFolder)
    }

    func testPolicyIneligibleReplayDoesNotPublishRawDiscoveryDelta() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredRawReplay")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        try write("hidden", to: root.appendingPathComponent("late.ignored"))
        let hiddenDelta = expectation(description: "Ignored replay must stay out of discovery-facing raw deltas")
        hiddenDelta.isInverted = true
        let stream = await store.fileSystemDeltaEvents()
        let observation = Task {
            for await event in stream where FileSystemDeltaPreparation.standardizedRelativePath(for: event.delta) == "late.ignored" {
                hiddenDelta.fulfill()
                break
            }
        }

        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("late.ignored")])
        await fulfillment(of: [hiddenDelta], timeout: 0.1)
        observation.cancel()
    }

    func testPolicyIneligibleReplayDoesNotMaterializeIgnoredFile() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredReplayPostcondition")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        try write("ignored", to: root.appendingPathComponent("late.ignored"))

        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("late.ignored")])

        let replayedIgnoredFile = await store.file(rootID: record.id, relativePath: "late.ignored")
        XCTAssertNil(replayedIgnoredFile)
        let replayedIgnoredLookup = await store.lookupPath("late.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        XCTAssertNil(replayedIgnoredLookup)
    }

    func testStaleCatalogRecordIsPrunedForExactMutationLookup() async throws {
        let root = try makeTemporaryRoot(name: "StaleCatalogPrune")
        let staleURL = root.appendingPathComponent("Stale.swift")
        try write("stale", to: staleURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let staleFileBeforeRemoval = await store.file(rootID: record.id, relativePath: "Stale.swift")
        XCTAssertNotNil(staleFileBeforeRemoval)

        try FileManager.default.removeItem(at: staleURL)
        let service = WorkspaceFileMutationService(store: store)

        let exactAfterRemoval = await service.exactExistingFile("Stale.swift", rootScope: .visibleWorkspace)
        XCTAssertNil(exactAfterRemoval)
        let staleFileAfterPrune = await store.file(rootID: record.id, relativePath: "Stale.swift")
        XCTAssertNil(staleFileAfterPrune)
        let staleLookupAfterPrune = await store.lookupPath("Stale.swift", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
        XCTAssertNil(staleLookupAfterPrune)
    }

    func testStaleAmbiguousExactMutationLookupPrunesMissingCandidate() async throws {
        let rootA = try makeTemporaryRoot(name: "StaleAmbiguousA")
        let rootB = try makeTemporaryRoot(name: "StaleAmbiguousB")
        let staleURL = rootA.appendingPathComponent("Sources/A.swift")
        let remainingURL = rootB.appendingPathComponent("Sources/A.swift")
        try write("stale", to: staleURL)
        try write("remaining", to: remainingURL)

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let service = WorkspaceFileMutationService(store: store)

        let ambiguousIssue = await store.exactPathResolutionIssue(for: "Sources/A.swift", kind: .file, rootScope: .visibleWorkspace)
        XCTAssertNotNil(ambiguousIssue)

        try FileManager.default.removeItem(at: staleURL)
        let resolved = try await service.resolveExactExistingFileForMutation("Sources/A.swift", rootScope: .visibleWorkspace)

        XCTAssertEqual(resolved.rootID, recordB.id)
        XCTAssertEqual(resolved.standardizedRelativePath, "Sources/A.swift")
        let staleAfterPrune = await store.file(rootID: recordA.id, relativePath: "Sources/A.swift")
        XCTAssertNil(staleAfterPrune)
        let remainingAfterPrune = await store.file(rootID: recordB.id, relativePath: "Sources/A.swift")
        XCTAssertNotNil(remainingAfterPrune)
    }

    func testMaterializationFailureReportsClearPostconditionError() async throws {
        let root = try makeTemporaryRoot(name: "MaterializationFailure")
        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)

        do {
            _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: record.id, relativePath: "Missing.swift")
            XCTFail("Expected missing post-write file to fail catalog materialization")
        } catch let error as WorkspaceFileContextStoreError {
            guard case let .catalogMaterializationFailed(message) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertTrue(message.contains("not catalog-eligible"))
            XCTAssertTrue(message.contains("missing"))
            XCTAssertTrue(error.localizedDescription.contains(message))
        }
    }

    func testDeleteRemovesCatalogAndCodemapVisibility() async throws {
        let root = try makeTemporaryRoot(name: "DeletePostcondition")
        let fileURL = root.appendingPathComponent("Deleted.swift")
        try write("struct Deleted {}", to: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileURL.path))
        ])
        let codemapBeforeDelete = await store.codemapSnapshot(rootID: record.id, relativePath: "Deleted.swift")
        XCTAssertNotNil(codemapBeforeDelete)

        try await store.deleteFile(rootID: record.id, relativePath: "Deleted.swift")

        let deletedFile = await store.file(rootID: record.id, relativePath: "Deleted.swift")
        XCTAssertNil(deletedFile)
        let codemapAfterDelete = await store.codemapSnapshot(rootID: record.id, relativePath: "Deleted.swift")
        XCTAssertNil(codemapAfterDelete)
        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(selectedPaths: [fileURL.path], autoCodemapPaths: [fileURL.path], slices: [fileURL.path: [LineRange(start: 1, end: 1)]], codemapAutoEnabled: true),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .selected,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: true,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        XCTAssertTrue(snapshot.selectedFileIDs.isEmpty)
    }

    func testWorkspaceFileMutationServiceRequiresExactExistingFileForOverwriteResolution() async throws {
        let rootA = try makeTemporaryRoot(name: "OverwriteExactA")
        let rootB = try makeTemporaryRoot(name: "OverwriteExactB")
        try write("a", to: rootA.appendingPathComponent("Sources/A.swift"))
        try write("b", to: rootB.appendingPathComponent("Sources/A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)
        let service = WorkspaceFileMutationService(store: store)

        do {
            _ = try await service.resolveExactExistingFileForMutation("Sources/A.swift", rootScope: .visibleWorkspace)
            XCTFail("Expected ambiguous relative overwrite target to fail exact resolution")
        } catch let error as FileManagerError {
            guard case let .fileSystemServiceNotFoundWithContext(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("matches multiple workspace roots"))
        }
    }

    func testWorkspaceReadableFileServiceResolvesAndReadsAlwaysReadableExternalFiles() async throws {
        let home = try makeTemporaryRoot(name: "ReadableHome")
        let external = home.appendingPathComponent(".agents/skills/example/SKILL.md")
        try write("skill body", to: external)

        let store = WorkspaceFileContextStore()
        let service = WorkspaceReadableFileService(store: store, homeDirectoryURL: home)
        let resolved = try XCTUnwrap(service.resolveAlwaysReadableExternalFile(atAbsolutePath: external.path))

        XCTAssertEqual(resolved.displayPath, "~/.agents/skills/example/SKILL.md")
        let externalContent = try await service.readAlwaysReadableExternalFile(resolved)
        XCTAssertEqual(externalContent, "skill body")
        XCTAssertTrue(service.isAlwaysReadableExternalPath(external.path))
    }

    @MainActor
    func testAttachRootShellFromPreloadedStoreRecordDoesNotMaterializeDescendants() async throws {
        let root = try makeTemporaryRoot(name: "RootShellAttach")
        let nestedFolderURL = root.appendingPathComponent("Sources")
        let fileURL = nestedFolderURL.appendingPathComponent("A.swift")
        try write("struct A {}", to: fileURL)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let workspace = WorkspaceModel(name: "RootShellAttach", repoPaths: [root.path])

        manager.registerPreloadedWorkspaceRoot(rootRecord)
        let shell = try manager.attachRootShell(for: rootRecord, workspaceID: workspace.id)

        XCTAssertEqual(manager.rootFolders.count, 1)
        XCTAssertEqual(shell.id, rootRecord.id)
        XCTAssertEqual(shell.standardizedFullPath, rootRecord.standardizedFullPath)
        XCTAssertTrue(shell.children.isEmpty)
        XCTAssertNil(manager.findFolderByFullPath(nestedFolderURL.path))
        XCTAssertNil(manager.findFileByFullPath(fileURL.path))
        XCTAssertTrue(manager.allFilesSnapshot(sorted: false).isEmpty)
        let storeFiles = await store.files(inRoot: rootRecord.id).map(\.standardizedRelativePath)
        XCTAssertEqual(storeFiles, ["Sources/A.swift"])

        await manager.unloadAllRootFolders()
        XCTAssertTrue(manager.rootFolders.isEmpty)
        let rootsAfterUnload = await store.roots()
        XCTAssertTrue(rootsAfterUnload.isEmpty)
    }

    @MainActor
    func testWatcherAddedUIViewModelsUseStoreRecordIDs() async throws {
        let root = try makeTemporaryRoot(name: "WatcherUIIdentity")
        try write("seed", to: root.appendingPathComponent("Existing.swift"))

        let store = WorkspaceFileContextStore()
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        await manager.setCodeScanEnabled(false)
        let workspace = WorkspaceModel(name: "WatcherUIIdentity", repoPaths: [root.path])

        try await manager.loadFolder(at: root, for: workspace)
        let roots = await store.roots()
        let rootRecord = try XCTUnwrap(roots.first)

        let addedURL = root.appendingPathComponent("Sources/Added.swift")
        try write("struct Added {}", to: addedURL)
        await store.replayObservedFileSystemDeltas(rootID: rootRecord.id, deltas: [.fileAdded("Sources/Added.swift")])

        let storedFile = await store.file(rootID: rootRecord.id, relativePath: "Sources/Added.swift")
        let storedFolder = await store.folder(rootID: rootRecord.id, relativePath: "Sources")
        let fileRecord = try XCTUnwrap(storedFile)
        let folderRecord = try XCTUnwrap(storedFolder)

        let fileVM = try await waitForFile(manager: manager, fullPath: addedURL.path, id: fileRecord.id)
        let folderVM = try await waitForFolder(manager: manager, fullPath: root.appendingPathComponent("Sources").path, id: folderRecord.id)

        XCTAssertEqual(fileVM.id, fileRecord.id)
        XCTAssertEqual(folderVM.id, folderRecord.id)

        await manager.unloadAllRootFolders()
    }

    @MainActor
    func testCancelledRootLoadDoesNotCommitUIOrStoreRoot() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "CancelledRootLoad")
            try write("struct A {}", to: root.appendingPathComponent("Sources/A.swift"))

            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "CancelledRootLoad", repoPaths: [root.path])
            let gate = AsyncGate()
            await store.setRootLoadWillStartHandler { _ in
                await gate.markStartedAndWaitForRelease()
            }

            let loadTask = Task { @MainActor in
                try await manager.loadFolder(at: root, for: workspace)
            }

            await gate.waitUntilStarted()
            manager.cancelAllLoadingTasks()
            await gate.release()

            do {
                try await loadTask.value
                XCTFail("Expected cancelled root load to throw")
            } catch is CancellationError {
                // Expected.
            }

            await store.setRootLoadWillStartHandler(nil)
            let roots = await store.roots()
            XCTAssertTrue(manager.rootFolders.isEmpty)
            XCTAssertTrue(roots.isEmpty)
        #endif
    }

    @MainActor
    func testLoadedRootShellAlignsWithStoreRootAndLeavesCodemapIDsStoreBacked() async throws {
        let root = try makeTemporaryRoot(name: "IdentityAlignment")
        let fileURL = root.appendingPathComponent("Sources/Nested/A.swift")
        try write("struct A {}", to: fileURL)
        try write("notes", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        await manager.setCodeScanEnabled(false)
        let workspace = WorkspaceModel(name: "IdentityAlignment", repoPaths: [root.path])

        try await manager.loadFolder(at: root, for: workspace)

        let storeRoots = await store.roots()
        let rootRecord = try XCTUnwrap(storeRoots.first)
        let storeFolders = await store.folders(inRoot: rootRecord.id).map(\.standardizedRelativePath)
        let storeFiles = await store.files(inRoot: rootRecord.id)
        let swiftFileRecord = try XCTUnwrap(storeFiles.first { $0.standardizedRelativePath == "Sources/Nested/A.swift" })

        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileURL.path))
        ])
        let codemapSnapshot = await store.codemapSnapshot(rootID: rootRecord.id, relativePath: "Sources/Nested/A.swift")
        let snapshot = try XCTUnwrap(codemapSnapshot)

        let rootVM = try XCTUnwrap(manager.rootFolders.first)
        XCTAssertEqual(manager.rootFolders.count, 1)
        XCTAssertEqual(rootVM.id, rootRecord.id)
        XCTAssertTrue(rootVM.children.isEmpty)
        XCTAssertNil(manager.findFileByFullPath(fileURL.path))
        XCTAssertNil(manager.findFolderByFullPath(root.appendingPathComponent("Sources").path))
        XCTAssertNil(manager.findFolderByFullPath(root.appendingPathComponent("Sources/Nested").path))
        XCTAssertTrue(manager.allFilesSnapshot(sorted: false).isEmpty)
        XCTAssertTrue(storeFolders.contains("Sources"))
        XCTAssertTrue(storeFolders.contains("Sources/Nested"))
        XCTAssertEqual(Set(storeFiles.map(\.standardizedRelativePath)), Set(["README.md", "Sources/Nested/A.swift"]))
        XCTAssertEqual(snapshot.fileID, swiftFileRecord.id)

        await manager.unloadAllRootFolders()
        XCTAssertTrue(manager.rootFolders.isEmpty)
        let rootsAfterUnload = await store.roots()
        XCTAssertTrue(rootsAfterUnload.isEmpty)
    }

    func testStoreReadContentReturnsCurrentDiskBytesAfterExternalChange() async throws {
        let root = try makeTemporaryRoot(name: "StrictStoreReadFreshness")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("old", to: fileURL)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try setDiskModificationDate(fixedDate, for: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let initialContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
        XCTAssertEqual(initialContent, "old")

        try write("new", to: fileURL)
        try setDiskModificationDate(fixedDate, for: fileURL)

        let refreshedContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
        XCTAssertEqual(refreshedContent, "new")
    }

    #if DEBUG
        func testInitialRootCodemapScansByRootIDSkipSamePathReloadedRoot() async throws {
            let root = try makeTemporaryRoot(name: "InitialScanRootIDGate")
            try write("struct A { func oldRoot() {} }\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let oldRecord = try await store.loadRoot(path: root.path)
            try await store.requestInitialRootCodemapScans(rootIDs: [oldRecord.id])
            _ = await waitForCodemapCounters(store: store) { counters in
                counters.trackedFileIDCount == 1
            }

            await store.unloadRoot(id: oldRecord.id)
            let unloadedCounters = await waitForCodemapCounters(store: store) { counters in
                counters.trackedFileIDCount == 0 &&
                    counters.trackedRootCount == 0 &&
                    counters.queuedCount == 0 &&
                    counters.activeScanCount == 0 &&
                    counters.outstandingScanCount == 0
            }
            XCTAssertEqual(unloadedCounters.trackedFileIDCount, 0)

            let newRecord = try await store.loadRoot(path: root.path)
            try await store.requestInitialRootCodemapScans(rootIDs: [oldRecord.id])
            try await Task.sleep(nanoseconds: 50_000_000)
            let afterOldRootIDRequest = await store.codemapMemoryCounters()
            XCTAssertEqual(afterOldRootIDRequest.trackedFileIDCount, 0)
            XCTAssertEqual(afterOldRootIDRequest.trackedRootCount, 0)

            try await store.requestInitialRootCodemapScans(rootIDs: [newRecord.id])
            let reloadedCounters = await waitForCodemapCounters(store: store) { counters in
                counters.trackedFileIDCount == 1
            }
            XCTAssertEqual(reloadedCounters.trackedFileIDCount, 1)
        }

        func testInitialRootCodemapScansByPathTargetReloadedSamePathRoot() async throws {
            let root = try makeTemporaryRoot(name: "InitialScanSamePathReload")
            try write("struct A { func samePath() {} }\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let oldRecord = try await store.loadRoot(path: root.path)
            try await store.requestInitialRootCodemapScans(rootFolderPaths: [root.path])
            _ = await waitForCodemapCounters(store: store) { counters in
                counters.trackedFileIDCount == 1
            }

            await store.unloadRoot(id: oldRecord.id)
            _ = await waitForCodemapCounters(store: store) { counters in
                counters.trackedFileIDCount == 0 &&
                    counters.trackedRootCount == 0 &&
                    counters.queuedCount == 0 &&
                    counters.activeScanCount == 0 &&
                    counters.outstandingScanCount == 0
            }

            let newRecord = try await store.loadRoot(path: root.path)
            XCTAssertNotEqual(newRecord.id, oldRecord.id)
            try await store.requestInitialRootCodemapScans(
                rootFolderPaths: [root.path],
                purgeCachesOnEmptyInitialRequests: true
            )

            let reloadedCounters = await waitForCodemapCounters(store: store) { counters in
                counters.trackedRootCount == 1 && counters.trackedFileIDCount == 1
            }
            XCTAssertEqual(reloadedCounters.trackedRootCount, 1)
            XCTAssertEqual(reloadedCounters.trackedFileIDCount, 1)
        }

        func testDeferredInitialRootLoadFlushUsesStoreRootsInsteadOfMainActorUIGather() throws {
            let source = try readWorkspaceFilesViewModelSource()
            let flushBody = try XCTUnwrap(source.slice(from: "func flushDeferredInitialRootLoadScans()", to: "private func clearDeferredInitialRootLoadScanState"))

            XCTAssertTrue(flushBody.contains("workspaceFileContextStore.rootRecords"), flushBody)
            XCTAssertTrue(flushBody.contains("enqueueInitialRootLoadRequests"), flushBody)
            XCTAssertFalse(flushBody.contains("getFilesRecursively"), flushBody)
        }
    #endif

    @MainActor
    func testContentSearchReloadsExternalModificationBeforeMatching() async throws {
        let root = try makeTemporaryRoot(name: "StrictSearchFreshness")
        let fileURL = root.appendingPathComponent("Sources/A.swift")
        let staleDate = Date(timeIntervalSince1970: 1_700_000_100)
        let freshDate = Date(timeIntervalSince1970: 1_700_000_200)
        try write("struct A { let staleSearchToken = true }\n", to: fileURL)
        try setDiskModificationDate(staleDate, for: fileURL)

        let store = WorkspaceFileContextStore()
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        await manager.setCodeScanEnabled(false)
        let workspace = WorkspaceModel(name: "StrictSearchFreshness", repoPaths: [root.path])
        try await manager.loadFolder(at: root, for: workspace)
        XCTAssertNil(manager.findFileByFullPath(fileURL.path))

        try write("struct A { let freshSearchToken = true }\n", to: fileURL)
        try setDiskModificationDate(freshDate, for: fileURL)

        let freshResults = try await manager.search(
            pattern: "freshSearchToken",
            mode: .content,
            isRegex: false,
            paths: ["Sources/A.swift"]
        )
        let staleResults = try await manager.search(
            pattern: "staleSearchToken",
            mode: .content,
            isRegex: false,
            paths: ["Sources/A.swift"]
        )

        XCTAssertEqual(freshResults.matches?.count, 1)
        XCTAssertTrue((staleResults.matches ?? []).isEmpty)
        XCTAssertNil(manager.findFileByFullPath(fileURL.path))

        await manager.unloadAllRootFolders()
    }

    @MainActor
    func testDiskValidatedSearchSnapshotReusesCacheWhenMetadataUnchanged() async throws {
        let root = try makeTemporaryRoot(name: "StrictSearchNoUnneededRefresh")
        let fileURL = root.appendingPathComponent("A.swift")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_300)
        try write("struct A { let stableToken = true }\n", to: fileURL)
        try setDiskModificationDate(fixedDate, for: fileURL)

        let store = WorkspaceFileContextStore()
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        await manager.setCodeScanEnabled(false)
        let workspace = WorkspaceModel(name: "StrictSearchNoUnneededRefresh", repoPaths: [root.path])
        try await manager.loadFolder(at: root, for: workspace)
        let materializedFile = await manager.materializeFileForUserInput(fileURL.path, profile: .mcpRead)
        let file = try XCTUnwrap(materializedFile)
        let initialContent = await file.latestContent
        XCTAssertEqual(initialContent, "struct A { let stableToken = true }\n")

        let cached = await file.searchContentSnapshot(freshnessPolicy: .cachedMetadata)
        let strict = await file.searchContentSnapshot(freshnessPolicy: .validateDiskMetadata)

        XCTAssertTrue(cached.isFresh)
        XCTAssertTrue(strict.isFresh)
        XCTAssertEqual(strict.content, cached.content)
        XCTAssertEqual(strict.contentRevision, cached.contentRevision)

        await manager.unloadAllRootFolders()
    }

    func testApplyEditsPreviewReadsFreshDiskBaseAfterExternalModification() async throws {
        let root = try makeTemporaryRoot(name: "StrictApplyEditsFreshBase")
        let fileURL = root.appendingPathComponent("A.swift")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_400)
        try write("struct A { let staleApplyToken = true }\n", to: fileURL)
        try setDiskModificationDate(fixedDate, for: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let initialContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
        XCTAssertEqual(initialContent, "struct A { let staleApplyToken = true }\n")

        try write("struct A { let freshApplyToken = true }\n", to: fileURL)
        try setDiskModificationDate(fixedDate, for: fileURL)

        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let service = ApplyEditsService(engine: .default, host: host)
        let request = ApplyEditsRequest(
            path: "A.swift",
            mode: .single(search: "freshApplyToken", replace: "editedApplyToken", replaceAll: false),
            verbose: true
        )

        let preview = try await service.preview(request)

        XCTAssertTrue(preview.exists)
        XCTAssertEqual(preview.originalText, "struct A { let freshApplyToken = true }\n")
        XCTAssertTrue(preview.result.updatedText.contains("editedApplyToken"))
        XCTAssertFalse(preview.result.updatedText.contains("staleApplyToken"))
    }

    func testApplyEditsRejectsDiskMissingStaleCatalogBase() async throws {
        let root = try makeTemporaryRoot(name: "StrictApplyEditsMissingBase")
        let fileURL = root.appendingPathComponent("Deleted.swift")
        try write("struct Deleted {}\n", to: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let loadedRecord = await store.file(rootID: record.id, relativePath: "Deleted.swift")
        XCTAssertNotNil(loadedRecord)
        try FileManager.default.removeItem(at: fileURL)

        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let service = ApplyEditsService(engine: .default, host: host)
        let request = ApplyEditsRequest(
            path: "Deleted.swift",
            mode: .single(search: "Deleted", replace: "Edited", replaceAll: false),
            verbose: false
        )

        do {
            _ = try await service.preview(request)
            XCTFail("Expected apply_edits preview to reject a stale disk-missing base")
        } catch let error as ApplyEditsError {
            guard case let .invalidParams(message) = error else {
                return XCTFail("Unexpected apply_edits error: \(error)")
            }
            XCTAssertTrue(message.contains("does not exist"))
        } catch let error as FileManagerError {
            XCTAssertTrue(error.localizedDescription.contains("Unknown or unloaded path"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let prunedRecord = await store.file(rootID: record.id, relativePath: "Deleted.swift")
        XCTAssertNil(prunedRecord)
    }

    #if DEBUG
        func testConcurrentSamePathRootLoadsShareInFlightLoad() async throws {
            let root = try makeTemporaryRoot(name: "ConcurrentSamePathLoad")
            try write("struct A {}", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let startGate = AsyncGate()
            let joinGate = AsyncGate()
            await store.setRootLoadWillStartHandler { _ in
                await startGate.markStartedAndWaitForRelease()
            }
            await store.setRootLoadDidJoinInFlightHandler { _ in
                await joinGate.markStartedAndWaitForRelease()
            }

            let firstLoad = Task { try await store.loadRoot(path: root.path, cancelUnderlyingLoadOnCallerCancellation: true) }
            await startGate.waitUntilStarted()
            let secondLoad = Task { try await store.loadRoot(path: root.path, cancelUnderlyingLoadOnCallerCancellation: true) }
            await joinGate.waitUntilStarted()

            await joinGate.release()
            await startGate.release()

            let firstRecord = try await firstLoad.value
            let secondRecord = try await secondLoad.value
            await store.setRootLoadWillStartHandler(nil)
            await store.setRootLoadDidJoinInFlightHandler(nil)

            let startCount = await startGate.startCount()
            let joinCount = await joinGate.startCount()
            let loadedRoots = await store.roots()
            XCTAssertEqual(firstRecord.id, secondRecord.id)
            XCTAssertEqual(startCount, 1)
            XCTAssertEqual(joinCount, 1)
            XCTAssertEqual(loadedRoots.map(\.id), [firstRecord.id])
        }

        @MainActor
        func testCancelledRootLoadAfterUIRootAppendDoesNotLeaveUIOrStoreRoot() async throws {
            let root = try makeTemporaryRoot(name: "CancelAfterUIRootAppend")
            for index in 0 ..< 1500 {
                try write("struct File\(index) {}\n", to: root.appendingPathComponent("Sources/File\(index).swift"))
            }

            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "CancelAfterUIRootAppend", repoPaths: [root.path])
            let attachGate = AsyncGate()
            manager.setRootLoadDidAttachRootShellHandler { _, _ in
                await attachGate.markStartedAndWaitForRelease()
            }
            defer { manager.setRootLoadDidAttachRootShellHandler(nil) }

            let loadTask = Task { @MainActor in
                try await manager.loadFolder(at: root, for: workspace)
            }

            await attachGate.waitUntilStarted()
            XCTAssertEqual(manager.rootFolders.count, 1)
            manager.cancelAllLoadingTasks()
            await attachGate.release()

            do {
                try await loadTask.value
                XCTFail("Expected root load cancelled after partial UI append to throw")
            } catch is CancellationError {
                // Expected.
            }

            let roots = await store.roots()
            XCTAssertTrue(manager.rootFolders.isEmpty)
            XCTAssertTrue(roots.isEmpty)
        }

        @MainActor
        func testCallerCancelledLoadFolderAfterUIRootAppendCleansUIAndStoreRoot() async throws {
            let root = try makeTemporaryRoot(name: "CallerCancelAfterUIRootAppend")
            for index in 0 ..< 1500 {
                try write("struct File\(index) {}\n", to: root.appendingPathComponent("Sources/File\(index).swift"))
            }

            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "CallerCancelAfterUIRootAppend", repoPaths: [root.path])
            let attachGate = AsyncGate()
            manager.setRootLoadDidAttachRootShellHandler { _, _ in
                await attachGate.markStartedAndWaitForRelease()
            }
            defer { manager.setRootLoadDidAttachRootShellHandler(nil) }

            let loadTask = Task { @MainActor in
                try await manager.loadFolder(at: root, for: workspace)
            }

            await attachGate.waitUntilStarted()
            XCTAssertEqual(manager.rootFolders.count, 1)
            loadTask.cancel()
            await attachGate.release()

            do {
                try await loadTask.value
                XCTFail("Expected caller-cancelled root load to throw")
            } catch is CancellationError {
                // Expected.
            }

            let roots = await store.roots()
            XCTAssertTrue(manager.rootFolders.isEmpty)
            XCTAssertTrue(roots.isEmpty)
        }

        @MainActor
        func testObsoleteSamePathLoadDoesNotUnloadNewerJoinedLoad() async throws {
            let root = try makeTemporaryRoot(name: "SamePathObsoleteCleanup")
            try write("struct A {}", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let startGate = AsyncGate()
            let joinGate = AsyncGate()
            await store.setRootLoadWillStartHandler { _ in
                await startGate.markStartedAndWaitForRelease()
            }
            await store.setRootLoadDidJoinInFlightHandler { _ in
                await joinGate.markStartedAndWaitForRelease()
            }

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "SamePathObsoleteCleanup", repoPaths: [root.path])

            let firstLoad = Task { @MainActor in
                try await manager.loadFolder(at: root, for: workspace)
            }
            await startGate.waitUntilStarted()

            let secondLoad = Task { @MainActor in
                try await manager.loadFolder(at: root, for: workspace)
            }
            await joinGate.waitUntilStarted()

            await joinGate.release()
            await startGate.release()

            do {
                try await firstLoad.value
                XCTFail("Expected older same-path load to be invalidated")
            } catch is CancellationError {
                // Expected.
            }
            try await secondLoad.value

            await store.setRootLoadWillStartHandler(nil)
            await store.setRootLoadDidJoinInFlightHandler(nil)

            let roots = await store.roots()
            XCTAssertEqual(roots.count, 1)
            XCTAssertEqual(manager.rootFolders.count, 1)
            XCTAssertEqual(manager.rootFolders.first?.standardizedFullPath, (root.path as NSString).standardizingPath)

            await manager.unloadAllRootFolders()
        }

        @MainActor
        func testUncommittedPreloadedRootIsUnloadedByFullUnload() async throws {
            let root = try makeTemporaryRoot(name: "UncommittedPreloadCleanup")
            try write("struct A {}", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            let rootRecord = try await store.loadRoot(path: root.path)
            manager.registerPreloadedWorkspaceRoot(rootRecord)

            let loadedRoots = await store.roots()
            XCTAssertEqual(loadedRoots.count, 1)
            await manager.unloadAllRootFolders()
            let unloadedRoots = await store.roots()
            XCTAssertTrue(unloadedRoots.isEmpty)
        }

        func testCancelledSamePathLoadWaitingForUnloadDoesNotCreateRoot() async throws {
            let root = try makeTemporaryRoot(name: "CancelWaitForUnload")
            try write("struct A {}", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let unloadGate = AsyncGate()
            await store.setRootUnloadDidDetachHandler { _ in
                await unloadGate.markStartedAndWaitForRelease()
            }

            let unloadTask = Task {
                await store.unloadRoot(id: record.id)
            }
            await unloadGate.waitUntilStarted()

            let waitingLoad = Task {
                try await store.loadRoot(path: root.path)
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            waitingLoad.cancel()
            await unloadGate.release()
            await unloadTask.value

            do {
                _ = try await waitingLoad.value
                XCTFail("Expected waiting root load to observe cancellation")
            } catch is CancellationError {
                // Expected.
            }

            await store.setRootUnloadDidDetachHandler(nil)
            let rootsAfterCancelledWait = await store.roots()
            XCTAssertTrue(rootsAfterCancelledWait.isEmpty)
        }

        @MainActor
        func testApplyStoredSelectionWithEmptySlicesClearsCurrentSliceProjection() async throws {
            let root = try makeTemporaryRoot(name: "ApplyStoredEmptySlices")
            let fileURL = root.appendingPathComponent("Sources/A.swift")
            try write("line 1\nline 2\nline 3\n", to: fileURL)

            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "ApplyStoredEmptySlices", repoPaths: [root.path])
            let tabID = UUID()

            try await manager.loadFolder(at: root, for: workspace)
            manager.setActiveTabID(tabID)

            _ = try await manager.setSelectionSlices(
                entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: [LineRange(start: 1, end: 2)])],
                mode: .set,
                persistWorkspace: false
            )
            let file = try XCTUnwrap(manager.findFileByFullPath(fileURL.path))
            XCTAssertEqual(manager.snapshotSelection().selectedPaths, [file.standardizedFullPath])
            XCTAssertEqual(manager.snapshotSelection().slices.count, 1)
            XCTAssertEqual(manager.getSelectionSlicesSnapshot().count, 1)

            await manager.applyStoredSelection(StoredSelection(
                selectedPaths: [fileURL.path],
                autoCodemapPaths: [],
                slices: [:],
                codemapAutoEnabled: false
            ))

            let snapshot = manager.snapshotSelection()
            XCTAssertEqual(snapshot.selectedPaths, [file.standardizedFullPath])
            XCTAssertEqual(snapshot.autoCodemapPaths.count, 0)
            XCTAssertTrue(snapshot.slices.isEmpty)
            XCTAssertFalse(snapshot.codemapAutoEnabled)
            XCTAssertTrue(manager.getSelectionSlicesSnapshot().isEmpty)
        }

        @MainActor
        func testHydrateSlicesForActiveTabWithEmptyStoredSelectionDeletesPersistedSlices() async throws {
            #if DEBUG
                let root = try makeTemporaryRoot(name: "HydrateEmptySlices")
                let fileURL = root.appendingPathComponent("Sources/A.swift")
                try write("line 1\nline 2\nline 3\n", to: fileURL)

                let store = WorkspaceFileContextStore()
                let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
                await manager.setCodeScanEnabled(false)
                let workspace = WorkspaceModel(name: "HydrateEmptySlices", repoPaths: [root.path])
                let tabID = UUID()

                try await manager.loadFolder(at: root, for: workspace)
                manager.setActiveTabID(tabID)

                _ = try await manager.setSelectionSlices(
                    entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: [LineRange(start: 1, end: 2)])],
                    mode: .set,
                    persistWorkspace: false
                )
                let file = try XCTUnwrap(manager.findFileByFullPath(fileURL.path))
                XCTAssertFalse(manager.snapshotSelection().slices.isEmpty)
                let hasSlicesBeforeHydrate = await manager._testHasAnySlicesForFile(file)
                XCTAssertTrue(hasSlicesBeforeHydrate)

                await manager.hydrateSlicesForActiveTab(from: StoredSelection(
                    selectedPaths: [fileURL.path],
                    autoCodemapPaths: [],
                    slices: [:],
                    codemapAutoEnabled: false
                ))

                XCTAssertTrue(manager.snapshotSelection().slices.isEmpty)
                XCTAssertTrue(manager.getSelectionSlicesSnapshot().isEmpty)
                let hasSlicesAfterHydrate = await manager._testHasAnySlicesForFile(file)
                XCTAssertFalse(hasSlicesAfterHydrate)
            #endif
        }

        private func waitForCodemapCounters(
            store: WorkspaceFileContextStore,
            timeout: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            until predicate: (CodeScanActor.CodemapMemoryCounters) -> Bool
        ) async -> CodeScanActor.CodemapMemoryCounters {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let counters = await store.codemapMemoryCounters()
                if predicate(counters) {
                    return counters
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let finalCounters = await store.codemapMemoryCounters()
            XCTFail("Timed out waiting for codemap counters: \(finalCounters)", file: file, line: line)
            return finalCounters
        }

        private actor AsyncGate {
            private var started = false
            private var startedCount = 0
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                started = true
                startedCount += 1
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }

                guard !released else { return }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            func release() {
                released = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }

            func startCount() -> Int {
                startedCount
            }
        }

        @MainActor
        private func waitUntilRootFolderVisible(
            manager: WorkspaceFilesViewModel,
            timeout: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !manager.rootFolders.isEmpty {
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for partial root UI append", file: file, line: line)
        }

        private func readWorkspaceFilesViewModelSource() throws -> String {
            let root = try RepoRoot.url()
            let url = root.appendingPathComponent("Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    #endif

    #if DEBUG
        func testAllCodemapFileAPIsCacheReusesOrderedAggregateAndRecordsRebuildOnlyRows() async throws {
            let root = try makeTemporaryRoot(name: "AllCodemapAPICacheReuse")
            let fileA = root.appendingPathComponent("A.swift")
            let fileB = root.appendingPathComponent("Nested/B.swift")
            try write("struct A {}", to: fileA)
            try write("struct B {}", to: fileB)

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: fileB.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileB.path, symbolName: "bSymbol")),
                WorkspaceObservedCodemapResult(fullPath: fileA.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileA.path, symbolName: "aSymbol"))
            ])
            startAllCodemapFileAPIsCapture(label: "all-codemap-file-apis-cache-reuse")
            defer { EditFlowPerf.resetDebugCaptureForTesting() }

            let cold = await store.codemapFileAPIAggregate()
            let warm = await store.codemapFileAPIAggregate()
            let compatibilityAPIs = await store.allCodemapFileAPIs()
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)

            XCTAssertEqual(codemapAPIProjection(cold.orderedFileAPIs), codemapAPIProjection(warm.orderedFileAPIs))
            XCTAssertEqual(codemapAPIProjection(cold.orderedFileAPIs), codemapAPIProjection(compatibilityAPIs))
            XCTAssertEqual(cold.orderedFileAPIs.map(\.filePath), [fileA.path, fileB.path])
            XCTAssertEqual(codemapAPIProjection(Array(cold.firstFileAPIByStandardizedNestedPath.values)), codemapAPIProjection(Array(warm.firstFileAPIByStandardizedNestedPath.values)))
            XCTAssertEqual(try codemapAPIProjection([XCTUnwrap(cold.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)])]), try codemapAPIProjection([XCTUnwrap(warm.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)])]))
            XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)?.sampleCount, 3)
            XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)?.sampleCount, 1)
            XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)?.sampleCount, 1)
            XCTAssertTrue(capture.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertEqual(capture.droppedSampleCount, 0)
        }
    #endif

    func testCodemapFileAPIAggregatePreservesForeignNestedPathFirstWinnerAndRetainedRecomputeResults() async throws {
        let root = try makeTemporaryRoot(name: "CodemapAPIAggregateForeignNestedPath")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let target = root.appendingPathComponent("Target.swift")
        try write("struct A {}", to: fileA)
        try write("struct B {}", to: fileB)
        try write("struct TargetType {}", to: target)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: fileA.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: fileB.path, symbolName: "foreignFirstWinner", referencedTypes: ["TargetType"])
            ),
            WorkspaceObservedCodemapResult(fullPath: fileB.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileB.path, symbolName: "ownSecondWinner")),
            WorkspaceObservedCodemapResult(fullPath: target.path, modificationDate: Date(), fileAPI: makeFileAPI(path: target.path, symbolName: "targetSymbol", className: "TargetType"))
        ])

        let aggregate = await store.codemapFileAPIAggregate()
        let legacyFirstWinners = legacyFirstFileAPIByStandardizedNestedPath(aggregate.orderedFileAPIs)
        XCTAssertEqual(codemapAPIProjection(Array(aggregate.firstFileAPIByStandardizedNestedPath.values)), codemapAPIProjection(Array(legacyFirstWinners.values)))
        XCTAssertNil(aggregate.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)])
        XCTAssertTrue(try XCTUnwrap(aggregate.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileB.path)]).apiDescription.contains("foreignFirstWinner"))

        let mutations = WorkspaceSelectionMutationService(store: store)
        let ownPathSelection = StoredSelection(selectedPaths: [fileA.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: true)
        let ownPathResult = await mutations.recomputeAutoCodemaps(ownPathSelection)
        XCTAssertTrue(ownPathResult.autoCodemapPaths.isEmpty)

        let foreignPathSelection = StoredSelection(selectedPaths: [fileB.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: true)
        let foreignPathResult = await mutations.recomputeAutoCodemaps(foreignPathSelection)
        XCTAssertEqual(foreignPathResult.autoCodemapPaths, [target.path])
    }

    func testCodemapFileAPIAggregateFirstWinnerMatchesLegacyGroupingAcrossOverlappingRoots() async throws {
        let parentRoot = try makeTemporaryRoot(name: "CodemapAPIAggregateOverlap")
        let nestedRoot = parentRoot.appendingPathComponent("Nested", isDirectory: true)
        let sharedFile = nestedRoot.appendingPathComponent("Shared.swift")
        try write("struct Shared {}", to: sharedFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: parentRoot.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: sharedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: sharedFile.path, symbolName: "parentSnapshotSymbol"))
        ])
        _ = try await store.loadRoot(path: nestedRoot.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: sharedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: sharedFile.path, symbolName: "nestedSnapshotSymbol"))
        ])

        let aggregate = await store.codemapFileAPIAggregate()
        let standardizedSharedPath = StandardizedPath.absolute(sharedFile.path)
        let collidingAPIs = aggregate.orderedFileAPIs.filter { StandardizedPath.absolute($0.filePath) == standardizedSharedPath }
        XCTAssertEqual(collidingAPIs.count, 2)
        let legacyFirstWinner = try XCTUnwrap(legacyFirstFileAPIByStandardizedNestedPath(aggregate.orderedFileAPIs)[standardizedSharedPath])
        let aggregateFirstWinner = try XCTUnwrap(aggregate.firstFileAPIByStandardizedNestedPath[standardizedSharedPath])
        XCTAssertEqual(codemapAPIProjection([aggregateFirstWinner]), codemapAPIProjection([legacyFirstWinner]))
    }

    func testAllCodemapFileAPIsCacheInvalidatesObservedReplacementModificationDeletionFolderClearAndStoreIsolation() async throws {
        let root = try makeTemporaryRoot(name: "AllCodemapAPICacheMutation")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let nested = root.appendingPathComponent("Nested/C.swift")
        try write("struct A {}", to: fileA)
        try write("struct B {}", to: fileB)
        try write("struct C {}", to: nested)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileA.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileA.path, symbolName: "oldASymbol"))
        ])
        var APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [fileA.path])

        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileB.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileB.path, symbolName: "bSymbol"))
        ])
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [fileA.path, fileB.path])

        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileA.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileA.path, symbolName: "newASymbol"))
        ])
        var APIs = await store.allCodemapFileAPIs()
        XCTAssertTrue(APIs.contains { $0.apiDescription.contains("newASymbol") })
        XCTAssertFalse(APIs.contains { $0.apiDescription.contains("oldASymbol") })

        _ = try await store.editFile(rootID: record.id, relativePath: "A.swift", newContent: "struct A { let changed = true }")
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [fileB.path])

        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fileA.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileA.path, symbolName: "restoredASymbol")),
            WorkspaceObservedCodemapResult(fullPath: nested.path, modificationDate: Date(), fileAPI: makeFileAPI(path: nested.path, symbolName: "cSymbol"))
        ])
        _ = await store.allCodemapFileAPIs()
        try await store.deleteFile(rootID: record.id, relativePath: "B.swift")
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(Set(APIPaths), [fileA.path, nested.path])
        try await store.moveItemToTrash(rootID: record.id, relativePath: "Nested")
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [fileA.path])

        let isolatedRoot = try makeTemporaryRoot(name: "AllCodemapAPICacheIsolation")
        let isolatedFile = isolatedRoot.appendingPathComponent("Other.swift")
        try write("struct Other {}", to: isolatedFile)
        let isolatedStore = WorkspaceFileContextStore()
        _ = try await isolatedStore.loadRoot(path: isolatedRoot.path)
        await isolatedStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: isolatedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: isolatedFile.path, symbolName: "otherSymbol"))
        ])
        var isolatedAPIPaths = await isolatedStore.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(isolatedAPIPaths, [isolatedFile.path])

        await store.clearAllCodemapCaches(rootFolders: [root.path])
        APIs = await store.allCodemapFileAPIs()
        XCTAssertTrue(APIs.isEmpty)
        isolatedAPIPaths = await isolatedStore.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(isolatedAPIPaths, [isolatedFile.path])
    }

    func testAllCodemapFileAPIsCacheInvalidatesAcrossManagedOnlyMoveTransition() async throws {
        let root = try makeTemporaryRoot(name: "AllCodemapAPICacheManagedOnly")
        let visible = root.appendingPathComponent("Visible.swift")
        let hidden = root.appendingPathComponent("Ignored/Hidden.swift")
        let visibleAgain = root.appendingPathComponent("VisibleAgain.swift")
        try write("Ignored/\n", to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("struct Visible {}", to: visible)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: visible.path, modificationDate: Date(), fileAPI: makeFileAPI(path: visible.path, symbolName: "visibleSymbol"))
        ])
        var APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [visible.path])

        try await store.moveFile(rootID: record.id, from: "Visible.swift", to: "Ignored/Hidden.swift")
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertTrue(APIPaths.isEmpty)
        try await store.moveFile(rootID: record.id, from: "Ignored/Hidden.swift", to: "VisibleAgain.swift")
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: visibleAgain.path, modificationDate: Date(), fileAPI: makeFileAPI(path: visibleAgain.path, symbolName: "visibleAgainSymbol"))
        ])
        APIPaths = await store.allCodemapFileAPIs().map(\.filePath)
        XCTAssertEqual(APIPaths, [visibleAgain.path])
    }

    func testAllCodemapFileAPIsCacheInvalidatesScannerInsertionAndReplacement() async throws {
        let root = try makeTemporaryRoot(name: "AllCodemapAPICacheScanner")
        let file = root.appendingPathComponent("Scanned.swift")
        try write("func firstScannedSymbol() {}", to: file)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        try await store.requestCodemapScan(rootID: record.id, relativePath: "Scanned.swift")
        _ = try await waitForCodemapFileAPI(store: store, containing: "firstScannedSymbol")
        _ = await store.allCodemapFileAPIs()

        try write("func replacementScannedSymbol() {}", to: file)
        try setDiskModificationDate(Date().addingTimeInterval(2), for: file)
        try await store.requestCodemapScan(rootID: record.id, relativePath: "Scanned.swift")
        let replacement = try await waitForCodemapFileAPI(store: store, containing: "replacementScannedSymbol")
        XCTAssertFalse(replacement.apiDescription.contains("firstScannedSymbol"))
    }

    #if DEBUG
        func testAllCodemapFileAPIsCachePreservesRootUnloadReentrantVisibilityInterval() async throws {
            let retainedRoot = try makeTemporaryRoot(name: "AllCodemapAPICacheUnloadRetained")
            let detachedRoot = try makeTemporaryRoot(name: "AllCodemapAPICacheUnloadDetached")
            let retainedFile = retainedRoot.appendingPathComponent("Retained.swift")
            let detachedFile = detachedRoot.appendingPathComponent("Detached.swift")
            try write("struct Retained {}", to: retainedFile)
            try write("struct Detached {}", to: detachedFile)

            let store = WorkspaceFileContextStore()
            let retainedRecord = try await store.loadRoot(path: retainedRoot.path)
            let detachedRecord = try await store.loadRoot(path: detachedRoot.path)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: retainedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: retainedFile.path, symbolName: "retainedSymbol")),
                WorkspaceObservedCodemapResult(fullPath: detachedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: detachedFile.path, symbolName: "detachedSymbol"))
            ])
            var aggregate = await store.codemapFileAPIAggregate()
            var APIPaths = aggregate.orderedFileAPIs.map(\.filePath)
            XCTAssertEqual(Set(APIPaths), [retainedFile.path, detachedFile.path])
            XCTAssertEqual(Set(aggregate.firstFileAPIByStandardizedNestedPath.keys), [retainedFile.path, detachedFile.path])

            let unloadGate = AsyncGate()
            await store.setRootUnloadDidDetachHandler { _ in
                await unloadGate.markStartedAndWaitForRelease()
            }
            let unloadTask = Task { await store.unloadRoot(id: detachedRecord.id) }
            await unloadGate.waitUntilStarted()
            aggregate = await store.codemapFileAPIAggregate()
            APIPaths = aggregate.orderedFileAPIs.map(\.filePath)
            XCTAssertEqual(Set(APIPaths), [retainedFile.path, detachedFile.path])
            XCTAssertEqual(Set(aggregate.firstFileAPIByStandardizedNestedPath.keys), [retainedFile.path, detachedFile.path])

            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: retainedFile.path, modificationDate: Date(), fileAPI: makeFileAPI(path: retainedFile.path, symbolName: "retainedReplacement"))
            ])
            aggregate = await store.codemapFileAPIAggregate()
            APIPaths = aggregate.orderedFileAPIs.map(\.filePath)
            XCTAssertEqual(Set(APIPaths), [retainedFile.path, detachedFile.path])
            XCTAssertEqual(Set(aggregate.firstFileAPIByStandardizedNestedPath.keys), [retainedFile.path, detachedFile.path])

            await unloadGate.release()
            await unloadTask.value
            await store.setRootUnloadDidDetachHandler(nil)
            aggregate = await store.codemapFileAPIAggregate()
            APIPaths = aggregate.orderedFileAPIs.map(\.filePath)
            XCTAssertEqual(APIPaths, [retainedFile.path])
            XCTAssertEqual(Set(aggregate.firstFileAPIByStandardizedNestedPath.keys), [retainedFile.path])
        }
    #endif

    private func codemapAPIProjection(_ APIs: [FileAPI]) -> [String] {
        APIs.map { "\($0.filePath)|\($0.apiDescription)" }.sorted()
    }

    private func legacyFirstFileAPIByStandardizedNestedPath(_ APIs: [FileAPI]) -> [String: FileAPI] {
        var firstFileAPIByStandardizedNestedPath: [String: FileAPI] = [:]
        for api in APIs {
            let standardizedNestedPath = StandardizedPath.absolute(api.filePath)
            if firstFileAPIByStandardizedNestedPath[standardizedNestedPath] == nil {
                firstFileAPIByStandardizedNestedPath[standardizedNestedPath] = api
            }
        }
        return firstFileAPIByStandardizedNestedPath
    }

    private func waitForCodemapFileAPI(store: WorkspaceFileContextStore, containing symbol: String) async throws -> FileAPI {
        for _ in 0 ..< 100 {
            if let API = await store.allCodemapFileAPIs().first(where: { $0.apiDescription.contains(symbol) }) {
                return API
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for codemap symbol: \(symbol)")
        throw NSError(domain: "WorkspaceFileContextStoreTests", code: 1)
    }

    #if DEBUG
        private func startAllCodemapFileAPIsCapture(label: String) {
            EditFlowPerf.resetDebugCaptureForTesting()
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("All codemap file APIs capture should start")
            }
        }

        private func allCodemapFileAPIsBucket(_ snapshot: EditFlowPerf.DebugCaptureSnapshot, stage: StaticString) -> EditFlowPerf.DebugCaptureStageAggregate? {
            snapshot.stages.first { $0.stageName == String(describing: stage) }
        }
    #endif

    @MainActor
    private func waitForFile(manager: WorkspaceFilesViewModel, fullPath: String, id: UUID? = nil) async throws -> FileViewModel {
        for _ in 0 ..< 50 {
            if let file = manager.findFileByFullPath(fullPath), id.map({ file.id == $0 }) ?? true {
                return file
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let file = try XCTUnwrap(manager.findFileByFullPath(fullPath))
        if let id { XCTAssertEqual(file.id, id) }
        return file
    }

    @MainActor
    private func waitForFolder(manager: WorkspaceFilesViewModel, fullPath: String, id: UUID? = nil) async throws -> FolderViewModel {
        for _ in 0 ..< 50 {
            if let folder = manager.findFolderByFullPath(fullPath), id.map({ folder.id == $0 }) ?? true {
                return folder
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let folder = try XCTUnwrap(manager.findFolderByFullPath(fullPath))
        if let id { XCTAssertEqual(folder.id, id) }
        return folder
    }

    #if DEBUG
        private func startSearchCatalogSnapshotCapture(label: String) {
            EditFlowPerf.resetDebugCaptureForTesting()
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("Search catalog snapshot capture should start")
            }
        }

        private func searchCatalogSnapshotBuckets(_ snapshot: EditFlowPerf.DebugCaptureSnapshot) -> [EditFlowPerf.DebugCaptureStageAggregate] {
            snapshot.stages.filter { $0.stageName == String(describing: EditFlowPerf.Stage.Search.catalogSnapshot) }
        }
    #endif

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setDiskModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String = "codemapOnlySymbol",
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.lowerBound])
    }
}
