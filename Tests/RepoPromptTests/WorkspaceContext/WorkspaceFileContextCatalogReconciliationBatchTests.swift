import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptFoundation
import XCTest

final class WorkspaceFileContextCatalogReconciliationBatchTests: XCTestCase {
    func testReconciliationScansBeyondServiceBatchLimit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogReconciliationBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for index in 0 ..< 260 {
            let folder = rootURL.appendingPathComponent(String(format: "folder-%03d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try "initial\n".write(
                to: folder.appendingPathComponent("marker.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let tailPath = "folder-259/new.swift"
        try "struct NewlyFound {}\n".write(
            to: rootURL.appendingPathComponent(tailPath),
            atomically: true,
            encoding: .utf8
        )

        let deltas = await store.reconcileLoadedRootCatalogWithDisk(rootID: root.id)
        XCTAssertTrue(deltas.contains(.fileAdded(tailPath)))
        let cataloged = await store.file(rootID: root.id, relativePath: tailPath)
        XCTAssertNotNil(cataloged)
    }
}

@MainActor
final class CatalogFileExtensionInventoryTests: XCTestCase {
    func testHeavyRecountUsesAllLoadedLanguageInventoryWithoutEnumeratingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let primaryURL = directory.appendingPathComponent("primary")
        let hiddenURL = directory.appendingPathComponent("hidden")
        for url in [primaryURL, hiddenURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in ["main.SWIFT", "script.py", "README", "unknown.zzz"] {
            try "fixture".write(to: primaryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in ["app.ts", "more.py"] {
            try "fixture".write(to: hiddenURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let primary = try await store.loadRoot(path: primaryURL.path)
        let hidden = try await store.loadRoot(path: hiddenURL.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: primary.id)
            await store.unloadRoot(id: hidden.id)
            try? FileManager.default.removeItem(at: directory)
        }
        // Capture the previous implementation's result before resetting counters.
        let primaryFiles = await store.files(inRoot: primary.id)
        let hiddenFiles = await store.files(inRoot: hidden.id)
        let expectedLanguages = Set((primaryFiles + hiddenFiles).compactMap {
            SyntaxManager.shared.extensionToLanguage[($0.name as NSString).pathExtension.lowercased()]
        })
        XCTAssertFalse(expectedLanguages.isEmpty)
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let git = GitViewModel(fileManager: manager, gitContextRefreshIntervalNanoseconds: 0)
        let counter = TokenCountingViewModel()
        counter.suspendAutomaticRecounts()
        counter.configure(
            fileManager: manager,
            gitViewModel: git,
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: { .init(fileTreeOption: .none, codeMapUsage: .none, filePathDisplayOption: .relative, includeFilesInClipboard: false, duplicateUserInstructionsAtTop: false, onlyIncludeRootsWithSelectedFiles: false, codeMapsGloballyDisabled: true) },
            getCopyContext: { .init(includeFiles: false, includeUserPrompt: false, includeMetaPrompts: false, includeFileTree: false, fileTreeMode: .none, codeMapUsage: .none, gitInclusion: .none, duplicateUserInstructionsAtTop: false) },
            getStoredSelection: { StoredSelection() }
        )
        await store.resetFilesInRootRequestCountForTesting()
        await counter.forceImmediateRecount()
        XCTAssertEqual(counter.scannedLanguages, expectedLanguages)
        let enumerations = await store.fileEnumerationRequestCountForTesting()
        XCTAssertEqual(enumerations, 0)
        let extensions = await store.allLoadedFileExtensions()
        XCTAssertEqual(extensions, ["swift", "py", "ts", "", "zzz"])
    }

    func testManagedOnlyFileStaysExcludedAcrossRepeatedAddsAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "*.toml\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let before = await store.allLoadedFileExtensions()
        try "fixture".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "config.toml")
        let managed = await store.allLoadedFileExtensions()
        XCTAssertEqual(managed, before)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileAdded("config.toml")])
        // Ignored add events are rejected by the existing catalog preflight;
        // exact managed-only materialization must not become discovery.
        let afterAdd = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterAdd, before)
        let discoverable = await store.files(inRoot: root.id)
        XCTAssertFalse(discoverable.contains { $0.name == "config.toml" })
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileRemoved("config.toml")])
        let removed = await store.allLoadedFileExtensions()
        XCTAssertEqual(removed, before)
    }

    func testInventoryTracksUpsertsLastExtensionRemovalAndRootUnload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["first.swift", "second.swift", "nested/script.py"] {
            try "fixture".write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        try "fixture".write(to: directory.appendingPathComponent("new.rs"), atomically: true, encoding: .utf8)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileAdded("first.swift"), .fileAdded("new.rs"), .fileRemoved("second.swift")])
        let afterUpsert = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterUpsert, ["swift", "py", "rs"])
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileRemoved("first.swift"), .folderRemoved("nested")])
        let afterRemoval = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterRemoval, ["rs"])
        await store.unloadRoot(id: root.id)
        let afterUnload = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterUnload, [])
    }
}

final class CatalogBulkAddPerformanceTests: XCTestCase {
    func testOrderedFolderRecreationAndExistingAddsPreserveCanonicalEventShape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.applyIndexDeltasWithFakeDiskForTesting(rootID: root.id, deltas: [.fileAdded("parent/old.swift")])
        let oldFileValue = await store.file(rootID: root.id, relativePath: "parent/old.swift")
        let oldFile = try XCTUnwrap(oldFileValue)
        let oldFolderValue = await store.folder(rootID: root.id, relativePath: "parent")
        let oldFolder = try XCTUnwrap(oldFolderValue)
        let events = await store.appliedIndexEvents()
        var iterator = events.makeAsyncIterator()
        try await store.applyIndexDeltasWithFakeDiskForTesting(rootID: root.id, deltas: [
            .fileAdded("parent/old.swift"), .folderRemoved("parent"),
            .fileAdded("parent/new.swift"), .fileAdded("parent/another.swift"),
            .folderAdded("more/nested"), .fileAdded("more/nested/last.swift")
        ])
        let eventValue = await iterator.next()
        let event = try XCTUnwrap(eventValue)
        let snapshotValue = await store.appliedIndexRootSnapshot(rootID: root.id)
        let snapshot = try XCTUnwrap(snapshotValue)
        let folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.standardizedRelativePath, $0) })
        let parent = try XCTUnwrap(folders["parent"])
        let more = try XCTUnwrap(folders["more"])
        let nested = try XCTUnwrap(folders["more/nested"])
        XCTAssertNotEqual(parent.id, oldFolder.id)
        XCTAssertEqual(event.upsertedFiles, (snapshot.files + [oldFile]).sorted { $0.standardizedRelativePath < $1.standardizedRelativePath })
        XCTAssertEqual(event.upsertedFolders, [oldFolder, parent, parent, parent, nested, more, nested].sorted { $0.standardizedRelativePath < $1.standardizedRelativePath })
        XCTAssertEqual(event.removedFileIDs, [oldFile.id])
        XCTAssertEqual(event.removedFolderIDs, [oldFolder.id])
        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["more/nested/last.swift", "parent/another.swift", "parent/new.swift"])
    }

    func testBulkAddPublicationPreservesIndexesAndEventsWithinBudget() async throws {
        let smaller = try await measureBulkAddPublication(fileCount: 10000)
        let larger = try await measureBulkAddPublication(fileCount: 20000)
        // Double files and folders together: linear work grows 2x and event sorting
        // about 2.2x. Allow 2.5x, but reject near-quadratic 4x growth without
        // depending on the shared runner's absolute speed.
        XCTAssertLessThanOrEqual(larger, smaller * 2.5)
    }

    private func measureBulkAddPublication(fileCount: Int) async throws -> Duration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let folderCount = fileCount / 20
        let folderPaths = (0 ..< folderCount).map { "folder-\($0)" }
        try await store.applyIndexDeltasWithFakeDiskForTesting(rootID: root.id, deltas: folderPaths.map(FileSystemDelta.folderAdded))
        let beforeValue = await store.appliedIndexRootSnapshot(rootID: root.id)
        let before = try XCTUnwrap(beforeValue)
        let lifetime = try await store.rootLifetimeIDForTesting(rootID: root.id)
        let events = await store.appliedIndexEvents()
        var iterator = events.makeAsyncIterator()
        let filePaths = (0 ..< fileCount).map { "folder-\($0 % folderCount)/child/file-\($0).swift" }
        let deltas = filePaths.map(FileSystemDelta.fileAdded)
        let start = ContinuousClock.now
        try await store.applyIndexDeltasWithFakeDiskForTesting(rootID: root.id, deltas: deltas)
        let elapsed = start.duration(to: .now)
        print("CATALOG_BULK_ADD files=\(fileCount) existingFolders=\(folderCount) newFolders=\(folderCount) duration=\(elapsed)")

        let eventValue = await iterator.next()
        let event = try XCTUnwrap(eventValue)
        let afterValue = await store.appliedIndexRootSnapshot(rootID: root.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.files.map(\.standardizedRelativePath), filePaths.sorted())
        XCTAssertEqual(after.folders.count, before.folders.count + folderCount)
        let foldersByPath = Dictionary(uniqueKeysWithValues: after.folders.map { ($0.standardizedRelativePath, $0) })
        for folder in before.folders {
            XCTAssertEqual(foldersByPath[folder.standardizedRelativePath], folder)
        }
        // Existing behavior emits every discoverable ancestor per file, plus each
        // newly indexed ancestor on its first add. Preserve that exact multiplicity.
        let expectedFolderPaths = filePaths.flatMap { path -> [String] in
            let child = (path as NSString).deletingLastPathComponent
            return [child, (child as NSString).deletingLastPathComponent]
        } + folderPaths.map { "\($0)/child" }
        let expectedFolders = try expectedFolderPaths.sorted().map { try XCTUnwrap(foldersByPath[$0]) }
        XCTAssertEqual(event, WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.standardizedFullPath,
            generation: before.generation + 1,
            rootLifetimeID: lifetime,
            upsertedFiles: after.files,
            upsertedFolders: expectedFolders
        ))
        let lookup = await store.appliedIndexRecordLookup(rootID: root.id, fileIDs: after.files.map(\.id), folderIDs: after.folders.map(\.id))
        XCTAssertEqual(lookup?.filesByID, Dictionary(uniqueKeysWithValues: after.files.map { ($0.id, $0) }))
        XCTAssertEqual(lookup?.foldersByID, Dictionary(uniqueKeysWithValues: after.folders.map { ($0.id, $0) }))

        let first = try XCTUnwrap(after.files.first)
        try await store.applyIndexDeltasWithFakeDiskForTesting(rootID: root.id, deltas: [.fileAdded(first.standardizedRelativePath)])
        let upsertValue = await iterator.next()
        let upsert = try XCTUnwrap(upsertValue)
        XCTAssertEqual(upsert.upsertedFiles, [first], "Repeated adds reconcile to the existing canonical ID")
        let parent = (first.standardizedRelativePath as NSString).deletingLastPathComponent
        let ancestorPaths = [parent, (parent as NSString).deletingLastPathComponent].sorted()
        XCTAssertEqual(upsert.upsertedFolders, try ancestorPaths.map { try XCTUnwrap(foldersByPath[$0]) })
        return elapsed
    }
}
