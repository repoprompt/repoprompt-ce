import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import XCTest

final class HiddenSessionSlicePathIndexTests: XCTestCase {
    func testIndexedMatchesPreserveLegacyPathPredicate() {
        let paths = [
            "file.swift", "Sources/file.swift", "file.swift", "Other/file.swift",
            "a//b", "/leading", "", "é.swift", "日本語/名前.swift",
            "nested/trailing/", ".hidden", "./file.swift", "\u{301}name.swift"
        ]
        let files = Dictionary(uniqueKeysWithValues: paths.enumerated().map { (fileID($0.offset), $0.element) })
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = [
            "file.swift", "Sources/file.swift", "/workspace/Sources/file.swift",
            "root@token//Sources/file.swift", "prefixfile.swift", "Sources/file.swift.backup",
            "other/File.swift", "a//b", "root/a//b", "root/a/b",
            "/leading", "root//leading", "root/leading", "", "root/",
            "e\u{301}.swift", "root/日本語/名前.swift", "root/nested/trailing/",
            "root/.hidden", "root/./file.swift", "root/\u{301}name.swift", "missing.swift"
        ]

        for slice in slices {
            let expected = Set(files.compactMap { fileID, relativePath in
                slice == relativePath || slice.hasSuffix("/" + relativePath) ? fileID : nil
            })
            XCTAssertEqual(index.matchingFileIDs(for: [slice]), expected, "Slice: \(slice)")
        }
        XCTAssertTrue(index.matchingFileIDs(for: []).isEmpty)
    }

    func testLargeIndexPreservesDuplicateRelativePathsAcrossRoots() {
        let count = 2048
        var files: [UUID: String] = [:]
        for value in 0 ..< count {
            let path = "Sources/Feature\(value)/File.swift"
            files[fileID(value * 2)] = path
            files[fileID(value * 2 + 1)] = path
        }
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = (0 ..< count).map { "root@token//Sources/Feature\($0)/File.swift" }

        XCTAssertEqual(index.matchingFileIDs(for: slices), Set(files.keys))
        XCTAssertEqual(index.matchingFileIDs(for: [slices[0], slices[0]]), [fileID(0), fileID(1)])
        XCTAssertTrue(index.matchingFileIDs(for: ["root@token//Sources/Feature0/Other.swift"]).isEmpty)
    }

    private func fileID(_ value: Int) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value >> 8), UInt8(value & 255)))
    }
}

@MainActor
final class HiddenSessionAppliedIndexHotPathTests: XCTestCase {
    func testIrrelevantEventsDoNotEnumerateRootRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let ordinary = try await store.loadRoot(path: directory.path)
        let hiddenDirectory = directory.appendingPathComponent("hidden")
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hidden = try await store.loadRoot(path: hiddenDirectory.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: hidden.id)
            await store.unloadRoot(id: ordinary.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let viewModel = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let hiddenLifetime = try await store.rootLifetimeIDForTesting(rootID: hidden.id)
        let ordinaryLifetime = try await store.rootLifetimeIDForTesting(rootID: ordinary.id)
        await store.resetFilesInRootRequestCountForTesting()
        await store.resetAppliedIndexRecordLookupDiagnosticsForTesting()

        for event in [
            WorkspaceAppliedIndexBatchEvent(rootID: ordinary.id, rootPath: ordinary.fullPath, generation: 1, rootLifetimeID: ordinaryLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: directory.path, generation: 1, rootLifetimeID: hiddenLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: hidden.fullPath, generation: 1, rootLifetimeID: hiddenLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: hidden.fullPath, generation: 1, rootLifetimeID: hiddenLifetime)
        ] {
            await viewModel.applyWorkspaceAppliedIndexEventForTesting(event)
        }

        let enumerations = await store.fileEnumerationRequestCountForTesting()
        let lookups = await store.appliedIndexRecordLookupDiagnosticsForTesting()
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(lookups.rootSnapshots, 0)
        // The empty first hidden event must advance handled generation: its replay
        // should be rejected before even a targeted lookup.
        XCTAssertEqual(lookups.lookupRequests, 1)
        XCTAssertEqual(lookups.requestedRecords, 0)
    }
}

@MainActor
final class RemovedFolderIndexRebuildTests: XCTestCase {
    func testMatcherPreservesStandardizedPathSemantics() {
        let paths = [
            "/", "/file.swift", "/work", "/work/file.swift", "/workspace/file.swift",
            "/work/a/b/c/d/e/file.swift", "/work/café/file.swift", "/work/cafe\u{301}/file.swift",
            "/work/日本語/名前.swift", "/work/\u{301}combining/file.swift", "/work/x\u{0600}/file.swift", "relative/file.swift"
        ].map(StandardizedPath.absolute)
        let removedSets: [Set<String>] = [
            [], ["/"], ["/work"], ["/workspace"], ["/work/a/b/c"], ["/work/café"],
            ["/work/cafe\u{301}"], ["/work/日本語"], ["/work/\u{301}combining"],
            ["/missing", "/work/a/b/c"], ["/work/x\u{0600}"], ["relative"]
        ]
        for removed in removedSets {
            let matcher = RemovedFolderPathMatcher(removedFolderPaths: removed)
            for path in paths {
                XCTAssertEqual(
                    matcher.containsPathEqualToOrInsideRemovedFolder(path),
                    legacyContains(path, removed: removed),
                    "Removed: \(removed), path: \(path)"
                )
            }
        }
    }

    func testRebuildDecisionPreservesOwnedAndFallbackIndexes() {
        let root = "/workspace"
        let removed: Set = ["/workspace/removed"]
        var index = FileHierarchyIndex()
        index.filePathsByRoot[root] = ["/workspace/kept/file.swift"]
        XCTAssertFalse(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: root))
        index.filePathsByRoot[root]?.insert("/workspace/removed/deep/file.swift")
        XCTAssertTrue(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: root))
        XCTAssertFalse(index.hasIndexedPaths(inRemovedFolders: [], rootKey: root))

        index.filePathsByRoot[root] = []
        index.foldersByFullPath["/workspace/removed"] = FolderViewModel(
            folder: Folder(name: "removed", path: "/workspace/removed", modificationDate: .distantPast),
            rootPath: root
        )
        XCTAssertTrue(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: root))
        index.foldersByFullPath = [:]
        let file = makeFile(path: "/workspace/removed/deep/file.swift", root: root)
        index.filesByFullPath[file.standardizedFullPath] = file
        // A present empty owned index remains authoritative, as in the old decision.
        XCTAssertFalse(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: root))
        index.filePathsByRoot = [:]
        XCTAssertTrue(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: root + "/./"))
        XCTAssertFalse(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: "/other-root"))
    }

    func testStandardizedOwnerInsertionsPreserveAllIndexMaps() {
        let root = "/workspace/日本語"
        let nestedRoot = root + "/nested"
        let path = nestedRoot + "/shared"
        let outer = makeFolder(path: root, root: root)
        let nested = makeFolder(path: nestedRoot, root: nestedRoot)
        let originalFolder = makeFolder(path: path, root: root + "/./")
        let originalFile = makeFile(path: path + "/file.swift", root: root + "/./")
        let replacementFolder = makeFolder(path: path, root: nestedRoot)
        let replacementFile = makeFile(path: path + "/file.swift", root: nestedRoot)
        let explicitOwnerFile = makeFile(path: nestedRoot + "/outer.swift", root: nestedRoot)

        var reference = FileHierarchyIndex()
        reference.insertFolder(outer, rootKey: root + "/./")
        reference.insertFolder(nested, rootKey: nestedRoot + "/")
        reference.insertFolder(originalFolder)
        reference.insertFile(originalFile)
        var index = FileHierarchyIndex()
        index.insertFolder(outer, standardizedOwnerRootKey: root)
        index.insertFolder(nested, standardizedOwnerRootKey: nestedRoot)
        index.insertFolder(originalFolder, standardizedOwnerRootKey: root)
        index.insertFile(originalFile, standardizedOwnerRootKey: root)
        assertSameIndex(index, as: reference)
        // Reading the default bucket during insertion does not store it.
        XCTAssertNil(index.filePathsByRoot[nestedRoot])

        reference.filePathsByRoot[nestedRoot] = []
        index.filePathsByRoot[nestedRoot] = []
        reference.insertFolder(nested, rootKey: nestedRoot + "/")
        index.insertFolder(nested, standardizedOwnerRootKey: nestedRoot)
        assertSameIndex(index, as: reference)
        XCTAssertEqual(index.filePathsByRoot[nestedRoot], [])

        reference.insertFolder(replacementFolder, rootKey: nestedRoot + "/./")
        reference.insertFile(replacementFile, rootKey: nestedRoot + "/./")
        reference.insertFile(explicitOwnerFile, rootKey: root + "/")
        index.insertFolder(replacementFolder, standardizedOwnerRootKey: nestedRoot)
        index.insertFile(replacementFile, standardizedOwnerRootKey: nestedRoot)
        index.insertFile(explicitOwnerFile, standardizedOwnerRootKey: root)
        assertSameIndex(index, as: reference)

        XCTAssertEqual(index.folderPathsByRoot, [root: [root], nestedRoot: [nestedRoot, path]])
        XCTAssertEqual(index.filePathsByRoot, [
            root: [explicitOwnerFile.standardizedFullPath],
            nestedRoot: [replacementFile.standardizedFullPath]
        ])
        XCTAssertNil(index.foldersByID[originalFolder.id])
        XCTAssertNil(index.filesByID[originalFile.id])
        XCTAssertTrue(index.foldersByFullPath[path] === replacementFolder)
        XCTAssertTrue(index.filesByFullPath[replacementFile.standardizedFullPath] === replacementFile)
    }

    #if DEBUG
        func testHierarchyRebuildPreservesTraversalAndVisitCounts() throws {
            let rootPath = "/workspace/日本語"
            let root = makeFolder(path: rootPath + "/./", root: rootPath)
            let first = makeFolder(path: rootPath + "/first", root: rootPath)
            let last = makeFolder(path: rootPath + "/last", root: rootPath)
            let path = rootPath + "/duplicate.swift"
            let original = makeFile(path: path, root: rootPath)
            let replacement = makeFile(path: path, root: rootPath)
            first.setChildren([.file(original)])
            last.setChildren([.file(replacement)])
            root.setChildren([.folder(last), .folder(first), .folder(first)])
            XCTAssertEqual(root.children.map(\.id), [first.id, first.id, last.id])

            let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
            let viewModel = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            for _ in 0 ..< 2 {
                viewModel.registerRootFolderForTesting(root)
                let sample = try XCTUnwrap(viewModel.latestIndexRebuildPerfSampleForTesting())
                XCTAssertEqual(sample.reindexVisitedFolderCount, 3)
                XCTAssertEqual(sample.reindexVisitedFileCount, 2)
                XCTAssertNil(viewModel.appliedIndexProjectedFileForTesting(id: original.id))
                XCTAssertTrue(viewModel.appliedIndexProjectedFileForTesting(id: replacement.id) === replacement)
                let snapshot = viewModel.appliedIndexProjectionIndexSnapshotForTesting()
                XCTAssertEqual(snapshot.fileIDsByPath, [path: replacement.id])
                XCTAssertEqual(snapshot.folderIDsByPath, [
                    rootPath: root.id,
                    first.standardizedFullPath: first.id,
                    last.standardizedFullPath: last.id
                ])
            }
        }
    #endif

    private func assertSameIndex(_ actual: FileHierarchyIndex, as expected: FileHierarchyIndex) {
        XCTAssertEqual(actual.filesByFullPath.mapValues(ObjectIdentifier.init), expected.filesByFullPath.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(actual.foldersByFullPath.mapValues(ObjectIdentifier.init), expected.foldersByFullPath.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(actual.filesByID.mapValues(ObjectIdentifier.init), expected.filesByID.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(actual.foldersByID.mapValues(ObjectIdentifier.init), expected.foldersByID.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(actual.filePathsByRoot, expected.filePathsByRoot)
        XCTAssertEqual(actual.folderPathsByRoot, expected.folderPathsByRoot)
    }

    private func makeFolder(path: String, root: String) -> FolderViewModel {
        FolderViewModel(
            folder: Folder(name: (path as NSString).lastPathComponent, path: path, modificationDate: .distantPast),
            rootPath: root
        )
    }

    func testLargeUnmaterializedRemovalBatchStaysResponsive() {
        let removed = Set((0 ..< 2000).map { "/workspace/.worktrees/removed-\($0)" })
        let files = Set((0 ..< 12000).map { "/workspace/source/module/component/detail/types/nested/File\($0).swift" })
        var index = FileHierarchyIndex()
        index.filePathsByRoot["/workspace"] = files
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(index.hasIndexedPaths(inRemovedFolders: removed, rootKey: "/workspace"))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("REMOVED_FOLDER_BATCH folders=2000 files=12000 new_ms=\(elapsed * 1000)")
        // Limit this synchronous decision to 250 ms (15 frames at 60 Hz), rather than
        // the multi-second UI starvation caused by a scan for every removed folder.
        XCTAssertLessThan(elapsed, 0.25)
    }

    private func legacyContains(_ path: String, removed: Set<String>) -> Bool {
        guard !removed.isEmpty else { return false }
        if removed.contains(path) {
            return true
        }
        var current = path
        while true {
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else { return false }
            if removed.contains(parent) {
                return true
            }
            current = parent
        }
    }

    private func makeFile(path: String, root: String) -> FileViewModel {
        FileViewModel(
            file: File(name: "file.swift", path: path, modificationDate: .distantPast),
            rootPath: root,
            rootIdentifier: UUID(),
            rootFolderPath: root,
            fileSystemService: nil
        )
    }
}

final class WorkspaceAppliedIndexFolderOrderingTests: XCTestCase {
    func testMixedFoldersPreserveLegacyOrderIncludingEqualPaths() {
        let paths = [
            "z/deep/child", "z", "", "a/child", "a", "A", "a/10", "a/2",
            "a/child", "é", "e\u{301}", "日本語/名前", ".hidden/child", ".hidden",
            "a//child/", "/", "nested/longer/path/leaf", "日本語", "z/deep"
        ]
        let folders = records(paths)
        let inputs = [
            folders,
            Array(folders.reversed()),
            Array(folders.dropFirst(7)) + Array(folders.prefix(7))
        ]

        for input in inputs {
            let expected = legacySorted(input)
            let actual = WorkspaceAppliedIndexFolderOrdering.sorted(input)
            // Both sorts are stable: equal paths must retain their distinct records' input order.
            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
            XCTAssertEqual(actual, expected)
        }
    }

    func testDepthIsEvaluatedOncePerRecordForLargeMixedBatch() {
        let paths = (0 ..< 2048).map { index in
            let depth = index % 9
            return (0 ..< depth).map { "level\($0)" }.joined(separator: "/")
                + "/folder\((index * 37) % 251)"
        }
        let folders = records(paths)
        var evaluatedPaths: [String] = []
        let actual = WorkspaceAppliedIndexFolderOrdering.sorted(folders) { path in
            evaluatedPaths.append(path)
            return path.split(separator: "/").count
        }

        XCTAssertEqual(evaluatedPaths, folders.map(\.standardizedRelativePath))
        XCTAssertEqual(evaluatedPaths.count, folders.count)
        XCTAssertEqual(actual.map(\.id), legacySorted(folders).map(\.id))
        XCTAssertEqual(WorkspaceAppliedIndexFolderOrdering.sorted(folders).map(\.id), actual.map(\.id))
    }

    func testEmptyAndSingletonBatches() {
        for folders in [[], records(["single/deep/path"])] {
            var depthEvaluations = 0
            let actual = WorkspaceAppliedIndexFolderOrdering.sorted(folders) { path in
                depthEvaluations += 1
                return path.split(separator: "/").count
            }
            XCTAssertEqual(actual, folders)
            XCTAssertEqual(depthEvaluations, folders.count)
            XCTAssertEqual(WorkspaceAppliedIndexFolderOrdering.sorted(folders), folders)
        }
    }

    private func legacySorted(_ folders: [WorkspaceFolderRecord]) -> [WorkspaceFolderRecord] {
        folders.sorted { lhs, rhs in
            let lhsDepth = lhs.standardizedRelativePath.split(separator: "/").count
            let rhsDepth = rhs.standardizedRelativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.standardizedRelativePath < rhs.standardizedRelativePath
        }
    }

    private func records(_ paths: [String]) -> [WorkspaceFolderRecord] {
        let rootIDs = [UUID(), UUID()]
        return paths.enumerated().map { index, path in
            WorkspaceFolderRecord(
                rootID: rootIDs[index % rootIDs.count],
                name: path,
                relativePath: path,
                fullPath: "/workspace/\(path)",
                parentFolderID: nil
            )
        }
    }
}
