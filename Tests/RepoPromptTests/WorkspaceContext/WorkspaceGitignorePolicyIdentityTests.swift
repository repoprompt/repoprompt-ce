import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptVCS
import XCTest

final class WorkspaceGitignorePolicyIdentityTests: XCTestCase {
    func testCurrentIdentityUsesGitIgnoreFloorV4() {
        XCTAssertEqual(WorkspaceGitignorePolicyIdentity.current, .gitIgnoreFloorV4)
        XCTAssertEqual(
            WorkspaceGitignorePolicyIdentity.current.rawValue,
            "mandatory-gitignore-floor-repository-excludes-v4"
        )
    }

    func testLoadedRootUsesMandatoryIdentityAndExcludesIgnoredFiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceGitignorePolicyIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("ignored.txt\n".utf8).write(to: rootURL.appendingPathComponent(".gitignore"))
        try Data("ignored".utf8).write(to: rootURL.appendingPathComponent("ignored.txt"))
        try Data("kept".utf8).write(to: rootURL.appendingPathComponent("kept.txt"))

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)

        let identity = await store.gitignorePolicyIdentityForTesting(rootID: root.id)
        let paths = await store.files(inRoot: root.id).map(\.standardizedRelativePath)
        XCTAssertEqual(identity, .gitIgnoreFloorV4)
        XCTAssertTrue(paths.contains("kept.txt"))
        XCTAssertFalse(paths.contains("ignored.txt"))
        await store.unloadRoot(id: root.id)
    }
}

// MARK: - Repository exclude policy and publication

final class WorkspaceRepositoryExcludeTests: XCTestCase {
    func testSharedRepositoryExcludesApplyToPrimaryAndLinkedWorktreeCatalogs() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let primary = try fixture.makeRepository(named: "primary", files: ["README.md": "fixture\n"])
        let linked = fixture.sandbox.appendingPathComponent("linked", isDirectory: true)
        try fixture.runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: primary)
        let primaryLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: primary))
        let linkedLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linked))
        XCTAssertTrue(linkedLayout.isWorktree)
        XCTAssertEqual(linkedLayout.commonDir, primaryLayout.commonDir)
        XCTAssertNotEqual(linkedLayout.gitDir, linkedLayout.commonDir)
        try fixture.write("/LocalCheckouts/\n", to: "info/exclude", at: primaryLayout.commonDir)

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        for rootURL in [primary, linked] {
            try fixture.write("struct Excluded {}\n", to: "LocalCheckouts/Nested/Excluded.swift", at: rootURL)
            try fixture.write("struct Kept {}\n", to: "Sources/Kept.swift", at: rootURL)
            let root = try await store.loadRoot(path: rootURL.path)
            let paths = await sourcePaths(in: store, rootID: root.id)
            XCTAssertEqual(paths, ["Sources/Kept.swift"], rootURL.lastPathComponent)
            await store.unloadRoot(id: root.id)
        }
    }

    func testGitignoreNegationsOverrideRepositoryExcludesButSecondaryNegationsCannot() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let rootURL = try fixture.makeRepository(named: "precedence", files: ["README.md": "fixture\n"])
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL))
        try fixture.write("*.swift\n", to: "info/exclude", at: layout.commonDir)
        try fixture.write(
            "!RootAllowed.swift\n!Nested/RootAllowed.swift\n",
            to: ".gitignore",
            at: rootURL
        )
        try fixture.write("!NestedAllowed.swift\n", to: "Nested/.gitignore", at: rootURL)
        try fixture.write(
            "!StillExcluded.swift\n!Nested/StillExcluded.swift\n",
            to: ".repo_ignore",
            at: rootURL
        )
        for path in [
            "RootAllowed.swift", "StillExcluded.swift", "Nested/RootAllowed.swift",
            "Nested/NestedAllowed.swift", "Nested/StillExcluded.swift"
        ] {
            try fixture.write("struct Fixture {}\n", to: path, at: rootURL)
        }

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        let paths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(paths, ["RootAllowed.swift", "Nested/RootAllowed.swift", "Nested/NestedAllowed.swift"])
        await store.unloadRoot(id: root.id)
    }

    func testSubdirectoryRootResolvesRepositoryRelativeExcludePatterns() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let repository = try fixture.makeRepository(named: "subdirectory", files: ["README.md": "fixture\n"])
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repository))
        try fixture.write(
            "/Project/Excluded.swift\n/OnlyAtRepositoryRoot.swift\nSharedBlocked.swift\n",
            to: "info/exclude",
            at: layout.commonDir
        )
        for path in [
            "OnlyAtRepositoryRoot.swift", "Project/Excluded.swift", "Project/OnlyAtRepositoryRoot.swift",
            "Project/Kept.swift", "Project/Nested/Kept.swift", "Project/Nested/SharedBlocked.swift"
        ] {
            try fixture.write("struct Fixture {}\n", to: path, at: repository)
        }
        let loadedURL = repository.appendingPathComponent("Project", isDirectory: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: loadedURL.path)
        let paths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(paths, ["OnlyAtRepositoryRoot.swift", "Kept.swift", "Nested/Kept.swift"])
        await store.unloadRoot(id: root.id)
    }

    func testSharedExcludeChangesReconcileBothLoadedRootsAndInvalidateCatalogSnapshots() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let primary = try fixture.makeRepository(named: "primary", files: ["README.md": "fixture\n"])
        let linked = fixture.sandbox.appendingPathComponent("linked", isDirectory: true)
        try fixture.runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: primary)
        let primaryLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: primary))
        let linkedLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linked))
        let keys = [primaryLayout, linkedLayout].map(GitWorkspaceAuthorityRepositoryKey.init(layout:))
        let excludeURL = primaryLayout.commonDir.appendingPathComponent("info/exclude")
        try fixture.write("/First.swift\n", to: "info/exclude", at: primaryLayout.commonDir)
        for rootURL in [primary, linked] {
            for path in ["First.swift", "Second.swift", "Kept.swift"] {
                try fixture.write("struct Fixture {}\n", to: path, at: rootURL)
            }
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let primaryRoot = try await store.loadRoot(path: primary.path)
        let linkedRoot = try await store.loadRoot(path: linked.path)
        let rootIDs = [primaryRoot.id, linkedRoot.id]
        for rootID in rootIDs {
            let paths = await sourcePaths(in: store, rootID: rootID)
            XCTAssertEqual(paths, ["Second.swift", "Kept.swift"])
        }
        let initialSnapshot = await store.searchCatalogSnapshot()

        // Index-only traffic must not rebuild otherwise unchanged source catalogs.
        for key in keys {
            await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                repositoryKey: key,
                invalidationGeneration: 1,
                acceptedMetadataWatermark: 1,
                kind: .metadata([.index])
            ))
        }
        for rootID in rootIDs {
            await store.waitForRepositoryExcludeReconciliationForTesting(rootID: rootID)
        }
        let afterIndexEvent = await store.searchCatalogSnapshot()
        XCTAssertEqual(afterIndexEvent, initialSnapshot)

        // Atomic replacement also changes the control's inode, exercising fresh authority reads.
        try "/Second.swift\n".write(to: excludeURL, atomically: true, encoding: .utf8)
        for key in keys {
            await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                repositoryKey: key,
                invalidationGeneration: 2,
                acceptedMetadataWatermark: 2,
                kind: .metadata([.ignoreAuthority])
            ))
        }
        for rootID in rootIDs {
            await store.waitForRepositoryExcludeReconciliationForTesting(rootID: rootID)
            let paths = await sourcePaths(in: store, rootID: rootID)
            XCTAssertEqual(paths, ["First.swift", "Kept.swift"])
        }
        let afterReplacement = await store.searchCatalogSnapshot()
        XCTAssertNotEqual(afterReplacement.generation, initialSnapshot.generation)
        XCTAssertEqual(
            Set(afterReplacement.files.filter { $0.name.hasSuffix(".swift") }.map(\.name)),
            ["First.swift", "Kept.swift"]
        )

        try FileManager.default.removeItem(at: excludeURL)
        for key in keys {
            await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                repositoryKey: key,
                invalidationGeneration: 3,
                acceptedMetadataWatermark: 3,
                kind: .metadata([.ignoreAuthority])
            ))
        }
        for rootID in rootIDs {
            await store.waitForRepositoryExcludeReconciliationForTesting(rootID: rootID)
            let paths = await sourcePaths(in: store, rootID: rootID)
            XCTAssertEqual(paths, ["First.swift", "Second.swift", "Kept.swift"])
        }
        let afterRemoval = await store.searchCatalogSnapshot()
        XCTAssertNotEqual(afterRemoval.generation, afterReplacement.generation)
        XCTAssertEqual(
            Set(afterRemoval.files.filter { $0.name.hasSuffix(".swift") }.map(\.name)),
            ["First.swift", "Second.swift", "Kept.swift"]
        )
        XCTAssertEqual(
            Set(initialSnapshot.files.filter { $0.name.hasSuffix(".swift") }.map(\.name)),
            ["Second.swift", "Kept.swift"],
            "Previously returned catalog snapshots must retain their immutable contents"
        )
        for rootID in rootIDs {
            await store.unloadRoot(id: rootID)
        }
    }

    func testGitDirectoryRebindObservesExcludesInTheNewCommonDirectory() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let firstRepository = try fixture.makeRepository(named: "first", files: ["README.md": "fixture\n"])
        let secondRepository = try fixture.makeRepository(named: "second", files: ["README.md": "fixture\n"])
        let loadedURL = fixture.sandbox.appendingPathComponent("loaded-worktree", isDirectory: true)
        let replacementURL = fixture.sandbox.appendingPathComponent("replacement-worktree", isDirectory: true)
        try fixture.runGit(["worktree", "add", "--detach", loadedURL.path, "HEAD"], at: firstRepository)
        try fixture.runGit(["worktree", "add", "--detach", replacementURL.path, "HEAD"], at: secondRepository)
        let initialLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: loadedURL))
        let replacementLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: replacementURL))
        XCTAssertNotEqual(initialLayout.commonDir, replacementLayout.commonDir)
        for layout in [initialLayout, replacementLayout] {
            try fixture.write("/First.swift\n", to: "info/exclude", at: layout.commonDir)
        }
        for path in ["First.swift", "Second.swift", "Kept.swift"] {
            try fixture.write("struct Fixture {}\n", to: path, at: loadedURL)
        }

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: loadedURL.path)
        let initialPaths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(initialPaths, ["Second.swift", "Kept.swift"])

        // Both controls have identical contents: topology must rebind even without a rule change.
        try fixture.write("gitdir: \(replacementLayout.gitDir.path)\n", to: ".git", at: loadedURL)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: initialLayout),
            invalidationGeneration: 1,
            acceptedMetadataWatermark: 1,
            kind: .metadata([.dotGit])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: root.id)
        let reboundLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: loadedURL))
        XCTAssertEqual(reboundLayout.commonDir, replacementLayout.commonDir)
        let reboundPaths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(reboundPaths, initialPaths)

        try fixture.write("/Second.swift\n", to: "info/exclude", at: replacementLayout.commonDir)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: reboundLayout),
            invalidationGeneration: 2,
            acceptedMetadataWatermark: 2,
            kind: .metadata([.ignoreAuthority])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: root.id)
        let changedPaths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(changedPaths, ["First.swift", "Kept.swift"])
        await store.unloadRoot(id: root.id)
    }

    func testPolicyChangeBeforePublicationRejectsStaleCrawlAndPreservesRestoredFiles() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let rootURL = try fixture.makeRepository(named: "publication-race", files: ["README.md": "fixture\n"])
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL))
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let excludeURL = layout.commonDir.appendingPathComponent("info/exclude")
        try fixture.write("/First.swift\n", to: "info/exclude", at: layout.commonDir)
        for path in ["First.swift", "Second.swift", "Third.swift", "Kept.swift"] {
            try fixture.write("struct Fixture {}\n", to: path, at: rootURL)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        let rootID = root.id
        let initialPaths = await sourcePaths(in: store, rootID: rootID)
        XCTAssertEqual(initialPaths, ["Second.swift", "Third.swift", "Kept.swift"])
        let probe = RepositoryExcludePublicationProbe()
        await store.setRepositoryExcludeWillPublishHandlerForTesting {
            let files = await store.files(inRoot: rootID)
            let paths = Set(files.map(\.standardizedRelativePath).filter { $0.hasSuffix(".swift") })
            guard await probe.record(paths) else { return }
            do {
                try "/Third.swift\n".write(to: excludeURL, atomically: true, encoding: .utf8)
                await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                    repositoryKey: key,
                    invalidationGeneration: 2,
                    acceptedMetadataWatermark: 2,
                    kind: .metadata([.ignoreAuthority])
                ))
            } catch {
                await probe.recordFailure(String(describing: error))
            }
        }
        try "/Second.swift\n".write(to: excludeURL, atomically: true, encoding: .utf8)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: key,
            invalidationGeneration: 1,
            acceptedMetadataWatermark: 1,
            kind: .metadata([.ignoreAuthority])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: rootID)
        await store.setRepositoryExcludeWillPublishHandlerForTesting(nil)

        let mutationFailure = await probe.failure
        let observedPaths = await probe.observedPaths
        XCTAssertNil(mutationFailure)
        XCTAssertGreaterThanOrEqual(observedPaths.count, 2)
        XCTAssertTrue(
            observedPaths.allSatisfy { $0 == initialPaths },
            "A rejected crawl must never replace the published catalog before a fresh attempt succeeds"
        )
        let finalPaths = await sourcePaths(in: store, rootID: rootID)
        XCTAssertEqual(finalPaths, ["First.swift", "Second.swift", "Kept.swift"])
        await store.unloadRoot(id: rootID)
    }

    func testMalformedRepositoryExcludeBlocksReadinessSearchAndCachedReadsUntilRecovery() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let rootURL = try fixture.makeRepository(named: "malformed-control", files: ["README.md": "fixture\n"])
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL))
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let excludeURL = layout.commonDir.appendingPathComponent("info/exclude")
        try fixture.write("/First.swift\n", to: "info/exclude", at: layout.commonDir)
        for path in ["First.swift", "Second.swift", "Kept.swift"] {
            try fixture.write("struct Fixture {}\n", to: path, at: rootURL)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        let refs = await store.rootRefs(scope: .visibleWorkspace)
        let scope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(canonicalRoots: Set(refs), physicalRoots: [])
        let initialContent = try await store.readContent(rootID: root.id, relativePath: "Kept.swift")
        XCTAssertEqual(initialContent, "struct Fixture {}\n")

        try FileManager.default.removeItem(at: excludeURL)
        try FileManager.default.createDirectory(at: excludeURL, withIntermediateDirectories: false)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: key,
            invalidationGeneration: 1,
            acceptedMetadataWatermark: 1,
            kind: .metadata([.ignoreAuthority])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: root.id)
        let blockedReadiness = await store.primaryRootReadinessObservation(orderedPaths: [root.standardizedFullPath])
        XCTAssertEqual(blockedReadiness.nonqueryablePaths, [root.standardizedFullPath])
        let blockedAvailability = await store.rootScopeAvailability(scope)
        XCTAssertEqual(blockedAvailability, .sessionWorktreeUnavailable(missingPhysicalRootPaths: [root.standardizedFullPath]))
        let blockedSearch = await store.searchCatalogAccess(rootScope: scope)
        XCTAssertEqual(blockedSearch, .unavailable(blockedAvailability))
        do {
            _ = try await store.readContent(rootID: root.id, relativePath: "Kept.swift")
            XCTFail("Previously cached content must not bypass an unreadable mandatory ignore control")
        } catch {
            XCTAssertEqual(error as? WorkspaceSessionWorktreeOwnershipError, .unavailableRoot(root.standardizedFullPath))
        }

        try FileManager.default.removeItem(at: excludeURL)
        try "/Second.swift\n".write(to: excludeURL, atomically: true, encoding: .utf8)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: key,
            invalidationGeneration: 2,
            acceptedMetadataWatermark: 2,
            kind: .metadata([.ignoreAuthority])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: root.id)
        let recoveredReadiness = await store.primaryRootReadinessObservation(orderedPaths: [root.standardizedFullPath])
        XCTAssertTrue(recoveredReadiness.nonqueryablePaths.isEmpty)
        let recoveredAvailability = await store.rootScopeAvailability(scope)
        XCTAssertEqual(recoveredAvailability, .available)
        let recoveredSearch = await store.searchCatalogAccess(rootScope: scope)
        if case let .available(snapshot) = recoveredSearch {
            XCTAssertEqual(
                Set(snapshot.files.filter { $0.name.hasSuffix(".swift") }.map(\.name)),
                ["First.swift", "Kept.swift"]
            )
        } else {
            XCTFail("Valid replacement ignore rules must restore scoped search availability")
        }
        let recoveredContent = try await store.readContent(rootID: root.id, relativePath: "Kept.swift")
        XCTAssertEqual(recoveredContent, initialContent)
        await store.unloadRoot(id: root.id)
    }

    func testRepositoryExcludeReconciliationPreservesExplicitlyManagedIgnoredFileIdentity() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let rootURL = try fixture.makeRepository(named: "managed-file", files: ["README.md": "fixture\n"])
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL))
        try fixture.write("/.private/\n/First.swift\n", to: "info/exclude", at: layout.commonDir)
        for path in ["First.swift", "Second.swift", ".private/kept.swift"] {
            try fixture.write("struct Fixture {}\n", to: path, at: rootURL)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        let materialized = try await store.materializeExplicitlyRequestedFile(rootURL.appendingPathComponent(".private/kept.swift").path)
        guard case let .materialized(managedFile) = materialized else {
            await store.unloadRoot(id: root.id)
            return XCTFail("An explicitly requested ignored file must materialize")
        }
        let before = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(before, ["Second.swift"])

        try fixture.write("/.private/\n/Second.swift\n", to: "info/exclude", at: layout.commonDir)
        await store.handleRepositoryExcludeInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            invalidationGeneration: 1,
            acceptedMetadataWatermark: 1,
            kind: .metadata([.ignoreAuthority])
        ))
        await store.waitForRepositoryExcludeReconciliationForTesting(rootID: root.id)
        let retained = await store.file(rootID: root.id, relativePath: ".private/kept.swift")
        XCTAssertEqual(retained?.id, managedFile.id)
        let paths = await sourcePaths(in: store, rootID: root.id)
        XCTAssertEqual(paths, ["First.swift"], "The explicitly managed file must stay excluded from discovery")
        let retainedContent = try await store.readContent(rootID: root.id, relativePath: ".private/kept.swift")
        XCTAssertEqual(retainedContent, "struct Fixture {}\n")
        await store.unloadRoot(id: root.id)
    }

    private func sourcePaths(in store: WorkspaceFileContextStore, rootID: UUID) async -> Set<String> {
        let files = await store.files(inRoot: rootID)
        return Set(files.map(\.standardizedRelativePath).filter { $0.hasSuffix(".swift") })
    }
}

private actor RepositoryExcludePublicationProbe {
    private(set) var observedPaths: [Set<String>] = []
    private(set) var failure: String?

    func record(_ paths: Set<String>) -> Bool {
        observedPaths.append(paths)
        return observedPaths.count == 1
    }

    func recordFailure(_ description: String) {
        failure = description
    }
}
