import CoreServices
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
        func testFlushWaitsForPublisherIngressAlreadyEmittedBeforeBarrier() async throws {
            let root = try makeTemporaryRoot(name: "FlushPublisherIngress")
            let lateFileURL = root.appendingPathComponent("Late.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let sinkGate = AsyncGate()
            let flushWaitSignal = AsyncSignal()
            let flushCompletedSignal = AsyncSignal()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setPublisherIngressWillWaitHandler { rootIDs in
                guard rootIDs.contains(rootID) else { return }
                await flushWaitSignal.mark()
            }

            try write("late", to: lateFileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: [.fileAdded("Late.swift")])
            await sinkGate.waitUntilStarted()
            let pendingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertGreaterThan(pendingIngressCount, 0)

            let flushTask = Task {
                let samples = await store.flushPendingServiceEventsForAllRoots()
                await flushCompletedSignal.mark()
                return samples
            }
            await flushWaitSignal.waitUntilMarked()
            let flushCompletedBeforeRelease = await flushCompletedSignal.isMarked()
            XCTAssertFalse(flushCompletedBeforeRelease)

            await sinkGate.release()
            let samples = await flushTask.value
            let lateFile = await store.file(rootID: rootID, relativePath: "Late.swift")
            let remainingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertEqual(samples.map(\.rootPath), [root.path])
            XCTAssertNotNil(lateFile)
            XCTAssertEqual(remainingIngressCount, 0)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setPublisherIngressWillWaitHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testFlushWaitsForSyntheticMutationPublisherIngress() async throws {
            let root = try makeTemporaryRoot(name: "FlushSyntheticPublisherIngress")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let sinkGate = AsyncGate()
            let flushWaitSignal = AsyncSignal()
            let flushCompletedSignal = AsyncSignal()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setPublisherIngressWillWaitHandler { rootIDs in
                guard rootIDs.contains(rootID) else { return }
                await flushWaitSignal.mark()
            }

            let createTask = Task {
                try await store.createFile(rootID: rootID, relativePath: "Created.swift", content: "created")
            }
            await sinkGate.waitUntilStarted()
            _ = try await createTask.value
            let pendingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertGreaterThan(pendingIngressCount, 0)

            let flushTask = Task {
                _ = await store.flushPendingServiceEventsForAllRoots()
                await flushCompletedSignal.mark()
            }
            await flushWaitSignal.waitUntilMarked()
            let flushCompletedBeforeRelease = await flushCompletedSignal.isMarked()
            XCTAssertFalse(flushCompletedBeforeRelease)

            await sinkGate.release()
            await flushTask.value
            let createdFile = await store.file(rootID: rootID, relativePath: "Created.swift")
            let remainingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertNotNil(createdFile)
            XCTAssertEqual(remainingIngressCount, 0)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setPublisherIngressWillWaitHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testCancelledCreateSettlesBeforeUncancellableIOAndReconcilesCatalogAfterCompletion() async throws {
            let root = try makeTemporaryRoot(name: "CancelledCreateReconciliation")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(loadedService)
            let mutationGate = AsyncGate()
            await service.setMutationIOWillBeginHandlerForTesting { operation in
                guard operation == .create else { return }
                await mutationGate.markStartedAndWaitForRelease()
            }

            let createTask = Task {
                try await store.createFile(
                    rootID: record.id,
                    relativePath: "CreatedAfterCancellation.swift",
                    content: "struct CreatedAfterCancellation {}"
                )
            }
            await mutationGate.waitUntilStarted()
            let settledSignal = AsyncSignal()
            let resultTask = Task {
                do {
                    _ = try await createTask.value
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

            createTask.cancel()

            let settledBeforeRelease = await waitForAsyncCondition(maxYields: 10000) {
                await settledSignal.isMarked()
            }
            XCTAssertTrue(settledBeforeRelease)
            let waiterCountAfterCancellation = await service.pendingMutationWaiterCountForTesting()
            XCTAssertEqual(waiterCountAfterCancellation, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("CreatedAfterCancellation.swift").path))

            await mutationGate.release()
            let observedCancellation = await resultTask.value
            XCTAssertTrue(observedCancellation)
            let reconciled = await waitForAsyncCondition(maxYields: 10000) {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("CreatedAfterCancellation.swift").path) else {
                    return false
                }
                return await store.file(
                    rootID: record.id,
                    relativePath: "CreatedAfterCancellation.swift"
                ) != nil
            }
            XCTAssertTrue(reconciled)
            let finalWaiterCount = await service.pendingMutationWaiterCountForTesting()
            XCTAssertEqual(finalWaiterCount, 0)

            await service.setMutationIOWillBeginHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testCancelledOverwriteSettlesBeforeUncancellableIOAndReconcilesCatalogAfterCompletion() async throws {
            let root = try makeTemporaryRoot(name: "CancelledOverwriteReconciliation")
            let fileURL = root.appendingPathComponent("OverwriteAfterCancellation.swift")
            try write("old", to: fileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(loadedService)
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
            let settledBeforeRelease = await waitForAsyncCondition(maxYields: 10000) {
                await settledSignal.isMarked()
            }
            XCTAssertTrue(settledBeforeRelease)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "old")
            let waiterCountAfterCancellation = await service.pendingMutationWaiterCountForTesting()
            XCTAssertEqual(waiterCountAfterCancellation, 0)

            await mutationGate.release()
            let observedCancellation = await resultTask.value
            XCTAssertTrue(observedCancellation)
            let reconciled = await waitForAsyncCondition(maxYields: 10000) {
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

            await service.setMutationIOWillBeginHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testCancelledMoveDeleteAndTrashSettleBeforeIOAndReconcileAfterCompletion() async throws {
            let root = try makeTemporaryRoot(name: "CancelledMutationReconciliation")
            try write("move", to: root.appendingPathComponent("MoveSource.swift"))
            try write("delete", to: root.appendingPathComponent("Delete.swift"))
            try write("trash", to: root.appendingPathComponent("Trash.swift"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(loadedService)

            func exercise(
                operation: FileSystemUncancellableMutation,
                mutation: @escaping () async throws -> Void,
                beforeRelease: () -> Bool,
                reconciled: @escaping () async -> Bool
            ) async throws {
                let gate = AsyncGate()
                await service.setMutationIOWillBeginHandlerForTesting { observed in
                    guard observed == operation else { return }
                    await gate.markStartedAndWaitForRelease()
                }
                let mutationTask = Task {
                    try await mutation()
                }
                await gate.waitUntilStarted()
                let settledSignal = AsyncSignal()
                let resultTask = Task {
                    do {
                        try await mutationTask.value
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

                mutationTask.cancel()
                let settledBeforeRelease = await waitForAsyncCondition(maxYields: 10000) {
                    await settledSignal.isMarked()
                }
                XCTAssertTrue(settledBeforeRelease)
                XCTAssertTrue(beforeRelease())
                let waiterCountAfterCancellation = await service.pendingMutationWaiterCountForTesting()
                XCTAssertEqual(waiterCountAfterCancellation, 0)

                await gate.release()
                let observedCancellation = await resultTask.value
                XCTAssertTrue(observedCancellation)
                let didReconcile = await waitForAsyncCondition(maxYields: 10000, reconciled)
                XCTAssertTrue(didReconcile)
                let finalWaiterCount = await service.pendingMutationWaiterCountForTesting()
                XCTAssertEqual(finalWaiterCount, 0)
            }

            try await exercise(
                operation: .move,
                mutation: {
                    try await store.moveFile(
                        rootID: record.id,
                        from: "MoveSource.swift",
                        to: "MoveDestination.swift"
                    )
                },
                beforeRelease: {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent("MoveSource.swift").path)
                        && !FileManager.default.fileExists(atPath: root.appendingPathComponent("MoveDestination.swift").path)
                },
                reconciled: {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("MoveSource.swift").path),
                          FileManager.default.fileExists(atPath: root.appendingPathComponent("MoveDestination.swift").path)
                    else { return false }
                    let source = await store.file(rootID: record.id, relativePath: "MoveSource.swift")
                    let destination = await store.file(rootID: record.id, relativePath: "MoveDestination.swift")
                    return source == nil && destination != nil
                }
            )

            try await exercise(
                operation: .delete,
                mutation: {
                    try await store.deleteFile(rootID: record.id, relativePath: "Delete.swift")
                },
                beforeRelease: {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent("Delete.swift").path)
                },
                reconciled: {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Delete.swift").path) else {
                        return false
                    }
                    return await store.file(rootID: record.id, relativePath: "Delete.swift") == nil
                }
            )

            try await exercise(
                operation: .trash,
                mutation: {
                    try await store.moveItemToTrash(rootID: record.id, relativePath: "Trash.swift")
                },
                beforeRelease: {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash.swift").path)
                },
                reconciled: {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash.swift").path) else {
                        return false
                    }
                    return await store.file(rootID: record.id, relativePath: "Trash.swift") == nil
                }
            )

            await service.setMutationIOWillBeginHandlerForTesting(nil)
            await store.stopWatchingRoot(id: record.id)
        }

        func testStopWatchingRootDrainsTrackedPublisherIngress() async throws {
            let root = try makeTemporaryRoot(name: "StopWatcherPublisherIngress")
            let lateFileURL = root.appendingPathComponent("Late.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let sinkGate = AsyncGate()
            let stopWaitSignal = AsyncSignal()
            let stopCompletedSignal = AsyncSignal()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setPublisherIngressWillWaitHandler { rootIDs in
                guard rootIDs.contains(rootID) else { return }
                await stopWaitSignal.mark()
            }

            try write("late", to: lateFileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: [.fileAdded("Late.swift")])
            await sinkGate.waitUntilStarted()

            let stopTask = Task {
                await store.stopWatchingRoot(id: rootID)
                await stopCompletedSignal.mark()
            }
            await stopWaitSignal.waitUntilMarked()
            let stopCompletedBeforeRelease = await stopCompletedSignal.isMarked()
            let pendingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertFalse(stopCompletedBeforeRelease)
            XCTAssertGreaterThan(pendingIngressCount, 0)

            await sinkGate.release()
            await stopTask.value
            let lateFile = await store.file(rootID: rootID, relativePath: "Late.swift")
            let remainingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertNotNil(lateFile)
            XCTAssertEqual(remainingIngressCount, 0)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setPublisherIngressWillWaitHandler(nil)
        }

        func testUnloadRootDrainsTrackedPublisherIngressWithoutPostDetachMutation() async throws {
            let root = try makeTemporaryRoot(name: "UnloadPublisherIngress")
            let lateFileURL = root.appendingPathComponent("Late.swift")
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let store = WorkspaceFileContextStore(
                unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                    publisherIngressGraceNanoseconds: 11,
                    watcherStopGraceNanoseconds: 22,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            )
            let diagnosticsRecorder = WorkspaceRootUnloadDiagnosticsRecorder()
            await store.setRootUnloadTerminationDidCompleteHandler { diagnostics in
                await diagnosticsRecorder.record(diagnostics)
            }
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let sinkGate = AsyncGate()
            let unloadWaitSignal = AsyncSignal()
            let unloadCompletedSignal = AsyncSignal()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setPublisherIngressWillWaitHandler { rootIDs in
                guard rootIDs.contains(rootID) else { return }
                await unloadWaitSignal.mark()
            }

            try write("late", to: lateFileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: [.fileAdded("Late.swift")])
            await sinkGate.waitUntilStarted()

            let unloadTask = Task {
                await store.unloadRoot(id: rootID)
                await unloadCompletedSignal.mark()
            }
            await unloadWaitSignal.waitUntilMarked()
            await sleeper.waitUntilSleeping(nanoseconds: 11)
            let unloadCompletedBeforeRelease = await unloadCompletedSignal.isMarked()
            let rootsDuringUnload = await store.roots()
            let pendingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            XCTAssertFalse(unloadCompletedBeforeRelease)
            XCTAssertTrue(rootsDuringUnload.isEmpty)
            XCTAssertGreaterThan(pendingIngressCount, 0)

            await sinkGate.release()
            await unloadTask.value
            let lateFile = await store.file(rootID: rootID, relativePath: "Late.swift")
            let remainingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            let recordedDiagnostics = await diagnosticsRecorder.snapshot()
            let diagnostics = try XCTUnwrap(recordedDiagnostics)
            let publisherReport = try XCTUnwrap(diagnostics.publisherIngressReports.first)
            XCTAssertNil(lateFile)
            XCTAssertEqual(remainingIngressCount, 0)
            XCTAssertEqual(publisherReport.rootID, rootID)
            XCTAssertEqual(publisherReport.outcome, .graceful)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setPublisherIngressWillWaitHandler(nil)
            await store.setRootUnloadTerminationDidCompleteHandler(nil)
        }

        func testUnloadRootForceDiscardsWedgedPublisherIngressAndReleasesWaiters() async throws {
            let root = try makeTemporaryRoot(name: "UnloadForcedPublisherIngress")
            let firstURL = root.appendingPathComponent("First.swift")
            let secondURL = root.appendingPathComponent("Second.swift")
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let store = WorkspaceFileContextStore(
                unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                    publisherIngressGraceNanoseconds: 11,
                    watcherStopGraceNanoseconds: 22,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            )
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let baselineAppliedSequence = await store.appliedIngressSnapshotForTesting(rootID: record.id)
                .appliedServicePublicationSequence

            let sinkGate = AsyncGate()
            let unloadCompleted = AsyncSignal()
            let waiterCompleted = AsyncSignal()
            let diagnosticsRecorder = WorkspaceRootUnloadDiagnosticsRecorder()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setRootUnloadTerminationDidCompleteHandler { diagnostics in
                await diagnosticsRecorder.record(diagnostics)
            }

            try write("first", to: firstURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded("First.swift")]
            )
            await sinkGate.waitUntilStarted()
            try write("second", to: secondURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded("Second.swift")]
            )
            let targetSequence = await store.appliedIngressSnapshotForTesting(rootID: rootID)
                .acceptedServicePublicationSequence
            let waiter = Task {
                await store.waitUntilPublisherIngressAppliedForTesting(
                    rootID: rootID,
                    servicePublicationSequence: targetSequence
                )
                await waiterCompleted.mark()
            }
            let waiterRegistered = await waitForAsyncCondition {
                await store.publisherIngressDebugSnapshotForTesting(rootID: rootID).waiterCount == 1
            }
            XCTAssertTrue(waiterRegistered)

            let unload = Task {
                await store.unloadRoot(id: rootID)
                await unloadCompleted.mark()
            }
            await sleeper.waitUntilSleeping(nanoseconds: 11)
            let unloadCompletedBeforeTimeout = await unloadCompleted.isMarked()
            let waiterCompletedBeforeTimeout = await waiterCompleted.isMarked()
            XCTAssertFalse(unloadCompletedBeforeTimeout)
            XCTAssertFalse(waiterCompletedBeforeTimeout)

            await sleeper.release(nanoseconds: 11)
            await unload.value
            await waiter.value

            let recordedDiagnostics = await diagnosticsRecorder.snapshot()
            let diagnostics = try XCTUnwrap(recordedDiagnostics)
            let publisherReport = try XCTUnwrap(diagnostics.publisherIngressReports.first)
            let unloadCompletedAfterTimeout = await unloadCompleted.isMarked()
            let waiterCompletedAfterTimeout = await waiterCompleted.isMarked()
            XCTAssertTrue(unloadCompletedAfterTimeout)
            XCTAssertTrue(waiterCompletedAfterTimeout)
            XCTAssertEqual(publisherReport.rootID, rootID)
            XCTAssertEqual(publisherReport.outcome, .forced)
            XCTAssertEqual(publisherReport.queuedPublicationCount, 1)
            XCTAssertEqual(publisherReport.applyingPublicationCount, 1)
            XCTAssertEqual(publisherReport.waiterCount, 1)
            XCTAssertEqual(publisherReport.acceptedServicePublicationSequence, targetSequence)
            XCTAssertEqual(publisherReport.appliedServicePublicationSequence, baselineAppliedSequence)
            let remainingIngressCount = await store.publisherIngressCountForTesting(rootID: rootID)
            let remainingRoots = await store.roots()
            let sinkStartCountBeforeRelease = await sinkGate.startCount()
            XCTAssertEqual(remainingIngressCount, 0)
            XCTAssertTrue(remainingRoots.isEmpty)
            XCTAssertEqual(sinkStartCountBeforeRelease, 1)

            await sinkGate.release()
            let staleDrainFinished = await waitForAsyncCondition {
                await sinkGate.startCount() == 1
            }
            XCTAssertTrue(staleDrainFinished)
            let sinkStartCountAfterRelease = await sinkGate.startCount()
            XCTAssertEqual(sinkStartCountAfterRelease, 1)
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setRootUnloadTerminationDidCompleteHandler(nil)
        }

        func testWatcherBoundedWaitPrefersCompletionThatRacesTimeout() async {
            let latch = WorkspaceRootUnloadCompletionLatch()

            let outcome = await WorkspaceRootUnloadBoundedWait.waitForCompletion(
                latch,
                timeoutNanoseconds: 22,
                sleep: { _ in latch.complete() }
            )

            XCTAssertEqual(outcome, .completed)

            let cancellationRaceLatch = WorkspaceRootUnloadCompletionLatch()
            cancellationRaceLatch.complete()
            XCTAssertEqual(
                cancellationRaceLatch.resolvedOutcome(after: .cancelled),
                .completed
            )
        }

        func testUnloadRootBoundsWatcherStopCallerSideWithoutInterruptClaim() async throws {
            let root = try makeTemporaryRoot(name: "UnloadWatcherStopBound")
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let store = WorkspaceFileContextStore(
                unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                    publisherIngressGraceNanoseconds: 11,
                    watcherStopGraceNanoseconds: 22,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            )
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let watcherStopGate = AsyncGate()
            let unloadCompleted = AsyncSignal()
            let diagnosticsRecorder = WorkspaceRootUnloadDiagnosticsRecorder()
            await store.setWatcherStopWillBeginHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await watcherStopGate.markStartedAndWaitForRelease()
            }
            await store.setRootUnloadTerminationDidCompleteHandler { diagnostics in
                await diagnosticsRecorder.record(diagnostics)
            }

            let unload = Task {
                await store.unloadRoot(id: record.id)
                await unloadCompleted.mark()
            }
            await watcherStopGate.waitUntilStarted()
            await sleeper.waitUntilSleeping(nanoseconds: 22)
            let unloadCompletedBeforeTimeout = await unloadCompleted.isMarked()
            XCTAssertFalse(unloadCompletedBeforeTimeout)

            await sleeper.release(nanoseconds: 22)
            await unload.value

            let recordedDiagnostics = await diagnosticsRecorder.snapshot()
            let diagnostics = try XCTUnwrap(recordedDiagnostics)
            let watcherReport = try XCTUnwrap(diagnostics.watcherStopReports.first)
            let unloadCompletedAfterTimeout = await unloadCompleted.isMarked()
            XCTAssertTrue(unloadCompletedAfterTimeout)
            XCTAssertEqual(watcherReport.rootID, record.id)
            XCTAssertEqual(watcherReport.outcome, .timedOut)
            let remainingRoots = await store.roots()
            XCTAssertTrue(remainingRoots.isEmpty)

            await watcherStopGate.release()
            await store.setWatcherStopWillBeginHandler(nil)
            await store.setRootUnloadTerminationDidCompleteHandler(nil)
        }

        func testUnloadRootReportsCompletedWatcherStopWhenStopFinishesWithinGrace() async throws {
            let root = try makeTemporaryRoot(name: "UnloadWatcherStopCompleted")
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let store = WorkspaceFileContextStore(
                unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                    publisherIngressGraceNanoseconds: 11,
                    watcherStopGraceNanoseconds: 22,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            )
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let diagnosticsRecorder = WorkspaceRootUnloadDiagnosticsRecorder()
            await store.setRootUnloadTerminationDidCompleteHandler { diagnostics in
                await diagnosticsRecorder.record(diagnostics)
            }

            await store.unloadRoot(id: record.id)

            let recordedDiagnostics = await diagnosticsRecorder.snapshot()
            let diagnostics = try XCTUnwrap(recordedDiagnostics)
            let watcherReport = try XCTUnwrap(diagnostics.watcherStopReports.first)
            XCTAssertEqual(watcherReport.rootID, record.id)
            XCTAssertEqual(watcherReport.outcome, .completed)
            let remainingRoots = await store.roots()
            XCTAssertTrue(remainingRoots.isEmpty)
            await store.setRootUnloadTerminationDidCompleteHandler(nil)
        }

        func testCancelledUnloadReportsWatcherStopCancelledWhileDetachedStopIsBlocked() async throws {
            let root = try makeTemporaryRoot(name: "UnloadWatcherStopCancelled")
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let store = WorkspaceFileContextStore(
                unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                    publisherIngressGraceNanoseconds: 11,
                    watcherStopGraceNanoseconds: 22,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            )
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let watcherStopGate = AsyncGate()
            let diagnosticsRecorder = WorkspaceRootUnloadDiagnosticsRecorder()
            await store.setWatcherStopWillBeginHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await watcherStopGate.markStartedAndWaitForRelease()
            }
            await store.setRootUnloadTerminationDidCompleteHandler { diagnostics in
                await diagnosticsRecorder.record(diagnostics)
            }

            let unload = Task {
                await store.unloadRoot(id: record.id)
            }
            await watcherStopGate.waitUntilStarted()
            await sleeper.waitUntilSleeping(nanoseconds: 22)
            unload.cancel()
            await unload.value

            let recordedDiagnostics = await diagnosticsRecorder.snapshot()
            let diagnostics = try XCTUnwrap(recordedDiagnostics)
            let watcherReport = try XCTUnwrap(diagnostics.watcherStopReports.first)
            XCTAssertEqual(watcherReport.rootID, record.id)
            XCTAssertEqual(watcherReport.outcome.rawValue, "cancelled")
            let remainingRoots = await store.roots()
            XCTAssertTrue(remainingRoots.isEmpty)

            await watcherStopGate.release()
            await store.setWatcherStopWillBeginHandler(nil)
            await store.setRootUnloadTerminationDidCompleteHandler(nil)
        }

        func testStalePublisherLifetimeCannotMutateCurrentRootState() async throws {
            let root = try makeTemporaryRoot(name: "StalePublisherLifetime")
            let lateURL = root.appendingPathComponent("Late.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let currentLifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)
            try write("late", to: lateURL)

            await store.replayPublisherFileSystemPublicationForTesting(
                rootID: record.id,
                expectedLifetimeID: UUID(),
                deltas: [.fileAdded("Late.swift")]
            )
            let staleLifetimeFile = await store.file(rootID: record.id, relativePath: "Late.swift")
            XCTAssertNil(staleLifetimeFile)

            await store.replayPublisherFileSystemPublicationForTesting(
                rootID: record.id,
                expectedLifetimeID: currentLifetimeID,
                deltas: [.fileAdded("Late.swift")]
            )
            let currentLifetimeFile = await store.file(rootID: record.id, relativePath: "Late.swift")
            XCTAssertNotNil(currentLifetimeFile)
        }

        @MainActor
        func testRecoveryFullResyncPublicationFlagsAppliedIndexEvent() async throws {
            let root = try makeTemporaryRoot(name: "RecoveryFullResyncAppliedIndex")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)
            let eventStream = await store.appliedIndexEvents()
            var events = eventStream.makeAsyncIterator()

            await store.replayPublisherFileSystemPublicationForTesting(
                rootID: record.id,
                expectedLifetimeID: lifetimeID,
                deltas: [],
                requiresFullResync: true
            )
            let event = await events.next()

            XCTAssertEqual(event?.rootID, record.id)
            XCTAssertEqual(event?.requiresFullResync, true)
        }

        func testWatcherActivationFailureThrowsAndRollsBackStoreLifecycle() async throws {
            let root = try makeTemporaryRoot(name: "WatcherActivationFailure")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
            let service = try XCTUnwrap(loadedService)
            await service.setWatcherActivationFailureForTesting(.streamStart)

            do {
                try await store.startWatchingRoot(id: record.id)
                XCTFail("Expected watcher activation to fail")
            } catch let error as FileSystemWatcherActivationError {
                XCTAssertEqual(error, .streamStartFailed(path: root.path))
            } catch {
                return XCTFail("Expected typed watcher activation error, got \(error)")
            }

            let watcherIsActiveAfterFailure = try await store.rootWatcherIsActiveForTesting(rootID: record.id)
            let pendingIngressAfterFailure = await store.publisherIngressCountForTesting(rootID: record.id)
            XCTAssertFalse(watcherIsActiveAfterFailure)
            XCTAssertEqual(pendingIngressAfterFailure, 0)

            await service.setWatcherActivationFailureForTesting(nil)
            try await store.startWatchingRoot(id: record.id)
            let watcherIsActiveAfterRetry = try await store.rootWatcherIsActiveForTesting(rootID: record.id)
            XCTAssertTrue(watcherIsActiveAfterRetry)
            await store.stopWatchingRoot(id: record.id)
        }

        @MainActor
        func testRedundantStartWatchingRootKeepsPublisherSinkAttached() async throws {
            let root = try makeTemporaryRoot(name: "RedundantStartWatcherPublisherIngress")
            let lateFileURL = root.appendingPathComponent("Late.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let rootID = record.id
            addTeardownBlock {
                await store.stopWatchingRoot(id: rootID)
            }

            try await store.startWatchingRoot(id: rootID)
            try write("late", to: lateFileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded("Late.swift")]
            )
            _ = await store.flushPendingServiceEventsForAllRoots()
            let lateFile = await store.file(rootID: rootID, relativePath: "Late.swift")
            XCTAssertNotNil(lateFile)

            await store.stopWatchingRoot(id: rootID)
        }

        func testWatcherRestartWinsRaceWithStaleStopReconciliation() async throws {
            let root = try makeTemporaryRoot(name: "WatcherRestartWinsStaleStop")
            let lateFileURL = root.appendingPathComponent("Late.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let staleStopGate = AsyncGate()
            let rootID = record.id
            await store.setWatcherServiceStateWillReconcileHandler { observedRootID, shouldWatch in
                guard observedRootID == rootID, !shouldWatch else { return }
                await staleStopGate.markStartedAndWaitForRelease()
            }

            let stopTask = Task {
                await store.stopWatchingRoot(id: rootID)
            }
            await staleStopGate.waitUntilStarted()
            try await store.startWatchingRoot(id: rootID)
            await staleStopGate.release()
            await stopTask.value

            let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: rootID)
            XCTAssertTrue(watcherIsActive)
            try write("late", to: lateFileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: [.fileAdded("Late.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()
            let lateFile = await store.file(rootID: rootID, relativePath: "Late.swift")
            XCTAssertNotNil(lateFile)

            await store.setWatcherServiceStateWillReconcileHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testAcceptedCallbackBeforeActorEntryDelaysBarrierUntilCanonicalApply() async throws {
            let root = try makeTemporaryRoot(name: "AcceptedCallbackCanonicalBarrier")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let sinkGate = AsyncGate()
            let barrierCompleted = AsyncSignal()
            let rootID = record.id
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }

            let acceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(absolutePath: "/outside/before-actor-entry.swift", flags: createdFileFlags, eventId: 100)],
                scheduleDrain: false
            )
            let accepted = try XCTUnwrap(acceptedPayload)
            let barrierTask = Task {
                let samples = await store.awaitAppliedIngressForAllRoots()
                await barrierCompleted.mark()
                return samples
            }
            await sinkGate.waitUntilStarted()
            let completedBeforeRelease = await barrierCompleted.isMarked()
            XCTAssertFalse(completedBeforeRelease)

            await sinkGate.release()
            let samples = await barrierTask.value
            let sample = try XCTUnwrap(samples.first)
            XCTAssertEqual(sample.acceptedWatcherWatermark, accepted.rawValue)
            XCTAssertGreaterThanOrEqual(sample.appliedWatcherWatermark, accepted.rawValue)

            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testBarrierCaptureCutExcludesCallbackAcceptedAfterCaptureUntilNextBarrier() async throws {
            let root = try makeTemporaryRoot(name: "AcceptedCallbackCaptureCut")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let baselineWatermark = await store.appliedIngressSnapshotForTesting(rootID: record.id)
                .appliedWatcherWatermark.rawValue

            let captureGate = AsyncGate()
            let rootID = record.id
            await store.setAppliedIngressDidCaptureWatermarksHandler { captured in
                guard captured[rootID] == baselineWatermark else { return }
                await captureGate.markStartedAndWaitForRelease()
            }

            let firstBarrierTask = Task {
                await store.awaitAppliedIngressForAllRoots()
            }
            await captureGate.waitUntilStarted()
            let acceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(absolutePath: "/outside/after-capture.swift", flags: createdFileFlags, eventId: 200)],
                scheduleDrain: false
            )
            let accepted = try XCTUnwrap(acceptedPayload)
            await captureGate.release()
            let firstSamples = await firstBarrierTask.value
            XCTAssertEqual(firstSamples.first?.acceptedWatcherWatermark, baselineWatermark)
            XCTAssertEqual(firstSamples.first?.appliedWatcherWatermark, baselineWatermark)

            await store.setAppliedIngressDidCaptureWatermarksHandler(nil)
            let secondSamples = await store.awaitAppliedIngressForAllRoots()
            XCTAssertGreaterThanOrEqual(secondSamples.first?.acceptedWatcherWatermark ?? 0, accepted.rawValue)
            XCTAssertGreaterThanOrEqual(secondSamples.first?.appliedWatcherWatermark ?? 0, accepted.rawValue)

            await store.stopWatchingRoot(id: rootID)
        }

        func testSyntheticPublicationAppliesWithoutAdvancingWatcherAcceptedWatermark() async throws {
            let root = try makeTemporaryRoot(name: "SyntheticPublicationWatermark")
            let lateFileURL = root.appendingPathComponent("Synthetic.swift")
            try write("synthetic", to: lateFileURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let baselineIngress = await store.appliedIngressSnapshotForTesting(rootID: record.id)
            let baselineWatcherWatermark = try await store.acceptedWatcherWatermarkForTesting(rootID: record.id)

            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileModified("Synthetic.swift", nil)])
            let samples = await store.awaitAppliedIngressForAllRoots()
            let sample = try XCTUnwrap(samples.first)
            let applied = await store.appliedIngressSnapshotForTesting(rootID: record.id)

            XCTAssertEqual(sample.acceptedWatcherWatermark, baselineWatcherWatermark.rawValue)
            XCTAssertEqual(sample.appliedWatcherWatermark, baselineWatcherWatermark.rawValue)
            XCTAssertGreaterThan(sample.appliedServicePublicationSequence, baselineIngress.appliedServicePublicationSequence)
            XCTAssertGreaterThan(applied.appliedServicePublicationSequence, baselineIngress.appliedServicePublicationSequence)
            XCTAssertEqual(applied.appliedWatcherWatermark, baselineWatcherWatermark)
            let syntheticFile = await store.file(rootID: record.id, relativePath: "Synthetic.swift")
            XCTAssertNotNil(syntheticFile)

            await store.stopWatchingRoot(id: record.id)
        }

        func testBarrierAfterWatcherRestartDoesNotWaitForPublicationEmittedWhileSinkDetached() async throws {
            let root = try makeTemporaryRoot(name: "DetachedPublicationRestartBarrier")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            await store.stopWatchingRoot(id: record.id)

            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Detached.swift")])
            try await store.startWatchingRoot(id: record.id)
            let restartBaseline = await store.appliedIngressSnapshotForTesting(rootID: record.id)
            let samples = await store.awaitAppliedIngressForAllRoots()
            let sample = try XCTUnwrap(samples.first)

            XCTAssertGreaterThan(sample.publishedServicePublicationSequence, 0)
            XCTAssertEqual(sample.appliedServicePublicationSequence, restartBaseline.appliedServicePublicationSequence)
            XCTAssertEqual(sample.appliedWatcherWatermark, restartBaseline.appliedWatcherWatermark.rawValue)
            await store.stopWatchingRoot(id: record.id)
        }

        func testWorkspaceIngressCoordinatorDrainsPublicationsInAcceptedOrder() async {
            let coordinator = WorkspaceFileSystemIngressCoordinator()
            let rootID = UUID()
            let recorder = OrderedIngressRecorder()
            let firstApplyGate = AsyncGate()
            let subscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                await recorder.append(publication.servicePublicationSequence)
                if publication.servicePublicationSequence == 1 {
                    await firstApplyGate.markStartedAndWaitForRelease()
                }
            }

            XCTAssertTrue(coordinator.accept(
                subscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 1,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: [.fileAdded("A.swift")]
                ),
                lifecycleCorrelation: nil
            ))
            await firstApplyGate.waitUntilStarted()
            XCTAssertTrue(coordinator.accept(
                subscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 2,
                    source: .watcherBarrierNoop,
                    watcherAcceptedWatermark: .init(rawValue: 7),
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))

            await firstApplyGate.release()
            await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 2)
            let recordedSequences = await recorder.snapshot()
            XCTAssertEqual(recordedSequences, [1, 2])
            let applied = coordinator.appliedSnapshot(rootID: rootID)
            XCTAssertEqual(applied.appliedServicePublicationSequence, 2)
            XCTAssertEqual(applied.appliedWatcherWatermark.rawValue, 7)
        }

        #if DEBUG
            func testWorkspaceIngressCoordinatorCancelledWaiterDetachesWhileLiveWaiterCompletes() async {
                let coordinator = WorkspaceFileSystemIngressCoordinator()
                let rootID = UUID()
                let applyGate = AsyncGate()
                let subscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                    guard publication.servicePublicationSequence == 1 else { return }
                    await applyGate.markStartedAndWaitForRelease()
                }

                XCTAssertTrue(coordinator.accept(
                    subscription,
                    publication: FileSystemDeltaPublication(
                        servicePublicationSequence: 1,
                        source: .watcherBarrierNoop,
                        watcherAcceptedWatermark: .init(rawValue: 13),
                        deltas: []
                    ),
                    lifecycleCorrelation: nil
                ))
                await applyGate.waitUntilStarted()

                let cancelledCompleted = AsyncSignal()
                let liveCompleted = AsyncSignal()
                let cancelledWaiter = Task {
                    await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 1)
                    await cancelledCompleted.mark()
                }
                let liveWaiter = Task {
                    await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 1)
                    await liveCompleted.mark()
                }
                let bothRegistered = await waitForAsyncCondition {
                    coordinator.debugSnapshot(rootID: rootID).waiterCount == 2
                }
                XCTAssertTrue(bothRegistered)

                cancelledWaiter.cancel()
                let cancelledPromptly = await waitForAsyncCondition {
                    await cancelledCompleted.isMarked()
                }
                XCTAssertTrue(cancelledPromptly)
                let liveCompletedBeforeRelease = await liveCompleted.isMarked()
                XCTAssertFalse(liveCompletedBeforeRelease)
                let afterCancellation = coordinator.debugSnapshot(rootID: rootID)
                XCTAssertEqual(afterCancellation.waiterCount, 1)
                XCTAssertEqual(afterCancellation.appliedServicePublicationSequence, 0)
                XCTAssertEqual(afterCancellation.appliedWatcherWatermark, 0)

                await applyGate.release()
                await cancelledWaiter.value
                await liveWaiter.value
                let settled = coordinator.debugSnapshot(rootID: rootID)
                XCTAssertEqual(settled.waiterCount, 0)
                XCTAssertEqual(settled.appliedServicePublicationSequence, 1)
                XCTAssertEqual(settled.appliedWatcherWatermark, 13)
            }

            func testWorkspaceIngressCoordinatorDebugSnapshotReportsDepthGapAndOldestAge() async {
                let clock = LockedWorkspaceDiagnosticsClock(nowNanoseconds: 2_000_000_000)
                let coordinator = WorkspaceFileSystemIngressCoordinator(debugNowNanoseconds: { clock.now() })
                let rootID = UUID()
                let firstApplyGate = AsyncGate()
                let subscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                    if publication.servicePublicationSequence == 1 {
                        await firstApplyGate.markStartedAndWaitForRelease()
                    }
                }

                XCTAssertTrue(coordinator.accept(
                    subscription,
                    publication: FileSystemDeltaPublication(
                        servicePublicationSequence: 1,
                        source: .syntheticMutation,
                        watcherAcceptedWatermark: nil,
                        deltas: [.fileAdded("A.swift")]
                    ),
                    lifecycleCorrelation: nil
                ))
                await firstApplyGate.waitUntilStarted()
                XCTAssertTrue(coordinator.accept(
                    subscription,
                    publication: FileSystemDeltaPublication(
                        servicePublicationSequence: 2,
                        source: .watcherBarrierNoop,
                        watcherAcceptedWatermark: .init(rawValue: 9),
                        deltas: []
                    ),
                    lifecycleCorrelation: nil
                ))

                clock.advance(milliseconds: 450)
                let blocked = coordinator.debugSnapshot(rootID: rootID)
                XCTAssertTrue(blocked.isOpen)
                XCTAssertEqual(blocked.queuedPublicationCount, 1)
                XCTAssertEqual(blocked.applyingPublicationCount, 1)
                XCTAssertEqual(blocked.outstandingPublicationCount, 2)
                XCTAssertEqual(blocked.acceptedServicePublicationSequence, 2)
                XCTAssertEqual(blocked.appliedServicePublicationSequence, 0)
                XCTAssertEqual(blocked.acceptedAppliedSequenceGap, 2)
                XCTAssertEqual(blocked.appliedWatcherWatermark, 0)
                XCTAssertEqual(blocked.oldestOutstandingPublicationAgeMilliseconds, 450)

                await firstApplyGate.release()
                await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 2)
                let settled = coordinator.debugSnapshot(rootID: rootID)
                XCTAssertEqual(settled.queuedPublicationCount, 0)
                XCTAssertEqual(settled.applyingPublicationCount, 0)
                XCTAssertEqual(settled.outstandingPublicationCount, 0)
                XCTAssertEqual(settled.acceptedServicePublicationSequence, 2)
                XCTAssertEqual(settled.appliedServicePublicationSequence, 2)
                XCTAssertEqual(settled.acceptedAppliedSequenceGap, 0)
                XCTAssertEqual(settled.appliedWatcherWatermark, 9)
                XCTAssertNil(settled.oldestOutstandingPublicationAgeMilliseconds)
            }
        #endif

        func testWorkspaceIngressCoordinatorForcedTerminationDropsQueuedWorkReleasesWaitersAndReportsSnapshot() async throws {
            let clock = LockedWorkspaceDiagnosticsClock(nowNanoseconds: 7_000_000_000)
            let coordinator = WorkspaceFileSystemIngressCoordinator(debugNowNanoseconds: { clock.now() })
            let rootID = UUID()
            let firstApplyGate = AsyncGate()
            let recorder = OrderedIngressRecorder()
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let subscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                await recorder.append(publication.servicePublicationSequence)
                if publication.servicePublicationSequence == 1 {
                    await firstApplyGate.markStartedAndWaitForRelease()
                }
            }

            XCTAssertTrue(coordinator.accept(
                subscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 1,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: [.fileAdded("A.swift")]
                ),
                lifecycleCorrelation: nil
            ))
            await firstApplyGate.waitUntilStarted()
            XCTAssertTrue(coordinator.accept(
                subscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 2,
                    source: .watcherBarrierNoop,
                    watcherAcceptedWatermark: .init(rawValue: 17),
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            coordinator.closePublisherIngress(rootID: rootID)

            let waiterCompleted = AsyncSignal()
            let waiter = Task {
                await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 2)
                await waiterCompleted.mark()
            }
            let waiterRegistered = await waitForAsyncCondition {
                coordinator.debugSnapshot(rootID: rootID).waiterCount == 1
            }
            XCTAssertTrue(waiterRegistered)
            clock.advance(milliseconds: 625)

            let termination = Task {
                await coordinator.terminateClosedPublisherIngress(
                    rootIDs: [rootID],
                    gracefulDrainTimeoutNanoseconds: 11,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            }
            await sleeper.waitUntilSleeping(nanoseconds: 11)
            let waiterCompletedBeforeTimeout = await waiterCompleted.isMarked()
            XCTAssertFalse(waiterCompletedBeforeTimeout)
            await sleeper.release(nanoseconds: 11)

            let reports = await termination.value
            await waiter.value
            let report = try XCTUnwrap(reports.first)
            XCTAssertEqual(report.rootID, rootID)
            XCTAssertEqual(report.outcome, .forced)
            XCTAssertEqual(report.queuedPublicationCount, 1)
            XCTAssertEqual(report.applyingPublicationCount, 1)
            XCTAssertEqual(report.waiterCount, 1)
            XCTAssertEqual(report.acceptedServicePublicationSequence, 2)
            XCTAssertEqual(report.appliedServicePublicationSequence, 0)
            XCTAssertEqual(report.acceptedAppliedSequenceGap, 2)
            XCTAssertEqual(report.oldestOutstandingPublicationAgeMilliseconds, 625)
            let waiterCompletedAfterTimeout = await waiterCompleted.isMarked()
            let recordedBeforeRelease = await recorder.snapshot()
            XCTAssertTrue(waiterCompletedAfterTimeout)
            XCTAssertEqual(coordinator.pendingPublisherIngressCount(rootIDs: [rootID]), 0)
            XCTAssertEqual(recordedBeforeRelease, [1])

            await firstApplyGate.release()
            let recordedAfterRelease = await recorder.snapshot()
            XCTAssertEqual(recordedAfterRelease, [1])
        }

        func testWorkspaceIngressCoordinatorTerminationDoesNotForceReopenedIngressDuringGrace() async {
            let coordinator = WorkspaceFileSystemIngressCoordinator()
            let rootID = UUID()
            let oldApplyGate = AsyncGate()
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let oldSubscription = coordinator.openPublisherIngress(rootID: rootID) { _, _ in
                await oldApplyGate.markStartedAndWaitForRelease()
            }
            XCTAssertTrue(coordinator.accept(
                oldSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 40,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            await oldApplyGate.waitUntilStarted()
            coordinator.closePublisherIngress(rootID: rootID)

            let termination = Task {
                await coordinator.terminateClosedPublisherIngress(
                    rootIDs: [rootID],
                    gracefulDrainTimeoutNanoseconds: 11,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            }
            await sleeper.waitUntilSleeping(nanoseconds: 11)

            let reopenedRecorder = OrderedIngressRecorder()
            let reopenedSubscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                await reopenedRecorder.append(publication.servicePublicationSequence)
            }
            XCTAssertTrue(coordinator.accept(
                reopenedSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 41,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))

            await sleeper.release(nanoseconds: 11)
            let reports = await termination.value
            XCTAssertEqual(reports.first?.outcome, .superseded)
            XCTAssertTrue(coordinator.isPublisherIngressOpen(reopenedSubscription))
            XCTAssertTrue(coordinator.accept(
                reopenedSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 42,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))

            await oldApplyGate.release()
            await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 42)
            let reopenedSequences = await reopenedRecorder.snapshot()
            XCTAssertEqual(reopenedSequences, [41, 42])
        }

        func testWorkspaceIngressCoordinatorLateForcedDrainCannotCorruptReopenedSameRootState() async {
            let rootID = UUID()
            let oldFinishApplyingLatch = WorkspaceRootUnloadCompletionLatch()
            let coordinator = WorkspaceFileSystemIngressCoordinator(
                debugFinishApplyingHandler: { observedRootID, servicePublicationSequence in
                    guard observedRootID == rootID, servicePublicationSequence == 40 else { return }
                    oldFinishApplyingLatch.complete()
                }
            )
            let oldApplyGate = AsyncGate()
            let oldHandlerFinished = AsyncSignal()
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let oldSubscription = coordinator.openPublisherIngress(rootID: rootID) { _, _ in
                await oldApplyGate.markStartedAndWaitForRelease()
                await oldHandlerFinished.mark()
            }
            XCTAssertTrue(coordinator.accept(
                oldSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 40,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: .init(rawValue: 19),
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            await oldApplyGate.waitUntilStarted()
            coordinator.closePublisherIngress(rootID: rootID)

            let termination = Task {
                await coordinator.terminateClosedPublisherIngress(
                    rootIDs: [rootID],
                    gracefulDrainTimeoutNanoseconds: 11,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            }
            await sleeper.waitUntilSleeping(nanoseconds: 11)
            await sleeper.release(nanoseconds: 11)
            let reports = await termination.value
            XCTAssertEqual(reports.first?.outcome, .forced)

            let newRecorder = OrderedIngressRecorder()
            let newSubscription = coordinator.openPublisherIngress(rootID: rootID) { publication, _ in
                await newRecorder.append(publication.servicePublicationSequence)
            }
            XCTAssertFalse(coordinator.accept(
                oldSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 41,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            XCTAssertTrue(coordinator.accept(
                newSubscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 1,
                    source: .syntheticMutation,
                    watcherAcceptedWatermark: nil,
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 1)
            await oldApplyGate.release()
            await oldHandlerFinished.waitUntilMarked()
            _ = await oldFinishApplyingLatch.wait()

            XCTAssertEqual(coordinator.appliedSnapshot(rootID: rootID).appliedServicePublicationSequence, 1)
            XCTAssertEqual(coordinator.appliedSnapshot(rootID: rootID).appliedWatcherWatermark, .zero)
            let newRecordedSequences = await newRecorder.snapshot()
            XCTAssertEqual(newRecordedSequences, [1])
        }

        func testWorkspaceIngressCoordinatorTerminationPreservesGracefulCompletionWithinBound() async throws {
            let coordinator = WorkspaceFileSystemIngressCoordinator()
            let rootID = UUID()
            let applyGate = AsyncGate()
            let sleeper = ManualWorkspaceRootUnloadSleeper()
            let subscription = coordinator.openPublisherIngress(rootID: rootID) { _, _ in
                await applyGate.markStartedAndWaitForRelease()
            }
            XCTAssertTrue(coordinator.accept(
                subscription,
                publication: FileSystemDeltaPublication(
                    servicePublicationSequence: 1,
                    source: .watcherBarrierNoop,
                    watcherAcceptedWatermark: .init(rawValue: 23),
                    deltas: []
                ),
                lifecycleCorrelation: nil
            ))
            await applyGate.waitUntilStarted()
            coordinator.closePublisherIngress(rootID: rootID)

            let termination = Task {
                await coordinator.terminateClosedPublisherIngress(
                    rootIDs: [rootID],
                    gracefulDrainTimeoutNanoseconds: 11,
                    sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
                )
            }
            await sleeper.waitUntilSleeping(nanoseconds: 11)
            await applyGate.release()
            let reports = await termination.value
            let report = try XCTUnwrap(reports.first)

            XCTAssertEqual(report.outcome, .graceful)
            XCTAssertEqual(report.acceptedServicePublicationSequence, 1)
            XCTAssertEqual(report.appliedServicePublicationSequence, 1)
            XCTAssertEqual(report.appliedWatcherWatermark, 23)
            XCTAssertEqual(coordinator.pendingPublisherIngressCount(rootIDs: [rootID]), 0)
        }

        func testWorkspaceIngressCoordinatorFinishResolvesOutstandingWaiter() async {
            let coordinator = WorkspaceFileSystemIngressCoordinator()
            let rootID = UUID()
            _ = coordinator.openPublisherIngress(rootID: rootID) { _, _ in }
            coordinator.closePublisherIngress(rootID: rootID)
            let waiterCompleted = AsyncSignal()
            let waiterTask = Task {
                await coordinator.waitUntilApplied(rootID: rootID, servicePublicationSequence: 99)
                await waiterCompleted.mark()
            }

            await Task.yield()
            let completedBeforeFinish = await waiterCompleted.isMarked()
            XCTAssertFalse(completedBeforeFinish)
            coordinator.finishPublisherIngress(rootIDs: [rootID])
            await waiterTask.value
            let completedAfterFinish = await waiterCompleted.isMarked()
            XCTAssertTrue(completedAfterFinish)
        }

        func testScopedAppliedIngressConcurrentSameRootRequestsJoinOneFlight() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressSingleFlight")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let rootID = record.id
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let firstBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            await flushGate.waitUntilStarted()
            let secondBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }

            var stats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
            for _ in 0 ..< 100 where stats.joinCount == 0 {
                await Task.yield()
                stats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
            }
            XCTAssertEqual(stats.launchCount, 1)
            XCTAssertEqual(stats.joinCount, 1)
            XCTAssertEqual(stats.successorCount, 0)

            await flushGate.release()
            let firstSamples = await firstBarrier.value
            let secondSamples = await secondBarrier.value
            let flushStartCount = await flushGate.startCount()
            XCTAssertEqual(firstSamples.map(\.rootID), [rootID])
            XCTAssertEqual(secondSamples.map(\.rootID), [rootID])
            XCTAssertEqual(flushStartCount, 1)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testScopedAppliedIngressCancelledFollowerDetachesWhileLeaderCompletes() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressFollowerCancellation")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let rootID = record.id
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let leaderCompleted = AsyncSignal()
            let followerCompleted = AsyncSignal()
            let leader = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await leaderCompleted.mark()
                return samples
            }
            await flushGate.waitUntilStarted()
            let follower = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await followerCompleted.mark()
                return samples
            }
            let joined = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: rootID).joinCount == 1
            }
            XCTAssertTrue(joined)

            follower.cancel()
            let followerDetached = await waitForAsyncCondition {
                await followerCompleted.isMarked()
            }
            XCTAssertTrue(followerDetached)
            let leaderCompletedBeforeRelease = await leaderCompleted.isMarked()
            XCTAssertFalse(leaderCompletedBeforeRelease)
            let activeBeforeRelease = await store.readSearchRootDiagnosticsSnapshot()
            XCTAssertNotNil(activeBeforeRelease.first { $0.rootID == rootID }?.barrier.active)

            await flushGate.release()
            let followerSamples = await follower.value
            let leaderSamples = await leader.value
            let settled = await store.readSearchRootDiagnosticsSnapshot()
            let settledRoot = try XCTUnwrap(settled.first { $0.rootID == rootID })
            XCTAssertTrue(followerSamples.isEmpty)
            XCTAssertEqual(leaderSamples.map(\.rootID), [rootID])
            XCTAssertNil(settledRoot.barrier.active)
            XCTAssertEqual(settledRoot.barrier.completionCount, 1)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testScopedAppliedIngressCancelledLauncherDoesNotCancelLiveJoiner() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressLauncherCancellation")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let rootID = record.id
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let launcherCompleted = AsyncSignal()
            let joinerCompleted = AsyncSignal()
            let launcher = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await launcherCompleted.mark()
                return samples
            }
            await flushGate.waitUntilStarted()
            let joiner = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await joinerCompleted.mark()
                return samples
            }
            let joined = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: rootID).joinCount == 1
            }
            XCTAssertTrue(joined)

            launcher.cancel()
            let launcherDetached = await waitForAsyncCondition {
                await launcherCompleted.isMarked()
            }
            XCTAssertTrue(launcherDetached)
            let joinerCompletedBeforeRelease = await joinerCompleted.isMarked()
            XCTAssertFalse(joinerCompletedBeforeRelease)

            await flushGate.release()
            let launcherSamples = await launcher.value
            let joinerSamples = await joiner.value
            let settled = await store.readSearchRootDiagnosticsSnapshot()
            let settledRoot = try XCTUnwrap(settled.first { $0.rootID == rootID })
            XCTAssertTrue(launcherSamples.isEmpty)
            XCTAssertEqual(joinerSamples.map(\.rootID), [rootID])
            XCTAssertNil(settledRoot.barrier.active)
            XCTAssertEqual(settledRoot.barrier.completionCount, 1)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testScopedAppliedIngressCancelledPendingCallerDoesNotCancelLiveCoalescedJoiner() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressPendingCancellation")
            let addedURL = root.appendingPathComponent("Added.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let rootID = record.id
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let activeBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            await flushGate.waitUntilStarted()

            try write("added", to: addedURL)
            let acceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(absolutePath: addedURL.path, flags: createdFileFlags, eventId: 250)],
                scheduleDrain: false
            )
            let accepted = try XCTUnwrap(acceptedPayload)
            let cancelledCompleted = AsyncSignal()
            let liveCompleted = AsyncSignal()
            let cancelledPendingCaller = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await cancelledCompleted.mark()
                return samples
            }
            let pendingCreated = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: rootID).successorCount == 1
            }
            XCTAssertTrue(pendingCreated)

            let livePendingJoiner = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await liveCompleted.mark()
                return samples
            }
            let coalesced = await waitForAsyncCondition {
                let stats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
                return stats.joinCount == 1 && stats.coalescedSuccessorCount == 1
            }
            XCTAssertTrue(coalesced)

            cancelledPendingCaller.cancel()
            let cancelledDetached = await waitForAsyncCondition {
                await cancelledCompleted.isMarked()
            }
            XCTAssertTrue(cancelledDetached)
            let liveCompletedBeforeRelease = await liveCompleted.isMarked()
            XCTAssertFalse(liveCompletedBeforeRelease)
            let blockedStats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
            XCTAssertEqual(blockedStats.launchCount, 1)
            XCTAssertEqual(blockedStats.successorCount, 1)

            await flushGate.release()
            let activeSamples = await activeBarrier.value
            let cancelledSamples = await cancelledPendingCaller.value
            let liveSamples = await livePendingJoiner.value
            let liveSample = try XCTUnwrap(liveSamples.first)
            let settledStats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)

            XCTAssertEqual(activeSamples.map(\.rootID), [rootID])
            XCTAssertTrue(cancelledSamples.isEmpty)
            XCTAssertEqual(liveSample.acceptedWatcherWatermark, accepted.rawValue)
            XCTAssertGreaterThanOrEqual(liveSample.appliedWatcherWatermark, accepted.rawValue)
            XCTAssertEqual(settledStats.launchCount, 2)
            XCTAssertEqual(settledStats.successorCount, 1)
            XCTAssertEqual(settledStats.coalescedSuccessorCount, 1)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testScopedAppliedIngressAllCancelledCallersStillReachIdleCleanup() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressAllCancellation")
            let addedURL = root.appendingPathComponent("Added.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let rootID = record.id
            let baselineIngress = await store.appliedIngressSnapshotForTesting(rootID: rootID)
            let sinkGate = AsyncGate()
            let publisherWaitStarted = AsyncSignal()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }
            await store.setPublisherIngressWillWaitHandler { rootIDs in
                guard rootIDs.contains(rootID) else { return }
                await publisherWaitStarted.mark()
            }

            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded("Added.swift")]
            )
            await sinkGate.waitUntilStarted()
            let initialRoots = await store.readSearchRootDiagnosticsSnapshot()
            let initialIngress = initialRoots.first { $0.rootID == rootID }?.ingress
            XCTAssertGreaterThan(
                initialIngress?.acceptedServicePublicationSequence ?? 0,
                baselineIngress.appliedServicePublicationSequence
            )
            XCTAssertEqual(
                initialIngress?.appliedServicePublicationSequence,
                baselineIngress.appliedServicePublicationSequence
            )

            let firstCompleted = AsyncSignal()
            let secondCompleted = AsyncSignal()
            let first = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await firstCompleted.mark()
                return samples
            }
            await publisherWaitStarted.waitUntilMarked()
            let canonicalWaitRegistered = await waitForAsyncCondition {
                let roots = await store.readSearchRootDiagnosticsSnapshot()
                return roots.first { $0.rootID == rootID }?.ingress.waiterCount == 1
            }
            XCTAssertTrue(canonicalWaitRegistered)
            let second = Task {
                let samples = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                await secondCompleted.mark()
                return samples
            }
            let joined = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: rootID).joinCount == 1
            }
            XCTAssertTrue(joined)

            first.cancel()
            second.cancel()
            let bothDetached = await waitForAsyncCondition {
                let firstIsCompleted = await firstCompleted.isMarked()
                let secondIsCompleted = await secondCompleted.isMarked()
                return firstIsCompleted && secondIsCompleted
            }
            XCTAssertTrue(bothDetached)
            let firstSamples = await first.value
            let secondSamples = await second.value
            XCTAssertTrue(firstSamples.isEmpty)
            XCTAssertTrue(secondSamples.isEmpty)
            let activeBeforeRelease = await store.readSearchRootDiagnosticsSnapshot()
            let activeRoot = activeBeforeRelease.first { $0.rootID == rootID }
            XCTAssertNotNil(activeRoot?.barrier.active)
            XCTAssertEqual(activeRoot?.barrier.completionCount, 0)
            XCTAssertEqual(activeRoot?.ingress.waiterCount, 1)
            XCTAssertGreaterThan(activeRoot?.ingress.outstandingPublicationCount ?? 0, 0)
            XCTAssertEqual(
                activeRoot?.ingress.appliedServicePublicationSequence,
                baselineIngress.appliedServicePublicationSequence
            )

            await sinkGate.release()
            let reachedIdle = await waitForAsyncCondition {
                let roots = await store.readSearchRootDiagnosticsSnapshot()
                guard let root = roots.first(where: { $0.rootID == rootID }) else { return false }
                return root.barrier.active == nil
                    && root.barrier.completionCount == 1
                    && root.ingress.waiterCount == 0
                    && root.ingress.outstandingPublicationCount == 0
            }
            XCTAssertTrue(reachedIdle)
            let settledRoots = await store.readSearchRootDiagnosticsSnapshot()
            let settledRoot = try XCTUnwrap(settledRoots.first { $0.rootID == rootID })
            XCTAssertEqual(
                settledRoot.ingress.appliedServicePublicationSequence,
                settledRoot.ingress.acceptedServicePublicationSequence
            )
            XCTAssertGreaterThanOrEqual(
                settledRoot.ingress.appliedServicePublicationSequence,
                initialIngress?.acceptedServicePublicationSequence ?? 0
            )
            XCTAssertGreaterThanOrEqual(
                settledRoot.ingress.appliedWatcherWatermark,
                baselineIngress.appliedWatcherWatermark.rawValue
            )
            XCTAssertEqual(
                settledRoot.barrier.lastCompleted?.appliedWatcherWatermark,
                settledRoot.ingress.appliedWatcherWatermark
            )
            XCTAssertEqual(
                settledRoot.barrier.lastCompleted?.appliedServicePublicationSequence,
                settledRoot.ingress.appliedServicePublicationSequence
            )
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.setPublisherIngressWillWaitHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

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

        func testCancelledFileSearchJoinThrowsBeforeCanonicalFlightCompletes() async throws {
            let root = try makeTemporaryRoot(name: "SearchFreshnessCancellation")
            try write("needle", to: root.appendingPathComponent("Seed.swift"))
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
                    _ = try await StoreBackedWorkspaceSearch.search(
                        pattern: "needle",
                        mode: .content,
                        store: store,
                        workspaceManager: nil
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

        func testScopedAppliedIngressCoalescesNewerSameRootTargetsIntoOnePendingSuccessor() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressSuccessor")
            let firstAddedURL = root.appendingPathComponent("FirstAdded.swift")
            let secondAddedURL = root.appendingPathComponent("SecondAdded.swift")
            let clock = LockedWorkspaceDiagnosticsClock(nowNanoseconds: 4_000_000_000)
            let store = WorkspaceFileContextStore(debugNowNanoseconds: { clock.now() })
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let rootID = record.id
            let baselineWatcherWatermark = try await store.acceptedWatcherWatermarkForTesting(rootID: rootID)
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == rootID else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let firstBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            await flushGate.waitUntilStarted()

            try write("first", to: firstAddedURL)
            let firstAcceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(absolutePath: firstAddedURL.path, flags: createdFileFlags, eventId: 300)],
                scheduleDrain: false
            )
            let firstAccepted = try XCTUnwrap(firstAcceptedPayload)
            let secondBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            let pendingSuccessorCreated = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: rootID).successorCount == 1
            }
            XCTAssertTrue(pendingSuccessorCreated)

            try write("second", to: secondAddedURL)
            let secondAcceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(absolutePath: secondAddedURL.path, flags: createdFileFlags, eventId: 301)],
                scheduleDrain: false
            )
            let secondAccepted = try XCTUnwrap(secondAcceptedPayload)
            XCTAssertGreaterThan(secondAccepted.rawValue, firstAccepted.rawValue)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileModified("FirstAdded.swift", nil)]
            )
            let acceptedServicePublicationSequence = await store.appliedIngressSnapshotForTesting(rootID: rootID)
                .acceptedServicePublicationSequence
            XCTAssertGreaterThan(acceptedServicePublicationSequence, 0)
            let thirdBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }

            for _ in 0 ..< 1000 {
                let stats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
                if await flushGate.startCount() >= 3 || stats.coalescedSuccessorCount == 1 { break }
                await Task.yield()
            }
            clock.advance(milliseconds: 175)
            let statsWhileBlocked = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
            let flightCountWhileBlocked = await store.scopedIngressBarrierFlightCountForTesting()
            let flushStartCountWhileBlocked = await flushGate.startCount()
            let blockedRoots = await store.readSearchRootDiagnosticsSnapshot()
            let blockedRoot = try XCTUnwrap(blockedRoots.first { $0.rootID == rootID })
            let active = try XCTUnwrap(blockedRoot.barrier.active)
            let pending = try XCTUnwrap(blockedRoot.barrier.pending)

            XCTAssertEqual(statsWhileBlocked.launchCount, 1)
            XCTAssertEqual(statsWhileBlocked.joinCount, 1)
            XCTAssertEqual(statsWhileBlocked.successorCount, 1)
            XCTAssertEqual(statsWhileBlocked.coalescedSuccessorCount, 1)
            XCTAssertEqual(flightCountWhileBlocked, 2)
            XCTAssertEqual(flushStartCountWhileBlocked, 1)
            XCTAssertEqual(active.targetWatcherWatermark, baselineWatcherWatermark.rawValue)
            XCTAssertEqual(pending.targetWatcherWatermark, secondAccepted.rawValue)
            XCTAssertEqual(pending.targetServicePublicationSequence, acceptedServicePublicationSequence)
            XCTAssertEqual(pending.ageMilliseconds, 175)

            await flushGate.release()
            let firstSamples = await firstBarrier.value
            let secondSamples = await secondBarrier.value
            let thirdSamples = await thirdBarrier.value
            let settledStats = await store.scopedIngressBarrierStatsForTesting(rootID: rootID)
            let settledFlushStartCount = await flushGate.startCount()
            let secondSample = try XCTUnwrap(secondSamples.first)
            let thirdSample = try XCTUnwrap(thirdSamples.first)

            XCTAssertEqual(settledStats.launchCount, 2)
            XCTAssertEqual(settledStats.joinCount, 1)
            XCTAssertEqual(settledStats.successorCount, 1)
            XCTAssertEqual(settledStats.coalescedSuccessorCount, 1)
            XCTAssertEqual(settledFlushStartCount, 2)
            XCTAssertEqual(
                firstSamples.first?.acceptedWatcherWatermark,
                baselineWatcherWatermark.rawValue
            )
            XCTAssertEqual(secondSample.acceptedWatcherWatermark, secondAccepted.rawValue)
            XCTAssertEqual(thirdSample.acceptedWatcherWatermark, secondAccepted.rawValue)
            XCTAssertGreaterThanOrEqual(secondSample.appliedWatcherWatermark, secondAccepted.rawValue)
            XCTAssertGreaterThanOrEqual(thirdSample.appliedWatcherWatermark, secondAccepted.rawValue)
            XCTAssertGreaterThanOrEqual(
                secondSample.appliedServicePublicationSequence,
                acceptedServicePublicationSequence
            )
            XCTAssertGreaterThanOrEqual(
                thirdSample.appliedServicePublicationSequence,
                acceptedServicePublicationSequence
            )
            await store.setScopedIngressBarrierWillFlushHandler(nil)
            await store.stopWatchingRoot(id: rootID)
        }

        func testScopedAppliedIngressDifferentRootsFlushConcurrently() async throws {
            let rootA = try makeTemporaryRoot(name: "ScopedIngressConcurrentA")
            let rootB = try makeTemporaryRoot(name: "ScopedIngressConcurrentB")
            let store = WorkspaceFileContextStore()
            let recordA = try await store.loadRoot(path: rootA.path)
            let recordB = try await store.loadRoot(path: rootB.path)
            let gateA = AsyncGate()
            let gateB = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                if observedRootID == recordA.id {
                    await gateA.markStartedAndWaitForRelease()
                } else if observedRootID == recordB.id {
                    await gateB.markStartedAndWaitForRelease()
                }
            }

            let barrier = Task {
                await store.awaitAppliedIngressForAllRoots()
            }
            await gateA.waitUntilStarted()
            await gateB.waitUntilStarted()
            await gateA.release()
            await gateB.release()

            let samples = await barrier.value
            let statsA = await store.scopedIngressBarrierStatsForTesting(rootID: recordA.id)
            let statsB = await store.scopedIngressBarrierStatsForTesting(rootID: recordB.id)
            XCTAssertEqual(Set(samples.map(\.rootID)), Set([recordA.id, recordB.id]))
            XCTAssertEqual(statsA.launchCount, 1)
            XCTAssertEqual(statsB.launchCount, 1)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testAggressiveAppliedIngressLimitsConcurrentRootFlushFanOut() async throws {
            let store = WorkspaceFileContextStore()
            var records: [WorkspaceRootRecord] = []
            for index in 0 ..< 9 {
                let root = try makeTemporaryRoot(name: "ScopedIngressFanOut\(index)")
                try await records.append(store.loadRoot(path: root.path))
            }
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { _ in
                await flushGate.markStartedAndWaitForRelease()
            }

            let barrier = Task {
                await store.awaitAppliedIngressForAllRoots()
            }
            for _ in 0 ..< 1000 {
                if await flushGate.startCount() >= 8 { break }
                await Task.yield()
            }
            for _ in 0 ..< 50 {
                await Task.yield()
            }
            let startsBeforeRelease = await flushGate.startCount()
            XCTAssertEqual(startsBeforeRelease, 8)

            await flushGate.release()
            let samples = await barrier.value
            let startsAfterRelease = await flushGate.startCount()
            XCTAssertEqual(Set(samples.map(\.rootID)), Set(records.map(\.id)))
            XCTAssertEqual(startsAfterRelease, 9)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testExplicitAbsoluteFreshnessBarrierTargetsOnlyContainingRoot() async throws {
            let rootA = try makeTemporaryRoot(name: "ExplicitFreshnessA")
            let rootB = try makeTemporaryRoot(name: "ExplicitFreshnessB")
            let fileA = rootA.appendingPathComponent("A.swift")
            try write("a", to: fileA)
            let store = WorkspaceFileContextStore()
            let recordA = try await store.loadRoot(path: rootA.path)
            let recordB = try await store.loadRoot(path: rootB.path)

            let samples = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileA.path,
                fallbackScope: .allLoaded
            )
            let statsA = await store.scopedIngressBarrierStatsForTesting(rootID: recordA.id)
            let statsBBeforeExternalRequest = await store.scopedIngressBarrierStatsForTesting(rootID: recordB.id)
            XCTAssertEqual(samples.map(\.rootID), [recordA.id])
            XCTAssertEqual(statsA.launchCount, 1)
            XCTAssertEqual(statsBBeforeExternalRequest.launchCount, 0)

            let rootPathSamples = await store.awaitAppliedIngressForExplicitRequest(
                userPath: recordA.standardizedFullPath,
                fallbackScope: .allLoaded
            )
            let statsAAfterRootPathRequest = await store.scopedIngressBarrierStatsForTesting(rootID: recordA.id)
            XCTAssertEqual(rootPathSamples.map(\.rootID), [recordA.id])
            XCTAssertEqual(statsAAfterRootPathRequest.launchCount, 1)
            XCTAssertEqual(statsAAfterRootPathRequest.noopCount, 1)

            let externalSamples = await store.awaitAppliedIngressForExplicitRequest(
                userPath: "/tmp/outside-repoprompt-workspace.swift",
                fallbackScope: .allLoaded
            )
            let statsBAfterExternalRequest = await store.scopedIngressBarrierStatsForTesting(rootID: recordB.id)
            XCTAssertTrue(externalSamples.isEmpty)
            XCTAssertEqual(statsBAfterExternalRequest.launchCount, 0)
        }

        func testCompletedCutNoopFastPathDoesNotHideImmediatelyAcceptedCallback() async throws {
            let root = try makeTemporaryRoot(name: "CompletedCutNoopFreshness")
            let seedURL = root.appendingPathComponent("Seed.swift")
            let addedURL = root.appendingPathComponent("Added.swift")
            try write("seed", to: seedURL)
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let initial = await store.awaitAppliedIngressForExplicitRequest(
                userPath: seedURL.path,
                fallbackScope: .allLoaded
            )
            let steady = await store.awaitAppliedIngressForExplicitRequest(
                userPath: seedURL.path,
                fallbackScope: .allLoaded
            )
            let steadyStats = await store.scopedIngressBarrierStatsForTesting(rootID: record.id)
            XCTAssertEqual(initial.map(\.rootID), [record.id])
            XCTAssertEqual(steady.map(\.rootID), [record.id])
            XCTAssertEqual(steadyStats.launchCount, 1)
            XCTAssertEqual(steadyStats.noopCount, 1)

            try write("added", to: addedURL)
            let accepted = try await store.acceptWatcherPayloadForTesting(
                rootID: record.id,
                events: [(absolutePath: addedURL.path, flags: createdFileFlags, eventId: 450)],
                scheduleDrain: false
            )
            let acceptedWatermark = try XCTUnwrap(accepted)
            let afterCallback = await store.awaitAppliedIngressForExplicitRequest(
                userPath: seedURL.path,
                fallbackScope: .allLoaded
            )
            let sample = try XCTUnwrap(afterCallback.first)
            let settledStats = await store.scopedIngressBarrierStatsForTesting(rootID: record.id)

            XCTAssertEqual(sample.acceptedWatcherWatermark, acceptedWatermark.rawValue)
            XCTAssertGreaterThanOrEqual(sample.appliedWatcherWatermark, acceptedWatermark.rawValue)
            XCTAssertEqual(settledStats.launchCount, 2)
            XCTAssertEqual(settledStats.noopCount, 1)
            await store.stopWatchingRoot(id: record.id)
        }

        func testExplicitAggressiveFreshnessBarrierStillFlushesAllLoadedRoots() async throws {
            let rootA = try makeTemporaryRoot(name: "AggressiveFreshnessA")
            let rootB = try makeTemporaryRoot(name: "AggressiveFreshnessB")
            let store = WorkspaceFileContextStore()
            let recordA = try await store.loadRoot(path: rootA.path)
            let recordB = try await store.loadRoot(path: rootB.path)

            let samples = await store.awaitAppliedIngressForAllRoots()
            let statsA = await store.scopedIngressBarrierStatsForTesting(rootID: recordA.id)
            let statsB = await store.scopedIngressBarrierStatsForTesting(rootID: recordB.id)
            XCTAssertEqual(Set(samples.map(\.rootID)), Set([recordA.id, recordB.id]))
            XCTAssertEqual(statsA.launchCount, 1)
            XCTAssertEqual(statsB.launchCount, 1)
        }

        func testScopedIngressBarrierDiagnosticsReportActiveTargetAndCompletedTiming() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressDiagnostics")
            let clock = LockedWorkspaceDiagnosticsClock(nowNanoseconds: 3_000_000_000)
            let store = WorkspaceFileContextStore(debugNowNanoseconds: { clock.now() })
            let record = try await store.loadRoot(path: root.path)
            let flushGate = AsyncGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await flushGate.markStartedAndWaitForRelease()
            }

            let barrierTask = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            await flushGate.waitUntilStarted()
            clock.advance(milliseconds: 325)

            let activeRoots = await store.readSearchRootDiagnosticsSnapshot()
            let activeRoot = try XCTUnwrap(activeRoots.first { $0.rootID == record.id })
            let active = try XCTUnwrap(activeRoot.barrier.active)
            XCTAssertEqual(active.targetWatcherWatermark, 0)
            XCTAssertEqual(active.targetServicePublicationSequence, 0)
            XCTAssertEqual(active.ageMilliseconds, 325)
            XCTAssertEqual(activeRoot.barrier.launchCount, 1)
            XCTAssertEqual(activeRoot.barrier.coalescedSuccessorCount, 0)
            XCTAssertEqual(activeRoot.barrier.completionCount, 0)
            XCTAssertNil(activeRoot.barrier.pending)
            XCTAssertNil(activeRoot.barrier.lastCompleted)

            await flushGate.release()
            let samples = await barrierTask.value
            XCTAssertEqual(samples.map(\.rootID), [record.id])

            let completedRoots = await store.readSearchRootDiagnosticsSnapshot()
            let completedRoot = try XCTUnwrap(completedRoots.first { $0.rootID == record.id })
            let completed = try XCTUnwrap(completedRoot.barrier.lastCompleted)
            XCTAssertNil(completedRoot.barrier.active)
            XCTAssertNil(completedRoot.barrier.pending)
            XCTAssertEqual(completedRoot.barrier.completionCount, 1)
            XCTAssertEqual(completed.targetWatcherWatermark, 0)
            XCTAssertEqual(completed.targetServicePublicationSequence, 0)
            XCTAssertEqual(completed.appliedServicePublicationSequence, samples[0].appliedServicePublicationSequence)
            XCTAssertEqual(completed.appliedWatcherWatermark, samples[0].appliedWatcherWatermark)
            XCTAssertEqual(completed.durationMilliseconds, 325)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testRootUnloadCancelsActiveAndPendingScopedIngressFlightsAndReleasesDetachedService() async throws {
            let root = try makeTemporaryRoot(name: "ScopedIngressUnloadRelease")
            let addedURL = root.appendingPathComponent("Pending.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            var service: FileSystemService? = await store.fileSystemServiceForTesting(rootID: record.id)
            let weakService = WeakObjectBox(service)
            let cancellationGate = CancellationAwareGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await cancellationGate.markStartedAndWaitForCancellation()
            }

            let activeBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            await cancellationGate.waitUntilStarted()

            try write("pending", to: addedURL)
            let acceptedPayload = try await store.acceptWatcherPayloadForTesting(
                rootID: record.id,
                events: [(absolutePath: addedURL.path, flags: createdFileFlags, eventId: 400)],
                scheduleDrain: false
            )
            XCTAssertNotNil(acceptedPayload)
            let pendingBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            let pendingCreated = await waitForAsyncCondition {
                await store.scopedIngressBarrierStatsForTesting(rootID: record.id).successorCount == 1
            }
            XCTAssertTrue(pendingCreated)
            let ownedFlightCount = await store.scopedIngressBarrierFlightCountForTesting()
            XCTAssertEqual(ownedFlightCount, 2)

            await store.unloadRoot(id: record.id)
            service = nil
            let activeSamples = await activeBarrier.value
            let pendingSamples = await pendingBarrier.value
            let roots = await store.roots()
            let retainedRootIDs = await store.retainedReadSearchDiagnosticRootIDsForTesting()
            let remainingFlightCount = await store.scopedIngressBarrierFlightCountForTesting()
            let serviceReleased = await waitForAsyncCondition(maxYields: 10000) {
                weakService.value == nil
            }

            XCTAssertTrue(activeSamples.isEmpty)
            XCTAssertTrue(pendingSamples.isEmpty)
            XCTAssertTrue(roots.isEmpty)
            XCTAssertEqual(remainingFlightCount, 0)
            XCTAssertFalse(retainedRootIDs.contains(record.id))
            XCTAssertTrue(serviceReleased)
            await store.setScopedIngressBarrierWillFlushHandler(nil)
        }

        func testLargePublicationUsesOneSelectiveInvalidationCycleAndPreservesFinalCatalog() async throws {
            let root = try makeTemporaryRoot(name: "PublicationInvalidationBatch")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let fileCount = 600
            let relativePaths = (0 ..< fileCount).map { String(format: "Batch-%03d.swift", $0) }
            for relativePath in relativePaths {
                try write(relativePath, to: root.appendingPathComponent(relativePath))
            }
            var appliedIndexEvents = await store.appliedIndexEvents().makeAsyncIterator()
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

            let sample = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
                rootID: record.id,
                deltas: relativePaths.map { .fileAdded($0) }
            )

            XCTAssertEqual(sample.servicePublicationSequence, 0)
            XCTAssertNil(sample.watcherAcceptedWatermark)
            XCTAssertEqual(sample.preparedDeltaCount, fileCount)
            XCTAssertEqual(sample.topologyInvalidationCount, 1)
            XCTAssertEqual(sample.catalogGenerationAdvanceCount, 3)
            XCTAssertEqual(sample.searchCatalogCacheClearCount, 1)
            XCTAssertEqual(sample.pathWorkerInvalidationRequestCount, 0)
            XCTAssertEqual(sample.contentInvalidationCount, 0)
            XCTAssertEqual(sample.distinctContentKeyCount, 0)
            XCTAssertEqual(sample.decodedCacheInvalidationRequestCount, 0)
            XCTAssertEqual(sample.codemapInvalidationRequestCount, 0)
            guard sample.appliedIndexEventYieldCount == 1 else {
                XCTFail("Expected exactly one applied-index event, got \(sample.appliedIndexEventYieldCount)")
                return
            }

            let appliedIndexEvent = await appliedIndexEvents.next()
            let observedAppliedIndexEvent = try XCTUnwrap(appliedIndexEvent)
            XCTAssertEqual(observedAppliedIndexEvent.rootID, record.id)
            XCTAssertEqual(observedAppliedIndexEvent.generation, 1)
            XCTAssertEqual(observedAppliedIndexEvent.upsertedFiles.map(\.standardizedRelativePath), relativePaths)
            XCTAssertTrue(observedAppliedIndexEvent.upsertedFolders.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.removedFileIDs.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.removedFolderIDs.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.removedFilePaths.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.removedFolderPaths.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.modifiedFileIDs.isEmpty)
            XCTAssertTrue(observedAppliedIndexEvent.modifiedFolderIDs.isEmpty)

            let rootSnapshots = await store.readSearchRootDiagnosticsSnapshot()
            let rootSnapshot = try XCTUnwrap(rootSnapshots.first { $0.rootID == record.id })
            XCTAssertEqual(rootSnapshot.invalidation.totalObservedPublicationCount, 0)
            XCTAssertTrue(rootSnapshot.invalidation.samples.isEmpty)

            let work = await store.storeWorkDiagnosticsSnapshot()
            let invalidation = try XCTUnwrap(work.invalidations.last)
            XCTAssertEqual(invalidation.reasons, ["file_system_publication"])
            XCTAssertEqual(invalidation.affectedRootIDs, [record.id])
            XCTAssertEqual(invalidation.affectedRootKinds, ["primary_workspace"])
            XCTAssertEqual(invalidation.evictedScopes, ["visible_workspace"])

            let catalog = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(catalog.files.map(\.standardizedRelativePath), relativePaths)
        }

        func testLargeModificationPublicationUsesOneDecodedCacheInvalidationAndPreservesFreshContent() async throws {
            let root = try makeTemporaryRoot(name: "PublicationContentInvalidationBatch")
            let fileCount = 64
            let relativePaths = (0 ..< fileCount).map { String(format: "Content-%03d.swift", $0) }
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            for (index, relativePath) in relativePaths.enumerated() {
                let fileURL = root.appendingPathComponent(relativePath)
                try write(String(format: "old-%03d", index), to: fileURL)
                try setDiskModificationDate(fixedDate, for: fileURL)
            }

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            var files: [WorkspaceFileRecord] = []
            var initialRevisionsByFileID: [UUID: UInt64] = [:]
            for (index, relativePath) in relativePaths.enumerated() {
                let loadedFile = await store.file(rootID: record.id, relativePath: relativePath)
                let file = try XCTUnwrap(loadedFile)
                let snapshot = try await store.searchContentSnapshot(for: file)
                XCTAssertEqual(snapshot.content, String(format: "old-%03d", index))
                files.append(file)
                initialRevisionsByFileID[file.id] = try XCTUnwrap(snapshot.contentRevision)
            }
            try await store.startWatchingRoot(id: record.id)

            for (index, relativePath) in relativePaths.enumerated() {
                let fileURL = root.appendingPathComponent(relativePath)
                try write(String(format: "new-%03d", index), to: fileURL)
                try setDiskModificationDate(fixedDate, for: fileURL)
            }
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: record.id,
                deltas: relativePaths.map { .fileModified($0, fixedDate) }
            )
            _ = await store.awaitAppliedIngressForAllRoots()

            let rootSnapshots = await store.readSearchRootDiagnosticsSnapshot(recentPublicationLimit: 32)
            let rootSnapshot = try XCTUnwrap(rootSnapshots.first { $0.rootID == record.id })
            let sample = try XCTUnwrap(rootSnapshot.invalidation.samples.last {
                $0.preparedDeltaCount == fileCount && $0.contentInvalidationCount == fileCount
            })
            XCTAssertEqual(sample.topologyInvalidationCount, 0)
            XCTAssertEqual(sample.catalogGenerationAdvanceCount, 0)
            XCTAssertEqual(sample.searchCatalogCacheClearCount, 0)
            XCTAssertEqual(sample.pathWorkerInvalidationRequestCount, 0)
            XCTAssertEqual(sample.distinctContentKeyCount, fileCount)
            XCTAssertEqual(sample.decodedCacheInvalidationRequestCount, 1)
            XCTAssertEqual(sample.codemapInvalidationRequestCount, fileCount)
            XCTAssertEqual(sample.appliedIndexEventYieldCount, 1)

            for (index, file) in files.enumerated() {
                let refreshed = try await store.searchContentSnapshot(for: file)
                XCTAssertTrue(refreshed.isFresh)
                XCTAssertEqual(refreshed.content, String(format: "new-%03d", index))
                let refreshedRevision = try XCTUnwrap(refreshed.contentRevision)
                XCTAssertGreaterThan(refreshedRevision, try XCTUnwrap(initialRevisionsByFileID[file.id]))
            }
        }

        func testPublicationInvalidationDiagnosticsRetainOnlyLatestThirtyTwoSamples() async throws {
            let root = try makeTemporaryRoot(name: "PublicationInvalidationRetention")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            // Keep publisher ingress attached for synthetic publications while excluding live
            // FSEvents from the measurement window.
            let loadedFileSystemService = await store.fileSystemServiceForTesting(rootID: record.id)
            let fileSystemService = try XCTUnwrap(loadedFileSystemService)
            await fileSystemService.stopWatchingForChanges()
            _ = await store.awaitAppliedIngressForAllRoots()
            let baselineSnapshots = await store.readSearchRootDiagnosticsSnapshot(recentPublicationLimit: 32)
            let baselineSnapshot = try XCTUnwrap(baselineSnapshots.first { $0.rootID == record.id })
            let publicationCount = 40

            for _ in 0 ..< publicationCount {
                try await store.publishSyntheticFileSystemDeltasForTesting(
                    rootID: record.id,
                    deltas: [.fileModified("Seed.swift", nil)]
                )
                _ = await store.awaitAppliedIngressForAllRoots()
            }

            let rootSnapshots = await store.readSearchRootDiagnosticsSnapshot(recentPublicationLimit: 32)
            let rootSnapshot = try XCTUnwrap(rootSnapshots.first { $0.rootID == record.id })
            let invalidation = rootSnapshot.invalidation
            XCTAssertEqual(invalidation.retainedSampleLimit, 32)
            XCTAssertEqual(
                invalidation.totalObservedPublicationCount,
                baselineSnapshot.invalidation.totalObservedPublicationCount + publicationCount
            )
            XCTAssertEqual(
                invalidation.droppedPublicationSampleCount,
                invalidation.totalObservedPublicationCount - invalidation.samples.count
            )
            XCTAssertEqual(invalidation.samples.count, 32)
            XCTAssertTrue(invalidation.samples.allSatisfy {
                $0.watcherAcceptedWatermark == nil && $0.preparedDeltaCount == 1
            })
            let retainedSequences = invalidation.samples.map(\.servicePublicationSequence)
            XCTAssertTrue(retainedSequences.allSatisfy { $0 > 0 })
            XCTAssertTrue(zip(retainedSequences, retainedSequences.dropFirst()).allSatisfy { pair in
                pair.0 < pair.1
            })

            await store.stopWatchingRoot(id: record.id)
        }

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
            let work = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(work.catalogRebuild.rebuildCount, 1)
            XCTAssertEqual(work.catalogRebuild.lastFileCount, 3)
            XCTAssertEqual(work.catalogRebuild.lastRootCount, 2)
            XCTAssertGreaterThanOrEqual(work.catalogRebuild.totalMicroseconds, work.catalogRebuild.filterMicroseconds)
            XCTAssertGreaterThanOrEqual(work.catalogRebuild.totalMicroseconds, work.catalogRebuild.sortMicroseconds)
            XCTAssertGreaterThanOrEqual(
                work.catalogRebuild.totalMicroseconds,
                work.catalogRebuild.materializationMicroseconds
            )
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

    func testDisplayRootRefsSnapshotMatchesExistingScopesPreservesLoadOrderAndRemainsStable() async throws {
        let visibleRootA = try makeTemporaryRoot(name: "DisplayRootSnapshotVisibleA")
        let supplementalRoot = try makeTemporaryRoot(name: "DisplayRootSnapshotSupplemental")
        let visibleRootB = try makeTemporaryRoot(name: "DisplayRootSnapshotVisibleB")
        let laterVisibleRoot = try makeTemporaryRoot(name: "DisplayRootSnapshotVisibleLater")

        let store = WorkspaceFileContextStore()
        let visibleA = try await store.loadRoot(path: visibleRootA.path)
        let supplemental = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)
        let visibleB = try await store.loadRoot(path: visibleRootB.path)

        let retainedSnapshot = await store.displayRootRefsSnapshot()
        let existingVisibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        let existingAllRoots = await store.rootRefs(scope: .allLoaded)
        XCTAssertEqual(retainedSnapshot.visibleRoots, existingVisibleRoots)
        XCTAssertEqual(retainedSnapshot.allRoots, existingAllRoots)
        XCTAssertEqual(retainedSnapshot.visibleRoots.map(\.id), [visibleA.id, visibleB.id])
        XCTAssertEqual(retainedSnapshot.allRoots.map(\.id), [visibleA.id, supplemental.id, visibleB.id])
        XCTAssertTrue(Set(retainedSnapshot.visibleRoots).isSubset(of: Set(retainedSnapshot.allRoots)))

        let laterVisible = try await store.loadRoot(path: laterVisibleRoot.path)
        let freshSnapshot = await store.displayRootRefsSnapshot()
        XCTAssertEqual(retainedSnapshot.visibleRoots.map(\.id), [visibleA.id, visibleB.id])
        XCTAssertEqual(retainedSnapshot.allRoots.map(\.id), [visibleA.id, supplemental.id, visibleB.id])
        XCTAssertEqual(freshSnapshot.visibleRoots.map(\.id), [visibleA.id, visibleB.id, laterVisible.id])
        XCTAssertEqual(freshSnapshot.allRoots.map(\.id), [visibleA.id, supplemental.id, visibleB.id, laterVisible.id])
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
        let scopeA = WorkspaceLookupRootScope.sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: [worktreeA.path])
        let scopeB = WorkspaceLookupRootScope.sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: [worktreeB.path])

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
        XCTAssertNotEqual(changedA.generation, initialA.generation)
        XCTAssertEqual(Set(changedA.files.map(\.standardizedRelativePath)), ["A.swift", "Added.swift"])
        XCTAssertEqual(unchangedB.files.map(\.standardizedRelativePath), ["B.swift"])
    }

    #if DEBUG
        func testSearchCatalogSnapshotCacheSelectivelyRetainsUnaffectedScopes() async throws {
            let visibleRoot = try makeTemporaryRoot(name: "SelectiveSnapshotVisible")
            let gitDataRoot = try makeTemporaryRoot(name: "SelectiveSnapshotGitData")
            let supplementalRoot = try makeTemporaryRoot(name: "SelectiveSnapshotSupplemental")
            let worktreeA = try makeTemporaryRoot(name: "SelectiveSnapshotWorktreeA")
            let worktreeB = try makeTemporaryRoot(name: "SelectiveSnapshotWorktreeB")
            try write("visible", to: visibleRoot.appendingPathComponent("Visible.swift"))
            try write("git", to: gitDataRoot.appendingPathComponent("Git.swift"))
            try write("system", to: supplementalRoot.appendingPathComponent("System.swift"))
            try write("a", to: worktreeA.appendingPathComponent("A.swift"))
            try write("b", to: worktreeB.appendingPathComponent("B.swift"))

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: visibleRoot.path)
            _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
            _ = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)
            let recordA = try await store.loadRoot(path: worktreeA.path, kind: .sessionWorktree)
            _ = try await store.loadRoot(path: worktreeB.path, kind: .sessionWorktree)
            let scopeA = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktreeA.path]
            )
            let scopeB = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktreeB.path]
            )
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let initialA = await store.searchCatalogSnapshot(rootScope: scopeA)
            let initialB = await store.searchCatalogSnapshot(rootScope: scopeB)

            try write("added", to: worktreeA.appendingPathComponent("Added.swift"))
            startSearchCatalogSnapshotCapture(label: "selective-snapshot-retention")
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            await store.replayObservedFileSystemDeltas(rootID: recordA.id, deltas: [.fileAdded("Added.swift")])

            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let changedA = await store.searchCatalogSnapshot(rootScope: scopeA)
            let unchangedB = await store.searchCatalogSnapshot(rootScope: scopeB)

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let buckets = searchCatalogSnapshotBuckets(capture)
            let missCount = buckets
                .filter { $0.sanitizedDimensions.contains("cacheHit=false") }
                .reduce(0) { $0 + $1.sampleCount }
            let hitCount = buckets
                .filter { $0.sanitizedDimensions.contains("cacheHit=true") }
                .reduce(0) { $0 + $1.sampleCount }
            XCTAssertEqual(missCount, 2)
            XCTAssertEqual(hitCount, 3)
            XCTAssertNotEqual(changedA.generation, initialA.generation)
            XCTAssertEqual(Set(changedA.files.map(\.standardizedRelativePath)), ["A.swift", "Added.swift"])
            XCTAssertEqual(unchangedB, initialB)

            let work = await store.storeWorkDiagnosticsSnapshot()
            let invalidation = try XCTUnwrap(work.invalidations.last)
            XCTAssertEqual(invalidation.reasons, ["file_system_publication"])
            XCTAssertEqual(invalidation.affectedRootIDs, [recordA.id])
            XCTAssertEqual(invalidation.affectedRootKinds, ["session_worktree"])
            XCTAssertEqual(invalidation.evictedScopes.count, 2)
            XCTAssertTrue(invalidation.evictedScopes.contains("all_loaded"))
            XCTAssertTrue(invalidation.evictedScopes.contains { $0.contains(worktreeA.path) })
            XCTAssertFalse(invalidation.evictedScopes.contains { $0.contains(worktreeB.path) })
        }

        func testGitDataPublicationRetainsWarmVisibleWorkspaceCatalog() async throws {
            let visibleRoot = try makeTemporaryRoot(name: "GitDataRetentionVisible")
            let gitDataRoot = try makeTemporaryRoot(name: "GitDataRetentionArtifact")
            try write("visible", to: visibleRoot.appendingPathComponent("Visible.swift"))
            try write("map", to: gitDataRoot.appendingPathComponent("MAP.txt"))

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: visibleRoot.path)
            let gitData = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
            let visible = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)

            try write("patch", to: gitDataRoot.appendingPathComponent("all.patch"))
            startSearchCatalogSnapshotCapture(label: "git-data-snapshot-retention")
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            await store.replayObservedFileSystemDeltas(rootID: gitData.id, deltas: [.fileAdded("all.patch")])

            let retainedVisible = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let rebuiltGitData = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let buckets = searchCatalogSnapshotBuckets(capture)
            let missCount = buckets
                .filter { $0.sanitizedDimensions.contains("cacheHit=false") }
                .reduce(0) { $0 + $1.sampleCount }
            let hitCount = buckets
                .filter { $0.sanitizedDimensions.contains("cacheHit=true") }
                .reduce(0) { $0 + $1.sampleCount }
            XCTAssertEqual(missCount, 2)
            XCTAssertEqual(hitCount, 1)
            XCTAssertEqual(retainedVisible, visible)
            XCTAssertTrue(rebuiltGitData.files.contains { $0.standardizedRelativePath == "all.patch" })

            let work = await store.storeWorkDiagnosticsSnapshot()
            let invalidation = try XCTUnwrap(work.invalidations.last)
            XCTAssertEqual(invalidation.evictedScopes, ["all_loaded", "visible_workspace_plus_git_data"])
        }

        func testSessionCatalogDependencyTokenChangesAcrossUnloadAndReload() async throws {
            let logicalRoot = try makeTemporaryRoot(name: "SessionDependencyLogical")
            let worktree = try makeTemporaryRoot(name: "SessionDependencyWorktree")
            try write("logical", to: logicalRoot.appendingPathComponent("Logical.swift"))
            try write("worktree", to: worktree.appendingPathComponent("Worktree.swift"))

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: logicalRoot.path)
            let initialRecord = try await store.loadRoot(path: worktree.path, kind: .sessionWorktree)
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktree.path]
            )
            let initial = await store.searchCatalogSnapshot(rootScope: scope)

            await store.unloadRoot(id: initialRecord.id)
            let unloaded = await store.searchCatalogSnapshot(rootScope: scope)
            let replacement = try await store.loadRoot(path: worktree.path, kind: .sessionWorktree)
            let reloaded = await store.searchCatalogSnapshot(rootScope: scope)

            XCTAssertEqual(initial.roots.map(\.id), [initialRecord.id])
            XCTAssertTrue(unloaded.roots.isEmpty)
            XCTAssertEqual(reloaded.roots.map(\.id), [replacement.id])
            XCTAssertNotEqual(initialRecord.id, replacement.id)
            XCTAssertNotEqual(initial.generation, unloaded.generation)
            XCTAssertNotEqual(unloaded.generation, reloaded.generation)
        }

        func testSearchCatalogSnapshotCacheEvictsOnlyLeastRecentlyUsedEntryAtCapacity() async {
            let store = WorkspaceFileContextStore()
            let scopes = (0 ... 16).map { index in
                WorkspaceLookupRootScope.sessionBoundWorkspace(
                    canonicalRootPaths: ["/canonical/\(index)"],
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
            _ = await store.searchCatalogSnapshot(rootScope: scopes[1])

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let buckets = searchCatalogSnapshotBuckets(capture)
            let missCount = buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=false") })?.sampleCount
            let hitCount = buckets.first(where: { $0.sanitizedDimensions.contains("cacheHit=true") })?.sampleCount
            XCTAssertEqual(missCount, 18)
            XCTAssertEqual(hitCount, 2)
            XCTAssertEqual((missCount ?? 0) + (hitCount ?? 0), 20)
            XCTAssertEqual(capture.droppedSampleCount, 0)

            let work = await store.storeWorkDiagnosticsSnapshot()
            let capacityEvents = work.invalidations.filter { $0.reasons == ["cache_capacity"] }
            XCTAssertEqual(capacityEvents.count, 2)
            XCTAssertEqual(capacityEvents[0].evictedScopes.count, 1)
            XCTAssertTrue(capacityEvents[0].evictedScopes[0].contains("/physical/1"))
            XCTAssertEqual(capacityEvents[1].evictedScopes.count, 1)
            XCTAssertTrue(capacityEvents[1].evictedScopes[0].contains("/physical/2"))
        }

        func testEnsureIndexedFilesUsesOneSelectiveInvalidationCycle() async throws {
            let root = try makeTemporaryRoot(name: "EnsureIndexedSelectiveInvalidation")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let before = await store.storeWorkDiagnosticsSnapshot().invalidations.count

            let first = root.appendingPathComponent("First.swift")
            let second = root.appendingPathComponent("Second.swift")
            try write("first", to: first)
            try write("second", to: second)
            let indexed = await store.ensureIndexedFiles(paths: [first.path, second.path])

            let work = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(Set(indexed), [first.path, second.path])
            XCTAssertEqual(work.invalidations.count, before + 1)
            let invalidation = try XCTUnwrap(work.invalidations.last)
            XCTAssertEqual(invalidation.reasons, ["explicit_materialization"])
            XCTAssertEqual(invalidation.evictedScopes, ["all_loaded", "visible_workspace"])
        }

        func testRootUnloadUsesOneSelectiveInvalidationCycle() async throws {
            let root = try makeTemporaryRoot(name: "UnloadSelectiveInvalidation")
            try write("seed", to: root.appendingPathComponent("Seed.swift"))
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            _ = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            _ = await store.warmPathLookupIndexes(rootScope: .visibleWorkspace)
            let before = await store.storeWorkDiagnosticsSnapshot().invalidations.count

            await store.unloadRoot(id: record.id)

            let work = await store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(work.invalidations.count, before + 1)
            let invalidation = try XCTUnwrap(work.invalidations.last)
            XCTAssertEqual(invalidation.reasons, ["root_unload"])
            XCTAssertEqual(invalidation.affectedRootIDs, [record.id])
            XCTAssertEqual(invalidation.evictedScopes, ["all_loaded", "visible_workspace"])
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

    func testReadFileWorkDiagnosticsCaptureDiskBytesDecodeAndReturnedRange() async throws {
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
            let value = try XCTUnwrap(loaded)
            let returned = "second\n"
            MCPToolWorkCountDiagnostics.recordReadFileResult(
                returnedBytes: returned.utf8.count,
                returnedLines: 1,
                cacheHit: false
            )
            return value
        }

        XCTAssertEqual(content, body)
        let snapshot = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().readFile.last)
        XCTAssertEqual(snapshot.source, "disk")
        XCTAssertEqual(snapshot.readBytes, body.utf8.count)
        XCTAssertEqual(snapshot.returnedBytes, "second\n".utf8.count)
        XCTAssertEqual(snapshot.returnedLines, 1)
        XCTAssertFalse(snapshot.cacheHit)
        XCTAssertGreaterThanOrEqual(snapshot.decodeMicroseconds, 0)
    }

    func testWorkspaceReadableFileServiceResolvesAndReadsAlwaysReadableExternalFiles() async throws {
        let home = try makeTemporaryRoot(name: "ReadableHome")
        let external = home.appendingPathComponent(".agents/skills/example/SKILL.md")
        try write("skill body", to: external)

        let store = WorkspaceFileContextStore()
        let service = WorkspaceReadableFileService(store: store, homeDirectoryURL: home)
        let resolved = try XCTUnwrap(service.resolveAlwaysReadableExternalFile(atAbsolutePath: external.path))

        XCTAssertEqual(resolved.displayPath, "~/.agents/skills/example/SKILL.md")
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
        XCTAssertEqual(externalContent, "skill body")
        let snapshot = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().readFile.last)
        XCTAssertEqual(snapshot.source, "external_disk")
        XCTAssertEqual(snapshot.readBytes, "skill body".utf8.count)
        XCTAssertEqual(snapshot.returnedBytes, "skill body".utf8.count)
        XCTAssertEqual(snapshot.returnedLines, 1)
        XCTAssertFalse(snapshot.cacheHit)
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

    #if DEBUG
        @MainActor
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

        func testInteractiveReadCacheInvalidatesForEpochMemoryPressureAndRootLifetime() async throws {
            let root = try makeTemporaryRoot(name: "InteractiveReadInvalidation")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("old\n", to: fileURL)

            let store = WorkspaceFileContextStore()
            let firstRoot = try await store.loadRoot(path: root.path)
            let firstLoadedFile = await store.file(rootID: firstRoot.id, relativePath: "A.swift")
            let firstFile = try XCTUnwrap(firstLoadedFile)
            let loadedCold = try await store.interactiveReadSnapshot(for: firstFile)
            let cold = try XCTUnwrap(loadedCold)
            let loadedWarm = try await store.interactiveReadSnapshot(for: firstFile)
            let warm = try XCTUnwrap(loadedWarm)
            XCTAssertFalse(cold.cacheHit)
            XCTAssertTrue(warm.cacheHit)

            try write("watcher-new\n", to: fileURL)
            await store.replayObservedFileSystemDeltas(
                rootID: firstRoot.id,
                deltas: [.fileModified("A.swift", nil)]
            )
            let invalidated = await waitForAsyncCondition {
                await store.interactiveReadCacheSnapshotForTesting().entryCount == 0
            }
            XCTAssertTrue(invalidated)
            let currentLoadedFile = await store.file(rootID: firstRoot.id, relativePath: "A.swift")
            let currentFile = try XCTUnwrap(currentLoadedFile)
            let loadedAfterEpoch = try await store.interactiveReadSnapshot(for: currentFile)
            let afterEpoch = try XCTUnwrap(loadedAfterEpoch)
            XCTAssertFalse(afterEpoch.cacheHit)
            XCTAssertEqual(afterEpoch.preparedContent.linesWithEndings, ["watcher-new\n"])

            await store.clearSearchDecodedContentCache()
            let afterPressureClear = await store.interactiveReadCacheSnapshotForTesting()
            XCTAssertEqual(afterPressureClear.entryCount, 0)
            let loadedAfterMemoryPressure = try await store.interactiveReadSnapshot(for: currentFile)
            let afterMemoryPressure = try XCTUnwrap(loadedAfterMemoryPressure)
            XCTAssertFalse(afterMemoryPressure.cacheHit)

            await store.unloadRoot(id: firstRoot.id)
            let reloadedRoot = try await store.loadRoot(path: root.path)
            let reloadedFileRecord = await store.file(rootID: reloadedRoot.id, relativePath: "A.swift")
            let reloadedFile = try XCTUnwrap(reloadedFileRecord)
            let loadedAfterRootLifetimeChange = try await store.interactiveReadSnapshot(for: reloadedFile)
            let afterRootLifetimeChange = try XCTUnwrap(loadedAfterRootLifetimeChange)
            XCTAssertNotEqual(firstRoot.id, reloadedRoot.id)
            XCTAssertFalse(afterRootLifetimeChange.cacheHit)
            XCTAssertEqual(afterRootLifetimeChange.preparedContent.linesWithEndings, ["watcher-new\n"])
        }

        func testInteractiveReadCacheEnforcesByteBoundAndIncludesRootLifetimeIdentity() async throws {
            let cache = WorkspaceInteractiveReadCache(maxEntryCount: 4, maxEstimatedCost: 32)
            let rootID = UUID()
            let fileID = UUID()
            let fingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 64,
                modificationSeconds: 1,
                modificationNanoseconds: 0,
                statusChangeSeconds: 1,
                statusChangeNanoseconds: 0
            )
            let firstKey = WorkspaceInteractiveReadCacheKey(
                rootID: rootID,
                rootLifetimeID: UUID(),
                fileID: fileID,
                standardizedRelativePath: "A.swift"
            )
            let secondKey = WorkspaceInteractiveReadCacheKey(
                rootID: rootID,
                rootLifetimeID: UUID(),
                fileID: fileID,
                standardizedRelativePath: "A.swift"
            )
            let prepared = WorkspaceInteractiveReadProcessor.prepare(String(repeating: "x", count: 64))

            let first = try await cache.snapshot(for: firstKey, fingerprint: fingerprint, invalidationEpoch: 0) {
                prepared
            }
            let second = try await cache.snapshot(for: secondKey, fingerprint: fingerprint, invalidationEpoch: 0) {
                prepared
            }
            let repeatedFirst = try await cache.snapshot(for: firstKey, fingerprint: fingerprint, invalidationEpoch: 0) {
                prepared
            }
            let snapshot = await cache.snapshotForTesting()

            XCTAssertFalse(first.cacheHit)
            XCTAssertFalse(second.cacheHit)
            XCTAssertFalse(repeatedFirst.cacheHit)
            XCTAssertEqual(snapshot.entryCount, 0)
            XCTAssertEqual(snapshot.preparationCount, 3)
            XCTAssertEqual(snapshot.hitCount, 0)
        }

        func testSearchDecodedContentCacheEnforcesEntryAndCostBounds() async throws {
            let entryBounded = WorkspaceSearchDecodedContentCache(maxEntryCount: 2, maxEstimatedCost: 1000)
            let fingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 1,
                modificationSeconds: 1,
                modificationNanoseconds: 0,
                statusChangeSeconds: 1,
                statusChangeNanoseconds: 0
            )
            func key(_ index: Int) -> WorkspaceSearchContentCacheKey {
                WorkspaceSearchContentCacheKey(
                    rootID: UUID(),
                    fileID: UUID(),
                    standardizedRelativePath: "\(index).txt"
                )
            }
            func load(_ content: String) -> ValidatedFileContentSnapshot {
                ValidatedFileContentSnapshot(
                    content: content,
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                    modificationDate: fingerprint.modificationDate,
                    fingerprint: fingerprint
                )
            }

            let firstKey = key(1)
            let secondKey = key(2)
            let thirdKey = key(3)
            _ = try await entryBounded.snapshot(for: firstKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("one") }
            _ = try await entryBounded.snapshot(for: secondKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("two") }
            _ = try await entryBounded.snapshot(for: firstKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("one-again") }
            _ = try await entryBounded.snapshot(for: thirdKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("three") }
            _ = try await entryBounded.snapshot(for: secondKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("two-reloaded") }
            let entrySnapshot = await entryBounded.snapshotForTesting()

            XCTAssertEqual(entrySnapshot.entryCount, 2)
            XCTAssertEqual(entrySnapshot.loadCount, 4)
            XCTAssertEqual(entrySnapshot.hitCount, 1)

            let costBounded = WorkspaceSearchDecodedContentCache(maxEntryCount: 2, maxEstimatedCost: 1)
            let costKey = key(4)
            let first = try await costBounded.snapshot(for: costKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("oversized") }
            let second = try await costBounded.snapshot(for: costKey, fingerprint: fingerprint, invalidationEpoch: 0) { load("oversized") }
            let costSnapshot = await costBounded.snapshotForTesting()

            XCTAssertNotEqual(first?.revision, second?.revision)
            XCTAssertEqual(costSnapshot.entryCount, 0)
            XCTAssertEqual(costSnapshot.loadCount, 2)
        }

        func testOlderSearchContentInvalidationDoesNotRejectNewerFlight() async throws {
            let cache = WorkspaceSearchDecodedContentCache(maxEntryCount: 2, maxEstimatedCost: 1000)
            let key = WorkspaceSearchContentCacheKey(
                rootID: UUID(),
                fileID: UUID(),
                standardizedRelativePath: "A.swift"
            )
            let fingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 1,
                modificationSeconds: 1,
                modificationNanoseconds: 0,
                statusChangeSeconds: 1,
                statusChangeNanoseconds: 0
            )
            let gate = AsyncGate()
            let load = Task {
                try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 2) {
                    await gate.markStartedAndWaitForRelease()
                    return ValidatedFileContentSnapshot(
                        content: "new",
                        detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                        modificationDate: fingerprint.modificationDate,
                        fingerprint: fingerprint
                    )
                }
            }
            await gate.waitUntilStarted()

            await cache.invalidate(key, through: 1)
            await gate.release()
            let value = try await load.value
            let snapshot = await cache.snapshotForTesting()

            XCTAssertEqual(value?.content, "new")
            XCTAssertNotNil(value?.revision)
            XCTAssertEqual(snapshot.entryCount, 1)
            XCTAssertEqual(snapshot.acceptedLoadCount, 1)
        }

        func testBulkSearchContentInvalidationEvictsEveryDistinctKeyAtUnchangedFingerprint() async throws {
            let cache = WorkspaceSearchDecodedContentCache(maxEntryCount: 8, maxEstimatedCost: 1000)
            let rootID = UUID()
            let fingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 1,
                modificationSeconds: 1,
                modificationNanoseconds: 0,
                statusChangeSeconds: 1,
                statusChangeNanoseconds: 0
            )
            let keys = (0 ..< 4).map { index in
                WorkspaceSearchContentCacheKey(
                    rootID: rootID,
                    fileID: UUID(),
                    standardizedRelativePath: "\(index).swift"
                )
            }
            var initialRevisions: [WorkspaceSearchContentCacheKey: UInt64] = [:]
            for (index, key) in keys.enumerated() {
                let value = try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 1) {
                    ValidatedFileContentSnapshot(
                        content: "old-\(index)",
                        detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                        modificationDate: fingerprint.modificationDate,
                        fingerprint: fingerprint
                    )
                }
                initialRevisions[key] = try XCTUnwrap(value?.revision)
            }

            var batch = WorkspaceSearchContentInvalidationBatch()
            for key in keys {
                batch.record(key, through: 1)
            }
            await cache.invalidate(batch)

            for (index, key) in keys.enumerated() {
                let refreshed = try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 1) {
                    ValidatedFileContentSnapshot(
                        content: "new-\(index)",
                        detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                        modificationDate: fingerprint.modificationDate,
                        fingerprint: fingerprint
                    )
                }
                XCTAssertEqual(refreshed?.content, "new-\(index)")
                XCTAssertGreaterThan(try XCTUnwrap(refreshed?.revision), try XCTUnwrap(initialRevisions[key]))
            }
            let snapshot = await cache.snapshotForTesting()

            XCTAssertEqual(batch.count, keys.count)
            XCTAssertEqual(snapshot.entryCount, keys.count)
            XCTAssertEqual(snapshot.loadCount, keys.count * 2)
            XCTAssertEqual(snapshot.acceptedLoadCount, keys.count * 2)
            XCTAssertEqual(snapshot.hitCount, 0)
        }

        func testBulkSearchContentInvalidationRetainsMaximumEpochAndProtectsNewerFlight() async throws {
            let cache = WorkspaceSearchDecodedContentCache(maxEntryCount: 2, maxEstimatedCost: 1000)
            let key = WorkspaceSearchContentCacheKey(
                rootID: UUID(),
                fileID: UUID(),
                standardizedRelativePath: "A.swift"
            )
            let oldFingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 9,
                modificationSeconds: 9,
                modificationNanoseconds: 0,
                statusChangeSeconds: 9,
                statusChangeNanoseconds: 0
            )
            let newFingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: 1,
                byteSize: 10,
                modificationSeconds: 10,
                modificationNanoseconds: 0,
                statusChangeSeconds: 10,
                statusChangeNanoseconds: 0
            )
            let oldGate = AsyncGate()
            let newGate = AsyncGate()
            let oldFlight = Task {
                try await cache.snapshot(for: key, fingerprint: oldFingerprint, invalidationEpoch: 9) {
                    await oldGate.markStartedAndWaitForRelease()
                    return ValidatedFileContentSnapshot(
                        content: "old",
                        detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                        modificationDate: oldFingerprint.modificationDate,
                        fingerprint: oldFingerprint
                    )
                }
            }
            let newFlight = Task {
                try await cache.snapshot(for: key, fingerprint: newFingerprint, invalidationEpoch: 10) {
                    await newGate.markStartedAndWaitForRelease()
                    return ValidatedFileContentSnapshot(
                        content: "new",
                        detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                        modificationDate: newFingerprint.modificationDate,
                        fingerprint: newFingerprint
                    )
                }
            }
            await oldGate.waitUntilStarted()
            await newGate.waitUntilStarted()

            var batch = WorkspaceSearchContentInvalidationBatch()
            batch.record(key, through: 7)
            batch.record(key, through: 3)
            batch.record(key, through: 9)
            batch.record(key, through: 5)
            XCTAssertEqual(batch.count, 1)
            XCTAssertEqual(batch.maximumEpoch(for: key), 9)
            await cache.invalidate(batch)

            await oldGate.release()
            await newGate.release()
            let oldValue = try await oldFlight.value
            let newValue = try await newFlight.value
            XCTAssertNil(oldValue)
            XCTAssertEqual(newValue?.content, "new")
            let acceptedRevision = try XCTUnwrap(newValue?.revision)

            var delayedOlderBatch = WorkspaceSearchContentInvalidationBatch()
            delayedOlderBatch.record(key, through: 5)
            await cache.invalidate(delayedOlderBatch)
            let cachedNewValue = try await cache.snapshot(
                for: key,
                fingerprint: newFingerprint,
                invalidationEpoch: 10
            ) {
                XCTFail("A delayed older invalidation must not evict the newer entry")
                return ValidatedFileContentSnapshot(
                    content: "unexpected",
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue,
                    modificationDate: newFingerprint.modificationDate,
                    fingerprint: newFingerprint
                )
            }
            let snapshot = await cache.snapshotForTesting()

            XCTAssertEqual(cachedNewValue?.content, "new")
            XCTAssertEqual(cachedNewValue?.revision, acceptedRevision)
            XCTAssertEqual(snapshot.entryCount, 1)
            XCTAssertEqual(snapshot.acceptedLoadCount, 1)
            XCTAssertEqual(snapshot.hitCount, 1)
        }

        func testSearchContentSnapshotWarmHitKeepsRevisionAndAvoidsSecondRead() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentWarmHit")
            try write("let warmToken = true\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let readCounter = AsyncGate()
            await readCounter.release()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
                await readCounter.markStartedAndWaitForRelease()
            }

            let cold = try await store.searchContentSnapshot(for: file)
            let readsAfterColdLoad = await readCounter.startCount()
            let warm = try await store.searchContentSnapshot(for: file)
            let readsAfterWarmLoad = await readCounter.startCount()
            let cache = await store.searchDecodedContentCacheSnapshotForTesting()

            XCTAssertTrue(cold.isFresh)
            XCTAssertEqual(cold.content, "let warmToken = true\n")
            XCTAssertNotNil(cold.contentRevision)
            XCTAssertEqual(warm.contentRevision, cold.contentRevision)
            XCTAssertEqual(readsAfterWarmLoad, readsAfterColdLoad)
            XCTAssertEqual(cache.entryCount, 1)
            XCTAssertEqual(cache.loadCount, 1)
            XCTAssertEqual(cache.acceptedLoadCount, 1)
            XCTAssertEqual(cache.hitCount, 1)
        }

        func testConcurrentSearchContentSnapshotMissesCoalesceToOneLoad() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentCoalescing")
            try write("let coalescedToken = true\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let readGate = AsyncGate()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
                await readGate.markStartedAndWaitForRelease()
            }

            let tasks = (0 ..< 12).map { _ in
                Task { try await store.searchContentSnapshot(for: file) }
            }
            await readGate.waitUntilStarted()
            let pressured = await waitForSearchContentCache(store: store) {
                $0.activeFlightCount == 1 && $0.waiterCount == 12
            }
            XCTAssertEqual(pressured.loadCount, 1)
            XCTAssertEqual(pressured.joinCount, 11)

            await readGate.release()
            var snapshots: [FileSearchContentSnapshot] = []
            for task in tasks {
                try await snapshots.append(task.value)
            }
            let revisions = Set(snapshots.compactMap(\.contentRevision))
            let settled = await waitForSearchContentCache(store: store) {
                $0.activeFlightCount == 0 && $0.entryCount == 1
            }

            XCTAssertEqual(revisions.count, 1)
            XCTAssertTrue(snapshots.allSatisfy { $0.content == "let coalescedToken = true\n" && $0.isFresh })
            XCTAssertEqual(settled.loadCount, 1)
            XCTAssertEqual(settled.acceptedLoadCount, 1)
        }

        func testCancellingOneSearchContentSnapshotWaiterDoesNotPoisonSharedLoad() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentFollowerCancellation")
            try write("let cancellationToken = true\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let readGate = AsyncGate()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
                await readGate.markStartedAndWaitForRelease()
            }

            let leader = Task { try await store.searchContentSnapshot(for: file) }
            await readGate.waitUntilStarted()
            let follower = Task { try await store.searchContentSnapshot(for: file) }
            _ = await waitForSearchContentCache(store: store) { $0.waiterCount == 2 }

            follower.cancel()
            do {
                _ = try await follower.value
                XCTFail("Expected follower cancellation")
            } catch is CancellationError {
                // Expected: the shared disk load remains owned by the leader.
            }

            let afterCancellation = await waitForSearchContentCache(store: store) {
                $0.waiterCount == 1 && $0.cancellationCount == 1
            }
            XCTAssertEqual(afterCancellation.activeFlightCount, 1)
            await readGate.release()
            let leaderSnapshot = try await leader.value
            let settled = await waitForSearchContentCache(store: store) {
                $0.activeFlightCount == 0 && $0.entryCount == 1
            }

            XCTAssertTrue(leaderSnapshot.isFresh)
            XCTAssertNotNil(leaderSnapshot.contentRevision)
            XCTAssertEqual(settled.acceptedLoadCount, 1)
        }

        func testCancellingAllSearchContentSnapshotWaitersPublishesNothing() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentAllCancellation")
            try write("let cancelledToken = true\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let readGate = AsyncGate()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
                await readGate.markStartedAndWaitForRelease()
            }

            let first = Task { try await store.searchContentSnapshot(for: file) }
            await readGate.waitUntilStarted()
            let second = Task { try await store.searchContentSnapshot(for: file) }
            _ = await waitForSearchContentCache(store: store) { $0.waiterCount == 2 }

            first.cancel()
            second.cancel()
            for task in [first, second] {
                do {
                    _ = try await task.value
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    // Expected.
                }
            }
            await readGate.release()
            let settled = await waitForSearchContentCache(store: store) {
                $0.activeFlightCount == 0 && $0.waiterCount == 0
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            let final = await store.searchDecodedContentCacheSnapshotForTesting()

            XCTAssertEqual(settled.entryCount, 0)
            XCTAssertEqual(final.entryCount, 0)
            XCTAssertEqual(final.acceptedLoadCount, 0)
            XCTAssertEqual(final.cancellationCount, 2)
        }

        func testSearchContentSnapshotRejectsChangedDuringReadAndRetriesFreshBytes() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentChangedDuringRead")
            let fileURL = root.appendingPathComponent("A.swift")
            try write("let oldReadToken = true\n", to: fileURL)

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let rewriteCounter = AsyncGate()
            await rewriteCounter.release()
            try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
                guard await rewriteCounter.startCount() == 0 else {
                    await rewriteCounter.markStartedAndWaitForRelease()
                    return
                }
                try? "let newReadToken = true\n".write(to: fileURL, atomically: true, encoding: .utf8)
                await rewriteCounter.markStartedAndWaitForRelease()
            }

            let snapshot = try await store.searchContentSnapshot(for: file)
            let cache = await store.searchDecodedContentCacheSnapshotForTesting()

            XCTAssertTrue(snapshot.isFresh)
            XCTAssertEqual(snapshot.content, "let newReadToken = true\n")
            XCTAssertNotNil(snapshot.contentRevision)
            XCTAssertEqual(cache.loadCount, 2)
            XCTAssertEqual(cache.acceptedLoadCount, 1)
        }

        func testSearchContentSnapshotSameMtimeRewriteAndMutationInvalidationAdvanceRevision() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentInvalidation")
            let fileURL = root.appendingPathComponent("A.swift")
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            try write("old", to: fileURL)
            try setDiskModificationDate(fixedDate, for: fileURL)

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let initial = try await store.searchContentSnapshot(for: file)

            try write("new", to: fileURL)
            try setDiskModificationDate(fixedDate, for: fileURL)
            let sameMtimeRewrite = try await store.searchContentSnapshot(for: file)

            _ = try await store.editFile(rootID: rootRecord.id, relativePath: "A.swift", newContent: "edit")
            let directEdit = try await store.searchContentSnapshot(for: file)

            try write("watch", to: fileURL)
            await store.replayObservedFileSystemDeltas(
                rootID: rootRecord.id,
                deltas: [.fileModified("A.swift", fixedDate)]
            )
            let watcherEdit = try await store.searchContentSnapshot(for: file)

            XCTAssertEqual(initial.content, "old")
            XCTAssertEqual(sameMtimeRewrite.content, "new")
            XCTAssertEqual(directEdit.content, "edit")
            XCTAssertEqual(watcherEdit.content, "watch")
            let revisions = try [initial, sameMtimeRewrite, directEdit, watcherEdit].map {
                try XCTUnwrap($0.contentRevision)
            }
            XCTAssertEqual(Set(revisions).count, revisions.count)
            XCTAssertEqual(revisions, revisions.sorted())
        }

        func testSearchContentSnapshotMoveDeleteAndFolderRemovalEvictOldIdentities() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentRemovalInvalidation")
            try write("move", to: root.appendingPathComponent("A.swift"))
            try write("nested", to: root.appendingPathComponent("Folder/B.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedA = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let loadedB = await store.file(rootID: rootRecord.id, relativePath: "Folder/B.swift")
            let oldA = try XCTUnwrap(loadedA)
            let oldB = try XCTUnwrap(loadedB)
            _ = try await store.searchContentSnapshot(for: oldA)
            _ = try await store.searchContentSnapshot(for: oldB)

            try await store.moveFile(rootID: rootRecord.id, from: "A.swift", to: "Moved.swift")
            let staleMovedIdentity = try await store.searchContentSnapshot(for: oldA)
            let loadedMovedRecord = await store.file(rootID: rootRecord.id, relativePath: "Moved.swift")
            let movedRecord = try XCTUnwrap(loadedMovedRecord)
            let moved = try await store.searchContentSnapshot(for: movedRecord)
            try await store.deleteFile(rootID: rootRecord.id, relativePath: "Moved.swift")

            try FileManager.default.removeItem(at: root.appendingPathComponent("Folder"))
            await store.replayObservedFileSystemDeltas(rootID: rootRecord.id, deltas: [.folderRemoved("Folder")])
            let staleNestedIdentity = try await store.searchContentSnapshot(for: oldB)
            let settled = await waitForSearchContentCache(store: store) { $0.entryCount == 0 }

            XCTAssertFalse(staleMovedIdentity.isFresh)
            XCTAssertTrue(moved.isFresh)
            XCTAssertFalse(staleNestedIdentity.isFresh)
            XCTAssertEqual(settled.entryCount, 0)
        }

        func testSearchContentSnapshotCacheClearAndRootUnloadEvictEntries() async throws {
            let root = try makeTemporaryRoot(name: "SearchContentCacheClear")
            try write("let clearToken = true\n", to: root.appendingPathComponent("A.swift"))

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFile = await store.file(rootID: rootRecord.id, relativePath: "A.swift")
            let file = try XCTUnwrap(loadedFile)
            let initial = try await store.searchContentSnapshot(for: file)
            await store.clearSearchDecodedContentCache()
            let afterClear = try await store.searchContentSnapshot(for: file)
            await store.unloadRoot(id: rootRecord.id)
            let afterUnload = await store.searchDecodedContentCacheSnapshotForTesting()

            XCTAssertNotEqual(initial.contentRevision, afterClear.contentRevision)
            XCTAssertEqual(afterUnload.entryCount, 0)
            XCTAssertEqual(afterUnload.activeFlightCount, 0)
        }

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
        let rootRecord = try await store.loadRoot(path: root.path)
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        await manager.setCodeScanEnabled(false)
        let workspace = WorkspaceModel(name: "StrictSearchFreshness", repoPaths: [root.path])
        manager.registerPreloadedWorkspaceRoot(rootRecord)
        _ = try manager.attachRootShell(for: rootRecord, workspaceID: workspace.id)
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

        private var createdFileFlags: FSEventStreamEventFlags {
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
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
            maxYields: Int = 1000,
            _ condition: () async -> Bool
        ) async -> Bool {
            for _ in 0 ..< maxYields {
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
