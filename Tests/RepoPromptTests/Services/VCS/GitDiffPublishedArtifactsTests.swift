@testable import RepoPrompt
import XCTest

final class GitDiffPublishedArtifactsTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testBuildsExactIdentitiesAliasesAndPrimaryOrdering() throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "GitDiffPublishedArtifacts")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let snapshotID = "2026-06-19/2307"
        let repoKey = "repo-key"
        let ref = GitDiffSnapshotStore.GitDiffSnapshotRef(
            repoKey: repoKey,
            snapshotID: snapshotID
        )
        let snapshotDirectory = gitDataRoot.appendingPathComponent(
            "repos/\(repoKey)/\(snapshotID)",
            isDirectory: true
        )
        let manifest = makeManifest(
            snapshotID: snapshotID,
            repoKey: repoKey,
            patchPaths: [
                "diff/per-file/Sources-App.swift.patch",
                "diff/per-file/Sources-App.swift.patch",
                "diff/per-file/Tests-AppTests.swift.diff"
            ]
        )

        let published = try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: snapshotDirectory,
            snapshotRef: ref,
            manifest: manifest,
            allPatchRelativePath: "diff/all.patch"
        )

        XCTAssertEqual(published.snapshotRef, ref)
        XCTAssertEqual(published.snapshotDirectoryPath, snapshotDirectory.path)
        XCTAssertEqual(
            published.orderedArtifacts.map(\.kind),
            [.manifest, .map, .allPatch, .perFilePatch, .perFilePatch]
        )
        XCTAssertEqual(
            published.orderedArtifacts.map(\.gitDataRelativePath),
            [
                "repos/\(repoKey)/\(snapshotID)/manifest.json",
                "repos/\(repoKey)/\(snapshotID)/MAP.txt",
                "repos/\(repoKey)/\(snapshotID)/diff/all.patch",
                "repos/\(repoKey)/\(snapshotID)/diff/per-file/Sources-App.swift.patch",
                "repos/\(repoKey)/\(snapshotID)/diff/per-file/Tests-AppTests.swift.diff"
            ]
        )
        XCTAssertEqual(
            published.orderedArtifacts.map(\.absolutePath),
            [
                snapshotDirectory.appendingPathComponent("manifest.json").path,
                snapshotDirectory.appendingPathComponent("MAP.txt").path,
                snapshotDirectory.appendingPathComponent("diff/all.patch").path,
                snapshotDirectory.appendingPathComponent("diff/per-file/Sources-App.swift.patch").path,
                snapshotDirectory.appendingPathComponent("diff/per-file/Tests-AppTests.swift.diff").path
            ]
        )
        XCTAssertEqual(
            published.primarySelectionArtifacts.map(\.clientAlias),
            [
                "_git_data/repos/\(repoKey)/\(snapshotID)/MAP.txt",
                "_git_data/repos/\(repoKey)/\(snapshotID)/diff/all.patch"
            ]
        )
        XCTAssertEqual(
            GitDiffPrimaryArtifacts(publishedArtifacts: published).selectionCandidates,
            published.primarySelectionArtifacts.compactMap(\.clientAlias)
        )
    }

    func testRejectsUnsafeManifestPatchPathsAndIdentityMismatches() throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "GitDiffPublishedArtifactsUnsafe")
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
        let unsafePaths = [
            "",
            "/diff/absolute.patch",
            "~/diff/home.patch",
            "diff/../escape.patch",
            "diff//empty.patch",
            "diff/colon:name.patch",
            "diff/nul\0name.patch",
            "diff/not-a-patch.txt",
            "diff/all.patch"
        ]

        for unsafePath in unsafePaths {
            XCTAssertThrowsError(
                try GitDiffPublishedArtifactSet(
                    snapshotDirectoryURL: snapshotDirectory,
                    snapshotRef: ref,
                    manifest: makeManifest(
                        snapshotID: snapshotID,
                        repoKey: repoKey,
                        patchPaths: [unsafePath]
                    ),
                    allPatchRelativePath: nil
                ),
                unsafePath
            ) { error in
                XCTAssertEqual(
                    error as? GitDiffPublishedArtifactError,
                    .unsafeRelativePath(unsafePath),
                    unsafePath
                )
            }
        }

        XCTAssertThrowsError(try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: snapshotDirectory,
            snapshotRef: ref,
            manifest: makeManifest(
                snapshotID: snapshotID,
                repoKey: "other-repo",
                patchPaths: []
            ),
            allPatchRelativePath: nil
        )) { error in
            XCTAssertEqual(error as? GitDiffPublishedArtifactError, .manifestIdentityMismatch)
        }
    }

    private func makeManifest(
        snapshotID: String,
        repoKey: String,
        patchPaths: [String]
    ) -> GitDiffSnapshotManifest {
        GitDiffSnapshotManifest(
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
            summary: GitDiffSnapshotManifest.Summary(
                files: patchPaths.count,
                insertions: patchPaths.count,
                deletions: 0
            ),
            files: patchPaths.enumerated().map { index, patchPath in
                GitDiffSnapshotManifest.FileEntry(
                    gitPath: "Sources/File\(index).swift",
                    status: "M",
                    additions: 1,
                    deletions: 0,
                    patchPath: patchPath,
                    bytes: 12,
                    lines: 1,
                    hunks: nil
                )
            },
            repoKey: repoKey,
            repoRoot: "/repo"
        )
    }
}
