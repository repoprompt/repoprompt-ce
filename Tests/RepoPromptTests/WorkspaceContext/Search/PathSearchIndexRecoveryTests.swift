import Foundation
@testable import RepoPromptApp
@testable import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptWorkspaceCore
import XCTest

final class PathSearchIndexRecoveryTests: XCTestCase {
    func testCandidateFilenamesPreserveComponentBytesAndLegacyDegeneratePaths() {
        let paths: [(path: String, filename: String?)] = [
            ("", nil), ("/", nil), ("//", nil), (".", nil), ("..", nil), ("./", nil), ("../", nil),
            ("a/.", nil), ("a/..", nil), ("/a/../../", nil), ("a//b/", nil), ("a/b///", nil),
            ("a//..", nil), ("/../..", nil), ("/a//../../", nil), ("a/./../..", nil),
            ("a%2Fb", "a%2Fb"), ("a%20b", "a%20b"), ("a?b#c", "a?b#c"), ("~", "~"),
            ("~/file.swift", "file.swift"), ("é/日本語.swift", "日本語.swift"), ("e\u{301}/🦊.swift", "🦊.swift"),
            ("d/é.swift", "é.swift"), ("d/e\u{301}.swift", "e\u{301}.swift"), ("d/e\u{301}.swift/", nil),
            ("d/a/\u{301}.swift", "\u{301}.swift"), ("a/line\nbreak.swift", "line\nbreak.swift"),
            ("a/back\\slash.swift", "back\\slash.swift"), ("/fixture/Sources/File.swift", "File.swift"),
            ("Sources/Relative.swift", "Relative.swift"), ("d/가.swift", "가.swift"), ("d/각.swift", "각.swift"),
            ("d/\u{F900}.swift", "\u{F900}.swift"), ("d/\u{2F800}.swift", "\u{2F800}.swift"),
            ("d/\u{212B}.swift", "\u{212B}.swift"), ("d/a\u{301}\u{327}.swift", "a\u{301}\u{327}.swift")
        ]
        let cases = paths.flatMap { entry -> [(key: String, filename: String?)] in
            [
                (entry.path, entry.filename),
                ("Root/" + entry.path + "\n/fixture/" + entry.path, entry.filename),
                ("Root\n" + entry.path, entry.filename.map { entry.path.contains("/") ? $0 : "Root\n" + $0 })
            ]
        }
        let index = PathSearchIndex(paths: cases.map(\.key))
        for (offset, entry) in cases.enumerated() {
            let expected = entry.filename ?? URL(fileURLWithPath: entry.key).lastPathComponent
            XCTAssertEqual(index.filename(at: offset).map { Array($0.utf8) }, Array(expected.utf8), entry.key.debugDescription)
        }
    }

    func testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata() async {
        let paths = [
            "/Volumes/Repo/Sources/Zeta/Widget.swift",
            "Sources/βeta/Search/Unicode.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Features/SearchPanel.swift",
            "docs/absolute-search-notes.md",
            "Worktree/Sources/CompositeCatalogTarget.rpfixture\n/Volumes/Worktree/Sources/CompositeCatalogTarget.rpfixture"
        ]
        let expectedFilenames = [
            "Widget.swift",
            "Unicode.swift",
            "Alpha.swift",
            "Alpha.swift",
            "SearchPanel.swift",
            "absolute-search-notes.md",
            "CompositeCatalogTarget.rpfixture"
        ]
        let index = PathSearchIndex(paths: paths)

        let duplicateHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(duplicateHits.map(\.index), [2, 3])
        assertMappings(duplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedDuplicateHits = await index.search("Alpha.swift", limit: 1)
        XCTAssertEqual(truncatedDuplicateHits.map(\.index), [2])
        assertMappings(truncatedDuplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedWildcardHits = await index.search("*.swift", limit: 3)
        XCTAssertEqual(truncatedWildcardHits.map(\.index), [0, 4, 2])
        assertMappings(truncatedWildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let wildcardHits = await index.search("*.swift", limit: 20)
        XCTAssertEqual(wildcardHits.map(\.index), [0, 4, 2, 3, 1])
        XCTAssertEqual(wildcardHits.map(\.filename), [
            "Widget.swift",
            "SearchPanel.swift",
            "Alpha.swift",
            "Alpha.swift",
            "Unicode.swift"
        ])
        assertMappings(wildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let spaceANDHits = await index.search("App Search", limit: 20)
        XCTAssertEqual(spaceANDHits.map(\.index), [4, 2, 3])
        assertMappings(spaceANDHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let unicodeHits = await index.search("βeta", limit: 20)
        XCTAssertEqual(unicodeHits.map(\.index), [1])
        assertMappings(unicodeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let absolutePathHits = await index.search("Volumes Widget", limit: 20)
        XCTAssertEqual(absolutePathHits.map(\.index), [0])
        assertMappings(absolutePathHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let compositeHits = await index.search("CompositeCatalogTarget", limit: 20)
        XCTAssertEqual(compositeHits.map(\.index), [6])
        assertMappings(compositeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let zeroLimitHits = await index.search("swift", limit: 0)
        XCTAssertEqual(zeroLimitHits, [])
        XCTAssertEqual(wildcardHits.count, 5)

        for invalidIndex in [-1, index.count, index.count + 10] {
            XCTAssertNil(index.path(at: invalidIndex))
            XCTAssertNil(index.filename(at: invalidIndex))
        }

        let emptyIndex = PathSearchIndex(paths: [])
        XCTAssertEqual(emptyIndex.count, 0)
        XCTAssertNil(emptyIndex.path(at: -1))
        XCTAssertNil(emptyIndex.path(at: 0))
        XCTAssertNil(emptyIndex.filename(at: -1))
        XCTAssertNil(emptyIndex.filename(at: 0))
        let emptyHits = await emptyIndex.search("swift", limit: 20)
        XCTAssertEqual(emptyHits, [])

        for iteration in 0 ..< 64 {
            let replacementPaths = [
                "Loop/Shared.swift",
                "Loop/Shared.swift",
                "/tmp/repoprompt-\(iteration)/Absolute.swift",
                "Loop/βeta/Unicode.swift"
            ]
            let replacementFilenames = [
                "Shared.swift",
                "Shared.swift",
                "Absolute.swift",
                "Unicode.swift"
            ]
            let replacement = PathSearchIndex(paths: replacementPaths)
            let replacementHits = replacement.searchSynchronously("*.swift", limit: 20)
            XCTAssertEqual(replacementHits.count, replacementPaths.count)
            assertMappings(
                replacementHits,
                in: replacement,
                paths: replacementPaths,
                expectedFilenames: replacementFilenames
            )
        }

        // The old immutable generation remains valid after replacements are constructed and released.
        let retainedHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(retainedHits, duplicateHits)
        assertMappings(retainedHits, in: index, paths: paths, expectedFilenames: expectedFilenames)
    }

    private func assertMappings(
        _ candidates: [PathSearchIndex.Candidate],
        in index: PathSearchIndex,
        paths: [String],
        expectedFilenames: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expectedFilenames.count, paths.count, file: file, line: line)
        for candidate in candidates {
            XCTAssertTrue(paths.indices.contains(candidate.index), file: file, line: line)
            guard paths.indices.contains(candidate.index) else { continue }
            XCTAssertEqual(candidate.path, paths[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.filename, expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.tieBreakKey, candidate.path, file: file, line: line)
            XCTAssertEqual(index.path(at: candidate.index), candidate.path, file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), candidate.filename, file: file, line: line)
            XCTAssertEqual(candidate.score, 1, file: file, line: line)
        }
    }
}

final class WorkspaceRootCatalogCompactionTests: XCTestCase {
    private let root = WorkspaceRootRecord(name: "Root", fullPath: "/tmp/catalog-compaction")

    func testRepeatedEditsDoNotRetainOverlayHistory() {
        let entries = makeEntries(count: 128)
        let lifetime = UUID()
        var index = makeIndex(entries, lifetime: lifetime)
        let owner = index.baseOwnerForTesting
        for generation in 1 ... 72 {
            index = index.applyingPatch(identity: identity(lifetime, generation), entries: entries, changedFileIDs: [entries[generation % entries.count].id])
        }
        XCTAssertTrue(index.baseOwnerForTesting === owner)
        XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
        assertParity(index, entries: entries)
    }

    func testInitialProjectedNormalizationValidatesPlanAndPrefixBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ["AFile.swift", "B.ignore", "CFile.swift", "DFile.swift"]
        let snapshot = try await WorkspaceRootSeedTestSupport.snapshot(paths: paths.map { ($0, "100644") }, policyIgnoredPaths: ["B.ignore"])
        let fixture = try await WorkspaceRootTargetSeedPlanTestSupport.makeFixture(
            root: directory,
            storeRoot: directory,
            snapshot: snapshot,
            namespaceRecords: paths.dropLast().filter { $0 != "B.ignore" }.map { .init(relativePath: $0, kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644) },
            deltaRecords: [.init(
                oldModeBytes: Data("100644".utf8),
                newModeBytes: nil,
                oldObjectIDBytes: Data(WorkspaceRootSeedTestSupport.oid("4").lowercaseHex.utf8),
                newObjectIDBytes: nil,
                status: .deleted,
                repositoryRelativePathBytes: Data("DFile.swift".utf8)
            )],
            indexRecords: paths.dropLast().enumerated().map { position, path in
                WorkspaceRootTargetSeedPlanTestSupport.indexRecord(path: path, objectID: WorkspaceRootSeedTestSupport.oid(path == "CFile.swift" ? "f" : Character(String(position + 1))))
            },
            targetTreeOID: WorkspaceRootSeedTestSupport.oid("e")
        )
        let records = try WorkspaceRootTargetSeedPlanTestSupport.readAll(fixture.handle)
        XCTAssertTrue(records.contains { $0.baseAction == .reuse })
        XCTAssertTrue(records.contains { $0.baseAction == .overlay })
        XCTAssertTrue(records.contains { $0.disposition == .baseTombstone })
        let entries = [entry("AFile.swift"), entry("CFile.swift")]
        let projected = try XCTUnwrap(
            WorkspaceSearchRootPathIndex(
                identity: identity(UUID(), 0),
                root: root,
                projectedSnapshot: snapshot,
                projectedPlanHandle: fixture.handle,
                additionalChangedRelativePaths: .empty,
                entries: entries
            ),
            records.map { String(decoding: $0.relativePathBytes, as: UTF8.self) + ":" + String(describing: $0.disposition) + ":" + String(describing: $0.baseAction) }.joined(separator: ",")
        )
        XCTAssertTrue(projected.baseOwnerForTesting === snapshot.searchBase)
        XCTAssertEqual(snapshot.searchBase.stableOrdinals, [0, 2, 3])
        assertParity(projected, entries: entries)

        let inventory = FileSystemVisitedInventory()
        try inventory.installSeeded(manifest: .makeForTesting(records: []))
        inventory.recordSeedReplayDelta(.fileAdded("ZAdditional.swift"))
        let changed = try inventory.seededSnapshot().changedRelativePaths
        let withAddition = entries + [entry("ZAdditional.swift")]
        let additional = try XCTUnwrap(WorkspaceSearchRootPathIndex(
            identity: identity(UUID(), 0),
            root: root,
            projectedSnapshot: snapshot,
            projectedPlanHandle: fixture.handle,
            additionalChangedRelativePaths: changed,
            entries: withAddition
        ))
        assertParity(additional, entries: withAddition)

        let unicodeRoot = WorkspaceRootRecord(id: root.id, name: "é", fullPath: root.fullPath)
        let badEntries = entries.map { value in
            WorkspaceSearchCatalogEntry(
                file: WorkspaceFileRecord(
                    id: value.id,
                    rootID: root.id,
                    name: value.name,
                    relativePath: value.relativePath,
                    fullPath: value.fullPath,
                    parentFolderID: nil
                ),
                root: unicodeRoot,
                displayPath: "e\u{301}/" + value.standardizedRelativePath
            )
        }
        XCTAssertNil(WorkspaceSearchRootPathIndex(
            identity: identity(UUID(), 0),
            root: unicodeRoot,
            projectedSnapshot: snapshot,
            projectedPlanHandle: fixture.handle,
            additionalChangedRelativePaths: .empty,
            entries: badEntries
        ))
    }

    func testMaterializedFoldPrunesRemovedNonBaseIdentitiesAndPreservesQueries() {
        var entries = makeEntries(count: 128)
        let lifetime = UUID()
        var index = makeIndex(entries, lifetime: lifetime)
        for generation in 1 ... 72 {
            let added = entry("nested/New\(generation).swift")
            entries.append(added)
            entries = ordered(entries)
            index = index.applyingPatch(identity: identity(lifetime, generation * 2), entries: entries, changedFileIDs: [added.id])
            weak var overlay = index.overlayOwnersForTesting.first
            XCTAssertNotNil(overlay)
            assertParity(index, entries: entries)
            entries.removeAll { $0.id == added.id }
            index = index.applyingPatch(identity: identity(lifetime, generation * 2 + 1), entries: entries, changedFileIDs: [added.id])
            XCTAssertNil(overlay)
            XCTAssertTrue(index.suppressionIsBaseSubsetForTesting)
            XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
            assertParity(index, entries: entries)
        }
        let original = entries[0]
        let replacement = entry("Renamed.swift", id: original.id)
        entries[0] = replacement
        entries = ordered(entries)
        let changed = index.applyingPatch(identity: identity(lifetime, 200), entries: entries, changedFileIDs: [original.id])
        entries.removeAll { $0.id == original.id }
        entries.append(original)
        entries = ordered(entries)
        let restored = changed.applyingPatch(identity: identity(lifetime, 201), entries: entries, changedFileIDs: [original.id])
        XCTAssertTrue(restored.baseOwnerForTesting === index.baseOwnerForTesting)
        XCTAssertEqual(restored.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
        assertParity(restored, entries: entries)

        let a = entry("AddedA.swift")
        let b = entry("AddedB.swift")
        let first = index.applyingPatch(identity: identity(lifetime, 202), entries: ordered(entries + [a]), changedFileIDs: [a.id])
        let second = first.applyingPatch(identity: identity(lifetime, 203), entries: ordered(entries + [a, b]), changedFileIDs: [b.id])
        XCTAssertTrue(second.baseOwnerForTesting === first.baseOwnerForTesting)
        XCTAssertEqual(second.overlayHistoryMetricsForTesting.totalPayloadCount, 1)
        assertParity(second, entries: ordered(entries + [a, b]))
        let third = second.applyingPatch(identity: identity(lifetime, 204), entries: ordered(entries + [b]), changedFileIDs: [a.id])
        assertParity(third, entries: ordered(entries + [b]))
        assertParity(first, entries: ordered(entries + [a]))
        let removed = index.applyingPatch(identity: identity(lifetime, 205), entries: Array(entries.dropFirst()), changedFileIDs: [entries[0].id])
        XCTAssertEqual(removed.overlayHistoryMetricsForTesting.totalPayloadCount, 1)
        assertParity(removed, entries: Array(entries.dropFirst()))
    }

    func testProjectedFoldRefreshesTargetsWithoutChangingSeedOrdinals() async throws {
        let entries = makeEntries(count: 128)
        let projected = try await makeProjected(entries)
        let base = projected.baseOwnerForTesting
        let lifetime = projected.identity.lifetimeID
        var current = entries
        var index = projected
        assertParity(index, entries: current)
        for generation in 1 ... 72 {
            let position = generation % current.count
            let old = current[position]
            current[position] = entry(old.standardizedRelativePath, id: UUID())
            current = ordered(current)
            index = try index.applyingPatch(
                identity: identity(lifetime, generation),
                entries: current,
                changedFileIDs: [old.id, XCTUnwrap(current.first { $0.standardizedRelativePath == old.standardizedRelativePath }?.id)]
            )
            XCTAssertTrue(index.baseOwnerForTesting === base)
            XCTAssertTrue(index.usesSharedRelativeBaseForTesting)
            XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
            assertParity(index, entries: current)
        }
        let sync = index.search("File", limit: 1024)
        let projectedStorage = try XCTUnwrap(index.projectedStorageOwnerForTesting as? WorkspaceProjectedPathSearchIndex)
        switch await projectedStorage.searchCancellable("File", limit: 1024) {
        case let .completed(values, _): assertCandidates(values, sync)
        case .cancelled: XCTFail("Uncancelled search did not complete")
        }
        let task = Task { () -> WorkspaceProjectedPathSearchIndex.CancellableSearchOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await projectedStorage.searchCancellable("File", limit: 1024)
        }
        if case .completed = await task.value { XCTFail("Cancelled search completed") }
        XCTAssertTrue(index.baseOwnerForTesting === base)
    }

    func testRepresentationPreservingRebaseKeepsHeldReadersImmutable() async throws {
        for projected in [false, true] {
            let original = makeEntries(count: 128)
            let held: WorkspaceSearchRootPathIndex = if projected { try await makeProjected(original) } else { makeIndex(original) }
            let before = held.search("File", limit: 1024)
            var entries = original
            var index = held
            for generation in 1 ... 2 {
                let removed = entries.removeLast()
                let owner = index.baseOwnerForTesting
                index = index.applyingPatch(
                    identity: identity(held.identity.lifetimeID, generation),
                    entries: entries,
                    changedFileIDs: [removed.id],
                    policy: .init(maximumWorkRatio: 1)
                )
                XCTAssertFalse(index.baseOwnerForTesting === owner)
                XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
                if projected { XCTAssertNotNil(index.projectedStorageOwnerForTesting) }
                assertParity(index, entries: entries)
            }
            assertCandidates(held.search("File", limit: 1024), before)
            XCTAssertEqual(held.entries, original)
        }
    }

    func testOldBaseOwnersReleaseAfterReadersDrop() async throws {
        for projected in [false, true] {
            let entries = makeEntries(count: 128)
            var held: WorkspaceSearchRootPathIndex? = if projected { try await makeProjected(entries) } else { makeIndex(entries) }
            weak var oldBase = held?.baseOwnerForTesting
            let lifetime = try XCTUnwrap(held?.identity.lifetimeID)
            let nextEntries = Array(entries.dropLast())
            let current = try XCTUnwrap(try held?.applyingPatch(
                identity: identity(lifetime, 1),
                entries: nextEntries,
                changedFileIDs: [XCTUnwrap(entries.last?.id)],
                policy: .init(maximumWorkRatio: 1)
            ))
            assertParity(current, entries: nextEntries)
            XCTAssertNotNil(oldBase)
            held = nil
            XCTAssertNil(oldBase)
            withExtendedLifetime(current) {}
        }
    }

    func testProductionPolicyCrossesWorkAndKeyBudgetsIndependently() async throws {
        let original = makeEntries(count: 4096)
        for projected in [false, true] {
            let held: WorkspaceSearchRootPathIndex = if projected { try await makeProjected(original) } else { makeIndex(original) }
            let replacementIDs = Set(original.prefix(512).map(\.id))
            var entries = original.map { replacementIDs.contains($0.id) ? entry("X" + $0.relativePath.dropFirst(), id: $0.id) : $0 }
            entries = ordered(entries)
            var index = held.applyingPatch(identity: identity(held.identity.lifetimeID, 1), entries: entries, changedFileIDs: replacementIDs)
            XCTAssertTrue(index.baseOwnerForTesting === held.baseOwnerForTesting)
            XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 1)
            assertParity(index, entries: entries)
            let next = original[512]
            entries.removeAll { $0.id == next.id }
            entries.append(entry("X" + next.relativePath.dropFirst(), id: next.id))
            entries = ordered(entries)
            index = index.applyingPatch(identity: identity(held.identity.lifetimeID, 2), entries: entries, changedFileIDs: [next.id])
            XCTAssertFalse(index.baseOwnerForTesting === held.baseOwnerForTesting)
            XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
            assertParity(index, entries: entries)
        }

        var longEntries = makeEntries(count: 128)
        let replaced = longEntries.removeLast()
        longEntries.append(entry(String(repeating: "z", count: 8192) + ".swift", id: replaced.id))
        longEntries = ordered(longEntries)
        let materialized = makeIndex(longEntries)
        let shortened = ordered(longEntries.filter { $0.id != replaced.id } + [entry("Short.swift", id: replaced.id)])
        let rebased = materialized.applyingPatch(identity: identity(materialized.identity.lifetimeID, 1), entries: shortened, changedFileIDs: [replaced.id])
        XCTAssertFalse(rebased.baseOwnerForTesting === materialized.baseOwnerForTesting)
        assertParity(rebased, entries: shortened)

        let longRoot = WorkspaceRootRecord(id: root.id, name: String(repeating: "Root", count: 1024), fullPath: root.fullPath)
        let ordinary = makeEntries(count: 128)
        func inLongRoot(_ value: WorkspaceSearchCatalogEntry) -> WorkspaceSearchCatalogEntry {
            WorkspaceSearchCatalogEntry(file: WorkspaceFileRecord(
                id: value.id,
                rootID: root.id,
                name: value.name,
                relativePath: value.relativePath,
                fullPath: value.fullPath,
                parentFolderID: nil
            ), root: longRoot)
        }
        let projectedEntries = ordinary.map(inLongRoot)
        let projected = try await makeProjected(projectedEntries, rootOverride: longRoot)
        let first = ordinary[0]
        let changed = ordered(projectedEntries.filter { $0.id != first.id } + [inLongRoot(entry("Changed.swift", id: first.id))])
        let privateBase = projected.applyingPatch(identity: identity(projected.identity.lifetimeID, 1), entries: changed, changedFileIDs: [first.id])
        XCTAssertFalse(privateBase.usesSharedRelativeBaseForTesting)
        XCTAssertNotNil(privateBase.projectedStorageOwnerForTesting)
        assertParity(privateBase, entries: changed)
    }

    func testSameParentUnicodeReplacementSurvivesFoldAndRebase() async throws {
        for (oldPath, newPath) in [("same/e\u{301}.swift", "same/é.swift"), ("same/\u{212A}.swift", "same/K.swift")] {
            let old = entry(oldPath)
            let original = ordered(makeEntries(count: 128) + [old])
            for projected in [false, true] {
                let held: WorkspaceSearchRootPathIndex = if projected { try await makeProjected(original) } else { makeIndex(original) }
                var current = ordered(original.filter { $0.id != old.id } + [entry(newPath, id: old.id)])
                var index = held.applyingPatch(identity: identity(held.identity.lifetimeID, 1), entries: current, changedFileIDs: [old.id])
                assertParity(index, entries: current, queries: ["", "e", "K", "swift"])
                let removed = current.removeFirst()
                index = index.applyingPatch(identity: identity(held.identity.lifetimeID, 2), entries: current, changedFileIDs: [removed.id], policy: .init(maximumWorkRatio: 1))
                assertParity(index, entries: current, queries: ["", "e", "K", "swift"])
                assertParity(held, entries: original, queries: ["", "e", "K", "swift"])
            }
        }
    }

    func testReloadedRootMapsFreshIdentitiesFromReusableSeed() async throws {
        let fixture = try await makeStore(count: 8)
        let value = await fixture.store.rootContextSnapshot()
        let held = try XCTUnwrap(value)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        let seed = try await makeSeed(entries: held.catalog.entries, root: fixture.root, directory: fixture.directory, artifacts: evidence)
        await fixture.store.unloadRoot(id: fixture.root.id)
        XCTAssertFalse(held.lifetimeIsCurrent())
        let restarted = WorkspaceFileContextStore(
            enableCatalogShardShadowValidation: false,
            codeMapsGloballyDisabled: true,
            codemapGraphIndexBuildLaunchPolicyForTesting: .disabled
        )
        addTeardownBlock {
            for root in await restarted.roots() {
                await restarted.unloadRoot(id: root.id)
            }
        }
        let reloaded = try await restarted.loadRoot(path: fixture.directory.path)
        _ = await restarted.rootContextSnapshot()
        let installed = await restarted.installProjectedPathSearchIndexForTesting(rootID: reloaded.id, snapshot: seed.0, plan: seed.1)
        XCTAssertTrue(installed)
        let reloadedValue = await restarted.rootContextSnapshot()
        let current = try XCTUnwrap(reloadedValue)
        XCTAssertNotEqual(current.catalog.rootPathIndexes[0].identity.lifetimeID, held.catalog.rootPathIndexes[0].identity.lifetimeID)
        XCTAssertTrue(Set(current.catalog.entries.map(\.id)).isDisjoint(with: Set(held.catalog.entries.map(\.id))))
        XCTAssertNotNil(current.catalog.rootPathIndexes[0].projectedStorageOwnerForTesting)
        XCTAssertTrue(current.catalog.rootPathIndexes[0].baseOwnerForTesting === seed.0.searchBase)
        assertParity(current.catalog.rootPathIndexes[0], entries: current.catalog.entries)
        await restarted.unloadRoot(id: reloaded.id)
    }

    func testEmptyBaseInitializesReusableKeys() {
        let empty = makeIndex([])
        let first = entry("First.swift")
        let index = empty.applyingPatch(identity: identity(empty.identity.lifetimeID, 1), entries: [first], changedFileIDs: [first.id])
        XCTAssertFalse(index.baseOwnerForTesting === empty.baseOwnerForTesting)
        XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
        let second = entry("Second.swift")
        let next = index.applyingPatch(identity: identity(empty.identity.lifetimeID, 2), entries: [first, second], changedFileIDs: [second.id])
        XCTAssertTrue(next.baseOwnerForTesting === index.baseOwnerForTesting)
        assertParity(next, entries: [first, second])
    }

    func testUnicodePathsAndPolicyBoundaryMatchFreshIndex() async throws {
        let unicode = ordered([entry("NFD/e\u{301}.swift"), entry("NFC/é.swift"), entry("Kelvin/\u{212A}.swift"), entry("ASCII/K.swift")])
        for index in try await [makeIndex(unicode), makeProjected(unicode)] {
            assertParity(index, entries: unicode, queries: ["", "e", "K", "é", "swift"])
        }
        let policy = WorkspacePathSearchCompactionPolicy.production
        XCTAssertFalse(policy.shouldRebase(
            baseCount: 4096,
            currentCount: 4096,
            overlayCount: 512,
            suppressedCount: 512,
            retainedKeyBytes: 4608,
            freshKeyBytes: 4096
        ))
        XCTAssertTrue(policy.shouldRebase(
            baseCount: 4096,
            currentCount: 4096,
            overlayCount: 513,
            suppressedCount: 513,
            retainedKeyBytes: 4609,
            freshKeyBytes: 4096
        ))
        XCTAssertFalse(policy.shouldRebase(
            baseCount: 4096,
            currentCount: 5120,
            overlayCount: 1024,
            suppressedCount: 0,
            retainedKeyBytes: 102_400,
            freshKeyBytes: 102_400
        ))
        XCTAssertTrue(policy.shouldRebase(
            baseCount: 4096,
            currentCount: 5119,
            overlayCount: 1024,
            suppressedCount: 1,
            retainedKeyBytes: 102_400,
            freshKeyBytes: 102_380
        ))
        XCTAssertFalse(policy.shouldRebase(
            baseCount: 128,
            currentCount: 128,
            overlayCount: 1,
            suppressedCount: 1,
            retainedKeyBytes: 8192,
            freshKeyBytes: 4096
        ))
        XCTAssertTrue(policy.shouldRebase(
            baseCount: 128,
            currentCount: 128,
            overlayCount: 1,
            suppressedCount: 1,
            retainedKeyBytes: 8191,
            freshKeyBytes: 4095
        ))
    }

    func testSingleFileEditsReuseSearchStorageWhileStoreGenerationsAdvance() async throws {
        for projected in [false, true] {
            let fixture = try await makeStore(count: 8)
            if projected { try await installProjected(fixture) }
            let initialValue = await fixture.store.rootContextSnapshot()
            var snapshot = try XCTUnwrap(initialValue).catalog
            let before = await fixture.store.storeWorkDiagnosticsSnapshot()
            let beforeGeneration = try XCTUnwrap(before.rootCatalogShards.roots.first { $0.rootID == fixture.root.id }?.lastAppliedIndexGeneration)
            let initial = try XCTUnwrap(snapshot.rootPathIndexes.first)
            let base = initial.baseOwnerForTesting
            let projectedOwner = initial.projectedStorageOwnerForTesting
            if projected { XCTAssertNotNil(projectedOwner) }
            let lifetime = try await fixture.store.rootLifetimeIDForTesting(rootID: fixture.root.id)
            for sequence in 1 ... 72 {
                let date = Date(timeIntervalSince1970: Double(1_800_000_000 + sequence))
                await fixture.store.replayObservedFileSystemDeltas(rootID: fixture.root.id, deltas: [.fileModified("File0000.swift", date)])
                let nextValue = await fixture.store.rootContextSnapshot()
                snapshot = try XCTUnwrap(nextValue).catalog
                let index = try XCTUnwrap(snapshot.rootPathIndexes.first)
                XCTAssertTrue(index.baseOwnerForTesting === base)
                if let projectedOwner { XCTAssertTrue(index.projectedStorageOwnerForTesting === projectedOwner) }
                XCTAssertEqual(index.overlayHistoryMetricsForTesting.totalPayloadCount, 0)
                let files = await fixture.store.files(inRoot: fixture.root.id)
                XCTAssertEqual(Set(files.map(\.id)), Set(snapshot.files.map(\.id)))
                let folderRecords = await fixture.store.folders(inRoot: fixture.root.id)
                let projectionValue = await fixture.store.catalogProjectionForTesting(rootID: fixture.root.id)
                let projection = try XCTUnwrap(projectionValue)
                XCTAssertEqual(Set(folderRecords), Set(projection.folders))
                XCTAssertEqual(projection.files, snapshot.files)
                XCTAssertEqual(projection.languages.map { Optional($0) }, Array(repeating: SyntaxManager.shared.language(forFileExtension: "swift"), count: snapshot.files.count))
                XCTAssertEqual(projection.indexByID, Dictionary(uniqueKeysWithValues: snapshot.files.enumerated().map { ($0.element.id, $0.offset) }))
                assertParity(index, entries: snapshot.entries)
            }
            let after = await fixture.store.storeWorkDiagnosticsSnapshot()
            XCTAssertEqual(after.rootCatalogShards.roots.first { $0.rootID == fixture.root.id }?.lastAppliedIndexGeneration, beforeGeneration + 72)
            let currentLifetime = try await fixture.store.rootLifetimeIDForTesting(rootID: fixture.root.id)
            XCTAssertEqual(currentLifetime, lifetime)
        }
    }

    func testProjectionNeutralGenerationRetagsWithoutReplacingSearchStorage() async throws {
        for projected in [false, true] {
            let fixture = try await makeStore(count: 8, ignoredFile: true)
            if projected { try await installProjected(fixture) }
            let oldValue = await fixture.store.rootContextSnapshot()
            let old = try XCTUnwrap(oldValue)
            let hidden = fixture.directory.appendingPathComponent("Hidden.ignored")
            try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: hidden)
            let result = try await fixture.store.materializeExplicitlyRequestedFile(hidden.path, rootScope: .allLoaded)
            guard case .materialized = result else { return XCTFail("Expected managed-only materialization") }
            let nextValue = await fixture.store.rootContextSnapshot()
            let next = try XCTUnwrap(nextValue)
            XCTAssertGreaterThan(next.roots[0].catalogGeneration, old.roots[0].catalogGeneration)
            XCTAssertTrue(next.catalog.rootPathIndexes[0].baseOwnerForTesting === old.catalog.rootPathIndexes[0].baseOwnerForTesting)
            XCTAssertEqual(next.catalog.entries.count, old.catalog.entries.count)
            assertParity(old.catalog.rootPathIndexes[0], entries: old.catalog.entries)
            assertParity(next.catalog.rootPathIndexes[0], entries: next.catalog.entries)
        }
    }

    func testRecordsOnlyEditsDoNotConstructPathIndexes() async throws {
        let fixture = try await makeStore(count: 8, indexed: false)
        for sequence in 1 ... 36 {
            await fixture.store.replayObservedFileSystemDeltas(rootID: fixture.root.id, deltas: [.fileModified("File0000.swift", Date(timeIntervalSince1970: Double(sequence)))])
            let snapshot = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded, requirement: .recordsOnly)
            XCTAssertTrue(snapshot.rootPathIndexes.isEmpty)
        }
        let promoted = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded)
        try assertParity(XCTUnwrap(promoted.rootPathIndexes.first), entries: promoted.entries)
    }

    func testPublisherCompletionIncludesIndexMaintenance() async throws {
        let fixture = try await makeStore(count: 8, policy: .init(maximumWorkRatio: 1))
        let initial = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded)
        let oldBase = try XCTUnwrap(initial.rootPathIndexes.first?.baseOwnerForTesting)
        let lifetime = try await fixture.store.rootLifetimeIDForTesting(rootID: fixture.root.id)
        let attached = try await fixture.store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: fixture.root.id)
        XCTAssertTrue(attached)
        let before = await fixture.store.storeWorkDiagnosticsSnapshot()
        let beforeGeneration = try XCTUnwrap(before.rootCatalogShards.roots.first { $0.rootID == fixture.root.id }?.lastAppliedIndexGeneration)
        let stream = await fixture.store.publisherIngressDebugSnapshotForTesting(rootID: fixture.root.id)
        try await fixture.store.publishSyntheticFileSystemDeltasForTesting(rootID: fixture.root.id, deltas: [.fileRemoved("File0000.swift")])
        let accepted = await fixture.store.publisherIngressDebugSnapshotForTesting(rootID: fixture.root.id)
        XCTAssertGreaterThan(accepted.acceptedServicePublicationSequence, stream.acceptedServicePublicationSequence)
        await fixture.store.waitUntilPublisherIngressAppliedForTesting(rootID: fixture.root.id, servicePublicationSequence: accepted.acceptedServicePublicationSequence)
        let projection = await fixture.store.catalogProjectionForTesting(rootID: fixture.root.id)
        XCTAssertEqual(projection?.files.count, 7)
        let completed = await fixture.store.publisherIngressDebugSnapshotForTesting(rootID: fixture.root.id)
        XCTAssertEqual(completed.acceptedAppliedSequenceGap, 0)
        let after = await fixture.store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(after.rootCatalogShards.roots.first { $0.rootID == fixture.root.id }?.lastAppliedIndexGeneration, beforeGeneration + 1)
        let snapshot = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded)
        let current = try XCTUnwrap(snapshot.rootPathIndexes.first)
        XCTAssertFalse(current.baseOwnerForTesting === oldBase)
        assertParity(current, entries: snapshot.entries)
        let currentLifetime = try await fixture.store.rootLifetimeIDForTesting(rootID: fixture.root.id)
        XCTAssertEqual(currentLifetime, lifetime)
    }

    func testCompactionAtReaderCapRecoversWithoutRevokingSnapshots() async throws {
        let fixture = try await makeStore(count: 8, policy: .init(maximumWorkRatio: 1))
        var held: [WorkspaceSearchCatalogSnapshot] = []
        for sequence in 1 ... 7 {
            try await fixture.store.applyIndexDeltasWithFakeDiskForTesting(
                rootID: fixture.root.id,
                deltas: [.fileModified("File0000.swift", Date(timeIntervalSince1970: Double(sequence)))]
            )
            let value = await fixture.store.rootContextSnapshot()
            try held.append(XCTUnwrap(value).catalog)
        }
        let oldBase = try XCTUnwrap(held.last?.rootPathIndexes.first?.baseOwnerForTesting)
        let oldResults = held.map { $0.rootPathIndexes[0].search("File", limit: 1024) }
        try await fixture.store.applyIndexDeltasWithFakeDiskForTesting(rootID: fixture.root.id, deltas: [.fileRemoved("File0007.swift")])
        let maintainedValue = await fixture.store.rootContextSnapshot()
        let maintained = try XCTUnwrap(maintainedValue).catalog
        XCTAssertFalse(try XCTUnwrap(maintained.rootPathIndexes.first).baseOwnerForTesting === oldBase)
        held.append(maintained)
        let before = await fixture.store.storeWorkDiagnosticsSnapshot()
        try await fixture.store.applyIndexDeltasWithFakeDiskForTesting(
            rootID: fixture.root.id,
            deltas: [.fileModified("File0000.swift", Date(timeIntervalSince1970: 99))]
        )
        let blocked = await fixture.store.storeWorkDiagnosticsSnapshot()
        XCTAssertGreaterThan(blocked.rootCatalogShards.totalBackstopCount, before.rootCatalogShards.totalBackstopCount)
        for (position, values) in oldResults.enumerated() {
            assertCandidates(held[position].rootPathIndexes[0].search("File", limit: 1024), values)
        }
        held.removeAll()
        let recovered = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded)
        try assertParity(XCTUnwrap(recovered.rootPathIndexes.first), entries: recovered.entries)
    }

    struct StoreFixture {
        let store: WorkspaceFileContextStore
        let root: WorkspaceRootRecord
        let directory: URL
    }

    func makeStore(count: Int, indexed: Bool = true, policy: WorkspacePathSearchCompactionPolicy = .production, ignoredFile: Bool = false) async throws -> StoreFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for position in 0 ..< count {
            try Data().write(to: directory.appendingPathComponent(String(format: "File%04d.swift", position)))
        }
        if ignoredFile {
            try Data("*.ignored\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
            try Data().write(to: directory.appendingPathComponent("Hidden.ignored"))
        }
        let store = WorkspaceFileContextStore(
            enableCatalogShardShadowValidation: false,
            pathSearchCompactionPolicyForTesting: policy,
            codeMapsGloballyDisabled: true,
            codemapGraphIndexBuildLaunchPolicyForTesting: .disabled
        )
        addTeardownBlock {
            for root in await store.roots() {
                await store.unloadRoot(id: root.id)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let root = try await store.loadRoot(path: directory.path)
        _ = await store.searchCatalogSnapshot(rootScope: .allLoaded, requirement: indexed ? .recordsAndPathIndexes : .recordsOnly)
        return StoreFixture(store: store, root: root, directory: directory)
    }

    func installProjected(_ fixture: StoreFixture) async throws {
        let snapshot = await fixture.store.searchCatalogSnapshot(rootScope: .allLoaded)
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: artifacts) }
        let seed = try await makeSeed(entries: snapshot.entries, root: fixture.root, directory: fixture.directory, artifacts: artifacts)
        let installed = await fixture.store.installProjectedPathSearchIndexForTesting(rootID: fixture.root.id, snapshot: seed.0, plan: seed.1)
        XCTAssertTrue(installed)
    }

    private func makeProjected(_ entries: [WorkspaceSearchCatalogEntry], rootOverride: WorkspaceRootRecord? = nil) async throws -> WorkspaceSearchRootPathIndex {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let projectedRoot = rootOverride ?? root
        let seed = try await makeSeed(entries: entries, root: projectedRoot, directory: directory)
        return try XCTUnwrap(WorkspaceSearchRootPathIndex(
            identity: identity(UUID(), 0),
            root: projectedRoot,
            projectedSnapshot: seed.0,
            projectedPlanHandle: seed.1,
            additionalChangedRelativePaths: .empty,
            entries: entries
        ))
    }

    func makeSeed(entries: [WorkspaceSearchCatalogEntry], root: WorkspaceRootRecord, directory: URL, artifacts: URL? = nil) async throws -> (WorkspaceRootReusableSnapshot, WorkspaceRootTargetSeedPlanHandle) {
        let paths = entries.map(\.standardizedRelativePath)
        let snapshot = try await WorkspaceRootSeedTestSupport.snapshot(paths: paths.map { ($0, "100644") })
        let fixture = try await WorkspaceRootTargetSeedPlanTestSupport.makeFixture(
            root: directory,
            storeRoot: artifacts ?? directory,
            snapshot: snapshot,
            namespaceRecords: paths.map { .init(relativePath: $0, kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644) },
            indexRecords: paths.enumerated().map { position, path in
                WorkspaceRootTargetSeedPlanTestSupport.indexRecord(path: path, objectID: WorkspaceRootSeedTestSupport.oid(Character(String(position % 8 + 1))))
            }
        )
        return (snapshot, fixture.handle)
    }

    private func makeEntries(count: Int) -> [WorkspaceSearchCatalogEntry] {
        (0 ..< count).map { entry(String(format: "File%04d.swift", $0)) }
    }

    private func entry(_ path: String, id: UUID = UUID()) -> WorkspaceSearchCatalogEntry {
        let file = WorkspaceFileRecord(
            id: id,
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.fullPath + "/" + path,
            parentFolderID: nil
        )
        return WorkspaceSearchCatalogEntry(file: file, root: root)
    }

    private func identity(_ lifetime: UUID, _ generation: Int) -> WorkspaceSearchRootPathIndexIdentity {
        .init(rootID: root.id, lifetimeID: lifetime, topologyGeneration: UInt64(generation))
    }

    private func makeIndex(_ entries: [WorkspaceSearchCatalogEntry], lifetime: UUID = UUID()) -> WorkspaceSearchRootPathIndex {
        WorkspaceSearchRootPathIndex(identity: identity(lifetime, 0), rootPath: root.fullPath, entries: entries)
    }

    private func ordered(_ entries: [WorkspaceSearchCatalogEntry]) -> [WorkspaceSearchCatalogEntry] {
        entries.sorted { WorkspaceFileContextStore.compareUTF8Binary($0.standardizedRelativePath, $1.standardizedRelativePath) == .orderedAscending }
    }

    private func assertCandidates(_ actual: [WorkspaceSearchRootPathIndex.Candidate], _ expected: [WorkspaceSearchRootPathIndex.Candidate], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (left, right) in zip(actual, expected) {
            XCTAssertTrue(left.entry.isByteIdentical(to: right.entry), file: file, line: line)
            XCTAssertEqual(left.score, right.score, file: file, line: line)
            XCTAssertEqual(Array(left.tieBreakKey.utf8), Array(right.tieBreakKey.utf8), file: file, line: line)
        }
    }

    func assertParity(_ index: WorkspaceSearchRootPathIndex, entries: [WorkspaceSearchCatalogEntry], queries: [String] = ["", "File", "swift", "0007"], file: StaticString = #filePath, line: UInt = #line) {
        let fresh = WorkspaceSearchRootPathIndex(identity: index.identity, rootPath: index.rootPath, entries: entries)
        for query in queries {
            for limit in [0, 1, 7, 1024, entries.count + 1] {
                assertCandidates(index.search(query, limit: limit), fresh.search(query, limit: limit), file: file, line: line)
            }
        }
    }
}
