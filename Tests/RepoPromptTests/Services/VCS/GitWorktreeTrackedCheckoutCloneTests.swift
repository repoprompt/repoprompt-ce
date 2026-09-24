import Darwin
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

final class GitWorktreeTrackedCheckoutCloneTests: XCTestCase {
    private var fixture: ReviewGitRepositoryFixture!

    override func setUpWithError() throws {
        fixture = try ReviewGitRepositoryFixture(name: "GitWorktreeTrackedCheckoutClone")
    }

    override func tearDownWithError() throws {
        fixture?.cleanup()
        fixture = nil
    }

    // MARK: - Parsers

    func testConfigAssessmentRejectsCheckoutAlteringSettingsAndHonorsLastValue() {
        typealias Clone = GitWorktreeTrackedCheckoutClone
        XCTAssertNil(Clone.assessConfig("core.bare\nfalse\0core.symlinks\ntrue\0").ineligibility)
        XCTAssertEqual(Clone.assessConfig("core.sparsecheckout\ntrue\0").ineligibility, .sparseCheckout)
        XCTAssertEqual(Clone.assessConfig("core.sparsecheckout\0").ineligibility, .sparseCheckout)
        XCTAssertNil(Clone.assessConfig("core.sparsecheckout\ntrue\0core.sparsecheckout\nfalse\0").ineligibility)
        XCTAssertEqual(Clone.assessConfig("core.symlinks\nfalse\0").ineligibility, .symlinksDisabled)
        XCTAssertEqual(Clone.assessConfig("core.autocrlf\ninput\0").ineligibility, .lineEndingConversion)
        XCTAssertEqual(Clone.assessConfig("core.autocrlf\ntrue\0").ineligibility, .lineEndingConversion)
        XCTAssertNil(Clone.assessConfig("core.autocrlf\nfalse\0").ineligibility)
        XCTAssertEqual(Clone.assessConfig("core.eol\ncrlf\0").ineligibility, .lineEndingConversion)
        XCTAssertTrue(Clone.assessConfig("core.attributesfile\n/tmp/attrs\0").attributesFileConfigured)
        XCTAssertFalse(Clone.assessConfig("core.bare\nfalse\0").attributesFileConfigured)
    }

    func testHiddenIndexStateRequiresEveryEntryToBePlainlyCached() {
        XCTAssertFalse(GitWorktreeTrackedCheckoutClone.hasHiddenIndexState("H README.md\0H src/a.txt\0"))
        XCTAssertTrue(GitWorktreeTrackedCheckoutClone.hasHiddenIndexState("H README.md\0h src/a.txt\0"))
        XCTAssertTrue(GitWorktreeTrackedCheckoutClone.hasHiddenIndexState("S README.md\0"))
        XCTAssertTrue(GitWorktreeTrackedCheckoutClone.hasHiddenIndexState("M conflicted.txt\0"))
    }

    func testCheckoutAttributesBlockConversionsAndRequestRawBytesForNormalizedText() {
        typealias Clone = GitWorktreeTrackedCheckoutClone
        let plain = Clone.assessCheckoutAttributes(
            "a.txt\0filter\0unspecified\0a.txt\0ident\0unset\0a.txt\0text\0unset\0"
        )
        XCTAssertEqual(plain, .init(blocksClone: false, rawByteVerificationPaths: []))
        let normalized = Clone.assessCheckoutAttributes(
            "a.txt\0eol\0lf\0a.txt\0text\0set\0b.md\0text\0auto\0"
        )
        XCTAssertEqual(normalized, .init(blocksClone: false, rawByteVerificationPaths: ["a.txt", "b.md"]))
        XCTAssertTrue(Clone.assessCheckoutAttributes("a.bin\0filter\0lfs\0").blocksClone)
        XCTAssertTrue(Clone.assessCheckoutAttributes("a.txt\0eol\0crlf\0").blocksClone)
        XCTAssertTrue(Clone.assessCheckoutAttributes("a.txt\0working-tree-encoding\0UTF-16\0").blocksClone)
        XCTAssertTrue(Clone.assessCheckoutAttributes("a.txt\0ident\0set\0").blocksClone)
    }

    func testTreeParserAcceptsFilesAndLinksAndRejectsUnsafeShapes() throws {
        let oid = String(repeating: "a", count: 40)
        let listing = [
            "100644 blob \(oid)      12\tREADME.md",
            "100755 blob \(oid)       7\tbin/run.sh",
            "120000 blob \(oid)       9\tlink"
        ].joined(separator: "\0") + "\0"
        let entries = try GitWorktreeTrackedCheckoutClone.parseTree(listing, caseSensitiveVolume: false).get()
        XCTAssertEqual(entries.map(\.kind), [.regular, .executable, .symbolicLink])
        XCTAssertEqual(entries.map(\.relativePath), ["README.md", "bin/run.sh", "link"])
        XCTAssertEqual(entries.map(\.size), [12, 7, 9])
        XCTAssertEqual(entries.map(\.objectID), [oid, oid, oid])

        func reason(_ listing: String, caseSensitive: Bool = false) -> GitWorktreeTrackedCloneIneligibility? {
            if case let .failure(reason) = GitWorktreeTrackedCheckoutClone.parseTree(
                listing,
                caseSensitiveVolume: caseSensitive
            ) {
                return reason
            }
            return nil
        }
        XCTAssertEqual(reason("160000 commit \(oid)       -\tvendor/sub\0"), .submodule)
        XCTAssertEqual(reason("100644 blob \(oid)       1\t.GIT/config\0"), .unsafeTreePath)
        XCTAssertEqual(reason("100644 blob \(oid)       1\t.g\u{200C}it/config\0"), .unsafeTreePath)
        XCTAssertEqual(reason("100644 blob \(oid)       1\ta/../b\0"), .unsafeTreePath)
        XCTAssertEqual(reason(""), .emptyTree)
        let caseCollision = "100644 blob \(oid)       1\tReadme.md\0100644 blob \(oid)       1\tREADME.md\0"
        XCTAssertEqual(reason(caseCollision), .pathFoldingCollision)
        XCTAssertNil(reason(caseCollision, caseSensitive: true))
        let directoryCollision = "100644 blob \(oid)       1\tDocs/a.txt\0100644 blob \(oid)       1\tdocs/b.txt\0"
        XCTAssertEqual(reason(directoryCollision), .pathFoldingCollision)
        let normalizationCollision = "100644 blob \(oid)       1\tcaf\u{E9}\0100644 blob \(oid)       1\tcafe\u{301}\0"
        XCTAssertEqual(reason(normalizationCollision, caseSensitive: true), .pathFoldingCollision)
    }

    // MARK: - Materializer safety

    func testCopySymbolicLinkAcceptsEmptyTarget() throws {
        let source = fixture.sandbox.appendingPathComponent("empty-link-source", isDirectory: true)
        let destination = fixture.sandbox.appendingPathComponent("empty-link-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertEqual(symlink("", source.appendingPathComponent("link").path), 0)

        let sourceDescriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(sourceDescriptor, 0)
        defer { close(sourceDescriptor) }
        let destinationDescriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(destinationDescriptor, 0)
        defer { close(destinationDescriptor) }

        XCTAssertEqual(
            GitWorktreeFileCloner.copySymbolicLink(
                sourceDirectory: sourceDescriptor,
                name: "link",
                destinationDirectory: destinationDescriptor
            ),
            .symbolicLinkCreated
        )
        var target = [CChar](repeating: 0, count: 1)
        XCTAssertEqual(readlinkat(destinationDescriptor, "link", &target, target.count), 0)
    }

    func testMaterializerRefusesDestinationSymlinkParentWithoutWritingThroughIt() throws {
        let source = fixture.sandbox.appendingPathComponent("materialize-source", isDirectory: true)
        let destination = fixture.sandbox.appendingPathComponent("materialize-destination", isDirectory: true)
        let outside = fixture.sandbox.appendingPathComponent("outside", isDirectory: true)
        try fixture.write("payload\n", to: "src/file.txt", at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("src"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try GitWorktreeTrackedCheckoutClone.materialize(
            entries: [GitWorktreeTrackedTreeEntry(
                kind: .regular,
                pathComponents: ["src", "file.txt"],
                size: 8,
                objectID: "unused"
            )],
            sourceRoot: source.resolvingSymlinksInPath(),
            destinationRoot: destination.resolvingSymlinksInPath(),
            revalidate: {}
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
    }

    func testMaterializerRefusesSourceSymlinkParent() throws {
        let source = fixture.sandbox.appendingPathComponent("materialize-source", isDirectory: true)
        let destination = fixture.sandbox.appendingPathComponent("materialize-destination", isDirectory: true)
        let elsewhere = fixture.sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try fixture.write("secret\n", to: "file.txt", at: elsewhere)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("src"), withDestinationURL: elsewhere)

        XCTAssertThrowsError(try GitWorktreeTrackedCheckoutClone.materialize(
            entries: [GitWorktreeTrackedTreeEntry(
                kind: .regular,
                pathComponents: ["src", "file.txt"],
                size: 7,
                objectID: "unused"
            )],
            sourceRoot: source.resolvingSymlinksInPath(),
            destinationRoot: destination.resolvingSymlinksInPath(),
            revalidate: {}
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/file.txt").path))
    }

    // MARK: - .worktreeinclude copying

    func testIncludeCopierClonesSelectedIgnoredFilesAndKeepsExistingDestinations() throws {
        let (source, destination) = try makeIncludeRoots(include: ".env.local\nconfig/\n!config/skip.json\n")
        try fixture.write("TOKEN=1\n", to: ".env.local", at: source)
        try fixture.write("{}\n", to: "config/app.json", at: source)
        try fixture.write("{}\n", to: "config/skip.json", at: source)
        try fixture.write("new\n", to: "config/existing.json", at: source)
        try fixture.write("keep\n", to: "config/existing.json", at: destination)

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: source,
            to: destination,
            ignoredFilesNULOutput: ".env.local\0config/app.json\0config/skip.json\0config/existing.json\0"
        ))

        XCTAssertEqual(result.copiedRelativePaths, [".env.local", "config/app.json"])
        XCTAssertEqual(result.copiedCount, 2)
        XCTAssertEqual(result.matchedCount, 3)
        XCTAssertEqual(result.clonedCount, try volumeSupportsCloning(source) ? 2 : 0)
        XCTAssertEqual(result.skippedSummaries, ["destination already exists for config/existing.json"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config/existing.json")), "keep\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(".env.local")), "TOKEN=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config/skip.json").path))
    }

    func testIncludeCopierFallsBackToExclusiveCopyWhenCloningIsUnsupported() throws {
        let (source, destination) = try makeIncludeRoots(include: "secrets/\n")
        try fixture.write("key\n", to: "secrets/dev.pem", at: source)
        XCTAssertEqual(chmod(source.appendingPathComponent("secrets/dev.pem").path, 0o600), 0)

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: source,
            to: destination,
            ignoredFilesNULOutput: "secrets/dev.pem\0",
            clone: { _, _, _, _ in ENOTSUP }
        ))

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(result.clonedCount, 0)
        XCTAssertNil(result.warningText)
        let copied = destination.appendingPathComponent("secrets/dev.pem")
        XCTAssertEqual(try String(contentsOf: copied), "key\n")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testIncludeCopierCopiesUntrackedMatchesOnlyWhenListedAndSkipsSymlinks() throws {
        let (source, destination) = try makeIncludeRoots(include: "local/\n")
        try fixture.write("draft\n", to: "local/draft.md", at: source)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("local/link"),
            withDestinationURL: source.appendingPathComponent("local/draft.md")
        )

        let withoutOptIn = try GitWorktreeIncludeCopier.copyIncludedFiles(
            from: source,
            to: destination,
            ignoredFilesNULOutput: ""
        )
        XCTAssertNil(withoutOptIn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("local/draft.md").path))

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: source,
            to: destination,
            ignoredFilesNULOutput: "",
            untrackedFilesNULOutput: "local/draft.md\0local/link\0"
        ))
        XCTAssertEqual(result.copiedRelativePaths, ["local/draft.md"])
        XCTAssertEqual(result.copiedUntrackedCount, 1)
        XCTAssertEqual(result.skippedSummaries, ["source is not a regular file for local/link"])
    }

    func testProtectedIncludeRulesDoNotFollowSourceSymlink() async throws {
        let (source, destination) = try makeIncludeRoots(include: "secret.txt\n")
        let include = source.appendingPathComponent(".worktreeinclude")
        let outsideRules = fixture.sandbox.appendingPathComponent("outside-rules")
        try "secret.txt\n".write(to: outsideRules, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: include)
        try FileManager.default.createSymbolicLink(at: include, withDestinationURL: outsideRules)
        try fixture.write("private\n", to: "secret.txt", at: source)
        try FileManager.default.removeItem(at: destination)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [source.path, destination.path],
            authorizedRoots: [source.path, destination.deletingLastPathComponent().path]
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let physicalGuard = DomainMutationPhysicalCommitGuard(snapshot: snapshot)

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: source,
            to: destination,
            ignoredFilesNULOutput: "secret.txt\0",
            physicalMutationGuard: physicalGuard
        ))
        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertTrue(result.errorSummaries.contains { $0.contains("open-worktreeinclude") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("secret.txt").path))
    }

    // MARK: - GitService integration

    func testCleanSameTreeSourceCreatesVerifiedClonedCheckoutWithoutTouchingSource() async throws {
        let source = try makeSourceRepository(named: "clone-repo")
        // The test's own status may refresh the source index, so snapshot the index after it.
        let sourceStatus = try fixture.runGit(["status", "--porcelain=v2", "--untracked-files=all"], at: source)
        let sourceIndex = try Data(contentsOf: source.appendingPathComponent(".git/index"))

        let result = try await createWorktree(from: source, branch: "rp/test/cloned")

        let report = try XCTUnwrap(result.checkoutReport)
        guard try volumeSupportsCloning(source) else {
            XCTAssertEqual(report.strategy, .ordinary)
            return
        }
        XCTAssertEqual(report.strategy, .cloned, String(describing: report))
        XCTAssertEqual(report.clonedFileCount, 5)
        XCTAssertEqual(report.symbolicLinkCount, 1)
        let worktree = URL(fileURLWithPath: result.descriptor.path)
        try assertCheckout(worktree, matches: source, branch: "rp/test/cloned")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent(".env.local")), "LOCAL=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(result.includeCopyResult?.copiedRelativePaths, [".env.local"])
        XCTAssertEqual(result.includeCopyResult?.clonedCount, 1)

        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".git/index")), sourceIndex)
        XCTAssertEqual(
            try fixture.runGit(["status", "--porcelain=v2", "--untracked-files=all"], at: source),
            sourceStatus
        )
    }

    func testProtectedWorktreeCreationClonesTrackedAndIncludedFiles() async throws {
        let source = try makeSourceRepository(named: "protected-clone-repo")
        guard try volumeSupportsCloning(source) else { throw XCTSkip("Requires an APFS temporary volume.") }
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: source,
            existingWorktreeRoots: [source],
            branch: "rp/test/protected-clone",
            purpose: .standaloneCreate(now: Date())
        ))
        try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [source.path, plan.path.path],
            authorizedRoots: [source.path, plan.appManagedContainer.path]
        )
        let physicalGuard = DomainMutationPhysicalCommitGuard(snapshot: snapshot)
        let controller = DomainMutationCommitController(
            physicalMutationGuard: { physicalGuard },
            willCommit: {}
        )
        let result = try await MCPDomainMutationCommitContext.$controller.withValue(controller) {
            try await GitService().createWorktreeWithResult(request: plan.createRequest, at: source)
        }

        XCTAssertEqual(result.checkoutReport?.strategy, .cloned)
        XCTAssertEqual(result.includeCopyResult?.copiedRelativePaths, [".env.local"])
        XCTAssertEqual(result.includeCopyResult?.clonedCount, 1)
        try assertCheckout(URL(fileURLWithPath: result.descriptor.path), matches: source, branch: "rp/test/protected-clone")
    }

    func testClonedCheckoutMatchesOrdinaryCheckoutBranchUpstreamAndIndex() async throws {
        let source = try makeSourceRepository(named: "parity-repo")
        try fixture.runGit(["branch", "upstreamish"], at: source)
        try fixture.runGit(["config", "branch.autoSetupMerge", "always"], at: source)

        let cloned = try await createWorktree(from: source, branch: "rp/test/clone-parity", baseRef: "upstreamish")
        let ordinary = try await createWorktree(
            from: source,
            branch: "rp/test/ordinary-parity",
            baseRef: "upstreamish",
            cloneTrackedCheckout: false
        )

        XCTAssertEqual(ordinary.checkoutReport?.strategy, .ordinary)
        XCTAssertEqual(ordinary.checkoutReport?.ineligibilityReason, "not-requested")
        if try volumeSupportsCloning(source) {
            XCTAssertEqual(cloned.checkoutReport?.strategy, .cloned)
        }
        let clonedRoot = URL(fileURLWithPath: cloned.descriptor.path)
        let ordinaryRoot = URL(fileURLWithPath: ordinary.descriptor.path)
        try assertCheckout(clonedRoot, matches: source, branch: "rp/test/clone-parity")
        try assertCheckout(ordinaryRoot, matches: source, branch: "rp/test/ordinary-parity")
        XCTAssertEqual(try git(["ls-files", "-s"], at: clonedRoot), try git(["ls-files", "-s"], at: ordinaryRoot))
        XCTAssertEqual(
            try git(["config", "branch.rp/test/clone-parity.merge"], at: source),
            try git(["config", "branch.rp/test/ordinary-parity.merge"], at: source)
        )
        XCTAssertEqual(try git(["config", "branch.rp/test/clone-parity.merge"], at: source), "refs/heads/upstreamish")
    }

    func testDetachedClonedCheckoutKeepsDetachedHead() async throws {
        let source = try makeSourceRepository(named: "detached-repo")
        let result = try await createWorktree(from: source, branch: nil, detach: true)
        let worktree = URL(fileURLWithPath: result.descriptor.path)
        if try volumeSupportsCloning(source) {
            XCTAssertEqual(result.checkoutReport?.strategy, .cloned)
        }
        XCTAssertThrowsError(try fixture.runGit(["symbolic-ref", "-q", "HEAD"], at: worktree))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: worktree), try git(["rev-parse", "HEAD"], at: source))
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], at: worktree), "")
    }

    func testIneligibleSourcesUseOrdinaryCheckout() async throws {
        try await assertOrdinary(.sourceHasTrackedChanges, repository: "dirty") { root in
            try self.fixture.write("changed\n", to: "README.md", at: root)
        }
        try await assertOrdinary(.baseTreeMismatch, repository: "base", baseRef: "other") { root in
            try self.fixture.runGit(["checkout", "-q", "-b", "other"], at: root)
            try self.fixture.write("other\n", to: "other.txt", at: root)
            try self.fixture.runGit(["add", "other.txt"], at: root)
            try self.fixture.commit("other", at: root)
            try self.fixture.runGit(["checkout", "-q", "main"], at: root)
        }
        try await assertOrdinary(.postCheckoutHook, repository: "hook-file") { root in
            try self.fixture.write("#!/bin/sh\nexit 0\n", to: ".git/hooks/post-checkout", at: root)
            XCTAssertEqual(chmod(root.appendingPathComponent(".git/hooks/post-checkout").path, 0o755), 0)
        }
        // Config-defined hooks exist only in Git versions with `git hook list`. GitService's
        // Git binary decides both hook execution and detection, so older Git keeps parity by
        // neither running nor detecting them.
        if try appGitSupportsHookList() {
            try await assertOrdinary(.postCheckoutHook, repository: "hook-config") { root in
                try self.fixture.runGit(["config", "hook.rpce.command", "true"], at: root)
                try self.fixture.runGit(["config", "hook.rpce.event", "post-checkout"], at: root)
            }
        }
        try await assertOrdinary(.postCheckoutHook, repository: "hooks-path") { root in
            try self.fixture.write("#!/bin/sh\nexit 0\n", to: ".githooks/post-checkout", at: root)
            XCTAssertEqual(chmod(root.appendingPathComponent(".githooks/post-checkout").path, 0o755), 0)
            try self.fixture.runGit(["add", ".githooks/post-checkout"], at: root)
            try self.fixture.commit("tracked hooks", at: root)
            try self.fixture.runGit(["config", "core.hooksPath", ".githooks"], at: root)
        }
        // A clean source may hold CRLF bytes that `text eol=lf` normalizes to an LF blob;
        // an ordinary checkout writes LF, so the clone path must not copy the CRLF bytes.
        try await assertOrdinary(.lineEndingConversion, repository: "crlf-normalized") { root in
            try self.fixture.write("*.txt text eol=lf\n", to: ".gitattributes", at: root)
            try self.fixture.runGit(["add", ".gitattributes"], at: root)
            try self.fixture.commit("attributes", at: root)
            try self.fixture.write("value\r\n", to: "src/nested/deep/value.txt", at: root)
            try self.fixture.runGit(["add", "src/nested/deep/value.txt"], at: root)
            XCTAssertEqual(try self.git(["status", "--porcelain", "--untracked-files=no"], at: root), "")
        }
        try await assertOrdinary(.checkoutAttributes, repository: "filter") { root in
            try self.fixture.write("*.md filter=rpcetest\n", to: ".gitattributes", at: root)
            try self.fixture.runGit(["add", ".gitattributes"], at: root)
            try self.fixture.commit("attributes", at: root)
        }
        try await assertOrdinary(.hiddenIndexState, repository: "skip-worktree") { root in
            try self.fixture.runGit(["update-index", "--skip-worktree", "README.md"], at: root)
        }
        try await assertOrdinary(.hiddenIndexState, repository: "assume-unchanged") { root in
            try self.fixture.runGit(["update-index", "--assume-unchanged", "README.md"], at: root)
        }
        try await assertOrdinary(.submodule, repository: "submodule") { root in
            let head = try self.git(["rev-parse", "HEAD"], at: root)
            try self.fixture.runGit(["update-index", "--add", "--cacheinfo", "160000,\(head),vendor/sub"], at: root)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("vendor/sub"),
                withIntermediateDirectories: true
            )
            try self.fixture.commit("gitlink", at: root)
        }
        try await assertOrdinary(.sparseCheckout, repository: "sparse", verifyCleanStatus: false) { root in
            try self.fixture.runGit(["config", "core.sparseCheckout", "true"], at: root)
        }
    }

    func testNormalizedTextAttributesStillCloneWhenRawBytesMatchBlobs() async throws {
        let source = try makeSourceRepository(named: "text-auto-repo")
        try fixture.write("* text=auto\n*.txt text eol=lf\n", to: ".gitattributes", at: source)
        try fixture.runGit(["add", ".gitattributes"], at: source)
        try fixture.commit("attributes", at: source)

        let result = try await createWorktree(from: source, branch: "rp/test/text-auto")

        if try volumeSupportsCloning(source) {
            XCTAssertEqual(result.checkoutReport?.strategy, .cloned, String(describing: result.checkoutReport))
        }
        try assertCheckout(URL(fileURLWithPath: result.descriptor.path), matches: source, branch: "rp/test/text-auto")
    }

    func testExternalDestinationIsNotEligible() async throws {
        let source = try makeSourceRepository(named: "external-repo")
        let external = fixture.sandbox.appendingPathComponent("external-worktree", isDirectory: true)
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: source,
            existingWorktreeRoots: [source],
            explicitPath: external,
            branch: "rp/test/external",
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date())
        ))
        XCTAssertTrue(plan.createRequest.cloneTrackedCheckout)
        let result = try await GitService().createWorktreeWithResult(request: plan.createRequest, at: source)
        XCTAssertEqual(result.checkoutReport?.strategy, .ordinary)
        XCTAssertEqual(result.checkoutReport?.ineligibilityReason, "destination-not-app-managed")
    }

    #if DEBUG
        func testUnsupportedCloneFallsBackToResetInsideNewWorktreeOnly() async throws {
            let source = try makeSourceRepository(named: "unsupported-repo")
            guard try volumeSupportsCloning(source) else { throw XCTSkip("Requires an APFS temporary volume.") }
            let git = GitService()
            await git.setTrackedCheckoutCloneSyscallForTesting { _, _, _, _ in ENOTSUP }

            let result = try await createWorktree(from: source, branch: "rp/test/unsupported", service: git)

            let report = try XCTUnwrap(result.checkoutReport)
            XCTAssertEqual(report.strategy, .checkoutFallback)
            XCTAssertNotNil(report.fallbackReason)
            try assertCheckout(URL(fileURLWithPath: result.descriptor.path), matches: source, branch: "rp/test/unsupported")
            XCTAssertEqual(try worktreeCount(source), 2)
        }

        func testTamperedCloneIsRejectedByIndexRefreshAndReplacedByGitCheckout() async throws {
            let source = try makeSourceRepository(named: "tamper-repo")
            guard try volumeSupportsCloning(source) else { throw XCTSkip("Requires an APFS temporary volume.") }
            let git = GitService()
            await git.setTrackedCheckoutCloneSyscallForTesting { sourceDescriptor, directory, name, flags in
                guard fclonefileat(sourceDescriptor, directory, name, flags) == 0 else { return errno }
                if name == "value.txt" {
                    let descriptor = openat(directory, name, O_WRONLY | O_TRUNC | O_NOFOLLOW)
                    if descriptor >= 0 {
                        _ = "tampered\n".withCString { write(descriptor, $0, strlen($0)) }
                        close(descriptor)
                    }
                }
                return 0
            }

            let result = try await createWorktree(from: source, branch: "rp/test/tampered", service: git)

            let report = try XCTUnwrap(result.checkoutReport)
            XCTAssertEqual(report.strategy, .checkoutFallback)
            XCTAssertEqual(report.fallbackReason, "index refresh found files that differ from the target tree")
            let worktree = URL(fileURLWithPath: result.descriptor.path)
            try assertCheckout(worktree, matches: source, branch: "rp/test/tampered")
            XCTAssertEqual(
                try String(contentsOf: worktree.appendingPathComponent("src/nested/deep/value.txt")),
                "value\n"
            )
            XCTAssertEqual(try worktreeCount(source), 2)
        }
    #endif

    #if DEBUG
        func testDestinationSwappedForSymlinkDuringCloneFailsClosedWithoutTouchingSource() async throws {
            let source = try makeSourceRepository(named: "swap-repo")
            guard try volumeSupportsCloning(source) else { throw XCTSkip("Requires an APFS temporary volume.") }
            let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
                mainWorktreeRoot: source,
                existingWorktreeRoots: [source],
                branch: "rp/test/swap",
                cloneTrackedCheckout: true,
                purpose: .standaloneCreate(now: Date())
            ))
            try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
            let canonicalDestination = plan.path.resolvingSymlinksInPath().path
            let readme = source.appendingPathComponent("README.md")
            let swapped = SwapOnce()
            let service = GitService()
            await service.setTrackedCheckoutCloneSyscallForTesting { sourceDescriptor, directory, name, flags in
                if swapped.claim() {
                    // Simulate an attacker replacing the new worktree with a link to the source
                    // and editing a tracked source file after eligibility was proven.
                    rename(canonicalDestination, canonicalDestination + ".moved")
                    symlink(source.path, canonicalDestination)
                    try? "attacker edit\n".write(to: readme, atomically: false, encoding: .utf8)
                }
                return fclonefileat(sourceDescriptor, directory, name, flags) == 0 ? 0 : errno
            }

            do {
                _ = try await service.createWorktreeWithResult(request: plan.createRequest, at: source)
                XCTFail("A swapped destination must fail closed.")
            } catch {
                XCTAssertTrue(String(describing: error).contains("changed identity"), String(describing: error))
            }
            XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "attacker edit\n")
            XCTAssertEqual(try git("status", "--porcelain", "--untracked-files=no", at: source), "M README.md")
        }
    #endif

    // MARK: - Helpers

    private final class SwapOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    private func git(_ arguments: String..., at root: URL) throws -> String {
        try git(arguments, at: root)
    }

    private func makeSourceRepository(named name: String) throws -> URL {
        let root = try fixture.makeRepository(named: name, files: [
            "README.md": "# fixture\n",
            "src/nested/deep/value.txt": "value\n",
            "bin/run.sh": "#!/bin/sh\necho ok\n",
            ".gitignore": ".env.local\nbuild/\n",
            ".worktreeinclude": ".env.local\n"
        ])
        XCTAssertEqual(chmod(root.appendingPathComponent("bin/run.sh").path, 0o755), 0)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("value-link").path,
            withDestinationPath: "src/nested/deep/value.txt"
        )
        try fixture.runGit(["add", "-A"], at: root)
        try fixture.commit("modes and links", at: root)
        try fixture.write("LOCAL=1\n", to: ".env.local", at: root)
        try fixture.write("untracked\n", to: "notes.txt", at: root)
        return root
    }

    private func createWorktree(
        from source: URL,
        branch: String?,
        baseRef: String? = nil,
        detach: Bool = false,
        cloneTrackedCheckout: Bool = true,
        service: GitService = GitService()
    ) async throws -> GitWorktreeCreateResult {
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: source,
            existingWorktreeRoots: [source],
            branch: branch,
            baseRef: baseRef,
            detach: detach,
            cloneTrackedCheckout: true,
            purpose: .standaloneCreate(now: Date())
        ))
        try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
        let planned = plan.createRequest
        XCTAssertTrue(planned.cloneTrackedCheckout)
        let request = GitWorktreeCreateRequest(
            path: planned.path,
            branch: detach ? nil : planned.branch,
            baseRef: planned.baseRef,
            detach: planned.detach,
            force: planned.force,
            lockReason: planned.lockReason,
            allowExternalPath: planned.allowExternalPath,
            appManagedContainer: planned.appManagedContainer,
            mainWorktreeRoot: planned.mainWorktreeRoot,
            knownWorktreeRoots: planned.knownWorktreeRoots,
            copyWorktreeIncludeFiles: planned.copyWorktreeIncludeFiles,
            cloneTrackedCheckout: cloneTrackedCheckout
        )
        return try await service.createWorktreeWithResult(request: request, at: source)
    }

    private func assertOrdinary(
        _ reason: GitWorktreeTrackedCloneIneligibility,
        repository: String,
        baseRef: String? = nil,
        verifyCleanStatus: Bool = true,
        prepare: (URL) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let source = try makeSourceRepository(named: "ineligible-\(repository)")
        try prepare(source)
        let result = try await createWorktree(
            from: source,
            branch: "rp/test/\(repository)",
            baseRef: baseRef
        )
        XCTAssertEqual(result.checkoutReport?.strategy, .ordinary, repository, file: file, line: line)
        if try volumeSupportsCloning(source) {
            XCTAssertEqual(
                result.checkoutReport?.ineligibilityReason,
                reason.rawValue,
                repository,
                file: file,
                line: line
            )
        }
        let worktree = URL(fileURLWithPath: result.descriptor.path)
        XCTAssertEqual(
            try git(["rev-parse", "HEAD"], at: worktree),
            try git(["rev-parse", baseRef ?? "HEAD"], at: source),
            repository,
            file: file,
            line: line
        )
        if verifyCleanStatus {
            XCTAssertEqual(
                try git(["status", "--porcelain", "--untracked-files=no"], at: worktree),
                "",
                repository,
                file: file,
                line: line
            )
        }
    }

    private func assertCheckout(
        _ worktree: URL,
        matches source: URL,
        branch: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], at: worktree), "", file: file, line: line)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], at: worktree), "refs/heads/\(branch)", file: file, line: line)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: worktree), try git(["rev-parse", "HEAD"], at: source), file: file, line: line)
        XCTAssertEqual(try git(["ls-files", "-s"], at: worktree), try git(["ls-files", "-s"], at: source), file: file, line: line)
        for path in ["README.md", "src/nested/deep/value.txt", "bin/run.sh"] {
            XCTAssertEqual(
                try Data(contentsOf: worktree.appendingPathComponent(path)),
                try Data(contentsOf: source.appendingPathComponent(path)),
                path,
                file: file,
                line: line
            )
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worktree.appendingPathComponent("bin/run.sh").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent("value-link").path),
            "src/nested/deep/value.txt",
            file: file,
            line: line
        )
    }

    private func makeIncludeRoots(include: String) throws -> (URL, URL) {
        let name = UUID().uuidString
        let source = fixture.sandbox.appendingPathComponent("include-source-\(name)", isDirectory: true)
        let destination = fixture.sandbox.appendingPathComponent("include-destination-\(name)", isDirectory: true)
        try fixture.write(include, to: ".worktreeinclude", at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (source, destination)
    }

    private func appGitSupportsHookList() throws -> Bool {
        let probe = fixture.sandbox.appendingPathComponent("hook-probe-\(UUID().uuidString)", isDirectory: true)
        try fixture.initializeRepository(at: probe)
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        list.arguments = ["hook", "list", "post-checkout"]
        list.currentDirectoryURL = probe
        list.standardOutput = FileHandle.nullDevice
        list.standardError = FileHandle.nullDevice
        try list.run()
        list.waitUntilExit()
        // Supported: 0 (hooks found) or 1 (none). Unsupported subcommand: 129.
        return list.terminationStatus == 0 || list.terminationStatus == 1
    }

    private func volumeSupportsCloning(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning == true
    }

    private func worktreeCount(_ source: URL) throws -> Int {
        try fixture.runGit(["worktree", "list", "--porcelain"], at: source)
            .split(separator: "\n")
            .count(where: { $0.hasPrefix("worktree ") })
    }

    private func git(_ arguments: [String], at root: URL) throws -> String {
        try fixture.runGit(arguments, at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
