@testable import RepoPrompt
import XCTest

@MainActor
final class SelectionSlicePersistenceAndRebaseTests: XCTestCase {
    #if DEBUG

    #endif

    #if DEBUG
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
            await manager.setCodeScanEnabled(false)
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
            await manager.setCodeScanEnabled(false)
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
                    flags: [.itemRenamed, .itemCreated, .itemIsFile],
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

    #if DEBUG
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
