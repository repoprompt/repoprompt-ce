import CoreServices
@testable import RepoPrompt
import XCTest

final class SelectionSlicePersistenceAndRebaseTests: XCTestCase {
    func testPartitionStoreColdReloadPreservesSlicesAndIsolatesScopes() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionSlicePersistenceAndRebaseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let rootPath = "/tmp/SelectionSlicePersistenceAndRebaseTests/root"
        let relativePath = "Sources/A.swift"
        let workspaceID = UUID()
        let tabID = UUID()
        let scope = PartitionScope(workspaceID: workspaceID, tabID: tabID)
        let normalizedRanges = [
            LineRange(start: 2, end: 4, description: "header"),
            LineRange(start: 8, end: 10, description: "body")
        ]
        let anchors = [
            SliceAnchor(range: normalizedRanges[0], startSignature: ["header-start"], endSignature: ["header-end"]),
            SliceAnchor(range: normalizedRanges[1], startSignature: ["body-start"], endSignature: ["body-end"])
        ]
        let modificationTime = 1_717_171_717.25

        let writer = PartitionStore(baseURL: baseURL)
        _ = try await writer.apply(
            forRoot: rootPath,
            scope: scope,
            updates: [
                relativePath: PartitionStore.SliceUpdate(
                    ranges: Array(normalizedRanges.reversed()),
                    fileModificationTime: modificationTime,
                    anchors: anchors
                )
            ],
            mode: .set
        )

        let reader = PartitionStore(baseURL: baseURL)
        let reloaded = await reader.load(forRoot: rootPath, scope: scope)
        XCTAssertEqual(
            reloaded.files,
            [relativePath: PartitionStore.StoredSlices(
                ranges: normalizedRanges,
                fileModificationTime: modificationTime,
                anchors: anchors
            )]
        )

        let anotherTab = await reader.load(
            forRoot: rootPath,
            scope: PartitionScope(workspaceID: workspaceID, tabID: UUID())
        )
        XCTAssertTrue(anotherTab.files.isEmpty)

        let anotherWorkspace = await reader.load(
            forRoot: rootPath,
            scope: PartitionScope(workspaceID: UUID(), tabID: tabID)
        )
        XCTAssertTrue(anotherWorkspace.files.isEmpty)
    }

    func testPartitionStoreCASConflictPreservesNewerPartition() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionSlicePartitionCAS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let rootPath = "/tmp/SelectionSlicePartitionCAS/root"
        let relativePath = "Sources/A.swift"
        let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
        let initial = PartitionStore.StoredSlices(
            ranges: [LineRange(start: 2, end: 4)],
            fileModificationTime: 1
        )
        let newer = PartitionStore.StoredSlices(
            ranges: [LineRange(start: 20, end: 24)],
            fileModificationTime: 2
        )
        let writer = PartitionStore(baseURL: baseURL)
        _ = try await writer.apply(
            forRoot: rootPath,
            scope: scope,
            updates: [relativePath: .init(
                ranges: initial.ranges,
                fileModificationTime: initial.fileModificationTime
            )],
            mode: .setPaths
        )
        _ = try await writer.apply(
            forRoot: rootPath,
            scope: scope,
            updates: [relativePath: .init(
                ranges: newer.ranges,
                fileModificationTime: newer.fileModificationTime
            )],
            mode: .setPaths
        )

        let staleWriter = PartitionStore(baseURL: baseURL)
        let result = try await staleWriter.applyIfCurrent(
            forRoot: rootPath,
            scope: scope,
            updates: [relativePath: .init(
                ranges: [LineRange(start: 3, end: 5)],
                fileModificationTime: 3
            )],
            mode: .setPaths,
            expectedCurrent: [relativePath: initial]
        )

        XCTAssertNil(result)
        let persisted = await writer.load(forRoot: rootPath, scope: scope)
        XCTAssertEqual(persisted.files[relativePath], newer)
    }

    #if DEBUG
        func testPartitionStoreCASIsSerializedAcrossStoreInstances() async throws {
            let baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectionSlicePartitionConcurrentCAS-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: baseURL) }

            let rootPath = "/tmp/SelectionSlicePartitionConcurrentCAS/root"
            let relativePath = "Sources/A.swift"
            let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
            let initial = PartitionStore.StoredSlices(
                ranges: [LineRange(start: 2, end: 4)],
                fileModificationTime: 1
            )
            let firstStore = PartitionStore(baseURL: baseURL)
            let secondStore = PartitionStore(baseURL: baseURL)
            _ = try await firstStore.apply(
                forRoot: rootPath,
                scope: scope,
                updates: [relativePath: .init(
                    ranges: initial.ranges,
                    fileModificationTime: initial.fileModificationTime
                )],
                mode: .setPaths
            )

            let firstValidated = expectation(description: "first writer validated expected state")
            let releaseFirst = SelectionSliceTestSemaphore()
            await firstStore.setDidValidateCurrentHandlerForTesting {
                firstValidated.fulfill()
                releaseFirst.wait()
            }
            defer {
                Task { await firstStore.setDidValidateCurrentHandlerForTesting(nil) }
                releaseFirst.signal()
            }

            let firstRanges = [LineRange(start: 10, end: 14)]
            let secondRanges = [LineRange(start: 20, end: 24)]
            let firstTask = Task {
                try await firstStore.applyIfCurrent(
                    forRoot: rootPath,
                    scope: scope,
                    updates: [relativePath: .init(ranges: firstRanges, fileModificationTime: 2)],
                    mode: .setPaths,
                    expectedCurrent: [relativePath: initial]
                )
            }
            await fulfillment(of: [firstValidated], timeout: 2)
            let secondTask = Task {
                try await secondStore.applyIfCurrent(
                    forRoot: rootPath,
                    scope: scope,
                    updates: [relativePath: .init(ranges: secondRanges, fileModificationTime: 3)],
                    mode: .setPaths,
                    expectedCurrent: [relativePath: initial]
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            releaseFirst.signal()

            let firstResult = try await firstTask.value
            let secondResult = try await secondTask.value
            XCTAssertNotNil(firstResult)
            XCTAssertNil(secondResult)
            let persisted = await firstStore.load(forRoot: rootPath, scope: scope)
            XCTAssertEqual(persisted.files[relativePath]?.ranges, firstRanges)
        }

        func testPartitionStoreCancellationAfterAtomicWriteStillSucceedsAndNotifies() async throws {
            let baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectionSlicePartitionCancellation-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: baseURL) }

            let store = PartitionStore(baseURL: baseURL)
            let rootPath = "/tmp/SelectionSlicePartitionCancellation/root"
            let relativePath = "Sources/A.swift"
            let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
            let persisted = expectation(description: "atomic replacement completed")
            let notified = expectation(description: "save notification posted")
            let release = SelectionSliceTestSemaphore()
            await store.setDidPersistHandlerForTesting {
                persisted.fulfill()
                release.wait()
            }
            defer {
                Task { await store.setDidPersistHandlerForTesting(nil) }
                release.signal()
            }
            let sourceID = store.notificationSourceID
            let observer = NotificationCenter.default.addObserver(
                forName: PartitionStore.didSaveNotification,
                object: nil,
                queue: nil
            ) { note in
                guard note.userInfo?[PartitionStore.notifSourceIDKey] as? UUID == sourceID else { return }
                notified.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let task = Task {
                try await store.apply(
                    forRoot: rootPath,
                    scope: scope,
                    updates: [relativePath: .init(
                        ranges: [LineRange(start: 4, end: 8)],
                        fileModificationTime: 4
                    )],
                    mode: .setPaths
                )
            }
            await fulfillment(of: [persisted], timeout: 2)
            task.cancel()
            release.signal()

            let result = try await task.value
            await fulfillment(of: [notified], timeout: 2)
            XCTAssertEqual(result[relativePath]?.ranges, [LineRange(start: 4, end: 8)])
            let reloaded = await store.load(forRoot: rootPath, scope: scope)
            XCTAssertEqual(reloaded.files[relativePath]?.ranges, [LineRange(start: 4, end: 8)])
        }

        func testValidatedSliceSnapshotRejectsMidReadReplacement() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectionSliceValidatedSnapshot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let relativePath = "Large.swift"
            let fileURL = rootURL.appendingPathComponent(relativePath)
            try Data(repeating: 0x61, count: 2_000_000).write(to: fileURL)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let loadedService = await store.fileSystemServiceForTesting(rootID: root.id)
            let service = try XCTUnwrap(loadedService)
            let mutation = SelectionSliceOneShotMutation()
            await service.setContentReadChunkHandlerForTesting { path in
                guard path == relativePath, await mutation.take() else { return }
                try? Data("replacement\n".utf8).write(to: fileURL, options: .atomic)
            }
            defer { Task { await service.setContentReadChunkHandlerForTesting(nil) } }

            do {
                _ = try await store.readValidatedContentSnapshot(
                    rootID: root.id,
                    relativePath: relativePath,
                    workloadClass: .contentSearch
                )
                XCTFail("Expected a changed fingerprint to reject the mixed snapshot")
            } catch FileContentValidationError.fingerprintChanged {
                // Expected: content and modification date must describe one exact revision.
            }
        }
    #endif

    func testSliceRebaseWholeFileReplacementUsesConservativeBoundedFallback() {
        let oldLines = (1 ... 2000).map { "old-\($0)" }
        let newLines = (1 ... 2000).map { "new-\($0)" }
        let selected = LineRange(start: 900, end: 1100, description: "selection")
        let oldText = oldLines.joined(separator: "\n") + "\n"

        let result = SliceRebaseEngine.rebase(
            oldText: oldText,
            newText: newLines.joined(separator: "\n") + "\n",
            oldRanges: [selected],
            anchors: SliceRebaseEngine.buildAnchors(content: oldText, ranges: [selected])
        )

        XCTAssertEqual(result.rebased, [LineRange(start: 1, end: 2000, description: "selection")])
        XCTAssertTrue(result.didChange)
        XCTAssertFalse(result.isStale)
    }

    func testSliceRebaseDropsOnlyWhenPostEditContentHasNoValidLine() {
        let originalRange = LineRange(start: 2, end: 2, description: "selected")
        let oldText = "before\nselected\nafter\n"
        let anchors = SliceRebaseEngine.buildAnchors(content: oldText, ranges: [originalRange])

        let result = SliceRebaseEngine.rebase(
            oldText: oldText,
            newText: "",
            oldRanges: [originalRange],
            anchors: anchors
        )

        XCTAssertEqual(result.rebased, [])
        XCTAssertEqual(result.dropped, [originalRange])
        XCTAssertTrue(result.didChange)
        XCTAssertFalse(result.isStale)
    }

    func testSliceRebaseTransformsOverlapMatrixWithStableAffinity() {
        struct Case {
            let name: String
            let oldLines: [String]
            let newLines: [String]
            let ranges: [LineRange]
            let expected: [LineRange]
        }

        let cases = [
            Case(
                name: "edit before shifts both bounds",
                oldLines: ["a", "b", "c", "d", "e"],
                newLines: ["inserted", "a", "b", "c", "d", "e"],
                ranges: [LineRange(start: 4, end: 5, description: "tail")],
                expected: [LineRange(start: 5, end: 6, description: "tail")]
            ),
            Case(
                name: "edit after preserves bounds",
                oldLines: ["a", "b", "c", "d"],
                newLines: ["a", "b", "c", "d", "after"],
                ranges: [LineRange(start: 2, end: 3, description: "middle")],
                expected: [LineRange(start: 2, end: 3, description: "middle")]
            ),
            Case(
                name: "strictly inside insertion is included",
                oldLines: ["a", "b", "c", "d", "e"],
                newLines: ["a", "b", "inside", "c", "d", "e"],
                ranges: [LineRange(start: 2, end: 4, description: "body")],
                expected: [LineRange(start: 2, end: 5, description: "body")]
            ),
            Case(
                name: "boundary insertions remain outside",
                oldLines: ["a", "b", "c", "d"],
                newLines: ["a", "before", "b", "c", "after", "d"],
                ranges: [LineRange(start: 2, end: 3, description: "body")],
                expected: [LineRange(start: 3, end: 4, description: "body")]
            ),
            Case(
                name: "partial overlap retains unaffected and replacement content",
                oldLines: ["a", "b", "c", "d", "e", "f"],
                newLines: ["a", "b", "r1", "r2", "f"],
                ranges: [LineRange(start: 2, end: 4, description: "partial")],
                expected: [LineRange(start: 2, end: 4, description: "partial")]
            ),
            Case(
                name: "full replacement maps to replacement span",
                oldLines: ["a", "b", "c", "d"],
                newLines: ["a", "r1", "r2", "r3", "d"],
                ranges: [LineRange(start: 2, end: 3, description: "replace")],
                expected: [LineRange(start: 2, end: 4, description: "replace")]
            ),
            Case(
                name: "full deletion uses following-line affinity",
                oldLines: ["a", "b", "c", "d", "e"],
                newLines: ["a", "d", "e"],
                ranges: [LineRange(start: 2, end: 3, description: "delete")],
                expected: [LineRange(start: 2, end: 2, description: "delete")]
            ),
            Case(
                name: "multiple ordered edits compose in pre-edit coordinates",
                oldLines: ["a", "b", "c", "d", "e", "f", "g", "h"],
                newLines: ["top", "a", "b", "c", "r1", "r2", "r3", "g", "h"],
                ranges: [LineRange(start: 3, end: 6, description: "multi")],
                expected: [LineRange(start: 4, end: 7, description: "multi")]
            ),
            Case(
                name: "unrelated ranges and descriptions remain distinct",
                oldLines: ["a", "b", "c", "d", "e", "f", "g"],
                newLines: ["top", "a", "b", "c", "d", "e", "f", "g", "bottom"],
                ranges: [
                    LineRange(start: 2, end: 2, description: "first"),
                    LineRange(start: 6, end: 7, description: "second")
                ],
                expected: [
                    LineRange(start: 3, end: 3, description: "first"),
                    LineRange(start: 7, end: 8, description: "second")
                ]
            )
        ]

        for testCase in cases {
            let oldText = testCase.oldLines.joined(separator: "\n") + "\n"
            let newText = testCase.newLines.joined(separator: "\n") + "\n"
            let result = SliceRebaseEngine.rebase(
                oldText: oldText,
                newText: newText,
                oldRanges: testCase.ranges,
                anchors: SliceRebaseEngine.buildAnchors(content: oldText, ranges: testCase.ranges)
            )

            XCTAssertEqual(result.rebased, testCase.expected, testCase.name)
            XCTAssertTrue(result.dropped.isEmpty, testCase.name)
            XCTAssertFalse(result.isStale, testCase.name)
        }

        let editedPath = "/tmp/Selected.swift"
        let unrelatedPath = "/tmp/Unrelated.swift"
        let selection = StoredSelection(
            selectedPaths: [editedPath, unrelatedPath],

            slices: [
                editedPath: [LineRange(start: 4, end: 5, description: "edited")],
                unrelatedPath: [LineRange(start: 10, end: 12, description: "unrelated")]
            ],
            codemapAutoEnabled: false
        )
        let updated = try? XCTUnwrap(WorkspaceManagerViewModel.rebasedStoredSelectionSlices(
            selection,
            for: editedPath,
            transform: { _ in [LineRange(start: 5, end: 6, description: "edited")] }
        ))
        XCTAssertEqual(updated?.selectedPaths, selection.selectedPaths)
        XCTAssertEqual(updated?.codemapAutoEnabled, selection.codemapAutoEnabled)
        XCTAssertEqual(updated?.slices[editedPath], [LineRange(start: 5, end: 6, description: "edited")])
        XCTAssertEqual(updated?.slices[unrelatedPath], selection.slices[unrelatedPath])
    }

    func testSliceRebaseLargeBeginningMiddleEndEditsAndRestoresStayCanonical() {
        let originalLines = (1 ... 14050).map { String(format: "line-%05d", $0) }
        let originalText = originalLines.joined(separator: "\n") + "\n"
        let originalRanges = [
            LineRange(start: 35, end: 45, description: "beginning"),
            LineRange(start: 2495, end: 2505, description: "middle"),
            LineRange(start: 13990, end: 14000, description: "end")
        ]

        struct EditCase {
            let name: String
            let replaced: ClosedRange<Int>
            let replacement: [String]
            let expected: [LineRange]
        }

        let edits = [
            EditCase(
                name: "beginning",
                replaced: 39 ... 41,
                replacement: ["begin-r1", "begin-r2", "begin-r3", "begin-r4", "begin-r5"],
                expected: [
                    LineRange(start: 35, end: 47, description: "beginning"),
                    LineRange(start: 2497, end: 2507, description: "middle"),
                    LineRange(start: 13992, end: 14002, description: "end")
                ]
            ),
            EditCase(
                name: "middle",
                replaced: 2499 ... 2501,
                replacement: ["middle-r1"],
                expected: [
                    LineRange(start: 35, end: 45, description: "beginning"),
                    LineRange(start: 2495, end: 2503, description: "middle"),
                    LineRange(start: 13988, end: 13998, description: "end")
                ]
            ),
            EditCase(
                name: "end",
                replaced: 13994 ... 13996,
                replacement: ["end-r1", "end-r2", "end-r3", "end-r4"],
                expected: [
                    LineRange(start: 35, end: 45, description: "beginning"),
                    LineRange(start: 2495, end: 2505, description: "middle"),
                    LineRange(start: 13990, end: 14001, description: "end")
                ]
            )
        ]

        for edit in edits {
            var editedLines = originalLines
            editedLines.replaceSubrange((edit.replaced.lowerBound - 1) ... (edit.replaced.upperBound - 1), with: edit.replacement)
            let editedText = editedLines.joined(separator: "\n") + "\n"
            let edited = SliceRebaseEngine.rebase(
                oldText: originalText,
                newText: editedText,
                oldRanges: originalRanges,
                anchors: SliceRebaseEngine.buildAnchors(content: originalText, ranges: originalRanges)
            )
            XCTAssertEqual(edited.rebased, edit.expected, edit.name)
            XCTAssertTrue(edited.dropped.isEmpty, edit.name)
            XCTAssertFalse(edited.isStale, edit.name)

            let restored = SliceRebaseEngine.rebase(
                oldText: editedText,
                newText: originalText,
                oldRanges: edited.rebased,
                anchors: SliceRebaseEngine.buildAnchors(content: editedText, ranges: edited.rebased)
            )
            XCTAssertEqual(restored.rebased, originalRanges, edit.name + " restore")
            XCTAssertTrue(restored.dropped.isEmpty, edit.name + " restore")
            XCTAssertFalse(restored.isStale, edit.name + " restore")

            for range in edited.rebased {
                XCTAssertGreaterThanOrEqual(range.start, 1, edit.name)
                XCTAssertLessThanOrEqual(range.end, editedLines.count, edit.name)
                XCTAssertLessThanOrEqual(range.start, range.end, edit.name)
                XCTAssertFalse(editedLines[(range.start - 1) ... (range.end - 1)].isEmpty, edit.name)
            }
        }
    }

    #if DEBUG
        @MainActor
        func testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectionSliceCanonicalIntegration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: rootURL)
            }

            let relativePath = "Fixtures/LargeSliceFixture.swift"
            let fileURL = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let originalLines = (1 ... 14050).map { String(format: "line-%05d", $0) }
            let originalText = originalLines.joined(separator: "\n") + "\n"
            try originalText.write(to: fileURL, atomically: true, encoding: .utf8)

            let originalRanges = [
                LineRange(start: 35, end: 45, description: "beginning"),
                LineRange(start: 2495, end: 2505, description: "middle"),
                LineRange(start: 13990, end: 14000, description: "end")
            ]
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let attachedPublisherIngress = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: root.id)
            XCTAssertTrue(attachedPublisherIngress)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            manager.setActiveTabID(UUID())
            addTeardownBlock {
                await manager.unloadAllRootFolders()
            }

            _ = try await manager.setSelectionSlices(
                entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: originalRanges)],
                mode: .set,
                persistWorkspace: false
            )
            let file = try XCTUnwrap(manager.findFileByFullPath(fileURL.path))
            XCTAssertEqual(manager.currentSlicesByRootForTesting()[root.standardizedFullPath]?[relativePath]?.ranges, originalRanges)
            XCTAssertEqual(manager.snapshotSelection().slices[file.standardizedFullPath], originalRanges)

            struct EditCase {
                let name: String
                let replaced: ClosedRange<Int>
                let replacement: [String]
                let expected: [LineRange]
            }
            let edits = [
                EditCase(
                    name: "beginning",
                    replaced: 39 ... 41,
                    replacement: ["begin-r1", "begin-r2", "begin-r3", "begin-r4", "begin-r5"],
                    expected: [
                        LineRange(start: 35, end: 47, description: "beginning"),
                        LineRange(start: 2497, end: 2507, description: "middle"),
                        LineRange(start: 13992, end: 14002, description: "end")
                    ]
                ),
                EditCase(
                    name: "middle",
                    replaced: 2499 ... 2501,
                    replacement: ["middle-r1"],
                    expected: [
                        LineRange(start: 35, end: 45, description: "beginning"),
                        LineRange(start: 2495, end: 2503, description: "middle"),
                        LineRange(start: 13988, end: 13998, description: "end")
                    ]
                ),
                EditCase(
                    name: "end",
                    replaced: 13994 ... 13996,
                    replacement: ["end-r1", "end-r2", "end-r3", "end-r4"],
                    expected: [
                        LineRange(start: 35, end: 45, description: "beginning"),
                        LineRange(start: 2495, end: 2505, description: "middle"),
                        LineRange(start: 13990, end: 14001, description: "end")
                    ]
                )
            ]

            for edit in edits {
                var editedLines = originalLines
                editedLines.replaceSubrange(
                    (edit.replaced.lowerBound - 1) ... (edit.replaced.upperBound - 1),
                    with: edit.replacement
                )
                let editedText = editedLines.joined(separator: "\n") + "\n"
                try await performCanonicalEditAndDrain(
                    text: editedText,
                    expectedRanges: edit.expected,
                    expectedLines: editedLines,
                    caseLabel: edit.name,
                    file: file,
                    fileURL: fileURL,
                    relativePath: relativePath,
                    root: root,
                    store: store,
                    manager: manager
                )
                try await performCanonicalEditAndDrain(
                    text: originalText,
                    expectedRanges: originalRanges,
                    expectedLines: originalLines,
                    caseLabel: edit.name + " restore",
                    file: file,
                    fileURL: fileURL,
                    relativePath: relativePath,
                    root: root,
                    store: store,
                    manager: manager
                )
            }

            let rapidBeforeStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let rapidBeforeStore = try XCTUnwrap(rapidBeforeStoreSnapshot)
            let rapidBeforeProjection = manager.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootID: root.id
            )
            var rapidFirstLines = originalLines
            rapidFirstLines.replaceSubrange(9 ... 10, with: ["rapid-top-1", "rapid-top-2", "rapid-top-3", "rapid-top-4"])
            let rapidFirstText = rapidFirstLines.joined(separator: "\n") + "\n"
            try await store.editFile(rootID: root.id, relativePath: relativePath, newContent: rapidFirstText)
            let rapidFirstDate = try await store.fileModificationDate(rootID: root.id, relativePath: relativePath)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified(relativePath, rapidFirstDate)]
            )

            var rapidFinalLines = rapidFirstLines
            rapidFinalLines.removeSubrange(2496 ... 2506)
            let rapidFinalText = rapidFinalLines.joined(separator: "\n") + "\n"
            try await store.editFile(rootID: root.id, relativePath: relativePath, newContent: rapidFinalText)
            let rapidFinalDate = try await store.fileModificationDate(rootID: root.id, relativePath: relativePath)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified(relativePath, rapidFinalDate)]
            )
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileURL.path,
                fallbackScope: .visibleWorkspace
            )
            let rapidAfterStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let rapidAfterStore = try XCTUnwrap(rapidAfterStoreSnapshot)
            XCTAssertEqual(
                rapidAfterStore.producedAppliedIndexGeneration - rapidBeforeStore.producedAppliedIndexGeneration,
                4,
                "rapid successor edits must retain canonical store and watcher publications per edit"
            )
            let rapidCaughtUp = await manager.debugWaitForAppliedIndexGeneration(
                rootID: root.id,
                targetGeneration: rapidAfterStore.producedAppliedIndexGeneration,
                deadline: ContinuousClock().now.advanced(by: .seconds(5))
            )
            XCTAssertTrue(rapidCaughtUp)
            let rapidFence = await manager.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [fileURL.path]
            )
            XCTAssertTrue(manager.isSliceRebaseFenceCurrent(rapidFence))
            let rapidAfterProjection = manager.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootID: root.id
            )
            XCTAssertEqual(rapidAfterProjection.handledGeneration - rapidBeforeProjection.handledGeneration, 4)
            XCTAssertEqual(rapidAfterProjection.registrationGeneration - rapidBeforeProjection.registrationGeneration, 4)
            let rapidExpected = [
                LineRange(start: 37, end: 47, description: "beginning"),
                LineRange(start: 2497, end: 2497, description: "middle"),
                LineRange(start: 13981, end: 13991, description: "end")
            ]
            let rapidStored = try XCTUnwrap(
                manager.currentSlicesByRootForTesting()[root.standardizedFullPath]?[relativePath]
            )
            XCTAssertEqual(rapidStored.ranges, rapidExpected)
            XCTAssertEqual(
                try XCTUnwrap(rapidStored.fileModificationTime),
                rapidFinalDate.timeIntervalSince1970,
                accuracy: 0.000_5
            )
            XCTAssertEqual(manager.getSelectionSlicesSnapshot()[file.id], rapidExpected)
            XCTAssertEqual(manager.snapshotSelection().slices[file.standardizedFullPath], rapidExpected)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), rapidFinalText)

            try await store.editFile(rootID: root.id, relativePath: relativePath, newContent: originalText)
            let rapidRestoreDate = try await store.fileModificationDate(rootID: root.id, relativePath: relativePath)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified(relativePath, rapidRestoreDate)]
            )
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileURL.path,
                fallbackScope: .visibleWorkspace
            )
            let rapidRestoreFence = await manager.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [fileURL.path]
            )
            XCTAssertTrue(manager.isSliceRebaseFenceCurrent(rapidRestoreFence))
            _ = try await manager.setSelectionSlices(
                entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: originalRanges)],
                mode: .set,
                persistWorkspace: false
            )

            var interruptedLines = originalLines
            interruptedLines.replaceSubrange(38 ... 40, with: ["interrupted-r1", "interrupted-r2"])
            try await store.editFile(
                rootID: root.id,
                relativePath: relativePath,
                newContent: interruptedLines.joined(separator: "\n") + "\n"
            )
            try await store.deleteFile(rootID: root.id, relativePath: relativePath)
            _ = try await store.createFile(rootID: root.id, relativePath: relativePath, content: originalText)
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileURL.path,
                fallbackScope: .visibleWorkspace
            )
            let maybeRecreatedStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let recreatedStoreSnapshot = try XCTUnwrap(maybeRecreatedStoreSnapshot)
            let recreatedProjectionCaughtUp = await manager.debugWaitForAppliedIndexGeneration(
                rootID: root.id,
                targetGeneration: recreatedStoreSnapshot.producedAppliedIndexGeneration,
                deadline: ContinuousClock().now.advanced(by: .seconds(5))
            )
            XCTAssertTrue(recreatedProjectionCaughtUp)
            _ = try await manager.setSelectionSlices(
                entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: originalRanges)],
                mode: .set,
                persistWorkspace: false
            )
            let recreatedFile = try XCTUnwrap(manager.findFileByFullPath(fileURL.path))
            XCTAssertNotEqual(recreatedFile.id, file.id)

            var recreatedEditedLines = originalLines
            recreatedEditedLines.replaceSubrange(38 ... 40, with: ["recreated-r1", "recreated-r2", "recreated-r3", "recreated-r4"])
            let recreatedExpected = [
                LineRange(start: 35, end: 46, description: "beginning"),
                LineRange(start: 2496, end: 2506, description: "middle"),
                LineRange(start: 13991, end: 14001, description: "end")
            ]
            try await performCanonicalEditAndDrain(
                text: recreatedEditedLines.joined(separator: "\n") + "\n",
                expectedRanges: recreatedExpected,
                expectedLines: recreatedEditedLines,
                caseLabel: "remove-recreate edit",
                file: recreatedFile,
                fileURL: fileURL,
                relativePath: relativePath,
                root: root,
                store: store,
                manager: manager
            )
            try await performCanonicalEditAndDrain(
                text: originalText,
                expectedRanges: originalRanges,
                expectedLines: originalLines,
                caseLabel: "remove-recreate restore",
                file: recreatedFile,
                fileURL: fileURL,
                relativePath: relativePath,
                root: root,
                store: store,
                manager: manager
            )
        }

        @MainActor
        func testAtomicReplacementWatcherRebases6500LineSlicesForAttachedRoot() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectionSliceAttachedRoot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let relativePath = "Fixtures/SessionWorktree6500.swift"
            let fileURL = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let originalLines = (1 ... 6500).map { String(format: "line-%05d", $0) }
            try (originalLines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: false, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let rootID = root.id
            let attachedPublisherIngress = try await store
                .attachPublisherIngressWithoutStartingWatcherForTesting(rootID: rootID)
            XCTAssertTrue(attachedPublisherIngress)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            manager.setActiveTabID(UUID())
            addTeardownBlock {
                await store.stopWatchingRoot(id: rootID)
                await manager.unloadAllRootFolders()
                try? FileManager.default.removeItem(at: rootURL)
            }

            let originalRanges = [
                LineRange(start: 100, end: 109, description: "beginning"),
                LineRange(start: 3200, end: 3209, description: "middle"),
                LineRange(start: 6400, end: 6409, description: "end")
            ]
            _ = try await manager.setSelectionSlices(
                entries: [WorkspaceFilesViewModel.SelectionSliceInput(path: fileURL.path, ranges: originalRanges)],
                mode: .set,
                persistWorkspace: false
            )
            let maybeOriginalFile = await store.file(rootID: rootID, relativePath: relativePath)
            let originalFile = try XCTUnwrap(maybeOriginalFile)

            var editedLines = originalLines
            editedLines.insert(contentsOf: (1 ... 40).map { "begin-insert-\($0)" }, at: 0)
            editedLines.insert(contentsOf: (1 ... 25).map { "middle-insert-\($0)" }, at: 3039)
            editedLines.removeSubrange(5064 ..< 5084)
            let replacementURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".SessionWorktree6500.swift.atomic-\(UUID().uuidString)")
            try (editedLines.joined(separator: "\n") + "\n").write(
                to: replacementURL,
                atomically: false,
                encoding: .utf8
            )
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: replacementURL)

            let accepted = try await store.acceptWatcherPayloadForTesting(
                rootID: rootID,
                events: [(
                    absolutePath: fileURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed
                            | kFSEventStreamEventFlagItemCreated
                            | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 9_000_000_000_000_000_000
                )]
            )
            XCTAssertNotNil(accepted)
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileURL.path,
                fallbackScope: .visibleWorkspace
            )
            let maybeStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let storeSnapshot = try XCTUnwrap(maybeStoreSnapshot)
            let projectionCaughtUp = await manager.debugWaitForAppliedIndexGeneration(
                rootID: rootID,
                targetGeneration: storeSnapshot.producedAppliedIndexGeneration,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
            XCTAssertTrue(projectionCaughtUp)
            let fence = await manager.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [fileURL.path]
            )
            XCTAssertTrue(manager.isSliceRebaseFenceCurrent(fence))

            let expectedRanges = [
                LineRange(start: 140, end: 149, description: "beginning"),
                LineRange(start: 3265, end: 3274, description: "middle"),
                LineRange(start: 6445, end: 6454, description: "end")
            ]
            let maybeRebasedFile = await store.file(rootID: rootID, relativePath: relativePath)
            let rebasedFile = try XCTUnwrap(maybeRebasedFile)
            XCTAssertEqual(rebasedFile.id, originalFile.id)
            XCTAssertEqual(
                manager.currentSlicesByRootForTesting()[root.standardizedFullPath]?[relativePath]?.ranges,
                expectedRanges
            )
            XCTAssertEqual(manager.snapshotSelection().slices[fileURL.path], expectedRanges)
            XCTAssertEqual(manager.getSelectionSlicesSnapshot()[originalFile.id], expectedRanges)
        }
    #endif

    func testSliceRebaseEqualCacheUsesSavedAnchorFallback() {
        let staleRange = LineRange(start: 2, end: 2, description: "selected")
        let preEditText = "before\nselected\nafter\n"
        let savedAnchors = SliceRebaseEngine.buildAnchors(content: preEditText, ranges: [staleRange])
        let currentText = "inserted\nbefore\nselected\nafter\n"

        let result = SliceRebaseEngine.rebase(
            oldText: currentText,
            newText: currentText,
            oldRanges: [staleRange],
            anchors: savedAnchors
        )

        XCTAssertEqual(result.rebased, [LineRange(start: 3, end: 3, description: "selected")])
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(result.didChange)
        XCTAssertFalse(result.isStale)

        let mismatched = SliceRebaseEngine.rebase(
            oldText: "before\nstale-other\nafter\n",
            newText: currentText,
            oldRanges: [staleRange],
            anchors: savedAnchors
        )
        XCTAssertEqual(mismatched.rebased, [staleRange])
        XCTAssertTrue(mismatched.dropped.isEmpty)
        XCTAssertFalse(mismatched.didChange)
        XCTAssertTrue(mismatched.isStale)

        let unavailable = SliceRebaseEngine.rebase(
            oldText: nil,
            newText: currentText,
            oldRanges: [staleRange],
            anchors: nil
        )
        XCTAssertEqual(unavailable.rebased, [staleRange])
        XCTAssertTrue(unavailable.dropped.isEmpty)
        XCTAssertFalse(unavailable.didChange)
        XCTAssertTrue(unavailable.isStale)

        let twoRanges = [
            LineRange(start: 1, end: 1, description: "first"),
            LineRange(start: 3, end: 3, description: "third")
        ]
        let completeAnchors = SliceRebaseEngine.buildAnchors(content: preEditText, ranges: twoRanges)
        let partialAnchors = SliceRebaseEngine.rebase(
            oldText: preEditText,
            newText: currentText,
            oldRanges: twoRanges,
            anchors: Array(completeAnchors.prefix(1))
        )
        XCTAssertEqual(partialAnchors.rebased, twoRanges)
        XCTAssertTrue(partialAnchors.isStale)

        let disjointAnchors = SliceRebaseEngine.rebase(
            oldText: preEditText,
            newText: currentText,
            oldRanges: [staleRange],
            anchors: SliceRebaseEngine.buildAnchors(
                content: preEditText,
                ranges: [LineRange(start: 1, end: 1, description: "other")]
            )
        )
        XCTAssertEqual(disjointAnchors.rebased, [staleRange])
        XCTAssertTrue(disjointAnchors.isStale)
    }

    #if DEBUG
        @MainActor
        private func performCanonicalEditAndDrain(
            text: String,
            expectedRanges: [LineRange],
            expectedLines: [String],
            caseLabel: String,
            file: FileViewModel,
            fileURL: URL,
            relativePath: String,
            root: WorkspaceRootRecord,
            store: WorkspaceFileContextStore,
            manager: WorkspaceFilesViewModel
        ) async throws {
            let beforeStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let beforeStore = try XCTUnwrap(beforeStoreSnapshot, caseLabel)
            let beforeProjection = manager.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootID: root.id
            )

            try await store.editFile(rootID: root.id, relativePath: relativePath, newContent: text)
            let modificationDate = try await store.fileModificationDate(rootID: root.id, relativePath: relativePath)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified(relativePath, modificationDate)]
            )
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: fileURL.path,
                fallbackScope: .visibleWorkspace
            )

            let afterStoreSnapshot = await store.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootScope: .visibleWorkspace
            )
            let afterStore = try XCTUnwrap(afterStoreSnapshot, caseLabel)
            XCTAssertEqual(
                afterStore.producedAppliedIndexGeneration - beforeStore.producedAppliedIndexGeneration,
                2,
                caseLabel + " must retain canonical store and watcher publications"
            )
            let caughtUp = await manager.debugWaitForAppliedIndexGeneration(
                rootID: root.id,
                targetGeneration: afterStore.producedAppliedIndexGeneration,
                deadline: ContinuousClock().now.advanced(by: .seconds(5))
            )
            XCTAssertTrue(caughtUp, caseLabel)
            let fence = await manager.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [fileURL.path]
            )
            XCTAssertTrue(manager.isSliceRebaseFenceCurrent(fence), caseLabel)

            let afterProjection = manager.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: fileURL.path,
                rootID: root.id
            )
            XCTAssertEqual(
                afterProjection.handledGeneration - beforeProjection.handledGeneration,
                2,
                caseLabel + " handled-generation count changed"
            )
            XCTAssertEqual(
                afterProjection.registrationGeneration - beforeProjection.registrationGeneration,
                2,
                caseLabel + " rebase registration count changed"
            )
            XCTAssertFalse(afterProjection.hasPendingRebaseTask, caseLabel)

            let persisted = manager.currentSlicesByRootForTesting()[root.standardizedFullPath]?[relativePath]?.ranges
            XCTAssertEqual(persisted, expectedRanges, caseLabel)
            XCTAssertEqual(manager.getSelectionSlicesSnapshot()[file.id], expectedRanges, caseLabel)
            XCTAssertEqual(manager.snapshotSelection().slices[file.standardizedFullPath], expectedRanges, caseLabel)

            let diskText = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertEqual(diskText, text, caseLabel)
            XCTAssertEqual(diskText.split(separator: "\n", omittingEmptySubsequences: false).count - 1, expectedLines.count, caseLabel)
            for range in expectedRanges {
                XCTAssertGreaterThanOrEqual(range.start, 1, caseLabel)
                XCTAssertLessThanOrEqual(range.end, expectedLines.count, caseLabel)
                XCTAssertLessThanOrEqual(range.start, range.end, caseLabel)
                let extracted = Array(expectedLines[(range.start - 1) ... (range.end - 1)])
                XCTAssertFalse(extracted.isEmpty, caseLabel)
            }
        }
    #endif
}

#if DEBUG
    private final class SelectionSliceTestSemaphore: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func signal() {
            semaphore.signal()
        }

        func wait() {
            semaphore.wait()
        }
    }

    private actor SelectionSliceOneShotMutation {
        private var available = true

        func take() -> Bool {
            guard available else { return false }
            available = false
            return true
        }
    }
#endif
