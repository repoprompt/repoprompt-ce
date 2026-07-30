@testable import RepoPromptApp
import XCTest

final class WorkspacePublishedGitArtifactIngressTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testLoadedBeforeWriteIngressCatalogsExactSnapshotWithoutWatcherDelivery() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactIngress")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        try FileSystemTestSupport.write("repos/\n", to: gitDataRoot.appendingPathComponent(".gitignore"))

        let store = WorkspaceFileContextStore()
        let loadedRoot = try await store.loadRoot(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let rootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let root = try XCTUnwrap(rootValue)
        XCTAssertEqual(root.id, loadedRoot.id)

        let published = try makePublishedSet(workspace: workspace)
        for artifact in published.orderedArtifacts {
            try FileSystemTestSupport.write(
                "content:\(artifact.kind)",
                to: URL(fileURLWithPath: artifact.absolutePath)
            )
        }

        let result = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: published.orderedArtifacts + [published.map]
            )
        )

        XCTAssertEqual(result.outcomes.count, published.orderedArtifacts.count + 1)
        XCTAssertTrue(result.outcomes.dropLast().allSatisfy { $0.status.record != nil })
        XCTAssertEqual(
            result.outcomes.last?.status,
            .duplicateOf(path: published.map.absolutePath)
        )
        XCTAssertNil(result.failuresByArtifact[published.map])
        XCTAssertEqual(
            result.selectionReadyArtifacts(for: published),
            published.primarySelectionArtifacts
        )
        XCTAssertEqual(
            result.advertisementReadyArtifacts(for: published),
            published.advertisedSelectionArtifacts
        )

        for artifact in published.orderedArtifacts {
            let record = try XCTUnwrap(result.recordsByAbsolutePath[artifact.absolutePath])
            let exactRecord = await store.exactCatalogFile(
                absolutePath: artifact.absolutePath,
                expectedRoot: root,
                expectedKind: .workspaceGitData
            )
            XCTAssertEqual(exactRecord, record, artifact.absolutePath)
            let content = await store.readExactCatalogFile(record, expectedRoot: root)
            XCTAssertEqual(content, "content:\(artifact.kind)", artifact.absolutePath)
        }

        let discoverableFiles = await store.files(inRoot: root.id)
        XCTAssertFalse(discoverableFiles.contains { $0.standardizedRelativePath.hasPrefix("repos/") })
        let searchSnapshot = await store.searchCatalogSnapshot(
            rootScope: .visibleWorkspacePlusGitData
        )
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedRelativePath.hasPrefix("repos/") })
        let sessionRoots = await store.rootRefs(scope: .sessionBoundWorkspace(
            canonicalRootPaths: [],
            physicalRootPaths: []
        ))
        XCTAssertFalse(sessionRoots.contains { $0.id == root.id })
    }

    func testPartialIngressRequiresManifestAndCandidateReadiness() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactPartial")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let rootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let root = try XCTUnwrap(rootValue)
        let published = try makePublishedSet(workspace: workspace)

        for artifact in [published.manifest, published.map] + published.perFilePatches {
            try FileSystemTestSupport.write(
                "content:\(artifact.kind)",
                to: URL(fileURLWithPath: artifact.absolutePath)
            )
        }

        let result = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: published.orderedArtifacts
            )
        )

        let allPatch = try XCTUnwrap(published.allPatch)
        let allPatchOutcome = try XCTUnwrap(result.outcomes.first {
            $0.artifact == allPatch
        })
        XCTAssertEqual(allPatchOutcome.status, .missingOnDisk)
        XCTAssertEqual(result.failuresByArtifact[allPatch], .missingOnDisk)
        XCTAssertEqual(result.selectionReadyArtifacts(for: published), [published.map])
        XCTAssertNotNil(result.recordsByAbsolutePath[published.perFilePatches[0].absolutePath])
        XCTAssertEqual(
            result.advertisementReadyArtifacts(for: published),
            [published.map] + published.perFilePatches
        )

        let withoutManifest = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: [published.map]
            )
        )
        XCTAssertTrue(withoutManifest.selectionReadyArtifacts(for: published).isEmpty)
        XCTAssertTrue(withoutManifest.advertisementReadyArtifacts(for: published).isEmpty)
    }

    func testWrongRootKindLifetimeAndTraversalFailClosedWithOrderedOutcomes() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactFailures")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore()
        let loaded = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let rootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let root = try XCTUnwrap(rootValue)
        let published = try makePublishedSet(workspace: workspace)
        try FileSystemTestSupport.write("map", to: URL(fileURLWithPath: published.map.absolutePath))

        let traversal = GitDiffPublishedArtifact(
            kind: .map,
            absolutePath: published.map.absolutePath,
            gitDataRelativePath: "repos/repo-key/2026-06-19/2307/../MAP.txt",
            clientAlias: nil,
            selectionDisposition: .primaryAutoSelect
        )
        let outside = GitDiffPublishedArtifact(
            kind: .map,
            absolutePath: workspace.appendingPathComponent("outside/MAP.txt").path,
            gitDataRelativePath: published.map.gitDataRelativePath,
            clientAlias: nil,
            selectionDisposition: .primaryAutoSelect
        )
        let mixed = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: [traversal, published.map, outside]
            )
        )
        XCTAssertEqual(mixed.outcomes[0].status, .invalidRelativePath)
        XCTAssertNotNil(mixed.outcomes[1].status.record)
        XCTAssertEqual(mixed.outcomes[2].status, .outsideExpectedRoot)

        let primaryWorkspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactWrongKind")
        _ = try await store.loadRoot(path: primaryWorkspace.path, kind: .primaryWorkspace)
        let wrongKindRootValue = await store.exactRootRef(
            path: primaryWorkspace.path,
            kind: .primaryWorkspace
        )
        let wrongKindRoot = try XCTUnwrap(wrongKindRootValue)
        let wrongKind = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: wrongKindRoot,
                artifacts: [published.map]
            )
        )
        XCTAssertEqual(wrongKind.outcomes.map(\.status), [.staleRoot])

        let otherWorkspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactWrongRoot")
        let otherGitDataRoot = otherWorkspace.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: otherGitDataRoot, withIntermediateDirectories: true)
        _ = try await store.loadRoot(path: otherGitDataRoot.path, kind: .workspaceGitData)
        let wrongRootValue = await store.exactRootRef(
            path: otherGitDataRoot.path,
            kind: .workspaceGitData
        )
        let wrongRoot = try XCTUnwrap(wrongRootValue)
        let wrongRootResult = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: wrongRoot,
                artifacts: [published.map]
            )
        )
        XCTAssertEqual(wrongRootResult.outcomes.map(\.status), [.outsideExpectedRoot])

        await store.unloadRoot(id: loaded.id)
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let stale = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: [published.map]
            )
        )
        XCTAssertEqual(stale.outcomes.map(\.status), [.staleRoot])
    }

    func testRootUnloadDuringIngressInvalidatesWholeBatch() async throws {
        #if DEBUG
            let workspace = try temporaryRoots.makeRoot(suiteName: "PublishedGitArtifactLifetimeRace")
            let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
            try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
            let rootValue = await store.exactRootRef(
                path: gitDataRoot.path,
                kind: .workspaceGitData
            )
            let root = try XCTUnwrap(rootValue)
            let published = try makePublishedSet(workspace: workspace)
            for artifact in published.orderedArtifacts {
                try FileSystemTestSupport.write(
                    "content:\(artifact.kind)",
                    to: URL(fileURLWithPath: artifact.absolutePath)
                )
            }

            await store.setPublishedGitArtifactIngressDidRegisterHandler { rootID, relativePath in
                guard relativePath == published.map.gitDataRelativePath else { return }
                await store.unloadRoot(id: rootID)
            }
            let result = await store.ingressPublishedGitArtifacts(
                WorkspacePublishedGitArtifactIngressRequest(
                    root: root,
                    artifacts: published.orderedArtifacts
                )
            )
            await store.setPublishedGitArtifactIngressDidRegisterHandler(nil)

            XCTAssertEqual(result.outcomes.count, published.orderedArtifacts.count)
            XCTAssertTrue(result.outcomes.allSatisfy { $0.status == .staleRoot })
            XCTAssertTrue(result.recordsByAbsolutePath.isEmpty)
            XCTAssertTrue(result.selectionReadyArtifacts(for: published).isEmpty)
        #endif
    }

    private func makePublishedSet(workspace: URL) throws -> GitDiffPublishedArtifactSet {
        let snapshotID = "2026-06-19/2307"
        let repoKey = "repo-key"
        let ref = GitDiffSnapshotStore.GitDiffSnapshotRef(
            repoKey: repoKey,
            snapshotID: snapshotID
        )
        let snapshotDirectory = workspace.appendingPathComponent(
            "_git_data/repos/\(repoKey)/\(snapshotID)",
            isDirectory: true
        )
        let manifest = GitDiffSnapshotManifest(
            snapshotID: snapshotID,
            generatedAt: Date(timeIntervalSince1970: 1),
            mode: .standard,
            compare: "HEAD",
            compareInput: nil,
            scope: .selected,
            requestedPaths: ["Sources/App.swift"],
            fingerprint: GitDiffFingerprint(
                headSHA: "abc",
                baseRef: "HEAD",
                statusHash: "status",
                generatedAt: Date(timeIntervalSince1970: 1)
            ),
            contextLines: 3,
            detectRenames: false,
            summary: GitDiffSnapshotManifest.Summary(files: 1, insertions: 1, deletions: 0),
            files: [GitDiffSnapshotManifest.FileEntry(
                gitPath: "Sources/App.swift",
                status: "M",
                additions: 1,
                deletions: 0,
                patchPath: "diff/per-file/Sources-App.swift.patch",
                bytes: 12,
                lines: 1,
                hunks: nil
            )],
            repoKey: repoKey,
            repoRoot: workspace.appendingPathComponent("Repo").path
        )
        return try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: snapshotDirectory,
            snapshotRef: ref,
            manifest: manifest,
            allPatchRelativePath: "diff/all.patch"
        )
    }
}
