@testable import RepoPromptApp
import XCTest

final class GitWorktreeDefaultPathPlannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeDefaultPathPlannerTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testStandaloneCreateDefaultsToSiblingManagedContainerAndBranch() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 1,
            day: 22
        )))

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            purpose: .standaloneCreate(now: now)
        ))

        let expectedContainer = tempRoot
            .appendingPathComponent(".repoprompt-worktrees", isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
            .standardizedFileURL
        XCTAssertEqual(plan.appManagedContainer, expectedContainer)
        XCTAssertTrue(plan.path.path.hasPrefix(expectedContainer.path + "/"))
        XCTAssertTrue(plan.path.lastPathComponent.hasPrefix("rp-worktree-worktree-"))
        XCTAssertEqual(plan.branch, "rp/worktree/20260122-worktree")
        XCTAssertEqual(plan.createRequest.mainWorktreeRoot, mainRoot.standardizedFileURL)
        XCTAssertEqual(plan.createRequest.appManagedContainer, expectedContainer)
        XCTAssertFalse(plan.createRequest.allowExternalPath)
        XCTAssertTrue(plan.createRequest.copyWorktreeIncludeFiles)
    }

    func testAgentStartDefaultsToAgentBranchAndReadablePathPrefix() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            baseRef: "feature/Long Branch Name",
            purpose: .agentStart(sessionID: "ABCDEF1234567890")
        ))

        XCTAssertEqual(plan.branch, "rp/agent/abcdef12-feature-long-branch-name")
        XCTAssertTrue(plan.path.lastPathComponent.hasPrefix("rp-agent-abcdef12-feature-long-branch-name"))
    }

    func testSuppliedBranchIsPreservedAndIncludedInDefaultLeaf() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            branch: "feature/new UI",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))

        XCTAssertEqual(plan.branch, "feature/new UI")
        XCTAssertTrue(plan.path.lastPathComponent.contains("feature-new-ui"))
    }

    func testExplicitExternalPathRequiresAllowExternalPath() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let externalPath = tempRoot.appendingPathComponent("external-worktree", isDirectory: true)

        XCTAssertThrowsError(try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: externalPath,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))) { error in
            XCTAssertTrue(String(describing: error).contains("allow_external_path=true"))
        }

        let allowed = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: externalPath,
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        XCTAssertEqual(allowed.path, externalPath.standardizedFileURL)
        XCTAssertFalse(allowed.createRequest.copyWorktreeIncludeFiles)
    }

    func testRejectsRelativeExplicitPathAndExpandsHomePath() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)

        XCTAssertThrowsError(try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: XCTUnwrap(URL(string: "relative-worktree")),
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))) { error in
            XCTAssertTrue(String(describing: error).contains("must be absolute"))
        }

        let homeRelativePath = try XCTUnwrap(URL(string: "~/rp-worktree-test"))
        let expanded = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: homeRelativePath,
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        XCTAssertEqual(
            expanded.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("rp-worktree-test")
                .standardizedFileURL
        )
    }

    func testExplicitPathInsideManagedContainerDoesNotRequireExternalFlag() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let managedPath = GitWorktreeDefaultPathPlanner
            .defaultContainer(forMainWorktreeRoot: mainRoot)
            .appendingPathComponent("custom", isDirectory: true)

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: managedPath,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))

        XCTAssertEqual(plan.path, managedPath.standardizedFileURL)
        XCTAssertTrue(plan.createRequest.copyWorktreeIncludeFiles)
    }

    func testRejectsExplicitPathInsideRepoOrGitDirectory() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let insideRepo = mainRoot.appendingPathComponent("worktree", isDirectory: true)
        let insideGit = mainRoot.appendingPathComponent(".git/objects/worktree", isDirectory: true)

        XCTAssertThrowsError(try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: insideRepo,
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))) { error in
            XCTAssertTrue(String(describing: error).contains("existing worktree"))
        }

        XCTAssertThrowsError(try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            explicitPath: insideGit,
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))) { error in
            XCTAssertTrue(String(describing: error).contains(".git directory"))
        }
    }

    func testDefaultPathCollisionUsesDeterministicNumericSuffix() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let request = GitWorktreeDefaultPathPlanner.Request(
            mainWorktreeRoot: mainRoot,
            branch: "feature/collision",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        )
        let first = try GitWorktreeDefaultPathPlanner.plan(request)
        try FileManager.default.createDirectory(at: first.path, withIntermediateDirectories: true)

        let second = try GitWorktreeDefaultPathPlanner.plan(request)

        XCTAssertEqual(second.path.deletingLastPathComponent(), first.path.deletingLastPathComponent())
        XCTAssertEqual(second.path.lastPathComponent, first.path.lastPathComponent + "-2")
    }

    func testDefaultPathCollisionUsesOccupiedRootsEvenWhenPathsDoNotExist() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let request = GitWorktreeDefaultPathPlanner.Request(
            mainWorktreeRoot: mainRoot,
            branch: "feature/occupied-root",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        )
        let baseline = try GitWorktreeDefaultPathPlanner.plan(request)
        let occupiedRoots = (1 ... 128).map { suffix in
            let leaf = suffix == 1
                ? baseline.path.lastPathComponent
                : "\(baseline.path.lastPathComponent)-\(suffix)"
            return baseline.path.deletingLastPathComponent()
                .appendingPathComponent(leaf, isDirectory: true)
        }

        XCTAssertTrue(occupiedRoots.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            existingWorktreeRoots: occupiedRoots,
            branch: "feature/occupied-root",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        let expected = baseline.path.deletingLastPathComponent()
            .appendingPathComponent("\(baseline.path.lastPathComponent)-129", isDirectory: true)
            .standardizedFileURL

        XCTAssertEqual(plan.path, expected)
    }

    func testDefaultPathNormalizesDuplicateDotAndTildeRootsWithDeterministicSuffix() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mainRoot = home.appendingPathComponent(
            "GitWorktreeDefaultPathPlanner-\(UUID().uuidString)",
            isDirectory: true
        )
        let request = GitWorktreeDefaultPathPlanner.Request(
            mainWorktreeRoot: mainRoot,
            branch: "feature/normalization",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        )
        let baseline = try GitWorktreeDefaultPathPlanner.plan(request)
        let secondOccupied = baseline.path.deletingLastPathComponent()
            .appendingPathComponent("\(baseline.path.lastPathComponent)-2", isDirectory: true)
        let dotAlias = URL(
            fileURLWithPath: baseline.path.deletingLastPathComponent().path
                + "/./"
                + baseline.path.lastPathComponent
        )
        let tildeSuffix = String(secondOccupied.path.dropFirst(home.path.count))
        let tildeAlias = URL(fileURLWithPath: "~\(tildeSuffix)")

        XCTAssertTrue([
            baseline.path,
            secondOccupied
        ].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let normalized = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            existingWorktreeRoots: [dotAlias, tildeAlias, baseline.path, secondOccupied],
            branch: "feature/normalization",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        let expected = baseline.path.deletingLastPathComponent()
            .appendingPathComponent("\(baseline.path.lastPathComponent)-3", isDirectory: true)
            .standardizedFileURL

        XCTAssertEqual(normalized.path, expected)
        XCTAssertEqual(normalized.createRequest.knownWorktreeRoots.map(\.path), [
            mainRoot.standardizedFileURL.path,
            baseline.path.standardizedFileURL.path,
            secondOccupied.standardizedFileURL.path
        ])
    }

    func testSymlinkedMainRootPreservesStandardizedPathAuthority() throws {
        let physicalRoot = tempRoot.appendingPathComponent("physical-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        let symlinkRoot = tempRoot.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: physicalRoot)

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: symlinkRoot,
            existingWorktreeRoots: [physicalRoot],
            branch: "feature/symlink",
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        // Preserve the planner's existing lexical identity: standardized paths
        // keep this symlink alias distinct from its physical target.
        let lexicalSymlinkPath = symlinkRoot.standardizedFileURL.path
        let physicalPath = physicalRoot.standardizedFileURL.path

        XCTAssertNotEqual(lexicalSymlinkPath, physicalPath)
        XCTAssertEqual(symlinkRoot.resolvingSymlinksInPath().standardizedFileURL.path, physicalPath)
        XCTAssertEqual(try XCTUnwrap(plan.createRequest.mainWorktreeRoot).path, lexicalSymlinkPath)
        XCTAssertEqual(
            plan.appManagedContainer.path,
            GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: symlinkRoot).path
        )
        XCTAssertEqual(plan.createRequest.knownWorktreeRoots.map(\.path), [lexicalSymlinkPath, physicalPath])
    }

    func testDetachSuppressesDefaultBranch() throws {
        let mainRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)

        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: mainRoot,
            detach: true,
            purpose: .agentStart(sessionID: "session")
        ))

        XCTAssertNil(plan.branch)
        XCTAssertNil(plan.createRequest.branch)
    }
}
