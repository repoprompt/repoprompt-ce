@testable import RepoPrompt
import XCTest

final class WorkspaceProjectedPathSearchTests: XCTestCase {
    private typealias Support = WorkspaceRootSeedTestSupport

    func testProjectedMatcherExactlyMatchesFullTargetIndexAcrossQueriesAndLimits() async throws {
        let root = WorkspaceRootRecord(
            name: "Projected Root",
            fullPath: "/tmp/Projected Root",
            kind: .sessionWorktree
        )
        let snapshot = try await Support.snapshot(paths: [
            ("A.swift", "100644"),
            ("Deleted.swift", "100644"),
            ("Old.swift", "100644"),
            ("Sources/Space Target.swift", "100644"),
            ("Sources/Ångström.swift", "100644"),
            ("Sources/line\nbreak.swift", "100644")
        ])
        let finalPaths = [
            "A.swift", "Added 文件.swift", "Renamed.swift", "Sources/Space Target.swift",
            "Sources/Ångström.swift", "Sources/line\nbreak.swift"
        ]
        let entries = makeEntries(paths: finalPaths, root: root)
        let projected = try XCTUnwrap(WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            changedRelativeFilePaths: ["Added 文件.swift", "Deleted.swift", "Old.swift", "Renamed.swift"],
            tombstonedBaseRelativeFilePaths: ["Deleted.swift", "Old.swift"],
            root: root,
            authoritativeEntries: entries
        ))
        let full = WorkspaceSearchRootPathIndex(
            identity: WorkspaceSearchRootPathIndexIdentity(
                rootID: root.id,
                lifetimeID: UUID(),
                topologyGeneration: 0
            ),
            rootPath: root.standardizedFullPath,
            entries: entries
        )

        let queries = [
            "A", "*.swift", "Space Target", "Projected Root", root.standardizedFullPath,
            "Ångström", "文件", "line\nbreak", "Sources *.swift"
        ]
        for query in queries {
            for limit in [0, 1, 3, 100] {
                let expected = full.search(query, limit: limit)
                let actual = projected.search(query, limit: limit)
                XCTAssertEqual(actual.map(\.entry.id), expected.map(\.entry.id), "query=\(query) limit=\(limit)")
                XCTAssertEqual(actual.map(\.score), expected.map(\.score), "query=\(query) limit=\(limit)")
                XCTAssertEqual(actual.map(\.tieBreakKey), expected.map(\.tieBreakKey), "query=\(query) limit=\(limit)")
            }
        }
        XCTAssertEqual(projected.overlayEntryCount, 2)
        XCTAssertEqual(projected.tombstoneCount, 2)
    }

    func testRealProjectedRootIndexExactlyMatchesMaterializedSearchAndEntryOrdering() async throws {
        let root = WorkspaceRootRecord(
            name: "Serving Root",
            fullPath: "/tmp/Serving Root",
            kind: .sessionWorktree
        )
        let snapshot = try await Support.snapshot(paths: [
            ("A.swift", "100644"),
            ("Deleted.swift", "100644"),
            ("Sources/Keep.swift", "100644"),
            ("Sources/Ångström.swift", "100644")
        ])
        let finalPaths = ["A.swift", "Added 文件.swift", "Sources/Keep.swift", "Sources/Ångström.swift"]
        let entries = makeEntries(paths: finalPaths, root: root)
        let identity = WorkspaceSearchRootPathIndexIdentity(
            rootID: root.id,
            lifetimeID: UUID(),
            topologyGeneration: 1
        )
        let projected = try XCTUnwrap(WorkspaceSearchRootPathIndex(
            identity: identity,
            root: root,
            projectedSnapshot: snapshot,
            changedRelativeFilePaths: ["Added 文件.swift", "Deleted.swift"],
            tombstonedBaseRelativeFilePaths: ["Deleted.swift"],
            entries: entries
        ))
        let materialized = WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: entries
        )

        XCTAssertEqual(projected.buildKind, .projectedReuse)
        XCTAssertEqual(projected.entries, materialized.entries)
        for query in ["", "*.swift", "Serving Root", root.standardizedFullPath, "Ångström", "文件"] {
            for limit in [0, 1, 2, 100] {
                XCTAssertEqual(
                    projected.search(query, limit: limit).map(\.entry.id),
                    materialized.search(query, limit: limit).map(\.entry.id),
                    "query=\(query) limit=\(limit)"
                )
                XCTAssertEqual(
                    projected.search(query, limit: limit).map(\.tieBreakKey),
                    materialized.search(query, limit: limit).map(\.tieBreakKey),
                    "query=\(query) limit=\(limit)"
                )
            }
        }
    }

    func testRealProjectedPatchesCross32CompactSegmentsAndRetainOlderGenerations() async throws {
        let root = WorkspaceRootRecord(name: "Patch Target", fullPath: "/tmp/Patch Target", kind: .sessionWorktree)
        let basePaths = (0 ..< 40).map { "File\($0).swift" }
        let snapshot = try await Support.snapshot(paths: basePaths.map { ($0, "100644") })
        let idsByBasePath = Dictionary(uniqueKeysWithValues: basePaths.map { ($0, UUID()) })
        var entries = makeEntries(paths: basePaths, root: root, idsByPath: idsByBasePath)
        let lifetimeID = UUID()
        func identity(_ generation: UInt64) -> WorkspaceSearchRootPathIndexIdentity {
            .init(rootID: root.id, lifetimeID: lifetimeID, topologyGeneration: generation)
        }
        let initial = try XCTUnwrap(WorkspaceSearchRootPathIndex(
            identity: identity(1),
            root: root,
            projectedSnapshot: snapshot,
            changedRelativeFilePaths: [],
            tombstonedBaseRelativeFilePaths: [],
            entries: entries
        ))
        XCTAssertEqual(initial.projectedAccumulatedChangedPathCount, 0)

        let deletedID = try XCTUnwrap(idsByBasePath["File1.swift"])
        let renamedID = try XCTUnwrap(idsByBasePath["File2.swift"])
        let addedID = UUID()
        entries.removeAll { $0.id == deletedID || $0.id == renamedID }
        entries.append(makeEntry(path: "Added.swift", id: addedID, root: root))
        entries.append(makeEntry(path: "Renamed.swift", id: renamedID, root: root))
        entries.sort(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
        var patched = try initial.applyingPatch(
            identity: identity(2),
            entries: entries,
            changedFileIDs: [
                XCTUnwrap(idsByBasePath["File0.swift"]),
                deletedID,
                renamedID,
                addedID
            ]
        )
        XCTAssertEqual(patched.buildKind, .projectedReuse)
        XCTAssertEqual(patched.projectedAccumulatedChangedPathCount, 5)
        assertSearchParity(patched, entries: entries, root: root, identity: identity(2))

        let pathsToReach31 = (3 ... 28).map { "File\($0).swift" }
        patched = patched.applyingPatch(
            identity: identity(3),
            entries: entries,
            changedFileIDs: Set(pathsToReach31.compactMap { idsByBasePath[$0] })
        )
        let retainedAt31 = patched
        XCTAssertEqual(retainedAt31.buildKind, .projectedReuse)
        XCTAssertEqual(retainedAt31.projectedAccumulatedChangedPathCount, 31)
        assertSearchParity(retainedAt31, entries: entries, root: root, identity: identity(3))

        var beyondFormerThreshold = try retainedAt31.applyingPatch(
            identity: identity(4),
            entries: entries,
            changedFileIDs: [XCTUnwrap(idsByBasePath["File29.swift"])]
        )
        XCTAssertEqual(beyondFormerThreshold.buildKind, .projectedReuse)
        XCTAssertEqual(beyondFormerThreshold.projectedAccumulatedChangedPathCount, 32)
        assertSearchParity(beyondFormerThreshold, entries: entries, root: root, identity: identity(4))

        var retainedBeforeCompaction: WorkspaceSearchRootPathIndex?
        for iteration in 0 ..< 20 {
            let renamedPath = "Cycle\(iteration)-文件.swift"
            entries.removeAll { $0.id == renamedID }
            entries.append(makeEntry(path: renamedPath, id: renamedID, root: root))
            entries.sort(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
            beyondFormerThreshold = beyondFormerThreshold.applyingPatch(
                identity: identity(UInt64(5 + iteration)),
                entries: entries,
                changedFileIDs: [renamedID]
            )
            if iteration == 12 {
                retainedBeforeCompaction = beyondFormerThreshold
                XCTAssertEqual(beyondFormerThreshold.overlaySegmentCountForTesting, 16)
            }
            assertSearchParity(
                beyondFormerThreshold,
                entries: entries,
                root: root,
                identity: identity(UInt64(5 + iteration))
            )
        }
        XCTAssertLessThanOrEqual(beyondFormerThreshold.overlaySegmentCountForTesting, 16)
        XCTAssertEqual(beyondFormerThreshold.buildKind, .projectedReuse)
        XCTAssertEqual(
            beyondFormerThreshold.search("Cycle19-文件", limit: 1).map(\.entry.id),
            [renamedID]
        )

        let retained = try XCTUnwrap(retainedBeforeCompaction)
        XCTAssertEqual(retained.search("Cycle12-文件", limit: 1).map(\.entry.id), [renamedID])
        XCTAssertTrue(retained.search("Cycle19-文件", limit: 1).isEmpty)

        XCTAssertEqual(initial.buildKind, .projectedReuse)
        XCTAssertEqual(initial.projectedAccumulatedChangedPathCount, 0)
        XCTAssertEqual(initial.search("File1.swift", limit: 10).map(\.entry.id), [deletedID])
        XCTAssertEqual(retainedAt31.buildKind, .projectedReuse)
        XCTAssertEqual(retainedAt31.projectedAccumulatedChangedPathCount, 31)
        XCTAssertTrue(retainedAt31.search("File1.swift", limit: 10).isEmpty)
        XCTAssertEqual(retainedAt31.search("Renamed.swift", limit: 10).map(\.entry.id), [renamedID])
    }

    func testProjectionHasNoEntryCountFallbackAndPreservesCrossRootIsolation() async throws {
        let root = WorkspaceRootRecord(name: "Target", fullPath: "/tmp/Target", kind: .sessionWorktree)
        let paths = (0 ..< 40).map { "File\($0).swift" }
        let snapshot = try await Support.snapshot(paths: paths.map { ($0, "100644") })
        let entries = makeEntries(paths: paths, root: root)

        let retained = try XCTUnwrap(WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            changedRelativeFilePaths: Set(paths.prefix(31)),
            tombstonedBaseRelativeFilePaths: [],
            root: root,
            authoritativeEntries: entries
        ))
        XCTAssertEqual(retained.overlayEntryCount, 31)
        let retainedAt32 = try XCTUnwrap(WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            changedRelativeFilePaths: Set(paths.prefix(32)),
            tombstonedBaseRelativeFilePaths: [],
            root: root,
            authoritativeEntries: entries
        ))
        XCTAssertEqual(retainedAt32.overlayEntryCount, 32)
        let materialized = WorkspaceSearchRootPathIndex(
            identity: .init(rootID: root.id, lifetimeID: UUID(), topologyGeneration: 1),
            rootPath: root.standardizedFullPath,
            entries: entries
        )
        for query in ["", "File", "*.swift", root.standardizedFullPath] {
            for limit in [1, 7, 100] {
                XCTAssertEqual(
                    retainedAt32.search(query, limit: limit).map(\.entry.id),
                    materialized.search(query, limit: limit).map(\.entry.id),
                    "query=\(query) limit=\(limit)"
                )
            }
        }

        XCTAssertTrue(retained.search("/tmp/OtherRoot", limit: 100).isEmpty)
        XCTAssertTrue(retained.search("OtherRoot/File1", limit: 100).isEmpty)
        XCTAssertEqual(
            retained.search(root.standardizedFullPath, limit: 100).map(\.entry.rootID),
            Array(repeating: root.id, count: paths.count)
        )
    }

    func testMaterializedOverlaySegmentsCompactWithoutInvalidatingRetainedGeneration() throws {
        let root = WorkspaceRootRecord(name: "Segment Root", fullPath: "/tmp/Segment Root")
        let basePaths = (0 ..< 80).map { "Base\($0).swift" }
        let idsByPath = Dictionary(uniqueKeysWithValues: basePaths.map { ($0, UUID()) })
        var entries = makeEntries(paths: basePaths, root: root, idsByPath: idsByPath)
        let lifetimeID = UUID()
        func identity(_ generation: UInt64) -> WorkspaceSearchRootPathIndexIdentity {
            .init(rootID: root.id, lifetimeID: lifetimeID, topologyGeneration: generation)
        }

        var index = WorkspaceSearchRootPathIndex(
            identity: identity(0),
            rootPath: root.standardizedFullPath,
            entries: entries
        )
        let mutableID = try XCTUnwrap(idsByPath["Base2.swift"])
        let deletedID = try XCTUnwrap(idsByPath["Base0.swift"])
        var retainedBeforeCompaction: WorkspaceSearchRootPathIndex?
        var retainedEntries: [WorkspaceSearchCatalogEntry] = []

        for iteration in 0 ..< 40 {
            entries.removeAll { entry in
                entry.id == mutableID || (iteration == 0 && entry.id == deletedID)
            }
            entries.append(makeEntry(path: "Mutable \(iteration) Å.swift", id: mutableID, root: root))
            entries.sort(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
            var changedFileIDs: Set<UUID> = [mutableID]
            if iteration == 0 { changedFileIDs.insert(deletedID) }
            index = index.applyingPatch(
                identity: identity(UInt64(iteration + 1)),
                entries: entries,
                changedFileIDs: changedFileIDs
            )
            XCTAssertEqual(index.buildKind, .overlay)
            if iteration == 15 {
                retainedBeforeCompaction = index
                retainedEntries = entries
                XCTAssertEqual(index.overlaySegmentCountForTesting, 16)
            }
        }

        XCTAssertLessThanOrEqual(index.overlaySegmentCountForTesting, 16)
        assertSearchParity(index, entries: entries, root: root, identity: identity(40))
        XCTAssertTrue(index.search("Base0.swift", limit: 10).isEmpty)
        XCTAssertEqual(index.search("Mutable 39 Å", limit: 10).map(\.entry.id), [mutableID])

        let retained = try XCTUnwrap(retainedBeforeCompaction)
        assertSearchParity(retained, entries: retainedEntries, root: root, identity: identity(16))
        XCTAssertEqual(retained.search("Mutable 15 Å", limit: 10).map(\.entry.id), [mutableID])
        XCTAssertTrue(retained.search("Mutable 39 Å", limit: 10).isEmpty)
    }

    func testProjectedMatcherUsesBoundedTopKStorageAndReusableScratch() async {
        let paths = (0 ..< 20000).map { index in
            index == 1 ? "A\u{1}.swift" : String(format: "Sources/%05d Target.swift", index)
        } + ["A.swift", "A\nbreak.swift"]
        let displayPrefix = "Large Root/"
        let absolutePrefix = "/tmp/Large Root/"
        let relative = PathSearchIndex(paths: paths)
        let full = PathSearchIndex(paths: paths.map {
            displayPrefix + $0 + "\n" + absolutePrefix + $0
        })

        let outcome = await relative.searchProjected(
            "*.swift",
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: 7
        )
        guard case let .completed(candidates, diagnostics) = outcome else {
            return XCTFail("Projected search unexpectedly cancelled")
        }
        let expected = full.searchSynchronously("*.swift", limit: 7)
        XCTAssertEqual(candidates.map(\.tieBreakKey), expected.map(\.tieBreakKey))
        XCTAssertEqual(diagnostics.examinedCount, paths.count)
        XCTAssertEqual(diagnostics.heapPeakCount, 7)
        XCTAssertLessThanOrEqual(diagnostics.heapComparisonCount, paths.count * 16)
        let maximumRelativeBytes = paths.map(\.utf8.count).max() ?? 0
        XCTAssertEqual(
            diagnostics.scratchBytes,
            displayPrefix.utf8.count + absolutePrefix.utf8.count + maximumRelativeBytes * 2 + 2
        )
    }

    func testProjectedMatcherCancellationJoinsLargeWorker() async {
        let paths = (0 ..< 50000).map { String(format: "Sources/%05d CancellationTarget.swift", $0) }
        let index = PathSearchIndex(paths: paths)
        let task = Task {
            await index.searchProjected(
                "*CancellationTarget.swift",
                displayPrefix: "Cancellation Root/",
                absolutePrefix: "/tmp/Cancellation Root/",
                limit: 300
            )
        }
        task.cancel()
        let outcome = await task.value
        guard case let .cancelled(diagnostics) = outcome else {
            return XCTFail("Expected cooperative C cancellation")
        }
        XCTAssertLessThan(diagnostics.examinedCount, paths.count)
        XCTAssertLessThanOrEqual(diagnostics.heapPeakCount, 300)
    }

    func testFirstParityMismatchAtomicallyDisablesRetainedShadow() async throws {
        WorktreeStartupInstrumentation.resetForTesting()
        let root = WorkspaceRootRecord(name: "Isolated", fullPath: "/tmp/Isolated", kind: .sessionWorktree)
        let snapshot = try await Support.snapshot(paths: [("A.swift", "100644")])
        let projectedEntries = makeEntries(paths: ["A.swift"], root: root)
        let authoritativeEntries = makeEntries(paths: ["A.swift", "B.swift"], root: root)
        let projection = try XCTUnwrap(WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            changedRelativeFilePaths: [],
            tombstonedBaseRelativeFilePaths: [],
            root: root,
            authoritativeEntries: projectedEntries
        ))
        let token = WorkspaceSessionWorktreeOwnershipToken(ownerID: UUID(), generation: 1)
        let scope = WorkspaceRootSeedShadowScope(
            token: token,
            bindingFingerprint: "binding",
            rootID: root.id,
            lifetimeID: UUID(),
            standardizedPhysicalPath: root.standardizedFullPath,
            catalogGeneration: 1,
            appliedIndexGeneration: 0
        )
        let control = WorkspaceProjectedPathSearchShadowControl(scope: scope, projection: projection)
        let index = WorkspaceSearchRootPathIndex(
            identity: .init(rootID: root.id, lifetimeID: scope.lifetimeID, topologyGeneration: 1),
            rootPath: root.standardizedFullPath,
            entries: authoritativeEntries,
            shadowControl: control
        )

        async let first = index.searchVerifyingShadow("*.swift", limit: 10)
        async let second = index.searchVerifyingShadow("*.swift", limit: 10)
        _ = await (first, second)
        XCTAssertFalse(control.isActive)
        XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().shadow.projectedSearchComparisons, 1)

        _ = await index.searchVerifyingShadow("*.swift", limit: 10)
        XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().shadow.projectedSearchComparisons, 1)
    }

    private func makeEntries(
        paths: [String],
        root: WorkspaceRootRecord,
        idsByPath: [String: UUID] = [:]
    ) -> [WorkspaceSearchCatalogEntry] {
        paths.map { relativePath in
            makeEntry(path: relativePath, id: idsByPath[relativePath] ?? UUID(), root: root)
        }.sorted(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
    }

    private func makeEntry(
        path: String,
        id: UUID,
        root: WorkspaceRootRecord
    ) -> WorkspaceSearchCatalogEntry {
        let file = WorkspaceFileRecord(
            id: id,
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.standardizedFullPath + "/" + path,
            parentFolderID: nil
        )
        return WorkspaceSearchCatalogEntry(file: file, root: root)
    }

    private func assertSearchParity(
        _ projected: WorkspaceSearchRootPathIndex,
        entries: [WorkspaceSearchCatalogEntry],
        root: WorkspaceRootRecord,
        identity: WorkspaceSearchRootPathIndexIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let materialized = WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: entries
        )
        for query in ["", "*.swift", "File", "Added", "Renamed", root.standardizedFullPath] {
            for limit in [0, 1, 7, 100] {
                XCTAssertEqual(
                    projected.search(query, limit: limit).map(\.entry.id),
                    materialized.search(query, limit: limit).map(\.entry.id),
                    "query=\(query) limit=\(limit)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
