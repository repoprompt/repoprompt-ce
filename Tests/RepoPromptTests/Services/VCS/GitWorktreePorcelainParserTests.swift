import Foundation
@testable import RepoPromptApp
import RepoPromptVCS
import RepoPromptWorkspaceCore
import XCTest

final class GitWorktreePorcelainParserTests: XCTestCase {
    func testParseNULTerminatedNormalMainAndLinkedWorktree() throws {
        let output = [
            "worktree /tmp/repo",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /tmp/repo-feature",
            "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/feature/test",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/tmp/repo")
        XCTAssertEqual(records[0].head, "1111111111111111111111111111111111111111")
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertFalse(records[0].isDetached)
        XCTAssertFalse(records[0].isLocked)
        XCTAssertFalse(records[0].isPrunable)
        XCTAssertEqual(records[1].path, "/tmp/repo-feature")
        XCTAssertEqual(records[1].branch, "feature/test")
    }

    func testParseNULTerminatedDetachedLockedPrunableRecordsWithNewlinesInReasons() throws {
        let output = [
            "worktree /tmp/repo-detached",
            "HEAD 3333333333333333333333333333333333333333",
            "detached",
            "locked keep this\nreason intact",
            "prunable stale admin\nreason intact",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, "/tmp/repo-detached")
        XCTAssertNil(records[0].branch)
        XCTAssertTrue(records[0].isDetached)
        XCTAssertTrue(records[0].isLocked)
        XCTAssertEqual(records[0].lockReason, "keep this\nreason intact")
        XCTAssertTrue(records[0].isPrunable)
        XCTAssertEqual(records[0].prunableReason, "stale admin\nreason intact")
    }

    func testParseNULTerminatedPreservesExactPathsWithTrailingWhitespaceAndNewlines() throws {
        let exactPath = "/tmp/repo with suffix \n"
        let output = [
            "worktree \(exactPath)",
            "HEAD 4444444444444444444444444444444444444444",
            "branch refs/heads/main",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, exactPath)
    }

    func testParseNewlineTerminatedFallback() throws {
        let output = """
        worktree /tmp/repo
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/main

        worktree /tmp/repo-linked
        HEAD 5555555555555555555555555555555555555555
        detached
        """

        let records = try GitWorktreePorcelainParser.parse(output, format: .newlineTerminated)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/tmp/repo")
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertEqual(records[1].path, "/tmp/repo-linked")
        XCTAssertTrue(records[1].isDetached)
    }

    func testParseLockedAndPrunableWithoutReasons() throws {
        let output = [
            "worktree /tmp/repo-linked",
            "HEAD 6666666666666666666666666666666666666666",
            "branch refs/heads/topic",
            "locked",
            "prunable",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].isLocked)
        XCTAssertNil(records[0].lockReason)
        XCTAssertTrue(records[0].isPrunable)
        XCTAssertNil(records[0].prunableReason)
    }

    func testParseMalformedRecordsThrowBranchSpecificErrors() {
        let scenarios = [
            ("attribute before worktree", "HEAD abc\0", "before worktree path"),
            ("empty worktree path", "worktree \0HEAD abc\0", "missing a path")
        ]

        for scenario in scenarios {
            XCTAssertThrowsError(try GitWorktreePorcelainParser.parse(scenario.1, format: .nulTerminated), scenario.0) { error in
                guard case let VCSError.parseError(message) = error else {
                    XCTFail("Expected parseError, got \(error)", file: #filePath, line: #line)
                    return
                }
                XCTAssertTrue(message.contains(scenario.2), scenario.0)
            }
        }
    }

    func testStandardizedPathAliasesCollapseOnlyForEquivalentRepositoryLayouts() throws {
        let canonicalPath = "/tmp/repo"
        let aliasPath = "/tmp/repo/linked/.."
        let output = [
            "worktree \(aliasPath)",
            "HEAD 7777777777777777777777777777777777777777",
            "branch refs/heads/main",
            "",
            "worktree \(canonicalPath)",
            "HEAD 7777777777777777777777777777777777777777",
            "branch refs/heads/main",
            ""
        ].joined(separator: "\0")
        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)
        let commonDirectory = URL(fileURLWithPath: "/tmp/repo/.git")

        func layout(
            root: URL,
            commonDirectory: URL,
            marksDirectories: Bool = false
        ) -> GitRepositoryLayout {
            let markedRoot = URL(fileURLWithPath: root.path, isDirectory: marksDirectories)
            let markedCommonDirectory = URL(
                fileURLWithPath: commonDirectory.path,
                isDirectory: marksDirectories
            )
            return GitRepositoryLayout(
                workTreeRoot: markedRoot,
                dotGitPath: markedRoot.appendingPathComponent(".git", isDirectory: marksDirectories),
                gitDir: markedCommonDirectory.appendingPathComponent("worktrees/repo", isDirectory: marksDirectories),
                commonDir: markedCommonDirectory,
                isWorktree: true
            )
        }

        let resolution = try GitService.collapseEquivalentWorktreeAliases(records) {
            layout(root: $0, commonDirectory: commonDirectory)
        }

        XCTAssertEqual(resolution.records.count, 1)
        XCTAssertEqual(resolution.collapsedAliasCount, 1)
        XCTAssertEqual(resolution.records[0].record.path, canonicalPath)
        XCTAssertEqual(resolution.records[0].pathURL.path, canonicalPath)
        XCTAssertEqual(resolution.records[0].layout?.workTreeRoot.path, canonicalPath)

        var directoryMarkerIndex = 0
        let directoryMarkerResolution = try GitService.collapseEquivalentWorktreeAliases(records) { root in
            defer { directoryMarkerIndex += 1 }
            return layout(
                root: root,
                commonDirectory: commonDirectory,
                marksDirectories: directoryMarkerIndex == 0
            )
        }
        XCTAssertEqual(directoryMarkerResolution.records.count, 1)
        XCTAssertEqual(directoryMarkerResolution.collapsedAliasCount, 1)
        XCTAssertEqual(directoryMarkerResolution.records[0].layout?.workTreeRoot.hasDirectoryPath, true)

        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { _ in nil }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var partialLayoutIndex = 0
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { root in
                defer { partialLayoutIndex += 1 }
                return partialLayoutIndex == 0
                    ? layout(root: root, commonDirectory: commonDirectory)
                    : nil
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var layoutIndex = 0
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { root in
                defer { layoutIndex += 1 }
                let resolvedCommonDirectory = layoutIndex == 0
                    ? commonDirectory
                    : URL(fileURLWithPath: "/tmp/other-repo/.git")
                return layout(root: root, commonDirectory: resolvedCommonDirectory)
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var conflictingRecords = records
        conflictingRecords[1].branch = "topic"
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(conflictingRecords) {
                layout(root: $0, commonDirectory: commonDirectory)
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .recordMetadata)
        }
    }

    func testWorktreeListZFallsBackOnlyForUnsupportedCapabilityFailures() {
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("error: unknown option `z'"))
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("usage: git worktree list [<options>]"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: not a git repository"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: bad object HEAD"))
    }
}

/// Pins the process-wide worktree listing shared by periodic Git context refreshes: windows
/// on one repository share one `git worktree list` + per-worktree metadata pass per time-to-live,
/// concurrent requests coalesce, RepoPrompt's own worktree mutations invalidate immediately, and
/// repositories never share entries. The spy counts real enumerations (one per process launch and
/// metadata pass); each test has a control that fails if sharing or invalidation is removed.
final class VCSServiceSharedWorktreeListingTests: XCTestCase {
    private var fixture: ReviewGitRepositoryFixture!
    private var mainRoot: URL!
    private var linkedRoot: URL!

    override func setUpWithError() throws {
        // Resolve /var -> /private/var so paths match `git worktree list` output exactly.
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        fixture = try ReviewGitRepositoryFixture(name: "SharedWorktreeListing", parentDirectory: parent)
        mainRoot = try fixture.makeRepository(named: "repo", files: ["README.md": "main\n"])
        linkedRoot = fixture.sandbox.appendingPathComponent("repo-feature", isDirectory: true)
        try fixture.runGit(["worktree", "add", "-b", "feature", linkedRoot.path], at: mainRoot)
    }

    override func tearDown() {
        fixture?.cleanup()
        fixture = nil
    }

    // MARK: - Two windows share one enumeration

    func testTwoWindowRefreshesOfOneRepositoryShareOneEnumerationWithinTimeToLive() async {
        let clock = ManualClock()
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let mainWindow = GitStatusActor(vcsService: service)
        let linkedWindow = GitStatusActor(vcsService: service)

        let mainDetections = await mainWindow.updateRoots([mainRoot.path])
        clock.advance(by: 1.0)
        let linkedDetections = await linkedWindow.updateRoots([linkedRoot.path])

        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 1, "Two windows on one repository within the TTL must share one enumeration")
        XCTAssertEqual(mainDetections.first?.gitWorktreeContext?.worktreePath, mainRoot.path)
        XCTAssertEqual(linkedDetections.first?.gitWorktreeContext?.worktreePath, linkedRoot.path)

        // Control: with sharing disabled (TTL 0), the same two refreshes enumerate twice.
        let controlSpy = ListingSpy()
        let control = makeService(spy: controlSpy, clock: ManualClock(), timeToLive: 0)
        _ = await GitStatusActor(vcsService: control).updateRoots([mainRoot.path])
        _ = await GitStatusActor(vcsService: control).updateRoots([linkedRoot.path])
        let controlEnumerations = await controlSpy.callCount
        XCTAssertEqual(controlEnumerations, 2)
    }

    func testSharedEntryReprojectsIsCurrentForEachCaller() async throws {
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 60)

        let fromMain = try await service.sharedGitWorktreeListing(for: resolvedGit(mainRoot))
        let fromLinked = try await service.sharedGitWorktreeListing(for: resolvedGit(linkedRoot))

        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 1)
        XCTAssertEqual(currentPaths(fromMain), [mainRoot.path])
        XCTAssertEqual(currentPaths(fromLinked), [linkedRoot.path])
        XCTAssertEqual(Set(fromMain.map(\.path)), Set(fromLinked.map(\.path)))
    }

    // MARK: - Time-to-live

    func testRefreshAfterTimeToLiveReenumerates() async throws {
        let clock = ManualClock()
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let resolved = resolvedGit(mainRoot)

        _ = try await service.sharedGitWorktreeListing(for: resolved)
        clock.advance(by: 2.4)
        _ = try await service.sharedGitWorktreeListing(for: resolved)
        let withinTimeToLive = await spy.callCount
        XCTAssertEqual(withinTimeToLive, 1)

        clock.advance(by: 0.1)
        _ = try await service.sharedGitWorktreeListing(for: resolved)
        let afterTimeToLive = await spy.callCount
        XCTAssertEqual(afterTimeToLive, 2, "An entry must not be served once the TTL has elapsed")
    }

    // MARK: - Single flight

    func testConcurrentRequestsJoinOneInFlightEnumeration() async throws {
        let gate = Gate()
        let spy = ListingSpy(gate: gate)
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 60)
        let main = resolvedGit(mainRoot)
        let linked = resolvedGit(linkedRoot)

        let first = Task { try await service.sharedGitWorktreeListing(for: main) }
        await waitUntil { await spy.callCount >= 1 }
        let joiners = [main, linked, main].map { resolved in
            Task { try await service.sharedGitWorktreeListing(for: resolved) }
        }
        // No entry exists while the flight is blocked, so all three must join it (not hit a cache).
        await waitUntil { await service.sharedWorktreeListing.joinedFlightCount >= 3 }
        await gate.open()

        let firstResult = try await first.value
        var joinerResults: [[GitWorktreeDescriptor]] = []
        for joiner in joiners {
            try await joinerResults.append(joiner.value)
        }
        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 1, "Concurrent requests for one repository must share one enumeration")
        XCTAssertEqual(firstResult.count, 2)
        XCTAssertEqual(currentPaths(joinerResults[1]), [linkedRoot.path])
    }

    func testInvalidationDuringInFlightEnumerationIsNotStored() async throws {
        let gate = Gate()
        let spy = ListingSpy(gate: gate)
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 60)
        let resolved = resolvedGit(mainRoot)

        let inFlight = Task { try await service.sharedGitWorktreeListing(for: resolved) }
        await waitUntil { await spy.callCount >= 1 }
        await service.invalidateSharedWorktreeListings()
        await gate.open()
        _ = try await inFlight.value

        _ = try await service.sharedGitWorktreeListing(for: resolved)
        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 2, "An enumeration that started before invalidation must not be cached")
    }

    // MARK: - RepoPrompt's own mutations are visible immediately

    func testRepoPromptWorktreeCreateAndRemoveAreVisibleBeforeTimeToLive() async throws {
        let spy = ListingSpy()
        // A long TTL proves visibility comes from invalidation, not expiry.
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 3600)
        let resolved = resolvedGit(mainRoot)
        let initial = try await service.sharedGitWorktreeListing(for: resolved)
        XCTAssertEqual(initial.count, 2)

        // Control: a worktree added outside RepoPrompt stays hidden until the TTL expires.
        let external = fixture.sandbox.appendingPathComponent("repo-external", isDirectory: true)
        try fixture.runGit(["worktree", "add", "-b", "external", external.path], at: mainRoot)
        let beforeInvalidation = try await service.sharedGitWorktreeListing(for: resolved)
        XCTAssertFalse(beforeInvalidation.contains { $0.path == external.path })

        // RepoPrompt creation (VCSService.createGitWorktree) invalidates immediately.
        let created = fixture.sandbox.appendingPathComponent("repo-created", isDirectory: true)
        _ = try await service.createGitWorktree(
            request: GitWorktreeCreateRequest(
                path: created,
                branch: "created",
                allowExternalPath: true,
                mainWorktreeRoot: mainRoot,
                knownWorktreeRoots: [mainRoot, linkedRoot, external]
            ),
            at: mainRoot
        )
        let afterCreate = try await service.sharedGitWorktreeListing(for: resolved)
        XCTAssertTrue(afterCreate.contains { $0.path == created.path })
        XCTAssertTrue(afterCreate.contains { $0.path == external.path })

        // RepoPrompt removal (the start coordinator's `git worktree remove`) invalidates the removed path.
        try fixture.runGit(["worktree", "remove", "--force", created.path], at: mainRoot)
        await service.invalidateCache(for: created)
        let afterRemove = try await service.sharedGitWorktreeListing(for: resolved)
        XCTAssertFalse(afterRemove.contains { $0.path == created.path })

        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 3)
    }

    func testInvalidateCacheForMutatedPathDropsSharedListings() async throws {
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 3600)
        let resolved = resolvedGit(mainRoot)

        _ = try await service.sharedGitWorktreeListing(for: resolved)
        // Branch switch and worktree merge call `invalidateCache(for:)` after mutating.
        await service.invalidateCache(for: linkedRoot)
        _ = try await service.sharedGitWorktreeListing(for: resolved)

        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 2)
    }

    // MARK: - Repository isolation

    func testDifferentRepositoriesDoNotShareEntries() async throws {
        let otherRoot = try fixture.makeRepository(named: "other", files: ["README.md": "other\n"])
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 3600)

        let first = try await service.sharedGitWorktreeListing(for: resolvedGit(mainRoot))
        let other = try await service.sharedGitWorktreeListing(for: resolvedGit(otherRoot))
        let firstAgain = try await service.sharedGitWorktreeListing(for: resolvedGit(mainRoot))

        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 2)
        XCTAssertEqual(other.map(\.path), [otherRoot.path])
        XCTAssertEqual(Set(first.map(\.path)), [mainRoot.path, linkedRoot.path])
        XCTAssertEqual(firstAgain.map(\.path), first.map(\.path))
    }

    // MARK: - Review hardening

    func testEnumerationRunsFromMainRootSoARemovedCallerRootCannotFailIt() async throws {
        let clock = ManualClock()
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let linked = resolvedGit(linkedRoot)

        // The linked window learns its key while its checkout exists.
        _ = try await service.sharedGitWorktreeListing(for: linked)
        // The checkout is then deleted outside RepoPrompt; the window keeps refreshing that root.
        try FileManager.default.removeItem(at: linkedRoot)
        clock.advance(by: 3.0)

        // The removed root starts the shared enumeration, which runs from the main root and succeeds.
        // The removed root itself is no longer listed, so only its own call falls back to its dead
        // directory and fails, exactly as before sharing.
        do {
            _ = try await service.sharedGitWorktreeListing(for: linked)
            XCTFail("The removed root's own fallback enumeration should fail as before sharing")
        } catch {}
        // A healthy window on the same repository receives the shared, successful listing.
        let fromMain = try await service.sharedGitWorktreeListing(for: resolvedGit(mainRoot))

        let calls = await spy.calledURLs
        XCTAssertEqual(calls.map(\.path), [mainRoot.path, mainRoot.path, linkedRoot.path])
        XCTAssertEqual(currentPaths(fromMain), [mainRoot.path])
    }

    func testWaiterOfInvalidatedEnumerationRetriesInsteadOfReturningPreMutationListing() async throws {
        let gate = Gate()
        let spy = ListingSpy(gate: gate)
        let service = makeService(spy: spy, clock: ManualClock(), timeToLive: 3600)
        let resolved = resolvedGit(mainRoot)

        // The first enumeration snapshots the worktree list, then blocks.
        let initiator = Task { try await service.sharedGitWorktreeListing(for: resolved) }
        await waitUntil { await spy.callCount >= 1 }
        let joiner = Task { try await service.sharedGitWorktreeListing(for: resolvedGit(linkedRoot)) }
        // Rendezvous: the joiner must be attached to the pre-mutation flight before the mutation.
        await waitUntil { await service.sharedWorktreeListing.joinedFlightCount >= 1 }

        // A RepoPrompt mutation lands while both requests wait on the pre-mutation snapshot.
        let created = fixture.sandbox.appendingPathComponent("repo-created", isDirectory: true)
        _ = try await service.createGitWorktree(
            request: GitWorktreeCreateRequest(
                path: created,
                branch: "created",
                allowExternalPath: true,
                mainWorktreeRoot: mainRoot,
                knownWorktreeRoots: [mainRoot, linkedRoot]
            ),
            at: mainRoot
        )
        await gate.open()

        let initiatorResult = try await initiator.value
        let joinerResult = try await joiner.value
        XCTAssertTrue(initiatorResult.contains { $0.path == created.path })
        XCTAssertTrue(joinerResult.contains { $0.path == created.path })
        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 2, "Invalidated waiters retry once on a fresh enumeration")
    }

    func testRequestAfterTimeToLiveDoesNotJoinAStaleInFlightEnumeration() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let spy = ListingSpy(gate: gate)
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let resolved = resolvedGit(mainRoot)

        let slow = Task { try await service.sharedGitWorktreeListing(for: resolved) }
        await waitUntil { await spy.callCount >= 1 }
        clock.advance(by: 3.0)
        let late = Task { try await service.sharedGitWorktreeListing(for: resolved) }
        await waitUntil { await spy.callCount >= 2 }
        await gate.open()
        _ = try await slow.value
        _ = try await late.value

        let joined = await service.sharedWorktreeListing.joinedFlightCount
        XCTAssertEqual(joined, 0, "A flight older than the TTL must not be joined")
        let enumerations = await spy.callCount
        XCTAssertEqual(enumerations, 2)
    }

    func testListingWithoutTheKeysMainRootIsNotCachedAndFallsBackToCallerRoot() async throws {
        // Simulates an inherited GIT_DIR: enumerating from the main root reports another repository.
        let otherRoot = try fixture.makeRepository(named: "other", files: ["README.md": "other\n"])
        let spy = ListingSpy()
        let backend = GitBackend()
        let mainRootPath = mainRoot.path
        let service = VCSService(
            jjRunner: JJCommandRunner(),
            sharedWorktreeListingConfiguration: SharedWorktreeListingConfiguration(
                timeToLive: 3600,
                now: { 1000 },
                lister: { url in
                    await spy.recordCall(url)
                    let target = url.path == mainRootPath ? otherRoot : url
                    return try await backend.listWorktrees(at: target)
                },
                gitProcessEnvironment: { [:] }
            )
        )
        let linked = resolvedGit(linkedRoot)

        let first = try await service.sharedGitWorktreeListing(for: linked)
        let second = try await service.sharedGitWorktreeListing(for: linked)

        XCTAssertTrue(first.contains { $0.path == linkedRoot.path })
        XCTAssertFalse(first.contains { $0.path == otherRoot.path })
        XCTAssertEqual(first.map(\.path), second.map(\.path))
        let calls = await spy.calledURLs
        XCTAssertEqual(
            calls.map(\.path),
            [mainRoot.path, linkedRoot.path, linkedRoot.path],
            "A foreign listing must not be cached; the root then bypasses sharing"
        )
    }

    func testInheritedGitLocationEnvironmentDisablesSharing() async throws {
        let spy = ListingSpy()
        let backend = GitBackend()
        let service = VCSService(
            jjRunner: JJCommandRunner(),
            sharedWorktreeListingConfiguration: SharedWorktreeListingConfiguration(
                timeToLive: 3600,
                now: { 1000 },
                lister: { url in
                    await spy.recordCall(url)
                    return try await backend.listWorktrees(at: url)
                },
                gitProcessEnvironment: { ["GIT_DIR": "/elsewhere/.git"] }
            )
        )
        let linked = resolvedGit(linkedRoot)

        _ = try await service.sharedGitWorktreeListing(for: linked)
        _ = try await service.sharedGitWorktreeListing(for: linked)

        let calls = await spy.calledURLs
        XCTAssertEqual(calls.map(\.path), [linkedRoot.path, linkedRoot.path], "No sharing, no main-root enumeration")
    }

    func testSharingDecisionReadsTheBackendsPreparedGitEnvironment() async {
        let backend = GitBackend(gitService: GitService(inheritedProcessEnvironment: ["GIT_DIR": "/elsewhere/.git"]))
        let environment = await backend.gitProcessEnvironment()
        XCTAssertEqual(environment["GIT_DIR"], "/elsewhere/.git")
    }

    func testCallerRootMissingFromItsRepositoryListingFallsBackToCallerRoot() async throws {
        let spy = ListingSpy()
        let backend = GitBackend()
        let mainRootPath = mainRoot.path
        let linkedRootPath = linkedRoot.path
        let service = VCSService(
            jjRunner: JJCommandRunner(),
            sharedWorktreeListingConfiguration: SharedWorktreeListingConfiguration(
                timeToLive: 3600,
                now: { 1000 },
                lister: { url in
                    await spy.recordCall(url)
                    let descriptors = try await backend.listWorktrees(at: url)
                    // The repository's listing no longer names the linked root (e.g. it was reused).
                    return url.path == mainRootPath ? descriptors.filter { $0.path != linkedRootPath } : descriptors
                },
                gitProcessEnvironment: { [:] }
            )
        )

        let result = try await service.sharedGitWorktreeListing(for: resolvedGit(linkedRoot))

        let calls = await spy.calledURLs
        XCTAssertEqual(calls.map(\.path), [mainRoot.path, linkedRoot.path])
        XCTAssertTrue(result.contains { $0.path == linkedRoot.path })
    }

    func testReusedWorktreePathReResolvesInsteadOfServingTheOldRepository() async throws {
        let clock = ManualClock()
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let linked = resolvedGit(linkedRoot)

        // The window learns the linked root's repository.
        _ = try await service.sharedGitWorktreeListing(for: linked)
        // The checkout is deleted and a different repository is cloned at the same path, without
        // `git worktree remove`; the old repository keeps listing the (non-prunable) record.
        try FileManager.default.removeItem(at: linkedRoot)
        let reusedRoot = try fixture.makeRepository(named: "repo-feature", files: ["README.md": "other\n"])
        XCTAssertEqual(reusedRoot.path, linkedRoot.path)
        clock.advance(by: 3.0)

        let listing = try await service.sharedGitWorktreeListing(for: linked)
        let root = try XCTUnwrap(listing.first { $0.path == linkedRoot.path })
        XCTAssertTrue(root.isMain)
        XCTAssertEqual(
            StandardizedPath.absolute(root.repository.commonGitDir),
            StandardizedPath.absolute(linkedRoot.appendingPathComponent(".git").path),
            "The reused path must be reported as its new repository, not the old one"
        )
        XCTAssertFalse(listing.contains { $0.path == mainRoot.path })
    }

    func testReplacedNestedCheckoutIsNotMaskedByItsAncestorWorktree() async throws {
        let clock = ManualClock()
        let spy = ListingSpy()
        let service = makeService(spy: spy, clock: clock, timeToLive: 2.5)
        let nestedRoot = mainRoot.appendingPathComponent("nested", isDirectory: true)
        try fixture.runGit(["worktree", "add", "-b", "nested", nestedRoot.path], at: mainRoot)
        let nested = resolvedGit(nestedRoot)

        // The window learns the nested linked root's repository.
        _ = try await service.sharedGitWorktreeListing(for: nested)
        // The nested checkout is removed and pruned, and a different repository is created there.
        try fixture.runGit(["worktree", "remove", "--force", nestedRoot.path], at: mainRoot)
        try fixture.initializeRepository(at: nestedRoot)
        try fixture.write("other\n", to: "README.md", at: nestedRoot)
        try fixture.stage("README.md", at: nestedRoot)
        try fixture.commit("Other", at: nestedRoot)
        clock.advance(by: 3.0)

        let listing = try await service.sharedGitWorktreeListing(for: nested)
        let root = try XCTUnwrap(listing.first { $0.path == nestedRoot.path })
        XCTAssertTrue(root.isMain)
        XCTAssertEqual(
            StandardizedPath.absolute(root.repository.commonGitDir),
            StandardizedPath.absolute(nestedRoot.appendingPathComponent(".git").path),
            "The ancestor main worktree must not stand in for the replaced nested checkout"
        )
    }

    func testFailedSharedEnumerationFallsBackToTheCallersOwnRoot() async throws {
        let spy = ListingSpy()
        let backend = GitBackend()
        let mainRootPath = mainRoot.path
        let service = VCSService(
            jjRunner: JJCommandRunner(),
            sharedWorktreeListingConfiguration: SharedWorktreeListingConfiguration(
                timeToLive: 3600,
                now: { 1000 },
                lister: { url in
                    await spy.recordCall(url)
                    // The main checkout moved away: enumerating from its old root fails.
                    if url.path == mainRootPath { throw VCSError.notARepository(path: url.path) }
                    return try await backend.listWorktrees(at: url)
                },
                gitProcessEnvironment: { [:] }
            )
        )

        let result = try await service.sharedGitWorktreeListing(for: resolvedGit(linkedRoot))

        let calls = await spy.calledURLs
        XCTAssertEqual(calls.map(\.path), [mainRoot.path, linkedRoot.path])
        XCTAssertTrue(result.contains { $0.path == linkedRoot.path })
    }

    func testProjectionChangesOnlyIsCurrent() {
        let original = GitWorktreeDescriptor(
            worktreeID: "wt",
            repository: GitWorktreeIdentity.repositoryIdentity(
                commonGitDir: mainRoot.appendingPathComponent(".git"),
                mainWorktreeRoot: mainRoot
            ),
            path: linkedRoot.path,
            gitDir: "/git/worktrees/feature",
            name: "repo-feature",
            branch: "feature",
            head: "abc123",
            isMain: false,
            isCurrent: false,
            isDetached: false,
            isLocked: true,
            lockReason: "reason",
            isPrunable: true,
            prunableReason: "gone"
        )
        let projected = VCSService.projectingCurrentWorktree([original], currentRepoURL: linkedRoot)
        let expected = GitWorktreeDescriptor(
            worktreeID: original.worktreeID,
            repository: original.repository,
            path: original.path,
            gitDir: original.gitDir,
            name: original.name,
            branch: original.branch,
            head: original.head,
            isMain: original.isMain,
            isCurrent: true,
            isDetached: original.isDetached,
            isLocked: original.isLocked,
            lockReason: original.lockReason,
            isPrunable: original.isPrunable,
            prunableReason: original.prunableReason
        )
        XCTAssertEqual(projected, [expected])
        XCTAssertEqual(VCSService.projectingCurrentWorktree(projected, currentRepoURL: mainRoot), [original])
    }

    // MARK: - Helpers

    private func makeService(spy: ListingSpy, clock: ManualClock, timeToLive: TimeInterval) -> VCSService {
        let backend = GitBackend()
        return VCSService(
            jjRunner: JJCommandRunner(),
            sharedWorktreeListingConfiguration: SharedWorktreeListingConfiguration(
                timeToLive: timeToLive,
                now: { clock.now },
                lister: { url in
                    await spy.recordCall(url)
                    let descriptors = try await backend.listWorktrees(at: url)
                    await spy.waitAtGate()
                    return descriptors
                },
                gitProcessEnvironment: { [:] }
            )
        )
    }

    /// Bounded rendezvous: fails (instead of hanging) if the condition never holds.
    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func resolvedGit(_ root: URL) -> VCSResolvedRepo {
        VCSResolvedRepo(rootURL: root, backendKind: .git)
    }

    private func currentPaths(_ descriptors: [GitWorktreeDescriptor]) -> [String] {
        descriptors.filter(\.isCurrent).map(\.path)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000

    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ListingSpy {
    private let gate: Gate?
    private(set) var calledURLs: [URL] = []

    var callCount: Int {
        calledURLs.count
    }

    init(gate: Gate? = nil) {
        self.gate = gate
    }

    func recordCall(_ url: URL) {
        calledURLs.append(url)
    }

    func waitAtGate() async {
        await gate?.wait()
    }
}

final class VCSReadRootAuthorizationTests: XCTestCase {
    func testNormalCheckoutReadDoesNotFollowConfiguredExternalWorktree() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-read-binding-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let external = base.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside-only.txt"))
        try Data("outside".utf8).write(to: external.appendingPathComponent("outside-only.txt"))
        for args in [["init", "--quiet"], ["config", "core.worktree", external.path]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let status = try await GitService().getStatusPorcelainZ(at: root)
        let text = String(decoding: status, as: UTF8.self)
        XCTAssertTrue(text.contains("inside-only.txt"), text)
        XCTAssertFalse(text.contains("outside-only.txt"), text)
    }

    func testJujutsuMetadataDoesNotExpandReadRoots() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jj-read-root-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let external = base.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = VCSService(jjRunner: JJCommandRunner { _, _, _ in ("", "", 0) })
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let initial = await service.resolveRepo(from: root)
        XCTAssertEqual(initial?.backendKind, .git)
        let jjDirectory = root.appendingPathComponent(".jj")
        try FileManager.default.createSymbolicLink(at: jjDirectory, withDestinationURL: external)
        let symlinkResult = await service.resolveRepoForRead(at: root, authorizedRoots: [root])
        XCTAssertNil(symlinkResult)
        try FileManager.default.removeItem(at: jjDirectory)
        try FileManager.default.createDirectory(at: jjDirectory, withIntermediateDirectories: true)
        try Data((external.path + "\n").utf8).write(to: jjDirectory.appendingPathComponent("repo"))
        let pointerResult = await service.resolveRepoForRead(at: root, authorizedRoots: [root])
        XCTAssertNil(pointerResult)
        let approvedResult = await service.resolveRepoForRead(at: root, authorizedRoots: [root, external])
        XCTAssertEqual(approvedResult?.backendKind, .jujutsu)
        let backend = await service.backend(forRepoRoot: root)
        XCTAssertEqual(backend.kind, .jujutsu)
    }

    func testScopedDiscoveryDoesNotReuseParentRepositoryCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-read-root-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = VCSService()
        let unrestricted = await service.resolveRepo(from: nested)
        XCTAssertEqual(unrestricted?.rootURL.standardizedFileURL.path, root.standardizedFileURL.path)
        let scoped = await service.resolveRepoForRead(at: nested, authorizedRoots: [nested])
        XCTAssertNil(scoped)
        let unauthorizedParent = await service.resolveRepoForRead(at: root, authorizedRoots: [nested])
        XCTAssertNil(unauthorizedParent)
        let authorizedParent = await service.resolveRepoForRead(at: root, authorizedRoots: [root])
        XCTAssertNotNil(authorizedParent)
    }
}
