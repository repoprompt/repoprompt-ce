import Combine
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceFileContextStoreTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
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
        let codemapSnapshotBundle = await store.codemapSnapshotBundle()
        let resolution = await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .selected,
            codemapSnapshotBundle: codemapSnapshotBundle
        )

        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Summarize",
            files: resolution.entries,
            fileTreeContent: nil,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .relative,
            codemapSnapshotBundle: codemapSnapshotBundle,
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

    #if DEBUG

        func testCancelledOverwriteSettlesBeforeUncancellableIOAndReconcilesCatalogAfterCompletion() async throws {
            let root = try makeTemporaryRoot(name: "CancelledOverwriteReconciliation")
            let fileURL = root.appendingPathComponent("OverwriteAfterCancellation.swift")
            try write("old", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(loadedService)
            let publications = LockedFileSystemPublications()
            let publicationCancellable = await service.publisherForChanges().sink { publications.append($0) }
            let mutationGate = AsyncGate()
            await service.setMutationIOWillBeginHandlerForTesting { operation in
                guard operation == .edit else { return }
                await mutationGate.markStartedAndWaitForRelease()
            }
            let host = WorkspaceFileEditHost(
                store: store,
                lookupRootScope: .visibleWorkspace,
                createPathResolutionPolicy: .literalPreferredIfStronger,
                selectCreatedFiles: false
            )

            let overwriteTask = Task {
                try await host.writeText(
                    path: fileURL.path,
                    content: "new",
                    overwrite: true
                )
            }
            await mutationGate.waitUntilStarted()
            let settledSignal = AsyncSignal()
            let resultTask = Task {
                do {
                    try await overwriteTask.value
                    await settledSignal.mark()
                    return false
                } catch is CancellationError {
                    await settledSignal.mark()
                    return true
                } catch {
                    await settledSignal.mark()
                    return false
                }
            }

            overwriteTask.cancel()
            let settledBeforeRelease = await waitForAsyncCondition(timeout: .seconds(2)) {
                await settledSignal.isMarked()
            }
            XCTAssertTrue(settledBeforeRelease)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "old")
            let waiterCountAfterCancellation = await service.pendingMutationWaiterCountForTesting()
            XCTAssertEqual(waiterCountAfterCancellation, 0)

            await mutationGate.release()
            let observedCancellation = await resultTask.value
            XCTAssertTrue(observedCancellation)
            let reconciled = await waitForAsyncCondition(timeout: .seconds(5)) {
                guard (try? String(contentsOf: fileURL, encoding: .utf8)) == "new" else { return false }
                return await (try? store.readContent(
                    rootID: record.id,
                    relativePath: "OverwriteAfterCancellation.swift"
                )) == "new"
            }
            XCTAssertTrue(reconciled)
            let catalogFile = await store.file(rootID: record.id, relativePath: "OverwriteAfterCancellation.swift")
            XCTAssertNotNil(catalogFile)
            let finalWaiterCount = await service.pendingMutationWaiterCountForTesting()
            XCTAssertEqual(finalWaiterCount, 0)
            let fallbackPublished = await waitForAsyncCondition(timeout: .seconds(2)) {
                publications.snapshot().contains { publication in
                    publication.source == .syntheticMutation
                        && publication.deltas.contains { delta in
                            guard case let .fileModified(relativePath, _) = delta else { return false }
                            return relativePath == "OverwriteAfterCancellation.swift"
                        }
                }
            }
            XCTAssertTrue(fallbackPublished)
            let matchingFallbackPublications = publications.snapshot().filter { publication in
                publication.source == .syntheticMutation
                    && publication.deltas.contains { delta in
                        guard case let .fileModified(relativePath, _) = delta else { return false }
                        return relativePath == "OverwriteAfterCancellation.swift"
                    }
            }
            XCTAssertEqual(matchingFallbackPublications.count, 1)
            let pendingDeferredPublicationCount = await service.pendingDeferredEditPublicationCountForTesting()
            XCTAssertEqual(pendingDeferredPublicationCount, 0)

            await service.setMutationIOWillBeginHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
            withExtendedLifetime(publicationCancellable) {}

            let postTokenRoot = try makeTemporaryRoot(name: "CancelledOverwriteAfterDeferredToken")
            let postTokenFileURL = postTokenRoot.appendingPathComponent("PostToken.swift")
            try write("old", to: postTokenFileURL)
            let postTokenStore = WorkspaceFileContextStore()
            let postTokenRecord = try await postTokenStore.loadRoot(path: postTokenRoot.path)
            try await postTokenStore.startWatchingRoot(id: postTokenRecord.id)
            let maybePostTokenService = await postTokenStore.fileSystemServiceForTesting(rootID: postTokenRecord.id)
            let postTokenService = try XCTUnwrap(maybePostTokenService)
            let postTokenPublications = LockedFileSystemPublications()
            let postTokenPublisher = await postTokenService.publisherForChanges()
            let postTokenCancellable = postTokenPublisher.sink { postTokenPublications.append($0) }
            let postTokenGate = AsyncGate()
            await postTokenStore.setStoreEditDeferredPublicationDidRegisterHandlerForTesting { rootID, relativePath in
                guard rootID == postTokenRecord.id, relativePath == "PostToken.swift" else { return }
                await postTokenGate.markStartedAndWaitForRelease()
            }

            let postTokenEditTask = Task {
                try await postTokenStore.editFile(
                    rootID: postTokenRecord.id,
                    relativePath: "PostToken.swift",
                    newContent: "new"
                )
            }
            await postTokenGate.waitUntilStarted()
            postTokenEditTask.cancel()
            await postTokenGate.release()
            do {
                _ = try await postTokenEditTask.value
                XCTFail("Expected cancellation after deferred publication registration")
            } catch is CancellationError {
                // Expected.
            }

            let postTokenReconciled = await waitForAsyncCondition(timeout: .seconds(5)) {
                await (try? postTokenStore.readContent(
                    rootID: postTokenRecord.id,
                    relativePath: "PostToken.swift"
                )) == "new"
            }
            XCTAssertTrue(postTokenReconciled)
            let postTokenSyntheticPublications = postTokenPublications.snapshot().filter { publication in
                publication.source == .syntheticMutation
                    && publication.deltas.contains { delta in
                        guard case let .fileModified(relativePath, _) = delta else { return false }
                        return relativePath == "PostToken.swift"
                    }
            }
            XCTAssertEqual(postTokenSyntheticPublications.count, 1)
            let postTokenPendingCount = await postTokenService.pendingDeferredEditPublicationCountForTesting()
            XCTAssertEqual(postTokenPendingCount, 0)

            await postTokenStore.setStoreEditDeferredPublicationDidRegisterHandlerForTesting(nil)
            await postTokenStore.stopWatchingRoot(id: postTokenRecord.id)
            withExtendedLifetime(postTokenCancellable) {}
        }

        #if DEBUG

        #endif

        func testCancelledReadFreshnessJoinThrowsBeforeCanonicalFlightCompletes() async throws {
            let root = try makeTemporaryRoot(name: "ReadFreshnessCancellation")
            let fileURL = root.appendingPathComponent("Seed.swift")
            try write("seed", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let completed = AsyncSignal()
            let request = Task { () -> Bool in
                let wasCancelled: Bool
                do {
                    let service = WorkspaceReadableFileService(store: store)
                    try await service.awaitFreshnessForExplicitRequest(
                        fileURL.path,
                        fallbackScope: .visibleWorkspace
                    )
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    wasCancelled = false
                }
                await completed.mark()
                return wasCancelled
            }
            await flushGate.waitUntilStarted()
            request.cancel()
            let cancelledPromptly = await waitForAsyncCondition {
                await completed.isMarked()
            }
            XCTAssertTrue(cancelledPromptly)

            await flushGate.release()
            let wasCancelled = await request.value
            XCTAssertTrue(wasCancelled)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

    #endif

    func testExplicitMaterializationUpdatesWarmSearchCatalogWithoutExposingManagedOnlyFiles() async throws {
        do {
            let caseLabel = "testEnsureIndexedFilesClearsWarmSearchSnapshotAcrossMultipleLateFiles"
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
            XCTAssertEqual(indexed, [lateA.path, lateB.path], caseLabel)

            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(Set(snapshot.files.map(\.standardizedRelativePath)), ["LateA.swift", "Nested/LateB.swift", "Seed.swift"], caseLabel)
        }

        do {
            let caseLabel = "testSearchCatalogSnapshotCacheKeepsManagedOnlyIgnoredFileHiddenAndReflectsPromotion"
            let root = try makeTemporaryRoot(name: "SearchSnapshotManagedOnlyPromotion")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

            try await host.writeText(path: "Hidden.ignored", content: "hidden", overwrite: false)
            var snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let hiddenRecord = await store.file(rootID: record.id, relativePath: "Hidden.ignored")
            XCTAssertNotNil(hiddenRecord, caseLabel)
            XCTAssertFalse(snapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" }, caseLabel)
            let warmHiddenSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(warmHiddenSnapshot, snapshot, caseLabel)

            try await store.moveFile(rootID: record.id, from: "Hidden.ignored", to: "Visible.md")
            snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(snapshot.files.contains { $0.standardizedRelativePath == "Visible.md" }, caseLabel)
            XCTAssertFalse(snapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" }, caseLabel)
        }
    }

    #if DEBUG

    #endif

    #if DEBUG

        func testValidatedSessionScopeRejectsSamePathRootReplacement() async throws {
            let logicalRoot = try makeTemporaryRoot(name: "ValidatedSessionLogical")
            let worktree = try makeTemporaryRoot(name: "ValidatedSessionWorktree")
            try write("logical", to: logicalRoot.appendingPathComponent("Logical.swift"))
            try write("initial", to: worktree.appendingPathComponent("Target.swift"))

            let store = WorkspaceFileContextStore()
            let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
            let initialWorktreeRecord = try await store.loadRoot(
                path: worktree.path,
                kind: .sessionWorktree
            )
            let scope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(
                canonicalRoots: [WorkspaceRootRef(
                    id: logicalRecord.id,
                    name: logicalRecord.name,
                    fullPath: logicalRecord.standardizedFullPath
                )],
                physicalRoots: [WorkspaceRootRef(
                    id: initialWorktreeRecord.id,
                    name: initialWorktreeRecord.name,
                    fullPath: initialWorktreeRecord.standardizedFullPath
                )]
            )
            let initialAvailability = await store.rootScopeAvailability(scope)
            let initialRootIDs = await Set(store.rootRefs(scope: scope).map(\.id))
            XCTAssertEqual(initialAvailability, .available)
            XCTAssertEqual(
                initialRootIDs,
                [logicalRecord.id, initialWorktreeRecord.id]
            )

            await store.unloadRoot(id: initialWorktreeRecord.id)
            try write("replacement", to: worktree.appendingPathComponent("Target.swift"))
            let replacement = try await store.loadRoot(path: worktree.path, kind: .sessionWorktree)
            XCTAssertNotEqual(replacement.id, initialWorktreeRecord.id)

            let replacementAvailability = await store.rootScopeAvailability(scope)
            let replacementScopedRootIDs = await store.rootRefs(scope: scope).map(\.id)
            let replacementCatalogAccess = await store.searchCatalogAccess(rootScope: scope)
            let replacementLookup = await store.lookupPath(
                worktree.appendingPathComponent("Target.swift").path,
                profile: .mcpRead,
                rootScope: scope
            )
            XCTAssertEqual(
                replacementAvailability,
                .sessionWorktreeUnavailable(missingPhysicalRootPaths: [worktree.standardizedFileURL.path])
            )
            XCTAssertEqual(replacementScopedRootIDs, [logicalRecord.id])
            XCTAssertEqual(
                replacementCatalogAccess,
                .unavailable(.sessionWorktreeUnavailable(
                    missingPhysicalRootPaths: [worktree.standardizedFileURL.path]
                ))
            )
            XCTAssertNil(replacementLookup)
            let replacementTarget = worktree.appendingPathComponent("Target.swift")
            let rejectedCreate = worktree.appendingPathComponent("ShouldNotExist.swift")
            let rejectedCanonicalCreate = logicalRoot.appendingPathComponent("ShouldAlsoNotExist.swift")
            do {
                _ = try await WorkspaceFileMutationService(store: store).createFileWithPostcondition(
                    userPath: rejectedCreate.path,
                    content: "must not be written",
                    rootScope: scope
                )
                XCTFail("Expected stale validated scope to reject mutation")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedCreate.path))
            }
            do {
                _ = try await WorkspaceFileMutationService(store: store).createFileWithPostcondition(
                    userPath: rejectedCanonicalCreate.path,
                    content: "must not be written",
                    rootScope: scope
                )
                XCTFail("Expected unavailable validated scope to reject canonical-root mutation")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedCanonicalCreate.path))
            }
            let atomicallyRejectedCreate = logicalRoot.appendingPathComponent("AtomicShouldNotExist.swift")
            do {
                _ = try await store.createFile(
                    rootID: logicalRecord.id,
                    relativePath: atomicallyRejectedCreate.lastPathComponent,
                    content: "must not be written",
                    validating: scope
                )
                XCTFail("Expected store write admission to revalidate the full scope atomically")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: atomicallyRejectedCreate.path))
            }
            XCTAssertEqual(try String(contentsOf: replacementTarget, encoding: .utf8), "replacement")
        }

    #endif
    func testFileTreeRequestsCoverFoldersDepthAndResolvedSubtree() async throws {
        do {
            let caseLabel = "testFileTreeSnapshotSupportsFoldersOnlyMode"
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

            XCTAssertTrue(tree.contains("Sources"), caseLabel)
            XCTAssertTrue(tree.contains("Selected.swift *"), caseLabel)
            XCTAssertFalse(tree.contains("Other.swift"), caseLabel)
            XCTAssertFalse(tree.contains("README.md"), caseLabel)
        }

        do {
            let caseLabel = "testFileTreeSnapshotHonorsExplicitMaxDepth"
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

            XCTAssertTrue(tree.contains("Sources"), caseLabel)
            XCTAssertTrue(tree.contains("Top.swift"), caseLabel)
            XCTAssertTrue(tree.contains("..."), caseLabel)
            XCTAssertFalse(tree.contains("Deep.swift"), caseLabel)
        }

        do {
            let caseLabel = "testFileTreeSnapshotCanStartAtResolvedSubtree"
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

            XCTAssertEqual(snapshot.roots.count, 1, caseLabel)
            XCTAssertTrue(tree.contains("Sources"), caseLabel)
            XCTAssertTrue(tree.contains("A.swift"), caseLabel)
            XCTAssertTrue(tree.contains("Nested"), caseLabel)
            XCTAssertTrue(tree.contains("B.swift"), caseLabel)
            XCTAssertFalse(tree.contains("Other.swift"), caseLabel)
        }
    }

    func testAmbiguousLookupConsumersFailWithoutMaterializingCandidates() async throws {
        do {
            let caseLabel = "testValuePathResolutionReportsAmbiguousRelativePathWithExistingRendererMessage"
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
            let issue = try XCTUnwrap(maybeIssue, caseLabel)
            let message = PathResolutionIssueRenderer.message(for: issue)
            XCTAssertTrue(message.contains("matches multiple workspace roots"), caseLabel)
            XCTAssertTrue(message.contains("SharedRoot"), caseLabel)
        }

        do {
            let caseLabel = "testAmbiguousRelativeIgnoredFileDoesNotMaterializeEitherRoot"
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
            XCTAssertNil(readable, caseLabel)
            XCTAssertNil(storedA, caseLabel)
            XCTAssertNil(storedB, caseLabel)

            do {
                _ = try await WorkspaceFileMutationService(store: store).resolveExactExistingFileForMutation("same.ignored", rootScope: .visibleWorkspace)
                XCTFail(caseLabel + ": " + "Expected ambiguous ignored mutation target to fail")
            } catch let error as FileManagerError {
                guard case let .fileSystemServiceNotFoundWithContext(message) = error else {
                    return XCTFail(caseLabel + ": " + "Unexpected error: \(error)")
                }
                XCTAssertTrue(message.contains("Unknown or unloaded path"), caseLabel + ": " + message)
            }
        }

        do {
            let caseLabel = "testAmbiguousAliasIsTerminalForExplicitReadAndSelectionLookup"
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
            XCTAssertEqual(catalogLookup, .ambiguous, caseLabel)
            let explicit = try await store.materializeExplicitlyRequestedFile("App/secret.ignored", rootScope: .visibleWorkspace)
            XCTAssertEqual(explicit, .noCandidate, caseLabel)
            let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile("App/secret.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)
            XCTAssertNil(readable, caseLabel)

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
            XCTAssertTrue(snapshot.selectedFileIDs.isEmpty, caseLabel)
        }
    }

    func testSelectionMutationCoversFolderExpansionCodemapFilteringAndStoredValueTransitions() async throws {
        do {
            let caseLabel = "testFolderExpansionAndSelectionMutationServiceAreDeterministicByRelativePath"
            let root = try makeTemporaryRoot(name: "SelectionMutation")
            try write("b", to: root.appendingPathComponent("Sources/B.swift"))
            try write("a", to: root.appendingPathComponent("Sources/Nested/A.swift"))
            try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let service = WorkspaceSelectionMutationService(store: store)

            let expansion = await store.expandFolderInputToFiles("Sources", rootScope: .visibleWorkspace)
            XCTAssertTrue(expansion.handled, caseLabel)
            XCTAssertEqual(expansion.files.map(\.standardizedRelativePath), [
                "Sources/B.swift",
                "Sources/Nested/A.swift",
                "Sources/notes.txt"
            ], caseLabel)

            let addResult = await service.addPaths(
                existing: StoredSelection(),
                paths: ["Sources"],
                rawPaths: ["Sources"],
                mode: "full",
                rootScope: .visibleWorkspace
            )
            XCTAssertTrue(addResult.mutated, caseLabel)
            XCTAssertEqual(addResult.selection.selectedPaths, expansion.files.map(\.standardizedFullPath), caseLabel)
            XCTAssertEqual(addResult.resolvedMap["Sources"], "Sources", caseLabel)
        }

        do {
            let caseLabel = "testCodemapOnlyCandidateFilteringPreservesUnsupportedMessages"
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
            XCTAssertTrue(fileOnly.candidates.isEmpty, caseLabel)
            XCTAssertEqual(fileOnly.codemapUnavailable, ["codemap unavailable: Sources/notes.txt"], caseLabel)

            let folder = await service.resolveCodemapOnlyCandidates(
                paths: ["Sources"],
                rawPaths: ["Sources"],
                expandFolders: true,
                rootScope: .visibleWorkspace
            )
            XCTAssertEqual(folder.candidates.map(\.standardizedRelativePath), ["Sources/A.swift"], caseLabel)
            XCTAssertEqual(folder.codemapUnavailable, ["codemap unavailable: 1 file(s) in Sources skipped (unsupported)"], caseLabel)
        }

        do {
            let caseLabel = "testSelectionMutationPromoteDemoteAndRemoveOperateOnStoredSelectionValues"
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
            XCTAssertTrue(demoted.mutated, caseLabel)
            XCTAssertEqual(demoted.selection.selectedPaths, [textURL.path], caseLabel)
            XCTAssertEqual(demoted.selection.autoCodemapPaths, [swiftURL.path], caseLabel)
            XCTAssertTrue(demoted.selection.slices.isEmpty, caseLabel)
            XCTAssertEqual(demoted.codemapUnavailable, ["codemap unavailable: notes.txt"], caseLabel)
            XCTAssertFalse(demoted.selection.codemapAutoEnabled, caseLabel)

            let promoted = await service.promotePaths(existing: demoted.selection, paths: [swiftURL.path], rawPaths: [swiftURL.path])
            XCTAssertTrue(promoted.mutated, caseLabel)
            XCTAssertEqual(Set(promoted.selection.selectedPaths), Set([swiftURL.path, textURL.path]), caseLabel)
            XCTAssertTrue(promoted.selection.autoCodemapPaths.isEmpty, caseLabel)
            XCTAssertFalse(promoted.selection.codemapAutoEnabled, caseLabel)

            let removed = await service.removePaths(existing: promoted.selection, paths: [swiftURL.path], rawPaths: [swiftURL.path])
            XCTAssertTrue(removed.mutated, caseLabel)
            XCTAssertEqual(removed.selection.selectedPaths, [textURL.path], caseLabel)
        }
    }

    func testManageSelectionPositiveSliceMutationsPreserveFullFilesAndAddMixedSlices() async throws {
        do {
            let caseLabel = "testManageSelectionSliceSetPreservesFullFilesAndReplacesOnlySpecifiedSlices"
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

            XCTAssertTrue(added.invalidPaths.isEmpty, caseLabel)
            XCTAssertEqual(Set(added.selection.selectedPaths), Set([fullURL.path, firstURL.path, secondURL.path]), caseLabel)
            XCTAssertEqual(added.selection.slices[firstURL.path], [LineRange(start: 1, end: 2)], caseLabel)
            XCTAssertEqual(added.selection.slices[secondURL.path], [LineRange(start: 5, end: 6)], caseLabel)

            let replaced = await service.buildManageSelectionSet(
                paths: [],
                slices: [WorkspaceSelectionSliceInput(path: firstURL.path, ranges: [LineRange(start: 3, end: 4)])],
                mode: "slices",
                existing: added.selection
            )

            XCTAssertTrue(replaced.invalidPaths.isEmpty, caseLabel)
            XCTAssertEqual(Set(replaced.selection.selectedPaths), Set([fullURL.path, firstURL.path, secondURL.path]), caseLabel)
            XCTAssertNil(replaced.selection.slices[fullURL.path], caseLabel)
            XCTAssertEqual(replaced.selection.slices[firstURL.path], [LineRange(start: 3, end: 4)], caseLabel)
            XCTAssertEqual(replaced.selection.slices[secondURL.path], [LineRange(start: 5, end: 6)], caseLabel)
        }

        do {
            let caseLabel = "testManageSelectionMixedAddPreservesExistingFullFilesAndAddsSlices"
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

            XCTAssertTrue(addFull.invalidPaths.isEmpty, caseLabel)
            XCTAssertTrue(addSlice.invalidPaths.isEmpty, caseLabel)
            XCTAssertEqual(addSlice.selection.selectedPaths, [existingURL.path, addedFullURL.path, addedSliceURL.path], caseLabel)
            XCTAssertEqual(addSlice.selection.slices[addedSliceURL.path], [LineRange(start: 1, end: 2)], caseLabel)
        }
    }

    func testManageSelectionSetValidationAndDestructiveModesPreserveContracts() async throws {
        do {
            let caseLabel = "testManageSelectionSliceSetRejectsInvalidRequestsWithoutMutation"
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
            XCTAssertEqual(barePath.selection, initial, caseLabel)
            XCTAssertEqual(barePath.invalidPaths, ["mode 'slices' requires line ranges for paths: \(fileURL.path). Use #L ranges, the slices array, or op='add' mode='full' for whole files."], caseLabel)

            let empty = await service.buildManageSelectionSet(
                paths: [],
                slices: [],
                mode: "slices",
                existing: initial
            )
            XCTAssertEqual(empty.selection, initial, caseLabel)
            XCTAssertEqual(empty.invalidPaths, ["mode 'slices' requires a non-empty slices array or #L line ranges on paths."], caseLabel)

            let parseFailure = await service.buildManageSelectionSet(
                paths: [],
                slices: [],
                sliceErrors: ["Invalid slice 'abc' for path 'A.swift#Labc'"],
                mode: "slices",
                existing: initial
            )
            XCTAssertEqual(parseFailure.selection, initial, caseLabel)
            XCTAssertEqual(parseFailure.invalidPaths, ["Invalid slice 'abc' for path 'A.swift#Labc'"], caseLabel)
        }

        do {
            let caseLabel = "testManageSelectionCodemapOnlySetRejectsSlices"
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

            XCTAssertEqual(result.selection, initial, caseLabel)
            XCTAssertEqual(result.invalidPaths, ["mode 'codemap_only' cannot be used with slices"], caseLabel)
        }

        do {
            let caseLabel = "testManageSelectionFullSetWithSlicesRemainsDestructive"
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

            XCTAssertTrue(result.invalidPaths.isEmpty, caseLabel)
            XCTAssertEqual(result.selection.selectedPaths, [newFullURL.path, newSliceURL.path], caseLabel)
            XCTAssertEqual(result.selection.slices, [newSliceURL.path: [LineRange(start: 2, end: 3)]], caseLabel)
            XCTAssertFalse(result.selection.selectedPaths.contains(oldFullURL.path), caseLabel)
            XCTAssertNil(result.selection.slices[oldSliceURL.path], caseLabel)
        }
    }

    func testWriteAdaptersAndApplyEditsMaterializeCreateOverwriteAndFailurePostconditions() async throws {
        do {
            let caseLabel = "testWorkspaceFileMutationServiceCreatesReadsAndOverwritesThroughStore"
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
            XCTAssertEqual(created.standardizedRelativePath, "Created.swift", caseLabel)
            let createdStoreContent = try await store.readContent(rootID: record.id, relativePath: "Created.swift")
            XCTAssertEqual(createdStoreContent, "created", caseLabel)
            let createdServiceContent = try await service.readText(file: created)
            XCTAssertEqual(createdServiceContent, "created", caseLabel)

            let existing = try await service.resolveExactExistingFileForMutation("Existing.swift", rootScope: .visibleWorkspace)
            try await service.overwrite(file: existing, content: "new")
            let overwrittenContent = try await store.readContent(rootID: record.id, relativePath: "Existing.swift")
            XCTAssertEqual(overwrittenContent, "new", caseLabel)
            let exactExisting = await service.exactExistingFile("Existing.swift", rootScope: .visibleWorkspace)
            XCTAssertNotNil(exactExisting, caseLabel)
        }

        do {
            let caseLabel = "testWorkspaceFileEditHostOverwriteCreatesMissingAndReplacesExisting"
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
            XCTAssertEqual(createdContent, "created", caseLabel)

            try await host.writeText(path: "Existing.swift", content: "new", overwrite: true)
            let overwrittenContent = try await store.readContent(rootID: record.id, relativePath: "Existing.swift")
            XCTAssertEqual(overwrittenContent, "new", caseLabel)
        }

        do {
            let caseLabel = "testApplyEditsRewriteCreateImmediatelyMaterializesForStoreLookupAndRead"
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

            XCTAssertTrue(result.fileCreated, caseLabel)
            let createdFile = await store.file(rootID: record.id, relativePath: "Created.swift")
            let recordFromStore = try XCTUnwrap(createdFile, caseLabel)
            XCTAssertEqual(recordFromStore.standardizedRelativePath, "Created.swift", caseLabel)
            let createdContent = try await store.readContent(rootID: record.id, relativePath: "Created.swift")
            XCTAssertEqual(createdContent, "struct Created {}\n", caseLabel)
            let createdLookup = await store.lookupPath("Created.swift", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            XCTAssertNotNil(createdLookup, caseLabel)
            let lookupFiles = await store.lookupFiles(atPaths: ["Created.swift"], profile: .mcpRead, rootScope: .visibleWorkspace)
            XCTAssertEqual(lookupFiles["Created.swift"]?.id, recordFromStore.id, caseLabel)
        }

        do {
            let caseLabel = "testMaterializationFailureReportsClearPostconditionError"
            let root = try makeTemporaryRoot(name: "MaterializationFailure")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)

            do {
                _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: record.id, relativePath: "Missing.swift")
                XCTFail(caseLabel + ": " + "Expected missing post-write file to fail catalog materialization")
            } catch let error as WorkspaceFileContextStoreError {
                guard case let .catalogMaterializationFailed(message) = error else {
                    return XCTFail(caseLabel + ": " + "Unexpected store error: \(error)")
                }
                XCTAssertTrue(message.contains("not catalog-eligible"), caseLabel)
                XCTAssertTrue(message.contains("missing"), caseLabel)
                XCTAssertTrue(error.localizedDescription.contains(message), caseLabel)
            }
        }
    }

    func testIgnoredFilesRemainExactlyManageableAcrossVisibilityAndMoveTransitions() async throws {
        do {
            let caseLabel = "testIgnoredCreateRemainsExactlyManageableWithoutDiscoveryExposure"
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
            XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredURL.path), caseLabel)
            let storedIgnoredFile = await store.file(rootID: record.id, relativePath: "secret.ignored")
            let ignoredFile = try XCTUnwrap(storedIgnoredFile, caseLabel)
            XCTAssertEqual(ignoredFile.standardizedFullPath, ignoredURL.path, caseLabel)

            let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .workspace(readableFile) = readable else {
                return XCTFail(caseLabel + ": " + "Ignored exact path should resolve as a workspace file")
            }
            XCTAssertEqual(readableFile.id, ignoredFile.id, caseLabel)

            let editService = ApplyEditsService(engine: .default, host: host)
            _ = try await editService.run(ApplyEditsRequest(
                path: "secret.ignored",
                mode: .single(search: "token", replace: "edited", replaceAll: false),
                verbose: false
            ))
            let editedContent = try await store.readContent(rootID: record.id, relativePath: "secret.ignored")
            XCTAssertEqual(editedContent, "ignored edited", caseLabel)

            let ignoredFuzzyLookup = await store.lookupPath("secret.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            let discoverableFiles = await store.files(inRoot: record.id)
            let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let rootChildren = await store.directFolderChildren(rootID: record.id)
            XCTAssertNil(ignoredFuzzyLookup, caseLabel)
            XCTAssertFalse(discoverableFiles.contains { $0.standardizedRelativePath == "secret.ignored" }, caseLabel)
            XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "secret.ignored" }, caseLabel)
            XCTAssertFalse(rootChildren?.childFiles.contains { $0.standardizedRelativePath == "secret.ignored" } ?? true, caseLabel)
            let ignoredFolderChildrenBeforeReplay = await store.directFolderChildren(rootID: record.id, relativePath: "ignored")
            XCTAssertNil(ignoredFolderChildrenBeforeReplay, caseLabel)
            let ignoredFolderExpansion = await store.expandFolderInputToFiles("ignored", rootScope: .visibleWorkspace)
            XCTAssertFalse(ignoredFolderExpansion.handled, caseLabel)
            await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.folderAdded("ignored")])
            let ignoredFolderChildrenAfterReplay = await store.directFolderChildren(rootID: record.id, relativePath: "ignored")
            XCTAssertNil(ignoredFolderChildrenAfterReplay, caseLabel)

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
            XCTAssertFalse(tree.contains("secret.ignored"), caseLabel + ": " + tree)
            XCTAssertFalse(tree.contains("ignored"), caseLabel + ": " + tree)
            XCTAssertFalse(tree.contains("report.md"), caseLabel + ": " + tree)

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
            XCTAssertTrue(selectedTree.contains("secret.ignored"), caseLabel + ": " + selectedTree)
            XCTAssertFalse(selectedTree.contains("report.md"), caseLabel + ": " + selectedTree)

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
            XCTAssertTrue(ignoredSubtree.roots.isEmpty, caseLabel)
        }

        do {
            let caseLabel = "testVisibleSiblingPromotesManagedOnlyParentWithoutExposingIgnoredSibling"
            let root = try makeTemporaryRoot(name: "IgnoredParentPromotion")
            try write("private/*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

            try await host.writeText(path: "private/secret.ignored", content: "hidden", overwrite: false)
            let hiddenParentChildren = await store.directFolderChildren(rootID: record.id, relativePath: "private")
            XCTAssertNil(hiddenParentChildren, caseLabel)
            try await host.writeText(path: "private/public.md", content: "visible", overwrite: false)

            let children = await store.directFolderChildren(rootID: record.id, relativePath: "private")
            XCTAssertEqual(children?.childFiles.map(\.standardizedRelativePath), ["private/public.md"], caseLabel)
            let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(searchSnapshot.files.contains { $0.standardizedRelativePath == "private/public.md" }, caseLabel)
            XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "private/secret.ignored" }, caseLabel)
        }

        do {
            let caseLabel = "testExistingIgnoredFileMaterializesOnlyForExactReadAndEdit"
            let root = try makeTemporaryRoot(name: "ExistingIgnoredExact")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let ignoredURL = root.appendingPathComponent("existing.ignored")
            try write("old", to: ignoredURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let ignoredBeforeExactRead = await store.file(rootID: record.id, relativePath: "existing.ignored")
            XCTAssertNil(ignoredBeforeExactRead, caseLabel)

            let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .workspace(file) = readable else {
                return XCTFail(caseLabel + ": " + "Existing ignored exact path should materialize for read_file semantics")
            }
            XCTAssertEqual(file.standardizedFullPath, ignoredURL.path, caseLabel)

            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
            try await host.writeText(path: ignoredURL.path, content: "new", overwrite: true)
            let editedContent = try await store.readContent(rootID: record.id, relativePath: "existing.ignored")
            let fuzzyLookup = await store.lookupPath("existing.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(editedContent, "new", caseLabel)
            XCTAssertNil(fuzzyLookup, caseLabel)
            XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "existing.ignored" }, caseLabel)
        }

        do {
            let caseLabel = "testMoveTransitionsBetweenDiscoverableAndManagedOnlyIgnoredFiles"
            let root = try makeTemporaryRoot(name: "IgnoredMove")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            try write("visible", to: root.appendingPathComponent("Visible.md"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)

            try await store.moveFile(rootID: record.id, from: "Visible.md", to: "Hidden.ignored")
            let hiddenFile = await store.file(rootID: record.id, relativePath: "Hidden.ignored")
            let hiddenLookup = await store.lookupPath("Hidden.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            XCTAssertNotNil(hiddenFile, caseLabel)
            XCTAssertNil(hiddenLookup, caseLabel)
            var searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath == "Hidden.ignored" }, caseLabel)

            try await store.moveFile(rootID: record.id, from: "Hidden.ignored", to: "VisibleAgain.md")
            let visibleAgainLookup = await store.lookupPath("VisibleAgain.md", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            XCTAssertNotNil(visibleAgainLookup, caseLabel)
            searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(searchSnapshot.files.contains { $0.standardizedRelativePath == "VisibleAgain.md" }, caseLabel)
        }
    }

    func testIgnoredCatalogDeletionAndExplicitIndexingRemainHidden() async throws {
        do {
            let caseLabel = "testIgnoredManagedFileDeleteRemovesCatalogWithoutRediscovery"
            let root = try makeTemporaryRoot(name: "IgnoredDelete")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)
            let ignoredURL = root.appendingPathComponent("delete.ignored")
            try await host.writeText(path: ignoredURL.path, content: "delete me", overwrite: false)

            try await store.deleteFile(rootID: record.id, relativePath: "delete.ignored")
            await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileRemoved("delete.ignored"), .fileAdded("delete.ignored")])

            XCTAssertFalse(FileManager.default.fileExists(atPath: ignoredURL.path), caseLabel)
            let deletedFile = await store.file(rootID: record.id, relativePath: "delete.ignored")
            XCTAssertNil(deletedFile, caseLabel)
        }

        do {
            let caseLabel = "testEnsureIndexedFilesDoesNotExposeIgnoredDiskFile"
            let root = try makeTemporaryRoot(name: "EnsureIndexedIgnored")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let ignoredURL = root.appendingPathComponent("late.ignored")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try write("hidden", to: ignoredURL)

            let indexed = await store.ensureIndexedFiles(paths: [ignoredURL.path])

            XCTAssertTrue(indexed.isEmpty, caseLabel)
            let indexedIgnoredFile = await store.file(rootID: record.id, relativePath: "late.ignored")
            XCTAssertNil(indexedIgnoredFile, caseLabel)
            let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedFullPath == ignoredURL.path }, caseLabel)
        }
    }

    func testExplicitCatalogLookupUsesSingleInterpretationWithoutIgnoredShadowProbe() async throws {
        do {
            let caseLabel = "testExplicitCatalogLookupFastPathsSingleInterpretation"
            let root = try makeTemporaryRoot(name: "CatalogFastPath")
            let fileURL = root.appendingPathComponent("Sources/Visible.swift")
            try write("visible", to: fileURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)

            let relativeLookup = await store.lookupCatalogFileForExplicitRequest("Sources/Visible.swift", rootScope: .visibleWorkspace)
            guard case let .matched(relativeFile) = relativeLookup else {
                return XCTFail(caseLabel + ": " + "Expected a single-root relative catalog hit")
            }
            XCTAssertEqual(relativeFile.rootID, record.id, caseLabel)
            XCTAssertEqual(relativeFile.standardizedFullPath, fileURL.path, caseLabel)

            let absoluteLookup = await store.lookupCatalogFileForExplicitRequest(fileURL.path, rootScope: .visibleWorkspace)
            guard case let .matched(absoluteFile) = absoluteLookup else {
                return XCTFail(caseLabel + ": " + "Expected an absolute catalog hit")
            }
            XCTAssertEqual(absoluteFile.id, relativeFile.id, caseLabel)
        }

        do {
            let caseLabel = "testExplicitCatalogLookupDoesNotProbeIgnoredShadowForRelativeMultiRootPath"
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
                return XCTFail(caseLabel + ": " + "Expected relative catalog hit without probing ignored disk siblings")
            }
            XCTAssertEqual(catalogFile.rootID, visibleRoot.id, caseLabel)

            let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile("same.md", profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .workspace(readableFile) = readable else {
                return XCTFail(caseLabel + ": " + "Expected visible cataloged file to resolve")
            }
            XCTAssertEqual(readableFile.rootID, visibleRoot.id, caseLabel)
            let ignoredRecord = await store.file(rootID: ignoredRoot.id, relativePath: "same.md")
            XCTAssertNil(ignoredRecord, caseLabel)
        }
    }

    func testStaleExactLookupPrunesMissingManagedAndAmbiguousCandidates() async throws {
        do {
            let caseLabel = "testMissingManagedIgnoredRecordIsPrunedByAbsoluteMutationRecovery"
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
                return XCTFail(caseLabel + ": " + "Expected ignored file to materialize before stale-record pruning")
            }
            try FileManager.default.removeItem(at: staleURL)

            do {
                _ = try await WorkspaceFileMutationService(store: store).resolveExactExistingFileForMutation(staleURL.path, rootScope: .visibleWorkspace)
                XCTFail(caseLabel + ": " + "Expected removed absolute mutation target to fail")
            } catch {}
            let resolved = await WorkspaceReadableFileService(store: store).resolveReadableFile("same.ignored", profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .workspace(file) = resolved else {
                return XCTFail(caseLabel + ": " + "Expected remaining visible file to resolve after stale ignored record pruning")
            }
            XCTAssertEqual(file.rootID, recordB.id, caseLabel)
            XCTAssertEqual(file.standardizedFullPath, visibleURL.path, caseLabel)
            let staleRecord = await store.file(rootID: recordA.id, relativePath: "same.ignored")
            XCTAssertNil(staleRecord, caseLabel)
        }

        do {
            let caseLabel = "testStaleCatalogRecordIsPrunedForExactMutationLookup"
            let root = try makeTemporaryRoot(name: "StaleCatalogPrune")
            let staleURL = root.appendingPathComponent("Stale.swift")
            try write("stale", to: staleURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let staleFileBeforeRemoval = await store.file(rootID: record.id, relativePath: "Stale.swift")
            XCTAssertNotNil(staleFileBeforeRemoval, caseLabel)

            try FileManager.default.removeItem(at: staleURL)
            let service = WorkspaceFileMutationService(store: store)

            let exactAfterRemoval = await service.exactExistingFile("Stale.swift", rootScope: .visibleWorkspace)
            XCTAssertNil(exactAfterRemoval, caseLabel)
            let staleFileAfterPrune = await store.file(rootID: record.id, relativePath: "Stale.swift")
            XCTAssertNil(staleFileAfterPrune, caseLabel)
            let staleLookupAfterPrune = await store.lookupPath("Stale.swift", profile: .mcpRead, rootScope: .visibleWorkspace)?.file
            XCTAssertNil(staleLookupAfterPrune, caseLabel)
        }

        do {
            let caseLabel = "testStaleAmbiguousExactMutationLookupPrunesMissingCandidate"
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
            XCTAssertNotNil(ambiguousIssue, caseLabel)

            try FileManager.default.removeItem(at: staleURL)
            let resolved = try await service.resolveExactExistingFileForMutation("Sources/A.swift", rootScope: .visibleWorkspace)

            XCTAssertEqual(resolved.rootID, recordB.id, caseLabel)
            XCTAssertEqual(resolved.standardizedRelativePath, "Sources/A.swift", caseLabel)
            let staleAfterPrune = await store.file(rootID: recordA.id, relativePath: "Sources/A.swift")
            XCTAssertNil(staleAfterPrune, caseLabel)
            let remainingAfterPrune = await store.file(rootID: recordB.id, relativePath: "Sources/A.swift")
            XCTAssertNotNil(remainingAfterPrune, caseLabel)
        }
    }

    func testIgnoredCreateRejectsSymlinkedParentAndDanglingLeafEscapes() async throws {
        do {
            let caseLabel = "testIgnoredCreateRejectsSymlinkedParentWithoutWritingOutsideRoot"
            let root = try makeTemporaryRoot(name: "IgnoredCreateSymlink")
            let outside = try makeTemporaryRoot(name: "IgnoredCreateSymlinkOutside")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ignored"), withDestinationURL: outside)
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

            do {
                try await host.writeText(path: "ignored/report.md", content: "must not escape", overwrite: false)
                XCTFail(caseLabel + ": " + "Expected symlinked parent create to fail")
            } catch {}

            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("report.md").path), caseLabel)
        }

        do {
            let caseLabel = "testIgnoredCreateRejectsDanglingLeafSymlinkWithoutWritingOutsideRoot"
            let root = try makeTemporaryRoot(name: "IgnoredCreateDanglingSymlink")
            let outside = try makeTemporaryRoot(name: "IgnoredCreateDanglingSymlinkOutside")
            let outsideTarget = outside.appendingPathComponent("missing-report.md")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("report.ignored"), withDestinationURL: outsideTarget)
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

            do {
                try await host.writeText(path: "report.ignored", content: "must not escape", overwrite: false)
                XCTFail(caseLabel + ": " + "Expected dangling symlink create to fail")
            } catch {}

            XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path), caseLabel)
        }
    }

    func testMutationConsumersRejectAmbiguousAndDiskMissingOverwriteBases() async throws {
        do {
            let caseLabel = "testWorkspaceFileMutationServiceRequiresExactExistingFileForOverwriteResolution"
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
                XCTFail(caseLabel + ": " + "Expected ambiguous relative overwrite target to fail exact resolution")
            } catch let error as FileManagerError {
                guard case let .fileSystemServiceNotFoundWithContext(message) = error else {
                    return XCTFail(caseLabel + ": " + "Unexpected error: \(error)")
                }
                XCTAssertTrue(message.contains("matches multiple workspace roots"), caseLabel)
            }
        }

        do {
            let caseLabel = "testApplyEditsRejectsDiskMissingStaleCatalogBase"
            let root = try makeTemporaryRoot(name: "StrictApplyEditsMissingBase")
            let fileURL = root.appendingPathComponent("Deleted.swift")
            try write("struct Deleted {}\n", to: fileURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let loadedRecord = await store.file(rootID: record.id, relativePath: "Deleted.swift")
            XCTAssertNotNil(loadedRecord, caseLabel)
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
                XCTFail(caseLabel + ": " + "Expected apply_edits preview to reject a stale disk-missing base")
            } catch let error as ApplyEditsError {
                guard case let .invalidParams(message) = error else {
                    return XCTFail(caseLabel + ": " + "Unexpected apply_edits error: \(error)")
                }
                XCTAssertTrue(message.contains("does not exist"), caseLabel)
            } catch let error as FileManagerError {
                XCTAssertTrue(error.localizedDescription.contains("Unknown or unloaded path"), caseLabel)
            } catch {
                XCTFail(caseLabel + ": " + "Unexpected error: \(error)")
            }
            let prunedRecord = await store.file(rootID: record.id, relativePath: "Deleted.swift")
            XCTAssertNil(prunedRecord, caseLabel)
        }
    }

    func testReadDiagnosticsDistinguishWorkspaceAndExternalDiskSources() async throws {
        do {
            let caseLabel = "testReadFileWorkDiagnosticsCaptureDiskBytesDecodeAndReturnedRange"
            let root = try makeTemporaryRoot(name: "ReadFileWorkDiagnostics")
            let body = "first\nsecond\nthird\n"
            try write(body, to: root.appendingPathComponent("Sample.txt"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)

            MCPToolWorkCountDiagnostics.resetForTesting()
            let content = try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                let loaded = try await store.readContent(
                    rootID: record.id,
                    relativePath: "Sample.txt",
                    workloadClass: .interactiveRead
                )
                let value = try XCTUnwrap(loaded, caseLabel)
                let returned = "second\n"
                MCPToolWorkCountDiagnostics.recordReadFileResult(
                    returnedBytes: returned.utf8.count,
                    returnedLines: 1,
                    cacheHit: false
                )
                return value
            }

            XCTAssertEqual(content, body, caseLabel)
            let snapshot = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().readFile.last, caseLabel)
            XCTAssertEqual(snapshot.source, "disk", caseLabel)
            XCTAssertEqual(snapshot.readBytes, body.utf8.count, caseLabel)
            XCTAssertEqual(snapshot.returnedBytes, "second\n".utf8.count, caseLabel)
            XCTAssertEqual(snapshot.returnedLines, 1, caseLabel)
            XCTAssertFalse(snapshot.cacheHit, caseLabel)
            XCTAssertGreaterThanOrEqual(snapshot.decodeMicroseconds, 0, caseLabel)
        }

        do {
            let caseLabel = "testWorkspaceReadableFileServiceResolvesAndReadsAlwaysReadableExternalFiles"
            let home = try makeTemporaryRoot(name: "ReadableHome")
            let external = home.appendingPathComponent(".agents/skills/example/SKILL.md")
            try write("skill body", to: external)

            let store = WorkspaceFileContextStore()
            let service = WorkspaceReadableFileService(store: store, homeDirectoryURL: home)
            let resolved = try XCTUnwrap(service.resolveAlwaysReadableExternalFile(atAbsolutePath: external.path), caseLabel)

            XCTAssertEqual(resolved.displayPath, "~/.agents/skills/example/SKILL.md", caseLabel)
            MCPToolWorkCountDiagnostics.resetForTesting()
            let externalContent = try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                let content = try await service.readAlwaysReadableExternalFile(resolved)
                MCPToolWorkCountDiagnostics.recordReadFileResult(
                    returnedBytes: content.utf8.count,
                    returnedLines: 1,
                    cacheHit: false
                )
                return content
            }
            XCTAssertEqual(externalContent, "skill body", caseLabel)
            let snapshot = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().readFile.last, caseLabel)
            XCTAssertEqual(snapshot.source, "external_disk", caseLabel)
            XCTAssertEqual(snapshot.readBytes, "skill body".utf8.count, caseLabel)
            XCTAssertEqual(snapshot.returnedBytes, "skill body".utf8.count, caseLabel)
            XCTAssertEqual(snapshot.returnedLines, 1, caseLabel)
            XCTAssertFalse(snapshot.cacheHit, caseLabel)
            XCTAssertTrue(service.isAlwaysReadableExternalPath(external.path), caseLabel)
        }
    }

    func testStoreBackedRootShellProjectionsPreserveIdentityWithoutMaterializingDescendants() async throws {
        do {
            let caseLabel = "testAttachRootShellFromPreloadedStoreRecordDoesNotMaterializeDescendants"
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

            XCTAssertEqual(manager.rootFolders.count, 1, caseLabel)
            XCTAssertEqual(shell.id, rootRecord.id, caseLabel)
            XCTAssertEqual(shell.standardizedFullPath, rootRecord.standardizedFullPath, caseLabel)
            XCTAssertTrue(shell.children.isEmpty, caseLabel)
            XCTAssertNil(manager.findFolderByFullPath(nestedFolderURL.path), caseLabel)
            XCTAssertNil(manager.findFileByFullPath(fileURL.path), caseLabel)
            XCTAssertTrue(manager.allFilesSnapshot(sorted: false).isEmpty, caseLabel)
            let storeFiles = await store.files(inRoot: rootRecord.id).map(\.standardizedRelativePath)
            XCTAssertEqual(storeFiles, ["Sources/A.swift"], caseLabel)

            await manager.unloadAllRootFolders()
            XCTAssertTrue(manager.rootFolders.isEmpty, caseLabel)
            let rootsAfterUnload = await store.roots()
            XCTAssertTrue(rootsAfterUnload.isEmpty, caseLabel)
        }

        do {
            let caseLabel = "testLoadedRootShellAlignsWithStoreRootAndLeavesCodemapIDsStoreBacked"
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
            let rootRecord = try XCTUnwrap(storeRoots.first, caseLabel)
            let storeFolders = await store.folders(inRoot: rootRecord.id).map(\.standardizedRelativePath)
            let storeFiles = await store.files(inRoot: rootRecord.id)
            let swiftFileRecord = try XCTUnwrap(storeFiles.first { $0.standardizedRelativePath == "Sources/Nested/A.swift" }, caseLabel)

            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: fileURL.path, modificationDate: Date(), fileAPI: makeFileAPI(path: fileURL.path))
            ])
            let codemapSnapshot = await store.codemapSnapshot(rootID: rootRecord.id, relativePath: "Sources/Nested/A.swift")
            let snapshot = try XCTUnwrap(codemapSnapshot, caseLabel)

            let rootVM = try XCTUnwrap(manager.rootFolders.first, caseLabel)
            XCTAssertEqual(manager.rootFolders.count, 1, caseLabel)
            XCTAssertEqual(rootVM.id, rootRecord.id, caseLabel)
            XCTAssertTrue(rootVM.children.isEmpty, caseLabel)
            XCTAssertNil(manager.findFileByFullPath(fileURL.path), caseLabel)
            XCTAssertNil(manager.findFolderByFullPath(root.appendingPathComponent("Sources").path), caseLabel)
            XCTAssertNil(manager.findFolderByFullPath(root.appendingPathComponent("Sources/Nested").path), caseLabel)
            XCTAssertTrue(manager.allFilesSnapshot(sorted: false).isEmpty, caseLabel)
            XCTAssertTrue(storeFolders.contains("Sources"), caseLabel)
            XCTAssertTrue(storeFolders.contains("Sources/Nested"), caseLabel)
            XCTAssertEqual(Set(storeFiles.map(\.standardizedRelativePath)), Set(["README.md", "Sources/Nested/A.swift"]), caseLabel)
            XCTAssertEqual(snapshot.fileID, swiftFileRecord.id, caseLabel)

            await manager.unloadAllRootFolders()
            XCTAssertTrue(manager.rootFolders.isEmpty, caseLabel)
            let rootsAfterUnload = await store.roots()
            XCTAssertTrue(rootsAfterUnload.isEmpty, caseLabel)
        }
    }

    func testLoadFolderWatcherFailureRetainsHydratedRootAndProjectedSlices() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "LoadFolderWatcherFailureRetention")
            let fileURL = root.appendingPathComponent("Sliced.swift")
            try write("one\ntwo\nthree\n", to: fileURL)

            let store = WorkspaceFileContextStore()
            await store.setWatcherActivationFailureForNewServicesForTesting(.streamStart)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "LoadFolderWatcherFailureRetention", repoPaths: [root.path])
            let ranges = [LineRange(start: 1, end: 2)]
            let scope = PartitionScope(workspaceID: workspace.id)
            let seedCoordinator = SelectionSliceCoordinator()
            try await seedCoordinator.applySliceUpdates(
                groupedByRootPath: [root.path: [SelectionSliceCoordinator.SliceUpdate(
                    relativePath: "Sliced.swift",
                    ranges: ranges,
                    fileModificationTime: nil
                )]],
                scope: scope,
                mode: .set
            )
            addTeardownBlock {
                await manager.unloadAllRootFolders()
                _ = try? await seedCoordinator.clearSlices(forRootPaths: [root.path], scope: scope)
            }

            do {
                try await manager.loadFolder(at: root, for: workspace)
                XCTFail("Expected watcher activation failure")
            } catch let error as FileSystemWatcherActivationError {
                XCTAssertEqual(error, .streamStartFailed(path: root.path))
            } catch {
                return XCTFail("Expected typed watcher activation error, got \(error)")
            }

            XCTAssertEqual(manager.rootFolders.map(\.standardizedFullPath), [root.path])
            let loadedRoots = await store.roots()
            let loadedRoot = try XCTUnwrap(loadedRoots.first)
            XCTAssertEqual(loadedRoots.map(\.standardizedFullPath), [root.path])
            let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: loadedRoot.id)
            XCTAssertFalse(watcherIsActive)
            XCTAssertEqual(manager.currentSlicesByRootForTesting()[root.path]?["Sliced.swift"]?.ranges, ranges)

            await manager.applyStoredSelection(StoredSelection(
                selectedPaths: [fileURL.path],
                autoCodemapPaths: [],
                slices: [fileURL.path: ranges],
                codemapAutoEnabled: false
            ))
            XCTAssertEqual(manager.snapshotSelection().slices[fileURL.path], ranges)
            XCTAssertEqual(manager.getSelectionSlicesSnapshot().values.first, ranges)

            let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(
                fileURL.path,
                profile: .mcpRead,
                rootScope: .visibleWorkspace
            )
            XCTAssertNotNil(readable)
            await store.setWatcherActivationFailureForNewServicesForTesting(nil)
        #endif
    }

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

    #if DEBUG
        func testAppliedIndexProjectionDiagnosticsReportProducedHandledLag() async throws {
            let root = try makeTemporaryRoot(name: "AppliedIndexProjectionLag")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))
            let store = WorkspaceFileContextStore()
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "AppliedIndexProjectionLag", repoPaths: [root.path])
            try await manager.loadFolder(at: root, for: workspace)
            let roots = await store.roots()
            let rootRecord = try XCTUnwrap(roots.first)

            // This test drives the store directly. Remove the live FSEvents producer and settle any
            // load-time publication before measuring one exact produced-versus-handled transition.
            await store.stopWatchingRoot(id: rootRecord.id)
            let baselineSettled = await waitForAsyncCondition {
                let roots = await store.readSearchRootDiagnosticsSnapshot()
                guard let root = roots.first(where: { $0.rootID == rootRecord.id }) else { return false }
                let handled = manager.appliedIndexProjectionDiagnosticsSnapshot()
                    .handledGenerationByRootID[rootRecord.id] ?? 0
                return handled == root.producedAppliedIndexGeneration
            }
            XCTAssertTrue(baselineSettled)
            let baselineRoots = await store.readSearchRootDiagnosticsSnapshot()
            let baselineRoot = try XCTUnwrap(baselineRoots.first { $0.rootID == rootRecord.id })
            let baselineProjection = manager.appliedIndexProjectionDiagnosticsSnapshot()
            let baselineGeneration = baselineRoot.producedAppliedIndexGeneration
            let expectedGeneration = baselineGeneration &+ 1
            XCTAssertEqual(
                baselineProjection.handledGenerationByRootID[rootRecord.id] ?? 0,
                baselineGeneration
            )

            let projectionGate = AsyncGate()
            manager.setAppliedIndexProjectionWillHandleHandlerForTesting { rootID, generation in
                guard rootID == rootRecord.id, generation == expectedGeneration else { return }
                await projectionGate.markStartedAndWaitForRelease()
            }

            let addedURL = root.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            let replayCompleted = AsyncSignal()
            let replayTask = Task {
                await store.replayObservedFileSystemDeltas(
                    rootID: rootRecord.id,
                    deltas: [.fileAdded("Added.swift")]
                )
                await replayCompleted.mark()
            }
            await projectionGate.waitUntilStarted()
            let producerCompletedBeforeProjectionRelease = await waitForAsyncCondition {
                await replayCompleted.isMarked()
            }
            XCTAssertTrue(producerCompletedBeforeProjectionRelease)

            let producedRoots = await store.readSearchRootDiagnosticsSnapshot()
            let producedRoot = try XCTUnwrap(producedRoots.first { $0.rootID == rootRecord.id })
            let blockedProjection = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(producedRoot.producedAppliedIndexGeneration, expectedGeneration)
            XCTAssertEqual(
                blockedProjection.handledGenerationByRootID[rootRecord.id] ?? 0,
                baselineGeneration
            )
            XCTAssertEqual(
                producedRoot.producedAppliedIndexGeneration - (blockedProjection.handledGenerationByRootID[rootRecord.id] ?? 0),
                1
            )

            await projectionGate.release()
            await replayTask.value
            let projectionSettled = await waitForAsyncCondition {
                manager.appliedIndexProjectionDiagnosticsSnapshot().handledGenerationByRootID[rootRecord.id]
                    == expectedGeneration
            }
            XCTAssertTrue(projectionSettled)
            let settledProjection = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(settledProjection.handledEventCount, baselineProjection.handledEventCount + 1)
            XCTAssertEqual(settledProjection.handledGenerationByRootID[rootRecord.id], expectedGeneration)
            manager.setAppliedIndexProjectionWillHandleHandlerForTesting(nil)
            await manager.unloadAllRootFolders()
        }
    #endif

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

    func testDiskValidatedConsumersObserveFreshBytesAndReuseUnchangedMetadata() async throws {
        do {
            let caseLabel = "testStoreReadContentReturnsCurrentDiskBytesAfterExternalChange"
            let root = try makeTemporaryRoot(name: "StrictStoreReadFreshness")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("old", to: fileURL)
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            try setDiskModificationDate(fixedDate, for: fileURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let initialContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
            XCTAssertEqual(initialContent, "old", caseLabel)

            try write("new", to: fileURL)
            try setDiskModificationDate(fixedDate, for: fileURL)

            let refreshedContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
            XCTAssertEqual(refreshedContent, "new", caseLabel)
        }

        do {
            let caseLabel = "testContentSearchReloadsExternalModificationBeforeMatching"
            let root = try makeTemporaryRoot(name: "StrictSearchFreshness")
            let fileURL = root.appendingPathComponent("Sources/A.swift")
            let staleDate = Date(timeIntervalSince1970: 1_700_000_100)
            let freshDate = Date(timeIntervalSince1970: 1_700_000_200)
            try write("struct A { let staleSearchToken = true }\n", to: fileURL)
            try setDiskModificationDate(staleDate, for: fileURL)

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            let workspace = WorkspaceModel(name: "StrictSearchFreshness", repoPaths: [root.path])
            manager.registerPreloadedWorkspaceRoot(rootRecord)
            _ = try manager.attachRootShell(for: rootRecord, workspaceID: workspace.id)
            XCTAssertNil(manager.findFileByFullPath(fileURL.path), caseLabel)

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

            XCTAssertEqual(freshResults.matches?.count, 1, caseLabel)
            XCTAssertTrue((staleResults.matches ?? []).isEmpty, caseLabel)
            XCTAssertNil(manager.findFileByFullPath(fileURL.path), caseLabel)

            await manager.unloadAllRootFolders()
        }

        do {
            let caseLabel = "testDiskValidatedSearchSnapshotReusesCacheWhenMetadataUnchanged"
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
            let file = try XCTUnwrap(materializedFile, caseLabel)
            let initialContent = await file.latestContent
            XCTAssertEqual(initialContent, "struct A { let stableToken = true }\n", caseLabel)

            let cached = await file.searchContentSnapshot(freshnessPolicy: .cachedMetadata)
            let strict = await file.searchContentSnapshot(freshnessPolicy: .validateDiskMetadata)

            XCTAssertTrue(cached.isFresh, caseLabel)
            XCTAssertTrue(strict.isFresh, caseLabel)
            XCTAssertEqual(strict.content, cached.content, caseLabel)
            XCTAssertEqual(strict.contentRevision, cached.contentRevision, caseLabel)

            await manager.unloadAllRootFolders()
        }

        do {
            let caseLabel = "testApplyEditsPreviewReadsFreshDiskBaseAfterExternalModification"
            let root = try makeTemporaryRoot(name: "StrictApplyEditsFreshBase")
            let fileURL = root.appendingPathComponent("A.swift")
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_400)
            try write("struct A { let staleApplyToken = true }\n", to: fileURL)
            try setDiskModificationDate(fixedDate, for: fileURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let initialContent = try await store.readContent(rootID: record.id, relativePath: "A.swift")
            XCTAssertEqual(initialContent, "struct A { let staleApplyToken = true }\n", caseLabel)

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

            XCTAssertTrue(preview.exists, caseLabel)
            XCTAssertEqual(preview.originalText, "struct A { let freshApplyToken = true }\n", caseLabel)
            XCTAssertTrue(preview.result.updatedText.contains("editedApplyToken"), caseLabel)
            XCTAssertFalse(preview.result.updatedText.contains("staleApplyToken"), caseLabel)
        }
    }

    #if DEBUG
        func testInteractiveReadCacheWarmRangeHitAvoidsDiskReadAndRepeatSplitting() async throws {
            let root = try makeTemporaryRoot(name: "InteractiveReadWarmHit")
            let content = (1 ... 200).map { "line-\($0)\r\n" }.joined()
            try write(content, to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            MCPToolWorkCountDiagnostics.resetForTesting()

            func rangedRead() async throws -> WorkspaceInteractiveReadSlice {
                try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                    let loadedSnapshot = try await store.interactiveReadSnapshot(for: file)
                    let snapshot = try XCTUnwrap(loadedSnapshot)
                    let slice = try await WorkspaceInteractiveReadProcessor.sliceOffActor(
                        snapshot.preparedContent,
                        startLine1Based: 80,
                        lineCount: 3
                    )
                    MCPToolWorkCountDiagnostics.recordReadFileResult(
                        returnedBytes: slice.content.utf8.count,
                        returnedLines: slice.returnedLineCount,
                        cacheHit: snapshot.cacheHit
                    )
                    return slice
                }
            }

            let cold = try await rangedRead()
            let warm = try await rangedRead()
            let cache = await store.interactiveReadCacheSnapshotForTesting()
            let diagnostics = MCPToolWorkCountDiagnostics.debugSnapshots().readFile

            XCTAssertEqual(cold, warm)
            XCTAssertEqual(warm.content, "line-80\r\nline-81\r\nline-82\r\n")
            XCTAssertEqual(warm.returnedLineCount, 3)
            XCTAssertEqual(cache.entryCount, 1)
            XCTAssertEqual(cache.preparationCount, 1)
            XCTAssertEqual(cache.hitCount, 1)
            XCTAssertEqual(diagnostics.count, 2)
            XCTAssertEqual(diagnostics[0].source, "disk")
            XCTAssertGreaterThanOrEqual(diagnostics[0].readBytes, content.utf8.count)
            XCTAssertFalse(diagnostics[0].cacheHit)
            XCTAssertEqual(diagnostics[1].source, "interactive_cache")
            XCTAssertEqual(diagnostics[1].readBytes, 0)
            XCTAssertEqual(diagnostics[1].returnedBytes, warm.content.utf8.count)
            XCTAssertEqual(diagnostics[1].returnedLines, 3)
            XCTAssertTrue(diagnostics[1].cacheHit)
        }

        func testDeferredInitialRootLoadFlushUsesStoreRootsInsteadOfMainActorUIGather() throws {
            let source = try readWorkspaceFilesViewModelSource()
            let flushBody = try XCTUnwrap(source.slice(from: "func flushDeferredInitialRootLoadScans()", to: "private func clearDeferredInitialRootLoadScanState"))

            XCTAssertTrue(flushBody.contains("workspaceFileContextStore.rootRecords"), flushBody)
            XCTAssertTrue(flushBody.contains("enqueueInitialRootLoadRequests"), flushBody)
            XCTAssertFalse(flushBody.contains("getFilesRecursively"), flushBody)
        }
    #endif

    #if DEBUG

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

            let lifetimeRoot = try makeTemporaryRoot(name: "SessionWorktreeSuccessorLifetime")
            try write("first", to: lifetimeRoot.appendingPathComponent("First.swift"))
            let lifetimeStore = WorkspaceFileContextStore()
            let lifetimeOwnerID = UUID()
            let lifetimePreparation = try await lifetimeStore.prepareSessionWorktreeOwnership(
                ownerID: lifetimeOwnerID,
                bindingFingerprint: "first-lifetime",
                physicalRootPaths: [lifetimeRoot.path]
            )
            let firstLifetimeRoots = try await lifetimeStore.commitSessionWorktreeOwnership(lifetimePreparation)
            let firstLifetimeRootID = try XCTUnwrap(firstLifetimeRoots.first?.rootID)
            let firstLifetimeID = try await lifetimeStore.rootLifetimeIDForTesting(rootID: firstLifetimeRootID)
            let staleCleanupGate = AsyncGate()
            let staleCleanupObserved = expectation(description: "first-lifetime orphan cleanup reaches watcher reconciliation")
            await lifetimeStore.setWatcherServiceStateWillReconcileHandler { rootID, shouldWatch in
                guard rootID == firstLifetimeRootID, !shouldWatch else { return }
                staleCleanupObserved.fulfill()
                await staleCleanupGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await staleCleanupGate.release()
                await lifetimeStore.setWatcherServiceStateWillReconcileHandler(nil)
            }

            let firstLifetimeReleaseTask = Task {
                await lifetimeStore.releaseSessionWorktreeOwnership(ownerID: lifetimeOwnerID)
            }
            await fulfillment(of: [staleCleanupObserved], timeout: 1)
            let staleCleanupCount = await staleCleanupGate.startCount()
            XCTAssertEqual(staleCleanupCount, 1)
            if staleCleanupCount == 1 {
                await lifetimeStore.unloadRoot(id: firstLifetimeRootID)
                try write("second", to: lifetimeRoot.appendingPathComponent("Second.swift"))
                let successorRoot = try await lifetimeStore.loadRoot(
                    path: lifetimeRoot.path,
                    kind: .sessionWorktree
                )
                let successorLifetimeID = try await lifetimeStore.rootLifetimeIDForTesting(rootID: successorRoot.id)
                XCTAssertNotEqual(successorRoot.id, firstLifetimeRootID)
                XCTAssertNotEqual(successorLifetimeID, firstLifetimeID)

                await staleCleanupGate.release()
                await firstLifetimeReleaseTask.value

                let rootsAfterStaleCleanup = await lifetimeStore.roots()
                XCTAssertEqual(rootsAfterStaleCleanup.map(\.id), [successorRoot.id])
                let retainedSuccessorLifetimeID = try await lifetimeStore.rootLifetimeIDForTesting(
                    rootID: successorRoot.id
                )
                XCTAssertEqual(retainedSuccessorLifetimeID, successorLifetimeID)
                await lifetimeStore.unloadRoot(id: successorRoot.id)
            } else {
                await staleCleanupGate.release()
                await firstLifetimeReleaseTask.value
            }
        }

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

        func testEmptyStoredSlicesClearActiveAndPersistedSliceProjections() async throws {
            do {
                let caseLabel = "testApplyStoredSelectionWithEmptySlicesClearsCurrentSliceProjection"
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
                let file = try XCTUnwrap(manager.findFileByFullPath(fileURL.path), caseLabel)
                XCTAssertEqual(manager.snapshotSelection().selectedPaths, [file.standardizedFullPath], caseLabel)
                XCTAssertEqual(manager.snapshotSelection().slices.count, 1, caseLabel)
                XCTAssertEqual(manager.getSelectionSlicesSnapshot().count, 1, caseLabel)

                await manager.applyStoredSelection(StoredSelection(
                    selectedPaths: [fileURL.path],
                    autoCodemapPaths: [],
                    slices: [:],
                    codemapAutoEnabled: false
                ))

                let snapshot = manager.snapshotSelection()
                XCTAssertEqual(snapshot.selectedPaths, [file.standardizedFullPath], caseLabel)
                XCTAssertEqual(snapshot.autoCodemapPaths.count, 0, caseLabel)
                XCTAssertTrue(snapshot.slices.isEmpty, caseLabel)
                XCTAssertFalse(snapshot.codemapAutoEnabled, caseLabel)
                XCTAssertTrue(manager.getSelectionSlicesSnapshot().isEmpty, caseLabel)
            }

            do {
                let caseLabel = "testHydrateSlicesForActiveTabWithEmptyStoredSelectionDeletesPersistedSlices"
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
                    let file = try XCTUnwrap(manager.findFileByFullPath(fileURL.path), caseLabel)
                    XCTAssertFalse(manager.snapshotSelection().slices.isEmpty, caseLabel)
                    let hasSlicesBeforeHydrate = await manager._testHasAnySlicesForFile(file)
                    XCTAssertTrue(hasSlicesBeforeHydrate, caseLabel)

                    await manager.hydrateSlicesForActiveTab(from: StoredSelection(
                        selectedPaths: [fileURL.path],
                        autoCodemapPaths: [],
                        slices: [:],
                        codemapAutoEnabled: false
                    ))

                    XCTAssertTrue(manager.snapshotSelection().slices.isEmpty, caseLabel)
                    XCTAssertTrue(manager.getSelectionSlicesSnapshot().isEmpty, caseLabel)
                    let hasSlicesAfterHydrate = await manager._testHasAnySlicesForFile(file)
                    XCTAssertFalse(hasSlicesAfterHydrate, caseLabel)
                #endif
            }
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

        private var createdFileFlags: FileSystemWatchEventFlags {
            [.itemCreated, .itemIsFile]
        }

        private actor WorkspaceRootUnloadDiagnosticsRecorder {
            private var diagnostics: WorkspaceRootUnloadTerminationDiagnostics?

            func record(_ diagnostics: WorkspaceRootUnloadTerminationDiagnostics) {
                self.diagnostics = diagnostics
            }

            func snapshot() -> WorkspaceRootUnloadTerminationDiagnostics? {
                diagnostics
            }
        }

        private actor ManualWorkspaceRootUnloadSleeper {
            private struct Waiter {
                let id: UUID
                let continuation: CheckedContinuation<Void, Never>
            }

            private var sleepWaitersByNanoseconds: [UInt64: [UUID: Waiter]] = [:]
            private var registrationWaitersByNanoseconds: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
            private var releasedNanoseconds: Set<UInt64> = []
            private var cancelledWaiterIDs: Set<UUID> = []

            func sleep(nanoseconds: UInt64) async {
                if releasedNanoseconds.contains(nanoseconds) { return }
                let waiterID = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                            continuation.resume()
                            return
                        }
                        if releasedNanoseconds.contains(nanoseconds) {
                            continuation.resume()
                            return
                        }
                        sleepWaitersByNanoseconds[nanoseconds, default: [:]][waiterID] = Waiter(
                            id: waiterID,
                            continuation: continuation
                        )
                        let registrationWaiters = registrationWaitersByNanoseconds.removeValue(forKey: nanoseconds) ?? []
                        registrationWaiters.forEach { $0.resume() }
                    }
                } onCancel: {
                    Task { await self.cancel(waiterID: waiterID, nanoseconds: nanoseconds) }
                }
            }

            func waitUntilSleeping(nanoseconds: UInt64) async {
                guard sleepWaitersByNanoseconds[nanoseconds]?.isEmpty != false else { return }
                await withCheckedContinuation { continuation in
                    registrationWaitersByNanoseconds[nanoseconds, default: []].append(continuation)
                }
            }

            func release(nanoseconds: UInt64) {
                releasedNanoseconds.insert(nanoseconds)
                let waiters = sleepWaitersByNanoseconds.removeValue(forKey: nanoseconds) ?? [:]
                waiters.values.forEach { $0.continuation.resume() }
                let registrationWaiters = registrationWaitersByNanoseconds.removeValue(forKey: nanoseconds) ?? []
                registrationWaiters.forEach { $0.resume() }
            }

            private func cancel(waiterID: UUID, nanoseconds: UInt64) {
                guard let waiter = sleepWaitersByNanoseconds[nanoseconds]?.removeValue(forKey: waiterID) else {
                    cancelledWaiterIDs.insert(waiterID)
                    return
                }
                if sleepWaitersByNanoseconds[nanoseconds]?.isEmpty == true {
                    sleepWaitersByNanoseconds.removeValue(forKey: nanoseconds)
                }
                waiter.continuation.resume()
            }
        }

        private actor OrderedIngressRecorder {
            private var sequences: [UInt64] = []

            func append(_ sequence: UInt64) {
                sequences.append(sequence)
            }

            func snapshot() -> [UInt64] {
                sequences
            }
        }

        private actor CapturedWatcherWatermarkRecorder {
            private let expectedRootID: UUID
            private var capturedWatermark: UInt64?

            init(expectedRootID: UUID) {
                self.expectedRootID = expectedRootID
            }

            func record(rootID: UUID, watermark: UInt64) {
                guard rootID == expectedRootID, capturedWatermark == nil else { return }
                capturedWatermark = watermark
            }

            func snapshot() -> UInt64? {
                capturedWatermark
            }
        }

        private func waitForSearchContentCache(
            store: WorkspaceFileContextStore,
            timeout: TimeInterval = 2,
            file: StaticString = #filePath,
            line: UInt = #line,
            until predicate: (WorkspaceSearchDecodedContentCache.Snapshot) -> Bool
        ) async -> WorkspaceSearchDecodedContentCache.Snapshot {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let snapshot = await store.searchDecodedContentCacheSnapshotForTesting()
                if predicate(snapshot) {
                    return snapshot
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let final = await store.searchDecodedContentCacheSnapshotForTesting()
            XCTFail("Timed out waiting for search content cache: \(final)", file: file, line: line)
            return final
        }

        private func waitForAsyncCondition(
            timeout: Duration = .seconds(2),
            _ condition: () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() { return true }
                await Task.yield()
            }
            return await condition()
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

        private actor CancellationAwareGate {
            private struct Waiter {
                let id: UUID
                let continuation: CheckedContinuation<Void, Never>
            }

            private var started = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var cancellationWaiter: Waiter?
            private var cancelledWaiterIDs: Set<UUID> = []

            func markStartedAndWaitForCancellation() async {
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }

                let waiterID = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                            continuation.resume()
                        } else {
                            cancellationWaiter = Waiter(id: waiterID, continuation: continuation)
                        }
                    }
                } onCancel: {
                    Task { await self.cancel(waiterID) }
                }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            private func cancel(_ waiterID: UUID) {
                guard let cancellationWaiter, cancellationWaiter.id == waiterID else {
                    cancelledWaiterIDs.insert(waiterID)
                    return
                }
                self.cancellationWaiter = nil
                cancellationWaiter.continuation.resume()
            }
        }

        private final class WeakObjectBox<T: AnyObject>: @unchecked Sendable {
            weak var value: T?

            init(_ value: T?) {
                self.value = value
            }
        }

        private actor AsyncSignal {
            private var marked = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func mark() {
                guard !marked else { return }
                marked = true
                let pendingWaiters = waiters
                waiters.removeAll()
                pendingWaiters.forEach { $0.resume() }
            }

            func waitUntilMarked() async {
                guard !marked else { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func isMarked() -> Bool {
                marked
            }
        }

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

    func testCodemapAggregatePreservesOrderedCacheAndLegacyFirstWinnerSemantics() async throws {
        #if DEBUG
            do {
                let caseLabel = "testAllCodemapFileAPIsCacheReusesOrderedAggregateAndRecordsRebuildOnlyRows"
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

                XCTAssertEqual(codemapAPIProjection(cold.orderedFileAPIs), codemapAPIProjection(warm.orderedFileAPIs), caseLabel)
                XCTAssertEqual(codemapAPIProjection(cold.orderedFileAPIs), codemapAPIProjection(compatibilityAPIs), caseLabel)
                XCTAssertEqual(cold.orderedFileAPIs.map(\.filePath), [fileA.path, fileB.path], caseLabel)
                XCTAssertEqual(codemapAPIProjection(Array(cold.firstFileAPIByStandardizedNestedPath.values)), codemapAPIProjection(Array(warm.firstFileAPIByStandardizedNestedPath.values)), caseLabel)
                XCTAssertEqual(try codemapAPIProjection([XCTUnwrap(cold.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)], caseLabel)]), try codemapAPIProjection([XCTUnwrap(warm.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)], caseLabel)]), caseLabel)
                XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)?.sampleCount, 3, caseLabel)
                XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)?.sampleCount, 1, caseLabel)
                XCTAssertEqual(allCodemapFileAPIsBucket(capture, stage: EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)?.sampleCount, 1, caseLabel)
                XCTAssertTrue(capture.stages.allSatisfy(\.sanitizedDimensions.isEmpty), caseLabel)
                XCTAssertEqual(capture.droppedSampleCount, 0, caseLabel)
            }
        #endif

        do {
            let caseLabel = "testCodemapFileAPIAggregatePreservesForeignNestedPathFirstWinnerAndRetainedRecomputeResults"
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
            XCTAssertEqual(codemapAPIProjection(Array(aggregate.firstFileAPIByStandardizedNestedPath.values)), codemapAPIProjection(Array(legacyFirstWinners.values)), caseLabel)
            XCTAssertNil(aggregate.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileA.path)], caseLabel)
            XCTAssertTrue(try XCTUnwrap(aggregate.firstFileAPIByStandardizedNestedPath[StandardizedPath.absolute(fileB.path)], caseLabel).apiDescription.contains("foreignFirstWinner"), caseLabel)

            let mutations = WorkspaceSelectionMutationService(store: store)
            let ownPathSelection = StoredSelection(selectedPaths: [fileA.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: true)
            let ownPathResult = await mutations.recomputeAutoCodemaps(ownPathSelection)
            XCTAssertTrue(ownPathResult.autoCodemapPaths.isEmpty, caseLabel)

            let foreignPathSelection = StoredSelection(selectedPaths: [fileB.path], autoCodemapPaths: [], slices: [:], codemapAutoEnabled: true)
            let foreignPathResult = await mutations.recomputeAutoCodemaps(foreignPathSelection)
            XCTAssertEqual(foreignPathResult.autoCodemapPaths, [target.path], caseLabel)
        }

        do {
            let caseLabel = "testCodemapFileAPIAggregateFirstWinnerMatchesLegacyGroupingAcrossOverlappingRoots"
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
            XCTAssertEqual(collidingAPIs.count, 2, caseLabel)
            let legacyFirstWinner = try XCTUnwrap(legacyFirstFileAPIByStandardizedNestedPath(aggregate.orderedFileAPIs)[standardizedSharedPath], caseLabel)
            let aggregateFirstWinner = try XCTUnwrap(aggregate.firstFileAPIByStandardizedNestedPath[standardizedSharedPath], caseLabel)
            XCTAssertEqual(codemapAPIProjection([aggregateFirstWinner]), codemapAPIProjection([legacyFirstWinner]), caseLabel)
        }
    }

    func testValidatedReadAndSearchSnapshotsPublishExactPreEditSourceAndFenceFileIdentity() async throws {
        let rootURL = try makeTemporaryRoot(name: "SliceRebaseSource")
        let readURL = rootURL.appendingPathComponent("Read.swift")
        let searchURL = rootURL.appendingPathComponent("Search.swift")
        let readOriginal = "read-one\nread-two\nread-three\n"
        let searchOriginal = "search-one\nsearch-two\nsearch-three\n"
        try write(readOriginal, to: readURL)
        try write(searchOriginal, to: searchURL)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path, kind: .sessionWorktree)
        let maybeReadRecord = await store.file(rootID: root.id, relativePath: "Read.swift")
        let readRecord = try XCTUnwrap(maybeReadRecord)
        let maybeSearchRecord = await store.file(rootID: root.id, relativePath: "Search.swift")
        let searchRecord = try XCTUnwrap(maybeSearchRecord)
        let readSnapshot = try await store.interactiveReadSnapshot(for: readRecord)
        XCTAssertEqual(readSnapshot?.preparedContent.linesWithEndings.joined(), readOriginal)
        let searchSnapshot = try await store.searchContentSnapshot(for: searchRecord)
        XCTAssertTrue(searchSnapshot.isFresh)
        XCTAssertEqual(searchSnapshot.content, searchOriginal)

        let stream = await store.appliedIndexEvents()
        let eventTask = Task { () -> [WorkspaceAppliedIndexBatchEvent] in
            var events: [WorkspaceAppliedIndexBatchEvent] = []
            for await event in stream where !event.modifiedFileIDs.isEmpty {
                events.append(event)
                if events.count == 3 { return events }
            }
            return events
        }

        _ = try await store.editFile(rootID: root.id, relativePath: "Read.swift", newContent: "read-edited\n")
        _ = try await store.editFile(rootID: root.id, relativePath: "Search.swift", newContent: "search-edited\n")
        try await store.deleteFile(rootID: root.id, relativePath: "Read.swift")
        _ = try await store.createFile(rootID: root.id, relativePath: "Read.swift", content: "replacement\n")
        let maybeReplacementRecord = await store.file(rootID: root.id, relativePath: "Read.swift")
        let replacementRecord = try XCTUnwrap(maybeReplacementRecord)
        XCTAssertNotEqual(replacementRecord.id, readRecord.id)
        _ = try await store.editFile(rootID: root.id, relativePath: "Read.swift", newContent: "replacement-edited\n")

        let events = await eventTask.value
        XCTAssertEqual(events.count, 3)
        let readEvent = try XCTUnwrap(events.first { $0.modifiedFileIDs.contains(readRecord.id) })
        let searchEvent = try XCTUnwrap(events.first { $0.modifiedFileIDs.contains(searchRecord.id) })
        let replacementEvent = try XCTUnwrap(events.first { $0.modifiedFileIDs.contains(replacementRecord.id) })
        let rootLifetimeID = try XCTUnwrap(readEvent.rootLifetimeID)
        XCTAssertEqual(searchEvent.rootLifetimeID, rootLifetimeID)
        XCTAssertEqual(replacementEvent.rootLifetimeID, rootLifetimeID)
        XCTAssertEqual(readEvent.modifiedFileSourceSnapshotsByID[readRecord.id]?.text, readOriginal)
        XCTAssertEqual(searchEvent.modifiedFileSourceSnapshotsByID[searchRecord.id]?.text, searchOriginal)
        XCTAssertNil(replacementEvent.modifiedFileSourceSnapshotsByID[replacementRecord.id])
        XCTAssertEqual(readEvent.modifiedFileSourceSnapshotsByID[readRecord.id]?.rootLifetimeID, rootLifetimeID)
        XCTAssertEqual(readEvent.modifiedFileSourceSnapshotsByID[readRecord.id]?.fileID, readRecord.id)
        XCTAssertEqual(readEvent.modifiedFileSourceSnapshotsByID[readRecord.id]?.fullPath, readRecord.standardizedFullPath)
    }

    private final class LockedFileSystemPublications: @unchecked Sendable {
        private let lock = NSLock()
        private var publications: [FileSystemDeltaPublication] = []

        func append(_ publication: FileSystemDeltaPublication) {
            lock.lock()
            publications.append(publication)
            lock.unlock()
        }

        func snapshot() -> [FileSystemDeltaPublication] {
            lock.lock()
            defer { lock.unlock() }
            return publications
        }
    }

    #if DEBUG
        private final class LockedWorkspaceDiagnosticsClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64

            init(nowNanoseconds: UInt64) {
                value = nowNanoseconds
            }

            func now() -> UInt64 {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func advance(milliseconds: UInt64) {
                lock.lock()
                value &+= milliseconds * 1_000_000
                lock.unlock()
            }
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
        for _ in 0 ..< 250 {
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
