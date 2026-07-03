@testable import RepoPrompt
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceFilesAppliedIndexProjectionTests: XCTestCase {
        private var temporaryRoots = FileSystemTemporaryRoots()

        override func tearDownWithError() throws {
            temporaryRoots.removeAll()
            try super.tearDownWithError()
        }

        func testIncrementalTopologyDeltasMaintainIndexWithoutHierarchyRebuild() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexIncrementalTopology")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            var folderIDs: [String: UUID] = [:]
            func folderRecord(_ relativePath: String) -> WorkspaceFolderRecord {
                let id = UUID()
                folderIDs[relativePath] = id
                let parentRelativePath = StandardizedPath.relative(
                    (relativePath as NSString).deletingLastPathComponent
                )
                return WorkspaceFolderRecord(
                    id: id,
                    rootID: root.id,
                    name: (relativePath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    fullPath: rootURL.appendingPathComponent(relativePath, isDirectory: true).path,
                    parentFolderID: parentRelativePath.isEmpty ? root.id : folderIDs[parentRelativePath],
                    modificationDate: Date(timeIntervalSince1970: 100)
                )
            }
            func fileRecord(_ relativePath: String, parentRelativePath: String) -> WorkspaceFileRecord {
                WorkspaceFileRecord(
                    id: UUID(),
                    rootID: root.id,
                    name: (relativePath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    fullPath: rootURL.appendingPathComponent(relativePath).path,
                    parentFolderID: folderIDs[parentRelativePath] ?? root.id,
                    modificationDate: Date(timeIntervalSince1970: 200)
                )
            }

            var folders: [WorkspaceFolderRecord] = []
            var files: [WorkspaceFileRecord] = []
            for moduleIndex in 0 ..< 24 {
                let module = "Module\(moduleIndex)"
                folders.append(folderRecord(module))
                for fileIndex in 0 ..< 4 {
                    files.append(fileRecord("\(module)/File\(fileIndex).swift", parentRelativePath: module))
                }
            }
            let removedFolder = folderRecord("RemoveMe")
            folders.append(removedFolder)
            let removedFolderFile = fileRecord("RemoveMe/Old.swift", parentRelativePath: "RemoveMe")
            files.append(removedFolderFile)
            let removedFile = files[3]
            let retainedFile = files[8]

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: files,
                upsertedFolders: folders
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount

            let addedFolder = folderRecord("Added")
            let addedFile = fileRecord("Added/New.swift", parentRelativePath: "Added")
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                upsertedFiles: [addedFile],
                upsertedFolders: [addedFolder],
                removedFilePaths: [removedFile.standardizedRelativePath],
                removedFolderPaths: [removedFolder.standardizedRelativePath]
            ))

            var index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount,
                baselineRebuildCount
            )
            XCTAssertEqual(index.filePathsByID[addedFile.id], addedFile.standardizedFullPath)
            XCTAssertEqual(index.fileIDsByPath[addedFile.standardizedFullPath], addedFile.id)
            XCTAssertEqual(index.filePathsByID[retainedFile.id], retainedFile.standardizedFullPath)
            XCTAssertEqual(index.fileIDsByPath[retainedFile.standardizedFullPath], retainedFile.id)
            XCTAssertNil(index.filePathsByID[removedFile.id])
            XCTAssertNil(index.fileIDsByPath[removedFile.standardizedFullPath])
            XCTAssertNil(index.folderPathsByID[removedFolder.id])
            XCTAssertNil(index.folderIDsByPath[removedFolder.standardizedFullPath])
            XCTAssertNil(index.filePathsByID[removedFolderFile.id])
            XCTAssertNil(index.fileIDsByPath[removedFolderFile.standardizedFullPath])

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 3,
                modifiedFileIDs: [retainedFile.id]
            ))
            index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount,
                baselineRebuildCount
            )
            XCTAssertEqual(index.filePathsByID[retainedFile.id], retainedFile.standardizedFullPath)
            XCTAssertEqual(index.fileIDsByPath[retainedFile.standardizedFullPath], retainedFile.id)

            await manager.unloadAllRootFolders()
        }

        func testRemovedSubtreeCleanupMismatchFallsBackToHierarchyRebuild() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexCleanupMismatch")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            let folderID = UUID()
            let folder = WorkspaceFolderRecord(
                id: folderID,
                rootID: root.id,
                name: "Victim",
                relativePath: "Victim",
                fullPath: rootURL.appendingPathComponent("Victim", isDirectory: true).path,
                parentFolderID: root.id
            )
            let file = WorkspaceFileRecord(
                id: UUID(),
                rootID: root.id,
                name: "KeptOnlyInTree.swift",
                relativePath: "Victim/KeptOnlyInTree.swift",
                fullPath: rootURL.appendingPathComponent("Victim/KeptOnlyInTree.swift").path,
                parentFolderID: folderID
            )
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [file],
                upsertedFolders: [folder]
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount

            let stalePath = rootURL.appendingPathComponent("Victim/StaleIndexedOnly.swift").path
            let staleFile = FileViewModel(
                file: File(name: "StaleIndexedOnly.swift", path: stalePath, modificationDate: Date()),
                rootPath: root.standardizedFullPath,
                rootIdentifier: root.id,
                rootFolderPath: root.standardizedFullPath,
                fileSystemService: nil
            )
            manager.injectIndexedFileForTesting(staleFile)

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                removedFolderPaths: [folder.standardizedRelativePath]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount,
                baselineRebuildCount + 1
            )
            XCTAssertNil(index.folderPathsByID[folderID])
            XCTAssertNil(index.folderIDsByPath[folder.standardizedFullPath])
            XCTAssertNil(index.filePathsByID[file.id])
            XCTAssertNil(index.fileIDsByPath[file.standardizedFullPath])
            XCTAssertNil(index.fileIDsByPath[staleFile.standardizedFullPath])

            await manager.unloadAllRootFolders()
        }

        func testRemovedFolderIndexMismatchFallsBackToHierarchyRebuild() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexMissingSubtreeMismatch")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount

            let staleFolderPath = rootURL.appendingPathComponent("IndexedOnly", isDirectory: true).path
            let staleFolder = FolderViewModel(
                folder: Folder(name: "IndexedOnly", path: staleFolderPath, modificationDate: Date()),
                rootPath: root.standardizedFullPath
            )
            manager.injectIndexedFolderForTesting(staleFolder)

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                removedFolderPaths: ["IndexedOnly"]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount,
                baselineRebuildCount + 1
            )
            XCTAssertNil(index.folderPathsByID[staleFolder.id])
            XCTAssertNil(index.folderIDsByPath[staleFolder.standardizedFullPath])
            XCTAssertEqual(index.folderPathsByID[root.id], root.standardizedFullPath)

            await manager.unloadAllRootFolders()
        }

        func testRemovedFolderDescendantFileIndexMismatchFallsBackToHierarchyRebuild() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexDescendantFileMismatch")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount

            let staleFilePath = rootURL.appendingPathComponent("IndexedOnly/Stale.swift").path
            let staleFile = FileViewModel(
                file: File(name: "Stale.swift", path: staleFilePath, modificationDate: Date()),
                rootPath: root.standardizedFullPath,
                rootIdentifier: root.id,
                rootFolderPath: root.standardizedFullPath,
                fileSystemService: nil
            )
            manager.injectIndexedFileForTesting(staleFile)

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                removedFolderPaths: ["IndexedOnly"]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount,
                baselineRebuildCount + 1
            )
            XCTAssertNil(index.filePathsByID[staleFile.id])
            XCTAssertNil(index.fileIDsByPath[staleFile.standardizedFullPath])
            XCTAssertEqual(index.folderPathsByID[root.id], root.standardizedFullPath)

            await manager.unloadAllRootFolders()
        }

        func testModifiedIDsUseDirectIndexesAndTopologyRemovalClearsUUIDMaps() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexDirectIDs")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            let folderURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("A.swift")
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try "struct A {}".write(to: fileURL, atomically: true, encoding: .utf8)

            let folderID = UUID()
            let fileID = UUID()
            let folder = WorkspaceFolderRecord(
                id: folderID,
                rootID: root.id,
                name: "Sources",
                relativePath: "Sources",
                fullPath: folderURL.path,
                parentFolderID: root.id,
                modificationDate: Date(timeIntervalSince1970: 10)
            )
            let file = WorkspaceFileRecord(
                id: fileID,
                rootID: root.id,
                name: "A.swift",
                relativePath: "Sources/A.swift",
                fullPath: fileURL.path,
                parentFolderID: folderID,
                modificationDate: Date(timeIntervalSince1970: 20)
            )

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [file],
                upsertedFolders: [folder]
            ))

            var index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.filePathsByID[fileID], file.standardizedFullPath)
            XCTAssertEqual(index.folderPathsByID[folderID], folder.standardizedFullPath)
            XCTAssertEqual(index.fileIDsByPath[file.standardizedFullPath], fileID)
            XCTAssertEqual(index.folderIDsByPath[folder.standardizedFullPath], folderID)

            manager.resetAppliedIndexProjectionLookupDiagnosticsForTesting()
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                modifiedFileIDs: [fileID],
                modifiedFolderIDs: [folderID]
            ))

            let lookupDiagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(lookupDiagnostics.directFileIDLookupCount, 1)
            XCTAssertEqual(lookupDiagnostics.directFolderIDLookupCount, 1)
            XCTAssertEqual(lookupDiagnostics.directIDLookupMissCount, 0)
            XCTAssertEqual(lookupDiagnostics.handledGenerationByRootID[root.id], 2)

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 3,
                removedFolderIDs: [folderID]
            ))

            index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertNil(index.filePathsByID[fileID])
            XCTAssertNil(index.folderPathsByID[folderID])
            XCTAssertNil(index.fileIDsByPath[file.standardizedFullPath])
            XCTAssertNil(index.folderIDsByPath[folder.standardizedFullPath])
            XCTAssertEqual(index.folderPathsByID[root.id], root.standardizedFullPath)

            await manager.unloadAllRootFolders()
        }

        func testContiguousModifiedIDsSkipCanonicalRecordsThatAreNotProjected() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexLazyModification")
            let folderURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("A.swift")
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try "let stale = true".write(to: fileURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let freshDate = Date(timeIntervalSince1970: 1_700_000_100)
            try "let fresh = true".write(to: fileURL, atomically: true, encoding: .utf8)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [
                    .fileModified("Sources/A.swift", freshDate),
                    .folderModified("Sources", freshDate)
                ]
            )
            let canonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let canonical = try XCTUnwrap(canonicalValue)
            let canonicalFile = try XCTUnwrap(canonical.files.first { $0.standardizedRelativePath == "Sources/A.swift" })
            let canonicalFolder = try XCTUnwrap(canonical.folders.first { $0.standardizedRelativePath == "Sources" })

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            manager.resetAppliedIndexProjectionLookupDiagnosticsForTesting()

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: canonical.generation,
                modifiedFileIDs: [canonicalFile.id],
                modifiedFolderIDs: [canonicalFolder.id]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertNil(index.filePathsByID[canonicalFile.id])
            XCTAssertNil(index.folderPathsByID[canonicalFolder.id])
            XCTAssertNil(index.fileIDsByPath[canonicalFile.standardizedFullPath])
            XCTAssertNil(index.folderIDsByPath[canonicalFolder.standardizedFullPath])
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.directFileIDLookupCount, 1)
            XCTAssertEqual(diagnostics.directFolderIDLookupCount, 1)
            XCTAssertEqual(diagnostics.directIDLookupMissCount, 2)
            XCTAssertEqual(diagnostics.canonicalResyncCount, 0)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], canonical.generation)
            await manager.unloadAllRootFolders()
        }

        func testContiguousModifiedIDPathConflictRequiresCanonicalResync() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexModificationConflict")
            let folderURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("A.swift")
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try "let value = 0".write(to: fileURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified("Sources/A.swift", Date(timeIntervalSince1970: 10))]
            )
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified("Sources/A.swift", Date(timeIntervalSince1970: 20))]
            )
            let canonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let canonical = try XCTUnwrap(canonicalValue)
            let canonicalFile = try XCTUnwrap(canonical.files.first { $0.standardizedRelativePath == "Sources/A.swift" })
            let canonicalFolder = try XCTUnwrap(canonical.folders.first { $0.standardizedRelativePath == "Sources" })
            XCTAssertEqual(canonical.generation, 2)

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            let conflictingFolderID = UUID()
            let conflictingFileID = UUID()
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [
                    WorkspaceFileRecord(
                        id: conflictingFileID,
                        rootID: root.id,
                        name: "A.swift",
                        relativePath: "Sources/A.swift",
                        fullPath: fileURL.path,
                        parentFolderID: conflictingFolderID
                    )
                ],
                upsertedFolders: [
                    WorkspaceFolderRecord(
                        id: conflictingFolderID,
                        rootID: root.id,
                        name: "Sources",
                        relativePath: "Sources",
                        fullPath: folderURL.path,
                        parentFolderID: root.id
                    )
                ]
            ))
            manager.resetAppliedIndexProjectionLookupDiagnosticsForTesting()

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: canonical.generation,
                modifiedFileIDs: [canonicalFile.id],
                modifiedFolderIDs: [canonicalFolder.id]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.filePathsByID[canonicalFile.id], canonicalFile.standardizedFullPath)
            XCTAssertEqual(index.folderPathsByID[canonicalFolder.id], canonicalFolder.standardizedFullPath)
            XCTAssertNil(index.filePathsByID[conflictingFileID])
            XCTAssertNil(index.folderPathsByID[conflictingFolderID])
            XCTAssertEqual(index.fileIDsByPath[canonicalFile.standardizedFullPath], canonicalFile.id)
            XCTAssertEqual(index.folderIDsByPath[canonicalFolder.standardizedFullPath], canonicalFolder.id)
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.directFileIDLookupCount, 1)
            XCTAssertEqual(diagnostics.directFolderIDLookupCount, 1)
            XCTAssertEqual(diagnostics.directIDLookupMissCount, 1)
            XCTAssertEqual(diagnostics.canonicalResyncCount, 1)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], canonical.generation)
            await manager.unloadAllRootFolders()
        }

        func testContiguousModifiedIDMissingFromCanonicalSnapshotRequiresResync() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexMissingCanonicalModification")
            let fileURL = rootURL.appendingPathComponent("Seed.swift")
            try "let seed = true".write(to: fileURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            await store.replayObservedFileSystemDeltas(
                rootID: root.id,
                deltas: [.fileModified("Seed.swift", Date(timeIntervalSince1970: 30))]
            )
            let canonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let canonical = try XCTUnwrap(canonicalValue)
            let canonicalFile = try XCTUnwrap(canonical.files.first { $0.standardizedRelativePath == "Seed.swift" })

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            manager.resetAppliedIndexProjectionLookupDiagnosticsForTesting()

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: canonical.generation,
                modifiedFileIDs: [UUID()]
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.filePathsByID[canonicalFile.id], canonicalFile.standardizedFullPath)
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.directFileIDLookupCount, 1)
            XCTAssertEqual(diagnostics.directIDLookupMissCount, 1)
            XCTAssertEqual(diagnostics.canonicalResyncCount, 1)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], canonical.generation)
            await manager.unloadAllRootFolders()
        }

        func testFullResyncDiffPreservesUnchangedLoadedFileState() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexDiffedResync")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let keepURL = rootURL.appendingPathComponent("Keep.swift")
            try "let keep = true".write(to: keepURL, atomically: true, encoding: .utf8)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Keep.swift")])
            let initialCanonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let initialCanonical = try XCTUnwrap(initialCanonicalValue)
            let keepRecord = try XCTUnwrap(initialCanonical.files.first { $0.standardizedRelativePath == "Keep.swift" })

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: initialCanonical.generation,
                upsertedFiles: [keepRecord]
            ))
            let keepBefore = try XCTUnwrap(manager.appliedIndexProjectedFileForTesting(id: keepRecord.id))
            let keepContent = await keepBefore.latestContent
            XCTAssertEqual(keepContent, "let keep = true")
            guard case .loaded = keepBefore.loadingState else {
                XCTFail("Expected unchanged file content to be loaded before resync")
                await manager.unloadAllRootFolders()
                return
            }

            let addedURL = rootURL.appendingPathComponent("Added.swift")
            try "let added = true".write(to: addedURL, atomically: true, encoding: .utf8)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Added.swift")])
            let latestCanonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let latestCanonical = try XCTUnwrap(latestCanonicalValue)
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: latestCanonical.generation,
                requiresFullResync: true
            ))

            let keepAfter = try XCTUnwrap(manager.appliedIndexProjectedFileForTesting(id: keepRecord.id))
            XCTAssertTrue(keepAfter === keepBefore)
            guard case .loaded = keepAfter.loadingState else {
                XCTFail("Diffed resync must not invalidate unchanged loaded files")
                await manager.unloadAllRootFolders()
                return
            }
            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            let addedRecord = try XCTUnwrap(latestCanonical.files.first { $0.standardizedRelativePath == "Added.swift" })
            XCTAssertEqual(index.filePathsByID[addedRecord.id], addedRecord.standardizedFullPath)
            XCTAssertEqual(
                manager.appliedIndexProjectionDiagnosticsSnapshot().handledGenerationByRootID[root.id],
                latestCanonical.generation
            )
            await manager.unloadAllRootFolders()
        }

        func testStaleAndSamePathWrongRootEventsCannotMutateCurrentProjection() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexStaleRoot")
            let fileURL = rootURL.appendingPathComponent("Keep.swift")
            try "let keep = true".write(to: fileURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            let fileID = UUID()
            let file = WorkspaceFileRecord(
                id: fileID,
                rootID: root.id,
                name: "Keep.swift",
                relativePath: "Keep.swift",
                fullPath: fileURL.path,
                parentFolderID: root.id
            )
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [file]
            ))

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 0,
                removedFileIDs: [fileID],
                removedFilePaths: ["Keep.swift"]
            ))
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: UUID(),
                rootPath: root.standardizedFullPath,
                generation: 2,
                removedFilePaths: ["Keep.swift"],
                isRootUnload: true
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.filePathsByID[fileID], file.standardizedFullPath)
            XCTAssertEqual(index.folderPathsByID[root.id], root.standardizedFullPath)
            XCTAssertEqual(manager.rootFolders.map(\.id), [root.id])
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.handledEventCount, 1)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], 1)

            await manager.unloadAllRootFolders()
        }

        func testFullResyncUsesCanonicalSnapshotAndAdvancesToSnapshotGeneration() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexCanonicalResync")
            try "seed".write(
                to: rootURL.appendingPathComponent("Seed.swift"),
                atomically: true,
                encoding: .utf8
            )

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            for name in ["One.swift", "Two.swift", "Three.swift"] {
                try name.write(
                    to: rootURL.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
                await store.replayObservedFileSystemDeltas(
                    rootID: root.id,
                    deltas: [.fileAdded(name)]
                )
            }
            let canonicalSnapshot = await store.appliedIndexRootSnapshot(rootID: root.id)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            XCTAssertEqual(canonical.generation, 3)

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            let ghostFolderID = UUID()
            let ghostFileID = UUID()
            let ghostFolderPath = rootURL.appendingPathComponent("Ghost", isDirectory: true).path
            let ghostFilePath = rootURL.appendingPathComponent("Ghost/Only.swift").path
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [
                    WorkspaceFileRecord(
                        id: ghostFileID,
                        rootID: root.id,
                        name: "Only.swift",
                        relativePath: "Ghost/Only.swift",
                        fullPath: ghostFilePath,
                        parentFolderID: ghostFolderID
                    )
                ],
                upsertedFolders: [
                    WorkspaceFolderRecord(
                        id: ghostFolderID,
                        rootID: root.id,
                        name: "Ghost",
                        relativePath: "Ghost",
                        fullPath: ghostFolderPath,
                        parentFolderID: root.id
                    )
                ]
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                requiresFullResync: true
            ))

            var index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertNil(index.filePathsByID[ghostFileID])
            XCTAssertNil(index.folderPathsByID[ghostFolderID])
            XCTAssertNil(index.fileIDsByPath[StandardizedPath.absolute(ghostFilePath)])
            XCTAssertNil(index.folderIDsByPath[StandardizedPath.absolute(ghostFolderPath)])
            for file in canonical.files {
                XCTAssertEqual(index.filePathsByID[file.id], file.standardizedFullPath)
                XCTAssertEqual(index.fileIDsByPath[file.standardizedFullPath], file.id)
            }
            for folder in canonical.folders where !folder.standardizedRelativePath.isEmpty {
                XCTAssertEqual(index.folderPathsByID[folder.id], folder.standardizedFullPath)
                XCTAssertEqual(index.folderIDsByPath[folder.standardizedFullPath], folder.id)
            }
            var diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.canonicalResyncCount, 1)
            XCTAssertGreaterThan(diagnostics.indexRebuildCount, baselineRebuildCount)
            XCTAssertEqual(diagnostics.handledEventCount, 2)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], canonical.generation)

            let canonicalFile = try XCTUnwrap(canonical.files.first)
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: canonical.generation,
                removedFileIDs: [canonicalFile.id],
                removedFilePaths: [canonicalFile.standardizedRelativePath]
            ))
            index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.filePathsByID[canonicalFile.id], canonicalFile.standardizedFullPath)
            diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.handledEventCount, 2)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], canonical.generation)

            await manager.unloadAllRootFolders()
        }

        func testGenerationGapResyncUsesLatestCanonicalSnapshot() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexGenerationGap")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            for name in ["One.swift", "Two.swift", "Three.swift"] {
                try name.write(
                    to: rootURL.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(name)])
            }
            let canonicalValue = await store.appliedIndexRootSnapshot(rootID: root.id)
            let canonical = try XCTUnwrap(canonicalValue)
            XCTAssertEqual(canonical.generation, 3)

            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1
            ))
            let baselineRebuildCount = manager.appliedIndexProjectionDiagnosticsSnapshot().indexRebuildCount
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 3
            ))

            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            for file in canonical.files {
                XCTAssertEqual(index.filePathsByID[file.id], file.standardizedFullPath)
            }
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.canonicalResyncCount, 1)
            XCTAssertGreaterThan(diagnostics.indexRebuildCount, baselineRebuildCount)
            XCTAssertEqual(diagnostics.handledEventCount, 2)
            XCTAssertEqual(diagnostics.handledGenerationByRootID[root.id], 3)

            await manager.unloadAllRootFolders()
        }

        func testHiddenSessionRootEventAdvancesOnlyHiddenConsumerWithoutProjectingRootShell() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexHiddenSessionRoot")
            let fileURL = rootURL.appendingPathComponent("Hidden.swift")
            try "let hidden = true\n".write(to: fileURL, atomically: false, encoding: .utf8)
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path, kind: .sessionWorktree)
            let rootLifetimeID = try await store.rootLifetimeIDForTesting(rootID: root.id)
            let files = await store.files(inRoot: root.id)
            let file = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Hidden.swift" })
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)

            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                rootLifetimeID: rootLifetimeID,
                modifiedFileIDs: [file.id]
            ))

            XCTAssertTrue(manager.rootFolders.isEmpty)
            XCTAssertNil(manager.findFileByFullPath(file.standardizedFullPath))
            let visible = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(visible.handledEventCount, 0)
            XCTAssertNil(visible.handledGenerationByRootID[root.id])
            let hidden = manager.hiddenSessionSliceRebaseDebugSnapshotForTesting(
                fullPath: file.standardizedFullPath,
                rootID: root.id,
                rootLifetimeID: rootLifetimeID
            )
            XCTAssertEqual(hidden.handledGeneration, 1)
            XCTAssertEqual(hidden.registrationGeneration, 0)
            XCTAssertFalse(hidden.hasPendingTask)
            XCTAssertFalse(hidden.hasSourceSnapshot)
            XCTAssertFalse(hidden.hasLifetimeMapping)
        }

        func testValidRootUnloadClearsUUIDPathIndexesAndHandledGeneration() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexValidUnload")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())

            let fileID = UUID()
            let filePath = rootURL.appendingPathComponent("Unload.swift").path
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: [
                    WorkspaceFileRecord(
                        id: fileID,
                        rootID: root.id,
                        name: "Unload.swift",
                        relativePath: "Unload.swift",
                        fullPath: filePath,
                        parentFolderID: root.id
                    )
                ]
            ))
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 2,
                isRootUnload: true
            ))

            XCTAssertTrue(manager.rootFolders.isEmpty)
            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertNil(index.filePathsByID[fileID])
            XCTAssertNil(index.folderPathsByID[root.id])
            XCTAssertNil(index.fileIDsByPath[StandardizedPath.absolute(filePath)])
            XCTAssertNil(index.folderIDsByPath[root.standardizedFullPath])
            let diagnostics = manager.appliedIndexProjectionDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.handledEventCount, 2)
            XCTAssertNil(diagnostics.handledGenerationByRootID[root.id])
        }

        func testOldRootUnloadCannotDetachReplacementAtSamePath() async throws {
            let rootURL = try temporaryRoots.makeRoot(suiteName: "AppliedIndexRootReplacement")
            let store = WorkspaceFileContextStore()
            let oldRoot = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            _ = try manager.attachRootShell(for: oldRoot, workspaceID: UUID())
            let detachedOldRoot = await manager.detachRootShell(forRootPath: rootURL.path, unloadStoreRoot: false)
            XCTAssertTrue(detachedOldRoot)

            let replacement = WorkspaceRootRecord(
                id: UUID(),
                name: oldRoot.name,
                fullPath: oldRoot.fullPath,
                kind: oldRoot.kind
            )
            _ = try manager.attachRootShell(for: replacement, workspaceID: UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: oldRoot.id,
                rootPath: oldRoot.standardizedFullPath,
                generation: 1,
                isRootUnload: true
            ))

            XCTAssertEqual(manager.rootFolders.map(\.id), [replacement.id])
            let index = manager.appliedIndexProjectionIndexSnapshotForTesting()
            XCTAssertEqual(index.folderPathsByID[replacement.id], replacement.standardizedFullPath)
            XCTAssertNil(index.folderPathsByID[oldRoot.id])
            XCTAssertEqual(manager.appliedIndexProjectionDiagnosticsSnapshot().handledEventCount, 0)

            _ = await manager.detachRootShell(forRootPath: replacement.fullPath, unloadStoreRoot: false)
        }
    }
#endif
